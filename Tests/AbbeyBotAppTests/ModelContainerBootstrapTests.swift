import Foundation
import Testing
@testable import AbbeyBotApp

@Suite("Model container bootstrap")
struct ModelContainerBootstrapTests {
    private struct PersistentFailure: LocalizedError {
        var errorDescription: String? { "store is locked" }
    }

    @Test func persistentFailureFallsBackWithoutRetryingOrMutatingDisk() throws {
        var persistentAttempts = 0
        var fallbackAttempts = 0

        let result = try ModelContainerBootstrap<String>.make(
            persistent: {
                persistentAttempts += 1
                throw PersistentFailure()
            },
            inMemory: {
                fallbackAttempts += 1
                return "memory"
            }
        )

        #expect(result.container == "memory")
        #expect(result.degraded)
        #expect(result.persistentErrorDescription == "store is locked")
        #expect(persistentAttempts == 1)
        #expect(fallbackAttempts == 1)
    }

    @Test func successfulPersistentOpenDoesNotConstructFallback() throws {
        var fallbackConstructed = false
        let result = try ModelContainerBootstrap<String>.make(
            persistent: { "disk" },
            inMemory: {
                fallbackConstructed = true
                return "memory"
            }
        )

        #expect(result.container == "disk")
        #expect(!result.degraded)
        #expect(!fallbackConstructed)
    }
}
