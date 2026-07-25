import Testing
@testable import AbbeyCore

@Suite("InteractionRouter guards")
struct InteractionRouterGuardsTests {
    @Test func validatedForgetIndexAcceptsPositiveOneBased() {
        #expect(InteractionRouter.validatedForgetIndex(1) == 1)
        #expect(InteractionRouter.validatedForgetIndex(2) == 2)
        #expect(InteractionRouter.validatedForgetIndex(99) == 99)
    }

    @Test func validatedForgetIndexRejectsMissingZeroAndNegative() {
        #expect(InteractionRouter.validatedForgetIndex(0) == nil)
        #expect(InteractionRouter.validatedForgetIndex(-1) == nil)
        #expect(InteractionRouter.validatedForgetIndex(-40) == nil)
    }

    @Test func autocompleteOnlyForAsk() {
        #expect(InteractionRouter.shouldProvideAutocomplete(for: "ask"))
        #expect(!InteractionRouter.shouldProvideAutocomplete(for: "forget"))
        #expect(!InteractionRouter.shouldProvideAutocomplete(for: "rep"))
        #expect(!InteractionRouter.shouldProvideAutocomplete(for: "remember"))
        #expect(!InteractionRouter.shouldProvideAutocomplete(for: "context"))
        #expect(!InteractionRouter.shouldProvideAutocomplete(for: "persona"))
        #expect(!InteractionRouter.shouldProvideAutocomplete(for: "voice"))
        #expect(!InteractionRouter.shouldProvideAutocomplete(for: ""))
    }
}
