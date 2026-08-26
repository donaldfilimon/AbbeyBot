import Foundation

public enum KnowledgeProvenance: String, Codable, CaseIterable, Sendable {
    case measured
    case target
    case reported
}

public enum KnowledgeTrustClassification: String, Codable, CaseIterable, Sendable {
    case constitutional
    case authoritative
    case explanatory
    case compatibility
}

public struct KnowledgeDocument: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var content: String
    public var sourceRepository: String
    public var sourceRevision: String
    public var sourcePath: String
    public var contentDigest: String
    public var scopes: Set<String>
    public var provenance: KnowledgeProvenance
    public var trustClassification: KnowledgeTrustClassification
    public var authority: Double
    public var supersedes: Set<String>

    public init(
        id: String,
        title: String,
        content: String,
        sourceRepository: String,
        sourceRevision: String,
        sourcePath: String,
        contentDigest: String,
        scopes: Set<String>,
        provenance: KnowledgeProvenance,
        trustClassification: KnowledgeTrustClassification = .authoritative,
        authority: Double = 0.5,
        supersedes: Set<String> = []
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.sourceRepository = sourceRepository
        self.sourceRevision = sourceRevision
        self.sourcePath = sourcePath
        self.contentDigest = contentDigest
        self.scopes = scopes
        self.provenance = provenance
        self.trustClassification = trustClassification
        self.authority = min(max(authority, 0), 1)
        self.supersedes = supersedes
    }
}

public struct KnowledgeQuery: Sendable {
    public var text: String
    public var requiredScopes: Set<String>
    public var callerScope: String?
    public var evidenceBudget: Int
    public var sourceRevision: String?

    public init(
        text: String,
        requiredScopes: Set<String> = [],
        callerScope: String? = nil,
        evidenceBudget: Int = 6,
        sourceRevision: String? = nil
    ) {
        self.text = text
        self.requiredScopes = requiredScopes
        self.callerScope = callerScope
        self.evidenceBudget = min(max(evidenceBudget, 1), 12)
        self.sourceRevision = sourceRevision
    }
}

public struct KnowledgeScore: Codable, Hashable, Sendable {
    public var lexical: Double
    public var authority: Double
    public var revision: Double
    public var scope: Double
    public var contradiction: Double

    public var total: Double {
        lexical * 0.42 + authority * 0.25 + revision * 0.08 + scope * 0.2 - contradiction * 0.05
    }
}

public struct KnowledgeHit: Codable, Hashable, Sendable, Identifiable {
    public var id: String { documentID }
    public var documentID: String
    public var title: String
    public var excerpt: String
    public var score: KnowledgeScore
    public var provenance: KnowledgeProvenance
    public var sourceRepository: String
    public var sourceRevision: String
    public var sourcePath: String
    public var contentDigest: String
}

public struct KnowledgeRefreshReport: Codable, Equatable, Sendable {
    public var additions: [String]
    public var removals: [String]
    public var changedDigests: [String]
    public var classificationChanges: [String]
    public var unresolvedDrift: [String]

    public init(
        additions: [String] = [],
        removals: [String] = [],
        changedDigests: [String] = [],
        classificationChanges: [String] = [],
        unresolvedDrift: [String] = []
    ) {
        self.additions = additions
        self.removals = removals
        self.changedDigests = changedDigests
        self.classificationChanges = classificationChanges
        self.unresolvedDrift = unresolvedDrift
    }

    public var isClean: Bool {
        additions.isEmpty && removals.isEmpty && changedDigests.isEmpty
            && classificationChanges.isEmpty && unresolvedDrift.isEmpty
    }
}
