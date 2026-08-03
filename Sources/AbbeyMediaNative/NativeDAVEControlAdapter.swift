import AbbeyCore
import Foundation

public enum NativeDAVEControlAdapterError: Error, Equatable, Sendable {
    case sessionUnavailable
    case staleOperation
    case transitionEventMismatch
    case unexpectedControlEvent
    case transitionProtocolUnavailable
}

protocol NativeDAVEControlSession: AnyObject, Sendable {
    var isMediaReady: Bool { get async }

    func marshalledKeyPackage() async throws -> Data
    func setExternalSender(_ bytes: Data) async throws
    func processProposals(
        _ proposals: Data,
        recognizedUserIDs: [String]
    ) async throws -> Data
    func processCommit(_ commit: Data) async throws -> NativeDAVECommitOutcome
    func processWelcome(
        _ welcome: Data,
        recognizedUserIDs: [String]
    ) async throws -> [UInt64]
}

extension NativeDAVESession: NativeDAVEControlSession {}

typealias NativeDAVEControlSessionFactory = @Sendable (
    _ protocolVersion: UInt16,
    _ groupID: UInt64,
    _ selfUserID: String
) throws -> any NativeDAVEControlSession

private struct NativeDAVEPendingTransition: Sendable {
    let generation: UInt64
    let transitionID: UInt16
    let protocolVersion: UInt16
    let session: (any NativeDAVEControlSession)?
    let isMediaReady: Bool
}

/// Owns the libdave MLS sessions shared by Voice Gateway control handling and
/// the native media plane.
///
/// The media plane sees only the active session. A nonzero epoch is built and
/// validated in a transition-correlated pending session, then promoted only by
/// Execute Transition. This prevents uncommitted ratchets, roster state, or MLS
/// objects from crossing an epoch boundary. Opaque MLS values remain
/// memory-only and are never included in this actor's diagnostics.
public actor NativeDAVEControlAdapter: CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    private var context: VoiceGatewayDAVEConnectionContext?
    private var activeSession: (any NativeDAVEControlSession)?
    private var activeGeneration: UInt64 = 0
    private var pendingTransition: NativeDAVEPendingTransition?
    private var pendingGeneration: UInt64 = 0
    private var recognizedUserIDs: [UInt64] = []
    private var recognizedMembershipGeneration: UInt64 = 0
    private var externalSender: Data?
    private let sessionFactory: NativeDAVEControlSessionFactory

    public nonisolated var description: String {
        "NativeDAVEControlAdapter(session: <redacted>, state: private)"
    }

    public nonisolated var debugDescription: String { description }

    public nonisolated var customMirror: Mirror {
        Mirror(self, children: ["session": "<redacted>"], displayStyle: .class)
    }

    public init() {
        sessionFactory = { protocolVersion, groupID, selfUserID in
            try NativeDAVESession(
                protocolVersion: protocolVersion,
                groupID: groupID,
                selfUserID: selfUserID
            )
        }
    }

    init(sessionFactory: @escaping NativeDAVEControlSessionFactory) {
        self.sessionFactory = sessionFactory
    }

    /// A value-semantic callback boundary suitable for injection into AbbeyCore.
    public nonisolated var controlHandler: VoiceGatewayDAVEControlHandler {
        VoiceGatewayDAVEControlHandler(
            beginSession: { [self] context, protocolVersion in
                try await beginSession(context: context, protocolVersion: protocolVersion)
            },
            replaceRecognizedUserIDs: { [self] userIDs in
                await replaceRecognizedUserIDs(userIDs)
            },
            handle: { [self] frame, event in
                try await handle(frame, event: event)
            },
            reset: { [self] in
                await reset()
            }
        )
    }

    /// Returns the exact actor used by the control path so the media plane cannot
    /// accidentally protect packets with an unrelated MLS session.
    public func mediaSession() -> NativeDAVESession? {
        activeSession as? NativeDAVESession
    }

    public func beginSession(
        context: VoiceGatewayDAVEConnectionContext,
        protocolVersion: UInt16
    ) async throws -> [VoiceGatewayDAVEClientMessage] {
        activeGeneration &+= 1
        let activeGeneration = self.activeGeneration
        activeSession = nil
        self.context = context
        if !recognizedUserIDs.contains(context.selfUserID) {
            recognizedUserIDs.append(context.selfUserID)
            recognizedUserIDs.sort()
        }
        let generation = invalidatePendingTransition()
        let prepared = try await makeSession(protocolVersion: protocolVersion)
        guard self.activeGeneration == activeGeneration,
              activeSession == nil,
              pendingGeneration == generation,
              self.context?.groupID == context.groupID,
              self.context?.selfUserID == context.selfUserID
        else {
            throw NativeDAVEControlAdapterError.sessionUnavailable
        }
        activeSession = prepared.session
        return [.keyPackage(prepared.keyPackage)]
    }

    public func replaceRecognizedUserIDs(_ userIDs: [UInt64]) {
        var normalized = Array(Set(userIDs.filter { $0 > 0 })).sorted()
        if let selfUserID = context?.selfUserID,
           !normalized.contains(selfUserID)
        {
            normalized.append(selfUserID)
            normalized.sort()
        }
        recognizedUserIDs = normalized
        recognizedMembershipGeneration &+= 1
    }

    public func handle(
        _ frame: VoiceGatewayDAVEInboundFrame,
        event: VoiceGatewayDAVETransitionStateMachine.Event
    ) async throws -> [VoiceGatewayDAVEClientMessage] {
        switch (event, frame.message) {
        case (.externalSenderRetained, .externalSenderPackage(let package)):
            let marshalled = package.marshalledBytes
            let active = activeSession
            let activeGeneration = self.activeGeneration
            let pending = pendingTransition
            if let active {
                try await active.setExternalSender(marshalled)
                try requireCurrentActiveSession(active, generation: activeGeneration)
                try requireCurrentPendingTransition(pending)
            }
            if let pendingSession = pending?.session {
                try await pendingSession.setExternalSender(marshalled)
                try requireCurrentActiveSession(active, generation: activeGeneration)
                try requireCurrentPendingTransition(pending)
            }
            try requireCurrentActiveSession(active, generation: activeGeneration)
            try requireCurrentPendingTransition(pending)
            externalSender = marshalled
            return []

        case (.transitionPrepared(let transitionID), .prepareTransition(let preparation)):
            guard transitionID == preparation.transitionID else {
                throw NativeDAVEControlAdapterError.transitionEventMismatch
            }
            try requireCompatiblePendingTransition(transitionID)
            let generation = invalidatePendingTransition()
            pendingTransition = NativeDAVEPendingTransition(
                generation: generation,
                transitionID: transitionID,
                protocolVersion: preparation.protocolVersion,
                session: nil,
                isMediaReady: preparation.protocolVersion == 0
            )
            return [.transitionReady(
                VoiceGatewayDAVETransitionReady(transitionID: transitionID)
            )]

        case (.epochAnnounced(let epoch), .prepareEpoch(let preparation)):
            guard epoch.transitionID == preparation.transitionID,
                  epoch.protocolVersion == preparation.protocolVersion,
                  epoch.epoch == preparation.epoch
            else {
                throw NativeDAVEControlAdapterError.transitionEventMismatch
            }
            try requireCompatiblePendingTransition(epoch.transitionID)
            let generation = invalidatePendingTransition()
            let prepared = try await makeSession(protocolVersion: epoch.protocolVersion)
            guard pendingGeneration == generation, pendingTransition == nil else {
                throw NativeDAVEControlAdapterError.transitionProtocolUnavailable
            }
            pendingTransition = NativeDAVEPendingTransition(
                generation: generation,
                transitionID: epoch.transitionID,
                protocolVersion: epoch.protocolVersion,
                session: prepared.session,
                isMediaReady: false
            )
            return [.keyPackage(prepared.keyPackage)]

        case (.mlsPayloadReceived(.proposals), .proposals(let proposals)):
            let pending = pendingTransition.flatMap { transition in
                transition.protocolVersion > 0 && transition.session != nil
                    ? transition
                    : nil
            }
            let proposalSession = pending?.session ?? activeSession
            guard let proposalSession else {
                throw NativeDAVEControlAdapterError.sessionUnavailable
            }
            let activeGeneration = self.activeGeneration
            let membership = recognizedMembershipSnapshot()
            let commitWelcome: Data
            do {
                commitWelcome = try await proposalSession.processProposals(
                    proposals.marshalledBytes,
                    recognizedUserIDs: membership.userIDs
                )
            } catch {
                try requireCurrentProposalSession(
                    proposalSession,
                    pending: pending,
                    activeGeneration: activeGeneration
                )
                try requireCurrentRecognizedMembership(membership.generation)
                throw error
            }
            try requireCurrentProposalSession(
                proposalSession,
                pending: pending,
                activeGeneration: activeGeneration
            )
            try requireCurrentRecognizedMembership(membership.generation)
            return [.commitWelcome(try VoiceGatewayDAVEOpaquePayload(commitWelcome))]

        case (.requiresMLSProcessing(let transitionID), .announceCommitTransition(let commit)):
            guard transitionID == commit.transitionID else {
                throw NativeDAVEControlAdapterError.transitionEventMismatch
            }
            let pending = try pendingSession(for: transitionID)
            do {
                let outcome = try await pending.session.processCommit(commit.commit.bytes)
                switch outcome {
                case .applied:
                    return try await markPendingMediaReady(pending)
                case .ignored:
                    try requireCurrentPendingSession(pending)
                    return []
                }
            } catch let error as NativeMediaError where error.isInvalidMLSControlInput {
                return try await recoveryMessages(
                    transitionID: transitionID,
                    poisonedGeneration: pending.generation
                )
            }

        case (.requiresMLSProcessing(let transitionID), .welcome(let welcome)):
            guard transitionID == welcome.transitionID else {
                throw NativeDAVEControlAdapterError.transitionEventMismatch
            }
            let pending = try pendingSession(for: transitionID)
            let membership = recognizedMembershipSnapshot()
            do {
                _ = try await pending.session.processWelcome(
                    welcome.welcome.bytes,
                    recognizedUserIDs: membership.userIDs
                )
                try requireCurrentRecognizedMembership(membership.generation)
                return try await markPendingMediaReady(
                    pending,
                    recognizedMembershipGeneration: membership.generation
                )
            } catch let error as NativeMediaError where error.isInvalidMLSControlInput {
                try requireCurrentRecognizedMembership(membership.generation)
                return try await recoveryMessages(
                    transitionID: transitionID,
                    poisonedGeneration: pending.generation,
                    recognizedMembershipGeneration: membership.generation
                )
            } catch {
                try requireCurrentRecognizedMembership(membership.generation)
                try requireCurrentPendingSession(pending)
                throw error
            }

        case (.transitionExecuted(let transitionID), .executeTransition(let execution)):
            guard transitionID == execution.transitionID else {
                throw NativeDAVEControlAdapterError.transitionEventMismatch
            }
            guard let pendingTransition,
                  pendingTransition.transitionID == transitionID,
                  pendingTransition.isMediaReady
            else {
                throw NativeDAVEControlAdapterError.transitionProtocolUnavailable
            }
            if pendingTransition.protocolVersion > 0,
               pendingTransition.session == nil
            {
                throw NativeDAVEControlAdapterError.transitionProtocolUnavailable
            }
            // No suspension occurs between validating the correlation/readiness
            // and publishing the new media epoch.
            activeGeneration &+= 1
            activeSession = pendingTransition.session
            self.pendingTransition = nil
            return []

        default:
            throw NativeDAVEControlAdapterError.unexpectedControlEvent
        }
    }

    public func reset() {
        activeGeneration &+= 1
        activeSession = nil
        pendingTransition = nil
        pendingGeneration &+= 1
        context = nil
        recognizedUserIDs.removeAll(keepingCapacity: false)
        recognizedMembershipGeneration &+= 1
        externalSender = nil
    }

    private func recoveryMessages(
        transitionID: UInt16,
        poisonedGeneration: UInt64,
        recognizedMembershipGeneration: UInt64? = nil
    ) async throws -> [VoiceGatewayDAVEClientMessage] {
        guard let poisoned = pendingTransition,
              poisoned.transitionID == transitionID,
              poisoned.generation == poisonedGeneration
        else {
            throw NativeDAVEControlAdapterError.transitionProtocolUnavailable
        }
        let protocolVersion = poisoned.protocolVersion
        guard protocolVersion > 0 else {
            throw NativeDAVEControlAdapterError.transitionProtocolUnavailable
        }

        // Remove the poisoned session before any await so a re-entrant Execute
        // cannot promote it. The generation reserves this recovery transaction;
        // a newer control event wins instead of being overwritten on resume.
        let generation = invalidatePendingTransition()
        let prepared = try await makeSession(protocolVersion: protocolVersion)
        if let recognizedMembershipGeneration {
            try requireCurrentRecognizedMembership(recognizedMembershipGeneration)
        }
        guard pendingGeneration == generation, pendingTransition == nil else {
            throw NativeDAVEControlAdapterError.transitionProtocolUnavailable
        }
        pendingTransition = NativeDAVEPendingTransition(
            generation: generation,
            transitionID: transitionID,
            protocolVersion: protocolVersion,
            session: prepared.session,
            isMediaReady: false
        )
        return [
            .invalidCommitWelcome(
                VoiceGatewayDAVEInvalidCommitWelcome(transitionID: transitionID)
            ),
            .keyPackage(prepared.keyPackage),
        ]
    }

    private func makeSession(
        protocolVersion: UInt16
    ) async throws -> (
        session: any NativeDAVEControlSession,
        keyPackage: VoiceGatewayDAVEOpaquePayload
    ) {
        guard let context else {
            throw NativeDAVEControlAdapterError.sessionUnavailable
        }
        let replacement = try sessionFactory(
            protocolVersion,
            context.groupID,
            String(context.selfUserID)
        )
        if let externalSender {
            try await replacement.setExternalSender(externalSender)
        }
        let keyPackage = try await replacement.marshalledKeyPackage()
        let opaque = try VoiceGatewayDAVEOpaquePayload(keyPackage)
        return (replacement, opaque)
    }

    private func requireCompatiblePendingTransition(_ transitionID: UInt16) throws {
        guard pendingTransition == nil
                || pendingTransition?.transitionID == transitionID
        else {
            throw NativeDAVEControlAdapterError.transitionProtocolUnavailable
        }
    }

    private func requireCurrentActiveSession(
        _ operationSession: (any NativeDAVEControlSession)?,
        generation operationGeneration: UInt64
    ) throws {
        guard activeGeneration == operationGeneration,
              sameSession(activeSession, operationSession)
        else {
            throw NativeDAVEControlAdapterError.staleOperation
        }
    }

    private func requireCurrentPendingTransition(
        _ operationTransition: NativeDAVEPendingTransition?
    ) throws {
        switch (pendingTransition, operationTransition) {
        case (nil, nil):
            return
        case (.some(let current), .some(let operation)):
            guard current.generation == operation.generation,
                  current.transitionID == operation.transitionID,
                  sameSession(current.session, operation.session)
            else {
                throw NativeDAVEControlAdapterError.staleOperation
            }
        default:
            throw NativeDAVEControlAdapterError.staleOperation
        }
    }

    private func requireCurrentProposalSession(
        _ operationSession: any NativeDAVEControlSession,
        pending operationTransition: NativeDAVEPendingTransition?,
        activeGeneration operationActiveGeneration: UInt64
    ) throws {
        if let operationTransition {
            try requireCurrentPendingTransition(operationTransition)
            guard operationTransition.session === operationSession else {
                throw NativeDAVEControlAdapterError.staleOperation
            }
        } else {
            try requireCurrentActiveSession(
                operationSession,
                generation: operationActiveGeneration
            )
            if let currentPending = pendingTransition,
               currentPending.protocolVersion > 0,
               currentPending.session != nil
            {
                throw NativeDAVEControlAdapterError.staleOperation
            }
        }
    }

    private func recognizedMembershipSnapshot() -> (
        generation: UInt64,
        userIDs: [String]
    ) {
        (
            recognizedMembershipGeneration,
            recognizedUserIDs.map(String.init)
        )
    }

    private func requireCurrentRecognizedMembership(_ generation: UInt64) throws {
        guard recognizedMembershipGeneration == generation else {
            throw NativeDAVEControlAdapterError.staleOperation
        }
    }

    private func pendingSession(
        for transitionID: UInt16
    ) throws -> (
        generation: UInt64,
        session: any NativeDAVEControlSession
    ) {
        guard let pendingTransition,
              pendingTransition.transitionID == transitionID,
              let session = pendingTransition.session
        else {
            throw NativeDAVEControlAdapterError.transitionProtocolUnavailable
        }
        return (pendingTransition.generation, session)
    }

    private func markPendingMediaReady(
        _ processed: (
            generation: UInt64,
            session: any NativeDAVEControlSession
        ),
        recognizedMembershipGeneration: UInt64? = nil
    ) async throws -> [VoiceGatewayDAVEClientMessage] {
        let isMediaReady = await processed.session.isMediaReady
        if let recognizedMembershipGeneration {
            try requireCurrentRecognizedMembership(recognizedMembershipGeneration)
        }
        guard isMediaReady,
              let pendingTransition,
              pendingTransition.generation == processed.generation,
              pendingTransition.session === processed.session
        else {
            throw NativeDAVEControlAdapterError.transitionProtocolUnavailable
        }
        self.pendingTransition = NativeDAVEPendingTransition(
            generation: pendingTransition.generation,
            transitionID: pendingTransition.transitionID,
            protocolVersion: pendingTransition.protocolVersion,
            session: pendingTransition.session,
            isMediaReady: true
        )
        return [.transitionReady(
            VoiceGatewayDAVETransitionReady(
                transitionID: pendingTransition.transitionID
            )
        )]
    }

    private func requireCurrentPendingSession(
        _ processed: (
            generation: UInt64,
            session: any NativeDAVEControlSession
        )
    ) throws {
        guard let pendingTransition,
              pendingTransition.generation == processed.generation,
              pendingTransition.session === processed.session
        else {
            throw NativeDAVEControlAdapterError.transitionProtocolUnavailable
        }
    }

    @discardableResult
    private func invalidatePendingTransition() -> UInt64 {
        pendingGeneration &+= 1
        pendingTransition = nil
        return pendingGeneration
    }

    private func sameSession(
        _ lhs: (any NativeDAVEControlSession)?,
        _ rhs: (any NativeDAVEControlSession)?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case (.some(let lhs), .some(let rhs)):
            lhs === rhs
        default:
            false
        }
    }
}

private extension NativeMediaError {
    var isInvalidMLSControlInput: Bool {
        switch self {
        case .daveCommitFailed,
             .daveWelcomeFailed,
             .daveMLSFailure,
             .daveParticipantUnavailable:
            true
        default:
            false
        }
    }
}
