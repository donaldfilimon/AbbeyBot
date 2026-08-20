import AbbeyServerKit
import Fluent
import Foundation
import Leaf
import LeafKit
import Vapor

public func configure(_ app: Application) async throws {
    let resourcesRoot = resourcesRootURL()

    var viewsPath = resourcesRoot.appendingPathComponent("Views").path
    if !viewsPath.hasSuffix("/") { viewsPath += "/" }
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
    // FileMiddleware requires the directory to exist at registration time.
    try FileManager.default.createDirectory(atPath: publicPath, withIntermediateDirectories: true)
    app.middleware.use(FileMiddleware(publicDirectory: publicPath))

    _ = try await configureRuntime(app, defaultDatabaseURL: "postgres://abbey:abbey@localhost:5432/abbeybot")
    app.lifecycle.use(BotLifecycleHandler())

    try routes(app)
}
