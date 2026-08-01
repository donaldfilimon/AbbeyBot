import AbbeyCore

/// Installs the audited native DAVE control plane in a Voice Gateway session.
///
/// This factory intentionally reports media unavailable until the persistent UDP
/// socket, RTP, AEAD, Opus, and capture/playback pumps are composed. Native MLS
/// signaling alone is not evidence that Discord audio can be transmitted.
public struct DiscordVoiceNativeControlSessionFactory: DiscordVoiceSessionFactory, Sendable {
    private let daveAdapter: NativeDAVEControlAdapter

    public let mediaAdapterAvailability: DiscordVoiceMediaAdapterAvailability = .unavailable

    public init(daveAdapter: NativeDAVEControlAdapter = NativeDAVEControlAdapter()) {
        self.daveAdapter = daveAdapter
    }

    public func makeGatewayClient() -> any DiscordVoiceGatewaySessionClient {
        DiscordVoiceGatewaySession(
            mediaAttestation: .portableUnavailable,
            daveControlHandler: daveAdapter.controlHandler,
            configuration: DiscordVoiceGatewaySessionConfiguration(
                maximumDAVEProtocolVersion: Int(
                    NativeMediaVersions.maximumDAVEProtocolVersion
                )
            )
        )
    }

    public func makeUDPDiscoverySession() -> any DiscordVoiceUDPDiscoverySession {
        DiscordVoiceUDPSessionAdapter()
    }
}
