import Foundation

public struct NodeCreatedPayload: Codable, Equatable, Sendable {
    public var parentId: String?
    public var kind: Kind
    public var title: String
    public var status: Status?
    public var priority: Priority?
    public var dueAt: Millis?
    public var assigneeId: String?
    public var body: String?
    public var sortKey: String?
    public init(parentId: String?, kind: Kind, title: String, status: Status? = nil, priority: Priority? = nil,
                dueAt: Millis? = nil, assigneeId: String? = nil, body: String? = nil, sortKey: String? = nil) {
        self.parentId = parentId; self.kind = kind; self.title = title; self.status = status; self.priority = priority
        self.dueAt = dueAt; self.assigneeId = assigneeId; self.body = body; self.sortKey = sortKey
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(parentId, forKey: .parentId) // explicit null, as TypeScript does
        try c.encode(kind, forKey: .kind); try c.encode(title, forKey: .title)
        try c.encodeIfPresent(status, forKey: .status); try c.encodeIfPresent(priority, forKey: .priority)
        try c.encodeIfPresent(dueAt, forKey: .dueAt); try c.encodeIfPresent(assigneeId, forKey: .assigneeId)
        try c.encodeIfPresent(body, forKey: .body); try c.encodeIfPresent(sortKey, forKey: .sortKey)
    }
}

public struct FieldChangedPayload: Codable, Equatable, Sendable {
    public var field: String
    public var before: JSONValue
    public var after: JSONValue
    public init(field: String, before: JSONValue, after: JSONValue) { self.field = field; self.before = before; self.after = after }
}

public struct MovedPayload: Codable, Equatable, Sendable {
    public var fromParentId: String?
    public var toParentId: String?
    public init(fromParentId: String?, toParentId: String?) { self.fromParentId = fromParentId; self.toParentId = toParentId }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fromParentId, forKey: .fromParentId); try c.encode(toParentId, forKey: .toParentId)
    }
}

public struct LabelPayload: Codable, Equatable, Sendable { public var label: String; public init(label: String) { self.label = label } }
public struct AttachmentAddedPayload: Codable, Equatable, Sendable { public var attachment: AttachmentInput; public init(attachment: AttachmentInput) { self.attachment = attachment } }
public struct AttachmentRefPayload: Codable, Equatable, Sendable { public var attachmentId: String; public init(attachmentId: String) { self.attachmentId = attachmentId } }
public struct AttachmentCaptionedPayload: Codable, Equatable, Sendable {
    public var attachmentId: String; public var caption: String
    public init(attachmentId: String, caption: String) { self.attachmentId = attachmentId; self.caption = caption }
}
public struct NoteEditedPayload: Codable, Equatable, Sendable { public var body: String; public init(body: String) { self.body = body } }
public struct MemberJoinedPayload: Codable, Equatable, Sendable {
    public var userId: String; public var role: Role; public var displayName: String
    public init(userId: String, role: Role, displayName: String) { self.userId = userId; self.role = role; self.displayName = displayName }
}
public struct MemberRolePayload: Codable, Equatable, Sendable {
    public var userId: String; public var role: Role
    public init(userId: String, role: Role) { self.userId = userId; self.role = role }
}

/// Discriminated by the wire `type` string. Mirrors EventBody in shared/src/types.ts.
public enum EventBody: Equatable, Sendable {
    case nodeCreated(NodeCreatedPayload)
    case fieldChanged(FieldChangedPayload)
    case moved(MovedPayload)
    case archived
    case restored
    case labelAdded(LabelPayload)
    case labelRemoved(LabelPayload)
    case attachmentAdded(AttachmentAddedPayload)
    case attachmentRemoved(AttachmentRefPayload)
    case attachmentCaptioned(AttachmentCaptionedPayload)
    case noteEdited(NoteEditedPayload)
    case memberJoined(MemberJoinedPayload)
    case memberRoleChanged(MemberRolePayload)

    public var type: String {
        switch self {
        case .nodeCreated: return "node.created"
        case .fieldChanged: return "node.field_changed"
        case .moved: return "node.moved"
        case .archived: return "node.archived"
        case .restored: return "node.restored"
        case .labelAdded: return "label.added"
        case .labelRemoved: return "label.removed"
        case .attachmentAdded: return "attachment.added"
        case .attachmentRemoved: return "attachment.removed"
        case .attachmentCaptioned: return "attachment.captioned"
        case .noteEdited: return "note.edited"
        case .memberJoined: return "member.joined"
        case .memberRoleChanged: return "member.role_changed"
        }
    }
}

public struct Event: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var spaceId: String
    public var nodeId: String?
    public var actorId: String
    public var deviceId: String
    public var at: Millis
    public var body: EventBody
    /// Server-assigned; nil until the event has been accepted.
    public var seq: Int?
    public var receivedAt: Millis?

    public var type: String { body.type }

    public init(id: String, spaceId: String, nodeId: String?, actorId: String, deviceId: String, at: Millis,
                body: EventBody, seq: Int? = nil, receivedAt: Millis? = nil) {
        self.id = id; self.spaceId = spaceId; self.nodeId = nodeId; self.actorId = actorId; self.deviceId = deviceId
        self.at = at; self.body = body; self.seq = seq; self.receivedAt = receivedAt
    }

    enum CodingKeys: String, CodingKey { case id, spaceId, nodeId, actorId, deviceId, at, type, payload, seq, receivedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        spaceId = try c.decode(String.self, forKey: .spaceId)
        nodeId = try c.decodeIfPresent(String.self, forKey: .nodeId)
        actorId = try c.decode(String.self, forKey: .actorId)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        at = try c.decode(Millis.self, forKey: .at)
        seq = try c.decodeIfPresent(Int.self, forKey: .seq)
        receivedAt = try c.decodeIfPresent(Millis.self, forKey: .receivedAt)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "node.created": body = .nodeCreated(try c.decode(NodeCreatedPayload.self, forKey: .payload))
        case "node.field_changed": body = .fieldChanged(try c.decode(FieldChangedPayload.self, forKey: .payload))
        case "node.moved": body = .moved(try c.decode(MovedPayload.self, forKey: .payload))
        case "node.archived": body = .archived
        case "node.restored": body = .restored
        case "label.added": body = .labelAdded(try c.decode(LabelPayload.self, forKey: .payload))
        case "label.removed": body = .labelRemoved(try c.decode(LabelPayload.self, forKey: .payload))
        case "attachment.added": body = .attachmentAdded(try c.decode(AttachmentAddedPayload.self, forKey: .payload))
        case "attachment.removed": body = .attachmentRemoved(try c.decode(AttachmentRefPayload.self, forKey: .payload))
        case "attachment.captioned": body = .attachmentCaptioned(try c.decode(AttachmentCaptionedPayload.self, forKey: .payload))
        case "note.edited": body = .noteEdited(try c.decode(NoteEditedPayload.self, forKey: .payload))
        case "member.joined": body = .memberJoined(try c.decode(MemberJoinedPayload.self, forKey: .payload))
        case "member.role_changed": body = .memberRoleChanged(try c.decode(MemberRolePayload.self, forKey: .payload))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown event type \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(spaceId, forKey: .spaceId); try c.encode(nodeId, forKey: .nodeId)
        try c.encode(actorId, forKey: .actorId); try c.encode(deviceId, forKey: .deviceId); try c.encode(at, forKey: .at)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(seq, forKey: .seq); try c.encodeIfPresent(receivedAt, forKey: .receivedAt)
        switch body {
        case .nodeCreated(let p): try c.encode(p, forKey: .payload)
        case .fieldChanged(let p): try c.encode(p, forKey: .payload)
        case .moved(let p): try c.encode(p, forKey: .payload)
        case .archived, .restored: try c.encode([String: String](), forKey: .payload)
        case .labelAdded(let p), .labelRemoved(let p): try c.encode(p, forKey: .payload)
        case .attachmentAdded(let p): try c.encode(p, forKey: .payload)
        case .attachmentRemoved(let p): try c.encode(p, forKey: .payload)
        case .attachmentCaptioned(let p): try c.encode(p, forKey: .payload)
        case .noteEdited(let p): try c.encode(p, forKey: .payload)
        case .memberJoined(let p): try c.encode(p, forKey: .payload)
        case .memberRoleChanged(let p): try c.encode(p, forKey: .payload)
        }
    }
}
