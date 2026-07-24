import Testing
@testable import AbbeyCLI

@Suite("CLICommandParser")
struct CLICommandParserTests {
    @Test func help() {
        #expect(CLICommandParser.parse("/help") == .help)
    }

    @Test func clear() {
        #expect(CLICommandParser.parse("/clear") == .clear)
    }

    @Test func exit() {
        #expect(CLICommandParser.parse("/exit") == .exit)
    }

    @Test func quit() {
        #expect(CLICommandParser.parse("/quit") == .exit)
    }

    @Test func modelBare() {
        #expect(CLICommandParser.parse("/model") == .model(nil))
    }

    @Test func modelWithArgument() {
        #expect(CLICommandParser.parse("/model onDevice") == .model("onDevice"))
    }

    @Test func modelWithArgumentTrimsSurroundingWhitespace() {
        #expect(CLICommandParser.parse("/model   onDevice   ") == .model("onDevice"))
    }

    @Test func plainChatText() {
        #expect(CLICommandParser.parse("hello there") == .chat("hello there"))
    }

    @Test func chatTextIsTrimmed() {
        #expect(CLICommandParser.parse("   hello   ") == .chat("hello"))
    }

    @Test func emptyString() {
        #expect(CLICommandParser.parse("") == .chat(""))
    }

    @Test func whitespaceOnlyString() {
        #expect(CLICommandParser.parse("   \t  ") == .chat(""))
    }

    @Test func unrecognizedSlashCommandFallsBackToChat() {
        #expect(CLICommandParser.parse("/frobnicate") == .chat("/frobnicate"))
    }

    @Test func commandKeywordsAreCaseInsensitive() {
        #expect(CLICommandParser.parse("/HELP") == .help)
        #expect(CLICommandParser.parse("/Exit") == .exit)
        #expect(CLICommandParser.parse("/Model onDevice") == .model("onDevice"))
    }
}
