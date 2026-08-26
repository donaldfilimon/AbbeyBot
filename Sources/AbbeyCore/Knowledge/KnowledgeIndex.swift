import Foundation

/// A disposable, actor-isolated projection over a signed knowledge snapshot.
/// It is deliberately not the canonical WDBX store and never owns raw user memory.
public actor KnowledgeIndex {
    private var documents: [KnowledgeDocument]

    public init(documents: [KnowledgeDocument] = []) {
        self.documents = documents
    }

    public func replace(with verifiedDocuments: [KnowledgeDocument]) {
        documents = verifiedDocuments
    }

    public func search(_ query: KnowledgeQuery) -> [KnowledgeHit] {
        let terms = Self.terms(in: query.text)
        guard !terms.isEmpty else { return [] }
        let superseded = Set(documents.flatMap(\.supersedes))

        return documents.compactMap { document in
            // Supersession is a current-authority boundary, not a small ranking
            // hint. A document named by a newer verified entry never appears in
            // current search results and therefore cannot be quoted as current.
            guard !superseded.contains(document.id) else { return nil }
            guard query.sourceRevision.map({ $0 == document.sourceRevision }) ?? true else { return nil }
            guard query.requiredScopes.isSubset(of: document.scopes) else { return nil }
            if let caller = query.callerScope,
               !document.scopes.isEmpty,
               !document.scopes.contains(caller),
               !document.scopes.contains("public") {
                return nil
            }

            let haystack = Self.terms(in: document.title + "\n" + document.content)
            let matched = terms.filter(haystack.contains).count
            guard matched > 0 else { return nil }
            let lexical = Double(matched) / Double(terms.count)
            let scopeScore = query.requiredScopes.isEmpty
                ? (document.scopes.contains("public") ? 1.0 : 0.75)
                : 1.0
            let score = KnowledgeScore(
                lexical: lexical,
                authority: document.authority,
                revision: query.sourceRevision == nil ? 0.8 : 1.0,
                scope: scopeScore,
                contradiction: 0
            )
            return KnowledgeHit(
                documentID: document.id,
                title: document.title,
                excerpt: Self.excerpt(from: document.content, matching: terms),
                score: score,
                provenance: document.provenance,
                sourceRepository: document.sourceRepository,
                sourceRevision: document.sourceRevision,
                sourcePath: document.sourcePath,
                contentDigest: document.contentDigest
            )
        }
        .sorted {
            if $0.score.total == $1.score.total { return $0.documentID < $1.documentID }
            return $0.score.total > $1.score.total
        }
        .prefix(query.evidenceBudget)
        .map { $0 }
    }

    private nonisolated static func terms(in text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 })
    }

    private nonisolated static func excerpt(from content: String, matching terms: Set<String>) -> String {
        let lines = content.split(whereSeparator: \.isNewline).map(String.init)
        let matching = lines.first { line in
            let lower = line.lowercased()
            return terms.contains { lower.contains($0) }
        } ?? lines.first ?? ""
        return String(matching.prefix(800))
    }
}
