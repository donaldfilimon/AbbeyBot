import Foundation
import Testing
@testable import AbbeyCore

@Suite("Production Discord Voice Gateway session")
struct DiscordVoiceGatewaySessionTests {
    @Test("external handshake phases share one live socket and portable media stays unavailable")
    func externallyDrivenHandshake() async throws {
        let harness = DiscordVoiceGatewaySessionHarness()
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: quiescentClock()
        )
        let connection = Task { try await gateway.connect(using: pair()) }

        try await eventually { await harness.attemptCount() == 1 }
        #expect(await harness.sentOpcodes().isEmpty)

        await harness.send(#"{"op":8,"d":{"heartbeat_interval":1000},"seq":1}"#)
        try await eventually { await harness.sentOpcodes() == [0] }

        await harness.send(readyJSON(modes: [DiscordVoiceTransportMode.aeadXChaCha20Poly1305RTPSIZE.rawValue]))
        let ready = try await connection.value
        #expect(ready.address == "203.0.113.8")
        #expect(ready.port == 50_000)
        #expect(ready.ssrc == 44)

        try await gateway.selectTransport(
            DiscordVoiceDiscoveredEndpoint(address: "198.51.100.20", port: 62_000)
        )
        try await eventually { await harness.sentOpcodes() == [0, 1] }
        #expect(
            await harness.sentString(opcode: 1, nestedKey: "mode") ==
                DiscordVoiceTransportMode.aeadXChaCha20Poly1305RTPSIZE.rawValue
        )

        let negotiation = Task { try await gateway.negotiateDAVEAndMedia() }
        try await Task.sleep(for: .milliseconds(10))
        #expect(!negotiation.isCancelled)
        await harness.send(sessionDescriptionJSON(mode: DiscordVoiceTransportMode.aeadXChaCha20Poly1305RTPSIZE.rawValue))
        let capabilities = try await negotiation.value
        #expect(capabilities == DiscordVoiceMediaCapabilities(dave: false, aead: false, opus: false))
        #expect(!capabilities.isProductionReady)
        #expect(await gateway.snapshot().phase == .established)

        await gateway.disconnect()
        #expect(await harness.closeCodes() == [1000])
        #expect(await harness.operationFinished())
        #expect(await gateway.snapshot().phase == .disconnected)
    }

    @Test("AES is selected only when the injected native attestation reports it available")
    func aesNegotiationUsesLocalAvailability() async throws {
        let harness = DiscordVoiceGatewaySessionHarness()
        let attestation = DiscordVoiceMediaCapabilityAttestation(
            aes256GCMAvailable: true,
            attest: { _, _ in
                DiscordVoiceMediaCapabilities(dave: false, aead: false, opus: false)
            }
        )
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: quiescentClock(),
            mediaAttestation: attestation
        )
        let connection = Task { try await gateway.connect(using: pair()) }
        try await eventually { await harness.attemptCount() == 1 }
        await harness.send(#"{"op":8,"d":{"heartbeat_interval":1000}}"#)
        await harness.send(readyJSON(modes: [
            DiscordVoiceTransportMode.aeadXChaCha20Poly1305RTPSIZE.rawValue,
            DiscordVoiceTransportMode.aeadAES256GCMRTPSIZE.rawValue,
        ]))
        _ = try await connection.value

        try await gateway.selectTransport(
            DiscordVoiceDiscoveredEndpoint(address: "198.51.100.21", port: 62_001)
        )
        #expect(
            await harness.sentString(opcode: 1, nestedKey: "mode") ==
                DiscordVoiceTransportMode.aeadAES256GCMRTPSIZE.rawValue
        )
        await gateway.disconnect()
    }

    @Test("adapter availability cannot claim DAVE on a protocol-version-zero session")
    func attestationCannotOverrideNegotiatedProtocol() async throws {
        let harness = DiscordVoiceGatewaySessionHarness()
        let attestation = DiscordVoiceMediaCapabilityAttestation(
            aes256GCMAvailable: false,
            attest: { _, _ in
                DiscordVoiceMediaCapabilities(dave: true, aead: true, opus: true)
            }
        )
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: quiescentClock(),
            mediaAttestation: attestation
        )
        let connection = Task { try await gateway.connect(using: pair()) }
        try await eventually { await harness.attemptCount() == 1 }
        await harness.send(#"{"op":8,"d":{"heartbeat_interval":1000}}"#)
        await harness.send(readyJSON(modes: [DiscordVoiceTransportMode.aeadXChaCha20Poly1305RTPSIZE.rawValue]))
        _ = try await connection.value
        try await gateway.selectTransport(
            DiscordVoiceDiscoveredEndpoint(address: "198.51.100.22", port: 62_002)
        )
        await harness.send(sessionDescriptionJSON(mode: DiscordVoiceTransportMode.aeadXChaCha20Poly1305RTPSIZE.rawValue))

        let capabilities = try await gateway.negotiateDAVEAndMedia()
        #expect(!capabilities.dave)
        #expect(capabilities.aead)
        #expect(capabilities.opus)
        #expect(!capabilities.isProductionReady)
        await gateway.disconnect()
    }

    @Test("capability gating requires advertised protocol, handler, and attestation; not production evidence")
    func daveCapabilityGatingIsNotProductionEvidence() async throws {
        let harness = DiscordVoiceGatewaySessionHarness()
        let attestation = DiscordVoiceMediaCapabilityAttestation(
            aes256GCMAvailable: false,
            attest: { mode, version in
                #expect(mode == .aeadXChaCha20Poly1305RTPSIZE)
                #expect(version == 1)
                return DiscordVoiceMediaCapabilities(dave: true, aead: true, opus: true)
            }
        )
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: quiescentClock(),
            mediaAttestation: attestation,
            daveControlHandler: VoiceGatewayDAVEControlHandler(
                beginSession: { _, _ in [.keyPackage(try .init(Data([0xAB])))] },
                handle: { _, _ in [] }
            ),
            configuration: .init(maximumDAVEProtocolVersion: 1)
        )
        let connection = Task { try await gateway.connect(using: pair()) }
        try await eventually { await harness.attemptCount() == 1 }
        await harness.send(#"{"op":8,"d":{"heartbeat_interval":1000}}"#)
        try await eventually {
            await harness.sentInteger(opcode: 0, key: "max_dave_protocol_version") == 1
        }
        await harness.send(readyJSON(modes: [DiscordVoiceTransportMode.aeadXChaCha20Poly1305RTPSIZE.rawValue]))
        _ = try await connection.value
        try await gateway.selectTransport(
            DiscordVoiceDiscoveredEndpoint(address: "198.51.100.24", port: 62_004)
        )
        await harness.send(sessionDescriptionJSON(
            mode: DiscordVoiceTransportMode.aeadXChaCha20Poly1305RTPSIZE.rawValue,
            daveProtocolVersion: 1
        ))

        let capabilities = try await gateway.negotiateDAVEAndMedia()
        #expect(capabilities == DiscordVoiceMediaCapabilities(dave: true, aead: true, opus: true))
        #expect(capabilities.isProductionReady)
        await gateway.disconnect()
    }

    @Test("nonzero Session Description sends the initial Key Package before establishment")
    func initialDAVEKeyPackageAndMembership() async throws {
        let harness = DiscordVoiceGatewaySessionHarness()
        let handler = DiscordVoiceGatewayDAVEHandlerRecorder()
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: quiescentClock(),
            daveControlHandler: handler.handler,
            configuration: .init(maximumDAVEProtocolVersion: 1)
        )

        try await establish(gateway, harness: harness, daveProtocolVersion: 1)

        #expect(await harness.sentDAVEClientMessages().map(\.opcode) == [.keyPackage])
        #expect(await harness.sentDAVERepresentations() == [.binary])
        #expect(await handler.membershipSnapshots() == [[101]])

        await harness.send(#"{"op":11,"d":{"user_ids":["9","2"]},"seq":5}"#)
        try await eventually {
            await handler.membershipSnapshots().last == [2, 9, 101]
        }
        await harness.send(#"{"op":13,"d":{"user_id":"9"},"seq":6}"#)
        try await eventually {
            await handler.membershipSnapshots().last == [2, 101]
        }
        await gateway.disconnect()
    }

    @Test("External Sender received before Session Description is retained and bootstrapped")
    func externalSenderMayPrecedeSessionDescription() async throws {
        let harness = DiscordVoiceGatewaySessionHarness()
        let handler = DiscordVoiceGatewayDAVEHandlerRecorder()
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: quiescentClock(),
            daveControlHandler: handler.handler,
            configuration: .init(maximumDAVEProtocolVersion: 1)
        )
        let connection = Task { try await gateway.connect(using: pair()) }
        try await eventually { await harness.attemptCount() == 1 }
        await harness.send(#"{"op":8,"d":{"heartbeat_interval":1000}}"#)
        await harness.send(
            readyJSON(modes: [DiscordVoiceTransportMode.aeadXChaCha20Poly1305RTPSIZE.rawValue])
        )
        _ = try await connection.value
        await harness.sendBinary(Data([
            0x00, 0x03,
            VoiceGatewayDAVEOpcode.externalSenderPackage.rawValue,
            0x01, 0xAA,
            0x00, 0x01,
            0x01, 0xBB,
        ]))
        try await eventually {
            await handler.receivedOpcodes() == [.externalSenderPackage]
        }

        let selection = Task {
            try await gateway.selectTransport(
                .init(address: "198.51.100.41", port: 63_041)
            )
        }
        try await eventually { await harness.sentOpcodes().contains(1) }
        await harness.send(sessionDescriptionJSON(
            mode: DiscordVoiceTransportMode.aeadXChaCha20Poly1305RTPSIZE.rawValue,
            daveProtocolVersion: 1
        ))
        try await selection.value
        try await eventually { await gateway.snapshot().phase == .established }
        #expect(await harness.sentDAVEClientMessages().map(\.opcode) == [.keyPackage])
        #expect(await harness.closeCodes().isEmpty)
        await gateway.disconnect()
    }

    @Test("only External Sender may precede Session Description")
    func proposalsBeforeSessionDescriptionFailClosed() async throws {
        let harness = DiscordVoiceGatewaySessionHarness()
        let handler = DiscordVoiceGatewayDAVEHandlerRecorder()
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: quiescentClock(),
            daveControlHandler: handler.handler,
            configuration: .init(maximumDAVEProtocolVersion: 1)
        )
        let connection = Task { try await gateway.connect(using: pair()) }
        try await eventually { await harness.attemptCount() == 1 }
        await harness.send(#"{"op":8,"d":{"heartbeat_interval":1000}}"#)
        await harness.send(
            readyJSON(modes: [DiscordVoiceTransportMode.aeadXChaCha20Poly1305RTPSIZE.rawValue])
        )
        _ = try await connection.value

        await harness.sendBinary(Data([
            0x00, 0x03,
            VoiceGatewayDAVEOpcode.externalSenderPackage.rawValue,
            0x01, 0xAA,
            0x00, 0x01,
            0x01, 0xBB,
        ]))
        try await eventually {
            await handler.receivedOpcodes() == [.externalSenderPackage]
        }
        await harness.sendBinary(Data([
            0x00, 0x04,
            VoiceGatewayDAVEOpcode.proposals.rawValue,
            VoiceGatewayDAVEProposalsOperation.append.rawValue,
            0x01, 0xCC,
        ]))

        try await eventually { await harness.closeCodes() == [1002] }
        #expect(await handler.receivedOpcodes() == [.externalSenderPackage])
        try await eventually { await gateway.snapshot().phase == .failed }
    }

    @Test("missing initial Key Package fails closed before establishment")
    func missingInitialDAVEKeyPackageFailsClosed() async throws {
        let harness = DiscordVoiceGatewaySessionHarness()
        let handler = VoiceGatewayDAVEControlHandler(
            beginSession: { _, _ in [] },
            handle: { _, _ in [] }
        )
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: quiescentClock(),
            daveControlHandler: handler,
            configuration: .init(maximumDAVEProtocolVersion: 1)
        )
        let connection = Task { try await gateway.connect(using: pair()) }
        try await eventually { await harness.attemptCount() == 1 }
        await harness.send(#"{"op":8,"d":{"heartbeat_interval":1000}}"#)
        await harness.send(
            readyJSON(modes: [DiscordVoiceTransportMode.aeadXChaCha20Poly1305RTPSIZE.rawValue])
        )
        _ = try await connection.value
        let selection = Task {
            try await gateway.selectTransport(
                .init(address: "198.51.100.42", port: 63_042)
            )
        }
        try await eventually { await harness.sentOpcodes().contains(1) }
        await harness.send(sessionDescriptionJSON(
            mode: DiscordVoiceTransportMode.aeadXChaCha20Poly1305RTPSIZE.rawValue,
            daveProtocolVersion: 1
        ))

        try await selection.value
        await #expect(throws: VoiceGatewayDAVEError.self) {
            _ = try await gateway.negotiateDAVEAndMedia()
        }
        try await eventually { await harness.closeCodes() == [1002] }
        try await eventually { await gateway.snapshot().phase == .failed }
        #expect(await harness.sentDAVEClientMessages().isEmpty)
    }

    @Test("live DAVE control dispatch preserves response order and wire representation")
    func liveDAVEControlDispatch() async throws {
        let harness = DiscordVoiceGatewaySessionHarness()
        let handler = DiscordVoiceGatewayDAVEHandlerRecorder()
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: quiescentClock(),
            daveControlHandler: handler.handler,
            configuration: .init(maximumDAVEProtocolVersion: 1)
        )
        try await establish(gateway, harness: harness, daveProtocolVersion: 1)

        await harness.sendBinary(Data([
            0x00, 0x06,
            VoiceGatewayDAVEOpcode.externalSenderPackage.rawValue,
            0x01, 0xAA,
            0x00, 0x01,
            0x01, 0xBB,
        ]))
        await harness.send(
            #"{"op":24,"d":{"protocol_version":1,"transition_id":42,"epoch":2},"seq":7}"#
        )
        await harness.sendBinary(Data([
            0x00, 0x08,
            VoiceGatewayDAVEOpcode.announceCommitTransition.rawValue,
            0x00, 0x2A,
            0xC0,
        ]))

        try await eventually { await harness.sentDAVEClientMessages().count == 3 }
        let messages = await harness.sentDAVEClientMessages()
        #expect(messages.map(\.opcode) == [.keyPackage, .keyPackage, .transitionReady])
        #expect(
            await harness.sentDAVERepresentations() == [.binary, .binary, .json]
        )
        #expect(
            await handler.receivedOpcodes() == [
                .externalSenderPackage,
                .prepareEpoch,
                .announceCommitTransition,
            ]
        )
        #expect(await harness.closeCodes().isEmpty)
        await gateway.disconnect()
    }

    @Test("invalid Commit recovery emits Invalid Commit Welcome before a new Key Package")
    func invalidCommitRecoveryOrdering() async throws {
        let harness = DiscordVoiceGatewaySessionHarness()
        let handler = VoiceGatewayDAVEControlHandler(
            beginSession: { _, _ in [.keyPackage(try .init(Data([0xAB])))] },
            handle: { frame, _ in
                guard case .announceCommitTransition(let payload) = frame.message else {
                    return []
                }
                return [
                    .invalidCommitWelcome(.init(transitionID: payload.transitionID)),
                    .keyPackage(try .init(Data([0xFA, 0xCE]))),
                ]
            }
        )
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: quiescentClock(),
            daveControlHandler: handler,
            configuration: .init(maximumDAVEProtocolVersion: 1)
        )
        try await establish(gateway, harness: harness, daveProtocolVersion: 1)

        await harness.sendBinary(Data([
            0x00, 0x20,
            VoiceGatewayDAVEOpcode.announceCommitTransition.rawValue,
            0x00, 0x33,
            0xDE, 0xAD,
        ]))

        try await eventually { await harness.sentDAVEClientMessages().count == 3 }
        #expect(
            await harness.sentDAVEClientMessages().map(\.opcode) == [
                .keyPackage,
                .invalidCommitWelcome,
                .keyPackage,
            ]
        )
        #expect(await harness.sentDAVERepresentations() == [.binary, .json, .binary])
        #expect(await harness.closeCodes().isEmpty)
        await gateway.disconnect()
    }

    @Test("downgrade Execute clears previously attested production readiness")
    func downgradeClearsCapabilities() async throws {
        let harness = DiscordVoiceGatewaySessionHarness()
        let handler = DiscordVoiceGatewayDAVEHandlerRecorder()
        let attestation = DiscordVoiceMediaCapabilityAttestation(
            aes256GCMAvailable: false,
            attest: { _, _ in .init(dave: true, aead: true, opus: true) }
        )
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: quiescentClock(),
            mediaAttestation: attestation,
            daveControlHandler: handler.handler,
            configuration: .init(maximumDAVEProtocolVersion: 1)
        )
        try await establish(gateway, harness: harness, daveProtocolVersion: 1)
        #expect(try await gateway.negotiateDAVEAndMedia().isProductionReady)

        await harness.send(
            #"{"op":21,"d":{"protocol_version":0,"transition_id":50},"seq":30}"#
        )
        try await eventually { await harness.sentDAVEClientMessages().count == 2 }
        await harness.send(
            #"{"op":22,"d":{"transition_id":50},"seq":31}"#
        )
        try await eventually { await handler.receivedOpcodes().count == 2 }

        #expect(!(await gateway.snapshot().mediaProductionReady))
        #expect(!(try await gateway.negotiateDAVEAndMedia().dave))
        await gateway.disconnect()
    }

    @Test("unexpected DAVE transition fails closed before native dispatch")
    func unexpectedDAVETransitionFailsClosed() async throws {
        let harness = DiscordVoiceGatewaySessionHarness()
        let handler = DiscordVoiceGatewayDAVEHandlerRecorder()
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: quiescentClock(),
            daveControlHandler: handler.handler,
            configuration: .init(maximumDAVEProtocolVersion: 1)
        )
        try await establish(gateway, harness: harness, daveProtocolVersion: 1)

        await harness.send(#"{"op":22,"d":{"transition_id":99},"seq":7}"#)

        try await eventually { await harness.closeCodes().contains(1002) }
        try await eventually { await gateway.snapshot().phase == .failed }
        #expect(await handler.receivedOpcodes().isEmpty)
    }

    @Test("unsupported DAVE transition version fails before native dispatch")
    func unsupportedDAVEVersionFailsClosed() async throws {
        let harness = DiscordVoiceGatewaySessionHarness()
        let handler = DiscordVoiceGatewayDAVEHandlerRecorder()
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: quiescentClock(),
            daveControlHandler: handler.handler,
            configuration: .init(maximumDAVEProtocolVersion: 1)
        )
        try await establish(gateway, harness: harness, daveProtocolVersion: 1)

        await harness.send(
            #"{"op":21,"d":{"protocol_version":2,"transition_id":12},"seq":12}"#
        )

        try await eventually { await harness.closeCodes().contains(1002) }
        #expect(await handler.receivedOpcodes().isEmpty)
        try await eventually { await gateway.snapshot().phase == .failed }
    }

    @Test("protocol zero accepts a staged upgrade but activates DAVE only after Execute Transition")
    func protocolZeroStagesUpgradeUntilExecute() async throws {
        let harness = DiscordVoiceGatewaySessionHarness()
        let handler = DiscordVoiceGatewayDAVEHandlerRecorder()
        let attestation = DiscordVoiceMediaCapabilityAttestation(
            aes256GCMAvailable: false,
            attest: { _, _ in .init(dave: true, aead: true, opus: true) }
        )
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: quiescentClock(),
            mediaAttestation: attestation,
            daveControlHandler: handler.handler,
            configuration: .init(maximumDAVEProtocolVersion: 1)
        )
        try await establish(gateway, harness: harness, daveProtocolVersion: 0)
        let capabilities = try await gateway.negotiateDAVEAndMedia()
        #expect(!capabilities.dave)

        await harness.send(
            #"{"op":24,"d":{"protocol_version":1,"transition_id":8,"epoch":1},"seq":8}"#
        )
        await harness.sendBinary(Data([
            0x00, 0x09,
            VoiceGatewayDAVEOpcode.welcome.rawValue,
            0x00, 0x08,
            0xAB,
        ]))
        try await eventually { await harness.sentDAVEClientMessages().count == 2 }
        await harness.send(
            #"{"op":22,"d":{"transition_id":8},"seq":10}"#
        )
        try await eventually { await handler.receivedOpcodes().count == 3 }

        let upgraded = try await gateway.negotiateDAVEAndMedia()
        #expect(upgraded.dave)
        #expect(upgraded.isProductionReady)
        #expect(await harness.closeCodes().isEmpty)
        await gateway.disconnect()
    }

    @Test("DAVE opcode sent with the wrong WebSocket representation closes")
    func wrongDAVERepresentationFailsClosed() async throws {
        let harness = DiscordVoiceGatewaySessionHarness()
        let handler = DiscordVoiceGatewayDAVEHandlerRecorder()
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: quiescentClock(),
            daveControlHandler: handler.handler,
            configuration: .init(maximumDAVEProtocolVersion: 1)
        )
        try await establish(gateway, harness: harness, daveProtocolVersion: 1)

        await harness.send(#"{"op":25,"d":{},"seq":9}"#)

        try await eventually { await harness.closeCodes().contains(1002) }
        #expect(await handler.receivedOpcodes().isEmpty)
    }

    @Test("disconnect cancels DAVE handling without emitting a stale response")
    func disconnectCancelsDAVEHandler() async throws {
        let harness = DiscordVoiceGatewaySessionHarness()
        let handler = DiscordVoiceGatewaySuspendedDAVEHandler()
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: quiescentClock(),
            daveControlHandler: handler.handler,
            configuration: .init(maximumDAVEProtocolVersion: 1)
        )
        try await establish(gateway, harness: harness, daveProtocolVersion: 1)
        await harness.send(
            #"{"op":21,"d":{"protocol_version":0,"transition_id":10},"seq":10}"#
        )
        await handler.waitUntilStarted()

        await gateway.disconnect()

        #expect(await harness.closeCodes() == [1000])
        #expect(await harness.sentDAVEClientMessages().map(\.opcode) == [.keyPackage])
        #expect(await gateway.snapshot().phase == .disconnected)
    }

    @Test("disconnect joins and clears an in-flight membership replacement")
    func disconnectJoinsDAVEMembershipReplacement() async throws {
        let harness = DiscordVoiceGatewaySessionHarness()
        let membership = DiscordVoiceGatewaySuspendedMembershipHandler()
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: quiescentClock(),
            daveControlHandler: membership.handler,
            configuration: .init(maximumDAVEProtocolVersion: 1)
        )
        try await establish(gateway, harness: harness, daveProtocolVersion: 1)
        #expect(await membership.nativeUserIDs() == [101])

        await harness.send(#"{"op":11,"d":{"user_ids":["9"]},"seq":12}"#)
        await membership.waitUntilReplacementStarted()
        await gateway.disconnect()

        #expect(await membership.replacementFinished())
        #expect(await membership.nativeUserIDs().isEmpty)
        #expect(await membership.resetCount() == 3)
        #expect(await harness.closeCodes() == [1000])
        #expect(await gateway.snapshot().phase == .disconnected)
    }

    @Test("disconnect cancels a suspended initial DAVE bootstrap without stale establishment")
    func disconnectCancelsInitialDAVEBootstrap() async throws {
        let harness = DiscordVoiceGatewaySessionHarness()
        let bootstrap = DiscordVoiceGatewaySuspendedDAVEBootstrap()
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: quiescentClock(),
            daveControlHandler: bootstrap.handler,
            configuration: .init(maximumDAVEProtocolVersion: 1)
        )
        let connection = Task { try await gateway.connect(using: pair()) }
        try await eventually { await harness.attemptCount() == 1 }
        await harness.send(#"{"op":8,"d":{"heartbeat_interval":1000}}"#)
        await harness.send(
            readyJSON(modes: [DiscordVoiceTransportMode.aeadXChaCha20Poly1305RTPSIZE.rawValue])
        )
        _ = try await connection.value
        try await gateway.selectTransport(
            .init(address: "198.51.100.46", port: 63_046)
        )
        await harness.send(sessionDescriptionJSON(
            mode: DiscordVoiceTransportMode.aeadXChaCha20Poly1305RTPSIZE.rawValue,
            daveProtocolVersion: 1
        ))
        await bootstrap.waitUntilStarted()

        await gateway.disconnect()

        #expect(await bootstrap.resetCount() == 2)
        #expect(await harness.sentDAVEClientMessages().isEmpty)
        #expect(await harness.closeCodes() == [1000])
        #expect(await gateway.snapshot().phase == .disconnected)
        await #expect(throws: DiscordVoiceGatewaySessionError.self) {
            _ = try await gateway.negotiateDAVEAndMedia()
        }
    }

    @Test("missing required DAVE response fails closed")
    func missingDAVEResponseFailsClosed() async throws {
        let harness = DiscordVoiceGatewaySessionHarness()
        let handler = VoiceGatewayDAVEControlHandler(
            beginSession: { _, _ in [.keyPackage(try .init(Data([0xAB])))] },
            handle: { _, _ in [] }
        )
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: quiescentClock(),
            daveControlHandler: handler,
            configuration: .init(maximumDAVEProtocolVersion: 1)
        )
        try await establish(gateway, harness: harness, daveProtocolVersion: 1)

        await harness.send(
            #"{"op":21,"d":{"protocol_version":0,"transition_id":11},"seq":11}"#
        )

        try await eventually { await harness.closeCodes().contains(1002) }
        #expect(await harness.sentDAVEClientMessages().map(\.opcode) == [.keyPackage])
        try await eventually { await gateway.snapshot().phase == .failed }
    }

    @Test("Session Description may arrive before the Select Protocol send call returns")
    func immediateSessionDescriptionResponse() async throws {
        let mode = DiscordVoiceTransportMode.aeadXChaCha20Poly1305RTPSIZE.rawValue
        let harness = DiscordVoiceGatewaySessionHarness(
            autoResponseOnSelect: sessionDescriptionJSON(mode: mode)
        )
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: quiescentClock()
        )
        let connection = Task { try await gateway.connect(using: pair()) }
        try await eventually { await harness.attemptCount() == 1 }
        await harness.send(#"{"op":8,"d":{"heartbeat_interval":1000}}"#)
        await harness.send(readyJSON(modes: [mode]))
        _ = try await connection.value

        try await gateway.selectTransport(
            DiscordVoiceDiscoveredEndpoint(address: "198.51.100.23", port: 62_003)
        )
        let capabilities = try await gateway.negotiateDAVEAndMedia()
        #expect(!capabilities.isProductionReady)
        #expect(await gateway.snapshot().phase == .established)
        await gateway.disconnect()
    }

    @Test("heartbeat ACK deadline closes the live socket and fails the pending connection")
    func heartbeatTimeout() async throws {
        let harness = DiscordVoiceGatewaySessionHarness()
        let manualClock = DiscordVoiceGatewaySessionManualClock()
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: VoiceGatewayClientClock(
                now: { await manualClock.now() },
                sleep: { milliseconds in try await manualClock.sleep(milliseconds: milliseconds) }
            ),
            configuration: .init(heartbeatPollMilliseconds: 1)
        )
        let connection = Task { try await gateway.connect(using: pair()) }
        try await eventually { await harness.attemptCount() == 1 }
        await harness.send(#"{"op":8,"d":{"heartbeat_interval":100},"seq":1}"#)
        try await eventually { await harness.sentOpcodes() == [0] }

        await manualClock.advance(to: 100)
        try await eventually { await harness.sentOpcodes().contains(3) }
        await manualClock.advance(to: 200)
        try await eventually { await harness.closeCodes().contains(1001) }

        await #expect(throws: VoiceGatewayV8Error.self) {
            _ = try await connection.value
        }
        #expect(await gateway.snapshot().phase == .failed)
    }

    @Test("matching heartbeat ACK permits the next heartbeat without closing")
    func heartbeatAcknowledgement() async throws {
        let harness = DiscordVoiceGatewaySessionHarness()
        let manualClock = DiscordVoiceGatewaySessionManualClock()
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: VoiceGatewayClientClock(
                now: { await manualClock.now() },
                sleep: { milliseconds in try await manualClock.sleep(milliseconds: milliseconds) }
            ),
            configuration: .init(heartbeatPollMilliseconds: 1)
        )
        let connection = Task { try await gateway.connect(using: pair()) }
        try await eventually { await harness.attemptCount() == 1 }
        await harness.send(#"{"op":8,"d":{"heartbeat_interval":100},"seq":1}"#)
        await harness.send(readyJSON(modes: [DiscordVoiceTransportMode.aeadXChaCha20Poly1305RTPSIZE.rawValue]))
        _ = try await connection.value

        await manualClock.advance(to: 100)
        try await eventually { await harness.sentInteger(opcode: 3, key: "t") == 100 }
        await harness.send(#"{"op":6,"d":{"t":100},"seq":3}"#)
        try await eventually {
            !(await gateway.snapshot().heartbeatAwaitingAcknowledgement)
        }
        await manualClock.advance(to: 200)
        try await eventually { await harness.sentOpcodes().filter { $0 == 3 }.count == 2 }
        let closeCodes = await harness.closeCodes()
        #expect(!closeCodes.contains(1001))
        await gateway.disconnect()
    }

    @Test("accepted binary DAVE sequence is acknowledged by the next heartbeat")
    func binaryDAVESequenceFeedsHeartbeatAcknowledgement() async throws {
        let harness = DiscordVoiceGatewaySessionHarness()
        let manualClock = DiscordVoiceGatewaySessionManualClock()
        let handler = DiscordVoiceGatewayDAVEHandlerRecorder()
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: VoiceGatewayClientClock(
                now: { await manualClock.now() },
                sleep: { milliseconds in try await manualClock.sleep(milliseconds: milliseconds) }
            ),
            daveControlHandler: handler.handler,
            configuration: .init(heartbeatPollMilliseconds: 1, maximumDAVEProtocolVersion: 1)
        )
        let connection = Task { try await gateway.connect(using: pair()) }
        try await eventually { await harness.attemptCount() == 1 }
        await harness.send(#"{"op":8,"d":{"heartbeat_interval":100},"seq":1}"#)
        await harness.send(
            readyJSON(modes: [DiscordVoiceTransportMode.aeadXChaCha20Poly1305RTPSIZE.rawValue])
        )
        _ = try await connection.value
        try await gateway.selectTransport(.init(address: "198.51.100.44", port: 63_044))
        await harness.send(sessionDescriptionJSON(
            mode: DiscordVoiceTransportMode.aeadXChaCha20Poly1305RTPSIZE.rawValue,
            daveProtocolVersion: 1
        ))
        try await eventually { await gateway.snapshot().phase == .established }
        await harness.sendBinary(Data([
            0x12, 0x34,
            VoiceGatewayDAVEOpcode.externalSenderPackage.rawValue,
            0x01, 0xAA,
            0x00, 0x01,
            0x01, 0xBB,
        ]))
        try await eventually { await handler.receivedOpcodes() == [.externalSenderPackage] }

        await manualClock.advance(to: 100)
        try await eventually {
            await harness.sentInteger(opcode: 3, key: "seq_ack") == 0x1234
        }
        await gateway.disconnect()
    }

    @Test("oversized inbound text is closed with 1009 before decoding")
    func boundedInbound() async throws {
        let harness = DiscordVoiceGatewaySessionHarness()
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: quiescentClock(),
            configuration: .init(maximumMessageBytes: 256)
        )
        let connection = Task { try await gateway.connect(using: pair()) }
        try await eventually { await harness.attemptCount() == 1 }
        await harness.send(String(repeating: "x", count: 257))

        await #expect(throws: VoiceGatewayClientTransportError.self) {
            _ = try await connection.value
        }
        #expect(await harness.closeCodes() == [1009])
        #expect(await gateway.snapshot().phase == .failed)
    }

    @Test("Ready before Hello fails without sending Identify")
    func helloBeforeIdentify() async throws {
        let harness = DiscordVoiceGatewaySessionHarness()
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: quiescentClock()
        )
        let connection = Task { try await gateway.connect(using: pair()) }
        try await eventually { await harness.attemptCount() == 1 }
        await harness.send(readyJSON(modes: [DiscordVoiceTransportMode.aeadXChaCha20Poly1305RTPSIZE.rawValue]))

        await #expect(throws: VoiceGatewayV8Error.self) {
            _ = try await connection.value
        }
        #expect(await harness.sentOpcodes().isEmpty)
        #expect(await gateway.snapshot().phase == .failed)
    }

    @Test("operator disconnect unblocks and joins pending receive and heartbeat work")
    func cancellationSafeDisconnect() async throws {
        let harness = DiscordVoiceGatewaySessionHarness()
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: quiescentClock()
        )
        let connection = Task { try await gateway.connect(using: pair()) }
        try await eventually { await harness.attemptCount() == 1 }

        await gateway.disconnect()
        await #expect(throws: DiscordVoiceGatewaySessionError.self) {
            _ = try await connection.value
        }
        #expect(await harness.operationFinished())
        #expect(await harness.closeCodes() == [1000])
        #expect(await gateway.snapshot().phase == .disconnected)
    }

    @Test("disconnect during native reset prevents an obsolete connect from opening a socket")
    func disconnectWinsDuringConnectReset() async throws {
        let harness = DiscordVoiceGatewaySessionHarness()
        let resetGate = DiscordVoiceGatewayResetGate()
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: quiescentClock(),
            daveControlHandler: resetGate.handler,
            configuration: .init(maximumDAVEProtocolVersion: 1)
        )
        let connection = Task { try await gateway.connect(using: pair()) }
        await resetGate.waitUntilFirstResetStarted()

        await gateway.disconnect()
        await resetGate.releaseFirstReset()

        await #expect(throws: DiscordVoiceGatewaySessionError.self) {
            _ = try await connection.value
        }
        #expect(await harness.attemptCount() == 0)
        #expect(await gateway.snapshot().phase == .disconnected)
    }

    @Test("disconnect during Select Protocol send cannot resurrect failed session state")
    func disconnectWinsDuringSelectSend() async throws {
        let harness = DiscordVoiceGatewaySessionHarness(suspendSelectSend: true)
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: quiescentClock()
        )
        let connection = Task { try await gateway.connect(using: pair()) }
        try await eventually { await harness.attemptCount() == 1 }
        await harness.send(#"{"op":8,"d":{"heartbeat_interval":1000}}"#)
        await harness.send(
            readyJSON(modes: [DiscordVoiceTransportMode.aeadXChaCha20Poly1305RTPSIZE.rawValue])
        )
        _ = try await connection.value

        let selection = Task {
            try await gateway.selectTransport(
                .init(address: "198.51.100.45", port: 63_045)
            )
        }
        await harness.waitUntilSelectSendStarted()
        let disconnection = Task { await gateway.disconnect() }
        try await eventually { await harness.closeCodes() == [1000] }
        await harness.releaseSelectSend()
        await disconnection.value

        await #expect(throws: DiscordVoiceGatewaySessionError.self) {
            try await selection.value
        }
        #expect(await harness.closeCodes() == [1000])
        #expect(await gateway.snapshot().phase == .disconnected)
    }

    @Test("disconnect without a transport still resets native DAVE state")
    func noTaskDisconnectResetsDAVEHandler() async {
        let handler = DiscordVoiceGatewayDAVEHandlerRecorder()
        let gateway = DiscordVoiceGatewaySession(
            transport: DiscordVoiceGatewaySessionHarness().transport,
            clock: quiescentClock(),
            daveControlHandler: handler.handler,
            configuration: .init(maximumDAVEProtocolVersion: 1)
        )

        await gateway.disconnect()

        #expect(await handler.resetCount() == 1)
        #expect(await gateway.snapshot().phase == .disconnected)
    }

    @Test("resumable remote close is conservatively surfaced as failure")
    func failClosedRemoteClose() async throws {
        let harness = DiscordVoiceGatewaySessionHarness()
        let handler = DiscordVoiceGatewayDAVEHandlerRecorder()
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: quiescentClock(),
            daveControlHandler: handler.handler,
            configuration: .init(maximumDAVEProtocolVersion: 1)
        )
        let connection = Task { try await gateway.connect(using: pair()) }
        try await eventually { await harness.attemptCount() == 1 }
        await harness.send(#"{"op":8,"d":{"heartbeat_interval":1000}}"#)
        await harness.send(readyJSON(modes: [DiscordVoiceTransportMode.aeadXChaCha20Poly1305RTPSIZE.rawValue]))
        _ = try await connection.value

        await harness.finishRemotely(code: 4015)
        try await eventually { await gateway.snapshot().phase == .failed }
        try await eventually { await handler.resetCount() == 2 }
        let snapshot = await gateway.snapshot()
        #expect(!snapshot.signalingEstablished)
        await #expect(throws: DiscordVoiceGatewaySessionError.self) {
            try await gateway.selectTransport(
                DiscordVoiceDiscoveredEndpoint(address: "198.51.100.30", port: 63_000)
            )
        }
        await gateway.disconnect()
    }

    @Test("endpoint and identity validation happen before opening a socket and descriptions redact credentials")
    func validationAndRedaction() async throws {
        let harness = DiscordVoiceGatewaySessionHarness()
        let gateway = DiscordVoiceGatewaySession(
            transport: harness.transport,
            clock: quiescentClock()
        )
        let token = "never-render-this-voice-token"

        await #expect(throws: VoiceGatewayV8Error.self) {
            _ = try await gateway.connect(using: DiscordVoiceGatewayPair(
                endpoint: "ws://unsafe.example.test",
                token: token,
                sessionID: "session",
                serverID: "guild",
                channelID: "channel",
                userID: "user"
            ))
        }
        #expect(await harness.attemptCount() == 0)

        let connection = Task { try await gateway.connect(using: pair(token: token)) }
        try await eventually { await harness.attemptCount() == 1 }
        let rendered = String(describing: gateway) + String(reflecting: gateway)
        #expect(!rendered.contains(token))
        #expect(!rendered.contains("voice.example.test"))
        #expect(rendered.contains("<redacted>"))
        await gateway.disconnect()
        await #expect(throws: DiscordVoiceGatewaySessionError.self) {
            _ = try await connection.value
        }
    }

    private func pair(token: String = "ephemeral-voice-token") -> DiscordVoiceGatewayPair {
        DiscordVoiceGatewayPair(
            endpoint: "voice.example.test",
            token: token,
            sessionID: "voice-session",
            serverID: "303",
            channelID: "202",
            userID: "101"
        )
    }

    private func quiescentClock() -> VoiceGatewayClientClock {
        VoiceGatewayClientClock(
            now: { 0 },
            sleep: { _ in try await Task.sleep(for: .seconds(60)) }
        )
    }

    private func readyJSON(modes: [String]) -> String {
        let modesJSON = modes.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"op":2,"seq":2,"d":{"ssrc":44,"ip":"203.0.113.8","port":50000,"modes":[\#(modesJSON)]}}"#
    }

    private func sessionDescriptionJSON(mode: String, daveProtocolVersion: Int = 0) -> String {
        let key = Array(repeating: "1", count: 32).joined(separator: ",")
        return #"{"op":4,"seq":4,"d":{"mode":"\#(mode)","secret_key":[\#(key)],"dave_protocol_version":\#(daveProtocolVersion)}}"#
    }

    private func establish(
        _ gateway: DiscordVoiceGatewaySession,
        harness: DiscordVoiceGatewaySessionHarness,
        daveProtocolVersion: Int
    ) async throws {
        let mode = DiscordVoiceTransportMode.aeadXChaCha20Poly1305RTPSIZE.rawValue
        let connection = Task { try await gateway.connect(using: pair()) }
        try await eventually { await harness.attemptCount() == 1 }
        await harness.send(#"{"op":8,"d":{"heartbeat_interval":1000}}"#)
        await harness.send(readyJSON(modes: [mode]))
        _ = try await connection.value
        try await gateway.selectTransport(
            .init(address: "198.51.100.40", port: 63_040)
        )
        await harness.send(
            sessionDescriptionJSON(
                mode: mode,
                daveProtocolVersion: daveProtocolVersion
            )
        )
        try await eventually { await gateway.snapshot().phase == .established }
    }

    private func eventually(
        attempts: Int = 1_000,
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Condition was not satisfied before timeout")
        throw DiscordVoiceGatewaySessionTestError.conditionTimedOut
    }
}

private enum DiscordVoiceGatewaySessionTestError: Error {
    case conditionTimedOut
}

private actor DiscordVoiceGatewaySessionHarness {
    private let socket: DiscordVoiceGatewaySessionSocket
    private var attempts = 0
    private var finished = false
    private var remoteClose: VoiceGatewayClientClose?

    init(autoResponseOnSelect: String? = nil, suspendSelectSend: Bool = false) {
        socket = DiscordVoiceGatewaySessionSocket(
            autoResponseOnSelect: autoResponseOnSelect,
            suspendSelectSend: suspendSelectSend
        )
    }

    nonisolated var transport: VoiceGatewayClientTransport {
        VoiceGatewayClientTransport { [self] _, _, operation in
            await beganOperation()
            do {
                try await operation(socket.session)
            } catch VoiceGatewayClientTransportError.connectionClosed {
                let close = await closeResult()
                await finishedOperation()
                return close
            } catch {
                await finishedOperation()
                throw error
            }
            let close = await closeResult()
            await finishedOperation()
            return close
        }
    }

    func send(_ text: String) async { await socket.enqueue(text) }
    func sendBinary(_ data: Data) async { await socket.enqueue(.binary(data)) }

    func finishRemotely(code: Int) async {
        remoteClose = VoiceGatewayClientClose(code: code, reason: "untrusted remote reason")
        await socket.finish()
    }

    func attemptCount() -> Int { attempts }
    func operationFinished() -> Bool { finished }
    func closeCodes() async -> [Int] { await socket.closeCodes() }
    func sentOpcodes() async -> [Int] { await socket.sentOpcodes() }
    func sentInteger(opcode: Int, key: String) async -> Int? {
        await socket.sentInteger(opcode: opcode, key: key)
    }
    func sentString(opcode: Int, nestedKey: String) async -> String? {
        await socket.sentString(opcode: opcode, nestedKey: nestedKey)
    }
    func sentDAVEClientMessages() async -> [VoiceGatewayDAVEClientMessage] {
        await socket.sentDAVEClientMessages()
    }
    func sentDAVERepresentations() async -> [VoiceGatewayDAVEWireRepresentation] {
        await socket.sentDAVERepresentations()
    }
    func waitUntilSelectSendStarted() async { await socket.waitUntilSelectSendStarted() }
    func releaseSelectSend() async { await socket.releaseSelectSend() }

    private func beganOperation() {
        attempts += 1
        finished = false
    }

    private func finishedOperation() { finished = true }
    private func closeResult() -> VoiceGatewayClientClose? { remoteClose }
}

private actor DiscordVoiceGatewaySessionSocket {
    private typealias Waiter = CheckedContinuation<VoiceGatewayClientFrame?, Never>

    private var buffered: [VoiceGatewayClientFrame] = []
    private var waiters: [Waiter] = []
    private var sent: [VoiceGatewayClientFrame] = []
    private var closes: [Int] = []
    private var isFinished = false
    private let autoResponseOnSelect: String?
    private let selectSendGate: DiscordVoiceGatewaySelectSendGate?

    init(autoResponseOnSelect: String?, suspendSelectSend: Bool) {
        self.autoResponseOnSelect = autoResponseOnSelect
        self.selectSendGate = suspendSelectSend ? DiscordVoiceGatewaySelectSendGate() : nil
    }

    nonisolated var session: VoiceGatewayClientSession {
        VoiceGatewayClientSession(
            receiveFrame: { [self] in await receive() },
            sendFrame: { [self] frame in try await recordSent(frame) },
            close: { [self] code, _ in await recordClose(code) }
        )
    }

    func enqueue(_ text: String) {
        enqueue(.text(text))
    }

    func enqueue(_ frame: VoiceGatewayClientFrame) {
        guard !isFinished else { return }
        if waiters.isEmpty {
            buffered.append(frame)
        } else {
            waiters.removeFirst().resume(returning: frame)
        }
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending { waiter.resume(returning: nil) }
    }

    func receive() async -> VoiceGatewayClientFrame? {
        if !buffered.isEmpty { return buffered.removeFirst() }
        if isFinished { return nil }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func recordSent(_ frame: VoiceGatewayClientFrame) async throws {
        if let selectSendGate,
           case .text(let text) = frame,
           object(from: text)?["op"] as? Int == VoiceGatewayV8SelectProtocol.opcode
        {
            await selectSendGate.suspend()
        }
        guard !isFinished else { throw VoiceGatewayClientTransportError.connectionClosed }
        sent.append(frame)
        if let autoResponseOnSelect,
           case .text(let text) = frame,
           object(from: text)?["op"] as? Int == VoiceGatewayV8SelectProtocol.opcode
        {
            enqueue(autoResponseOnSelect)
        }
    }

    func recordClose(_ code: Int) {
        closes.append(code)
        finish()
    }

    func closeCodes() -> [Int] { closes }

    func sentOpcodes() -> [Int] {
        sent.compactMap { frame in
            guard case .text(let text) = frame else { return nil }
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return object["op"] as? Int
        }
    }

    func sentInteger(opcode: Int, key: String) -> Int? {
        let objects: [[String: Any]] = sent.compactMap { frame in
            guard case .text(let text) = frame else { return nil }
            return object(from: text)
        }
        return objects.first { $0["op"] as? Int == opcode }
            .flatMap { ($0["d"] as? [String: Any])?[key] as? Int }
    }

    func sentString(opcode: Int, nestedKey: String) -> String? {
        let objects: [[String: Any]] = sent.compactMap { frame in
            guard case .text(let text) = frame else { return nil }
            return object(from: text)
        }
        return objects.first { $0["op"] as? Int == opcode }
            .flatMap { envelope in
                guard let payload = envelope["d"] as? [String: Any],
                      let data = payload["data"] as? [String: Any]
                else { return nil }
                return data[nestedKey] as? String
            }
    }

    func sentDAVEClientMessages() -> [VoiceGatewayDAVEClientMessage] {
        sent.compactMap { frame in
            switch frame {
            case .text(let text):
                return try? VoiceGatewayDAVECodec.decodeClientJSON(Data(text.utf8))
            case .binary(let data):
                return try? VoiceGatewayDAVECodec.decodeClientBinary(data)
            }
        }
    }

    func sentDAVERepresentations() -> [VoiceGatewayDAVEWireRepresentation] {
        sent.compactMap { frame in
            switch frame {
            case .text(let text):
                guard (try? VoiceGatewayDAVECodec.decodeClientJSON(Data(text.utf8))) != nil
                else { return nil }
                return .json
            case .binary(let data):
                guard (try? VoiceGatewayDAVECodec.decodeClientBinary(data)) != nil
                else { return nil }
                return .binary
            }
        }
    }

    func waitUntilSelectSendStarted() async {
        await selectSendGate?.waitUntilStarted()
    }

    func releaseSelectSend() async {
        await selectSendGate?.release()
    }

    private func object(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

private actor DiscordVoiceGatewaySelectSendGate {
    private var started = false
    private var released = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        started = true
        let pending = startedWaiters
        startedWaiters.removeAll(keepingCapacity: false)
        for waiter in pending { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        released = true
        let pending = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in pending { waiter.resume() }
    }
}

private actor DiscordVoiceGatewaySessionManualClock {
    private var milliseconds: UInt64 = 0

    func now() -> UInt64 { milliseconds }
    func advance(to value: UInt64) { milliseconds = max(milliseconds, value) }

    func sleep(milliseconds delay: UInt64) async throws {
        let target = self.milliseconds + delay
        while self.milliseconds < target {
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private actor DiscordVoiceGatewayDAVEHandlerRecorder {
    private var opcodes: [VoiceGatewayDAVEOpcode] = []
    private var recognizedUserIDSnapshots: [[UInt64]] = []
    private var resets = 0

    nonisolated var handler: VoiceGatewayDAVEControlHandler {
        VoiceGatewayDAVEControlHandler(
            beginSession: { _, _ in
                [.keyPackage(try .init(Data([0xBA, 0x5E])))]
            },
            replaceRecognizedUserIDs: { [self] userIDs in
                await replaceRecognizedUserIDs(userIDs)
            },
            handle: { [self] frame, _ in
                try await handle(frame)
            },
            reset: { [self] in await reset() }
        )
    }

    func receivedOpcodes() -> [VoiceGatewayDAVEOpcode] { opcodes }
    func membershipSnapshots() -> [[UInt64]] { recognizedUserIDSnapshots }
    func resetCount() -> Int { resets }

    private func replaceRecognizedUserIDs(_ userIDs: [UInt64]) {
        recognizedUserIDSnapshots.append(userIDs)
    }

    private func handle(
        _ frame: VoiceGatewayDAVEInboundFrame
    ) throws -> [VoiceGatewayDAVEClientMessage] {
        opcodes.append(frame.message.opcode)
        switch frame.message {
        case .prepareTransition(let payload):
            return [
                .transitionReady(.init(transitionID: payload.transitionID))
            ]
        case .prepareEpoch:
            return [
                .keyPackage(try .init(Data([0xC0, 0xDE])))
            ]
        case .announceCommitTransition(let payload):
            return [
                .transitionReady(.init(transitionID: payload.transitionID))
            ]
        case .welcome(let payload):
            return [
                .transitionReady(.init(transitionID: payload.transitionID))
            ]
        default:
            return []
        }
    }

    private func reset() {
        resets += 1
        opcodes.removeAll(keepingCapacity: false)
        recognizedUserIDSnapshots.removeAll(keepingCapacity: false)
    }
}

private actor DiscordVoiceGatewaySuspendedDAVEHandler {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    nonisolated var handler: VoiceGatewayDAVEControlHandler {
        VoiceGatewayDAVEControlHandler(
            beginSession: { _, _ in
                [.keyPackage(try .init(Data([0xBA, 0x5E])))]
            },
            handle: { [self] _, _ in
                await suspendUntilReset()
                try Task.checkCancellation()
                return []
            },
            reset: { [self] in await releaseIfStarted() }
        )
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    private func suspendUntilReset() async {
        started = true
        let pending = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    private func releaseIfStarted() {
        guard started else { return }
        let pending = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor DiscordVoiceGatewaySuspendedDAVEBootstrap {
    private var started = false
    private var resets = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    nonisolated var handler: VoiceGatewayDAVEControlHandler {
        VoiceGatewayDAVEControlHandler(
            beginSession: { [self] _, _ in
                await suspendUntilReset()
                try Task.checkCancellation()
                return [.keyPackage(try .init(Data([0xBA, 0x5E])))]
            },
            handle: { _, _ in [] },
            reset: { [self] in await reset() }
        )
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resetCount() -> Int { resets }

    private func suspendUntilReset() async {
        started = true
        let pending = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        for waiter in pending { waiter.resume() }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    private func reset() {
        resets += 1
        let pending = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in pending { waiter.resume() }
    }
}

private actor DiscordVoiceGatewaySuspendedMembershipHandler {
    private var replacementCalls = 0
    private var resets = 0
    private var userIDs: [UInt64] = []
    private var replacementStarted = false
    private var replacementDidFinish = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    nonisolated var handler: VoiceGatewayDAVEControlHandler {
        VoiceGatewayDAVEControlHandler(
            beginSession: { _, _ in
                [.keyPackage(try .init(Data([0xBA, 0x5E])))]
            },
            replaceRecognizedUserIDs: { [self] userIDs in
                await replaceRecognizedUserIDs(userIDs)
            },
            handle: { _, _ in [] },
            reset: { [self] in await reset() }
        )
    }

    func waitUntilReplacementStarted() async {
        guard !replacementStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func nativeUserIDs() -> [UInt64] { userIDs }
    func replacementFinished() -> Bool { replacementDidFinish }
    func resetCount() -> Int { resets }

    private func replaceRecognizedUserIDs(_ nextUserIDs: [UInt64]) async {
        replacementCalls += 1
        if replacementCalls == 1 {
            userIDs = nextUserIDs
            return
        }

        replacementStarted = true
        let pendingStarts = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        for waiter in pendingStarts { waiter.resume() }
        await withCheckedContinuation { releaseWaiters.append($0) }

        // Deliberately ignore cooperative cancellation and model a native
        // replacement that lands after the reset which released it.
        userIDs = nextUserIDs
        replacementDidFinish = true
    }

    private func reset() {
        resets += 1
        userIDs.removeAll(keepingCapacity: false)
        let pendingReleases = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in pendingReleases { waiter.resume() }
    }
}

private actor DiscordVoiceGatewayResetGate {
    private var resetCalls = 0
    private var firstResetStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    nonisolated var handler: VoiceGatewayDAVEControlHandler {
        VoiceGatewayDAVEControlHandler(
            handle: { _, _ in [] },
            reset: { [self] in await reset() }
        )
    }

    func waitUntilFirstResetStarted() async {
        guard !firstResetStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseFirstReset() {
        let pending = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in pending { waiter.resume() }
    }

    private func reset() async {
        resetCalls += 1
        guard resetCalls == 1 else { return }
        firstResetStarted = true
        let pending = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        for waiter in pending { waiter.resume() }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
}
