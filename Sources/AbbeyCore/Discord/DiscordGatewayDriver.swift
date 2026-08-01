import DiscordBM

private enum DiscordBMGatewayDriverFailure: Error, Sendable {
    case eventFailure
}

actor DiscordGatewayEventBarrier {
    private var resolved = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if resolved { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func resolve() {
        guard !resolved else { return }
        resolved = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
    }
}

enum DiscordGatewayDriverEvent: Sendable {
    case gateway(Gateway.Event)
    case barrier(DiscordGatewayEventBarrier)
}

enum DiscordGatewayEventStreamMerger {
    static func merge(
        events: AsyncStream<DiscordGatewayDriverEvent>,
        failures: AsyncStream<Void>
    ) -> AsyncThrowingStream<DiscordGatewayDriverEvent, any Error> {
        AsyncThrowingStream { continuation in
            let eventsTask = Task {
                for await event in events {
                    guard !Task.isCancelled else { return }
                    continuation.yield(event)
                }
                guard !Task.isCancelled else { return }
                continuation.finish()
            }
            let failuresTask = Task {
                for await _ in failures {
                    guard !Task.isCancelled else { return }
                    continuation.finish(throwing: DiscordBMGatewayDriverFailure.eventFailure)
                    return
                }
            }
            continuation.onTermination = { @Sendable _ in
                eventsTask.cancel()
                failuresTask.cancel()
            }
        }
    }
}

actor DiscordConnectionOperationCoordinator {
    enum Phase: Equatable, Sendable {
        case idle
        case connecting
        case connected
        case disconnecting
        case disconnected
    }

    private enum State {
        case idle
        case connecting(Task<Void, Never>)
        case connected
        case disconnecting(Task<Void, Never>)
        case disconnected
    }

    private var state: State = .idle

    var phase: Phase {
        switch state {
        case .idle: .idle
        case .connecting: .connecting
        case .connected: .connected
        case .disconnecting: .disconnecting
        case .disconnected: .disconnected
        }
    }

    var hasActiveOperation: Bool {
        switch state {
        case .connecting, .disconnecting: true
        case .idle, .connected, .disconnected: false
        }
    }

    func connect(_ operation: @escaping @Sendable () async -> Void) async {
        let task: Task<Void, Never>
        switch state {
        case .idle:
            task = Task { await operation() }
            state = .connecting(task)
        case .connecting(let current):
            task = current
        case .connected, .disconnecting, .disconnected:
            return
        }

        await task.value
        guard case .connecting = state else { return }
        state = .connected
    }

    func disconnect(_ operation: @escaping @Sendable () async -> Void) async {
        let task: Task<Void, Never>
        switch state {
        case .disconnecting(let current):
            task = current
        case .disconnected:
            return
        case .connecting(let connectTask):
            task = Task {
                await connectTask.value
                await operation()
            }
            state = .disconnecting(task)
        case .idle, .connected:
            task = Task { await operation() }
            state = .disconnecting(task)
        }

        await task.value
        guard case .disconnecting = state else { return }
        state = .disconnected
    }
}

/// Internal transport boundary around DiscordBM's gateway manager. The bridge
/// owns lifecycle authority; a driver's `connect()` return only means that the
/// manager started its work, never that Discord sent READY.
protocol DiscordGatewayDriver: Sendable {
    var client: (any DiscordClient)? { get }

    func makeEvents() async -> AsyncThrowingStream<DiscordGatewayDriverEvent, any Error>
    func connect() async
    func disconnect() async
    func updateVoiceState(payload: VoiceStateUpdate) async
}

struct DiscordGatewayDriverConfiguration: Sendable {
    let token: String
    let presenceActivityName: String
}

typealias DiscordGatewayDriverFactory = @Sendable (
    DiscordGatewayDriverConfiguration
) async -> any DiscordGatewayDriver

/// Production adapter. It deliberately forwards DiscordBM's nonthrowing event
/// sequence through the throwing driver boundary so deterministic test drivers
/// can also model a transport failure.
actor DiscordBMGatewayDriver: DiscordGatewayDriver {
    nonisolated let client: (any DiscordClient)?
    private let manager: BotGatewayManager
    private let connectionOperations = DiscordConnectionOperationCoordinator()

    init(configuration: DiscordGatewayDriverConfiguration) async {
        let manager = await BotGatewayManager(
            token: configuration.token,
            presence: .init(
                activities: [.init(name: configuration.presenceActivityName, type: .listening)],
                status: .online,
                afk: false
            ),
            intents: [
                .guildMessages,
                .messageContent,
                .guildMembers,
                .directMessages,
                .guildMessageReactions,
                .guildVoiceStates
            ]
        )
        self.manager = manager
        self.client = manager.client
    }

    func makeEvents() async -> AsyncThrowingStream<DiscordGatewayDriverEvent, any Error> {
        let source = await manager.events
        let failureSource = await manager.eventFailures
        let events = AsyncStream<DiscordGatewayDriverEvent> { continuation in
            let task = Task {
                for await event in source {
                    guard !Task.isCancelled else { return }
                    continuation.yield(.gateway(event))
                }
                guard !Task.isCancelled else { return }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
        let failures = AsyncStream<Void> { continuation in
            let task = Task {
                for await _ in failureSource {
                    guard !Task.isCancelled else { return }
                    // Capability-bearing parse bytes and underlying errors stay
                    // inside DiscordBM. The bridge receives one generic failure.
                    continuation.yield(())
                    continuation.finish()
                    return
                }
                guard !Task.isCancelled else { return }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
        return DiscordGatewayEventStreamMerger.merge(events: events, failures: failures)
    }

    func connect() async {
        let manager = manager
        await connectionOperations.connect {
            await manager.connect()
        }
    }

    func disconnect() async {
        let manager = manager
        await connectionOperations.disconnect {
            await manager.disconnect()
        }
    }

    func updateVoiceState(payload: VoiceStateUpdate) async {
        await manager.updateVoiceState(payload: payload)
    }
}

enum DiscordGatewayDrivers {
    static let production: DiscordGatewayDriverFactory = { configuration in
        await DiscordBMGatewayDriver(configuration: configuration)
    }
}
