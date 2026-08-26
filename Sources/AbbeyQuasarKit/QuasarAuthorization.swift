import Crypto
import Foundation

public enum QuasarProposalAction: String, Codable, Sendable { case create, edit, archive, previewStart, previewStop }

public struct QuasarAuthorizationFacts: Codable, Equatable, Sendable {
    public var guildID: String
    public var initiatorID: String
    public var ownerAllowed: Bool
    public var discordPermissionAllowed: Bool
    public var guildOptedIn: Bool
    public var quiet: Bool
    public var remainingBudget: Int

    /// Read-only Discord surfaces still reveal local site identities and status,
    /// so they require the same owner, Discord, opt-in, and QUIET facts. Budget
    /// is deliberately excluded because inspection is not a mutation.
    public var permitsRead: Bool {
        ownerAllowed && discordPermissionAllowed && guildOptedIn && !quiet
    }

    public var permitsMutation: Bool {
        permitsRead && remainingBudget > 0
    }

    public static func current(
        guildID: String,
        initiatorID: String,
        discordPermissionAllowed: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self {
        func values(_ key: String) -> Set<String> {
            Set((environment[key] ?? "").split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty })
        }
        let quietValue = (environment["ABBEY_QUIET"] ?? "").lowercased()
        let budgetKey = "ABBEY_QUASAR_GUILD_BUDGET_\(guildID)"
        let budget = Int(environment[budgetKey] ?? environment["ABBEY_QUASAR_GUILD_BUDGET"] ?? "0") ?? 0
        return Self(
            guildID: guildID,
            initiatorID: initiatorID,
            ownerAllowed: values("DISCORD_OPERATOR_USER_IDS").contains(initiatorID),
            discordPermissionAllowed: discordPermissionAllowed,
            guildOptedIn: values("ABBEY_QUASAR_GUILD_IDS").contains(guildID),
            quiet: ["1", "true", "yes", "on"].contains(quietValue),
            remainingBudget: max(budget, 0)
        )
    }
}

public struct QuasarProposal: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var action: QuasarProposalAction
    public var siteID: String?
    public var summary: String
    public var impact: String
    public var rollback: String
    /// SHA-256 of the short-lived in-memory request payload; no prompt content is retained here.
    public var payloadDigest: String
    public var digest: String
    public var createdAt: Date
    public var expiresAt: Date
    public var facts: QuasarAuthorizationFacts
}

public actor QuasarProposalGate {
    private static let maximumPendingProposals = 256
    private var proposals: [UUID: QuasarProposal] = [:]
    public init() {}

    public func propose(
        action: QuasarProposalAction,
        siteID: String?,
        summary: String,
        impact: String,
        rollback: String,
        facts: QuasarAuthorizationFacts,
        payloadDigest: String = "",
        lifetime: Duration = .seconds(300)
    ) throws -> QuasarProposal {
        _ = pruneExpired()
        guard proposals.count < Self.maximumPendingProposals else {
            throw QuasarError.budgetExceeded("pending proposal count")
        }
        guard facts.permitsMutation else { throw QuasarError.authorizationDenied("current guild policy facts do not permit proposals") }
        guard (1...512).contains(summary.utf8.count),
              (1...1_024).contains(impact.utf8.count),
              (1...1_024).contains(rollback.utf8.count),
              payloadDigest.isEmpty || (payloadDigest.count == 64 && payloadDigest.allSatisfy({ $0.isHexDigit && !$0.isUppercase })),
              siteID.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true,
              !facts.guildID.isEmpty,
              facts.guildID.utf8.count <= 128,
              !facts.initiatorID.isEmpty,
              facts.initiatorID.utf8.count <= 128
        else { throw QuasarError.invalidInput("proposal metadata is invalid") }
        let now = Date()
        let seconds = Double(lifetime.components.seconds) + Double(lifetime.components.attoseconds) / 1e18
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let factDigest = SHA256.hash(data: try encoder.encode(facts)).map { String(format: "%02x", $0) }.joined()
        let digestInput = [action.rawValue, siteID ?? "", summary, impact, rollback, payloadDigest, factDigest].joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(digestInput.utf8)).map { String(format: "%02x", $0) }.joined()
        let proposal = QuasarProposal(id: UUID(), action: action, siteID: siteID, summary: summary, impact: impact, rollback: rollback, payloadDigest: payloadDigest, digest: digest, createdAt: now, expiresAt: now.addingTimeInterval(min(max(seconds, 1), 300)), facts: facts)
        proposals[proposal.id] = proposal
        return proposal
    }

    public func pending(now: Date = Date()) -> [QuasarProposal] {
        for id in proposals.compactMap({ $0.value.expiresAt <= now ? $0.key : nil }) { proposals[id] = nil }
        return proposals.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func pruneExpired(now: Date = Date()) -> [UUID] {
        let expired = proposals.compactMap { $0.value.expiresAt <= now ? $0.key : nil }
        for id in expired { proposals[id] = nil }
        return expired
    }

    /// Desktop-only approval. Revalidation facts must exactly match the proposal's facts.
    public func approve(id: UUID, digest: String, revalidated facts: QuasarAuthorizationFacts, desktopConfirmed: Bool) throws -> QuasarProposal {
        guard desktopConfirmed else { throw QuasarError.authorizationDenied("desktop confirmation is required") }
        guard let proposal = proposals[id] else { throw QuasarError.notFound }
        guard proposal.expiresAt > Date() else { proposals[id] = nil; throw QuasarError.proposalExpired }
        guard proposal.digest == digest, proposal.facts == facts else { proposals[id] = nil; throw QuasarError.proposalChanged }
        guard facts.permitsMutation else { proposals[id] = nil; throw QuasarError.authorizationDenied("policy no longer permits this effect") }
        proposals[id] = nil
        return proposal
    }

    public func cancel(id: UUID) { proposals[id] = nil }
}
