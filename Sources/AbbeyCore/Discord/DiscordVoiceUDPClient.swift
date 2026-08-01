import Foundation
import NIOCore
import NIOPosix

public struct DiscordVoiceUDPDiscoveryClock: Sendable {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private let sleepImpl: Sleep

    public init(sleep: @escaping Sleep) {
        self.sleepImpl = sleep
    }

    public func sleep(for duration: Duration) async throws {
        try await sleepImpl(duration)
    }

    public static let continuous = Self { duration in
        try await Task.sleep(for: duration)
    }
}

/// A one-shot, receive-capable UDP client for Discord voice IP discovery.
///
/// Each call owns its event loop and channel. Both are closed before the call returns or throws.
/// The client never logs packet contents or either endpoint address.
public struct DiscordVoiceUDPDiscoveryClient: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var timeout: Duration
        public var maximumDatagrams: Int
        public var maximumDatagramBytes: Int

        public init(
            timeout: Duration = .seconds(5),
            maximumDatagrams: Int = 8,
            maximumDatagramBytes: Int = 512
        ) {
            self.timeout = timeout
            self.maximumDatagrams = maximumDatagrams
            self.maximumDatagramBytes = maximumDatagramBytes
        }
    }

    private let configuration: Configuration
    private let clock: DiscordVoiceUDPDiscoveryClock

    public init(
        configuration: Configuration = .init(),
        clock: DiscordVoiceUDPDiscoveryClock = .continuous
    ) {
        self.configuration = configuration
        self.clock = clock
    }

    public func discover(
        serverAddress: String,
        serverPort: Int,
        ssrc: UInt32
    ) async throws -> DiscordVoiceUDPDiscoveryResult {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let result = try await discover(
                serverAddress: serverAddress,
                serverPort: serverPort,
                ssrc: ssrc,
                eventLoopGroup: group
            )
            try await group.shutdownGracefully()
            return result
        } catch {
            try? await group.shutdownGracefully()
            throw mapTransportError(error)
        }
    }

    /// Internal event-loop injection keeps real-socket teardown testable without widening the live API.
    func discover(
        serverAddress: String,
        serverPort: Int,
        ssrc: UInt32,
        eventLoopGroup: any EventLoopGroup
    ) async throws -> DiscordVoiceUDPDiscoveryResult {
        guard configuration.timeout > .zero,
              configuration.maximumDatagrams > 0,
              configuration.maximumDatagramBytes >= DiscordVoiceUDPDiscoveryCodec.packetSize
        else {
            throw DiscordVoiceUDPDiscoveryError.invalidConfiguration
        }
        guard (1...Int(UInt16.max)).contains(serverPort),
              let remoteAddress = try? SocketAddress(ipAddress: serverAddress, port: serverPort)
        else {
            throw DiscordVoiceUDPDiscoveryError.invalidConfiguration
        }

        let bindHost: String
        switch remoteAddress {
        case .v4: bindHost = "0.0.0.0"
        case .v6: bindHost = "::"
        case .unixDomainSocket:
            throw DiscordVoiceUDPDiscoveryError.invalidConfiguration
        }

        do {
            let channel = try await DatagramBootstrap(group: eventLoopGroup)
                .channelOption(
                    ChannelOptions.recvAllocator,
                    value: AdaptiveRecvByteBufferAllocator(
                        minimum: DiscordVoiceUDPDiscoveryCodec.packetSize,
                        initial: min(128, configuration.maximumDatagramBytes),
                        maximum: configuration.maximumDatagramBytes
                    )
                )
                .bind(host: bindHost, port: 0) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel<AddressedEnvelope<ByteBuffer>, AddressedEnvelope<ByteBuffer>>(
                            wrappingChannelSynchronously: channel,
                            configuration: .init(
                                backPressureStrategy: .init(lowWatermark: 1, highWatermark: 2)
                            )
                        )
                    }
                }

            return try await channel.executeThenClose { inbound, outbound in
                var request = channel.channel.allocator.buffer(
                    capacity: DiscordVoiceUDPDiscoveryCodec.packetSize
                )
                request.writeBytes(DiscordVoiceUDPDiscoveryCodec.encodeRequest(ssrc: ssrc))
                try await outbound.write(
                    AddressedEnvelope(remoteAddress: remoteAddress, data: request)
                )

                return try await withThrowingTaskGroup(
                    of: DiscordVoiceUDPDiscoveryResult.self
                ) { group in
                    group.addTask {
                        var received = 0
                        for try await envelope in inbound {
                            received += 1
                            guard received <= configuration.maximumDatagrams else {
                                throw DiscordVoiceUDPDiscoveryError.datagramLimitExceeded
                            }
                            guard envelope.remoteAddress == remoteAddress else { continue }
                            let bytes = envelope.data.getBytes(
                                at: envelope.data.readerIndex,
                                length: envelope.data.readableBytes
                            ) ?? []
                            return try DiscordVoiceUDPDiscoveryCodec.decodeResponse(
                                bytes,
                                expectedSSRC: ssrc
                            )
                        }
                        throw DiscordVoiceUDPDiscoveryError.responseStreamEnded
                    }
                    group.addTask {
                        try await clock.sleep(for: configuration.timeout)
                        throw DiscordVoiceUDPDiscoveryError.timeout
                    }

                    defer { group.cancelAll() }
                    guard let result = try await group.next() else {
                        throw DiscordVoiceUDPDiscoveryError.responseStreamEnded
                    }
                    return result
                }
            }
        } catch {
            throw mapTransportError(error)
        }
    }

    private func mapTransportError(_ error: any Error) -> any Error {
        if error is CancellationError { return CancellationError() }
        if let discoveryError = error as? DiscordVoiceUDPDiscoveryError {
            return discoveryError
        }
        return DiscordVoiceUDPDiscoveryError.transportFailure
    }
}
