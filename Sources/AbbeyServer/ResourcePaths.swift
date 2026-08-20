import Foundation

/// Where this target's bundled `Resources/` directory actually lives.
///
/// SwiftPM bundle layout differs by platform, and the difference has bitten
/// this server before: on Apple platforms `Bundle.module.bundleURL` is a
/// `.bundle` with a `Contents/Resources/` layer inside it, while on Linux it is
/// a flat `.resources` directory with no such nesting. `.resourceURL` is meant
/// to paper over that, but it is not guaranteed to point somewhere that exists,
/// and a wrong answer here is *silent*: `FileMiddleware` gets a path with no
/// files and Leaf gets a views directory with no templates, so `GET /` fails at
/// render time with no hint that the path was ever the problem.
///
/// So resolve by probing rather than by trusting one accessor: take the first
/// candidate that exists on disk. `resolvedResourcesRootURL()` reports whether
/// anything matched, which lets startup fail loudly instead of continuing on a
/// path that will only misbehave later.
func resourcesRootCandidates() -> [URL] {
    var candidates: [URL] = []
    if let resourceURL = Bundle.module.resourceURL {
        candidates.append(resourceURL.appendingPathComponent("Resources"))
        // Some layouts nest an Apple-style Contents/Resources even when the
        // bundle is otherwise flat; probing for it costs nothing.
        candidates.append(
            resourceURL
                .appendingPathComponent("Contents")
                .appendingPathComponent("Resources")
                .appendingPathComponent("Resources")
        )
    }
    candidates.append(Bundle.module.bundleURL.appendingPathComponent("Resources"))
    candidates.append(
        Bundle.module.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Resources")
            .appendingPathComponent("Resources")
    )
    return candidates
}

/// The first candidate that exists, or nil when the bundle's resources cannot
/// be located at all. Callers needing a path unconditionally use
/// `resourcesRootURL()`; callers that need to *verify* use this.
func resolvedResourcesRootURL() -> URL? {
    resourcesRootCandidates().first { candidate in
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: candidate.path,
            isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue
    }
}

func resourcesRootURL() -> URL {
    // Falling back to the first candidate keeps diagnostics meaningful: an
    // error message then names the path we actually expected.
    resolvedResourcesRootURL() ?? resourcesRootCandidates()[0]
}

func resourcesPublicDirectory() -> URL {
    resourcesRootURL().appendingPathComponent("Public")
}

func resourcesViewsDirectory() -> URL {
    resourcesRootURL().appendingPathComponent("Views")
}
