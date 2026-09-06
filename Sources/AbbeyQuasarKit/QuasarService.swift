import AbbeyCore
import Crypto
import Foundation

public struct QuasarArchiveReceipt: Codable, Equatable, Sendable {
    public var siteID: String
    public var slug: String
    public var archivedAt: String
    /// SHA-256 over a length-framed, path-sorted directory tree. Symlinks and
    /// non-regular filesystem entries are rejected instead of being followed.
    public var contentDigest: String
    public var archiveDigest: String
    public var archiveName: String

    public init(
        siteID: String,
        slug: String,
        archivedAt: String,
        contentDigest: String,
        archiveDigest: String,
        archiveName: String
    ) {
        self.siteID = siteID
        self.slug = slug
        self.archivedAt = archivedAt
        self.contentDigest = contentDigest
        self.archiveDigest = archiveDigest
        self.archiveName = archiveName
    }
}

private struct QuasarArchivedSiteRecord: Codable, Equatable, Sendable {
    var site: Site
    var receipt: QuasarArchiveReceipt
}

public actor QuasarService {
    public let registry: QuasarRegistry
    public let proposals: QuasarProposalGate
    public let coordinator: QuasarGenerationCoordinator
    public let preview: QuasarPreviewManager
    private let planner: QuasarPlanner
    private let executor: QuasarMutationExecutor
    private let scaffolder: QuasarScaffolder
    private let home: URL
    private let sitesRoot: URL
    private let rollbackRoot: URL
    private let archiveRoot: URL
    private var proposalOperations: [UUID: DiscordQuasarRequest] = [:]
    private var consumedGuildBudget: [String: Int] = [:]
    private var isShuttingDown = false

    public init(
        home: URL = QuasarRegistry.defaultHome(),
        planner: QuasarPlanner,
        preview: QuasarPreviewManager = QuasarPreviewManager()
    ) throws {
        self.home = home.standardizedFileURL
        self.sitesRoot = self.home.appendingPathComponent("sites", isDirectory: true)
        self.rollbackRoot = self.home.appendingPathComponent("rollback", isDirectory: true)
        self.archiveRoot = self.home.appendingPathComponent("archive", isDirectory: true)
        self.registry = try QuasarRegistry(home: self.home)
        self.proposals = QuasarProposalGate()
        self.coordinator = QuasarGenerationCoordinator()
        self.preview = preview
        self.planner = planner
        self.executor = QuasarMutationExecutor()
        self.scaffolder = try QuasarScaffolder()
    }

    public func listSites() async -> [Site] { await registry.list() }
    public func site(id: String) async throws -> Site {
        guard let site = await registry.site(id: id) else { throw QuasarError.notFound }
        return site
    }

    @discardableResult
    public func create(name: String, prompt: String, installDependencies: Bool = false) async throws -> Site {
        guard !isShuttingDown else { throw QuasarError.processFailed("Quasar service is shut down") }
        let site = try await registry.reserve(name: name, prompt: prompt)
        let root = siteRoot(site)
        do {
            try scaffolder.scaffold(at: root, installDependencies: installDependencies)
            try await coordinator.start(site: site, prompt: prompt, siteRoot: root, registry: registry, planner: planner, executor: executor)
            return site
        } catch {
            try? archivePartial(root: root, slug: site.slug)
            _ = try? await registry.remove(id: site.id)
            throw error
        }
    }

    @discardableResult
    public func edit(id: String, prompt: String) async throws -> Site {
        guard !isShuttingDown else { throw QuasarError.processFailed("Quasar service is shut down") }
        let site = try await registry.beginEdit(id: id, prompt: prompt)
        do {
            try await coordinator.start(site: site, prompt: prompt, siteRoot: siteRoot(site), registry: registry, planner: planner, executor: executor)
        } catch {
            try? await registry.finish(id: id, error: error.localizedDescription)
            throw error
        }
        return site
    }

    public func pendingPlan(id: String) async throws -> QuasarMutationPreview? {
        _ = try await site(id: id)
        return await coordinator.pending(siteID: id)
    }

    public func approve(id: String, planDigest: String) async throws -> QuasarMutationReceipt {
        let site = try await site(id: id)
        return try await coordinator.approve(
            siteID: id,
            expectedDigest: planDigest,
            siteRoot: siteRoot(site),
            rollbackRoot: rollbackRoot,
            registry: registry,
            executor: executor
        )
    }

    public func reject(id: String) async throws {
        _ = try await site(id: id)
        try await coordinator.reject(siteID: id, registry: registry)
    }

    public func rollback(id: String, planDigest: String) async throws -> QuasarRollbackReceipt {
        let site = try await site(id: id)
        guard site.status == .idle, await coordinator.pending(siteID: id) == nil else {
            throw QuasarError.jobRunning
        }
        return try await executor.rollback(
            planDigest: planDigest,
            siteID: id,
            siteRoot: siteRoot(site),
            rollbackRoot: rollbackRoot
        )
    }

    public func handleDiscord(
        _ request: DiscordQuasarRequest,
        facts: QuasarAuthorizationFacts
    ) async -> String {
        do {
            for id in await proposals.pruneExpired() { proposalOperations[id] = nil }
            guard request.guildID == facts.guildID,
                  request.initiatorID == facts.initiatorID
            else {
                throw QuasarError.authorizationDenied(
                    "request identity does not match the evaluated policy facts"
                )
            }
            guard facts.permitsRead else {
                throw QuasarError.authorizationDenied(
                    "current guild policy facts do not permit Quasar access"
                )
            }
            switch request.action {
            case .list:
                let sites = await registry.list()
                guard !sites.isEmpty else { return "No Quasar sites are registered." }
                return sites.map { "• \($0.name) — `\($0.id)` — \($0.status.rawValue)" }.joined(separator: "\n")
            case .status:
                guard let id = request.siteID else { throw QuasarError.invalidInput("site is required") }
                let value = try await site(id: id)
                let pending = await coordinator.pending(siteID: id)
                return "**\(value.name)** — \(value.status.rawValue)\(pending == nil ? "" : " — mutation plan awaiting desktop approval")"
            case .create, .edit, .archive, .previewStart, .previewStop:
                let action = try proposalAction(request.action)
                let summary = try proposalSummary(request)
                let proposal = try await proposals.propose(
                    action: action,
                    siteID: request.siteID,
                    summary: summary,
                    impact: proposalImpact(action),
                    rollback: proposalRollback(action),
                    facts: effectiveFacts(facts),
                    payloadDigest: requestPayloadDigest(request)
                )
                proposalOperations[proposal.id] = request
                return "Proposal `\(proposal.id.uuidString)` created. Digest `\(proposal.digest)`. It expires at \(proposal.expiresAt.formatted()) and can execute only after exact-fact confirmation in the AbbeyBot desktop app."
            }
        } catch {
            return error.localizedDescription
        }
    }

    public func pendingDiscordProposals() async -> [QuasarProposal] {
        for id in await proposals.pruneExpired() { proposalOperations[id] = nil }
        return await proposals.pending()
    }

    public func approveDiscordProposal(
        id: UUID,
        digest: String,
        revalidated facts: QuasarAuthorizationFacts
    ) async throws -> String {
        var debitedGuild: String?
        do {
            let currentFacts = effectiveFacts(facts)
            let proposal = try await proposals.approve(id: id, digest: digest, revalidated: currentFacts, desktopConfirmed: true)
            guard let request = proposalOperations.removeValue(forKey: id) else { throw QuasarError.proposalChanged }
            consumedGuildBudget[proposal.facts.guildID, default: 0] += 1
            debitedGuild = proposal.facts.guildID
            switch proposal.action {
            case .create:
                guard let name = request.name, let prompt = request.prompt else { throw QuasarError.invalidInput("name and prompt are required") }
                let created = try await create(name: name, prompt: prompt)
                return "Create proposal approved. Site `\(created.id)` is planning; review its mutation digest before writes."
            case .edit:
                guard let siteID = request.siteID, let prompt = request.prompt else { throw QuasarError.invalidInput("site and prompt are required") }
                _ = try await edit(id: siteID, prompt: prompt)
                return "Edit proposal approved. A bounded mutation plan is being prepared for `\(siteID)`."
            case .archive:
                guard let siteID = request.siteID else { throw QuasarError.invalidInput("site is required") }
                let receipt = try await archive(id: siteID)
                return "Archived recoverably. Receipt digest `\(receipt.archiveDigest)`."
            case .previewStart:
                guard let siteID = request.siteID else { throw QuasarError.invalidInput("site is required") }
                let status = try await startPreview(id: siteID)
                return "Preview \(status.state.rawValue) at \(status.url ?? "localhost")."
            case .previewStop:
                guard let siteID = request.siteID else { throw QuasarError.invalidInput("site is required") }
                _ = try await stopPreview(id: siteID)
                return "Preview stopped."
            }
        } catch {
            if let debitedGuild {
                consumedGuildBudget[debitedGuild] = max((consumedGuildBudget[debitedGuild] ?? 1) - 1, 0)
            }
            proposalOperations[id] = nil
            throw error
        }
    }

    public func cancelDiscordProposal(id: UUID) async {
        proposalOperations[id] = nil
        await proposals.cancel(id: id)
    }

    public func events(id: String, since cursor: Int) async throws -> EventPage {
        _ = try await site(id: id)
        return await coordinator.events(siteID: id, since: cursor)
    }

    public func previewStatus(id: String) async throws -> PreviewStatus {
        _ = try await site(id: id)
        return await preview.status(siteID: id)
    }

    public func startPreview(id: String) async throws -> PreviewStatus {
        let site = try await site(id: id)
        guard site.status == .idle, await coordinator.pending(siteID: id) == nil else {
            throw QuasarError.authorizationDenied("approve or reject the pending mutation before preview")
        }
        let used = Set((await registry.list()).compactMap(\.previewPort))
        var port = 4_710
        while used.contains(port), port < 65_535 { port += 1 }
        guard !used.contains(port), port <= 65_535 else {
            throw QuasarError.budgetExceeded("preview ports")
        }
        try await registry.setPreviewPort(id: id, port: port)
        let status = await preview.start(siteID: id, siteRoot: siteRoot(site), port: port)
        if status.state != .running {
            try await registry.clearPreviewPort(id: id, ifMatching: port)
        }
        return status
    }

    public func stopPreview(id: String) async throws -> PreviewStatus {
        _ = try await site(id: id)
        guard await preview.stop(siteID: id) else {
            throw QuasarError.processFailed("preview process did not stop")
        }
        try await registry.setPreviewPort(id: id, port: nil)
        return await preview.status(siteID: id)
    }

    public func archive(id: String) async throws -> QuasarArchiveReceipt {
        let site = try await site(id: id)
        await coordinator.discard(siteID: id)
        guard await preview.stop(siteID: id) else {
            throw QuasarError.processFailed("preview process did not stop; archive stayed in place")
        }
        try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let archiveName = "\(stamp)-\(site.slug)"
        let destination = archiveRoot.appendingPathComponent(archiveName, isDirectory: true)
        let source = siteRoot(site)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw QuasarError.notFound }
        try FileManager.default.moveItem(at: source, to: destination)
        do {
            let contentDigest = try Self.treeDigest(root: destination)
            let digest = Self.archiveDigest(
                siteID: site.id,
                slug: site.slug,
                archivedAt: stamp,
                archiveName: archiveName,
                contentDigest: contentDigest
            )
            let receipt = QuasarArchiveReceipt(
                siteID: site.id,
                slug: site.slug,
                archivedAt: stamp,
                contentDigest: contentDigest,
                archiveDigest: digest,
                archiveName: archiveName
            )
            let record = QuasarArchivedSiteRecord(site: site, receipt: receipt)
            try Self.writeDeterministically(
                record,
                to: archiveRoot.appendingPathComponent("\(archiveName).receipt.json")
            )
            _ = try await registry.remove(id: id)
            return receipt
        } catch {
            if FileManager.default.fileExists(atPath: destination.path),
               !FileManager.default.fileExists(atPath: source.path)
            {
                try? FileManager.default.moveItem(at: destination, to: source)
            }
            try? FileManager.default.removeItem(
                at: archiveRoot.appendingPathComponent("\(archiveName).receipt.json")
            )
            throw error
        }
    }

    /// Restores a recoverably archived site only when the complete detached
    /// receipt and its sidecar record agree. No caller-controlled path is ever
    /// used: the archive name is a bounded basename and every resolved path is
    /// required to remain beneath the Quasar archive root.
    public func restore(_ receipt: QuasarArchiveReceipt) async throws -> Site {
        guard Self.isSafeArchiveName(receipt.archiveName),
              receipt.slug == QuasarSlug.make(receipt.slug),
              Self.isDigest(receipt.contentDigest),
              Self.archiveDigest(
                siteID: receipt.siteID,
                slug: receipt.slug,
                archivedAt: receipt.archivedAt,
                archiveName: receipt.archiveName,
                contentDigest: receipt.contentDigest
              ) == receipt.archiveDigest
        else { throw QuasarError.invalidInput("archive receipt failed verification") }
        let source = archiveRoot.appendingPathComponent(receipt.archiveName, isDirectory: true)
        let sidecar = archiveRoot.appendingPathComponent("\(receipt.archiveName).receipt.json")
        try Self.requireContained(source, by: archiveRoot)
        try Self.requireContained(sidecar, by: archiveRoot)
        guard FileManager.default.fileExists(atPath: source.path),
              FileManager.default.fileExists(atPath: sidecar.path)
        else { throw QuasarError.invalidInput("archive receipt has already been restored or is unavailable") }
        let record = try JSONDecoder().decode(
            QuasarArchivedSiteRecord.self,
            from: Data(contentsOf: sidecar)
        )
        guard record.receipt == receipt,
              record.site.id == receipt.siteID,
              record.site.slug == receipt.slug,
              try Self.treeDigest(root: source) == receipt.contentDigest
        else { throw QuasarError.invalidInput("archive receipt does not match its stored record") }
        let destination = siteRoot(record.site)
        guard !FileManager.default.fileExists(atPath: destination.path)
        else { throw QuasarError.invalidInput("archive is missing or its destination already exists") }
        try FileManager.default.createDirectory(at: sitesRoot, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: destination)
        do {
            let restored = try await registry.restore(record.site)
            try? FileManager.default.removeItem(at: sidecar)
            return restored
        } catch {
            try? FileManager.default.moveItem(at: destination, to: source)
            throw error
        }
    }

    public func shutdown() async {
        isShuttingDown = true
        await coordinator.shutdown(registry: registry)
        await preview.stopAll()
    }

    private func siteRoot(_ site: Site) -> URL { sitesRoot.appendingPathComponent(site.slug, isDirectory: true) }

    private func archivePartial(root: URL, slug: String) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        let destination = archiveRoot.appendingPathComponent("failed-\(UUID().uuidString)-\(slug)", isDirectory: true)
        try FileManager.default.moveItem(at: root, to: destination)
    }

    private static func archiveDigest(
        siteID: String,
        slug: String,
        archivedAt: String,
        archiveName: String,
        contentDigest: String
    ) -> String {
        SHA256.hash(data: Data(
            "\(siteID)|\(slug)|\(archivedAt)|\(archiveName)|\(contentDigest)".utf8
        ))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func treeDigest(root: URL) throws -> String {
        let root = root.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                ],
                options: []
              )
        else { throw QuasarError.invalidInput("archive directory is unavailable") }

        struct Entry {
            var relativePath: String
            var url: URL
            var isDirectory: Bool
            var byteCount: Int
        }
        var entries: [Entry] = []
        for case let url as URL in enumerator {
            guard entries.count < 100_000 else {
                throw QuasarError.budgetExceeded("archive entry count")
            }
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard values.isSymbolicLink != true else {
                enumerator.skipDescendants()
                throw QuasarError.pathRejected("archive contains a symbolic link")
            }
            let relative = String(url.path.dropFirst(root.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relative.isEmpty else { continue }
            if values.isDirectory == true {
                entries.append(.init(
                    relativePath: relative,
                    url: url,
                    isDirectory: true,
                    byteCount: 0
                ))
            } else if values.isRegularFile == true, let size = values.fileSize, size >= 0 {
                entries.append(.init(
                    relativePath: relative,
                    url: url,
                    isDirectory: false,
                    byteCount: size
                ))
            } else {
                throw QuasarError.pathRejected("archive contains a non-regular filesystem entry")
            }
        }

        var hasher = SHA256()
        func updateFrame(_ data: Data) {
            var count = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &count) { hasher.update(data: Data($0)) }
            hasher.update(data: data)
        }
        for entry in entries.sorted(by: { $0.relativePath < $1.relativePath }) {
            hasher.update(data: Data([entry.isDirectory ? 0x44 : 0x46]))
            updateFrame(Data(entry.relativePath.utf8))
            guard !entry.isDirectory else { continue }
            var expected = UInt64(entry.byteCount).bigEndian
            withUnsafeBytes(of: &expected) { hasher.update(data: Data($0)) }
            let handle = try FileHandle(forReadingFrom: entry.url)
            defer { try? handle.close() }
            var readCount = 0
            while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                readCount += chunk.count
                guard readCount <= entry.byteCount else {
                    throw QuasarError.proposalChanged
                }
                hasher.update(data: chunk)
            }
            guard readCount == entry.byteCount else { throw QuasarError.proposalChanged }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isSafeArchiveName(_ value: String) -> Bool {
        guard (1...180).contains(value.utf8.count), value != ".", value != ".." else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "."
        }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func requireContained(_ candidate: URL, by root: URL) throws {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedCandidate.hasPrefix(resolvedRoot) else {
            throw QuasarError.pathRejected("archive path escaped its root")
        }
    }

    private static func writeDeterministically<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func proposalAction(_ action: DiscordQuasarAction) throws -> QuasarProposalAction {
        switch action {
        case .create: return .create
        case .edit: return .edit
        case .archive: return .archive
        case .previewStart: return .previewStart
        case .previewStop: return .previewStop
        case .list, .status: throw QuasarError.invalidInput("read-only actions do not create proposals")
        }
    }

    private func proposalSummary(_ request: DiscordQuasarRequest) throws -> String {
        switch request.action {
        case .create:
            guard let name = request.name, !name.isEmpty, request.prompt?.isEmpty == false else { throw QuasarError.invalidInput("name and prompt are required") }
            return "Create site \(String(name.prefix(60)))"
        case .edit: return "Prepare an edit for site \(request.siteID ?? "missing")"
        case .archive: return "Archive site \(request.siteID ?? "missing")"
        case .previewStart: return "Start preview for site \(request.siteID ?? "missing")"
        case .previewStop: return "Stop preview for site \(request.siteID ?? "missing")"
        case .list, .status: throw QuasarError.invalidInput("read-only actions do not create proposals")
        }
    }

    private func proposalImpact(_ action: QuasarProposalAction) -> String {
        switch action {
        case .create, .edit: return "Starts bounded planning; generated writes still require a second exact-digest desktop approval."
        case .archive: return "Moves the site into the recoverable Quasar archive and stops its preview."
        case .previewStart: return "Launches the pinned local preview process with bounded logs."
        case .previewStop: return "Stops only the selected site's preview process."
        }
    }

    private func proposalRollback(_ action: QuasarProposalAction) -> String {
        switch action {
        case .create, .edit: return "Reject the pending plan; applied plans retain pre-write snapshots."
        case .archive: return "Restore from the receipt-associated archive directory."
        case .previewStart: return "Stop preview."
        case .previewStop: return "Start preview again after reauthorization."
        }
    }

    private func requestPayloadDigest(_ request: DiscordQuasarRequest) -> String {
        let material = [
            request.action.rawValue,
            request.siteID ?? "",
            request.name ?? "",
            request.prompt ?? "",
            request.initiatorID,
            request.guildID,
        ].joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func effectiveFacts(_ facts: QuasarAuthorizationFacts) -> QuasarAuthorizationFacts {
        var adjusted = facts
        adjusted.remainingBudget = max(facts.remainingBudget - (consumedGuildBudget[facts.guildID] ?? 0), 0)
        return adjusted
    }
}
