import Foundation
import Testing
@testable import PropertyTasksCore

/// Replays every fixture in ../shared/fixtures and compares to the expected
/// projection. This is the contract with the TypeScript implementation.
struct FixturesTests {
    struct Fixture: Decodable {
        var name: String
        var events: [Event]
        var expected: Serialized
    }

    static var fixturesDir: URL {
        // apple/Core/Tests/PropertyTasksCoreTests/FixturesTests.swift -> repo root -> shared/fixtures
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "shared/fixtures")
    }

    static func fixtureFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: fixturesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test func hasFixtures() throws {
        #expect(try Self.fixtureFiles().count >= 3)
    }

    @Test(arguments: try fixtureFiles())
    func replaysToExpected(file: URL) throws {
        let fx = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
        let store = MemoryStore()
        try replay(store, fx.events)
        #expect(serialize(store) == fx.expected, "\(fx.name)")
    }

    @Test func eventsRoundTripThroughCodable() throws {
        for file in try Self.fixtureFiles() {
            let fx = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
            let data = try JSONEncoder().encode(fx.events)
            let again = try JSONDecoder().decode([Event].self, from: data)
            #expect(again == fx.events, "\(file.lastPathComponent)")
        }
    }
}
