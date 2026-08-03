import CLibDave
import COpus
import CSodium

public enum NativeMediaVersions {
    public static let libdave = "1.1.1"
    public static let libdaveCommit = "52cd56dc550f447fb354b3a06c9e2d2e2a4309c6"
    public static let opus = "1.6.1"
    public static let libsodium = "1.0.22"

    public static var maximumDAVEProtocolVersion: UInt16 {
        daveMaxSupportedProtocolVersion()
    }

    public static var runtimeOpusVersion: String {
        String(cString: opus_get_version_string())
    }

    public static var runtimeSodiumVersion: String {
        String(cString: sodium_version_string())
    }
}
