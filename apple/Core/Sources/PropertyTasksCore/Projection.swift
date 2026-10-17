import Foundation

/// Thrown when an event cannot be applied. Mirrors ProjectionError in shared/src/projection.ts.
public struct ProjectionError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public let eventId: String
    public init(_ message: String, eventId: String) { self.message = message; self.eventId = eventId }
    public var description: String { "\(message) (event \(eventId))" }
}

private func requireNode(_ store: ProjectionStore, _ ev: Event) throws -> Node {
    guard let nodeId = ev.nodeId else { throw ProjectionError("\(ev.type) requires nodeId", eventId: ev.id) }
    guard let node = store.getNode(nodeId) else { throw ProjectionError("unknown node \(nodeId)", eventId: ev.id) }
    return node
}

private func touch(_ node: Node, _ ev: Event) -> Node {
    var n = node
    n.lastEventAt = ev.at
    n.lastEventBy = ev.actorId
    return n
}

/// Apply one event to a store. Port of applyEvent in shared/src/projection.ts;
/// the fixtures in shared/fixtures are the contract between the two.
public func applyEvent(_ store: ProjectionStore, _ ev: Event) throws {
    switch ev.body {
    case .nodeCreated(let p):
        guard let nodeId = ev.nodeId else { throw ProjectionError("node.created requires nodeId", eventId: ev.id) }
        if store.getNode(nodeId) != nil { return } // duplicate create: first one wins
        if let parent = p.parentId, store.getNode(parent) == nil {
            throw ProjectionError("unknown parent \(parent)", eventId: ev.id)
        }
        var status: Status? = p.status
        if p.kind == .task { status = status ?? .open } else { status = nil }
        store.putNode(Node(
            id: nodeId, parentId: p.parentId, kind: p.kind, title: p.title, status: status,
            priority: p.priority ?? .none, dueAt: p.dueAt, assigneeId: p.assigneeId,
            body: p.kind == .note ? (p.body ?? "") : nil, sortKey: p.sortKey ?? ev.id,
            createdAt: ev.at, createdBy: ev.actorId, lastEventAt: ev.at, lastEventBy: ev.actorId, archivedAt: nil))

    case .fieldChanged(let p):
        let node = try requireNode(store, ev)
        var next = touch(node, ev)
        switch p.field {
        case "title":
            guard let s = p.after.stringValue else { throw ProjectionError("bad title", eventId: ev.id) }
            next.title = s
        case "status":
            if node.kind != .task { throw ProjectionError("only tasks have status", eventId: ev.id) }
            if p.after.isNull { next.status = nil }
            else {
                guard let s = p.after.stringValue, let st = Status(rawValue: s) else { throw ProjectionError("bad status \(p.after)", eventId: ev.id) }
                next.status = st
            }
        case "priority":
            guard let s = p.after.stringValue, let pr = Priority(rawValue: s) else { throw ProjectionError("bad priority \(p.after)", eventId: ev.id) }
            next.priority = pr
        case "dueAt":
            next.dueAt = p.after.isNull ? nil : p.after.intValue
        case "assigneeId":
            next.assigneeId = p.after.isNull ? nil : p.after.stringValue
        case "sortKey":
            guard let s = p.after.stringValue else { throw ProjectionError("bad sortKey", eventId: ev.id) }
            next.sortKey = s
        default:
            throw ProjectionError("bad field \(p.field)", eventId: ev.id)
        }
        store.putNode(next)

    case .moved(let p):
        let node = try requireNode(store, ev)
        if let to = p.toParentId {
            if to == node.id { throw ProjectionError("cannot move a node under itself", eventId: ev.id) }
            guard store.getNode(to) != nil else { throw ProjectionError("unknown parent \(to)", eventId: ev.id) }
            if store.getAncestors(to).contains(where: { $0.id == node.id }) {
                throw ProjectionError("cannot move a node under its own descendant", eventId: ev.id)
            }
        }
        var next = touch(node, ev)
        next.parentId = p.toParentId
        store.putNode(next)

    case .archived:
        let node = try requireNode(store, ev)
        var next = touch(node, ev)
        next.archivedAt = node.archivedAt ?? ev.at
        store.putNode(next)

    case .restored:
        let node = try requireNode(store, ev)
        var next = touch(node, ev)
        next.archivedAt = nil
        store.putNode(next)

    case .labelAdded(let p):
        let node = try requireNode(store, ev)
        store.addLabel(node.id, p.label)
        store.putNode(touch(node, ev))

    case .labelRemoved(let p):
        let node = try requireNode(store, ev)
        store.removeLabel(node.id, p.label)
        store.putNode(touch(node, ev))

    case .attachmentAdded(let p):
        let node = try requireNode(store, ev)
        let a = p.attachment
        if store.getAttachment(a.id) != nil { return }
        store.putAttachment(Attachment(
            id: a.id, nodeId: node.id, kind: a.kind, mime: a.mime, filename: a.filename, byteSize: a.byteSize,
            sha256: a.sha256, url: a.url, width: a.width, height: a.height, durationMs: a.durationMs,
            caption: a.caption, sortKey: a.sortKey, capture: a.capture, createdAt: ev.at, createdBy: ev.actorId, removedAt: nil))
        store.putNode(touch(node, ev))

    case .attachmentRemoved(let p):
        let node = try requireNode(store, ev)
        guard var a = store.getAttachment(p.attachmentId), a.nodeId == node.id else {
            throw ProjectionError("unknown attachment \(p.attachmentId)", eventId: ev.id)
        }
        a.removedAt = a.removedAt ?? ev.at
        store.putAttachment(a)
        store.putNode(touch(node, ev))

    case .attachmentCaptioned(let p):
        let node = try requireNode(store, ev)
        guard var a = store.getAttachment(p.attachmentId), a.nodeId == node.id else {
            throw ProjectionError("unknown attachment \(p.attachmentId)", eventId: ev.id)
        }
        a.caption = p.caption
        store.putAttachment(a)
        store.putNode(touch(node, ev))

    case .noteEdited(let p):
        let node = try requireNode(store, ev)
        if node.kind != .note { throw ProjectionError("only notes have a body", eventId: ev.id) }
        var next = touch(node, ev)
        next.body = p.body
        store.putNode(next)

    case .memberJoined(let p):
        if store.getMember(p.userId) != nil { return }
        store.putMember(Member(userId: p.userId, role: p.role, displayName: p.displayName, joinedAt: ev.at))

    case .memberRoleChanged(let p):
        guard var m = store.getMember(p.userId) else { throw ProjectionError("unknown member \(p.userId)", eventId: ev.id) }
        m.role = p.role
        store.putMember(m)
    }
}

public func replay(_ store: ProjectionStore, _ events: some Sequence<Event>) throws {
    for ev in events { try applyEvent(store, ev) }
}
