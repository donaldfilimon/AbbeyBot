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
                let inbox = VoiceGatewayClientMessageInbox()
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

                try await withTaskCancellationHandler {
                    try await withThrowingTaskGroup(of: VoiceGatewayClientTransportTask.self) { group in
                        group.addTask {
                            try await operation(session)
                            return .operation
                        }
                        group.addTask {
                            do {
                                for try await message in inbound.messages(maxSize: maximumMessageBytes) {
                                    switch message {
                                    case .text(let text):
                                        guard text.utf8.count <= maximumMessageBytes else {
                                            throw VoiceGatewayClientTransportError.messageTooLarge
                                        }
                                        await inbox.yield(text)
                                    case .binary:
                                        throw VoiceGatewayClientTransportError.binaryMessageRejected
                                    }
                                }
                                await inbox.finish()
                                return .inbound
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
                        }

                        guard let first = try await group.next() else { return }
                        if first == .operation {
                            group.cancelAll()
                            await inbox.finish()
                        }
                        while await group.nextResult() != nil {}
                    }
                } onCancel: {
                    Task {
                        await inbox.finish(throwing: CancellationError())
                        try? await outbound.close(.goingAway, reason: "cancelled")
                    }
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

private enum VoiceGatewayClientTransportTask: Equatable, Sendable {
    case operation
    case inbound
}

private actor VoiceGatewayClientMessageInbox {
    private typealias Waiter = CheckedContinuation<Result<String?, any Error>, Never>

    private var buffered: [String] = []
    private var waiters: [Waiter] = []
    private var finished: Result<String?, any Error>?

    func yield(_ message: String) {
        guard finished == nil else { return }
        if waiters.isEmpty {
            buffered.append(message)
        } else {
            waiters.removeFirst().resume(returning: .success(message))
        }
    }

    func finish(throwing error: (any Error)? = nil) {
        guard finished == nil else { return }
        let result: Result<String?, any Error> = error.map(Result.failure) ?? .success(nil)
        finished = result
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume(returning: result)
        }
    }

    func next() async throws -> String? {
        if !buffered.isEmpty {
            return buffered.removeFirst()
        }
        if let finished {
            return try finished.get()
        }
        return try await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }.get()
    }
}
