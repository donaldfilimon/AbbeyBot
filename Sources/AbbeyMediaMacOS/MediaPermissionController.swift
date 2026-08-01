import AVFoundation
import CoreGraphics
import Foundation

public enum MediaPermissionKind: String, CaseIterable, Hashable, Sendable {
    case microphone
    case camera
    case screen
    case systemAudio
}

public enum MediaAuthorizationStatus: String, CaseIterable, Hashable, Sendable {
    case notDetermined
    case restricted
    case denied
    case authorized
    case unavailable
}

public protocol MediaPermissionProviding: Sendable {
    func authorizationStatus(for kind: MediaPermissionKind) async -> MediaAuthorizationStatus
    func requestAuthorization(for kind: MediaPermissionKind) async -> MediaAuthorizationStatus
}

public protocol MediaRuntimePolicyProviding: Sendable {
    func mediaDisabled() -> Bool
}

public struct ProcessMediaRuntimePolicy: MediaRuntimePolicyProviding {
    private let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func mediaDisabled() -> Bool {
        environment["ABBEY_MEDIA_DISABLED"] == "1"
    }
}

public enum MediaRuntimeError: Error, Equatable, Sendable {
    case disabledByEnvironment
    case microphonePermissionRequired(MediaAuthorizationStatus)
    case unsupportedInputDevice
    case unsupportedOutputDevice
    case deviceSelectionRequiresStoppedEngine
    case playbackQueueFull
    case runtimeFailure(String)
}

public actor MediaPermissionController {
    private let provider: any MediaPermissionProviding
    private let policy: any MediaRuntimePolicyProviding

    public init(
        provider: any MediaPermissionProviding,
        policy: any MediaRuntimePolicyProviding = ProcessMediaRuntimePolicy()
    ) {
        self.provider = provider
        self.policy = policy
    }

    public init() {
        provider = SystemMediaPermissionProvider()
        policy = ProcessMediaRuntimePolicy()
    }

    public func authorizationStatus(for kind: MediaPermissionKind) async -> MediaAuthorizationStatus {
        await provider.authorizationStatus(for: kind)
    }

    /// Requests one permission only after an explicit operator action invokes this method.
    public func requestAuthorization(
        for kind: MediaPermissionKind
    ) async throws -> MediaAuthorizationStatus {
        guard !policy.mediaDisabled() else {
            throw MediaRuntimeError.disabledByEnvironment
        }
        return await provider.requestAuthorization(for: kind)
    }

    public func requireMicrophoneAuthorization() async throws {
        guard !policy.mediaDisabled() else {
            throw MediaRuntimeError.disabledByEnvironment
        }
        let status = await provider.authorizationStatus(for: .microphone)
        guard status == .authorized else {
            throw MediaRuntimeError.microphonePermissionRequired(status)
        }
    }

    public func isMediaDisabled() -> Bool {
        policy.mediaDisabled()
    }
}

public struct SystemMediaPermissionProvider: MediaPermissionProviding {
    public init() {}

    public func authorizationStatus(for kind: MediaPermissionKind) async -> MediaAuthorizationStatus {
        switch kind {
        case .microphone:
            map(AVCaptureDevice.authorizationStatus(for: .audio))
        case .camera:
            map(AVCaptureDevice.authorizationStatus(for: .video))
        case .screen:
            // Core Graphics intentionally exposes a granted/not-granted preflight rather than
            // AVFoundation's four-state status. A false result remains notDetermined here so the
            // controller never misreports a prior denial as a positive authorization.
            CGPreflightScreenCaptureAccess() ? .authorized : .notDetermined
        case .systemAudio:
            // Core Audio process taps have no non-capturing preflight API. Creating a tap just to
            // inspect TCC would violate this layer's status-only guarantee.
            .unavailable
        }
    }

    public func requestAuthorization(for kind: MediaPermissionKind) async -> MediaAuthorizationStatus {
        switch kind {
        case .microphone:
            await AVCaptureDevice.requestAccess(for: .audio) ? .authorized : .denied
        case .camera:
            await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied
        case .screen:
            CGRequestScreenCaptureAccess() ? .authorized : .denied
        case .systemAudio:
            // A future process-tap implementation may provide an explicit request operation.
            // Until then, do not create a tap or start capture from a permission controller.
            .unavailable
        }
    }

    private func map(_ status: AVAuthorizationStatus) -> MediaAuthorizationStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        @unknown default: .unavailable
        }
    }
}
