import Foundation
import Testing
@testable import PropertyTasksCore

struct ProjectionTests {
    static func load(_ name: String) throws -> MemoryStore {
        let url = FixturesTests.fixturesDir.appending(path: "\(name).json")
        let fx = try JSONDecoder().decode(FixturesTests.Fixture.self, from: Data(contentsOf: url))
        let s = MemoryStore()
        try replay(s, fx.events)
        return s
    }

    @Test func createTreeHierarchyAndDefaults() throws {
        let s = try Self.load("create-tree")
        #expect(s.getAncestors("ac").map(\.id) == ["bath", "house", "cabin"])
        #expect(s.getNode("ac")?.status == .in_progress)
        #expect(s.getNode("bath")?.status == nil)
        #expect(s.getNode("ac-note")?.body == "Error code P6 on the display")
        #expect(s.getLabels("ac") == ["Repair"])
        #expect(s.getAttachmentsForNode("ac").count == 1)
    }

    @Test func moveRefusesCycles() throws {
        let s = try Self.load("move-subtree")
        #expect(s.getNode("bath")?.parentId == "barn")
        let ev = Event(id: "x1", spaceId: "space-1", nodeId: "cabin", actorId: "paul", deviceId: "d", at: 1,
                       body: .moved(MovedPayload(fromParentId: nil, toParentId: "ac")))
        #expect(throws: ProjectionError.self) { try applyEvent(s, ev) }
    }

    @Test func filterAndTree() throws {
        let s = try Self.load("create-tree")
        let now = 1_760_000_000_000 + 10 * 60_000
        var f = Filter()
        #expect(query(s, f, now: now).map(\.id).sorted() == ["ac", "ac-note", "bath", "cabin", "house"])
        f.under = ["house"]; f.kind = [.task]
        #expect(query(s, f, now: now).map(\.id) == ["ac"])
        var g = Filter(); g.has = [.photos]
        #expect(query(s, g, now: now).map(\.id) == ["ac"])
        var h = Filter(); h.kind = [.task]
        let rows = tree(s, h, now: now)
        #expect(rows.map { [$0.node.id, String($0.depth), String($0.dimmed)] } ==
                [["cabin", "0", "true"], ["house", "1", "true"], ["bath", "2", "true"], ["ac", "3", "false"]])
    }

    @Test func uuidv7IsVersion7AndOrdered() {
        let a = uuidv7(now: 1_000), b = uuidv7(now: 2_000)
        #expect(a.count == 36)
        #expect(a[a.index(a.startIndex, offsetBy: 14)] == "7")
        #expect(a < b)
    }
}
