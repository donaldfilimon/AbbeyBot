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

    @Test("native MLS callback failure is sticky until session replacement")
    func nativeFailureCallbackIsStickyAndRedacted() async throws {
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
        #expect(await session.rosterMemberIDs.isEmpty)

        await #expect(throws: NativeMediaError.daveMLSFailure(
            operation: "create-key-package"
        )) {
            _ = try await session.marshalledKeyPackage()
        }
        await #expect(throws: NativeMediaError.daveMLSFailure(
            operation: "activate-roster"
        )) {
            try await session.activateRoster(memberIDs: [901])
        }
        await #expect(throws: NativeMediaError.daveMLSFailure(operation: "protect")) {
            _ = try await session.protect(
                Data([0xf8, 0xff, 0xfe]),
                mediaType: .audio,
                codec: .opus,
                ssrc: 42
            )
        }
        await #expect(throws: NativeMediaError.daveMLSFailure(operation: "unprotect")) {
            _ = try await session.unprotect(
                Data([1, 2, 3]),
                mediaType: .audio,
                senderID: 902
            )
        }

        let replacement = try NativeDAVESession(
            protocolVersion: 1,
            groupID: 900,
            selfUserID: "901"
        )
        let replacementKeyPackage = try await replacement.marshalledKeyPackage()
        #expect(!replacementKeyPackage.isEmpty)
        #expect(await replacement.isMediaReady == false)
    }

    @Test("Commit change maps add, refresh, and remove only named members")
    func commitRosterChangeMapMerge() {
        #expect(
            NativeDAVESession.rosterAfterCommit(
                current: [10, 20, 30],
                changes: [20: true, 40: true]
            ) == [10, 20, 30, 40]
        )
        #expect(
            NativeDAVESession.rosterAfterCommit(
                current: [10, 20, 30],
                changes: [20: false, 40: true]
            ) == [10, 30, 40]
        )
        #expect(
            NativeDAVESession.rosterAfterCommit(
                current: [7, 9],
                changes: [:]
            ) == [7, 9]
        )
        #expect(
            NativeDAVESession.rosterAfterCommit(
                current: [9, 7, 9, 7],
                changes: [8: true]
            ) == [7, 8, 9]
        )
    }

    @Test("Commit change map self removal produces a roster that fails activation closed")
    func commitSelfRemovalFailsClosed() async throws {
        let roster = NativeDAVESession.rosterAfterCommit(
            current: [50, 60],
            changes: [50: false]
        )
        #expect(roster == [60])

        let session = try NativeDAVESession(
            protocolVersion: 1,
            groupID: 49,
            selfUserID: "50"
        )
        await #expect(throws: NativeMediaError.daveParticipantUnavailable) {
            try await session.activateRoster(memberIDs: roster)
        }
        #expect(await session.isMediaReady == false)
        #expect(await session.rosterMemberIDs.isEmpty)
    }

    @Test("Commit removal for an absent member is idempotent")
    func commitAbsentRemovalIsIdempotent() {
        #expect(
            NativeDAVESession.rosterAfterCommit(
                current: [1, 2, 2, 3],
                changes: [4: false]
            ) == [1, 2, 3]
        )
    }

    @Test("runtime native output secrecy probe")
    func runtimeNativeOutputSecrecyProbe() async throws {
        let environment = ProcessInfo.processInfo.environment
        let sentinel = environment["ABBEY_NATIVE_SECRET_SENTINEL"]
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "abbey-native-output-secrecy-probe"
        guard !sentinel.contains("\0"), sentinel.utf8.count <= 256 else {
            Issue.record("Native secrecy sentinel violates the bounded input contract")
            return
        }

        let groupIDText = environment["ABBEY_NATIVE_GROUP_ID_SENTINEL"] ?? "812345678901234567"
        let userIDText = environment["ABBEY_NATIVE_USER_ID_SENTINEL"] ?? "712345678901234569"
        guard let groupID = UInt64(groupIDText), groupID > 0,
              let userID = UInt64(userIDText), userID > 0,
              groupID != userID,
              groupIDText.utf8.count <= 64,
              userIDText.utf8.count <= 64
        else {
            Issue.record("Native numeric secrecy sentinels violate the identifier contract")
            return
        }

        // This value is deliberately invalid as a Discord snowflake but still
        // carries opaque sentinel material through the Swift validation path.
        let invalidIdentifier = String(sentinel.prefix(64))
        if UInt64(invalidIdentifier) == nil {
            #expect(throws: NativeMediaError.invalidDAVEIdentifier) {
                _ = try NativeDAVESession(
                    protocolVersion: 1,
                    groupID: groupID,
                    selfUserID: invalidIdentifier,
                    authenticationSessionID: sentinel
                )
            }
        }

        var malformedMLS = Data([0xff])
        malformedMLS.append(contentsOf: sentinel.utf8)
        malformedMLS.append(contentsOf: groupIDText.utf8)
        malformedMLS.append(contentsOf: userIDText.utf8)
        let mediaBytes = Data(sentinel.utf8)

        // Protocol zero is not a product capability. It is the only fixture
        // that can drive both libdave media functions without manufacturing
        // unaudited MLS state, so it serves solely as an output-secrecy probe.
        let passthrough = try DAVEPassThroughCodec()
        let protected = try await passthrough.protectOpus(mediaBytes, ssrc: 42)
        if protected != mediaBytes {
            Issue.record("Native passthrough protection changed the probe payload")
        }
        let unprotected = try await passthrough.unprotectOpus(protected)
        if unprotected != mediaBytes {
            Issue.record("Native passthrough unprotection changed the probe payload")
        }

        await expectTypedNativeFailure {
            let session = try makeSecrecyProbeSession(
                sentinel: sentinel,
                groupID: groupID,
                userID: userIDText
            )
            try await session.setExternalSender(malformedMLS)
        }
        await expectTypedNativeFailure {
            let session = try makeSecrecyProbeSession(
                sentinel: sentinel,
                groupID: groupID,
                userID: userIDText
            )
            _ = try await session.processCommit(malformedMLS)
        }
        await expectTypedNativeFailure {
            let session = try makeSecrecyProbeSession(
                sentinel: sentinel,
                groupID: groupID,
                userID: userIDText
            )
            _ = try await session.processWelcome(
                malformedMLS,
                recognizedUserIDs: [userIDText]
            )
        }
        await expectTypedNativeFailure {
            let session = try makeSecrecyProbeSession(
                sentinel: sentinel,
                groupID: groupID,
                userID: userIDText
            )
            _ = try await session.protect(
                mediaBytes,
                mediaType: .audio,
                codec: .opus,
                ssrc: 42
            )
        }
        await expectTypedNativeFailure {
            let session = try makeSecrecyProbeSession(
                sentinel: sentinel,
                groupID: groupID,
                userID: userIDText
            )
            _ = try await session.unprotect(
                mediaBytes,
                mediaType: .audio,
                senderID: userID
            )
        }
    }

    private func makeSecrecyProbeSession(
        sentinel: String,
        groupID: UInt64,
        userID: String
    ) throws -> NativeDAVESession {
        try NativeDAVESession(
            protocolVersion: 1,
            groupID: groupID,
            selfUserID: userID,
            authenticationSessionID: sentinel
        )
    }

    private func expectTypedNativeFailure(
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected a typed native-media failure")
        } catch is NativeMediaError {
            // The error type is the assertion. Never render its inputs here.
        } catch {
            Issue.record("Received an unexpected non-native error type")
        }
    }

}
