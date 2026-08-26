import Foundation
import Testing
@testable import AbbeyQuasarKit

@Suite("Quasar wire contract")
struct QuasarModelsTests {
    private struct BunContract: Decodable {
        var site: Site
        var eventPage: EventPage
        var preview: PreviewStatus
    }

    @Test func sanitizedBunServiceFixtureDecodesWithoutTranslation() throws {
        let url = try #require(Bundle.module.url(forResource: "bun-service-contract", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(BunContract.self, from: Data(contentsOf: url))
        #expect(fixture.site.slug == "fixture-site")
        #expect(fixture.eventPage.next == 4)
        #expect(fixture.eventPage.events[1] == .tool(.readFile, path: "app/page.tsx"))
        #expect(fixture.preview == .init(state: .running, port: 4710, url: "http://127.0.0.1:4710/", logTail: []))
    }
    @Test func eventEncodingMatchesTypeScriptShape() throws {
        let data = try JSONEncoder().encode(GenerationEvent.tool(.writeFile, path: "app/page.tsx"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "tool")
        #expect(object["name"] as? String == "write_file")
        #expect(object["path"] as? String == "app/page.tsx")
        #expect(object["message"] == nil)
    }

    @Test func slugMatchesQuasarContract() {
        #expect(QuasarSlug.make("Hello, Swift World!") == "hello-swift-world")
        #expect(QuasarSlug.make("✨") == "site")
    }

    @Test func requestBounds() throws {
        _ = try CreateSiteRequest(name: "Site", prompt: "Build it").validated()
        #expect(throws: QuasarError.self) { try CreateSiteRequest(name: "", prompt: "Build it").validated() }
        #expect(throws: QuasarError.self) { try CreateSiteRequest(name: "Site", prompt: String(repeating: "x", count: 4_001)).validated() }
    }
}
