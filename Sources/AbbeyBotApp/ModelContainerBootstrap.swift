import Foundation

struct ModelContainerBootstrap<Container> {
    struct Result {
        var container: Container
        var degraded: Bool
        var persistentErrorDescription: String?
    }

    static func make(
        persistent: () throws -> Container,
        inMemory: () throws -> Container
    ) throws -> Result {
        do {
            return Result(
                container: try persistent(),
                degraded: false,
                persistentErrorDescription: nil
            )
        } catch {
            let description = error.localizedDescription
            return Result(
                container: try inMemory(),
                degraded: true,
                persistentErrorDescription: description
            )
        }
    }
}
