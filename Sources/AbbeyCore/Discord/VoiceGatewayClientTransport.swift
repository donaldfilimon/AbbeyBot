import Foundation
import Logging
import NIOCore
import WSClient

public enum VoiceGatewayClientTransportError: Error, Equatable, Sendable, CustomStringConvertible {
    case binaryMessageRejected
    case messageTooLarge
    case invalidTextEncoding
    case connectionClosed

    public var description: String {
        switch self {
        case .binaryMessageRejected: "Discord Voice Gateway sent an unsupported binary message"
        case .messageTooLarge: "Discord Voice Gateway message exceeded the configured limit"
        case .invalidTextEncoding: "Discord Voice Gateway sent invalid text"
        case .connectionClosed: "Discord Voice Gateway connection closed"
        }
    }
}

public struct VoiceGatewayClientClose: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let code: Int
    public let reason: String?

    public init(code: Int, reason: String?) {
        self.code = code
        self.reason = reason.map { String($0.prefix(123)) }
    }

    /// Close reasons are untrusted server text and are deliberately omitted.
    public var description: String { "VoiceGatewayClientClose(code: \(code), reason: <redacted>)" }
    public var debugDescription: String { description }
}

/// Type-erased connection scoped to one Voice Gateway WebSocket.
public struct VoiceGatewayClientSession: Sendable {
    public typealias Receive = @Sendable () async throws -> String?
    public typealias Send = @Sendable (String) async throws -> Void
    public typealias Close = @Sendable (Int, String?) async -> Void

    private let receiveImpl: Receive
    private let sendImpl: Send
    private let closeImpl: Close

    public init(
        receive: @escaping Receive,
        send: @escaping Send,
        close: @escaping Close
    ) {
        self.receiveImpl = receive
        self.sendImpl = send
        self.closeImpl = close
    }

    public func receive() async throws -> String? { try await receiveImpl() }
    public func send(_ text: String) async throws { try await sendImpl(text) }
    public func close(code: Int = 1000, reason: String? = nil) async {
        await closeImpl(code, reason.map { String($0.prefix(123)) })
    }
}

/// Type-erased WebSocket transport. Tests inject a hermetic runner; production uses the live adapter.
public struct VoiceGatewayClientTransport: Sendable {
    public typealias Operation = @Sendable (VoiceGatewayClientSession) async throws -> Void
    public typealias Runner = @Sendable (
        VoiceGatewayV8Endpoint,
        Int,
        @escaping Operation
    ) async throws -> VoiceGatewayClientClose?

    private let runner: Runner

    public init(run: @escaping Runner) {
        self.runner = run
    }

    public func run(
        endpoint: VoiceGatewayV8Endpoint,
        maximumMessageBytes: Int,
        operation: @escaping Operation
    ) async throws -> VoiceGatewayClientClose? {
        try await runner(endpoint, maximumMessageBytes, operation)
    }

    /// Production WSS adapter backed by the same pinned WSClient package as DiscordBM.
    public static func live(logger: Logger = Logger(label: "AbbeyCore.VoiceGateway")) -> Self {
        Self { endpoint, maximumMessageBytes, operation in
            let configuration = WebSocketClientConfiguration(
                maxFrameSize: maximumMessageBytes,
                closeTimeout: .seconds(5),
                autoPing: .disabled,
                validateUTF8: true,
                sniHostname: endpoint.url.host
            )
            let client = WebSocketClient(
                url: endpoint.url.absoluteString,
                configuration: configuration,
                logger: logger
            ) { inbound, outbound, _ in
                let maximumBufferedBytes = min(maximumMessageBytes * 8, 4 * 1_024 * 1_024)
                let inbox = VoiceGatewayClientInboundBuffer(
                    maximumMessages: 128,
                    maximumBytes: maximumBufferedBytes
                )
                let session = VoiceGatewayClientSession(
                    receive: {
                        try await inbox.next()
                    },
                    send: { text in
                        guard text.utf8.count <= maximumMessageBytes else {
                            throw VoiceGatewayClientTransportError.messageTooLarge
                        }
                        try await outbound.write(.text(text))
                    },
                    close: { code, reason in
                        guard (1_000...4_999).contains(code) else { return }
                        try? await outbound.close(
                            .init(codeNumber: code),
                            reason: reason
                        )
                    }
                )

                try await VoiceGatewayClientTaskCoordinator.run(
                    operation: {
                            try await operation(session)
                    },
                    inbound: {
                            do {
                                for try await message in inbound.messages(maxSize: maximumMessageBytes) {
                                    switch message {
                                    case .text(let text):
                                        guard text.utf8.count <= maximumMessageBytes else {
                                            throw VoiceGatewayClientTransportError.messageTooLarge
                                        }
                                        do {
                                            try await inbox.yield(text)
                                        } catch {
                                            try? await outbound.close(
                                                .init(codeNumber: 1009),
                                                reason: "inbound queue overflow"
                                            )
                                            throw error
                                        }
                                    case .binary:
                                        throw VoiceGatewayClientTransportError.binaryMessageRejected
                                    }
                                }
                                await inbox.finish()
                            } catch {
                                let mapped: any Error
                                if let clientError = error as? WebSocketClientError {
                                    if clientError == .serverSentMessageTooLarge {
                                        mapped = VoiceGatewayClientTransportError.messageTooLarge
                                    } else if clientError == .serverSentDataInconsistentWithMessage {
                                        mapped = VoiceGatewayClientTransportError.invalidTextEncoding
                                    } else {
                                        mapped = error
                                    }
                                } else {
                                    mapped = error
                                }
                                await inbox.finish(throwing: mapped)
                                throw mapped
                            }
                    },
                    operationCompleted: {
                        await inbox.finish()
                    },
                    cancelled: {
                        await inbox.finish(throwing: CancellationError())
                        try? await outbound.close(.goingAway, reason: "cancelled")
                    }
            }

            let close = try await client.run()
            return close.map {
                VoiceGatewayClientClose(
                    code: Int(UInt16(webSocketErrorCode: $0.closeCode)),
                    reason: $0.reason
                )
            }
        }
    }
}

enum VoiceGatewayClientTransportTask: Equatable, Sendable {
    case operation
    case inbound
}

enum VoiceGatewayClientTaskCoordinator {
    typealias Work = @Sendable () async throws -> Void
    typealias Cleanup = @Sendable () async -> Void

    static func run(
        operation: @escaping Work,
        inbound: @escaping Work,
        operationCompleted: @escaping Cleanup,
        cancelled: @escaping Cleanup
    ) async throws {
        let completion = VoiceGatewayClientFirstCompletion()
        let operationTask = Task {
            do {
                try await operation()
                await completion.complete(.success(.operation))
            } catch {
                await completion.complete(.failure(error))
            }
        }
        let inboundTask = Task {
            do {
                try await inbound()
                await completion.complete(.success(.inbound))
            } catch {
                await completion.complete(.failure(error))
            }
        }

        let first = await withTaskCancellationHandler {
            await completion.next()
        } onCancel: {
            operationTask.cancel()
            inboundTask.cancel()
            Task {
                await cancelled()
                await completion.complete(.failure(CancellationError()))
            }
        }

        operationTask.cancel()
        inboundTask.cancel()
        if case .success(.operation) = first {
            await operationCompleted()
        }
        _ = try first.get()
    }
}

private actor VoiceGatewayClientFirstCompletion {
    private typealias Waiter = CheckedContinuation<Result<VoiceGatewayClientTransportTask, any Error>, Never>
    private var result: Result<VoiceGatewayClientTransportTask, any Error>?
    private var waiter: Waiter?

    func complete(_ result: Result<VoiceGatewayClientTransportTask, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        waiter?.resume(returning: result)
        waiter = nil
    }

    func next() async -> Result<VoiceGatewayClientTransportTask, any Error> {
        if let result { return result }
        return await withCheckedContinuation { waiter = $0 }
    }
}

actor VoiceGatewayClientInboundBuffer {
    private typealias Waiter = CheckedContinuation<Result<String?, any Error>, Never>

    private var buffered: [String] = []
    private var bufferedBytes = 0
    private var waiters: [Waiter] = []
    private var finished: Result<String?, any Error>?
    private let maximumMessages: Int
    private let maximumBytes: Int

    init(maximumMessages: Int, maximumBytes: Int) {
        self.maximumMessages = max(1, maximumMessages)
        self.maximumBytes = max(1, maximumBytes)
    }

    func yield(_ message: String) throws {
        guard finished == nil else { return }
        if waiters.isEmpty {
            let byteCount = message.utf8.count
            guard buffered.count < maximumMessages,
                  byteCount <= maximumBytes - min(bufferedBytes, maximumBytes)
            else {
                finish(throwing: VoiceGatewayClientTransportError.messageTooLarge, discardingBuffered: true)
                throw VoiceGatewayClientTransportError.messageTooLarge
            }
            buffered.append(message)
            bufferedBytes += byteCount
        } else {
            waiters.removeFirst().resume(returning: .success(message))
        }
    }

    func finish(throwing error: (any Error)? = nil, discardingBuffered: Bool = false) {
        guard finished == nil else { return }
        let result: Result<String?, any Error> = error.map(Result.failure) ?? .success(nil)
        finished = result
        if discardingBuffered {
            buffered.removeAll(keepingCapacity: false)
            bufferedBytes = 0
        }
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume(returning: result)
        }
    }

    func next() async throws -> String? {
        if !buffered.isEmpty {
            let message = buffered.removeFirst()
            bufferedBytes -= message.utf8.count
            return message
        }
        if let finished {
            return try finished.get()
        }
        return try await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }.get()
    }
}
