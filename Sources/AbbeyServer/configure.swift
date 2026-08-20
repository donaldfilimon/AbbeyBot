import AbbeyServerKit
import Fluent
import Foundation
import Leaf
import LeafKit
import Vapor

/// Startup failures that mean the server's own bundled resources are not where
/// the build put them. Carries the probed paths, because the useful question is
/// always "where did it look?".
enum AbbeyServerResourceError: Error, CustomStringConvertible {
    case bundleResourcesMissing(candidates: [String])
    case viewsDirectoryMissing(path: String)

    var description: String {
        switch self {
        case .bundleResourcesMissing(let candidates):
            "AbbeyServer bundle resources not found. Looked in: \(candidates.joined(separator: ", "))"
        case .viewsDirectoryMissing(let path):
            "AbbeyServer Leaf views directory not found at \(path)"
        }
    }
}

public func configure(_ app: Application) async throws {
    let resourcesRoot = resourcesRootURL()

    // Fail loudly if the bundle's resources cannot be found at all. Continuing
    // here is what made the Linux failure so hard to see: FileMiddleware would
    // be handed a directory that gets CREATED empty below, Leaf would be handed
    // a views directory with no templates, and the only symptom was a 500 from
    // `GET /` at render time.
    guard resolvedResourcesRootURL() != nil else {
        throw AbbeyServerResourceError.bundleResourcesMissing(
            candidates: resourcesRootCandidates().map(\.path)
        )
    }

    var viewsPath = resourcesViewsDirectory().path
    if !viewsPath.hasSuffix("/") { viewsPath += "/" }
    guard FileManager.default.fileExists(atPath: viewsPath) else {
        throw AbbeyServerResourceError.viewsDirectoryMissing(path: viewsPath)
    }
    app.directory.viewsDirectory = viewsPath
    // Leaf's default source refuses this directory outright. Two of its
    // default limits fight a SwiftPM resource bundle: `.toSandbox` sandboxes
    // to the working directory, and `.toVisibleFiles` rejects any path
    // containing a dot-prefixed component — and a bundle inside a checkout
    // lives under `.build`. The result is a 500 reading
    // "Attempted to access .build", not a missing-template error, which is
    // almost certainly why the route rendering `status.leaf` disappeared.
    //
    // The sandbox is kept and pointed at the bundle's own Views directory, so
    // templates still cannot be escaped out of; only the visible-files limit
    // is dropped, and only because the bundle path is legitimately hidden.
    app.leaf.sources = LeafSources.singleSource(
        NIOLeafFiles(
            fileio: app.fileio,
            limits: [.toSandbox, .requireExtensions],
            sandboxDirectory: viewsPath,
            viewDirectory: viewsPath
        )
    )
    app.views.use(.leaf)

    let publicPath = resourcesPublicDirectory().path
    // FileMiddleware requires the directory to exist at registration time, and
    // the SPA is legitimately absent until `bun run build` has run — so this
    // create stays. It is only safe because the resources root was verified
    // above; without that check it silently manufactured a plausible-looking
    // path and hid a misresolved bundle.
    try FileManager.default.createDirectory(atPath: publicPath, withIntermediateDirectories: true)
    app.middleware.use(FileMiddleware(publicDirectory: publicPath))

    _ = try await configureRuntime(app, defaultDatabaseURL: "postgres://abbey:abbey@localhost:5432/abbeybot")
    app.lifecycle.use(BotLifecycleHandler())

    try routes(app)
}
