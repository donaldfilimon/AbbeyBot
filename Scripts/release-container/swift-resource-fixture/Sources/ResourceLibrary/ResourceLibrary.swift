import Foundation

public func resourceMarker() throws -> String {
    guard let url = Bundle.module.url(forResource: "marker", withExtension: "txt") else {
        fatalError("packaged resource is missing")
    }
    return try String(contentsOf: url, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
