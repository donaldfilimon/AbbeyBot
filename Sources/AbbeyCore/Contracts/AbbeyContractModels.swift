import Foundation

public protocol AbbeyClosedStringEnum: Codable, RawRepresentable, Equatable
where RawValue == String {}

extension AbbeyClosedStringEnum {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    guard let value = Self(rawValue: raw) else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "unknown_contract_enum")
    }
    self = value
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public enum AbbeyRiskClass: String, AbbeyClosedStringEnum, Sendable {
  case informational = "Informational"
  case low = "Low"
  case medium = "Medium"
  case high = "High"
  case prohibited = "Prohibited"
}

public enum AbbeyConsentState: String, AbbeyClosedStringEnum, Sendable {
  case closed = "Closed"
  case pendingAttestation = "PendingAttestation"
  case open = "Open"
  case closing = "Closing"
}

public enum AbbeyLearningState: String, AbbeyClosedStringEnum, Sendable {
  case unset = "Unset"
  case explicitEnabled = "ExplicitEnabled"
  case explicitDisabled = "ExplicitDisabled"
}

public enum AbbeyResponseTerminalState: String, AbbeyClosedStringEnum, Sendable {
  case complete, cancelled, error
  case outcomeUnresolved = "outcome_unresolved"
}

public enum AbbeyClaimClass: String, AbbeyClosedStringEnum, Sendable {
  case observation = "Observation"
  case inference = "Inference"
  case proposedCriterion = "ProposedCriterion"
}

public enum AbbeyCapabilityState: String, AbbeyClosedStringEnum, Sendable {
  case proposed = "Proposed"
  case partial = "Partial"
  case current = "Current"
  case failed = "Failed"
  case revoked = "Revoked"
  case superseded = "Superseded"
  case expired = "Expired"
}

public enum AbbeyEvidenceLevel: String, AbbeyClosedStringEnum, Sendable {
  case c0 = "C0"
  case c1 = "C1"
  case c2 = "C2"
  case c3 = "C3"
  case c4 = "C4"
  case c5 = "C5"
  case c6 = "C6"
  case c7 = "C7"
}

public enum AbbeyContractReasonCode: String, AbbeyClosedStringEnum, Sendable {
  case valid
  case schemaInvalid = "schema_invalid"
  case numericDomain = "numeric_domain"
  case duplicateMember = "duplicate_member"
  case mandatoryControlsMissing = "mandatory_controls_missing"
  case evidenceOverclaim = "evidence_overclaim"
  case delegationCycle = "delegation_cycle"
  case selfApproval = "self_approval"
  case degradedAuthority = "degraded_authority"
  case idempotencyRequired = "idempotency_required"
  case cancellationMismatch = "cancellation_mismatch"
  case consentCloseRequired = "consent_close_required"
  case consentOpenDenied = "consent_open_denied"
  case learningAuthorityForbidden = "learning_authority_forbidden"
  case learningDisabled = "learning_disabled"
  case forbiddenContent = "forbidden_content"
  case authentication, authorization, approval, consent, schema, version
  case corpusMismatch = "corpus_mismatch"
  case deadline, cancellation, rate, budget, dependency, verification, compensation
  case outcomeUnresolved = "outcome_unresolved"
}

public enum AbbeyJSONScalar: Codable, Equatable, Sendable {
  case string(String)
  case integer(Int)
  case bool(Bool)
  case null

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .integer(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "extension_scalar_invalid")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}

public struct AbbeyMetadataEvent: Codable, Equatable, Sendable {
  public let correlationID: String
  public let sequence: String
  public let eventKind: String
  public let occurredAt: String
  public let extensions: [String: AbbeyJSONScalar]

  enum CodingKeys: String, CodingKey {
    case correlationID = "correlation_id"
    case sequence
    case eventKind = "event_kind"
    case occurredAt = "occurred_at"
    case extensions
  }
}

public enum AbbeyEvidenceClassification: String, AbbeyClosedStringEnum, Sendable {
  case localTest = "local_test"
  case installedArtifact = "installed_artifact"
  case liveDiscord = "live_discord"
}

public enum AbbeyOperatorTerminalStatus: String, AbbeyClosedStringEnum, Sendable {
  case complete, cancelled, failed
  case outcomeUnresolved = "outcome_unresolved"
}

public struct AbbeyOperatorVerificationReport: Codable, Equatable, Sendable {
  public let verifierBuildID: String
  public let contractRevision: Int
  public let authorizationResult: String
  public let epochOpenCount, epochCloseCount, participantChangeCount: Int
  public let decodedReceiveCount, sttCompletionCount, synthesisCompletionCount: Int
  public let playbackCompletionCount, bargeInCancellationCount: Int
  public let pauseCount, resumeCount, finalLeaveCount: Int
  public let durationMilliseconds: String
  public let terminalStatus: AbbeyOperatorTerminalStatus
  public let evidenceClassification: AbbeyEvidenceClassification
  public let redacted, truncated: Bool

  enum CodingKeys: String, CodingKey {
    case verifierBuildID = "verifier_build_id"
    case contractRevision = "contract_revision"
    case authorizationResult = "authorization_result"
    case epochOpenCount = "epoch_open_count"
    case epochCloseCount = "epoch_close_count"
    case participantChangeCount = "participant_change_count"
    case decodedReceiveCount = "decoded_receive_count"
    case sttCompletionCount = "stt_completion_count"
    case synthesisCompletionCount = "synthesis_completion_count"
    case playbackCompletionCount = "playback_completion_count"
    case bargeInCancellationCount = "barge_in_cancellation_count"
    case pauseCount = "pause_count"
    case resumeCount = "resume_count"
    case finalLeaveCount = "final_leave_count"
    case durationMilliseconds = "duration_ms"
    case terminalStatus = "terminal_status"
    case evidenceClassification = "evidence_classification"
    case redacted, truncated
  }
}

public struct AbbeyFixtureDisposition: Equatable, Sendable {
  public let actual: AbbeyContractReasonCode
  public let expected: AbbeyContractReasonCode
}

public enum AbbeyContractError: Error, Equatable, CustomStringConvertible, Sendable {
  case artifactUnreadable(path: String)
  case artifactInvalid(path: String)
  case pathInvalid(path: String)
  case jsonInvalid(path: String)
  case lockInvalid(path: String)
  case manifestInvalid(path: String)
  case inventoryMismatch(path: String)
  case artifactDigestMismatch(path: String)
  case aggregateDigestMismatch(path: String)
  case fixtureInvalid(path: String)

  public var description: String {
    switch self {
    case .artifactUnreadable(let path): "artifact_unreadable:\(path)"
    case .artifactInvalid(let path): "artifact_invalid:\(path)"
    case .pathInvalid(let path): "path_invalid:\(path)"
    case .jsonInvalid(let path): "json_invalid:\(path)"
    case .lockInvalid(let path): "lock_invalid:\(path)"
    case .manifestInvalid(let path): "manifest_invalid:\(path)"
    case .inventoryMismatch(let path): "inventory_mismatch:\(path)"
    case .artifactDigestMismatch(let path): "artifact_digest_mismatch:\(path)"
    case .aggregateDigestMismatch(let path): "aggregate_digest_mismatch:\(path)"
    case .fixtureInvalid(let path): "fixture_invalid:\(path)"
    }
  }
}
