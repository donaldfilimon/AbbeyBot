import AbbeyServerKit
import Fluent
import Foundation
import Leaf
import Vapor

public func configure(_ app: Application) async throws {
    // Bundle.module.bundleURL is the bundle *package* root. On Apple platforms that's a
    // `.bundle` with a `Contents/Resources/` layer inside it; on Linux (flat `.resources`
    // dirs, e.g. this repo's Docker build) there's no such nesting. `.resourceURL` accounts
    // for that difference on both platforms — `.bundleURL` does not, and silently resolves
    // to a path that doesn't exist on macOS (this went unnoticed here because nothing
    // previously exercised the Leaf-rendered `GET /` route in the server smoke test).
    let resourcesRoot = (Bundle.module.resourceURL ?? Bundle.module.bundleURL)
        .appendingPathComponent("Resources")

    let viewsPath = resourcesRoot.appendingPathComponent("Views").path
    app.directory.viewsDirectory = viewsPath.hasSuffix("/") ? viewsPath : viewsPath + "/"
    app.views.use(.leaf)

    let publicPath = resourcesRoot.appendingPathComponent("Public").path
    app.middleware.use(FileMiddleware(publicDirectory: publicPath))

    _ = try await configureRuntime(app, defaultDatabaseURL: "postgres://abbey:abbey@localhost:5432/abbeybot")
    app.lifecycle.use(BotLifecycleHandler())

    try routes(app)
}
