import Foundation
import PropertyTasksCore
import Testing
@testable import PropertyTasks

@MainActor
struct SpaceStoreTests {
    private func makeStore() -> SpaceStore {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pt-tests-\(UUID().uuidString)")
        // Port 9 is discard; nothing listens, so pushes fail fast and the local state must survive that.
        let client = SyncClient(baseURL: URL(string: "http://127.0.0.1:9")!, auth: .devUser("paul"))
        return SpaceStore(spaceId: "space-test", title: "Test", client: client, actorId: "paul", deviceId: "test", cacheDirectory: dir)
    }

    @Test func submitAppliesLocallyAndStaysPendingWhenOffline() async {
        let s = makeStore()
        s.ingest(Event(id: "m1", spaceId: "space-test", nodeId: nil, actorId: "paul", deviceId: "server", at: 1,
                       body: .memberJoined(MemberJoinedPayload(userId: "paul", role: .owner, displayName: "Paul")), seq: 1, receivedAt: 1))
        #expect(s.canWrite)
        let ok = await s.submit(.nodeCreated(NodeCreatedPayload(parentId: nil, kind: .container, title: "Cabin")), nodeId: "cabin")
        #expect(ok)
        #expect(s.store.getNode("cabin")?.title == "Cabin")
        #expect(s.pending.count == 1)
        #expect(s.lastError != nil)
        #expect(s.history(for: "cabin").count == 1)
    }

    @Test func ingestingOwnEventClearsPending() async {
        let s = makeStore()
        s.ingest(Event(id: "m1", spaceId: "space-test", nodeId: nil, actorId: "paul", deviceId: "server", at: 1,
                       body: .memberJoined(MemberJoinedPayload(userId: "paul", role: .owner, displayName: "Paul")), seq: 1, receivedAt: 1))
        _ = await s.submit(.nodeCreated(NodeCreatedPayload(parentId: nil, kind: .task, title: "Fix AC")), nodeId: "ac")
        let mine = s.pending[0]
        var stamped = mine
        stamped.seq = 2; stamped.receivedAt = 2
        s.ingest(stamped)
        #expect(s.pending.isEmpty)
        #expect(s.events.count == 2)
        #expect(s.store.getNode("ac")?.status == .open)
    }

    @Test func invalidEventIsRefusedLocally() async {
        let s = makeStore()
        let ok = await s.submit(.fieldChanged(FieldChangedPayload(field: "title", before: .null, after: .string("x"))), nodeId: "missing")
        #expect(!ok)
        #expect(s.pending.isEmpty)
    }
}
