import CoreFoundation
import Crypto
import Foundation

public struct AbbeyQualifiedCorpus: Sendable {
  public let sourceRevision: String
  public let aggregateDigest: String
  public let artifactCount: Int
  public let totalBytes: Int
  public let fixturePaths: [String]

  fileprivate let corpusURL: URL
  fileprivate let schemas: [String: [String: AnySendable]]

  public func decodeFixture(_ relativePath: String) throws -> AbbeyFixtureDisposition {
    try decodeFixture(at: relativePath)
  }

  public func decodeFixture(at relativePath: String) throws -> AbbeyFixtureDisposition {
    let (fixture, hasDuplicateMember) = try loadFixture(relativePath: relativePath)
    guard Set(fixture.keys) == ["case_id", "schema", "expect", "document"],
      let caseID = fixture["case_id"] as? String,
      let schemaID = fixture["schema"] as? String,
      let expectedRaw = fixture["expect"] as? String,
      let expected = AbbeyContractReasonCode(rawValue: expectedRaw),
      let document = fixture["document"]
    else {
      throw AbbeyContractError.fixtureInvalid(path: boundedPath(relativePath))
    }

    let actual: AbbeyContractReasonCode
    if hasDuplicateMember {
      actual = .duplicateMember
    } else if !Self.isPrivacySafe(document) {
      actual = .forbiddenContent
    } else if caseID == "jcs_number_outside_safe_domain", Self.containsUnsafeJCSNumber(document) {
      actual = .numericDomain
    } else if let preSchema = Self.preSchemaReason(schemaID: schemaID, document: document) {
      actual = preSchema
    } else if let wrappedSchema = schemas[schemaID] {
      let schema = wrappedSchema.mapValues(\.value)
      let limit = schema["x-abbey-max-bytes"] as? Int ?? maximumArtifactBytes
      let documentBytes = try JSONSerialization.data(
        withJSONObject: document, options: [.sortedKeys])
      if documentBytes.count > limit {
        actual = .schemaInvalid
      } else if !Self.validate(document, schema: schema, ownerID: schemaID, registry: schemas) {
        actual = .schemaInvalid
      } else {
        actual = Self.semanticReason(schemaID: schemaID, document: document) ?? .valid
      }
    } else {
      actual = .schemaInvalid
    }
    return AbbeyFixtureDisposition(actual: actual, expected: expected)
  }

  public func decodeMetadataEventFixture(at relativePath: String) throws -> AbbeyMetadataEvent {
    try decodeDocument(AbbeyMetadataEvent.self, at: relativePath)
  }

  public func decodeOperatorVerificationReportFixture(
    at relativePath: String
  ) throws -> AbbeyOperatorVerificationReport {
    try decodeDocument(AbbeyOperatorVerificationReport.self, at: relativePath)
  }

  private func decodeDocument<T: Decodable>(_ type: T.Type, at relativePath: String) throws -> T {
    let disposition = try decodeFixture(at: relativePath)
    guard disposition.actual == .valid, disposition.expected == .valid else {
      throw AbbeyContractError.fixtureInvalid(path: boundedPath(relativePath))
    }
    let (fixture, _) = try loadFixture(relativePath: relativePath)
    guard let document = fixture["document"] else {
      throw AbbeyContractError.fixtureInvalid(path: boundedPath(relativePath))
    }
    do {
      return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: document))
    } catch {
      throw AbbeyContractError.fixtureInvalid(path: boundedPath(relativePath))
    }
  }

  private func loadFixture(relativePath: String) throws -> ([String: Any], Bool) {
    let safePath = try validateRelativePath(relativePath)
    let data = try readBounded(corpusURL.appending(path: safePath), displayPath: safePath)
    do {
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw AbbeyContractError.fixtureInvalid(path: safePath)
      }
      return (object, try JSONDuplicateMemberScanner.containsDuplicate(in: data))
    } catch let error as AbbeyContractError {
      throw error
    } catch {
      throw AbbeyContractError.fixtureInvalid(path: safePath)
    }
  }

  private static func isPrivacySafe(_ value: Any) -> Bool {
    let forbiddenKeys: Set<String> = [
      "audio", "transcript", "message", "prompt", "response_text", "credential",
      "token", "password", "username", "display_name", "filesystem_path",
      "participant_identity",
    ]
    if let object = value as? [String: Any] {
      for (key, nested) in object {
        if forbiddenKeys.contains(key.lowercased()) || !isPrivacySafe(nested) { return false }
      }
    } else if let array = value as? [Any] {
      return array.allSatisfy(isPrivacySafe)
    } else if let string = value as? String {
      let isSnowflake = (17...20).contains(string.count) && string.allSatisfy(\.isNumber)
      let hasSensitivePrefix = ["/Users/", "/home/", "C:\\", "sk-", "ghp_"].contains {
        string.hasPrefix($0)
      }
      return !isSnowflake && !hasSensitivePrefix
    }
    return true
  }

  private static func containsUnsafeJCSNumber(_ value: Any) -> Bool {
    if let object = value as? [String: Any] {
      return object.values.contains(where: containsUnsafeJCSNumber)
    }
    if let array = value as? [Any] { return array.contains(where: containsUnsafeJCSNumber) }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
      return false
    }
    return abs(number.doubleValue) > 9_007_199_254_740_991
  }

  private static func preSchemaReason(schemaID: String, document: Any) -> AbbeyContractReasonCode? {
    guard let object = document as? [String: Any] else { return nil }
    if schemaID.hasSuffix("/learning/promotion-candidate.schema.json") {
      let forbidden: Set<String> = [
        "grant", "approval", "safety_policy_mutation", "command_registration",
        "platform_write", "direct_platform_write",
      ]
      if !forbidden.isDisjoint(with: object.keys) { return .learningAuthorityForbidden }
    }
    if schemaID.hasSuffix("/episode/proposal.schema.json"),
      object["priority_class"] as? String == "MandatoryIncident",
      object["minimized"] as? Bool != true || object["redacted"] as? Bool != true
        || object["deletion_required"] as? Bool != true || object["deletion_key"] == nil
        || object["retention_class"] as? String != "mandatory_incident"
    {
      return .mandatoryControlsMissing
    }
    return nil
  }

  private static func semanticReason(schemaID: String, document: Any) -> AbbeyContractReasonCode? {
    guard let object = document as? [String: Any] else { return nil }
    if schemaID.hasSuffix("/identity/delegation-chain.schema.json"),
      let hops = object["hops"] as? [[String: Any]],
      let first = hops.first?["delegator_principal_id"] as? String
    {
      var seen: Set<String> = [first]
      for hop in hops {
        if let delegatee = hop["delegatee_principal_id"] as? String,
          !seen.insert(delegatee).inserted
        {
          return .delegationCycle
        }
      }
    }
    if schemaID.hasSuffix("/authorization/approval.schema.json"),
      object["approver_principal_id"] as? String == object["request_subject_principal_id"]
        as? String
    {
      return .selfApproval
    }
    if schemaID.hasSuffix("/authorization/policy-decision.schema.json"),
      object["reason_code"] as? String == "dependency_unavailable",
      object["decision"] as? String != "deny"
    {
      return .degradedAuthority
    }
    if schemaID.hasSuffix("/cognition/request.schema.json"),
      ["durable_write", "platform_effect"].contains(object["effect_class"] as? String),
      object["idempotency_key"] == nil
    {
      return .idempotencyRequired
    }
    if schemaID.hasSuffix("/event/cancellation.schema.json"),
      object["cancellation_reference"] as? String != object["target_cancellation_reference"]
        as? String
    {
      return .cancellationMismatch
    }
    if schemaID.hasSuffix("/consent/transition.schema.json") {
      let transition =
        (object["from_state"] as? String ?? "") + "->"
        + (object["to_state"] as? String ?? "")
      let allowed: Set<String> = [
        "Closed->PendingAttestation", "PendingAttestation->Open",
        "Open->Closing", "Closing->Closed",
      ]
      if !allowed.contains(transition),
        [
          "participant_change", "unidentified_participant", "attestation_lost",
          "manager_deauthorized", "connection_lost", "explicit_stop",
        ].contains(object["reason_code"] as? String)
      {
        return .consentCloseRequired
      }
      if object["to_state"] as? String == "Open",
        object["manager_authorized"] as? Bool != true
          || object["all_current_participants_consented"] as? Bool != true
          || (object["participant_count"] as? Int ?? 0) <= 0
      {
        return .consentOpenDenied
      }
    }
    if schemaID.hasSuffix("/episode/claim.schema.json"),
      let evidence = evidenceOrdinal(object["evidence_level"] as? String),
      let display = evidenceOrdinal(object["display_evidence_level"] as? String), display > evidence
    {
      return .evidenceOverclaim
    }
    if schemaID.hasSuffix("/learning/guild-learning-policy.schema.json"),
      ["Unset", "ExplicitDisabled"].contains(object["state"] as? String),
      object["adaptive_update_allowed"] as? Bool == true
    {
      return .learningDisabled
    }
    return nil
  }

  private static func evidenceOrdinal(_ level: String?) -> Int? {
    guard let level, level.count == 2, level.first == "C" else { return nil }
    return Int(level.dropFirst())
  }

  private static func validate(
    _ value: Any,
    schema: [String: Any],
    ownerID: String,
    registry: [String: [String: AnySendable]]
  ) -> Bool {
    if let reference = schema["$ref"] as? String {
      guard
        let (target, targetID) = resolve(reference: reference, ownerID: ownerID, registry: registry)
      else { return false }
      return validate(value, schema: target, ownerID: targetID, registry: registry)
    }
    if let constant = schema["const"], !jsonEqual(value, constant) { return false }
    if let allowed = schema["enum"] as? [Any], !allowed.contains(where: { jsonEqual(value, $0) }) {
      return false
    }
    if let all = schema["allOf"] as? [[String: Any]],
      !all.allSatisfy({ validate(value, schema: $0, ownerID: ownerID, registry: registry) })
    {
      return false
    }
    if let one = schema["oneOf"] as? [[String: Any]],
      one.filter({ validate(value, schema: $0, ownerID: ownerID, registry: registry) }).count != 1
    {
      return false
    }
    if let any = schema["anyOf"] as? [[String: Any]],
      !any.contains(where: { validate(value, schema: $0, ownerID: ownerID, registry: registry) })
    {
      return false
    }
    if let type = schema["type"] as? String, !isJSONType(value, type) { return false }
    if let types = schema["type"] as? [String], !types.contains(where: { isJSONType(value, $0) }) {
      return false
    }

    if let string = value as? String {
      if string.count < (schema["minLength"] as? Int ?? 0)
        || string.count > (schema["maxLength"] as? Int ?? .max)
      {
        return false
      }
      if let pattern = schema["pattern"] as? String,
        string.range(of: pattern, options: .regularExpression) == nil
      {
        return false
      }
    }
    if let array = value as? [Any] {
      if array.count < (schema["minItems"] as? Int ?? 0)
        || array.count > (schema["maxItems"] as? Int ?? .max)
      {
        return false
      }
      if schema["uniqueItems"] as? Bool == true {
        for left in array.indices {
          for right in array.indices where right > left {
            if jsonEqual(array[left], array[right]) { return false }
          }
        }
      }
      if let itemSchema = schema["items"] as? [String: Any],
        !array.allSatisfy({ validate($0, schema: itemSchema, ownerID: ownerID, registry: registry) }
        )
      {
        return false
      }
    }
    if let object = value as? [String: Any] {
      if let required = schema["required"] as? [String], !required.allSatisfy({ object[$0] != nil })
      {
        return false
      }
      if object.count < (schema["minProperties"] as? Int ?? 0)
        || object.count > (schema["maxProperties"] as? Int ?? .max)
      {
        return false
      }
      let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
      for (key, nested) in object {
        if let property = properties[key] {
          if !validate(nested, schema: property, ownerID: ownerID, registry: registry) {
            return false
          }
        } else if schema["additionalProperties"] as? Bool == false {
          return false
        } else if let additional = schema["additionalProperties"] as? [String: Any],
          !validate(nested, schema: additional, ownerID: ownerID, registry: registry)
        {
          return false
        }
      }
    }
    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
      if number.doubleValue < (schema["minimum"] as? NSNumber)?.doubleValue ?? number.doubleValue
        || number.doubleValue > (schema["maximum"] as? NSNumber)?.doubleValue ?? number.doubleValue
      {
        return false
      }
    }
    return true
  }

  private static func resolve(
    reference: String,
    ownerID: String,
    registry: [String: [String: AnySendable]]
  ) -> ([String: Any], String)? {
    let pieces = reference.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
    let base = String(pieces[0])
    let targetID = base.isEmpty ? ownerID : base
    guard var target: Any = registry[targetID]?.mapValues(\.value) else { return nil }
    if pieces.count == 2, !pieces[1].isEmpty {
      guard pieces[1].first == "/" else { return nil }
      for rawToken in pieces[1].dropFirst().split(separator: "/") {
        let token = rawToken.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(
          of: "~0", with: "~")
        guard let object = target as? [String: Any], let nested = object[token] else { return nil }
        target = nested
      }
    }
    guard let result = target as? [String: Any] else { return nil }
    return (result, targetID)
  }

  private static func isJSONType(_ value: Any, _ type: String) -> Bool {
    switch type {
    case "object": value is [String: Any]
    case "array": value is [Any]
    case "string": value is String
    case "boolean": (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
    case "integer":
      (value as? NSNumber).map {
        CFGetTypeID($0) != CFBooleanGetTypeID() && floor($0.doubleValue) == $0.doubleValue
      } ?? false
    case "number": (value as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() } ?? false
    case "null": value is NSNull
    default: false
    }
  }

  private static func jsonEqual(_ lhs: Any, _ rhs: Any) -> Bool {
    if lhs is NSNull || rhs is NSNull {
      return lhs is NSNull && rhs is NSNull
    }
    if let lhs = lhs as? String, let rhs = rhs as? String {
      return lhs == rhs
    }
    if let lhs = lhs as? NSNumber, let rhs = rhs as? NSNumber {
      let lhsIsBoolean = CFGetTypeID(lhs) == CFBooleanGetTypeID()
      let rhsIsBoolean = CFGetTypeID(rhs) == CFBooleanGetTypeID()
      if lhsIsBoolean || rhsIsBoolean {
        return lhsIsBoolean && rhsIsBoolean && lhs.boolValue == rhs.boolValue
      }
      return lhs.compare(rhs) == .orderedSame
    }
    if let lhs = lhs as? [Any], let rhs = rhs as? [Any] {
      return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { jsonEqual($0, $1) }
    }
    if let lhs = lhs as? [String: Any], let rhs = rhs as? [String: Any] {
      guard lhs.keys == rhs.keys else { return false }
      return lhs.allSatisfy { key, value in
        guard let other = rhs[key] else { return false }
        return jsonEqual(value, other)
      }
    }
    return false
  }
}

public enum AbbeyContractCorpus {
  private static let expectedRepository = "https://github.com/donaldfilimon/abi"
  private static let expectedSourceRevision = "348754bdaaf59a40fbb858380f925e0aba95a23b"
  private static let expectedAggregateDigest =
    "72e241e34967df318376bf68f4a0e2db13f5ebf17d1a219709731f1f470dbe8e"

  public static func verify(at rootURL: URL) throws -> AbbeyQualifiedCorpus {
    let suppliedRoot = rootURL.standardizedFileURL
    try requireDirectory(suppliedRoot, displayPath: "Abbey")
    let root = suppliedRoot.resolvingSymlinksInPath()
    let rootEntries = try Set(FileManager.default.contentsOfDirectory(atPath: root.path()))
    guard rootEntries == ["abbey-contracts.lock.json", "corpus"] else {
      throw AbbeyContractError.inventoryMismatch(path: "Abbey")
    }

    let lockData = try readBounded(
      root.appending(path: "abbey-contracts.lock.json"), displayPath: "abbey-contracts.lock.json")
    let lockObject: [String: Any]
    do { lockObject = try strictJSONObject(lockData, path: "abbey-contracts.lock.json") } catch {
      throw AbbeyContractError.lockInvalid(path: "abbey-contracts.lock.json")
    }
    guard
      Set(lockObject.keys) == [
        "source_repository", "source_revision", "contract_major", "contract_revision",
        "aggregate_digest",
      ]
    else { throw AbbeyContractError.lockInvalid(path: "abbey-contracts.lock.json") }
    let lock: Lock
    do { lock = try JSONDecoder().decode(Lock.self, from: lockData) } catch {
      throw AbbeyContractError.lockInvalid(path: "abbey-contracts.lock.json")
    }
    guard lock.sourceRepository == expectedRepository,
      lock.sourceRevision == expectedSourceRevision,
      lock.contractMajor == 1,
      lock.contractRevision == 1,
      lock.aggregateDigest == expectedAggregateDigest
    else { throw AbbeyContractError.lockInvalid(path: "abbey-contracts.lock.json") }

    let corpus = root.appending(path: "corpus", directoryHint: .isDirectory)
    try requireDirectory(corpus, displayPath: "corpus")
    let manifestData = try readBounded(
      corpus.appending(path: "manifest.json"), displayPath: "manifest.json")
    let manifestObject: [String: Any]
    do { manifestObject = try strictJSONObject(manifestData, path: "manifest.json") } catch {
      throw AbbeyContractError.manifestInvalid(path: "manifest.json")
    }
    guard
      Set(manifestObject.keys) == [
        "contract_major", "contract_revision", "algorithm", "redaction_profile", "artifacts",
        "aggregate_digest",
      ]
    else { throw AbbeyContractError.manifestInvalid(path: "manifest.json") }
    let manifest: Manifest
    do { manifest = try JSONDecoder().decode(Manifest.self, from: manifestData) } catch {
      throw AbbeyContractError.manifestInvalid(path: "manifest.json")
    }
    guard let rawArtifacts = manifestObject["artifacts"] as? [[String: Any]],
      rawArtifacts.count == manifest.artifacts.count
    else { throw AbbeyContractError.manifestInvalid(path: "manifest.json") }
    guard manifest.algorithm == "abbey-contract-corpus-sha256-v1",
      manifest.redactionProfile == "abbey-contract-redaction-v1",
      manifest.contractMajor == 1,
      manifest.contractRevision == 1,
      manifest.contractMajor == lock.contractMajor,
      manifest.contractRevision == lock.contractRevision,
      manifest.aggregateDigest == lock.aggregateDigest
    else { throw AbbeyContractError.manifestInvalid(path: "manifest.json") }

    var indexed: [String: Artifact] = [:]
    var totalBytes = 0
    var schemas: [String: [String: AnySendable]] = [:]
    for (artifact, rawArtifact) in zip(manifest.artifacts, rawArtifacts) {
      let requiredKeys: Set<String> = ["path", "bytes", "media_type", "sha256"]
      let allowedKeys = requiredKeys.union(["schema_id"])
      let path = try validateRelativePath(artifact.path)
      let expectedMediaType =
        path.hasSuffix(".schema.json")
        ? "application/schema+json"
        : path.hasSuffix(".json") ? "application/json" : "text/markdown; charset=utf-8"
      guard requiredKeys.isSubset(of: rawArtifact.keys),
        Set(rawArtifact.keys).isSubset(of: allowedKeys),
        indexed[path] == nil,
        artifact.bytes >= 0,
        artifact.bytes <= maximumArtifactBytes,
        artifact.mediaType == expectedMediaType,
        artifact.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
      else { throw AbbeyContractError.manifestInvalid(path: "manifest.json") }
      indexed[path] = artifact
      let data = try readBounded(corpus.appending(path: path), displayPath: path)
      guard data.count == artifact.bytes else {
        throw AbbeyContractError.artifactInvalid(path: path)
      }
      guard hexadecimalDigest(data) == artifact.sha256 else {
        throw AbbeyContractError.artifactDigestMismatch(path: path)
      }
      totalBytes += data.count
      if let schemaID = artifact.schemaID {
        let object = try strictJSONObject(data, path: path)
        guard object["$id"] as? String == schemaID else {
          throw AbbeyContractError.manifestInvalid(path: path)
        }
        schemas[schemaID] = object.mapValues(AnySendable.init)
      }
    }
    guard totalBytes <= maximumCorpusBytes else {
      throw AbbeyContractError.manifestInvalid(path: "manifest.json")
    }
    let discovered = try discoverArtifacts(in: corpus)
    guard discovered == Set(indexed.keys) else {
      throw AbbeyContractError.inventoryMismatch(path: "corpus")
    }

    let aggregate = try aggregateDigest(manifest: manifest, rawManifest: manifestData)
    guard aggregate == manifest.aggregateDigest else {
      throw AbbeyContractError.aggregateDigestMismatch(path: "manifest.json")
    }
    return AbbeyQualifiedCorpus(
      sourceRevision: lock.sourceRevision,
      aggregateDigest: aggregate,
      artifactCount: indexed.count,
      totalBytes: totalBytes,
      fixturePaths: indexed.keys.filter { $0.contains("/fixtures/") }.sorted(),
      corpusURL: corpus,
      schemas: schemas
    )
  }

  public static func verifyBundled() throws -> AbbeyQualifiedCorpus {
    guard let resourceURL = Bundle.module.resourceURL else {
      throw AbbeyContractError.artifactUnreadable(path: "Abbey")
    }
    return try verify(at: resourceURL.appending(path: "Abbey", directoryHint: .isDirectory))
  }

  private static func aggregateDigest(manifest: Manifest, rawManifest: Data) throws -> String {
    guard let manifestText = String(data: rawManifest, encoding: .utf8) else {
      throw AbbeyContractError.manifestInvalid(path: "manifest.json")
    }
    let needle = "\"aggregate_digest\": \"" + manifest.aggregateDigest + "\""
    let replacement = "\"aggregate_digest\": \"" + String(repeating: "0", count: 64) + "\""
    guard manifestText.components(separatedBy: needle).count == 2 else {
      throw AbbeyContractError.manifestInvalid(path: "manifest.json")
    }
    let zeroed = Data(manifestText.replacingOccurrences(of: needle, with: replacement).utf8)
    var rows = manifest.artifacts
    rows.append(
      Artifact(
        path: "manifest.json", bytes: zeroed.count, mediaType: "application/json",
        sha256: hexadecimalDigest(zeroed), schemaID: nil))
    rows.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    var digest = SHA256()
    digest.update(data: Data("abbey-contract-corpus-v1\0".utf8))
    for row in rows {
      digest.update(data: Data(row.path.utf8))
      digest.update(data: Data([0]))
      digest.update(data: Data(String(row.bytes).utf8))
      digest.update(data: Data([0]))
      digest.update(data: Data(row.sha256.utf8))
      digest.update(data: Data([10]))
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

private let maximumArtifactBytes = 1_024 * 1_024
private let maximumCorpusBytes = 16 * 1_024 * 1_024

private struct Lock: Decodable {
  let sourceRepository, sourceRevision, aggregateDigest: String
  let contractMajor, contractRevision: Int

  enum CodingKeys: String, CodingKey {
    case sourceRepository = "source_repository"
    case sourceRevision = "source_revision"
    case contractMajor = "contract_major"
    case contractRevision = "contract_revision"
    case aggregateDigest = "aggregate_digest"
  }
}

private struct Manifest: Decodable {
  let contractMajor, contractRevision: Int
  let algorithm, redactionProfile, aggregateDigest: String
  let artifacts: [Artifact]

  enum CodingKeys: String, CodingKey {
    case contractMajor = "contract_major"
    case contractRevision = "contract_revision"
    case algorithm
    case redactionProfile = "redaction_profile"
    case artifacts
    case aggregateDigest = "aggregate_digest"
  }
}

private struct Artifact: Decodable {
  let path: String
  let bytes: Int
  let mediaType, sha256: String
  let schemaID: String?

  enum CodingKeys: String, CodingKey {
    case path, bytes
    case mediaType = "media_type"
    case sha256
    case schemaID = "schema_id"
  }
}

private struct AnySendable: @unchecked Sendable {
  let value: Any
  init(_ value: Any) { self.value = value }
}

private struct JSONDuplicateMemberScanner {
  private let bytes: [UInt8]
  private var index = 0
  private var duplicateFound = false

  static func containsDuplicate(in data: Data) throws -> Bool {
    var scanner = Self(bytes: Array(data))
    try scanner.parseValue(depth: 0)
    scanner.skipWhitespace()
    guard scanner.index == scanner.bytes.count else { throw JSONScanError.invalid }
    return scanner.duplicateFound
  }

  private mutating func parseValue(depth: Int) throws {
    guard depth <= 128 else { throw JSONScanError.invalid }
    skipWhitespace()
    guard let byte = peek() else { throw JSONScanError.invalid }
    switch byte {
    case 0x7B: try parseObject(depth: depth + 1)
    case 0x5B: try parseArray(depth: depth + 1)
    case 0x22: _ = try parseString()
    case 0x74: try consumeLiteral("true")
    case 0x66: try consumeLiteral("false")
    case 0x6E: try consumeLiteral("null")
    case 0x2D, 0x30...0x39: parseNumber()
    default: throw JSONScanError.invalid
    }
  }

  private mutating func parseObject(depth: Int) throws {
    try consume(0x7B)
    skipWhitespace()
    if consumeIfPresent(0x7D) { return }
    var keys: Set<String> = []
    while true {
      skipWhitespace()
      let key = try parseString()
      if !keys.insert(key).inserted { duplicateFound = true }
      skipWhitespace()
      try consume(0x3A)
      try parseValue(depth: depth)
      skipWhitespace()
      if consumeIfPresent(0x7D) { return }
      try consume(0x2C)
    }
  }

  private mutating func parseArray(depth: Int) throws {
    try consume(0x5B)
    skipWhitespace()
    if consumeIfPresent(0x5D) { return }
    while true {
      try parseValue(depth: depth)
      skipWhitespace()
      if consumeIfPresent(0x5D) { return }
      try consume(0x2C)
    }
  }

  private mutating func parseString() throws -> String {
    let start = index
    try consume(0x22)
    while let byte = peek() {
      index += 1
      if byte == 0x22 {
        let encoded = Data(bytes[start..<index])
        guard let value = try? JSONDecoder().decode(String.self, from: encoded) else {
          throw JSONScanError.invalid
        }
        return value
      }
      if byte < 0x20 { throw JSONScanError.invalid }
      if byte == 0x5C {
        guard let escaped = peek() else { throw JSONScanError.invalid }
        index += 1
        if escaped == 0x75 {
          guard index + 4 <= bytes.count,
            bytes[index..<(index + 4)].allSatisfy(Self.isHexDigit)
          else { throw JSONScanError.invalid }
          index += 4
        } else if ![0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(escaped) {
          throw JSONScanError.invalid
        }
      }
    }
    throw JSONScanError.invalid
  }

  private mutating func parseNumber() {
    while let byte = peek(),
      byte == 0x2D || byte == 0x2B || byte == 0x2E || byte == 0x45 || byte == 0x65
        || (0x30...0x39).contains(byte)
    {
      index += 1
    }
  }

  private mutating func consumeLiteral(_ literal: String) throws {
    let literalBytes = Array(literal.utf8)
    guard index + literalBytes.count <= bytes.count,
      Array(bytes[index..<(index + literalBytes.count)]) == literalBytes
    else { throw JSONScanError.invalid }
    index += literalBytes.count
  }

  private mutating func skipWhitespace() {
    while let byte = peek(), [0x20, 0x09, 0x0A, 0x0D].contains(byte) { index += 1 }
  }

  private mutating func consume(_ byte: UInt8) throws {
    guard consumeIfPresent(byte) else { throw JSONScanError.invalid }
  }

  private mutating func consumeIfPresent(_ byte: UInt8) -> Bool {
    guard peek() == byte else { return false }
    index += 1
    return true
  }

  private func peek() -> UInt8? {
    index < bytes.count ? bytes[index] : nil
  }

  private static func isHexDigit(_ byte: UInt8) -> Bool {
    (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
  }
}

private enum JSONScanError: Error {
  case invalid
}

private func validateRelativePath(_ path: String) throws -> String {
  guard !path.isEmpty, path.utf8.count <= 256, !path.contains("\\"), !path.hasPrefix("/"),
    !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
      $0.isEmpty || $0 == "." || $0 == ".."
    })
  else { throw AbbeyContractError.pathInvalid(path: boundedPath(path)) }
  return path
}

private func boundedPath(_ path: String) -> String {
  let normalized = path.replacingOccurrences(of: "\\", with: "/")
  return normalized.count <= 256 ? normalized : String(normalized.prefix(253)) + "..."
}

private func requireDirectory(_ url: URL, displayPath: String) throws {
  do {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw AbbeyContractError.artifactInvalid(path: displayPath)
    }
  } catch let error as AbbeyContractError { throw error } catch {
    throw AbbeyContractError.artifactUnreadable(path: displayPath)
  }
}

private func readBounded(_ url: URL, displayPath: String) throws -> Data {
  do {
    let values = try url.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, size <= maximumArtifactBytes
    else { throw AbbeyContractError.artifactInvalid(path: displayPath) }
    return try Data(contentsOf: url, options: [.mappedIfSafe])
  } catch let error as AbbeyContractError { throw error } catch {
    throw AbbeyContractError.artifactUnreadable(path: displayPath)
  }
}

private func strictJSONObject(_ data: Data, path: String) throws -> [String: Any] {
  do {
    guard try !JSONDuplicateMemberScanner.containsDuplicate(in: data) else {
      throw AbbeyContractError.jsonInvalid(path: path)
    }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw AbbeyContractError.jsonInvalid(path: path)
    }
    return object
  } catch let error as AbbeyContractError { throw error } catch {
    throw AbbeyContractError.jsonInvalid(path: path)
  }
}

private func discoverArtifacts(in corpus: URL) throws -> Set<String> {
  guard let enumerator = FileManager.default.enumerator(atPath: corpus.path()) else {
    throw AbbeyContractError.artifactUnreadable(path: "corpus")
  }
  var result: Set<String> = []
  for case let relative as String in enumerator {
    let url = corpus.appending(path: relative)
    let values = try url.resourceValues(forKeys: [
      .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
    ])
    if values.isSymbolicLink == true {
      throw AbbeyContractError.artifactInvalid(path: boundedPath(relative))
    }
    if values.isRegularFile == true, relative != "manifest.json" {
      result.insert(try validateRelativePath(relative))
    }
  }
  return result
}

private func hexadecimalDigest(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
