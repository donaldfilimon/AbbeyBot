import AbbeyCore

/// Installs the audited native DAVE control plane in a Voice Gateway session.
///
/// This factory intentionally reports media unavailable until the persistent UDP
/// socket, RTP, AEAD, Opus, and capture/playback pumps are composed. Native MLS
/// signaling alone is not evidence that Discord audio can be transmitted.
public struct DiscordVoiceNativeControlSessionFactory: DiscordVoiceSessionFactory, Sendable {
    private let makeDAVEAdapter: @Sendable () -> NativeDAVEControlAdapter

    public let mediaAdapterAvailability: DiscordVoiceMediaAdapterAvailability = .unavailable

    public init(daveAdapter: NativeDAVEControlAdapter? = nil) {
        if let daveAdapter {
            self.makeDAVEAdapter = { daveAdapter }
        } else {
            self.makeDAVEAdapter = { NativeDAVEControlAdapter() }
        }
    }

    public func makeGatewayClient() -> any DiscordVoiceGatewaySessionClient {
        makeGatewayClient(daveAdapter: makeDAVEAdapter())
    }

    public func makeUDPDiscoverySession() -> any DiscordVoiceUDPDiscoverySession {
        DiscordVoiceUDPSessionAdapter()
    }

    public func makeSessionComponents() -> DiscordVoiceSessionComponents {
        let daveAdapter = makeDAVEAdapter()
        let udp = DiscordVoiceUDPSessionAdapter()
        return DiscordVoiceSessionComponents(
            gateway: makeGatewayClient(daveAdapter: daveAdapter),
            udp: udp
        )
    }

    private func makeGatewayClient(
        daveAdapter: NativeDAVEControlAdapter
    ) -> DiscordVoiceGatewaySession {
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
}
