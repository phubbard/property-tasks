import Foundation
import Observation
import PropertyTasksCore

/// The local replica of one Space: the accepted event log, events authored
/// here and not yet accepted, and the projection built from both. Cached on
/// disk as JSON so the app opens offline; SQLite can replace the cache later
/// without changing the API of this class. See DESIGN.md §5, §11.
@MainActor @Observable
final class SpaceStore {
    let spaceId: String
    let title: String
    let client: SyncClient
    let actorId: String
    let deviceId: String

    private(set) var store = MemoryStore()
    private(set) var events: [Event] = []
    private(set) var pending: [Event] = []
    private(set) var cursor = 0
    /// Bumped on every change so views that read `store` re-render.
    private(set) var version = 0
    var lastError: String?
    private(set) var syncing = false
    private var blobCache: [String: Data] = [:]

    struct Cache: Codable { var cursor: Int; var events: [Event]; var pending: [Event] }

    init(spaceId: String, title: String, client: SyncClient, actorId: String, deviceId: String, cacheDirectory: URL? = nil) {
        self.spaceId = spaceId
        self.title = title
        self.client = client
        self.actorId = actorId
        self.deviceId = deviceId
        let base = cacheDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "PropertyTasks/spaces")
        self.cacheURL = base.appending(path: "\(spaceId).json")
    }

    private let cacheURL: URL

    // MARK: - Lifecycle

    func load() async {
        if let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data) {
            events = cache.events
            pending = cache.pending
            cursor = cache.cursor
            rebuild()
        }
        await flush()
        await refresh()
    }

    func refresh() async {
        syncing = true
        defer { syncing = false }
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

    func flush() async {
        guard !pending.isEmpty else { return }
        do {
            let result = try await client.push(spaceId: spaceId, events: pending)
            if result.ok {
                // Accepted events come back stamped on the next pull, which removes them from pending.
                await refresh()
            } else {
                // One event in the batch was rejected server-side; drop it and rebuild without it.
                lastError = result.error ?? "rejected"
                if let bad = result.eventId { pending.removeAll { $0.id == bad }; rebuild(); save() }
            }
        } catch {
            lastError = describe(error)
        }
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
        let cache = Cache(cursor: cursor, events: events, pending: pending)
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

    func blob(sha256: String, variant: String?) async -> Data? {
        let key = "\(sha256)/\(variant ?? "")"
        if let d = blobCache[key] { return d }
        guard let d = try? await client.getBlob(spaceId: spaceId, sha256: sha256, variant: variant) else { return nil }
        blobCache[key] = d
        return d
    }
}
