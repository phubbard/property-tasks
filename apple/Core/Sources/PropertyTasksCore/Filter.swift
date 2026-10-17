import Foundation

private let day: Double = 86_400_000

/// One filter bar for tree and list. Port of shared/src/filter.ts.
public struct Filter: Equatable, Sendable {
    public var status: [Status]? = nil
    public var priority: [Priority]? = nil
    public var priorityMin: Priority? = nil
    public var kind: [Kind]? = nil
    public var labels: [String]? = nil
    public var under: [String]? = nil
    public var ageMaxDays: Double? = nil
    public var ageMinDays: Double? = nil
    public var staleDays: Double? = nil
    public var createdBy: String? = nil
    public var lastTouchedBy: String? = nil
    public var assigneeId: String? = nil
    public var has: [Has]? = nil
    public var due: Due? = nil
    public var includeArchived: Bool = false
    public var text: String? = nil

    public enum Has: String, Sendable { case photos, documents, due, children }
    public enum Due: String, Sendable { case overdue, week, month }

    public init() {}
}

public let defaultOpenStatuses: [Status] = [.open, .in_progress, .blocked]

public func matches(_ store: ProjectionStore, _ node: Node, _ f: Filter, now: Millis) -> Bool {
    if !f.includeArchived && node.archivedAt != nil { return false }
    if let kinds = f.kind, !kinds.contains(node.kind) { return false }

    let statuses = f.status ?? defaultOpenStatuses
    if !statuses.isEmpty && node.kind == .task {
        guard let st = node.status, statuses.contains(st) else { return false }
    }
    if let ps = f.priority, !ps.contains(node.priority) { return false }
    if let min = f.priorityMin, node.priority < min { return false }

    if let labels = f.labels, !labels.isEmpty {
        let have = Set(store.getLabels(node.id))
        if !labels.allSatisfy({ have.contains($0) }) { return false }
    }
    if let under = f.under, !under.isEmpty {
        let ancestors = Set(store.getAncestors(node.id).map(\.id))
        if !under.contains(where: { ancestors.contains($0) }) { return false }
    }
    let ageDays = Double(now - node.createdAt) / day
    if let m = f.ageMaxDays, ageDays > m { return false }
    if let m = f.ageMinDays, ageDays < m { return false }
    if let s = f.staleDays, Double(now - node.lastEventAt) / day < s { return false }

    if let c = f.createdBy, node.createdBy != c { return false }
    if let t = f.lastTouchedBy, node.lastEventBy != t { return false }
    if let a = f.assigneeId, node.assigneeId != a { return false }

    if let has = f.has {
        for h in has {
            switch h {
            case .due: if node.dueAt == nil { return false }
            case .children: if store.getChildren(node.id).isEmpty { return false }
            case .photos, .documents:
                let live = store.getAttachmentsForNode(node.id).filter { $0.removedAt == nil }
                let ok = h == .photos
                    ? live.contains { $0.kind == .image || $0.kind == .video }
                    : live.contains { $0.kind == .pdf || $0.kind == .document || $0.kind == .spreadsheet }
                if !ok { return false }
            }
        }
    }
    if let due = f.due {
        guard let dueAt = node.dueAt else { return false }
        switch due {
        case .overdue: if dueAt >= now { return false }
        case .week: if dueAt > now + Int(7 * day) || dueAt < now { return false }
        case .month: if dueAt > now + Int(30 * day) || dueAt < now { return false }
        }
    }
    if let text = f.text, !text.isEmpty {
        let hay = (node.title + "\n" + (node.body ?? "")).lowercased()
        if !hay.contains(text.lowercased()) { return false }
    }
    return true
}

public enum SortBy: String, Sendable { case priority, created, lastActivity, due, tree }

public func treePath(_ store: ProjectionStore, _ node: Node) -> String {
    var parts = store.getAncestors(node.id).reversed().map(\.sortKey)
    parts.append(node.sortKey)
    return parts.joined(separator: "\u{0}")
}

public func compare(_ sortBy: SortBy, _ a: Node, _ b: Node, path: (Node) -> String) -> Bool {
    switch sortBy {
    case .priority:
        if a.priority != b.priority { return a.priority > b.priority }
        return a.lastEventAt > b.lastEventAt
    case .created: return a.createdAt > b.createdAt
    case .lastActivity: return a.lastEventAt > b.lastEventAt
    case .due: return (a.dueAt ?? Int.max) < (b.dueAt ?? Int.max)
    case .tree: return path(a) < path(b)
    }
}

/// Flat list: every node matching the filter, sorted.
public func query(_ store: ProjectionStore & ReadableStore, _ f: Filter, now: Millis, sortBy: SortBy = .priority) -> [Node] {
    store.allNodes()
        .filter { matches(store, $0, f, now: now) }
        .sorted { compare(sortBy, $0, $1, path: { treePath(store, $0) }) }
}

public struct TreeRow: Equatable, Sendable, Identifiable {
    public var id: String { node.id }
    public var node: Node
    public var depth: Int
    public var dimmed: Bool
    public init(node: Node, depth: Int, dimmed: Bool) { self.node = node; self.depth = depth; self.dimmed = dimmed }
}

/// Tree: matching nodes plus their non-matching ancestors (dimmed), so the path to every hit survives.
public func tree(_ store: ProjectionStore & ReadableStore, _ f: Filter, now: Millis) -> [TreeRow] {
    let hits = Set(store.allNodes().filter { matches(store, $0, f, now: now) }.map(\.id))
    var keep = hits
    for id in hits { for a in store.getAncestors(id) { keep.insert(a.id) } }
    var rows: [TreeRow] = []
    func walk(_ parentId: String?, _ depth: Int) {
        for child in store.getChildren(parentId).sorted(by: { $0.sortKey < $1.sortKey }) where keep.contains(child.id) {
            rows.append(TreeRow(node: child, depth: depth, dimmed: !hits.contains(child.id)))
            walk(child.id, depth + 1)
        }
    }
    walk(nil, 0)
    return rows
}
