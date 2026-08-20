import Foundation

public enum DiscordVoiceGatewaySessionPhase: String, Equatable, Sendable {
    case idle
    case connecting
    case awaitingTransportSelection
    case awaitingSessionDescription
    /// Voice Gateway signaling is established; media readiness is separately attested.
    case established
    case disconnecting
    case disconnected
    case failed
}

public enum DiscordVoiceGatewaySessionError: Error, Equatable, Sendable, CustomStringConvertible {
    case alreadyRunning
    case notConnected
    case transportNotReady
    case transportAlreadySelected
    case sessionDescriptionUnavailable
    case transportFailed
    case connectionClosed(Int)
    case disconnected
    case staleConnection
    case outboundEncodingFailed
    case outboundPayloadTooLarge

    public var description: String {
        switch self {
        case .alreadyRunning: "Discord Voice Gateway session is already running"
        case .notConnected: "Discord Voice Gateway session is not connected"
        case .transportNotReady: "Discord Voice Gateway transport is not ready for selection"
        case .transportAlreadySelected: "Discord Voice Gateway transport was already selected"
        case .sessionDescriptionUnavailable: "Discord Voice Gateway Session Description is unavailable"
        case .transportFailed: "Discord Voice Gateway transport failed"
        case .connectionClosed(let code): "Discord Voice Gateway connection closed with code \(code)"
        case .disconnected: "Discord Voice Gateway session was disconnected"
        case .staleConnection: "Discord Voice Gateway operation belongs to an obsolete connection"
        case .outboundEncodingFailed: "Discord Voice Gateway outbound message could not be encoded"
        case .outboundPayloadTooLarge: "Discord Voice Gateway outbound message exceeded its size limit"
        }
    }
}

/// Injectable evidence about the native media stack available to this process.
///
/// The attestation never receives the transport secret key. It reports whether
/// the installed native stack can operate the already-negotiated mode and DAVE
/// protocol version. The session independently prevents DAVE from being reported
/// active when Discord negotiated protocol version zero.
public struct DiscordVoiceMediaCapabilityAttestation: Sendable {
    public typealias Attest = @Sendable (
        _ transportMode: DiscordVoiceTransportMode,
        _ daveProtocolVersion: Int
    ) async throws -> DiscordVoiceMediaCapabilities

    public let aes256GCMAvailable: Bool
    private let attestImpl: Attest

    public init(
        aes256GCMAvailable: Bool,
        attest: @escaping Attest
    ) {
        self.aes256GCMAvailable = aes256GCMAvailable
        self.attestImpl = attest
    }

    public func attest(
        transportMode: DiscordVoiceTransportMode,
        daveProtocolVersion: Int
    ) async throws -> DiscordVoiceMediaCapabilities {
        try await attestImpl(transportMode, daveProtocolVersion)
    }

    /// Portable AbbeyCore has signaling and packet models, but no native
    /// libdave/AEAD/Opus runtime. It must remain fail-closed by default.
    public static let portableUnavailable = Self(
        aes256GCMAvailable: false,
        attest: { _, _ in
            DiscordVoiceMediaCapabilities(dave: false, aead: false, opus: false)
        }
    )
}

public struct DiscordVoiceGatewaySessionConfiguration: Equatable, Sendable {
    public let maximumMessageBytes: Int
    public let heartbeatPollMilliseconds: UInt64
    public let maximumDAVEProtocolVersion: Int

    public init(
        maximumMessageBytes: Int = VoiceGatewayV8Decoder.maximumPayloadBytes,
        heartbeatPollMilliseconds: UInt64 = 25,
        maximumDAVEProtocolVersion: Int = 0
    ) {
        self.maximumMessageBytes = min(
            max(1, maximumMessageBytes),
            VoiceGatewayV8Decoder.maximumPayloadBytes
        )
        self.heartbeatPollMilliseconds = min(max(1, heartbeatPollMilliseconds), 1_000)
        self.maximumDAVEProtocolVersion = min(
            max(0, maximumDAVEProtocolVersion),
            Int(UInt16.max)
        )
    }
}

public actor DiscordVoiceGatewaySession: DiscordVoiceGatewaySessionClient,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public struct Snapshot: Equatable, Sendable, CustomStringConvertible {
        public let phase: DiscordVoiceGatewaySessionPhase
        public let generation: UInt64
        public let selectedMode: DiscordVoiceTransportMode?
        public let signalingEstablished: Bool
        public let mediaProductionReady: Bool
        public let heartbeatAwaitingAcknowledgement: Bool

        public var description: String {
            "DiscordVoiceGatewaySession.Snapshot(phase: \(phase.rawValue), generation: \(generation), selectedMode: \(selectedMode?.rawValue ?? "none"), signalingEstablished: \(signalingEstablished), mediaProductionReady: \(mediaProductionReady), heartbeatAwaitingAcknowledgement: \(heartbeatAwaitingAcknowledgement))"
        }
    }

    private nonisolated let safeDescription = "DiscordVoiceGatewaySession(endpoint: <redacted>, credentials: <redacted>)"
    private let transport: VoiceGatewayClientTransport
    private let clock: VoiceGatewayClientClock
    private let mediaPlane: any DiscordVoiceMediaPlane
    private let daveControlHandler: VoiceGatewayDAVEControlHandler
    private let configuration: DiscordVoiceGatewaySessionConfiguration

    private var phase: DiscordVoiceGatewaySessionPhase = .idle
    private var generation: UInt64 = 0
    private var machine: VoiceGatewayV8StateMachine?
    private var activeSession: VoiceGatewayClientSession?
    private var transportTask: Task<Void, Never>?
    private var daveHandlingTask: Task<[VoiceGatewayDAVEClientMessage], any Error>?
    private var daveMembershipTask: Task<Void, Never>?
    private var readySignal: DiscordVoiceGatewaySessionSignal<DiscordVoiceGatewayTransportReady>?
    private var descriptionSignal: DiscordVoiceGatewaySessionSignal<DiscordVoiceMediaCapabilities>?
    private var selectedMode: DiscordVoiceTransportMode?
    private var negotiatedDAVEProtocolVersion: Int?
    private var daveTransitionState: VoiceGatewayDAVETransitionStateMachine
    private var daveConnectionContext: VoiceGatewayDAVEConnectionContext?
    private var recognizedDAVEUserIDs: Set<UInt64> = []
    private var lastCapabilities = DiscordVoiceMediaCapabilities(dave: false, aead: false, opus: false)
    private var mediaLifecycleRevision: UInt64 = 0
    private var disconnectRequested = false

    public init(
        transport: VoiceGatewayClientTransport = .live(),
        clock: VoiceGatewayClientClock = .continuous,
        mediaAttestation: DiscordVoiceMediaCapabilityAttestation = .portableUnavailable,
        mediaPlane: (any DiscordVoiceMediaPlane)? = nil,
        daveControlHandler: VoiceGatewayDAVEControlHandler = .unavailable,
        configuration: DiscordVoiceGatewaySessionConfiguration = .init()
    ) {
        self.transport = transport
        self.clock = clock
        self.mediaPlane = mediaPlane ?? DiscordVoiceAttestedMediaPlane(attestation: mediaAttestation)
        self.daveControlHandler = daveControlHandler
        self.configuration = configuration
        self.daveTransitionState = VoiceGatewayDAVETransitionStateMachine(
            maximumProtocolVersion: UInt16(configuration.maximumDAVEProtocolVersion)
        )
    }

    public nonisolated var description: String { safeDescription }
    public nonisolated var debugDescription: String { safeDescription }
    public nonisolated var customMirror: Mirror {
        Mirror(
            self,
            children: ["endpoint": "<redacted>", "credentials": "<redacted>"],
            displayStyle: .class
        )
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            phase: phase,
            generation: generation,
            selectedMode: selectedMode,
            signalingEstablished: phase == .established,
            mediaProductionReady: lastCapabilities.isProductionReady,
            heartbeatAwaitingAcknowledgement: machine?.pendingHeartbeatTimestamp != nil
        )
    }

    public func connect(using pair: DiscordVoiceGatewayPair) async throws -> DiscordVoiceGatewayTransportReady {
        guard transportTask == nil,
              phase == .idle || phase == .disconnected || phase == .failed
        else { throw DiscordVoiceGatewaySessionError.alreadyRunning }

        let endpoint = try VoiceGatewayV8Endpoint(pair.endpoint)
        let identity = try VoiceGatewayV8Identify(
            serverID: pair.serverID,
            userID: pair.userID,
            sessionID: pair.sessionID,
            token: pair.token,
            maxDAVEProtocolVersion: daveControlHandler.isAvailable
                ? configuration.maximumDAVEProtocolVersion
                : 0
        )
        let pendingDAVEContext: VoiceGatewayDAVEConnectionContext?
        if daveControlHandler.isAvailable {
            pendingDAVEContext = try VoiceGatewayDAVEConnectionContext(
                groupID: requireDAVESnowflake(pair.channelID),
                selfUserID: requireDAVESnowflake(pair.userID)
            )
        } else {
            pendingDAVEContext = nil
        }
        generation &+= 1
        let connectionGeneration = generation
        disconnectRequested = false
        phase = .connecting
        mediaLifecycleRevision &+= 1
        await mediaPlane.reset()
        await daveControlHandler.reset()
        daveConnectionContext = pendingDAVEContext
        recognizedDAVEUserIDs = pendingDAVEContext.map { [$0.selfUserID] } ?? []
        try await replaceRecognizedDAVEUserIDs(
            recognizedDAVEUserIDs.sorted(),
            generation: connectionGeneration
        )
        guard generation == connectionGeneration,
              phase == .connecting,
              !disconnectRequested
        else {
            throw DiscordVoiceGatewaySessionError.disconnected
        }
        do {
            try Task.checkCancellation()
        } catch {
            if generation == connectionGeneration {
                clearEphemeralState(finalPhase: .disconnected)
            }
            throw error
        }

        let readySignal = DiscordVoiceGatewaySessionSignal<DiscordVoiceGatewayTransportReady>()
        let descriptionSignal = DiscordVoiceGatewaySessionSignal<DiscordVoiceMediaCapabilities>()
        self.readySignal = readySignal
        self.descriptionSignal = descriptionSignal
        machine = VoiceGatewayV8StateMachine(identity: identity)
        // Re-attach every connect() so a reused session's callback always
        // closes over the current generation rather than a stale one.
        await mediaPlane.attachSpeakingSignal { [weak self] in
            guard let self else { throw DiscordVoiceGatewaySessionError.disconnected }
            try await self.sendSpeakingSignal(generation: connectionGeneration)
        }
        selectedMode = nil
        negotiatedDAVEProtocolVersion = nil
        daveTransitionState.reset()
        lastCapabilities = DiscordVoiceMediaCapabilities(dave: false, aead: false, opus: false)

        let transport = self.transport
        let maximumMessageBytes = configuration.maximumMessageBytes
        let task = Task { [self] in
            do {
                let close = try await transport.run(
                    endpoint: endpoint,
                    maximumMessageBytes: maximumMessageBytes
                ) { session in
                    try await self.runSession(session, generation: connectionGeneration)
                }
                await self.transportDidFinish(
                    close: close,
                    error: nil,
                    generation: connectionGeneration
                )
            } catch {
                await self.transportDidFinish(
                    close: nil,
                    error: error,
                    generation: connectionGeneration
                )
            }
        }
        transportTask = task

        do {
            let ready = try await withTaskCancellationHandler {
                try await readySignal.value()
            } onCancel: {
                Task { await self.disconnect() }
            }
            guard generation == connectionGeneration, !disconnectRequested else {
                throw DiscordVoiceGatewaySessionError.staleConnection
            }
            return ready
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    public func selectTransport(_ endpoint: DiscordVoiceDiscoveredEndpoint) async throws {
        guard phase == .awaitingTransportSelection,
              let activeSession,
              var machine,
              let ready = machine.readyPayload
        else {
            if selectedMode != nil { throw DiscordVoiceGatewaySessionError.transportAlreadySelected }
            throw DiscordVoiceGatewaySessionError.transportNotReady
        }

        let mode = try DiscordVoiceTransportMode.negotiate(
            advertisedModes: ready.modes,
            aes256GCMAvailable: mediaPlane.aes256GCMAvailable
        )
        let outbound = try machine.selectProtocol(
            address: endpoint.address,
            port: endpoint.port,
            mode: mode.rawValue
        )
        // Commit before the asynchronous write: the server may deliver Session
        // Description as soon as it receives Select Protocol.
        self.machine = machine
        selectedMode = mode
        phase = .awaitingSessionDescription
        let connectionGeneration = generation
        do {
            try await send(outbound, through: activeSession)
        } catch {
            guard generation == connectionGeneration,
                  !disconnectRequested,
                  (phase == .awaitingSessionDescription || phase == .established)
            else {
                throw DiscordVoiceGatewaySessionError.staleConnection
            }
            phase = .failed
            await descriptionSignal?.resolve(.failure(safeFailure(from: error)))
            await resetMediaAndClose(
                activeSession,
                code: 1011,
                reason: "protocol selection failed",
                generation: connectionGeneration
            )
            transportTask?.cancel()
            throw error
        }
        guard generation == connectionGeneration,
              !disconnectRequested,
              (phase == .awaitingSessionDescription || phase == .established)
        else { throw DiscordVoiceGatewaySessionError.staleConnection }
    }

    public func negotiateDAVEAndMedia() async throws -> DiscordVoiceMediaCapabilities {
        guard phase == .awaitingSessionDescription || phase == .established,
              let descriptionSignal
        else { throw DiscordVoiceGatewaySessionError.sessionDescriptionUnavailable }

        let connectionGeneration = generation
        let capabilities: DiscordVoiceMediaCapabilities
        do {
            capabilities = try await withTaskCancellationHandler {
                try await descriptionSignal.value()
            } onCancel: {
                Task { await self.disconnect() }
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        guard generation == connectionGeneration,
              !disconnectRequested,
              phase == .established
        else { throw DiscordVoiceGatewaySessionError.staleConnection }
        // The install signal proves that the raw Session Description was
        // consumed. DAVE epoch transitions may subsequently change only the
        // secret-free readiness booleans.
        _ = capabilities
        return lastCapabilities
    }

    public func disconnect() async {
        if transportTask == nil {
            generation &+= 1
            disconnectRequested = true
            phase = .disconnecting
            mediaLifecycleRevision &+= 1
            let failure = DiscordVoiceGatewaySessionError.disconnected
            await readySignal?.resolve(.failure(failure))
            await descriptionSignal?.resolve(.failure(failure))
            await mediaPlane.reset()
            await cancelDAVEHandling()
            clearEphemeralState(finalPhase: .disconnected)
            return
        }

        generation &+= 1
        disconnectRequested = true
        phase = .disconnecting
        let failure = DiscordVoiceGatewaySessionError.disconnected
        await readySignal?.resolve(.failure(failure))
        await descriptionSignal?.resolve(.failure(failure))

        let task = transportTask
        daveHandlingTask?.cancel()
        task?.cancel()
        if let activeSession {
            await resetMediaAndClose(
                activeSession,
                code: 1000,
                reason: "operator disconnect",
                generation: generation
            )
        } else {
            await mediaPlane.reset()
        }
        await cancelDAVEHandling()
        if let task { await task.value }
        clearEphemeralState(finalPhase: .disconnected)
    }

    private func runSession(
        _ session: VoiceGatewayClientSession,
        generation connectionGeneration: UInt64
    ) async throws {
        guard generation == connectionGeneration, !disconnectRequested, var machine else {
            throw DiscordVoiceGatewaySessionError.staleConnection
        }
        try machine.opened()
        self.machine = machine
        activeSession = session
        defer {
            if generation == connectionGeneration {
                activeSession = nil
            }
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.receiveLoop(session, generation: connectionGeneration)
            }
            group.addTask {
                try await self.heartbeatLoop(session, generation: connectionGeneration)
            }

            _ = try await group.next()
            group.cancelAll()
            while await group.nextResult() != nil {}
        }
    }

    private func receiveLoop(
        _ session: VoiceGatewayClientSession,
        generation connectionGeneration: UInt64
    ) async throws {
        while !Task.isCancelled {
            guard let frame = try await session.receiveFrame() else {
                throw VoiceGatewayClientTransportError.connectionClosed
            }
            guard frame.byteCount <= configuration.maximumMessageBytes else {
                await resetMediaAndClose(
                    session,
                    code: 1009,
                    reason: "message too large",
                    generation: connectionGeneration
                )
                throw VoiceGatewayClientTransportError.messageTooLarge
            }
            switch frame {
            case .binary(let data):
                do {
                    let daveFrame = try VoiceGatewayDAVECodec.decodeServerBinary(data)
                    try await receiveDAVE(
                        daveFrame,
                        through: session,
                        generation: connectionGeneration
                    )
                } catch {
                    if Task.isCancelled || disconnectRequested {
                        throw CancellationError()
                    }
                    await resetMediaAndClose(
                        session,
                        code: 1002,
                        reason: "DAVE control failed",
                        generation: connectionGeneration
                    )
                    throw error
                }
                continue

            case .text(let text):
                let data = Data(text.utf8)
                if DiscordVoiceGatewayOpcodeProbe.daveOpcode(in: data) != nil {
                    do {
                        let daveFrame = try VoiceGatewayDAVECodec.decodeServerJSON(data)
                        try await receiveDAVE(
                            daveFrame,
                            through: session,
                            generation: connectionGeneration
                        )
                    } catch {
                        if Task.isCancelled || disconnectRequested {
                            throw CancellationError()
                        }
                        await resetMediaAndClose(
                            session,
                            code: 1002,
                            reason: "DAVE control failed",
                            generation: connectionGeneration
                        )
                        throw error
                    }
                    continue
                }
                try await receiveVoiceGatewayEvent(
                    data,
                    through: session,
                    generation: connectionGeneration
                )
            }
        }
        throw CancellationError()
    }

    private func receiveVoiceGatewayEvent(
        _ data: Data,
        through session: VoiceGatewayClientSession,
        generation connectionGeneration: UInt64
    ) async throws {
            let event = try VoiceGatewayV8Decoder.decode(data)
            let now = await clock.nowMilliseconds()
            // Fetch the state after the injected-clock suspension so a heartbeat
            // update cannot be overwritten by a stale value copy.
            guard generation == connectionGeneration, !disconnectRequested, var machine else {
                throw DiscordVoiceGatewaySessionError.staleConnection
            }
            let authentication = try machine.receive(event, nowMilliseconds: now)
            if case .sessionDescription(let description) = event.payload {
                guard let version = UInt16(exactly: description.daveProtocolVersion) else {
                    throw VoiceGatewayDAVEError.controlProtocolUnavailable
                }
                try daveTransitionState.initializeEffectiveProtocolVersion(version)
            }
            self.machine = machine
            if let authentication {
                try await send(authentication, through: session)
            }

            switch event.payload {
            case .ready(let ready):
                phase = .awaitingTransportSelection
                let publicReady = DiscordVoiceGatewayTransportReady(
                    address: ready.ip,
                    port: ready.port,
                    ssrc: ready.ssrc,
                    encryptionModes: ready.modes
                )
                await readySignal?.resolve(.success(publicReady))

            case .sessionDescription(let description):
                guard description.daveProtocolVersion <= configuration.maximumDAVEProtocolVersion,
                      description.daveProtocolVersion == 0 || daveControlHandler.isAvailable
                else {
                    await resetMediaAndClose(
                        session,
                        code: 1002,
                        reason: "DAVE protocol unavailable",
                        generation: connectionGeneration
                    )
                    throw VoiceGatewayDAVEError.controlProtocolUnavailable
                }
                if description.daveProtocolVersion > 0 {
                    do {
                        guard let protocolVersion = UInt16(exactly: description.daveProtocolVersion) else {
                            throw VoiceGatewayDAVEError.controlProtocolUnavailable
                        }
                        let handler = daveControlHandler
                        guard let daveConnectionContext else {
                            throw VoiceGatewayDAVEError.controlProtocolUnavailable
                        }
                        let bootstrapTask = Task {
                            try await handler.beginSession(
                                context: daveConnectionContext,
                                protocolVersion: protocolVersion
                            )
                        }
                        daveHandlingTask = bootstrapTask
                        defer { daveHandlingTask = nil }
                        let outbound = try await withTaskCancellationHandler {
                            try await bootstrapTask.value
                        } onCancel: {
                            bootstrapTask.cancel()
                        }
                        guard generation == connectionGeneration, !disconnectRequested else {
                            throw DiscordVoiceGatewaySessionError.staleConnection
                        }
                        try validateDAVEBootstrap(outbound)
                        try await sendDAVE(
                            outbound,
                            through: session,
                            generation: connectionGeneration
                        )
                    } catch {
                        if !Task.isCancelled && !disconnectRequested {
                            await resetMediaAndClose(
                                session,
                                code: 1002,
                                reason: "DAVE bootstrap failed",
                                generation: connectionGeneration
                            )
                        }
                        throw error
                    }
                }
                let daveProtocolVersion = daveTransitionState.effectiveProtocolVersion
                let installationRevision = mediaLifecycleRevision
                let attested: DiscordVoiceMediaCapabilities
                do {
                    guard let ready = machine.readyPayload,
                          let selectedMode,
                          description.mode == selectedMode.rawValue
                    else {
                        throw DiscordVoiceGatewaySessionError.sessionDescriptionUnavailable
                    }
                    let capability = try DiscordVoiceNegotiatedMediaCapability(
                        generation: connectionGeneration,
                        ssrc: ready.ssrc,
                        transportMode: selectedMode,
                        transportKey: description.secretKey,
                        daveProtocolVersion: daveProtocolVersion
                    )
                    attested = try await mediaPlane.install(capability)
                } catch {
                    if !Task.isCancelled && !disconnectRequested {
                        await resetMediaAndClose(
                            session,
                            code: 1002,
                            reason: "media bootstrap failed",
                            generation: connectionGeneration
                        )
                    }
                    throw error
                }
                guard generation == connectionGeneration,
                      !disconnectRequested,
                      phase == .awaitingSessionDescription,
                      mediaLifecycleRevision == installationRevision
                else {
                    await mediaPlane.reset()
                    throw DiscordVoiceGatewaySessionError.staleConnection
                }
                let capabilities = DiscordVoiceMediaCapabilities(
                    dave: attested.dave
                        && daveProtocolVersion > 0
                        && daveControlHandler.isAvailable,
                    aead: attested.aead,
                    opus: attested.opus
                )
                negotiatedDAVEProtocolVersion = description.daveProtocolVersion
                lastCapabilities = capabilities
                phase = .established
                await descriptionSignal?.resolve(.success(capabilities))

            case .clientsConnect(let payload):
                if daveControlHandler.isAvailable {
                    let userIDs = try payload.userIDs.map(requireDAVESnowflake)
                    var nextUserIDs = recognizedDAVEUserIDs
                    nextUserIDs.formUnion(userIDs)
                    try await replaceRecognizedDAVEUserIDs(
                        nextUserIDs.sorted(),
                        generation: connectionGeneration
                    )
                    recognizedDAVEUserIDs = nextUserIDs
                }
                guard generation == connectionGeneration, !disconnectRequested else {
                    throw DiscordVoiceGatewaySessionError.staleConnection
                }

            case .clientDisconnect(let payload):
                if daveControlHandler.isAvailable {
                    let userID = try requireDAVESnowflake(payload.userID)
                    var nextUserIDs = recognizedDAVEUserIDs
                    if userID != daveConnectionContext?.selfUserID {
                        nextUserIDs.remove(userID)
                    }
                    try await replaceRecognizedDAVEUserIDs(
                        nextUserIDs.sorted(),
                        generation: connectionGeneration
                    )
                    recognizedDAVEUserIDs = nextUserIDs
                }
                guard generation == connectionGeneration, !disconnectRequested else {
                    throw DiscordVoiceGatewaySessionError.staleConnection
                }

            default:
                break
            }
    }

    private func receiveDAVE(
        _ frame: VoiceGatewayDAVEInboundFrame,
        through session: VoiceGatewayClientSession,
        generation connectionGeneration: UInt64
    ) async throws {
        guard generation == connectionGeneration, !disconnectRequested else {
            throw DiscordVoiceGatewaySessionError.staleConnection
        }
        guard daveControlHandler.isAvailable else {
            throw VoiceGatewayDAVEError.controlHandlerUnavailable
        }
        let isPreDescriptionExternalSender: Bool
        if case .externalSenderPackage = frame.message {
            isPreDescriptionExternalSender = negotiatedDAVEProtocolVersion == nil
                && configuration.maximumDAVEProtocolVersion > 0
        } else {
            isPreDescriptionExternalSender = false
        }
        guard negotiatedDAVEProtocolVersion != nil || isPreDescriptionExternalSender else {
            throw VoiceGatewayDAVEError.controlProtocolUnavailable
        }

        var transitionState = daveTransitionState
        let previousEffectiveProtocolVersion = transitionState.effectiveProtocolVersion
        let event = try transitionState.receive(frame.message)
        let handler = daveControlHandler
        let handlerTask = Task {
            try await handler.handle(frame, event: event)
        }
        daveHandlingTask = handlerTask
        defer { daveHandlingTask = nil }
        let outbound = try await withTaskCancellationHandler {
            try await handlerTask.value
        } onCancel: {
            handlerTask.cancel()
        }

        guard generation == connectionGeneration, !disconnectRequested else {
            throw DiscordVoiceGatewaySessionError.staleConnection
        }
        try validateDAVEOutboundSet(
            outbound,
            event: event,
            inboundOpcode: frame.message.opcode
        )
        for message in outbound {
            try validateDAVEOutbound(message, event: event, state: &transitionState)
        }

        // A DAVE frame and its native-handler response are one state-machine
        // transaction. Nothing becomes effective until both have validated.
        daveTransitionState = transitionState
        // Discord may send External Sender before Session Description. Retain
        // that package without changing the nil sentinel which keeps every
        // other DAVE opcode fail-closed until Session Description is accepted.
        if !isPreDescriptionExternalSender {
            negotiatedDAVEProtocolVersion = Int(transitionState.effectiveProtocolVersion)
        }
        if previousEffectiveProtocolVersion != transitionState.effectiveProtocolVersion {
            let version = transitionState.effectiveProtocolVersion
            let lifecycleRevision = mediaLifecycleRevision
            let updated = try await mediaPlane.updateDAVEProtocolVersion(
                version,
                generation: connectionGeneration
            )
            guard generation == connectionGeneration,
                  !disconnectRequested,
                  phase == .established,
                  lifecycleRevision == mediaLifecycleRevision
            else {
                throw DiscordVoiceGatewaySessionError.staleConnection
            }
            lastCapabilities = DiscordVoiceMediaCapabilities(
                dave: updated.dave
                    && version > 0
                    && daveControlHandler.isAvailable,
                aead: updated.aead,
                opus: updated.opus
            )
            if previousEffectiveProtocolVersion > 0, version == 0 {
                // Current Discord calls require DAVE. Destroy the media runtime
                // above and fail the signaling session so a future packet pump
                // cannot continue with transport-only protection.
                throw VoiceGatewayDAVEError.controlProtocolUnavailable
            }
        }

        // Binary DAVE frames carry the same server sequence used by heartbeat
        // and resume acknowledgements. Commit it only after accepting the
        // control transaction, and fetch the current machine after the handler
        // suspension so heartbeat mutations are not overwritten.
        if let sequence = frame.sequence {
            guard generation == connectionGeneration, !disconnectRequested, var machine else {
                throw DiscordVoiceGatewaySessionError.staleConnection
            }
            try machine.commitServerSequence(Int(sequence))
            self.machine = machine
        }

        try await sendDAVE(outbound, through: session, generation: connectionGeneration)
    }

    private func replaceRecognizedDAVEUserIDs(
        _ userIDs: [UInt64],
        generation connectionGeneration: UInt64
    ) async throws {
        guard generation == connectionGeneration, !disconnectRequested else {
            throw DiscordVoiceGatewaySessionError.staleConnection
        }
        let handler = daveControlHandler
        let membershipTask = Task {
            await handler.replaceRecognizedUserIDs(userIDs)
        }
        daveMembershipTask = membershipTask
        defer { daveMembershipTask = nil }
        await withTaskCancellationHandler {
            await membershipTask.value
        } onCancel: {
            membershipTask.cancel()
        }
        guard generation == connectionGeneration, !disconnectRequested else {
            throw DiscordVoiceGatewaySessionError.staleConnection
        }
        try Task.checkCancellation()
    }

    /// Cancels and joins native DAVE processing before transport teardown.
    /// The first reset releases handlers waiting in non-cancellation-aware
    /// native callbacks. Membership replacement is joined and followed by a
    /// final reset so a stale native write cannot survive disconnect.
    private func cancelDAVEHandling() async {
        let handlerTask = daveHandlingTask
        let membershipTask = daveMembershipTask
        handlerTask?.cancel()
        membershipTask?.cancel()
        await daveControlHandler.reset()
        if let handlerTask {
            _ = await handlerTask.result
        }
        if let membershipTask {
            await membershipTask.value
            await daveControlHandler.reset()
        }
        daveHandlingTask = nil
        daveMembershipTask = nil
    }

    private func validateDAVEOutboundSet(
        _ messages: [VoiceGatewayDAVEClientMessage],
        event: VoiceGatewayDAVETransitionStateMachine.Event,
        inboundOpcode: VoiceGatewayDAVEOpcode
    ) throws {
        let opcodes = messages.map(\.opcode)
        let valid: Bool
        switch event {
        case .transitionPrepared:
            valid = opcodes == [.transitionReady]
        case .requiresMLSProcessing:
            // libdave may explicitly ignore a duplicate/out-of-window Commit.
            // An empty response preserves the awaiting-MLS state so Discord can
            // retry. Welcome has no ignored outcome and must fail closed when
            // its native handler produces no response.
            valid = (opcodes.isEmpty && inboundOpcode == .announceCommitTransition)
                || opcodes == [.transitionReady]
                || opcodes == [.invalidCommitWelcome, .keyPackage]
        case .epochAnnounced:
            valid = opcodes == [.keyPackage]
        case .externalSenderRetained:
            valid = opcodes.isEmpty
        case .mlsPayloadReceived(.proposals):
            valid = opcodes == [.commitWelcome]
        case .transitionExecuted:
            valid = opcodes.isEmpty
        case .mlsPayloadReceived, .transitionReady, .recoveryRequired:
            valid = false
        }
        guard valid else {
            throw VoiceGatewayDAVEError.invalidOutboundResponse(
                opcode: opcodes.first?.rawValue ?? 0
            )
        }
    }

    private func validateDAVEBootstrap(
        _ messages: [VoiceGatewayDAVEClientMessage]
    ) throws {
        guard messages.map(\.opcode) == [.keyPackage] else {
            throw VoiceGatewayDAVEError.invalidOutboundResponse(
                opcode: messages.first?.opcode.rawValue ?? 0
            )
        }
    }

    private func sendDAVE(
        _ messages: [VoiceGatewayDAVEClientMessage],
        through session: VoiceGatewayClientSession,
        generation connectionGeneration: UInt64
    ) async throws {
        for message in messages {
            guard generation == connectionGeneration, !disconnectRequested else {
                throw DiscordVoiceGatewaySessionError.staleConnection
            }
            let encoded = try VoiceGatewayDAVECodec.encodeClient(message)
            guard encoded.count <= configuration.maximumMessageBytes else {
                throw DiscordVoiceGatewaySessionError.outboundPayloadTooLarge
            }
            switch encoded.representation {
            case .json:
                guard let text = String(data: encoded.bytes, encoding: .utf8) else {
                    throw DiscordVoiceGatewaySessionError.outboundEncodingFailed
                }
                try await session.sendFrame(.text(text))
            case .binary:
                try await session.sendFrame(.binary(encoded.bytes))
            }
        }
    }

    private func validateDAVEOutbound(
        _ message: VoiceGatewayDAVEClientMessage,
        event: VoiceGatewayDAVETransitionStateMachine.Event,
        state: inout VoiceGatewayDAVETransitionStateMachine
    ) throws {
        switch message {
        case .transitionReady(let payload):
            switch event {
            case .transitionPrepared(let transitionID):
                guard payload.transitionID == transitionID else {
                    throw VoiceGatewayDAVEError.invalidOutboundResponse(
                        opcode: message.opcode.rawValue
                    )
                }
            case .requiresMLSProcessing(let transitionID):
                guard payload.transitionID == transitionID else {
                    throw VoiceGatewayDAVEError.invalidOutboundResponse(
                        opcode: message.opcode.rawValue
                    )
                }
                _ = try state.markMLSProcessed(transitionID: transitionID)
            default:
                throw VoiceGatewayDAVEError.invalidOutboundResponse(
                    opcode: message.opcode.rawValue
                )
            }
            guard try state.transitionReadyMessage(transitionID: payload.transitionID) == message
            else {
                throw VoiceGatewayDAVEError.invalidOutboundResponse(
                    opcode: message.opcode.rawValue
                )
            }

        case .keyPackage:
            let isPreparedEpoch: Bool
            switch event {
            case .epochAnnounced:
                isPreparedEpoch = true
            case .requiresMLSProcessing:
                // In the invalid Commit/Welcome recovery sequence, validation
                // of opcode 31 resets the group before this new key package.
                isPreparedEpoch = state.awaitingMLSProcessingTransitionID == nil
            default:
                isPreparedEpoch = false
            }
            guard isPreparedEpoch else {
                throw VoiceGatewayDAVEError.invalidOutboundResponse(
                    opcode: message.opcode.rawValue
                )
            }

        case .commitWelcome:
            guard event == .mlsPayloadReceived(.proposals) else {
                throw VoiceGatewayDAVEError.invalidOutboundResponse(
                    opcode: message.opcode.rawValue
                )
            }

        case .invalidCommitWelcome(let payload):
            guard case .requiresMLSProcessing(let transitionID) = event,
                  transitionID == payload.transitionID
            else {
                throw VoiceGatewayDAVEError.invalidOutboundResponse(
                    opcode: message.opcode.rawValue
                )
            }
            _ = try state.resetMLSGroupForRecovery(transitionID: transitionID)
        }
    }

    private func heartbeatLoop(
        _ session: VoiceGatewayClientSession,
        generation connectionGeneration: UInt64
    ) async throws {
        while !Task.isCancelled {
            guard generation == connectionGeneration, !disconnectRequested else {
                throw DiscordVoiceGatewaySessionError.staleConnection
            }
            let now = await clock.nowMilliseconds()
            // Fetch the state after the injected-clock suspension so inbound
            // events cannot be overwritten by a stale value copy.
            guard generation == connectionGeneration, !disconnectRequested, var machine else {
                throw DiscordVoiceGatewaySessionError.staleConnection
            }
            do {
                if let heartbeat = try machine.heartbeatIfDue(nowMilliseconds: now) {
                    self.machine = machine
                    try await send(heartbeat, through: session)
                } else {
                    self.machine = machine
                }
            } catch VoiceGatewayV8Error.missedHeartbeatAcknowledgement {
                self.machine = machine
                await resetMediaAndClose(
                    session,
                    code: 1001,
                    reason: "heartbeat ACK timeout",
                    generation: connectionGeneration
                )
                throw VoiceGatewayV8Error.missedHeartbeatAcknowledgement
            }

            let delay: UInt64
            if let due = machine.nextHeartbeatAt, due > now {
                delay = min(due - now, configuration.heartbeatPollMilliseconds)
            } else {
                delay = configuration.heartbeatPollMilliseconds
            }
            try await clock.sleep(milliseconds: delay)
        }
    }

    /// Invoked by the media plane immediately before its first protected
    /// packet of a generation. A stale generation, disconnect, or missing
    /// session fails closed so a superseded connection cannot emit Speaking
    /// on behalf of a newer (or torn-down) one.
    private func sendSpeakingSignal(generation connectionGeneration: UInt64) async throws {
        guard generation == connectionGeneration,
              !disconnectRequested,
              phase == .established,
              let activeSession,
              let machine
        else { throw DiscordVoiceGatewaySessionError.staleConnection }
        let outbound = try machine.speaking(flags: 1)
        try await send(outbound, through: activeSession)
    }

    private func send(
        _ outbound: VoiceGatewayV8Outbound,
        through session: VoiceGatewayClientSession
    ) async throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(outbound)
        } catch {
            throw DiscordVoiceGatewaySessionError.outboundEncodingFailed
        }
        guard data.count <= configuration.maximumMessageBytes else {
            throw DiscordVoiceGatewaySessionError.outboundPayloadTooLarge
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw DiscordVoiceGatewaySessionError.outboundEncodingFailed
        }
        try await session.send(text)
    }

    private func requireDAVESnowflake(_ value: String) throws -> UInt64 {
        guard let numeric = UInt64(value),
              numeric > 0,
              String(numeric) == value
        else {
            throw VoiceGatewayDAVEError.invalidIdentifier
        }
        return numeric
    }

    private func transportDidFinish(
        close: VoiceGatewayClientClose?,
        error: (any Error)?,
        generation connectionGeneration: UInt64
    ) async {
        guard generation == connectionGeneration else { return }
        activeSession = nil
        mediaLifecycleRevision &+= 1
        await mediaPlane.reset()

        if disconnectRequested || error is CancellationError {
            let failure = DiscordVoiceGatewaySessionError.disconnected
            await readySignal?.resolve(.failure(failure))
            await descriptionSignal?.resolve(.failure(failure))
            phase = .disconnected
            return
        }

        let failure: any Error
        if let close {
            if var machine {
                _ = machine.handleClose(code: close.code)
                self.machine = machine
            }
            failure = DiscordVoiceGatewaySessionError.connectionClosed(close.code)
        } else if let voiceError = error as? VoiceGatewayV8Error {
            failure = voiceError
        } else if let transportError = error as? VoiceGatewayClientTransportError {
            failure = transportError
        } else if let sessionError = error as? DiscordVoiceGatewaySessionError {
            failure = sessionError
        } else if let daveError = error as? VoiceGatewayDAVEError {
            failure = daveError
        } else {
            failure = DiscordVoiceGatewaySessionError.transportFailed
        }
        await readySignal?.resolve(.failure(failure))
        await descriptionSignal?.resolve(.failure(failure))
        // Drop credentials, transport key material, and completed signals as
        // soon as the socket is no longer usable. Callers already waiting on a
        // signal retain only their resolved result long enough to observe the
        // failure; a later phase cannot reuse stale session evidence.
        machine = nil
        readySignal = nil
        descriptionSignal = nil
        selectedMode = nil
        lastCapabilities = DiscordVoiceMediaCapabilities(dave: false, aead: false, opus: false)
        phase = .failed
        daveTransitionState.reset()
        negotiatedDAVEProtocolVersion = nil
        daveConnectionContext = nil
        recognizedDAVEUserIDs.removeAll(keepingCapacity: false)
        await daveControlHandler.reset()
        guard generation == connectionGeneration else { return }
        transportTask = nil
    }

    /// Every locally initiated Voice WebSocket close passes this boundary so
    /// transport key state is discarded before the close frame is emitted.
    /// An obsolete socket may still be closed, but it cannot reset a newer
    /// generation's media plane.
    private func resetMediaAndClose(
        _ session: VoiceGatewayClientSession,
        code: Int,
        reason: String,
        generation connectionGeneration: UInt64
    ) async {
        if generation == connectionGeneration {
            mediaLifecycleRevision &+= 1
            await mediaPlane.reset()
        }
        await session.close(code: code, reason: reason)
    }

    private func safeFailure(from error: any Error) -> any Error {
        if let voiceError = error as? VoiceGatewayV8Error { return voiceError }
        if let transportError = error as? VoiceGatewayClientTransportError { return transportError }
        if let sessionError = error as? DiscordVoiceGatewaySessionError { return sessionError }
        if error is CancellationError { return DiscordVoiceGatewaySessionError.disconnected }
        return DiscordVoiceGatewaySessionError.transportFailed
    }

    private func clearEphemeralState(finalPhase: DiscordVoiceGatewaySessionPhase) {
        machine = nil
        activeSession = nil
        transportTask = nil
        readySignal = nil
        descriptionSignal = nil
        selectedMode = nil
        negotiatedDAVEProtocolVersion = nil
        daveTransitionState.reset()
        daveConnectionContext = nil
        recognizedDAVEUserIDs.removeAll(keepingCapacity: false)
        daveHandlingTask = nil
        daveMembershipTask = nil
        lastCapabilities = DiscordVoiceMediaCapabilities(dave: false, aead: false, opus: false)
        disconnectRequested = false
        phase = finalPhase
    }
}

private struct DiscordVoiceGatewayOpcodeProbe: Decodable {
    let op: Int

    static func daveOpcode(in data: Data) -> VoiceGatewayDAVEOpcode? {
        guard let probe = try? JSONDecoder().decode(Self.self, from: data),
              let rawValue = UInt8(exactly: probe.op)
        else { return nil }
        return VoiceGatewayDAVEOpcode(rawValue: rawValue)
    }
}

private actor DiscordVoiceGatewaySessionSignal<Value: Sendable> {
    private typealias Waiter = CheckedContinuation<Result<Value, any Error>, Never>
    private var result: Result<Value, any Error>?
    private var waiters: [Waiter] = []

    func resolve(_ result: Result<Value, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume(returning: result)
        }
    }

    func value() async throws -> Value {
        if let result { return try result.get() }
        return try await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }.get()
    }
}
