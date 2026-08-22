import Foundation
import Testing

@testable import AbbeyCore

@Suite("Abbey contract corpus")
struct AbbeyContractCorpusTests {
  private let sourceRevision = "348754bdaaf59a40fbb858380f925e0aba95a23b"
  private let aggregateDigest = "72e241e34967df318376bf68f4a0e2db13f5ebf17d1a219709731f1f470dbe8e"

  @Test("repository and packaged resources independently qualify")
  func repositoryAndBundleQualify() throws {
    let repository = try AbbeyContractCorpus.verify(at: Self.repositoryCorpusURL)
    #expect(repository.sourceRevision == sourceRevision)
    #expect(repository.aggregateDigest == aggregateDigest)
    #expect(repository.artifactCount == 81)
    #expect(repository.totalBytes == 88_328)

    let packaged = try AbbeyContractCorpus.verifyBundled()
    #expect(packaged.sourceRevision == sourceRevision)
    #expect(packaged.aggregateDigest == aggregateDigest)
    #expect(packaged.artifactCount == 81)
  }

  @Test("closed contract enums decode known values and reject authority unknowns")
  func enumsAreClosed() throws {
    let decoder = JSONDecoder()
    #expect(try decoder.decode(AbbeyRiskClass.self, from: Data("\"High\"".utf8)) == .high)
    #expect(try decoder.decode(AbbeyConsentState.self, from: Data("\"Open\"".utf8)) == .open)
    #expect(try decoder.decode(AbbeyLearningState.self, from: Data("\"Unset\"".utf8)) == .unset)
    #expect(
      try decoder.decode(AbbeyResponseTerminalState.self, from: Data("\"outcome_unresolved\"".utf8))
        == .outcomeUnresolved)
    #expect(
      try decoder.decode(AbbeyClaimClass.self, from: Data("\"Observation\"".utf8)) == .observation)
    #expect(
      try decoder.decode(AbbeyCapabilityState.self, from: Data("\"Current\"".utf8)) == .current)
    #expect(try decoder.decode(AbbeyEvidenceLevel.self, from: Data("\"C7\"".utf8)) == .c7)
    #expect(throws: DecodingError.self) {
      try decoder.decode(AbbeyRiskClass.self, from: Data("\"OwnerOverride\"".utf8))
    }
  }

  @Test("representative valid and hostile fixtures get native dispositions")
  func fixtureDispositions() throws {
    let corpus = try AbbeyContractCorpus.verify(at: Self.repositoryCorpusURL)
    let expected: [(String, AbbeyContractReasonCode)] = [
      ("v1/fixtures/valid/authorization-grant.json", .valid),
      ("v1/fixtures/valid/consent-operator-flow.json", .valid),
      ("v1/fixtures/valid/episode-claim.json", .valid),
      ("v1/fixtures/valid/execution-complete-response.json", .valid),
      ("v1/fixtures/degraded/consent-connection-loss.json", .valid),
      ("v1/fixtures/invalid/authorization-unknown-field.json", .schemaInvalid),
      ("v1/fixtures/boundary/identity-delegation-nine-hops.json", .schemaInvalid),
      ("v1/fixtures/invalid/consent-open-without-manager.json", .consentOpenDenied),
      ("v1/fixtures/invalid/consent-participant-change-stays-open.json", .consentCloseRequired),
      ("v1/fixtures/cancellation/execution-stale-cancellation.json", .cancellationMismatch),
      ("v1/fixtures/invalid/episode-overstated-claim.json", .evidenceOverclaim),
      ("v1/fixtures/invalid/learning-unset-update.json", .learningDisabled),
      ("v1/fixtures/privacy/consent-report-content.json", .forbiddenContent),
      ("v1/fixtures/boundary/jcs-number-domain.json", .numericDomain),
    ]

    for (path, reason) in expected {
      let disposition = try corpus.decodeFixture(at: path)
      #expect(disposition.actual == reason, Comment(rawValue: path))
      #expect(disposition.expected == reason, Comment(rawValue: path))
    }
  }

  @Test("tolerant metadata preserves bounded extensions")
  func extensionsArePreserved() throws {
    let corpus = try AbbeyContractCorpus.verify(at: Self.repositoryCorpusURL)
    let event = try corpus.decodeMetadataEventFixture(
      at: "v1/fixtures/unknown-field/execution-metadata-extension.json"
    )
    #expect(event.extensions["future_counter"] == .integer(7))
    #expect(event.extensions["future_flag"] == .bool(true))
  }

  @Test("synthetic operator report remains content free")
  func reportIsContentFree() throws {
    let corpus = try AbbeyContractCorpus.verify(at: Self.repositoryCorpusURL)
    let report = try corpus.decodeOperatorVerificationReportFixture(
      at: "v1/fixtures/valid/consent-operator-flow.json"
    )
    #expect(report.evidenceClassification == .localTest)
    #expect(report.terminalStatus == .complete)
    #expect(report.redacted)

    let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
    for forbidden in [
      "audio", "transcript", "message", "prompt", "response_text", "participant_identity",
      "credential",
    ] {
      #expect(!encoded.contains(forbidden))
    }
  }

  @Test("byte mutation fails with a bounded content-free error")
  func byteMutationFailsClosed() throws {
    let scratch = FileManager.default.temporaryDirectory
      .appending(path: "abbey-contract-swift-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: scratch) }
    try FileManager.default.copyItem(at: Self.repositoryCorpusURL, to: scratch)
    let artifact = scratch.appending(path: "corpus/v1/fixtures/valid/episode-evidence.json")
    var bytes = try Data(contentsOf: artifact)
    bytes[bytes.startIndex] ^= 1
    try bytes.write(to: artifact)

    do {
      _ = try AbbeyContractCorpus.verify(at: scratch)
      Issue.record("mutated artifact qualified")
    } catch let error as AbbeyContractError {
      #expect(error == .artifactDigestMismatch(path: "v1/fixtures/valid/episode-evidence.json"))
      #expect(!error.description.contains("integrity_state"))
      #expect(!error.description.contains(scratch.path()))
    }
  }

  private static var repositoryCorpusURL: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Contracts/Abbey", directoryHint: .isDirectory)
  }
}
