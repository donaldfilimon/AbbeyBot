import Testing
@testable import AbbeyMediaMacOS

@Suite("Media permission controller")
struct MediaPermissionControllerTests {
    @Test("construction never reads or requests TCC")
    func initializationDoesNotTouchProvider() async {
        let provider = PermissionProviderRecorder()
        _ = MediaPermissionController(provider: provider)
        #expect(await provider.statusCalls() == [])
        #expect(await provider.requestCalls() == [])
    }

    @Test("all authorization states are preserved")
    func allStatusesArePreserved() async {
        for status in MediaAuthorizationStatus.allCases {
            let provider = PermissionProviderRecorder(status: status)
            let controller = MediaPermissionController(provider: provider)
            #expect(await controller.authorizationStatus(for: .microphone) == status)
        }
    }

    @Test("request is explicit and attributed to one permission")
    func deniedRequestIsReturned() async throws {
        let provider = PermissionProviderRecorder(status: .notDetermined, requestResult: .denied)
        let controller = MediaPermissionController(provider: provider)
        #expect(try await controller.requestAuthorization(for: .microphone) == .denied)
        #expect(await provider.requestCalls() == [.microphone])
        #expect(await provider.statusCalls() == [])
    }

    @Test("disabled policy rejects before provider request")
    func disabledRejectsBeforePrompt() async {
        let provider = PermissionProviderRecorder()
        let controller = MediaPermissionController(
            provider: provider,
            policy: DisabledPolicy()
        )
        await #expect(throws: MediaRuntimeError.disabledByEnvironment) {
            try await controller.requestAuthorization(for: .microphone)
        }
        #expect(await provider.requestCalls().isEmpty)
    }
}

private actor PermissionProviderRecorder: MediaPermissionProviding {
    private let status: MediaAuthorizationStatus
    private let requestResult: MediaAuthorizationStatus
    private var statuses: [MediaPermissionKind] = []
    private var requests: [MediaPermissionKind] = []

    init(
        status: MediaAuthorizationStatus = .notDetermined,
        requestResult: MediaAuthorizationStatus = .authorized
    ) {
        self.status = status
        self.requestResult = requestResult
    }

    func authorizationStatus(for kind: MediaPermissionKind) -> MediaAuthorizationStatus {
        statuses.append(kind)
        return status
    }

    func requestAuthorization(for kind: MediaPermissionKind) -> MediaAuthorizationStatus {
        requests.append(kind)
        return requestResult
    }

    func statusCalls() -> [MediaPermissionKind] { statuses }
    func requestCalls() -> [MediaPermissionKind] { requests }
}

private struct DisabledPolicy: MediaRuntimePolicyProviding {
    func mediaDisabled() -> Bool { true }
}
