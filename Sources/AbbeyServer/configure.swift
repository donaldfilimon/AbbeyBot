import AbbeyServerKit
import Fluent
import Foundation
import Leaf
import Vapor

public func configure(_ app: Application) async throws {
    let viewsPath = Bundle.module.bundleURL
        .appendingPathComponent("Resources")
        .appendingPathComponent("Views")
        .path
    app.directory.viewsDirectory = viewsPath.hasSuffix("/") ? viewsPath : viewsPath + "/"
    app.views.use(.leaf)

    _ = try await configureRuntime(app, defaultDatabaseURL: "postgres://abbey:abbey@localhost:5432/abbeybot")
    app.lifecycle.use(BotLifecycleHandler())

    try routes(app)
}
