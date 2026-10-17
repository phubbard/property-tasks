import Foundation
import Observation
import PropertyTasksCore

/// The local replica of one Space: the accepted event log, events authored
/// here and not yet accepted, blobs staged on disk and not yet uploaded, and
/// the projection built from the events. Cached on disk as JSON so the app
/// opens offline; SQLite can replace the cache later without changing the API
/// of this class. See DESIGN.md §3, §5, §11.
@MainActor @Observable
final class SpaceStore {
    let spaceId: String
    let title: String
    let client: any SyncTransport
    let actorId: String
    let deviceId: String

    private(set) var store = MemoryStore()
    private(set) var events: [Event] = []
    private(set) var pending: [Event] = []
    /// Blobs written to disk and waiting for the Worker, oldest first. The
    /// attachment.added event for each goes out before its bytes (DESIGN.md §3).
    private(set) var uploadQueue: [UploadItem] = []
    private(set) var cursor = 0
    /// Bumped on every change so views that read `store` re-render.
    private(set) var version = 0
    var lastError: String?
    private(set) var syncing = false
    private(set) var uploading = false
    private var blobCache: [String: Data] = [:]

    /// One blob (an original or a derivative) staged under Application Support.
    struct UploadItem: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var sha256: String
        var variant: String?
        var mime: String
        /// File name inside `blobsDirectory`; the directory itself is not stored because the
        /// app container path can change between installs.
        var filename: String
        var byteSize: Int
        var attempts: Int
        var stagedAt: Millis
    }

    struct Cache: Codable {
        var cursor: Int
        var events: [Event]
        var pending: [Event]
        var uploadQueue: [UploadItem]?
    }

    init(spaceId: String, title: String, client: any SyncTransport, actorId: String, deviceId: String, cacheDirectory: URL? = nil) {
        self.spaceId = spaceId
        self.title = title
        self.client = client
        self.actorId = actorId
        self.deviceId = deviceId
        let base = cacheDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "PropertyTasks/spaces")
        self.cacheURL = base.appending(path: "\(spaceId).json")
        self.blobsDirectory = base.appending(path: "blobs/\(spaceId)", directoryHint: .isDirectory)
    }

    private let cacheURL: URL
    let blobsDirectory: URL

    // MARK: - Lifecycle

    /// Read the on-disk cache without touching the network.
    func loadFromDisk() {
        guard let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        events = cache.events
        pending = cache.pending
        uploadQueue = cache.uploadQueue ?? []
        cursor = cache.cursor
        rebuild()
    }

    func load() async {
        loadFromDisk()
        await flush()
        await refresh()
    }

    func refresh() async {
        syncing = true
        do {
            while true {
                let page = try await client.pull(spaceId: spaceId, since: cursor)
                for ev in page.events { ingest(ev) }
                cursor = page.nextSeq
                if !page.hasMore { break }
            }
            lastError = nil
            save()
        } catch {
            lastError = describe(error)
        }
        syncing = false
        await drainUploads()
    }

    /// Author an event: apply locally, queue, and try to push.
    @discardableResult
    func submit(_ body: EventBody, nodeId: String?) async -> Bool {
        let ev = Event(id: uuidv7(), spaceId: spaceId, nodeId: nodeId, actorId: actorId, deviceId: deviceId,
                       at: Millis(Date().timeIntervalSince1970 * 1000), body: body)
        do {
            try applyEvent(store, ev)
        } catch {
            lastError = describe(error)
            return false
        }
        pending.append(ev)
        version += 1
        save()
        await flush()
        return true
    }

    /// Push pending events, then upload staged blobs. Events go first so other members see the
    /// item with placeholders while the bytes are still in flight.
    func flush() async {
        if !pending.isEmpty {
            do {
                let result = try await client.push(spaceId: spaceId, events: pending)
                if result.ok {
                    // Accepted events come back stamped on the next pull, which removes them from pending.
                    await refresh()
                    return // refresh drains the upload queue
                } else {
                    // One event in the batch was rejected server-side; drop it and rebuild without it.
                    lastError = result.error ?? "rejected"
                    if let bad = result.eventId { pending.removeAll { $0.id == bad }; rebuild(); save() }
                }
            } catch {
                lastError = describe(error)
            }
        }
        await drainUploads()
    }

    // MARK: - Blobs

    /// Write a blob to disk and queue it for upload. Returns false if the file could not be written,
    /// in which case nothing is queued. Idempotent per (sha256, variant).
    @discardableResult
    func stageBlob(sha256: String, variant: String?, data: Data, mime: String) -> Bool {
        let filename = Self.filename(sha256: sha256, variant: variant)
        do {
            try FileManager.default.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)
            try data.write(to: blobsDirectory.appending(path: filename), options: .atomic)
        } catch {
            lastError = describe(error)
            return false
        }
        if !uploadQueue.contains(where: { $0.sha256 == sha256 && $0.variant == variant }) {
            uploadQueue.append(UploadItem(id: uuidv7(), sha256: sha256, variant: variant, mime: mime, filename: filename,
                                          byteSize: data.count, attempts: 0, stagedAt: Millis(Date().timeIntervalSince1970 * 1000)))
        }
        version += 1
        save()
        return true
    }

    /// Upload staged blobs in order. Stops at the first failure and leaves the rest queued for
    /// the next flush or refresh; a staged file that has vanished is dropped from the queue.
    func drainUploads() async {
        guard !uploading, !uploadQueue.isEmpty else { return }
        uploading = true
        defer { uploading = false }
        while let item = uploadQueue.first {
            let url = fileURL(for: item)
            guard let data = try? Data(contentsOf: url) else {
                uploadQueue.removeAll { $0.id == item.id }
                save()
                continue
            }
            do {
                try await client.putBlob(spaceId: spaceId, sha256: item.sha256, variant: item.variant, data: data, mime: item.mime)
            } catch {
                lastError = describe(error)
                if let i = uploadQueue.firstIndex(where: { $0.id == item.id }) { uploadQueue[i].attempts += 1 }
                save()
                return
            }
            uploadQueue.removeAll { $0.id == item.id }
            blobCache["\(item.sha256)/\(item.variant ?? "")"] = data
            try? FileManager.default.removeItem(at: url)
            version += 1
            save()
        }
    }

    func fileURL(for item: UploadItem) -> URL { blobsDirectory.appending(path: item.filename) }

    static func filename(sha256: String, variant: String?) -> String { "\(sha256).\(variant ?? "orig")" }

    /// True while any blob of this attachment is still waiting for the Worker.
    func isUploadPending(sha256: String?) -> Bool {
        guard let sha256 else { return false }
        return uploadQueue.contains { $0.sha256 == sha256 }
    }

    /// Bytes for a blob: memory, then the staged file on disk, then the Worker. The local copy
    /// is what lets a thumbnail show before (or without) a network round trip.
    func blob(sha256: String, variant: String?) async -> Data? {
        let key = "\(sha256)/\(variant ?? "")"
        if let d = blobCache[key] { return d }
        let local = blobsDirectory.appending(path: Self.filename(sha256: sha256, variant: variant))
        if let d = try? Data(contentsOf: local) {
            blobCache[key] = d
            return d
        }
        guard let d = try? await client.getBlob(spaceId: spaceId, sha256: sha256, variant: variant) else { return nil }
        blobCache[key] = d
        return d
    }

    // MARK: - Internals

    /// Apply a server-stamped event. If it was authored here it is already in the projection.
    func ingest(_ ev: Event) {
        events.append(ev)
        if let i = pending.firstIndex(where: { $0.id == ev.id }) {
            pending.remove(at: i)
        } else if !(events.dropLast().contains { $0.id == ev.id }) {
            do { try applyEvent(store, ev) } catch { lastError = describe(error) }
        }
        version += 1
    }

    private func rebuild() {
        let fresh = MemoryStore()
        for ev in events { try? applyEvent(fresh, ev) }
        var kept: [Event] = []
        for ev in pending {
            if (try? applyEvent(fresh, ev)) != nil { kept.append(ev) }
        }
        pending = kept
        store = fresh
        version += 1
    }

    private func save() {
        let cache = Cache(cursor: cursor, events: events, pending: pending, uploadQueue: uploadQueue)
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
        } catch {
            lastError = describe(error)
        }
    }

    private func describe(_ error: Error) -> String {
        if let e = error as? SyncClient.HTTPError { return "HTTP \(e.status): \(e.body.prefix(200))" }
        if let e = error as? ProjectionError { return e.message }
        return error.localizedDescription
    }

    // MARK: - Queries

    var canWrite: Bool {
        guard let m = store.getMember(actorId) else { return false }
        return m.role == .owner || m.role == .editor
    }

    func history(for nodeId: String) -> [Event] {
        (events + pending).filter { $0.nodeId == nodeId }.sorted { $0.at > $1.at }
    }

    func path(for nodeId: String) -> String {
        store.getAncestors(nodeId).reversed().map(\.title).joined(separator: " › ")
    }

    func displayName(_ userId: String) -> String {
        store.getMember(userId)?.displayName ?? userId
    }

    /// Live containers, for place pickers.
    var containers: [Node] {
        store.allNodes().filter { $0.kind == .container && $0.archivedAt == nil }
    }

    /// The Space's root "Inbox" container, if someone has created it.
    var inboxId: String? {
        store.getChildren(nil).first { $0.kind == .container && $0.archivedAt == nil && $0.title.caseInsensitiveCompare(Self.inboxTitle) == .orderedSame }?.id
    }

    static let inboxTitle = "Inbox"

    /// The Inbox container, created at the root on first use (DESIGN.md §3).
    func ensureInbox() async -> String? {
        if let id = inboxId { return id }
        let id = uuidv7()
        let ok = await submit(.nodeCreated(NodeCreatedPayload(parentId: nil, kind: .container, title: Self.inboxTitle, priority: Priority.none)), nodeId: id)
        return ok ? id : nil
    }
}
