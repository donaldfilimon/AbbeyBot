import Testing
@testable import AbbeyCLI
import AbbeyServerKit
import Foundation

@Suite("CLISyncPushPlan")
struct CLISyncPushPlanTests {
    @Test func ordersMessagesByCreatedAtAndDropsTombstones() {
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        let plan = CLISyncPushPlan.build(
            messages: [
                (createdAt: newer, discordMessageId: "m2", content: "second", channelId: "c", guildId: "g", authorId: "u", deletedAt: nil),
                (createdAt: older, discordMessageId: "m1", content: "first", channelId: "c", guildId: "g", authorId: "u", deletedAt: nil),
                (createdAt: newer, discordMessageId: "m3", content: "gone", channelId: "c", guildId: "g", authorId: "u", deletedAt: newer)
            ],
            memories: []
        )
        #expect(plan.messages.map(\.discordMessageId) == ["m1", "m2"])
        #expect(plan.facts.isEmpty)
    }

    @Test func expandsFactsInArrayOrderAndSkipsEmpty() {
        let plan = CLISyncPushPlan.build(
            messages: [],
            memories: [
                (
                    updatedAt: Date(timeIntervalSince1970: 50),
                    discordUserId: "u1",
                    guildId: "g1",
                    facts: ["likes tea", "   ", "lives in nyc"],
                    deletedAt: nil
                ),
                (
                    updatedAt: Date(timeIntervalSince1970: 10),
                    discordUserId: "u0",
                    guildId: "g1",
                    facts: ["earlier user"],
                    deletedAt: nil
                ),
                (
                    updatedAt: Date(timeIntervalSince1970: 90),
                    discordUserId: "ghost",
                    guildId: "g1",
                    facts: ["should not push"],
                    deletedAt: Date()
                )
            ]
        )
        #expect(plan.facts == [
            .init(userId: "u0", guildId: "g1", fact: "earlier user"),
            .init(userId: "u1", guildId: "g1", fact: "likes tea"),
            .init(userId: "u1", guildId: "g1", fact: "lives in nyc")
        ])
    }

    @Test func emptyInputsYieldEmptyPlan() {
        let plan = CLISyncPushPlan.build(messages: [], memories: [])
        #expect(plan.messages.isEmpty)
        #expect(plan.facts.isEmpty)
    }

    @Test func tiedTimestampsUseStableIdentifiers() {
        let tied = Date(timeIntervalSince1970: 100)
        let plan = CLISyncPushPlan.build(
            messages: [
                (createdAt: tied, discordMessageId: "m-z", content: "z", channelId: "c", guildId: "g", authorId: "u", deletedAt: nil),
                (createdAt: tied, discordMessageId: "m-a", content: "a", channelId: "c", guildId: "g", authorId: "u", deletedAt: nil)
            ],
            memories: [
                (updatedAt: tied, discordUserId: "u-z", guildId: "g", facts: ["z"], deletedAt: nil),
                (updatedAt: tied, discordUserId: "u-a", guildId: "g", facts: ["a"], deletedAt: nil)
            ]
        )

        #expect(plan.messages.map(\.discordMessageId) == ["m-a", "m-z"])
        #expect(plan.facts.map(\.userId) == ["u-a", "u-z"])
    }

    @Test func streamCursorsMigrateFromLegacyAndAdvanceIndependently() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLISyncPushCursorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SyncCursorFileStore(fileURL: directory.appendingPathComponent("push-cursor"))
        let legacy = Date(timeIntervalSince1970: 100)
        let messageProgress = Date(timeIntervalSince1970: 200)
        let memoryProgress = Date(timeIntervalSince1970: 300)

        try store.saveLastSuccess(legacy)
        #expect(store.loadLastSuccess(for: .messages) == legacy)
        #expect(store.loadLastSuccess(for: .memories) == legacy)

        try store.saveLastSuccess(messageProgress, for: .messages)
        #expect(store.loadLastSuccess(for: .messages) == messageProgress)
        #expect(store.loadLastSuccess(for: .memories) == legacy)

        try store.saveLastSuccess(memoryProgress, for: .memories)
        #expect(store.loadLastSuccess(for: .messages) == messageProgress)
        #expect(store.loadLastSuccess(for: .memories) == memoryProgress)
    }

    @Test func pushesMoreThanLegacyLimitAndResumesFailedStreamWithoutReplayingSuccessfulFacts() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLISyncPushResumeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SyncCursorFileStore(fileURL: directory.appendingPathComponent("push-cursor"))
        let rowTimestamp = Date(timeIntervalSince1970: 100)
        let firstStartedAt = Date(timeIntervalSince1970: 1_000)
        let secondStartedAt = Date(timeIntervalSince1970: 2_000)
        let messageRows: [CLISyncPushPlan.MessageRow] = (0..<501).map { index in
            (
                createdAt: rowTimestamp,
                discordMessageId: "m-\(index)",
                content: "message \(index)",
                channelId: "c",
                guildId: "g",
                authorId: "u",
                deletedAt: nil
            )
        }
        let memoryRows: [CLISyncPushPlan.MemoryRow] = [
            (updatedAt: rowTimestamp, discordUserId: "u", guildId: "g", facts: ["one fact"], deletedAt: nil)
        ]
        let source = CLISyncPush.Source(
            messages: { since in
                messageRows.filter { row in
                    guard let since else { return true }
                    return (row.createdAt ?? .distantPast) >= since
                }
            },
            memories: { since in
                memoryRows.filter { row in
                    guard let since else { return true }
                    return (row.updatedAt ?? .distantPast) >= since
                }
            }
        )
        let recorder = PushRecorder(failMessageOnce: "m-250")
        let sink = CLISyncPush.Sink(
            baseURL: "https://sync.test",
            pushMessage: { payload in try await recorder.pushMessage(payload) },
            pushFact: { payload in await recorder.pushFact(payload) }
        )

        _ = await CLISyncPush.execute(
            source: source,
            sink: sink,
            cursorStore: store,
            startedAt: firstStartedAt
        )

        #expect(store.loadLastSuccess(for: .messages) == nil)
        #expect(store.loadLastSuccess(for: .memories) == firstStartedAt)
        let afterFailure = await recorder.snapshot()
        #expect(afterFailure.uniqueMessages.count < 501)
        #expect(afterFailure.facts == ["one fact"])

        _ = await CLISyncPush.execute(
            source: source,
            sink: sink,
            cursorStore: store,
            startedAt: secondStartedAt
        )

        let afterResume = await recorder.snapshot()
        #expect(afterResume.uniqueMessages.count == 501)
        #expect(afterResume.facts == ["one fact"])
        #expect(store.loadLastSuccess(for: .messages) == secondStartedAt)
        #expect(store.loadLastSuccess(for: .memories) == secondStartedAt)
    }
}

private struct InjectedPushFailure: Error, LocalizedError {
    var errorDescription: String? { "injected push failure" }
}

private actor PushRecorder {
    struct Snapshot: Sendable {
        var uniqueMessages: Set<String>
        var facts: [String]
    }

    private let failMessageOnce: String
    private var didFail = false
    private var messageIds: Set<String> = []
    private var facts: [String] = []

    init(failMessageOnce: String) {
        self.failMessageOnce = failMessageOnce
    }

    func pushMessage(_ payload: CLISyncPushPlan.MessagePayload) throws -> Bool {
        if payload.discordMessageId == failMessageOnce, !didFail {
            didFail = true
            throw InjectedPushFailure()
        }
        messageIds.insert(payload.discordMessageId)
        return false
    }

    func pushFact(_ payload: CLISyncPushPlan.FactPayload) {
        facts.append(payload.fact)
    }

    func snapshot() -> Snapshot {
        Snapshot(uniqueMessages: messageIds, facts: facts)
    }
}
