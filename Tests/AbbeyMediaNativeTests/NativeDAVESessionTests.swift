import Foundation
import Testing
@testable import AbbeyMediaNative

@Suite("Native DAVE session")
struct NativeDAVESessionTests {
    @Test("rejects protocol zero and versions above the audited runtime")
    func protocolBounds() {
        #expect(throws: NativeMediaError.invalidDAVEProtocolVersion(0)) {
            _ = try NativeDAVESession(protocolVersion: 0, groupID: 1, selfUserID: "2")
        }
        let unsupported = NativeMediaVersions.maximumDAVEProtocolVersion &+ 1
        #expect(throws: NativeMediaError.invalidDAVEProtocolVersion(unsupported)) {
            _ = try NativeDAVESession(
                protocolVersion: unsupported,
                groupID: 1,
                selfUserID: "2"
            )
        }
    }

    @Test("validates identifiers without exposing them in diagnostics")
    func identifiersAndRedaction() async throws {
        #expect(throws: NativeMediaError.invalidDAVEIdentifier) {
            _ = try NativeDAVESession(protocolVersion: 1, groupID: 0, selfUserID: "secret-user")
        }
        let session = try NativeDAVESession(
            protocolVersion: 1,
            groupID: 111,
            selfUserID: "222",
            authenticationSessionID: "private-auth-session"
        )
        let diagnostics = "\(session) \(String(reflecting: session))"
        #expect(!diagnostics.contains("111"))
        #expect(!diagnostics.contains("222"))
        #expect(!diagnostics.contains("private-auth-session"))
        #expect(await session.protocolVersion == 1)
        #expect(await session.isMediaReady == false)

        let mirror = Mirror(reflecting: session)
        #expect(mirror.children.count == 1)
        var dumped = ""
        dump(session, to: &dumped)
        #expect(!dumped.contains("111"))
        #expect(!dumped.contains("222"))
        #expect(!dumped.contains("private-auth-session"))
        #expect(dumped.contains("<redacted>"))

        #expect(throws: NativeMediaError.invalidDAVEIdentifier) {
            _ = try NativeDAVESession(
                protocolVersion: 1,
                groupID: 111,
                selfUserID: "222",
                authenticationSessionID: ""
            )
        }
        #expect(throws: NativeMediaError.invalidDAVEIdentifier) {
            _ = try NativeDAVESession(
                protocolVersion: 1,
                groupID: 111,
                selfUserID: "222",
                authenticationSessionID: "namespace\0collision"
            )
        }
    }

    @Test("creates a bounded MLS key package but fails media closed before roster activation")
    func keyPackageAndFailClosedMedia() async throws {
        let session = try NativeDAVESession(protocolVersion: 1, groupID: 333, selfUserID: "444")
        let keyPackage = try await session.marshalledKeyPackage()
        #expect(!keyPackage.isEmpty)
        #expect(keyPackage.count <= NativeDAVESession.maximumControlPayloadBytes)

        await #expect(throws: NativeMediaError.daveParticipantUnavailable) {
            _ = try await session.protect(
                Data([0xf8, 0xff, 0xfe]),
                mediaType: .audio,
                codec: .opus,
                ssrc: 42
            )
        }
        await #expect(throws: NativeMediaError.daveParticipantUnavailable) {
            _ = try await session.unprotect(
                Data([1, 2, 3]),
                mediaType: .audio,
                senderID: 555
            )
        }
    }

    @Test("bounds control payloads and requires the local participant in a roster")
    func boundsAndRoster() async throws {
        let session = try NativeDAVESession(protocolVersion: 1, groupID: 666, selfUserID: "777")
        await #expect(throws: NativeMediaError.daveParticipantUnavailable) {
            try await session.activateRoster(memberIDs: [888])
        }
        await #expect(throws: NativeMediaError.daveFrameTooLarge(
            actual: 0,
            maximum: NativeDAVESession.maximumControlPayloadBytes
        )) {
            try await session.setExternalSender(Data())
        }
    }

    @Test("native MLS failures cross the void C boundary as a generic Swift error")
    func nativeFailureCallbackIsFailClosedAndRedacted() async throws {
        let session = try NativeDAVESession(
            protocolVersion: 1,
            groupID: 900,
            selfUserID: "901"
        )

        await #expect(throws: NativeMediaError.daveMLSFailure(
            operation: "set-external-sender"
        )) {
            try await session.setExternalSender(Data([0xff]))
        }
        #expect(await session.isMediaReady == false)
    }

    @Test("Commit roster deltas preserve unchanged members and apply removals")
    func commitRosterDeltaMerge() {
        #expect(
            NativeDAVESession.mergedRoster(
                current: [10, 20, 30],
                changes: [20: true, 30: false, 40: true]
            ) == [10, 20, 40]
        )
        #expect(
            NativeDAVESession.mergedRoster(
                current: [],
                changes: [9: true, 7: true]
            ) == [7, 9]
        )
    }
}
