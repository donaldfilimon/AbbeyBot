import Foundation
import CLibDave

private final class DAVEEncryptorStorage {
    let raw: OpaquePointer
    init(_ raw: OpaquePointer) { self.raw = raw }
    deinit { daveEncryptorDestroy(raw) }
}

private final class DAVEDecryptorStorage {
    let raw: OpaquePointer
    init(_ raw: OpaquePointer) { self.raw = raw }
    deinit { daveDecryptorDestroy(raw) }
}

/// Verified lifecycle and protocol-zero passthrough only. This type deliberately exposes no MLS,
/// roster, ratchet, or nonzero-protocol behavior.
public actor DAVEPassThroughCodec {
    private let encryptor: DAVEEncryptorStorage
    private let decryptor: DAVEDecryptorStorage

    public init() throws {
        NativeDAVEPrivacy.installDiscardLogSink()
        guard let encryptor = daveEncryptorCreate() else {
            throw NativeMediaError.initializationFailed(component: "libdaveEncryptor")
        }
        guard let decryptor = daveDecryptorCreate() else {
            daveEncryptorDestroy(encryptor)
            throw NativeMediaError.initializationFailed(component: "libdaveDecryptor")
        }
        daveEncryptorSetPassthroughMode(encryptor, true)
        daveDecryptorTransitionToPassthroughMode(decryptor, true)
        self.encryptor = DAVEEncryptorStorage(encryptor)
        self.decryptor = DAVEDecryptorStorage(decryptor)
    }

    public var protocolVersion: UInt16 {
        daveEncryptorGetProtocolVersion(encryptor.raw)
    }

    public var isPassthrough: Bool {
        daveEncryptorIsPassthroughMode(encryptor.raw)
    }

    public func protectOpus(_ frame: Data, ssrc: UInt32) throws -> Data {
        daveEncryptorAssignSsrcToCodec(encryptor.raw, ssrc, DAVE_CODEC_OPUS)
        let capacity = max(
            frame.count,
            daveEncryptorGetMaxCiphertextByteSize(
                encryptor.raw,
                DAVE_MEDIA_TYPE_AUDIO,
                frame.count
            )
        )
        var output = Data(count: capacity)
        var written = 0
        let result = output.withUnsafeMutableBytes { outputBytes in
            frame.withUnsafeBytes { frameBytes in
                daveEncryptorEncrypt(
                    encryptor.raw,
                    DAVE_MEDIA_TYPE_AUDIO,
                    ssrc,
                    frameBytes.bindMemory(to: UInt8.self).baseAddress,
                    frame.count,
                    outputBytes.bindMemory(to: UInt8.self).baseAddress,
                    capacity,
                    &written
                )
            }
        }
        guard result == DAVE_ENCRYPTOR_RESULT_CODE_SUCCESS else {
            throw NativeMediaError.daveFailure(operation: "passthroughProtect", code: result.rawValue)
        }
        output.removeSubrange(written..<output.count)
        return output
    }

    public func unprotectOpus(_ frame: Data) throws -> Data {
        let capacity = max(
            frame.count,
            daveDecryptorGetMaxPlaintextByteSize(
                decryptor.raw,
                DAVE_MEDIA_TYPE_AUDIO,
                frame.count
            )
        )
        var output = Data(count: capacity)
        var written = 0
        let result = output.withUnsafeMutableBytes { outputBytes in
            frame.withUnsafeBytes { frameBytes in
                daveDecryptorDecrypt(
                    decryptor.raw,
                    DAVE_MEDIA_TYPE_AUDIO,
                    frameBytes.bindMemory(to: UInt8.self).baseAddress,
                    frame.count,
                    outputBytes.bindMemory(to: UInt8.self).baseAddress,
                    capacity,
                    &written
                )
            }
        }
        guard result == DAVE_DECRYPTOR_RESULT_CODE_SUCCESS else {
            throw NativeMediaError.daveFailure(operation: "passthroughUnprotect", code: result.rawValue)
        }
        output.removeSubrange(written..<output.count)
        return output
    }
}
