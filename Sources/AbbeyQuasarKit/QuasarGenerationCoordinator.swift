import AbbeyCore
import Foundation

public struct QuasarPlanner: Sendable {
    public var readPlan: @Sendable (_ prompt: String, _ files: [String]) async throws -> QuasarReadPlan
    public var mutationPlan: @Sendable (_ prompt: String, _ approvedFiles: [String: String]) async throws -> QuasarMutationPlan

    public init(
        readPlan: @escaping @Sendable (_ prompt: String, _ files: [String]) async throws -> QuasarReadPlan,
        mutationPlan: @escaping @Sendable (_ prompt: String, _ approvedFiles: [String: String]) async throws -> QuasarMutationPlan
    ) {
        self.readPlan = readPlan; self.mutationPlan = mutationPlan
    }

    public static func abbey(router: InferenceRouter) -> Self {
        Self(
            readPlan: { prompt, files in
                let schema = #"{"type":"object","required":["paths"],"properties":{"paths":{"type":"array","maxItems":24,"items":{"type":"string"}}}}"#
                let response = try await router.generateStructured(.init(
                    request: .init(systemPrompt: "You are Quasar's bounded read planner. Select only files necessary for the requested website change.", userText: prompt, contextLines: files),
                    jsonSchema: schema,
                    maximumOutputBytes: 32_768
                ))
                return try JSONDecoder().decode(QuasarReadPlan.self, from: response.json)
            },
            mutationPlan: { prompt, files in
                let schema = #"{"type":"object","required":["summary","operations","idempotencyKey"],"properties":{"summary":{"type":"string"},"idempotencyKey":{"type":"string"},"operations":{"type":"array","maxItems":32,"items":{"type":"object","required":["type","path"],"properties":{"type":{"enum":["write","remove"]},"path":{"type":"string"},"content":{"type":"string"}}}}}}"#
                let context = files.keys.sorted().map { path in "FILE \(path)\n\(files[path] ?? "")" }
                let response = try await router.generateStructured(.init(
                    request: .init(systemPrompt: "You are Quasar's bounded mutation planner. Return complete file writes only; never request shell or network access.", userText: prompt, contextLines: context),
                    jsonSchema: schema
                ))
                return try JSONDecoder().decode(QuasarMutationPlan.self, from: response.json)
            }
        )
    }
}

public actor QuasarGenerationCoordinator {
    private struct Prepared: Sendable {
        var plan: QuasarMutationPlan
        var review: QuasarPlanReview
    }
    private struct Job {
        var generationID: UUID
        var task: Task<Void, Never>?
        var events: [GenerationEvent]
        var baseCursor: Int
        var prepared: Prepared?
        var applying: Bool
    }
    private var jobs: [String: Job] = [:]
    private var isShuttingDown = false
    private let maximumEvents: Int

    public init(maximumEvents: Int = 512) { self.maximumEvents = min(max(maximumEvents, 8), 2_048) }

    public func start(
        site: Site,
        prompt: String,
        siteRoot: URL,
        registry: QuasarRegistry,
        planner: QuasarPlanner,
        executor: QuasarMutationExecutor
    ) throws {
        guard !isShuttingDown else { throw QuasarError.processFailed("generation coordinator is shut down") }
        if let current = jobs[site.id], current.task != nil || current.prepared != nil || current.applying {
            throw QuasarError.jobRunning
        }
        let generationID = UUID()
        jobs[site.id] = Job(
            generationID: generationID,
            task: nil,
            events: jobs[site.id]?.events ?? [],
            baseCursor: jobs[site.id]?.baseCursor ?? 0,
            prepared: nil,
            applying: false
        )
        let task = Task { [weak self] in
            do {
                let guarder = try QuasarPathGuard(root: siteRoot)
                let files = try guarder.list()
                await self?.emit(.tool(.listFiles), siteID: site.id, generationID: generationID)
                let readPlan = try await planner.readPlan(prompt, files)
                try Task.checkCancellation()
                guard readPlan.paths.count <= 24 else { throw QuasarError.budgetExceeded("read plan") }
                var approved: [String: String] = [:]
                for path in readPlan.paths {
                    try Task.checkCancellation()
                    approved[path] = try guarder.read(path)
                    await self?.emit(.tool(.readFile, path: path), siteID: site.id, generationID: generationID)
                }
                try Task.checkCancellation()
                let mutation = try await planner.mutationPlan(prompt, approved)
                try Task.checkCancellation()
                let review = try await executor.review(
                    mutation,
                    siteID: site.id,
                    generationID: generationID.uuidString,
                    siteRoot: siteRoot
                )
                try Task.checkCancellation()
                await self?.storePrepared(.init(plan: mutation, review: review), siteID: site.id, generationID: generationID)
                await self?.emit(.plan(review.planDigest), siteID: site.id, generationID: generationID)
            } catch is CancellationError {
                await self?.failGeneration(
                    "generation cancelled",
                    siteID: site.id,
                    generationID: generationID,
                    registry: registry
                )
            } catch {
                await self?.failGeneration(
                    error.localizedDescription,
                    siteID: site.id,
                    generationID: generationID,
                    registry: registry
                )
            }
            await self?.clearTask(siteID: site.id, generationID: generationID)
        }
        jobs[site.id]?.task = task
    }

    public func pending(siteID: String) -> QuasarMutationPreview? { jobs[siteID]?.prepared?.review.preview }

    public func pendingReview(siteID: String) -> QuasarPlanReview? { jobs[siteID]?.prepared?.review }

    public func approve(
        siteID: String,
        expectedDigest: String,
        siteRoot: URL,
        rollbackRoot: URL,
        registry: QuasarRegistry,
        executor: QuasarMutationExecutor,
        now: Date = Date()
    ) async throws -> QuasarMutationReceipt {
        guard var job = jobs[siteID], let prepared = job.prepared else { throw QuasarError.notFound }
        guard !job.applying else { throw QuasarError.jobRunning }
        guard prepared.review.planDigest == expectedDigest else {
            job.prepared = nil
            jobs[siteID] = job
            try await registry.finish(id: siteID, error: "mutation digest changed; prepare a new plan")
            throw QuasarError.proposalChanged
        }
        guard now < prepared.review.expiresAt else {
            job.prepared = nil
            jobs[siteID] = job
            try await registry.finish(id: siteID, error: "mutation approval expired")
            throw QuasarError.proposalExpired
        }
        job.applying = true
        jobs[siteID] = job
        do {
            let receipt = try await executor.apply(
                prepared.plan,
                approvedReview: prepared.review,
                to: siteRoot,
                rollbackRoot: rollbackRoot,
                now: now
            )
            for path in receipt.changedPaths { emit(.tool(.writeFile, path: path), siteID: siteID) }
            emit(.text(prepared.plan.summary), siteID: siteID)
            try await registry.finish(id: siteID)
            if var completed = jobs[siteID] {
                completed.prepared = nil
                completed.applying = false
                jobs[siteID] = completed
            }
            emit(.done, siteID: siteID)
            return receipt
        } catch {
            if var failed = jobs[siteID] {
                failed.prepared = nil
                failed.applying = false
                jobs[siteID] = failed
            }
            try? await registry.finish(id: siteID, error: error.localizedDescription)
            emit(.error(error.localizedDescription), siteID: siteID)
            throw error
        }
    }

    public func reject(siteID: String, registry: QuasarRegistry) async throws {
        guard var job = jobs[siteID], job.prepared != nil || job.task != nil else { throw QuasarError.notFound }
        job.task?.cancel()
        job.generationID = UUID()
        job.task = nil
        job.prepared = nil
        jobs[siteID] = job
        try await registry.finish(id: siteID, error: "mutation rejected by operator")
        emit(.error("mutation rejected by operator"), siteID: siteID)
    }

    public func cancel(siteID: String) { jobs[siteID]?.task?.cancel() }

    /// Invalidate before suspending. Planners may ignore cancellation, so shutdown
    /// must not wait for them or let their eventual completion publish a plan.
    /// Already-approved applications retain their existing completion contract.
    @discardableResult
    func shutdown(registry: QuasarRegistry) async -> [Task<Void, Never>] {
        isShuttingDown = true
        let interrupted = jobs
        jobs.removeAll()
        let tasks = interrupted.values.compactMap(\.task)
        for task in tasks { task.cancel() }
        for (siteID, job) in interrupted where !job.applying && (job.task != nil || job.prepared != nil) {
            try? await registry.finish(
                id: siteID,
                error: "generation interrupted by shutdown; prepare and approve a new plan"
            )
        }
        return tasks
    }

    /// Cancels and removes all in-memory state for a site that is leaving the
    /// active registry. This prevents archived sites from retaining mutation
    /// payloads or event history in the long-lived coordinator.
    public func discard(siteID: String) {
        jobs[siteID]?.task?.cancel()
        jobs[siteID] = nil
    }

    public func events(siteID: String, since cursor: Int) -> EventPage {
        let all = jobs[siteID]?.events ?? []
        let base = jobs[siteID]?.baseCursor ?? 0
        let relative = min(max(cursor - base, 0), all.count)
        return EventPage(events: Array(all[relative...]), next: base + all.count)
    }

    private func storePrepared(_ prepared: Prepared, siteID: String, generationID: UUID) {
        guard jobs[siteID]?.generationID == generationID else { return }
        jobs[siteID]?.prepared = prepared
    }

    private func clearTask(siteID: String, generationID: UUID) {
        guard jobs[siteID]?.generationID == generationID else { return }
        jobs[siteID]?.task = nil
    }

    private func failGeneration(
        _ message: String,
        siteID: String,
        generationID: UUID,
        registry: QuasarRegistry
    ) async {
        guard jobs[siteID]?.generationID == generationID else { return }
        try? await registry.finish(id: siteID, error: message)
        guard jobs[siteID]?.generationID == generationID else { return }
        emit(.error(message), siteID: siteID, generationID: generationID)
    }

    private func emit(_ event: GenerationEvent, siteID: String, generationID: UUID? = nil) {
        guard var job = jobs[siteID] else { return }
        if let generationID, job.generationID != generationID { return }
        job.events.append(event)
        if job.events.count > maximumEvents {
            let removed = job.events.count - maximumEvents
            job.events.removeFirst(removed)
            job.baseCursor += removed
        }
        jobs[siteID] = job
    }
}
