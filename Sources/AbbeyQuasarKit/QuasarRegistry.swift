import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public actor QuasarRegistry {
    private static let maximumSites = 10_000
    private static let maximumPromptHistoryEntries = 256
    public let home: URL
    private let registryURL: URL
    private let lockDescriptor: Int32
    private var sites: [Site]

    public init(home: URL = QuasarRegistry.defaultHome()) throws {
        self.home = home.standardizedFileURL
        self.registryURL = self.home.appendingPathComponent("registry.json")
        try FileManager.default.createDirectory(at: self.home, withIntermediateDirectories: true)
        let lockURL = self.home.appendingPathComponent(".writer.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw QuasarError.registryLocked }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw QuasarError.registryLocked
        }
        self.lockDescriptor = descriptor
        self.sites = try Self.loadRecovering(home: self.home, registryURL: self.registryURL)
    }

    deinit {
        flock(lockDescriptor, LOCK_UN)
        close(lockDescriptor)
    }

    public static func defaultHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["ABBEY_QUASAR_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".quasar", isDirectory: true)
    }

    public func list() -> [Site] { sites }
    public func site(id: String) -> Site? { sites.first { $0.id == id } }

    public func reserve(name: String, prompt: String) throws -> Site {
        guard sites.count < Self.maximumSites else {
            throw QuasarError.budgetExceeded("registered site count")
        }
        let request = try CreateSiteRequest(name: name, prompt: prompt).validated()
        let existing = Set(sites.map(\.slug))
        let base = QuasarSlug.make(request.name)
        var slug = base
        var suffix = 2
        while existing.contains(slug) { slug = "\(base)-\(suffix)"; suffix += 1 }
        let now = ISO8601DateFormatter().string(from: Date())
        let site = Site(name: request.name, slug: slug, status: .generating, promptHistory: [.init(prompt: request.prompt, at: now)])
        var updated = sites
        updated.append(site)
        try commit(updated)
        return site
    }

    public func beginEdit(id: String, prompt rawPrompt: String) throws -> Site {
        guard let index = sites.firstIndex(where: { $0.id == id }) else { throw QuasarError.notFound }
        guard sites[index].status != .generating else { throw QuasarError.jobRunning }
        guard sites[index].promptHistory.count < Self.maximumPromptHistoryEntries else {
            throw QuasarError.budgetExceeded("prompt history")
        }
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...4_000).contains(prompt.count) else { throw QuasarError.invalidInput("prompt must contain 1...4000 characters") }
        var updated = sites
        updated[index].status = .generating
        updated[index].promptHistory.append(.init(prompt: prompt, at: ISO8601DateFormatter().string(from: Date())))
        try commit(updated)
        return updated[index]
    }

    public func finish(id: String, error: String? = nil) throws {
        guard let index = sites.firstIndex(where: { $0.id == id }) else { return }
        var updated = sites
        updated[index].status = error == nil ? .idle : .error
        updated[index].lastError = error
        try commit(updated)
    }

    public func setPreviewPort(id: String, port: Int?) throws {
        guard let index = sites.firstIndex(where: { $0.id == id }) else { throw QuasarError.notFound }
        if let port {
            guard (1_024...65_535).contains(port) else {
                throw QuasarError.invalidInput("preview port must be in 1024...65535")
            }
            guard !sites.contains(where: { $0.id != id && $0.previewPort == port }) else {
                throw QuasarError.invalidInput("preview port is already reserved")
            }
        }
        var updated = sites
        updated[index].previewPort = port
        try commit(updated)
    }

    /// Compare-and-clear for a preview start that completed after another
    /// operation changed the site's reservation. A stale start must never
    /// erase the newer port.
    public func clearPreviewPort(id: String, ifMatching expectedPort: Int) throws {
        guard let index = sites.firstIndex(where: { $0.id == id }),
              sites[index].previewPort == expectedPort
        else { return }
        var updated = sites
        updated[index].previewPort = nil
        try commit(updated)
    }

    public func remove(id: String) throws -> Site {
        guard let index = sites.firstIndex(where: { $0.id == id }) else { throw QuasarError.notFound }
        var updated = sites
        let removed = updated.remove(at: index)
        try commit(updated)
        return removed
    }

    /// Reinstates the exact content-free registry record carried by a verified
    /// archive receipt. Callers must first verify and restore the corresponding
    /// site directory; the registry still independently rejects identity or
    /// slug collisions so a receipt can never overwrite a live site.
    public func restore(_ archived: Site) throws -> Site {
        guard !sites.contains(where: { $0.id == archived.id || $0.slug == archived.slug }) else {
            throw QuasarError.invalidInput("an active site already uses this archive identity")
        }
        var restored = archived
        restored.status = .idle
        restored.previewPort = nil
        restored.lastError = nil
        try Self.validateSite(restored)
        var updated = sites
        updated.append(restored)
        try commit(updated)
        return restored
    }

    private func commit(_ updated: [Site]) throws {
        let previous = sites
        sites = updated
        do {
            try persist()
        } catch {
            sites = previous
            throw error
        }
    }

    private func persist() throws {
        try Self.validateSites(sites)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(sites)
        let temporary = home.appendingPathComponent("registry.json.tmp")
        try data.write(to: temporary, options: .atomic)
        guard rename(temporary.path, registryURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let directory = open(home.path, O_RDONLY)
        if directory >= 0 { _ = fsync(directory); close(directory) }
    }

    private static func loadRecovering(home: URL, registryURL: URL) throws -> [Site] {
        let decoder = JSONDecoder()
        if let decoded = try? decodeValidated(registryURL, decoder: decoder) {
            return decoded
        }
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsSubdirectoryDescendants]
        ))?.filter { $0.lastPathComponent.hasPrefix("registry") && $0.pathExtension == "tmp" }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs > rhs
            } ?? []
        for candidate in candidates {
            guard let data = try? Data(contentsOf: candidate),
                  let decoded = try? decoder.decode([Site].self, from: data),
                  (try? validateSites(decoded)) != nil
            else { continue }
            try data.write(to: registryURL, options: .atomic)
            return decoded
        }
        if FileManager.default.fileExists(atPath: registryURL.path) {
            return try decodeValidated(registryURL, decoder: decoder)
        }
        return []
    }

    private static func decodeValidated(_ url: URL, decoder: JSONDecoder) throws -> [Site] {
        let decoded = try decoder.decode([Site].self, from: Data(contentsOf: url))
        try validateSites(decoded)
        return decoded
    }

    private static func validateSites(_ values: [Site]) throws {
        guard values.count <= maximumSites else {
            throw QuasarError.budgetExceeded("registered site count")
        }
        var ids = Set<String>()
        var slugs = Set<String>()
        var ports = Set<Int>()
        for site in values {
            try validateSite(site)
            guard ids.insert(site.id).inserted else {
                throw QuasarError.invalidInput("registry contains a duplicate site identity")
            }
            guard slugs.insert(site.slug).inserted else {
                throw QuasarError.invalidInput("registry contains a duplicate site slug")
            }
            if let port = site.previewPort, !ports.insert(port).inserted {
                throw QuasarError.invalidInput("registry contains a duplicate preview port")
            }
        }
    }

    private static func validateSite(_ site: Site) throws {
        guard isSafeIdentifier(site.id, maximum: 128) else {
            throw QuasarError.invalidInput("registry site identity is invalid")
        }
        let name = site.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name == site.name,
              (1...60).contains(name.count),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw QuasarError.invalidInput("registry site name is invalid") }
        guard (1...80).contains(site.slug.utf8.count),
              site.slug == QuasarSlug.make(site.slug)
        else { throw QuasarError.invalidInput("registry site slug is invalid") }
        guard site.createdAt.utf8.count <= 64,
              ISO8601DateFormatter().date(from: site.createdAt) != nil
        else { throw QuasarError.invalidInput("registry creation timestamp is invalid") }
        if let port = site.previewPort, !(1_024...65_535).contains(port) {
            throw QuasarError.invalidInput("registry preview port is invalid")
        }
        guard site.promptHistory.count <= maximumPromptHistoryEntries else {
            throw QuasarError.budgetExceeded("prompt history")
        }
        for entry in site.promptHistory {
            guard (1...4_000).contains(entry.prompt.count),
                  entry.at.utf8.count <= 64,
                  ISO8601DateFormatter().date(from: entry.at) != nil
            else { throw QuasarError.invalidInput("registry prompt history is invalid") }
        }
        if let lastError = site.lastError, lastError.utf8.count > 8_192 {
            throw QuasarError.invalidInput("registry error text is too large")
        }
    }

    private static func isSafeIdentifier(_ value: String, maximum: Int) -> Bool {
        (1...maximum).contains(value.utf8.count)
            && value.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".")
            }
    }
}
