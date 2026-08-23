import Crypto
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

  @Test("all manifest fixtures match their declared disposition")
  func allFixtureDispositions() throws {
    let corpus = try AbbeyContractCorpus.verify(at: Self.repositoryCorpusURL)
    #expect(corpus.fixturePaths.count == 52)
    for path in corpus.fixturePaths {
      let disposition = try corpus.decodeFixture(path)
      #expect(disposition.actual == disposition.expected, Comment(rawValue: path))
    }
  }

  @Test("duplicate JSON members fail closed in fixtures and qualification metadata")
  func duplicateMembersFailClosed() throws {
    let corpus = try AbbeyContractCorpus.verify(at: Self.repositoryCorpusURL)
    let fixture = try corpus.decodeFixture("v1/fixtures/invalid/jcs-duplicate-member.json")
    #expect(fixture.actual == .duplicateMember)
    #expect(fixture.actual == fixture.expected)

    try Self.withScratchCorpus { scratch in
      let lockURL = scratch.appending(path: "abbey-contracts.lock.json")
      var lock = try String(contentsOf: lockURL, encoding: .utf8)
      lock = lock.replacingOccurrences(
        of: "{\n",
        with: "{\n  \"source_revision\": \"1111111111111111111111111111111111111111\",\n",
        options: [.anchored]
      )
      try Data(lock.utf8).write(to: lockURL)
      #expect(throws: AbbeyContractError.lockInvalid(path: "abbey-contracts.lock.json")) {
        try AbbeyContractCorpus.verify(at: scratch)
      }
    }
  }

  @Test("qualification rejects alternate source and recomputed corpus identities")
  func exactIdentityIsRequired() throws {
    try Self.withScratchCorpus { scratch in
      let lockURL = scratch.appending(path: "abbey-contracts.lock.json")
      var lock = try String(contentsOf: lockURL, encoding: .utf8)
      lock = lock.replacingOccurrences(
        of: sourceRevision, with: String(repeating: "1", count: 40))
      try Data(lock.utf8).write(to: lockURL)
      #expect(throws: AbbeyContractError.lockInvalid(path: "abbey-contracts.lock.json")) {
        try AbbeyContractCorpus.verify(at: scratch)
      }
    }

    try Self.withScratchCorpus { scratch in
      let alternateDigest = try Self.rewriteWithAlternateQualifiedIdentity(at: scratch)
      #expect(alternateDigest != aggregateDigest)
      #expect(
        try String(
          contentsOf: scratch.appending(path: "abbey-contracts.lock.json"), encoding: .utf8
        ).contains(alternateDigest))
      #expect(
        try String(
          contentsOf: scratch.appending(path: "corpus/manifest.json"), encoding: .utf8
        ).contains(alternateDigest))
      #expect(throws: AbbeyContractError.lockInvalid(path: "abbey-contracts.lock.json")) {
        try AbbeyContractCorpus.verify(at: scratch)
      }
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

  private static func withScratchCorpus(_ body: (URL) throws -> Void) throws {
    let scratch = FileManager.default.temporaryDirectory
      .appending(path: "abbey-contract-swift-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: scratch) }
    try FileManager.default.copyItem(at: repositoryCorpusURL, to: scratch)
    try body(scratch)
  }

  private static func rewriteWithAlternateQualifiedIdentity(at root: URL) throws -> String {
    let canonicalDigest = "72e241e34967df318376bf68f4a0e2db13f5ebf17d1a219709731f1f470dbe8e"
    let manifestURL = root.appending(path: "corpus/manifest.json")
    var manifest = try String(contentsOf: manifestURL, encoding: .utf8)
    manifest = manifest.replacingOccurrences(
      of: "\"redaction_profile\": \"abbey-contract-redaction-v1\"",
      with: "\"redaction_profile\": \"alternate-contract-redaction-v1\""
    )
    let zeroed = manifest.replacingOccurrences(
      of: canonicalDigest, with: String(repeating: "0", count: 64))
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(manifest.utf8)) as? [String: Any]
    )
    let artifacts = try #require(object["artifacts"] as? [[String: Any]])
    var entries = try artifacts.map { row -> (String, Int, String) in
      (
        try #require(row["path"] as? String), try #require(row["bytes"] as? Int),
        try #require(row["sha256"] as? String)
      )
    }
    entries.append(("manifest.json", zeroed.utf8.count, Self.sha256(Data(zeroed.utf8))))
    entries.sort { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }
    var digest = SHA256()
    digest.update(data: Data("abbey-contract-corpus-v1\0".utf8))
    for entry in entries {
      digest.update(data: Data(entry.0.utf8))
      digest.update(data: Data([0]))
      digest.update(data: Data(String(entry.1).utf8))
      digest.update(data: Data([0]))
      digest.update(data: Data(entry.2.utf8))
      digest.update(data: Data([10]))
    }
    let alternateDigest = digest.finalize().map { String(format: "%02x", $0) }.joined()
    manifest = manifest.replacingOccurrences(of: canonicalDigest, with: alternateDigest)
    try Data(manifest.utf8).write(to: manifestURL)

    let lockURL = root.appending(path: "abbey-contracts.lock.json")
    let lock = try String(contentsOf: lockURL, encoding: .utf8)
      .replacingOccurrences(of: canonicalDigest, with: alternateDigest)
    try Data(lock.utf8).write(to: lockURL)
    return alternateDigest
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
