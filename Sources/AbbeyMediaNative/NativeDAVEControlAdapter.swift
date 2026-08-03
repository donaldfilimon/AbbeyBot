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
    func activatePendingCommit() async throws
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
    enum Origin: Equatable, Sendable {
        case replacementSession
        case activeSessionCommit
    }

    let generation: UInt64
    let transitionID: UInt16
    let protocolVersion: UInt16
    let session: (any NativeDAVEControlSession)?
    let origin: Origin
    let isReadyToExecute: Bool
    let isExecuting: Bool
    let requiresCommitActivation: Bool
}

private struct NativeDAVEExternalSenderState: Equatable, Sendable {
    let bytes: Data
    let activeGeneration: UInt64
    let groupID: UInt64
    let selfUserID: UInt64
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
    private var activeProtocolVersion: UInt16?
    private var pendingTransition: NativeDAVEPendingTransition?
    private var pendingGeneration: UInt64 = 0
    private var recognizedUserIDs: [UInt64] = []
    private var recognizedMembershipGeneration: UInt64 = 0
    private var externalSender: NativeDAVEExternalSenderState?
    private var externalSenderIntent: NativeDAVEExternalSenderState?
    private var externalSenderIntentGeneration: UInt64 = 0
    private var externalSenderPublicationGeneration: UInt64 = 0
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
        let previousContext = self.context
        let previousActiveGeneration = activeGeneration
        activeGeneration &+= 1
        let activeGeneration = self.activeGeneration
        activeSession = nil
        activeProtocolVersion = nil
        if previousContext?.groupID == context.groupID,
           previousContext?.selfUserID == context.selfUserID {
            rescopeExternalSenderState(
                from: previousActiveGeneration,
                to: activeGeneration,
                context: context
            )
        } else {
            invalidateExternalSenderState()
        }
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
        activeProtocolVersion = protocolVersion
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
            guard let context, let active = activeSession else {
                throw NativeDAVEControlAdapterError.sessionUnavailable
            }
            let activeGeneration = self.activeGeneration
            externalSenderIntentGeneration &+= 1
            let senderGeneration = externalSenderIntentGeneration
            externalSenderIntent = NativeDAVEExternalSenderState(
                bytes: marshalled,
                activeGeneration: activeGeneration,
                groupID: context.groupID,
                selfUserID: context.selfUserID
            )

            try await stabilizeExternalSender(
                on: active,
                activeGeneration: activeGeneration,
                context: context
            )
            try requireCurrentActiveSession(active, generation: activeGeneration)
            try requireCurrentContext(context)

            // Capture the pending session only after the active write resumes.
            // A transition constructed during that await must receive the same
            // latest package before this transaction can publish retention.
            let pending = pendingTransition
            if let pendingSession = pending?.session {
                // An active-epoch candidate aliases the active session; do not
                // send the same package twice to one libdave actor.
                if !sameSession(pendingSession, active) {
                    try await stabilizeExternalSender(
                        on: pendingSession,
                        activeGeneration: activeGeneration,
                        context: context
                    )
                }
                try requireCurrentActiveSession(active, generation: activeGeneration)
                try requireCurrentContext(context)
                try requireCurrentPendingTransition(pending)
            }
            try requireCurrentActiveSession(active, generation: activeGeneration)
            try requireCurrentContext(context)
            if pending != nil {
                try requireCurrentPendingTransition(pending)
            }
            guard externalSenderIntentGeneration == senderGeneration,
                  let latest = externalSenderIntent,
                  externalSenderState(latest, matches: activeGeneration, context: context)
            else {
                // A newer same-context transaction owns publication. This
                // older call may have converged the native actors to its value,
                // but it must never overwrite retained state.
                return []
            }
            externalSender = latest
            externalSenderPublicationGeneration &+= 1
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
                origin: .replacementSession,
                isReadyToExecute: preparation.protocolVersion == 0,
                isExecuting: false,
                requiresCommitActivation: false
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
                origin: .replacementSession,
                isReadyToExecute: false,
                isExecuting: false,
                requiresCommitActivation: false
            )
            return [.keyPackage(prepared.keyPackage)]

        case (.mlsPayloadReceived(.proposals), .proposals(let proposals)):
            if pendingTransition?.isExecuting == true
                || pendingTransition?.origin == .activeSessionCommit {
                throw NativeDAVEControlAdapterError.transitionProtocolUnavailable
            }
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
                try requireCurrentMembershipOrDiscardMutatedSession(
                    membership.generation,
                    session: proposalSession,
                    pending: pending,
                    activeGeneration: activeGeneration
                )
                discardMutatedProposalSessionIfCurrent(
                    proposalSession,
                    pending: pending,
                    activeGeneration: activeGeneration
                )
                throw error
            }
            try requireCurrentProposalSession(
                proposalSession,
                pending: pending,
                activeGeneration: activeGeneration
            )
            try requireCurrentMembershipOrDiscardMutatedSession(
                membership.generation,
                session: proposalSession,
                pending: pending,
                activeGeneration: activeGeneration
            )
            return [.commitWelcome(try VoiceGatewayDAVEOpaquePayload(commitWelcome))]

        case (.requiresMLSProcessing(let transitionID), .announceCommitTransition(let commit)):
            guard transitionID == commit.transitionID else {
                throw NativeDAVEControlAdapterError.transitionEventMismatch
            }
            let pending = try commitSession(for: transitionID)
            let isActiveSessionCommit = pendingTransition?.generation == pending.generation
                && pendingTransition?.origin == .activeSessionCommit
            do {
                let outcome = try await pending.session.processCommit(commit.commit.bytes)
                switch outcome {
                case .applied:
                    return try markPendingCommitReady(pending)
                case .ignored:
                    try requireCurrentPendingSession(pending)
                    return []
                }
            } catch let error as NativeMediaError where error.isInvalidMLSControlInput {
                guard isCurrentPendingSession(pending) else {
                    if isActiveSessionCommit {
                        poisonActiveSessionIfCurrent(
                            pending.session,
                            transitionGeneration: pending.generation
                        )
                    }
                    throw NativeDAVEControlAdapterError.staleOperation
                }
                return try await recoveryMessages(
                    transitionID: transitionID,
                    poisonedGeneration: pending.generation
                )
            } catch {
                if isActiveSessionCommit {
                    poisonActiveSessionIfCurrent(
                        pending.session,
                        transitionGeneration: pending.generation
                    )
                } else if isCurrentPendingSession(pending),
                          let current = pendingTransition {
                    invalidatePendingTransitionIfCurrent(current)
                }
                throw error
            }

        case (.requiresMLSProcessing(let transitionID), .welcome(let welcome)):
            guard transitionID == welcome.transitionID else {
                throw NativeDAVEControlAdapterError.transitionEventMismatch
            }
            guard pendingTransition?.origin == .replacementSession else {
                throw NativeDAVEControlAdapterError.transitionProtocolUnavailable
            }
            let pending = try pendingSession(for: transitionID)
            let membership = recognizedMembershipSnapshot()
            do {
                _ = try await pending.session.processWelcome(
                    welcome.welcome.bytes,
                    recognizedUserIDs: membership.userIDs
                )
                try requireCurrentMembershipOrDiscardPendingSession(
                    membership.generation,
                    processed: pending
                )
                return try await markPendingMediaReady(
                    pending,
                    recognizedMembershipGeneration: membership.generation
                )
            } catch let error as NativeDAVEControlAdapterError {
                throw error
            } catch let error as NativeMediaError where error.isInvalidMLSControlInput {
                try requireCurrentMembershipOrDiscardPendingSession(
                    membership.generation,
                    processed: pending
                )
                return try await recoveryMessages(
                    transitionID: transitionID,
                    poisonedGeneration: pending.generation,
                    recognizedMembershipGeneration: membership.generation
                )
            } catch {
                try requireCurrentPendingSession(pending)
                try requireCurrentMembershipOrDiscardPendingSession(
                    membership.generation,
                    processed: pending
                )
                if let current = pendingTransition {
                    invalidatePendingTransitionIfCurrent(current)
                }
                throw error
            }

        case (.transitionExecuted(let transitionID), .executeTransition(let execution)):
            guard transitionID == execution.transitionID else {
                throw NativeDAVEControlAdapterError.transitionEventMismatch
            }
            guard let pendingTransition,
                  pendingTransition.transitionID == transitionID,
                  pendingTransition.isReadyToExecute,
                  !pendingTransition.isExecuting
            else {
                throw NativeDAVEControlAdapterError.transitionProtocolUnavailable
            }
            if pendingTransition.protocolVersion > 0,
               pendingTransition.session == nil
            {
                throw NativeDAVEControlAdapterError.transitionProtocolUnavailable
            }

            let executing = NativeDAVEPendingTransition(
                generation: pendingTransition.generation,
                transitionID: pendingTransition.transitionID,
                protocolVersion: pendingTransition.protocolVersion,
                session: pendingTransition.session,
                origin: pendingTransition.origin,
                isReadyToExecute: true,
                isExecuting: true,
                requiresCommitActivation: pendingTransition.requiresCommitActivation
            )
            self.pendingTransition = executing
            if executing.requiresCommitActivation,
               let session = executing.session {
                do {
                    try await session.activatePendingCommit()
                } catch {
                    if executing.origin == .activeSessionCommit {
                        poisonActiveSessionIfCurrent(
                            session,
                            transitionGeneration: executing.generation
                        )
                    } else {
                        invalidatePendingTransitionIfCurrent(executing)
                    }
                    throw error
                }
                try requireCurrentPendingTransition(executing)
                if executing.origin == .activeSessionCommit,
                   !sameSession(activeSession, session) {
                    throw NativeDAVEControlAdapterError.staleOperation
                }
            }

            // No suspension remains between validating the execution lease and
            // publishing the new media epoch.
            let previousActiveGeneration = activeGeneration
            activeGeneration &+= 1
            activeSession = executing.session
            activeProtocolVersion = executing.protocolVersion > 0
                ? executing.protocolVersion
                : nil
            if executing.protocolVersion > 0, let context {
                rescopeExternalSenderState(
                    from: previousActiveGeneration,
                    to: activeGeneration,
                    context: context
                )
            } else {
                invalidateExternalSenderState()
            }
            self.pendingTransition = nil
            return []

        default:
            throw NativeDAVEControlAdapterError.unexpectedControlEvent
        }
    }

    public func reset() {
        activeGeneration &+= 1
        activeSession = nil
        activeProtocolVersion = nil
        pendingTransition = nil
        pendingGeneration &+= 1
        context = nil
        recognizedUserIDs.removeAll(keepingCapacity: false)
        recognizedMembershipGeneration &+= 1
        invalidateExternalSenderState()
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
        if poisoned.origin == .activeSessionCommit,
           let poisonedSession = poisoned.session,
           activeSession === poisonedSession {
            invalidateActiveSessionPreservingValidatedSender()
        }
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
            origin: .replacementSession,
            isReadyToExecute: false,
            isExecuting: false,
            requiresCommitActivation: false
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
        for _ in 0..<3 {
            guard let context else {
                throw NativeDAVEControlAdapterError.sessionUnavailable
            }
            let intentGeneration = externalSenderIntentGeneration
            let publicationGeneration = externalSenderPublicationGeneration
            if let intent = externalSenderIntent,
               externalSenderState(
                   intent,
                   matches: activeGeneration,
                   context: context
               ),
               externalSender != intent {
                // A current-context sender write has begun but has not yet
                // passed transaction validation. Building a Key Package from
                // the previously published sender would mix generations.
                throw NativeDAVEControlAdapterError.staleOperation
            }
            let sender = externalSender.flatMap { state in
                externalSenderState(
                    state,
                    matches: activeGeneration,
                    context: context
                ) ? state.bytes : nil
            }
            let replacement = try sessionFactory(
                protocolVersion,
                context.groupID,
                String(context.selfUserID)
            )
            if let sender {
                try await replacement.setExternalSender(sender)
            }
            let keyPackage = try await replacement.marshalledKeyPackage()
            guard externalSenderIntentGeneration == intentGeneration,
                  externalSenderPublicationGeneration == publicationGeneration,
                  isCurrentContext(context)
            else {
                // This replacement contains a Key Package derived from an old
                // External Sender. Drop it and retry; never publish it.
                continue
            }
            let opaque = try VoiceGatewayDAVEOpaquePayload(keyPackage)
            return (replacement, opaque)
        }
        throw NativeDAVEControlAdapterError.staleOperation
    }

    private func requireCompatiblePendingTransition(_ transitionID: UInt16) throws {
        guard pendingTransition == nil
                || (pendingTransition?.transitionID == transitionID
                    && pendingTransition?.origin == .replacementSession
                    && pendingTransition?.session == nil
                    && pendingTransition?.isExecuting == false)
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
                  current.protocolVersion == operation.protocolVersion,
                  current.origin == operation.origin,
                  current.isReadyToExecute == operation.isReadyToExecute,
                  current.isExecuting == operation.isExecuting,
                  current.requiresCommitActivation == operation.requiresCommitActivation,
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

    private func requireCurrentMembershipOrDiscardMutatedSession(
        _ membershipGeneration: UInt64,
        session: any NativeDAVEControlSession,
        pending operationTransition: NativeDAVEPendingTransition?,
        activeGeneration operationActiveGeneration: UInt64
    ) throws {
        guard recognizedMembershipGeneration != membershipGeneration else { return }
        if let operationTransition {
            invalidatePendingTransitionIfCurrent(operationTransition)
        } else if activeGeneration == operationActiveGeneration,
                  activeSession === session {
            // processProposals is stateful. Once its roster snapshot is stale,
            // the active MLS object cannot remain observable even though its
            // output is rejected. A fresh beginSession is the recovery point.
            invalidateActiveSessionPreservingValidatedSender()
            if let pendingTransition,
               pendingTransition.session === session {
                _ = invalidatePendingTransition()
            }
        }
        throw NativeDAVEControlAdapterError.staleOperation
    }

    private func discardMutatedProposalSessionIfCurrent(
        _ session: any NativeDAVEControlSession,
        pending operationTransition: NativeDAVEPendingTransition?,
        activeGeneration operationActiveGeneration: UInt64
    ) {
        if let operationTransition {
            invalidatePendingTransitionIfCurrent(operationTransition)
        } else if activeGeneration == operationActiveGeneration,
                  activeSession === session {
            invalidateActiveSessionPreservingValidatedSender()
            if let pendingTransition,
               pendingTransition.session === session {
                _ = invalidatePendingTransition()
            }
        }
    }

    private func requireCurrentMembershipOrDiscardPendingSession(
        _ membershipGeneration: UInt64,
        processed: (
            generation: UInt64,
            session: any NativeDAVEControlSession
        )
    ) throws {
        guard recognizedMembershipGeneration != membershipGeneration else { return }
        if let pendingTransition,
           pendingTransition.generation == processed.generation,
           pendingTransition.session === processed.session {
            _ = invalidatePendingTransition()
        }
        throw NativeDAVEControlAdapterError.staleOperation
    }

    private func stabilizeExternalSender(
        on session: any NativeDAVEControlSession,
        activeGeneration operationActiveGeneration: UInt64,
        context operationContext: VoiceGatewayDAVEConnectionContext
    ) async throws {
        for _ in 0..<3 {
            let appliedGeneration = externalSenderIntentGeneration
            guard let sender = externalSenderIntent,
                  externalSenderState(
                      sender,
                      matches: operationActiveGeneration,
                      context: operationContext
                  )
            else {
                throw NativeDAVEControlAdapterError.staleOperation
            }
            try await session.setExternalSender(sender.bytes)
            try requireCurrentContext(operationContext)
            guard activeGeneration == operationActiveGeneration else {
                throw NativeDAVEControlAdapterError.staleOperation
            }
            guard externalSenderIntentGeneration != appliedGeneration else { return }
        }
        throw NativeDAVEControlAdapterError.staleOperation
    }

    private func requireCurrentContext(
        _ operationContext: VoiceGatewayDAVEConnectionContext
    ) throws {
        guard isCurrentContext(operationContext) else {
            throw NativeDAVEControlAdapterError.staleOperation
        }
    }

    private func isCurrentContext(
        _ operationContext: VoiceGatewayDAVEConnectionContext
    ) -> Bool {
        context?.groupID == operationContext.groupID
            && context?.selfUserID == operationContext.selfUserID
    }

    private func externalSenderState(
        _ state: NativeDAVEExternalSenderState,
        matches operationActiveGeneration: UInt64,
        context operationContext: VoiceGatewayDAVEConnectionContext
    ) -> Bool {
        state.activeGeneration == operationActiveGeneration
            && state.groupID == operationContext.groupID
            && state.selfUserID == operationContext.selfUserID
    }

    private func invalidateExternalSenderState() {
        externalSender = nil
        externalSenderIntent = nil
        externalSenderIntentGeneration &+= 1
        externalSenderPublicationGeneration &+= 1
    }

    private func invalidateActiveSessionPreservingValidatedSender() {
        let previousGeneration = activeGeneration
        activeGeneration &+= 1
        activeSession = nil
        activeProtocolVersion = nil
        if let context {
            rescopeExternalSenderState(
                from: previousGeneration,
                to: activeGeneration,
                context: context
            )
        } else {
            invalidateExternalSenderState()
        }
    }

    private func rescopeExternalSenderState(
        from previousGeneration: UInt64,
        to currentGeneration: UInt64,
        context: VoiceGatewayDAVEConnectionContext
    ) {
        guard let published = externalSender,
              published == externalSenderIntent,
              externalSenderState(
                  published,
                  matches: previousGeneration,
                  context: context
              )
        else {
            invalidateExternalSenderState()
            return
        }
        let rescoped = NativeDAVEExternalSenderState(
            bytes: published.bytes,
            activeGeneration: currentGeneration,
            groupID: context.groupID,
            selfUserID: context.selfUserID
        )
        externalSender = rescoped
        externalSenderIntent = rescoped
        externalSenderIntentGeneration &+= 1
        externalSenderPublicationGeneration &+= 1
    }

    private func invalidatePendingTransitionIfCurrent(
        _ operationTransition: NativeDAVEPendingTransition
    ) {
        guard let current = pendingTransition,
              current.generation == operationTransition.generation,
              current.transitionID == operationTransition.transitionID,
              sameSession(current.session, operationTransition.session)
        else { return }
        _ = invalidatePendingTransition()
    }

    private func poisonActiveSessionIfCurrent(
        _ session: any NativeDAVEControlSession,
        transitionGeneration: UInt64
    ) {
        guard activeSession === session else { return }
        invalidateActiveSessionPreservingValidatedSender()
        if pendingTransition?.generation == transitionGeneration {
            _ = invalidatePendingTransition()
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
              !pendingTransition.isExecuting,
              let session = pendingTransition.session
        else {
            throw NativeDAVEControlAdapterError.transitionProtocolUnavailable
        }
        return (pendingTransition.generation, session)
    }

    private func commitSession(
        for transitionID: UInt16
    ) throws -> (
        generation: UInt64,
        session: any NativeDAVEControlSession
    ) {
        if pendingTransition != nil {
            return try pendingSession(for: transitionID)
        }
        guard let activeSession,
              let activeProtocolVersion,
              activeProtocolVersion > 0
        else {
            throw NativeDAVEControlAdapterError.transitionProtocolUnavailable
        }
        pendingGeneration &+= 1
        let transition = NativeDAVEPendingTransition(
            generation: pendingGeneration,
            transitionID: transitionID,
            protocolVersion: activeProtocolVersion,
            session: activeSession,
            origin: .activeSessionCommit,
            isReadyToExecute: false,
            isExecuting: false,
            requiresCommitActivation: false
        )
        pendingTransition = transition
        return (transition.generation, activeSession)
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
            try requireCurrentMembershipOrDiscardPendingSession(
                recognizedMembershipGeneration,
                processed: processed
            )
        }
        guard isMediaReady,
              let pendingTransition,
              pendingTransition.generation == processed.generation,
              pendingTransition.session === processed.session,
              !pendingTransition.isExecuting
        else {
            throw NativeDAVEControlAdapterError.transitionProtocolUnavailable
        }
        self.pendingTransition = NativeDAVEPendingTransition(
            generation: pendingTransition.generation,
            transitionID: pendingTransition.transitionID,
            protocolVersion: pendingTransition.protocolVersion,
            session: pendingTransition.session,
            origin: pendingTransition.origin,
            isReadyToExecute: true,
            isExecuting: false,
            requiresCommitActivation: false
        )
        return [.transitionReady(
            VoiceGatewayDAVETransitionReady(
                transitionID: pendingTransition.transitionID
            )
        )]
    }

    private func markPendingCommitReady(
        _ processed: (
            generation: UInt64,
            session: any NativeDAVEControlSession
        )
    ) throws -> [VoiceGatewayDAVEClientMessage] {
        guard let pendingTransition,
              pendingTransition.generation == processed.generation,
              pendingTransition.session === processed.session,
              !pendingTransition.isExecuting
        else {
            throw NativeDAVEControlAdapterError.transitionProtocolUnavailable
        }
        self.pendingTransition = NativeDAVEPendingTransition(
            generation: pendingTransition.generation,
            transitionID: pendingTransition.transitionID,
            protocolVersion: pendingTransition.protocolVersion,
            session: pendingTransition.session,
            origin: pendingTransition.origin,
            isReadyToExecute: true,
            isExecuting: false,
            requiresCommitActivation: true
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

    private func isCurrentPendingSession(
        _ processed: (
            generation: UInt64,
            session: any NativeDAVEControlSession
        )
    ) -> Bool {
        guard let pendingTransition else { return false }
        return pendingTransition.generation == processed.generation
            && pendingTransition.session === processed.session
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
