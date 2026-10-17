import Foundation

/// Port of shared/src/store.ts. `applyEvent` works against this protocol so
/// the same semantics run over an in-memory store (tests, previews) and a
/// SQLite-backed one (the app).
public protocol ProjectionStore: AnyObject {
    func getNode(_ id: String) -> Node?
    func putNode(_ node: Node)
    func getChildren(_ parentId: String?) -> [Node]
    /// Ancestors nearest first, excluding the node itself.
    func getAncestors(_ id: String) -> [Node]
    func getLabels(_ nodeId: String) -> [String]
    func addLabel(_ nodeId: String, _ label: String)
    func removeLabel(_ nodeId: String, _ label: String)
    func getAttachment(_ id: String) -> Attachment?
    func putAttachment(_ attachment: Attachment)
    func getAttachmentsForNode(_ nodeId: String) -> [Attachment]
    func getMember(_ userId: String) -> Member?
    func putMember(_ member: Member)
}

public protocol ReadableStore: AnyObject {
    func allNodes() -> [Node]
    func allLabels() -> [(nodeId: String, label: String)]
    func allAttachments() -> [Attachment]
    func allMembers() -> [Member]
}

/// Stable, sorted view of a projection. Fixtures compare this.
public struct Serialized: Codable, Equatable, Sendable {
    public var nodes: [Node]
    public var labels: [String: [String]]
    public var attachments: [Attachment]
    public var members: [Member]
    public init(nodes: [Node], labels: [String: [String]], attachments: [Attachment], members: [Member]) {
        self.nodes = nodes; self.labels = labels; self.attachments = attachments; self.members = members
    }
}

public func serialize(_ store: ReadableStore) -> Serialized {
    var labels: [String: [String]] = [:]
    for (nodeId, label) in store.allLabels() { labels[nodeId, default: []].append(label) }
    for k in labels.keys { labels[k]!.sort() }
    return Serialized(
        nodes: store.allNodes().sorted { $0.id < $1.id },
        labels: labels,
        attachments: store.allAttachments().sorted { $0.id < $1.id },
        members: store.allMembers().sorted { $0.userId < $1.userId }
    )
}

public final class MemoryStore: ProjectionStore, ReadableStore {
    private var nodes: [String: Node] = [:]
    private var labels: [String: Set<String>] = [:]
    private var attachments: [String: Attachment] = [:]
    private var members: [String: Member] = [:]

    public init() {}

    public func getNode(_ id: String) -> Node? { nodes[id] }
    public func putNode(_ node: Node) { nodes[node.id] = node }
    public func getChildren(_ parentId: String?) -> [Node] { nodes.values.filter { $0.parentId == parentId } }
    public func getAncestors(_ id: String) -> [Node] {
        var out: [Node] = []
        var seen: Set<String> = [id]
        var cur = nodes[id]
        while let c = cur, let pid = c.parentId {
            if seen.contains(pid) { break }
            seen.insert(pid)
            guard let parent = nodes[pid] else { break }
            out.append(parent)
            cur = parent
        }
        return out
    }
    public func getLabels(_ nodeId: String) -> [String] { (labels[nodeId] ?? []).sorted() }
    public func addLabel(_ nodeId: String, _ label: String) { labels[nodeId, default: []].insert(label) }
    public func removeLabel(_ nodeId: String, _ label: String) { labels[nodeId]?.remove(label) }
    public func getAttachment(_ id: String) -> Attachment? { attachments[id] }
    public func putAttachment(_ attachment: Attachment) { attachments[attachment.id] = attachment }
    public func getAttachmentsForNode(_ nodeId: String) -> [Attachment] { attachments.values.filter { $0.nodeId == nodeId } }
    public func getMember(_ userId: String) -> Member? { members[userId] }
    public func putMember(_ member: Member) { members[member.userId] = member }

    public func allNodes() -> [Node] { Array(nodes.values) }
    public func allLabels() -> [(nodeId: String, label: String)] {
        labels.flatMap { nodeId, set in set.map { (nodeId: nodeId, label: $0) } }
    }
    public func allAttachments() -> [Attachment] { Array(attachments.values) }
    public func allMembers() -> [Member] { Array(members.values) }
}
