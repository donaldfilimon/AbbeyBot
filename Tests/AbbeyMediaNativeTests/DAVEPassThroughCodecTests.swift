import Foundation
import Testing
@testable import AbbeyMediaNative

@Suite("Pinned libdave boundary")
struct DAVEPassThroughCodecTests {
    @Test("reports audited library pins and a runtime maximum protocol")
    func versions() {
        #expect(NativeMediaVersions.libdave == "1.1.1")
        #expect(NativeMediaVersions.libdaveCommit == "52cd56dc550f447fb354b3a06c9e2d2e2a4309c6")
        #expect(NativeMediaVersions.maximumDAVEProtocolVersion > 0)
        #expect(NativeMediaVersions.runtimeOpusVersion.contains("1.6.1"))
        #expect(NativeMediaVersions.runtimeSodiumVersion == "1.0.22")
    }

    @Test("protocol-zero passthrough lifecycle preserves an Opus frame")
    func passthrough() async throws {
        let codec = try DAVEPassThroughCodec()
        #expect(await codec.isPassthrough)
        #expect(await codec.protocolVersion == 0)
        let frame = Data([0xf8, 0xff, 0xfe])
        let protected = try await codec.protectOpus(frame, ssrc: 42)
        #expect(protected == frame)
        #expect(try await codec.unprotectOpus(protected) == frame)
    }
}
