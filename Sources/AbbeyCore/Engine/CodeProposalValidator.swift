import Foundation

/// Static safety gate for generated-code proposals (Phase 2). Not a sandbox — rejects
/// dangerous patterns before acceptance. Aligns with Learning & Safety Policy.
public enum CodeProposalValidator: Sendable {
    public enum Verdict: Sendable, Equatable {
        case accepted
        case rejected(reasons: [String])
    }

    /// Patterns that must not appear in accepted proposals (case-insensitive where noted).
    private static let forbiddenSubstrings: [(needle: String, reason: String)] = [
        ("Process.Process", "spawns a process"),
        ("/bin/sh", "shell path"),
        ("/bin/bash", "shell path"),
        ("NSTask", "legacy process API"),
        ("posix_spawn", "posix_spawn"),
        ("dlopen", "dynamic library load"),
        ("dlsym", "dynamic symbol resolve"),
        ("JSContext", "JavaScriptCore eval surface"),
        ("eval(", "dynamic eval"),
        ("exec(", "exec call"),
        ("system(", "system call"),
        ("FileManager.default.removeItem", "deletes filesystem entries"),
        ("#include <unistd.h>", "native process headers"),
        ("URLSession.shared.data", "undeclared network activity"),
        ("URLSession.shared.upload", "undeclared network activity"),
    ]

    private static let forbiddenRegex: [(pattern: String, reason: String)] = [
        (#"(?i)\bimport\s+Darwin\b"#, "Darwin import (low-level system)"),
        (#"(?i)\bdlopen\s*\("#, "dlopen call"),
        (#"(?i)\bNSTask\b"#, "NSTask"),
        (#"(?i)\bProcess\s*\(\s*\)"#, "Process() construction"),
        (#"(?i)rm\s+-rf"#, "destructive shell rm"),
        (#"(?i)\bcurl\s+"#, "shell network fetch"),
        (#"(?i)\bwget\s+"#, "shell network fetch"),
    ]

    public static func validate(_ source: String) -> Verdict {
        var reasons: [String] = []
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .rejected(reasons: ["empty proposal"])
        }

        for item in forbiddenSubstrings {
            if source.localizedCaseInsensitiveContains(item.needle) {
                reasons.append(item.reason)
            }
        }
        for item in forbiddenRegex {
            if source.range(of: item.pattern, options: .regularExpression) != nil {
                reasons.append(item.reason)
            }
        }

        // Deduplicate while preserving order
        var seen = Set<String>()
        let unique = reasons.filter { seen.insert($0).inserted }
        return unique.isEmpty ? .accepted : .rejected(reasons: unique)
    }

    /// Throws if rejected — for call sites that prefer errors.
    public static func acceptOrThrow(_ source: String) throws {
        switch validate(source) {
        case .accepted:
            return
        case .rejected(let reasons):
            throw CodeProposalRejection(reasons: reasons)
        }
    }
}

public struct CodeProposalRejection: Error, LocalizedError, Sendable {
    public let reasons: [String]

    public init(reasons: [String]) {
        self.reasons = reasons
    }

    public var errorDescription: String? {
        "Code proposal rejected: " + reasons.joined(separator: "; ")
    }
}
