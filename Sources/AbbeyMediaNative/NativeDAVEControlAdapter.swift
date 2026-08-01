import AbbeyCore
import Foundation

public enum NativeDAVEControlAdapterError: Error, Equatable, Sendable {
    case sessionUnavailable
    case unexpectedControlEvent
    case transitionProtocolUnavailable
}

/// Owns the single libdave MLS session shared by Voice Gateway control handling
/// and the native media plane.
///
/// Every nonzero protocol transition or recovery replaces the complete native
/// session. This prevents ratchets, roster state, or pending MLS objects from
/// crossing an epoch boundary. Opaque MLS values remain memory-only and are
/// never included in this actor's diagnostics.
public actor NativeDAVEControlAdapter: CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    private var context: VoiceGatewayDAVEConnectionContext?
    private var session: NativeDAVESession?
    private var recognizedUserIDs: [UInt64] = []
    private var externalSender: Data?
    private var transitionProtocolVersions: [UInt16: UInt16] = [:]
    private var effectiveProtocolVersion: UInt16 = 0

    public nonisolated var description: String {
        "NativeDAVEControlAdapter(session: <redacted>, state: private)"
    }

    public nonisolated var debugDescription: String { description }

    public nonisolated var customMirror: Mirror {
        Mirror(self, children: ["session": "<redacted>"], displayStyle: .class)
    }

    public init() {}

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
    public func mediaSession() -> NativeDAVESession? { session }

    public func beginSession(
        context: VoiceGatewayDAVEConnectionContext,
        protocolVersion: UInt16
    ) async throws -> [VoiceGatewayDAVEClientMessage] {
        self.context = context
        effectiveProtocolVersion = protocolVersion
        if !recognizedUserIDs.contains(context.selfUserID) {
            recognizedUserIDs.append(context.selfUserID)
            recognizedUserIDs.sort()
        }
        let keyPackage = try await replaceSession(protocolVersion: protocolVersion)
        return [.keyPackage(keyPackage)]
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
    }

    public func handle(
        _ frame: VoiceGatewayDAVEInboundFrame,
        event: VoiceGatewayDAVETransitionStateMachine.Event
    ) async throws -> [VoiceGatewayDAVEClientMessage] {
        switch (event, frame.message) {
        case (.externalSenderRetained, .externalSenderPackage(let package)):
            let marshalled = package.marshalledBytes
            if let session {
                try await session.setExternalSender(marshalled)
            }
            externalSender = marshalled
            return []

        case (.transitionPrepared(let transitionID), .prepareTransition(let preparation)):
            transitionProtocolVersions[transitionID] = preparation.protocolVersion
            return [.transitionReady(
                VoiceGatewayDAVETransitionReady(transitionID: transitionID)
            )]

        case (.epochAnnounced(let epoch), .prepareEpoch):
            transitionProtocolVersions[epoch.transitionID] = epoch.protocolVersion
            let keyPackage = try await replaceSession(protocolVersion: epoch.protocolVersion)
            return [.keyPackage(keyPackage)]

        case (.mlsPayloadReceived(.proposals), .proposals(let proposals)):
            guard let session else {
                throw NativeDAVEControlAdapterError.sessionUnavailable
            }
            let commitWelcome = try await session.processProposals(
                proposals.marshalledBytes,
                recognizedUserIDs: recognizedUserIDs.map(String.init)
            )
            return [.commitWelcome(try VoiceGatewayDAVEOpaquePayload(commitWelcome))]

        case (.requiresMLSProcessing(let transitionID), .announceCommitTransition(let commit)):
            do {
                guard let session else {
                    throw NativeDAVEControlAdapterError.sessionUnavailable
                }
                _ = try await session.processCommit(commit.commit.bytes)
                return [.transitionReady(
                    VoiceGatewayDAVETransitionReady(transitionID: transitionID)
                )]
            } catch {
                return try await recoveryMessages(transitionID: transitionID)
            }

        case (.requiresMLSProcessing(let transitionID), .welcome(let welcome)):
            do {
                guard let session else {
                    throw NativeDAVEControlAdapterError.sessionUnavailable
                }
                _ = try await session.processWelcome(
                    welcome.welcome.bytes,
                    recognizedUserIDs: recognizedUserIDs.map(String.init)
                )
                return [.transitionReady(
                    VoiceGatewayDAVETransitionReady(transitionID: transitionID)
                )]
            } catch {
                return try await recoveryMessages(transitionID: transitionID)
            }

        case (.transitionExecuted(let transitionID), .executeTransition):
            guard let protocolVersion = transitionProtocolVersions.removeValue(
                forKey: transitionID
            ) else {
                throw NativeDAVEControlAdapterError.transitionProtocolUnavailable
            }
            effectiveProtocolVersion = protocolVersion
            if protocolVersion == 0 {
                session = nil
            } else {
                guard let session,
                      await session.protocolVersion == protocolVersion
                else {
                    throw NativeDAVEControlAdapterError.transitionProtocolUnavailable
                }
            }
            return []

        default:
            throw NativeDAVEControlAdapterError.unexpectedControlEvent
        }
    }

    public func reset() {
        session = nil
        context = nil
        recognizedUserIDs.removeAll(keepingCapacity: false)
        externalSender = nil
        transitionProtocolVersions.removeAll(keepingCapacity: false)
        effectiveProtocolVersion = 0
    }

    private func recoveryMessages(
        transitionID: UInt16
    ) async throws -> [VoiceGatewayDAVEClientMessage] {
        let protocolVersion = transitionProtocolVersions[transitionID]
            ?? effectiveProtocolVersion
        guard protocolVersion > 0 else {
            throw NativeDAVEControlAdapterError.transitionProtocolUnavailable
        }
        let keyPackage = try await replaceSession(protocolVersion: protocolVersion)
        return [
            .invalidCommitWelcome(
                VoiceGatewayDAVEInvalidCommitWelcome(transitionID: transitionID)
            ),
            .keyPackage(keyPackage),
        ]
    }

    private func replaceSession(
        protocolVersion: UInt16
    ) async throws -> VoiceGatewayDAVEOpaquePayload {
        guard let context else {
            throw NativeDAVEControlAdapterError.sessionUnavailable
        }
        let replacement = try NativeDAVESession(
            protocolVersion: protocolVersion,
            groupID: context.groupID,
            selfUserID: String(context.selfUserID)
        )
        if let externalSender {
            try await replacement.setExternalSender(externalSender)
        }
        let keyPackage = try await replacement.marshalledKeyPackage()
        let opaque = try VoiceGatewayDAVEOpaquePayload(keyPackage)
        session = replacement
        effectiveProtocolVersion = protocolVersion
        return opaque
    }
}
