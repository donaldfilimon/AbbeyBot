import Foundation

/// Bundle.module.bundleURL is the bundle *package* root. On Apple platforms that's a
/// `.bundle` with a `Contents/Resources/` layer inside it; on Linux (flat `.resources`
/// dirs, e.g. this repo's Docker build) there's no such nesting. `.resourceURL` accounts
/// for that difference on both platforms — `.bundleURL` does not, and silently resolves
/// to a path that doesn't exist on macOS.
func resourcesRootURL() -> URL {
    (Bundle.module.resourceURL ?? Bundle.module.bundleURL)
        .appendingPathComponent("Resources")
}

func resourcesPublicDirectory() -> URL {
    resourcesRootURL().appendingPathComponent("Public")
}
