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
    /// Playback boundary for received audio. Injected because the concrete sink
    /// lives in AbbeyBotApp, which this target cannot depend on.
    private let playbackSink: (any DiscordVoicePlaybackSink)?

    /// `.locallyComposed` once BOTH directions are actually composed — capture
    /// in, playback out — because that is when real audio can flow on this
    /// machine. It deliberately stops short of `.fullyWired`: that case
    /// additionally advertises a nonzero DAVE version to Discord, and nothing
    /// here has been proven against a live call.
    public var mediaAdapterAvailability: DiscordVoiceMediaAdapterAvailability {
        (captureSource != nil && playbackSink != nil) ? .locallyComposed : .unavailable
    }

    public init(
        daveAdapter: NativeDAVEControlAdapter? = nil,
        captureSource: (any DiscordVoiceCaptureSource)? = nil,
        playbackSink: (any DiscordVoicePlaybackSink)? = nil
    ) {
        if let daveAdapter {
            self.makeDAVEAdapter = { daveAdapter }
        } else {
            self.makeDAVEAdapter = { NativeDAVEControlAdapter() }
        }
        self.captureSource = captureSource
        self.playbackSink = playbackSink
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
        // The capture loop is bound to this session's own media plane, whose
        // `sendAudioFrame` fails closed without an installed generation and an
        // attested DAVE session.
        let captureLoop: (any DiscordVoiceCaptureLoopControlling)? = captureSource.map {
            DiscordVoiceCaptureLoop(source: $0, sender: mediaPlane)
        }

        // Bound to a local rather than built inline, because the sender
        // resolver below has to close over the concrete session. Going through
        // `any DiscordVoiceGatewaySessionClient` would risk dispatching to the
        // protocol extension's nil-returning default, and receive would then
        // never learn a sender — silently, with no error.
        let gateway = makeGatewayClient(daveAdapter: daveAdapter, mediaPlane: mediaPlane)

        // Receive: UDP in -> AEAD open -> DAVE unprotect -> Opus decode ->
        // jitter/PLC/mix -> playback. `udp` is both the discovery session and
        // the media datagram transport, so it is the same socket the send path
        // uses. DAVE needs the sender's identity for its per-participant
        // ratchet; only the gateway knows it, learned from inbound Speaking.
        //
        // A failure to construct the loop must not take the whole session down
        // — signaling and capture are still perfectly usable without playback —
        // so this degrades to "no receive" rather than throwing.
        var receiveLoop: (any DiscordVoiceReceiveLoopControlling)?
        if let playbackSink {
            let decoder = DiscordVoiceNativeAudioFrameDecoder(
                plane: mediaPlane,
                resolveSender: { [gateway] ssrc in await gateway.senderID(forSSRC: ssrc) }
            )
            receiveLoop = try? DiscordVoiceReceiveLoop(
                transport: udp,
                decoder: decoder,
                sink: playbackSink
            )
        }

        return DiscordVoiceSessionComponents(
            gateway: gateway,
            udp: udp,
            captureLoop: captureLoop,
            receiveLoop: receiveLoop
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
