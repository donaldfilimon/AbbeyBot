import Foundation
// Explicit, like AppConfig.swift: the Apple SDK makes `@Observable` visible
// through Foundation, but corelibs Foundation on Linux does not — without
// this the server graph fails to compile with "unknown attribute 'Observable'".

import Observation

/// In-memory counters for the Dashboard view. Deliberately not persisted — these reset
/// each launch, since they describe "this session," not historical fact (historical
/// fact lives in the SwiftData models and is queried directly by the views that need it).
///
/// `@unchecked Sendable` because actors (`InferenceRouter`, `AbbeyScheduler`) and the
/// `@MainActor` engine both mutate these counters; values are simple scalars with no
/// cross-thread invariants beyond "best-effort session telemetry."
@Observable
public final class EngineMetrics: @unchecked Sendable {
    public private(set) var messagesIngestedThisSession: Int = 0
    public private(set) var reputationEventsThisSession: Int = 0
    public private(set) var inferenceCallsByMode: [InferenceMode: Int] = [:]
    public private(set) var inferenceFailuresByMode: [InferenceMode: Int] = [:]
    public private(set) var destructiveActionsConfirmed: Int = 0
    public private(set) var destructiveActionsCancelled: Int = 0
    public private(set) var storeDegraded: Bool = false
    public private(set) var lastConsolidationAt: Date?
    public private(set) var lastInferenceFailureMessage: String?

    public init() {}

    public func recordMessageIngested() {
        messagesIngestedThisSession += 1
    }

    public func recordReputationEvent() {
        reputationEventsThisSession += 1
    }

    public func recordInferenceCall(mode: InferenceMode, succeeded: Bool) {
        inferenceCallsByMode[mode, default: 0] += 1
        if !succeeded {
            inferenceFailuresByMode[mode, default: 0] += 1
        } else {
            lastInferenceFailureMessage = nil
        }
    }

    public func recordInferenceFailureMessage(_ message: String) {
        lastInferenceFailureMessage = message
    }

    public func recordDestructiveAction(confirmed: Bool) {
        if confirmed {
            destructiveActionsConfirmed += 1
        } else {
            destructiveActionsCancelled += 1
        }
    }

    public func recordConsolidation() {
        lastConsolidationAt = .now
    }

    public func markStoreDegraded() {
        storeDegraded = true
    }

    public var totalInferenceCalls: Int {
        inferenceCallsByMode.values.reduce(0, +)
    }

    public var totalInferenceFailures: Int {
        inferenceFailuresByMode.values.reduce(0, +)
    }
}
