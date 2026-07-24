import DiscordBM

public enum CommandRegistry {
    public static var all: [Payloads.ApplicationCommandCreate] {
        [
            .init(name: "ask", description: "Ask Abbey anything", options: [questionOption]),
            .init(name: "rep", description: "Check a user's reputation", options: [userOption]),
            .init(name: "remember", description: "Store a fact about a user", options: [userOption, factOption]),
            .init(name: "forget", description: "Remove a stored fact", options: [userOption, factIndexOption]),
            .init(name: "context", description: "Show channel memory summary"),
            .init(name: "persona", description: "Switch active persona", options: [personaOption])
        ]
    }

    public static let questionOption = ApplicationCommand.Option(
        type: .string, name: "question", description: "Your question", required: true, autocomplete: true
    )
    public static let userOption = ApplicationCommand.Option(
        type: .user, name: "user", description: "Target user", required: true
    )
    public static let factOption = ApplicationCommand.Option(
        type: .string, name: "fact", description: "Fact to remember", required: true
    )
    public static let factIndexOption = ApplicationCommand.Option(
        type: .integer, name: "index", description: "1-based fact index", required: true
    )
    public static let personaOption = ApplicationCommand.Option(
        type: .string, name: "name", description: "abbey | aviva | abi", required: true,
        choices: [
            .init(name: "Abbey", value: .string("abbey")),
            .init(name: "Aviva", value: .string("aviva")),
            .init(name: "Abi", value: .string("abi"))
        ]
    )

    public static func register(client: any DiscordClient, guildId: String?) async throws {
        if let guildId, !guildId.isEmpty {
            try await client.bulkSetGuildApplicationCommands(
                guildId: GuildSnowflake(guildId),
                payload: all
            ).guardSuccess()
        } else {
            try await client.bulkSetApplicationCommands(payload: all).guardSuccess()
        }
    }
}
