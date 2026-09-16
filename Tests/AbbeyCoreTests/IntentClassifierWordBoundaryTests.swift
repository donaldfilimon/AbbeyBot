import Testing
@testable import AbbeyCore

/// `classifyLoose` matched its keywords with bare `contains`, so ordinary words
/// containing them were misclassified. This is not only a wrong-reply bug:
/// `Intent.quality` feeds `recordInteraction` and the DQN's reward, so every
/// misclassification writes corrupted signal into reputation and learning.
@Suite("Intent classifier word boundaries")
struct IntentClassifierWordBoundaryTests {
    /// Want: ordinary sentences. Got, before the fix: `.repQuery`, because
    /// "report" and "reply" both contain "rep".
    @Test func wordsContainingRepAreNotReputationQueries() {
        #expect(IntentClassifier.classify("I'll reply later") != .repQuery)
        #expect(IntentClassifier.classify("here is the report") != .repQuery)
        #expect(IntentClassifier.classify("let me prepare that") != .repQuery)
        #expect(IntentClassifier.classify("they represent the team") != .repQuery)
    }

    /// Want: small talk. Got, before the fix: `.modRequest` at quality 0.8,
    /// because "banana" contains "ban" and "kickoff" contains "kick".
    @Test func wordsContainingModerationVerbsAreNotModerationRequests() {
        #expect(IntentClassifier.classify("that is a banana") != .modRequest)
        #expect(IntentClassifier.classify("the kickoff is at noon") != .modRequest)
        #expect(IntentClassifier.classify("urban planning is hard") != .modRequest)
        #expect(IntentClassifier.classify("do not abandon it") != .modRequest)
    }

    /// The rules must still fire on the real thing — a boundary fix that also
    /// broke genuine matches would be a worse bug than the one it replaced.
    @Test func genuineKeywordsStillClassify() {
        #expect(IntentClassifier.classify("please kick that user") == .modRequest)
        #expect(IntentClassifier.classify("ban them now") == .modRequest)
        #expect(IntentClassifier.classify("purge the channel") == .modRequest)
        #expect(IntentClassifier.classify("give them a timeout") == .modRequest)
        #expect(IntentClassifier.classify("what is my rep") == .repQuery)
        #expect(IntentClassifier.classify("check their reputation") == .repQuery)
        #expect(IntentClassifier.classify("remember tea") == .memoryStore)
        #expect(IntentClassifier.classify("note that we ship friday") == .memoryStore)
    }

    /// Punctuation is a word boundary, so a trailing `?` or `.` must not stop
    /// a genuine keyword from matching.
    @Test func punctuationDoesNotSuppressGenuineKeywords() {
        #expect(IntentClassifier.classify("what is my rep?") == .repQuery)
        #expect(IntentClassifier.classify("kick, please") == .modRequest)
    }

    /// The corrupted-signal consequence, stated as a check rather than prose:
    /// a misread noun must not be scored as a high-quality moderation turn.
    @Test func misreadNounsDoNotEarnModerationQuality() {
        let banana = IntentClassifier.classify("that is a banana")
        #expect(banana.quality < IntentClassifier.Intent.modRequest.quality)
    }
}
