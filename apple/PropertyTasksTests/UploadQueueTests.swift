import CoreGraphics
import Foundation
import ImageIO
import PropertyTasksCore
import Testing
import UniformTypeIdentifiers
@testable import PropertyTasks

/// A Worker stand-in that records every call in order and can be told to fail uploads,
/// so the offline contract of DESIGN.md §3 (event first, bytes later, retry on refresh)
/// is checked without a server.
actor RecordingTransport: SyncTransport {
    enum Call: Equatable, Sendable {
        case push([String])            // event types in the batch
        case pull
        case putBlob(String, String?)  // sha256, variant
    }
    private(set) var calls: [Call] = []
    var failUploads = false
    var failPush = false

    struct Offline: Error {}

    func setFailUploads(_ v: Bool) { failUploads = v }
    func setFailPush(_ v: Bool) { failPush = v }
    func uploads() -> [Call] { calls.filter { if case .putBlob = $0 { return true } else { return false } } }

    func push(spaceId: String, events: [Event]) async throws -> SyncClient.PushResult {
        calls.append(.push(events.map(\.type)))
        if failPush { throw Offline() }
        return SyncClient.PushResult(ok: true, seqs: [:], error: nil, eventId: nil)
    }
    func pull(spaceId: String, since: Int, limit: Int) async throws -> SyncClient.PullResult {
        calls.append(.pull)
        if failPush { throw Offline() }
        return SyncClient.PullResult(events: [], nextSeq: since, hasMore: false)
    }
    func putBlob(spaceId: String, sha256: String, variant: String?, data: Data, mime: String) async throws {
        calls.append(.putBlob(sha256, variant))
        if failUploads { throw Offline() }
    }
    func getBlob(spaceId: String, sha256: String, variant: String?) async throws -> Data { throw Offline() }
}

@MainActor
struct UploadQueueTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "pt-upload-tests-\(UUID().uuidString)")
    }

    private func makeStore(_ transport: RecordingTransport, dir: URL) -> SpaceStore {
        let s = SpaceStore(spaceId: "space-test", title: "Test", client: transport, actorId: "paul", deviceId: "test", cacheDirectory: dir)
        s.ingest(Event(id: "m1", spaceId: "space-test", nodeId: nil, actorId: "paul", deviceId: "server", at: 1,
                       body: .memberJoined(MemberJoinedPayload(userId: "paul", role: .owner, displayName: "Paul")), seq: 1, receivedAt: 1))
        return s
    }

    /// A small real JPEG so hashing and derivatives run for real.
    private static func jpeg(width: Int = 64, height: Int = 48) -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    @Test func eventGoesOutBeforeBytesAndQueueDrainsInOrder() async {
        let t = RecordingTransport()
        let s = makeStore(t, dir: tempDir())
        _ = await s.submit(.nodeCreated(NodeCreatedPayload(parentId: nil, kind: .task, title: "Fix AC")), nodeId: "ac")
        let before = await t.calls.count

        let id = await s.attachPhoto(CapturedPhoto(data: Self.jpeg()), to: "ac")
        #expect(id != nil)
        let att = s.store.getAttachmentsForNode("ac")
        #expect(att.count == 1)
        let sha = att[0].sha256!
        #expect(att[0].capture?.intrinsics?.imageWidth == 64)

        let calls = Array(await t.calls.dropFirst(before))
        // The attachment.added push precedes every upload (the fake never stamps events, so the
        // earlier node.created is still in the batch); original, thumb, phone in staging order.
        guard case .push(let batch)? = calls.first else { Issue.record("first call was \(String(describing: calls.first))"); return }
        #expect(batch.contains("attachment.added"))
        #expect(calls.firstIndex(of: .putBlob(sha, nil)) ?? -1 > 0)
        #expect(await t.uploads().suffix(3) == [.putBlob(sha, nil), .putBlob(sha, "thumb"), .putBlob(sha, "phone")])
        #expect(s.uploadQueue.isEmpty)
        #expect(!s.isUploadPending(sha256: sha))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: s.blobsDirectory.path).count) ?? 0 == 0)
    }

    @Test func networkFailureLeavesItemsQueuedAndPersisted() async {
        let t = RecordingTransport()
        await t.setFailUploads(true)
        await t.setFailPush(true)
        let dir = tempDir()
        let s = makeStore(t, dir: dir)
        _ = await s.submit(.nodeCreated(NodeCreatedPayload(parentId: nil, kind: .task, title: "Fix AC")), nodeId: "ac")
        let id = await s.attachPhoto(CapturedPhoto(data: Self.jpeg()), to: "ac")
        #expect(id != nil)
        let sha = s.store.getAttachmentsForNode("ac")[0].sha256!

        // The event applied locally and is pending; all three blobs stay queued with their files.
        #expect(s.pending.count == 2)
        #expect(s.uploadQueue.map(\.variant) == [nil, "thumb", "phone"])
        #expect(s.uploadQueue[0].attempts == 1)
        #expect(s.isUploadPending(sha256: sha))
        for item in s.uploadQueue { #expect(FileManager.default.fileExists(atPath: s.fileURL(for: item).path)) }
        // Only the first upload was tried; the drain stops at the first failure.
        #expect(await t.uploads().count == 1)
        // The local derivative serves the thumbnail without the network.
        let thumb = await s.blob(sha256: sha, variant: "thumb")
        #expect(thumb != nil)
        #expect(ImageTools.info(thumb!)?.width == 64)

        // A fresh store over the same cache directory sees the same queue.
        let s2 = SpaceStore(spaceId: "space-test", title: "Test", client: t, actorId: "paul", deviceId: "test", cacheDirectory: dir)
        s2.loadFromDisk()
        #expect(s2.uploadQueue == s.uploadQueue)
        #expect(s2.pending.count == 2)

        // Back online: the next refresh pushes nothing new but drains the queue in order.
        await t.setFailUploads(false)
        await t.setFailPush(false)
        await s2.refresh()
        #expect(s2.uploadQueue.isEmpty)
        #expect(await t.uploads().suffix(3) == [.putBlob(sha, nil), .putBlob(sha, "thumb"), .putBlob(sha, "phone")])
    }

    @Test func missingStagedFileIsDroppedNotRetriedForever() async {
        let t = RecordingTransport()
        await t.setFailUploads(true)
        let s = makeStore(t, dir: tempDir())
        s.stageBlob(sha256: "abc", variant: nil, data: Data([1, 2, 3]), mime: "application/octet-stream")
        await s.drainUploads()
        #expect(s.uploadQueue.count == 1)
        try? FileManager.default.removeItem(at: s.fileURL(for: s.uploadQueue[0]))
        await t.setFailUploads(false)
        await s.drainUploads()
        #expect(s.uploadQueue.isEmpty)
        #expect(await t.uploads().count == 1)
    }

    @Test func capturedItemLandsInInboxCreatedOnFirstUse() async {
        let t = RecordingTransport()
        let s = makeStore(t, dir: tempDir())
        #expect(s.inboxId == nil)
        let sensors = CaptureSidecar(gps: .init(lat: 1, lon: 2, accuracyM: 5), headingDeg: 90, attitude: .init(roll: 0, pitch: 0.1, yaw: 1))
        let nodeId = await s.createCapturedItem(title: "  Bathroom AC dead ", parentId: nil, priority: .high,
                                                photos: [CapturedPhoto(data: Self.jpeg(), sensors: sensors), CapturedPhoto(data: Self.jpeg(width: 32, height: 32))])
        #expect(nodeId != nil)
        let inbox = s.inboxId
        #expect(inbox != nil)
        let node = s.store.getNode(nodeId!)
        #expect(node?.parentId == inbox)
        #expect(node?.title == "Bathroom AC dead")
        #expect(node?.priority == .high)
        #expect(node?.status == .open)
        let atts = s.store.getAttachmentsForNode(nodeId!).sorted { $0.sortKey < $1.sortKey }
        #expect(atts.count == 2)
        #expect(atts[0].capture?.gps?.lat == 1)
        #expect(atts[0].capture?.headingDeg == 90)
        #expect(atts[0].capture?.attitude?.yaw == 1)
        #expect(atts[1].capture?.gps == nil)
        #expect(atts[1].capture?.intrinsics?.imageWidth == 32)
        // Second capture reuses the Inbox rather than making another.
        _ = await s.createCapturedItem(title: "Again", parentId: nil, priority: .normal, photos: [])
        #expect(s.store.getChildren(nil).filter { $0.title == SpaceStore.inboxTitle }.count == 1)
    }

    @Test func placeMemoryKeepsLastAndRecents() {
        let defaults = UserDefaults(suiteName: "pt-place-tests-\(UUID().uuidString)")!
        let m = PlaceMemory(spaceId: "s", defaults: defaults)
        #expect(m.lastPlace == nil)
        for id in ["a", "b", "c", "a", "d", "e", "f"] { m.noteUse(id) }
        #expect(m.lastPlace == "f")
        #expect(m.recents == ["f", "e", "d", "a", "c"])
    }
}
