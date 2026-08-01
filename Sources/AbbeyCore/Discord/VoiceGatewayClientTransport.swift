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

/// One complete Voice Gateway WebSocket message. Binary payloads are deliberately
/// redacted from textual and reflective diagnostics.
public enum VoiceGatewayClientFrame: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    case text(String)
    case binary(Data)

    public var byteCount: Int {
        switch self {
        case .text(let value): value.utf8.count
        case .binary(let value): value.count
        }
    }

    public var description: String {
        switch self {
        case .text(let value): "VoiceGatewayClientFrame.text(count: \(value.utf8.count))"
        case .binary(let value): "VoiceGatewayClientFrame.binary(<redacted>, count: \(value.count))"
        }
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["representation": representation, "payload": "<redacted>", "count": byteCount],
            displayStyle: .enum
        )
    }

    private var representation: String {
        switch self {
        case .text: "text"
        case .binary: "binary"
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
    public typealias ReceiveFrame = @Sendable () async throws -> VoiceGatewayClientFrame?
    public typealias SendFrame = @Sendable (VoiceGatewayClientFrame) async throws -> Void
    public typealias Receive = @Sendable () async throws -> String?
    public typealias Send = @Sendable (String) async throws -> Void
    public typealias Close = @Sendable (Int, String?) async -> Void

    private let receiveFrameImpl: ReceiveFrame
    private let sendFrameImpl: SendFrame
    private let closeImpl: Close

    public init(
        receiveFrame: @escaping ReceiveFrame,
        sendFrame: @escaping SendFrame,
        close: @escaping Close
    ) {
        self.receiveFrameImpl = receiveFrame
        self.sendFrameImpl = sendFrame
        self.closeImpl = close
    }

    /// Compatibility initializer for text-only Voice Gateway consumers.
    public init(
        receive: @escaping Receive,
        send: @escaping Send,
        close: @escaping Close
    ) {
        self.receiveFrameImpl = {
            try await receive().map(VoiceGatewayClientFrame.text)
        }
        self.sendFrameImpl = { frame in
            guard case .text(let text) = frame else {
                throw VoiceGatewayClientTransportError.binaryMessageRejected
            }
            try await send(text)
        }
        self.closeImpl = close
    }

    public func receiveFrame() async throws -> VoiceGatewayClientFrame? {
        try await receiveFrameImpl()
    }

    public func sendFrame(_ frame: VoiceGatewayClientFrame) async throws {
        try await sendFrameImpl(frame)
    }

    public func receive() async throws -> String? {
        guard let frame = try await receiveFrameImpl() else { return nil }
        guard case .text(let text) = frame else {
            throw VoiceGatewayClientTransportError.binaryMessageRejected
        }
        return text
    }

    public func send(_ text: String) async throws {
        try await sendFrameImpl(.text(text))
    }
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
                    receiveFrame: {
                        try await inbox.nextFrame()
                    },
                    sendFrame: { frame in
                        guard frame.byteCount <= maximumMessageBytes else {
                            throw VoiceGatewayClientTransportError.messageTooLarge
                        }
                        switch frame {
                        case .text(let text):
                            try await outbound.write(.text(text))
                        case .binary(let data):
                            try await outbound.write(.binary(ByteBuffer(bytes: data)))
                        }
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
                                            try await inbox.yield(.text(text))
                                        } catch {
                                            try? await outbound.close(
                                                .init(codeNumber: VoiceGatewayClientInboundBuffer.overflowCloseCode),
                                                reason: "inbound queue overflow"
                                            )
                                            throw error
                                        }
                                    case .binary(let buffer):
                                        guard buffer.readableBytes <= maximumMessageBytes else {
                                            throw VoiceGatewayClientTransportError.messageTooLarge
                                        }
                                        do {
                                            try await inbox.yield(
                                                .binary(Data(buffer.readableBytesView))
                                            )
                                        } catch {
                                            try? await outbound.close(
                                                .init(codeNumber: VoiceGatewayClientInboundBuffer.overflowCloseCode),
                                                reason: "inbound queue overflow"
                                            )
                                            throw error
                                        }
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
                )
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
                await completion.complete(.failure(CancellationError()))
            }
        }

        operationTask.cancel()
        inboundTask.cancel()
        if Task.isCancelled {
            // Cleanup must unblock transport waits before joining both child
            // tasks. Joining prevents a cancelled session from racing the next
            // connection attempt with stale reads or writes.
            await cancelled()
        } else if case .success(.operation) = first {
            await operationCompleted()
        }
        _ = await operationTask.result
        _ = await inboundTask.result
        if Task.isCancelled { throw CancellationError() }
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
    nonisolated static let overflowCloseCode = 1009
    private typealias Waiter = CheckedContinuation<
        Result<VoiceGatewayClientFrame?, any Error>,
        Never
    >

    private var buffered: [VoiceGatewayClientFrame] = []
    private var bufferedBytes = 0
    private var waiters: [Waiter] = []
    private var finished: Result<VoiceGatewayClientFrame?, any Error>?
    private let maximumMessages: Int
    private let maximumBytes: Int

    init(maximumMessages: Int, maximumBytes: Int) {
        self.maximumMessages = max(1, maximumMessages)
        self.maximumBytes = max(1, maximumBytes)
    }

    func yield(_ message: String) throws {
        try yield(.text(message))
    }

    func yield(_ frame: VoiceGatewayClientFrame) throws {
        guard finished == nil else { return }
        if waiters.isEmpty {
            let byteCount = frame.byteCount
            guard buffered.count < maximumMessages,
                  byteCount <= maximumBytes - min(bufferedBytes, maximumBytes)
            else {
                finish(throwing: VoiceGatewayClientTransportError.messageTooLarge, discardingBuffered: true)
                throw VoiceGatewayClientTransportError.messageTooLarge
            }
            buffered.append(frame)
            bufferedBytes += byteCount
        } else {
            waiters.removeFirst().resume(returning: .success(frame))
        }
    }

    func finish(throwing error: (any Error)? = nil, discardingBuffered: Bool = false) {
        guard finished == nil else { return }
        let result: Result<VoiceGatewayClientFrame?, any Error> =
            error.map(Result.failure) ?? .success(nil)
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
        guard let frame = try await nextFrame() else { return nil }
        guard case .text(let text) = frame else {
            throw VoiceGatewayClientTransportError.binaryMessageRejected
        }
        return text
    }

    func nextFrame() async throws -> VoiceGatewayClientFrame? {
        if !buffered.isEmpty {
            let frame = buffered.removeFirst()
            bufferedBytes -= frame.byteCount
            return frame
        }
        if let finished {
            return try finished.get()
        }
        return try await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }.get()
    }
}
