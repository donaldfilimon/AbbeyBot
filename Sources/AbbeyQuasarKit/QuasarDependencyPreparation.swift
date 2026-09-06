import Crypto
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

struct QuasarPreviewRuntimeDirectories: Sendable {
    var home: URL
    var temporary: URL
    var cache: URL
}

enum QuasarPreviewRuntime {
    static func prepare(siteRoot: URL) throws -> QuasarPreviewRuntimeDirectories {
        let root = siteRoot.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw QuasarError.invalidInput("preview site root is unavailable")
        }
        let runtime = root.appendingPathComponent(".quasar-runtime", isDirectory: true)
        let home = runtime.appendingPathComponent("home", isDirectory: true)
        let temporary = runtime.appendingPathComponent("tmp", isDirectory: true)
        let cache = runtime.appendingPathComponent("cache", isDirectory: true)
        for directory in [runtime, home, temporary, cache] {
            if FileManager.default.fileExists(atPath: directory.path) {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true,
                      directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path
                else { throw QuasarError.pathRejected("preview runtime directory is not site-local") }
            } else {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        return .init(home: home, temporary: temporary, cache: cache)
    }
}

public struct QuasarDependencyFingerprint: Codable, Equatable, Sendable {
    public var packageJSONSHA256: String
    public var bunLockSHA256: String

    public init(packageJSONSHA256: String, bunLockSHA256: String) {
        self.packageJSONSHA256 = packageJSONSHA256
        self.bunLockSHA256 = bunLockSHA256
    }

    public static func capture(siteRoot: URL) throws -> Self {
        try capture(siteRoot: siteRoot, applying: [])
    }

    /// Computes the dependency inputs the operator is reviewing, including
    /// writes in a pending plan that have not reached disk yet.
    public static func capture(
        siteRoot: URL,
        applying operations: [QuasarMutationOperation]
    ) throws -> Self {
        let root = try checkedRoot(siteRoot)
        var package = try dependencyData(named: "package.json", root: root)
        var lock = try dependencyData(named: "bun.lock", root: root)
        for operation in operations {
            switch operation {
            case .write("package.json", let content): package = Data(content.utf8)
            case .write("bun.lock", let content): lock = Data(content.utf8)
            case .remove("package.json"), .remove("bun.lock"):
                throw QuasarError.malformedPlan("preview dependencies require package.json and bun.lock")
            default: continue
            }
        }
        guard !package.isEmpty, !lock.isEmpty,
              package.count <= 1_048_576, lock.count <= 8_388_608
        else { throw QuasarError.invalidInput("preview dependency inputs are empty or oversized") }
        return .init(packageJSONSHA256: sha256(package), bunLockSHA256: sha256(lock))
    }

    private static func checkedRoot(_ url: URL) throws -> URL {
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw QuasarError.invalidInput("preview site root is unavailable")
        }
        return root
    }

    private static func dependencyData(named name: String, root: URL) throws -> Data {
        let candidate = root.appendingPathComponent(name, isDirectory: false)
        let resolved = candidate.resolvingSymlinksInPath()
        guard resolved.deletingLastPathComponent() == root else {
            throw QuasarError.pathRejected("preview dependency input escapes the site root")
        }
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw QuasarError.invalidInput("preview dependency input \(name) is unavailable")
        }
        return try Data(contentsOf: resolved, options: [.mappedIfSafe])
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct QuasarDependencyPreparation: Codable, Equatable, Sendable {
    public var siteID: String
    public var generation: String
    public var fingerprint: QuasarDependencyFingerprint
    public var preparedAt: Date
    public var nextEntryPoint: String

    public init(
        siteID: String,
        generation: String,
        fingerprint: QuasarDependencyFingerprint,
        preparedAt: Date,
        nextEntryPoint: String = "node_modules/next/dist/bin/next"
    ) {
        self.siteID = siteID
        self.generation = generation
        self.fingerprint = fingerprint
        self.preparedAt = preparedAt
        self.nextEntryPoint = nextEntryPoint
    }
}

public actor QuasarDependencyPreparer {
    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ next: Data) {
            guard !next.isEmpty else { return }
            lock.lock(); defer { lock.unlock() }
            data.append(next)
            if data.count > 16_384 { data = data.suffix(16_384) }
        }

        func lines() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return QuasarPreviewManager.lines(String(decoding: data, as: UTF8.self))
        }
    }

    public static let nextEntryPoint = "node_modules/next/dist/bin/next"
    private let bunExecutableURL: URL
    private let timeout: Duration
    private let inheritedEnvironment: [String: String]

    public init(
        bunExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/env"),
        timeout: Duration = .seconds(300),
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.bunExecutableURL = bunExecutableURL
        self.timeout = min(max(timeout, .seconds(1)), .seconds(900))
        self.inheritedEnvironment = inheritedEnvironment
    }

    public func prepare(
        siteID: String,
        generation: String,
        siteRoot: URL,
        reviewedFingerprint: QuasarDependencyFingerprint,
        now: Date = Date()
    ) async throws -> QuasarDependencyPreparation {
        guard Self.isIdentifier(siteID), Self.isIdentifier(generation) else {
            throw QuasarError.invalidInput("preview site and generation identifiers are invalid")
        }
        let root = siteRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard try QuasarDependencyFingerprint.capture(siteRoot: root) == reviewedFingerprint else {
            throw QuasarError.proposalChanged
        }
        let runtime = try QuasarPreviewRuntime.prepare(siteRoot: root)

        let process = Process()
        process.executableURL = bunExecutableURL
        process.arguments = bunExecutableURL.path == "/usr/bin/env"
            ? ["bun", "install", "--frozen-lockfile", "--ignore-scripts"]
            : ["install", "--frozen-lockfile", "--ignore-scripts"]
        process.currentDirectoryURL = root
        process.environment = Self.environment(
            inherited: inheritedEnvironment,
            home: runtime.home,
            temporary: runtime.temporary,
            cache: runtime.cache
        )
        process.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe()
        let output = OutputBuffer()
        outputPipe.fileHandleForReading.readabilityHandler = { output.append($0.availableData) }
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        do { try process.run() }
        catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            throw QuasarError.processFailed("dependency preparation could not launch Bun")
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while process.isRunning, clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(25))
        }
        let completed = !process.isRunning
        if !completed {
            process.terminate()
            for _ in 0..<20 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if process.isRunning { Self.killExact(process.processIdentifier) }
            for _ in 0..<40 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        outputPipe.fileHandleForReading.readabilityHandler = nil
        if Task.isCancelled { throw CancellationError() }
        guard completed else {
            throw QuasarError.processFailed("dependency preparation exceeded its time limit")
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let detail = output.lines().suffix(5).joined(separator: " | ")
            throw QuasarError.processFailed(detail.isEmpty ? "Bun install failed" : "Bun install failed: \(detail)")
        }
        guard try QuasarDependencyFingerprint.capture(siteRoot: root) == reviewedFingerprint else {
            throw QuasarError.proposalChanged
        }
        try Self.validateNextEntry(root: root)
        return .init(
            siteID: siteID,
            generation: generation,
            fingerprint: reviewedFingerprint,
            preparedAt: now,
            nextEntryPoint: Self.nextEntryPoint
        )
    }

    private static func environment(
        inherited: [String: String],
        home: URL,
        temporary: URL,
        cache: URL
    ) -> [String: String] {
        var result: [String: String] = [
            "HOME": home.path,
            "TMPDIR": temporary.path,
            "XDG_CACHE_HOME": cache.path,
            "BUN_INSTALL_CACHE_DIR": cache.path,
            "CI": "1",
            "NO_COLOR": "1",
        ]
        for key in ["PATH", "LANG", "LC_ALL", "SSL_CERT_FILE", "SSL_CERT_DIR"] {
            if let value = inherited[key], !value.isEmpty { result[key] = value }
        }
        return result
    }

    private static func validateNextEntry(root: URL) throws {
        let entry = root.appendingPathComponent(nextEntryPoint).resolvingSymlinksInPath()
        guard entry.path.hasPrefix(root.path + "/") else {
            throw QuasarError.pathRejected("installed Next entry point escapes the site root")
        }
        let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
            throw QuasarError.processFailed("installed Next entry point is missing")
        }
    }

    private static func isIdentifier(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count)
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    private nonisolated static func killExact(_ processID: Int32) {
        guard processID > 1 else { return }
        #if canImport(Darwin)
        _ = Darwin.kill(processID, SIGKILL)
        #elseif canImport(Glibc)
        _ = Glibc.kill(processID, SIGKILL)
        #elseif canImport(Musl)
        _ = Musl.kill(processID, SIGKILL)
        #endif
    }
}
