import CLibDave

private let abbeyDAVEDiscardLogSink: @convention(c) (
    DAVELoggingSeverity,
    UnsafePointer<CChar>?,
    Int32,
    UnsafePointer<CChar>?
) -> Void = { _, _, _, _ in }

/// libdave logging is process-global. Install the privacy sink before creating
/// any handle so group identifiers, roster data, MLS bytes, or media metadata
/// cannot reach stdout/stderr through the native library's default logger.
enum NativeDAVEPrivacy {
    static func installDiscardLogSink() {
        daveSetLogSinkCallback(abbeyDAVEDiscardLogSink)
    }
}
