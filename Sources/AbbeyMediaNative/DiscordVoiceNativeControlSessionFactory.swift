import AbbeyCore

/// Installs the audited native DAVE control plane in a Voice Gateway session.
///
/// This factory intentionally reports media unavailable until the persistent UDP
/// socket, RTP, AEAD, Opus, and capture/playback pumps are composed. Native MLS
/// signaling alone is not evidence that Discord audio can be transmitted.
public struct DiscordVoiceNativeControlSessionFactory: DiscordVoiceSessionFactory, Sendable {
    private let makeDAVEAdapter: @Sendable () -> NativeDAVEControlAdapter
    /// Optional platform microphone source. When present,
    /// `makeSessionComponents()` composes a `DiscordVoiceCaptureLoop` bound to
    /// the same session-owned media plane, so the controller can pump
    /// capture → 20 ms PCM → the protected `sendAudioFrame` path while the
    /// operator's microphone is enabled. Absent, the components carry no
    /// capture loop and the microphone fails closed to disabled.
    private let captureSource: (any DiscordVoiceCaptureSource)?

    public let mediaAdapterAvailability: DiscordVoiceMediaAdapterAvailability = .unavailable

    public init(
        daveAdapter: NativeDAVEControlAdapter? = nil,
        captureSource: (any DiscordVoiceCaptureSource)? = nil
    ) {
        if let daveAdapter {
            self.makeDAVEAdapter = { daveAdapter }
        } else {
            self.makeDAVEAdapter = { NativeDAVEControlAdapter() }
        }
        self.captureSource = captureSource
    }

    public func makeGatewayClient() -> any DiscordVoiceGatewaySessionClient {
        let daveAdapter = makeDAVEAdapter()
        let udp = DiscordVoiceUDPSessionAdapter()
        let mediaPlane = DiscordVoiceNativeMediaPlane(
            daveAdapter: daveAdapter,
            datagramTransport: udp
        )
        return makeGatewayClient(
            daveAdapter: daveAdapter,
            mediaPlane: mediaPlane
        )
    }

    public func makeUDPDiscoverySession() -> any DiscordVoiceUDPDiscoverySession {
        DiscordVoiceUDPSessionAdapter()
    }

    public func makeSessionComponents() -> DiscordVoiceSessionComponents {
        let daveAdapter = makeDAVEAdapter()
        let udp = DiscordVoiceUDPSessionAdapter()
        let mediaPlane = DiscordVoiceNativeMediaPlane(
            daveAdapter: daveAdapter,
            datagramTransport: udp
        )
        // Phase 6a: the capture loop is bound to this session's own media
        // plane, whose `sendAudioFrame` fails closed without an installed
        // generation and attested DAVE session. Composing it here does not
        // change `mediaAdapterAvailability`: receive/playback and live
        // evidence remain missing, so audio is still not claimed as shipped.
        let captureLoop: (any DiscordVoiceCaptureLoopControlling)? = captureSource.map {
            DiscordVoiceCaptureLoop(source: $0, sender: mediaPlane)
        }
        return DiscordVoiceSessionComponents(
            gateway: makeGatewayClient(
                daveAdapter: daveAdapter,
                mediaPlane: mediaPlane
            ),
            udp: udp,
            captureLoop: captureLoop
        )
    }

    /// Claim-honesty gate: a nonzero DAVE advertisement offers Discord an E2EE
    /// capability this client must be able to honor with real frame
    /// encryption. MLS control-plane availability alone cannot protect Opus
    /// frames, so the advertised version stays 0 until the media adapters are
    /// fully wired.
    static func advertisedDAVEProtocolVersion(
        for availability: DiscordVoiceMediaAdapterAvailability
    ) -> Int {
        availability == .fullyWired
            ? Int(NativeMediaVersions.maximumDAVEProtocolVersion)
            : 0
    }

    private func makeGatewayClient(
        daveAdapter: NativeDAVEControlAdapter,
        mediaPlane: DiscordVoiceNativeMediaPlane
    ) -> DiscordVoiceGatewaySession {
        DiscordVoiceGatewaySession(
            mediaAttestation: .portableUnavailable,
            mediaPlane: mediaPlane,
            daveControlHandler: daveAdapter.controlHandler,
            configuration: DiscordVoiceGatewaySessionConfiguration(
                maximumDAVEProtocolVersion: Self.advertisedDAVEProtocolVersion(
                    for: mediaAdapterAvailability
                )
            )
        )
    }
}
