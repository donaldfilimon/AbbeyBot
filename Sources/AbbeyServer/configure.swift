import AbbeyServerKit
import Fluent
import Foundation
import Leaf
import Vapor

public func configure(_ app: Application) async throws {
    let resourcesRoot = resourcesRootURL()

    let viewsPath = resourcesRoot.appendingPathComponent("Views").path
    app.directory.viewsDirectory = viewsPath.hasSuffix("/") ? viewsPath : viewsPath + "/"
    app.views.use(.leaf)

    let publicPath = resourcesPublicDirectory().path
    // FileMiddleware requires the directory to exist at registration time.
    try FileManager.default.createDirectory(atPath: publicPath, withIntermediateDirectories: true)
    app.middleware.use(FileMiddleware(publicDirectory: publicPath))

    _ = try await configureRuntime(app, defaultDatabaseURL: "postgres://abbey:abbey@localhost:5432/abbeybot")
    app.lifecycle.use(BotLifecycleHandler())

    try routes(app)
}
