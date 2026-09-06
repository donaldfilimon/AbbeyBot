import Foundation
import NIOCore
import NIOPosix

/// A long-lived Discord voice UDP socket used for both IP discovery and protected media.
///
/// Discord's discovery result describes the NAT mapping of this socket, so callers must not
/// replace the socket between discovery and RTP traffic. This actor owns that invariant and never
/// exposes or logs either endpoint, packet contents, or key material.
public actor DiscordVoiceUDPSession {
    public struct Configuration: Equatable, Sendable {
        public var serverAddress: String
        public var serverPort: Int
        public var discoveryTimeout: Duration
        public var maximumDatagramBytes: Int
        public var maximumBufferedDatagrams: Int

        public init(
            serverAddress: String,
            serverPort: Int,
            discoveryTimeout: Duration = .seconds(5),
            maximumDatagramBytes: Int = 4_096,
            maximumBufferedDatagrams: Int = 32
        ) {
            self.serverAddress = serverAddress
            self.serverPort = serverPort
            self.discoveryTimeout = discoveryTimeout
            self.maximumDatagramBytes = maximumDatagramBytes
            self.maximumBufferedDatagrams = maximumBufferedDatagrams
        }
    }

    public enum State: String, Equatable, Sendable {
        case idle
        case opening
        case open
        case discovering
        case ready
        case failed
        case closed
    }

    /// Deliberately redacted operational state: no local/remote address or packet data is exposed.
    public struct Snapshot: Equatable, Sendable, CustomStringConvertible {
        public let state: State
        public let queuedDatagrams: Int
        public let droppedDatagrams: UInt64

        public var description: String {
            "DiscordVoiceUDPSession.Snapshot(state: \(state.rawValue), queued: \(queuedDatagrams), dropped: \(droppedDatagrams))"
        }
    }

    /// Deliberately carries no addresses, packet bytes, or transport secrets.
    public enum SessionError: Error, Equatable, Sendable, CustomStringConvertible {
        case invalidConfiguration
        case notOpen
        case alreadyOpen
        case closed
        case operationInProgress
        case invalidDatagramSize
        case receiveInProgress
        case streamEnded
        case transportFailure

        public var description: String {
            switch self {
            case .invalidConfiguration: "Discord voice UDP session configuration was invalid"
            case .notOpen: "Discord voice UDP session is not open"
            case .alreadyOpen: "Discord voice UDP session is already open"
            case .closed: "Discord voice UDP session is closed"
            case .operationInProgress: "Discord voice UDP session has another operation in progress"
            case .invalidDatagramSize: "Discord voice UDP datagram size was invalid"
            case .receiveInProgress: "Discord voice UDP session already has a receiver"
            case .streamEnded: "Discord voice UDP receive stream ended"
            case .transportFailure: "Discord voice UDP transport failed"
            }
        }
    }

    private struct ReceiveWaiter {
        let id: UUID
        let continuation: CheckedContinuation<[UInt8], any Error>
    }

    private let configuration: Configuration
    private let didBindHook: (@Sendable () async -> Void)?
    private var state: State = .idle
    private var openAttemptID: UUID?
    private var remoteAddress: SocketAddress?
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var channel: NIOAsyncChannel<
        AddressedEnvelope<ByteBuffer>,
        AddressedEnvelope<ByteBuffer>
    >?
    private var receiveTask: Task<Void, Never>?
    private var bufferedDatagrams: [[UInt8]] = []
    private var receiveWaiter: ReceiveWaiter?
    private var droppedDatagrams: UInt64 = 0

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.didBindHook = nil
    }

    init(
        configuration: Configuration,
        didBindHook: @escaping @Sendable () async -> Void
    ) {
        self.configuration = configuration
        self.didBindHook = didBindHook
    }

    deinit {
        receiveTask?.cancel()
        if let channel {
            channel.channel.close(promise: nil)
        }
        if let eventLoopGroup {
            try? eventLoopGroup.syncShutdownGracefully()
        }
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            state: state,
            queuedDatagrams: bufferedDatagrams.count,
            droppedDatagrams: droppedDatagrams
        )
    }

    /// Opens an ephemeral local UDP socket. A session is intentionally single-use after close.
    public func open() async throws {
        switch state {
        case .idle:
            break
        case .closed:
            throw SessionError.closed
        default:
            throw SessionError.alreadyOpen
        }

        guard configuration.discoveryTimeout > .zero,
              configuration.maximumDatagramBytes >= DiscordVoiceUDPDiscoveryCodec.packetSize,
              configuration.maximumDatagramBytes < 65_507,
              configuration.maximumBufferedDatagrams > 0,
              (1...Int(UInt16.max)).contains(configuration.serverPort),
              let remote = try? SocketAddress(
                  ipAddress: configuration.serverAddress,
                  port: configuration.serverPort
              )
        else {
            throw SessionError.invalidConfiguration
        }

        let bindHost: String
        switch remote {
        case .v4:
            bindHost = "0.0.0.0"
        case .v6:
            bindHost = "::"
        case .unixDomainSocket:
            throw SessionError.invalidConfiguration
        }

        let attemptID = UUID()
        openAttemptID = attemptID
        state = .opening

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var openedChannel: NIOAsyncChannel<
            AddressedEnvelope<ByteBuffer>,
            AddressedEnvelope<ByteBuffer>
        >?
        do {
            // A UDP receive buffer capped at the application limit can silently truncate an
            // oversized datagram into an apparently valid one. Accept the protocol maximum at
            // the syscall boundary, then enforce the smaller application limit before buffering.
            let receiveCapacity = 65_507
            openedChannel = try await DatagramBootstrap(group: group)
                .channelOption(
                    ChannelOptions.recvAllocator,
                    value: AdaptiveRecvByteBufferAllocator(
                        minimum: 128,
                        initial: 2_048,
                        maximum: receiveCapacity
                    )
                )
                .bind(host: bindHost, port: 0) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel<
                            AddressedEnvelope<ByteBuffer>,
                            AddressedEnvelope<ByteBuffer>
                        >(
                            wrappingChannelSynchronously: channel,
                            configuration: .init(
                                backPressureStrategy: .init(lowWatermark: 1, highWatermark: 2)
                            )
                        )
                    }
                }

        } catch {
            try? await group.shutdownGracefully()
            guard state == .opening, openAttemptID == attemptID else {
                throw errorForCurrentState()
            }
            openAttemptID = nil
            state = .failed
            throw SessionError.transportFailure
        }

        await didBindHook?()
        guard state == .opening, openAttemptID == attemptID else {
            if let channel = openedChannel {
                try? await channel.executeThenClose { _, _ in }
            }
            openedChannel = nil
            try? await group.shutdownGracefully()
            throw errorForCurrentState()
        }
        guard let openedChannel else {
            state = .failed
            openAttemptID = nil
            try? await group.shutdownGracefully()
            throw SessionError.transportFailure
        }

        openAttemptID = nil
        remoteAddress = remote
        eventLoopGroup = group
        channel = openedChannel
        state = .open
        startReceiving(from: openedChannel, exactRemote: remote)
    }

    /// Performs Discord IP discovery without closing or replacing the media socket.
    public func discover(
        ssrc: UInt32,
        deadline: ContinuousClock.Instant? = nil
    ) async throws -> DiscordVoiceUDPDiscoveryResult {
        guard state == .open else {
            throw errorForCurrentState()
        }
        state = .discovering

        do {
            try await write(
                DiscordVoiceUDPDiscoveryCodec.encodeRequest(ssrc: ssrc),
                permitsDiscovery: true
            )
            let clock = ContinuousClock()
            let effectiveDeadline = deadline
                ?? clock.now.advanced(by: configuration.discoveryTimeout)
            guard effectiveDeadline > clock.now else {
                throw DiscordVoiceUDPDiscoveryError.timeout
            }

            let result = try await withThrowingTaskGroup(
                of: DiscordVoiceUDPDiscoveryResult.self
            ) { group in
                group.addTask { [weak self] in
                    guard let self else { throw SessionError.streamEnded }
                    let bytes = try await self.nextDatagram(permitsDiscovery: true)
                    return try DiscordVoiceUDPDiscoveryCodec.decodeResponse(
                        bytes,
                        expectedSSRC: ssrc
                    )
                }
                group.addTask {
                    try await Task.sleep(until: effectiveDeadline, clock: clock)
                    throw DiscordVoiceUDPDiscoveryError.timeout
                }

                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw SessionError.streamEnded
                }
                return result
            }
            guard state == .discovering else {
                throw errorForCurrentState()
            }
            state = .ready
            return result
        } catch {
            if state == .discovering {
                state = .open
            }
            throw mapError(error)
        }
    }

    /// Sends one already-encrypted RTP/RTCP datagram to the configured Discord voice server.
    public func sendProtectedPacket(_ bytes: [UInt8]) async throws {
        guard state == .ready else {
            throw errorForCurrentState()
        }
        try await write(bytes, permitsDiscovery: false)
    }

    /// Receives one datagram from the configured Discord voice server.
    public func receiveProtectedPacket() async throws -> [UInt8] {
        guard state == .ready else {
            throw errorForCurrentState()
        }
        return try await nextDatagram(permitsDiscovery: false)
    }

    /// Closes the channel and event-loop group. Repeated calls are harmless.
    public func close() async {
        guard state != .closed else { return }
        state = .closed
        openAttemptID = nil
        bufferedDatagrams.removeAll(keepingCapacity: false)
        resumeReceiveWaiter(throwing: SessionError.closed)

        let task = receiveTask
        receiveTask = nil
        task?.cancel()

        let openedChannel = channel
        channel = nil
        remoteAddress = nil
        if let openedChannel {
            try? await openedChannel.channel.close()
        }
        _ = await task?.result

        let group = eventLoopGroup
        eventLoopGroup = nil
        if let group {
            try? await group.shutdownGracefully()
        }
    }

    private func startReceiving(
        from openedChannel: NIOAsyncChannel<
            AddressedEnvelope<ByteBuffer>,
            AddressedEnvelope<ByteBuffer>
        >,
        exactRemote: SocketAddress
    ) {
        let maximumDatagramBytes = configuration.maximumDatagramBytes
        receiveTask = Task { [weak self, openedChannel] in
            do {
                try await openedChannel.executeThenClose { inbound, _ in
                    for try await envelope in inbound {
                        guard envelope.remoteAddress == exactRemote else { continue }
                        let readableBytes = envelope.data.readableBytes
                        guard readableBytes <= maximumDatagramBytes else {
                            await self?.recordDroppedDatagram()
                            continue
                        }
                        guard let bytes = envelope.data.getBytes(
                            at: envelope.data.readerIndex,
                            length: readableBytes
                        ) else {
                            await self?.recordDroppedDatagram()
                            continue
                        }
                        await self?.acceptDatagram(bytes)
                    }
                }
                await self?.receiveStreamEnded()
            } catch is CancellationError {
                await self?.receiveStreamCancelled()
            } catch {
                await self?.receiveStreamEnded()
            }
        }
    }

    private func acceptDatagram(_ bytes: [UInt8]) {
        guard state == .open || state == .discovering || state == .ready else { return }
        if let waiter = receiveWaiter {
            receiveWaiter = nil
            waiter.continuation.resume(returning: bytes)
            return
        }
        guard bufferedDatagrams.count < configuration.maximumBufferedDatagrams else {
            droppedDatagrams &+= 1
            return
        }
        bufferedDatagrams.append(bytes)
    }

    private func recordDroppedDatagram() {
        guard state != .closed else { return }
        droppedDatagrams &+= 1
    }

    private func receiveStreamCancelled() {
        guard state != .closed else { return }
        receiveStreamEnded()
    }

    private func receiveStreamEnded() {
        guard state != .closed else { return }
        state = .failed
        resumeReceiveWaiter(throwing: SessionError.streamEnded)
    }

    private func write(_ bytes: [UInt8], permitsDiscovery: Bool) async throws {
        try Task.checkCancellation()
        guard !bytes.isEmpty,
              bytes.count <= configuration.maximumDatagramBytes
        else {
            throw SessionError.invalidDatagramSize
        }
        guard let channel, let remoteAddress else {
            throw errorForCurrentState()
        }
        if permitsDiscovery {
            guard state == .discovering else { throw errorForCurrentState() }
        } else {
            guard state == .ready else { throw errorForCurrentState() }
        }

        var buffer = channel.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        do {
            // NIO's future-to-async bridge does not cancel pending writes. Close
            // this exact socket to fail queued writes instead of letting capture
            // stop wait forever for its cancelled send. A session is single-use:
            // never rebind after cancellation and invalidate its NAT mapping.
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await channel.channel.writeAndFlush(
                    AddressedEnvelope(remoteAddress: remoteAddress, data: buffer)
                )
                try Task.checkCancellation()
            } onCancel: {
                channel.channel.close(promise: nil)
            }
        } catch {
            if state != .closed {
                state = .failed
                bufferedDatagrams.removeAll(keepingCapacity: false)
                resumeReceiveWaiter(throwing: SessionError.transportFailure)
            }
            if Task.isCancelled {
                // Do not return to the media-plane drain until this socket and
                // its pipeline have finished closing. Already-sent UDP cannot
                // be recalled, but no queued packet can be emitted afterwards.
                channel.channel.close(promise: nil)
                try? await channel.channel.closeFuture.get()
                throw CancellationError()
            }
            throw SessionError.transportFailure
        }
    }

    private func nextDatagram(permitsDiscovery: Bool) async throws -> [UInt8] {
        try Task.checkCancellation()
        if permitsDiscovery {
            guard state == .discovering else { throw errorForCurrentState() }
        } else {
            guard state == .ready else { throw errorForCurrentState() }
        }
        if !bufferedDatagrams.isEmpty {
            return bufferedDatagrams.removeFirst()
        }
        guard receiveWaiter == nil else {
            throw SessionError.receiveInProgress
        }

        let waiterID = UUID()
        let bytes = try await waitForDatagram(waiterID: waiterID)
        try Task.checkCancellation()
        return bytes
    }

    /// Keeping the cancellation handler outside the actor-isolated continuation setup avoids a
    /// Swift 6.4 release-mode compiler failure while preserving the same cancellation race: the
    /// actor either observes cancellation before installing the waiter or removes that exact waiter.
    private func waitForDatagram(waiterID: UUID) async throws -> [UInt8] {
        try await withTaskCancellationHandler(
            operation: {
                try await self.installReceiveWaiter(id: waiterID)
            },
            onCancel: {
                Task { await self.cancelReceiveWaiter(id: waiterID) }
            }
        )
    }

    private func installReceiveWaiter(id: UUID) async throws -> [UInt8] {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<[UInt8], any Error>) in
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                receiveWaiter = ReceiveWaiter(id: id, continuation: continuation)
            }
        }
    }

    private func cancelReceiveWaiter(id: UUID) {
        guard receiveWaiter?.id == id else { return }
        let waiter = receiveWaiter
        receiveWaiter = nil
        waiter?.continuation.resume(throwing: CancellationError())
    }

    private func resumeReceiveWaiter(throwing error: any Error) {
        let waiter = receiveWaiter
        receiveWaiter = nil
        waiter?.continuation.resume(throwing: error)
    }

    private func errorForCurrentState() -> SessionError {
        switch state {
        case .idle:
            .notOpen
        case .closed:
            .closed
        case .opening, .discovering:
            .operationInProgress
        case .failed:
            .transportFailure
        case .open, .ready:
            .notOpen
        }
    }

    private func mapError(_ error: any Error) -> any Error {
        if error is CancellationError { return CancellationError() }
        if error is DiscordVoiceUDPDiscoveryError { return error }
        if error is SessionError { return error }
        return SessionError.transportFailure
    }

    func hasPendingReceiveWaiterForTesting() -> Bool {
        receiveWaiter != nil
    }

    func installOutboundHandlerForTesting(_ handler: any ChannelHandler & Sendable) async throws {
        guard let channel else { throw errorForCurrentState() }
        try await channel.channel.pipeline.addHandler(handler).get()
    }
}
