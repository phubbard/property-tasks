// Port of shared/src/types.ts. Field names and JSON keys match the TypeScript
// model exactly so events and snapshots round-trip with the Worker.
import Foundation

public typealias Millis = Int

public enum Kind: String, Codable, Sendable, CaseIterable { case container, task, note }
public enum Status: String, Codable, Sendable, CaseIterable { case open, in_progress, blocked, done, cancelled }
public enum Priority: String, Codable, Sendable, CaseIterable, Comparable {
    case none, low, normal, high, urgent
    public var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (a: Priority, b: Priority) -> Bool { a.rank < b.rank }
}
public enum Role: String, Codable, Sendable, CaseIterable { case owner, editor, viewer }
public enum AttachmentKind: String, Codable, Sendable, CaseIterable {
    case image, video, pdf, document, spreadsheet, link, scan, other
}

public struct Node: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var parentId: String?
    public var kind: Kind
    public var title: String
    public var status: Status?
    public var priority: Priority
    public var dueAt: Millis?
    public var assigneeId: String?
    public var body: String?
    public var sortKey: String
    public var createdAt: Millis
    public var createdBy: String
    public var lastEventAt: Millis
    public var lastEventBy: String
    public var archivedAt: Millis?

    public init(id: String, parentId: String?, kind: Kind, title: String, status: Status?, priority: Priority,
                dueAt: Millis?, assigneeId: String?, body: String?, sortKey: String, createdAt: Millis,
                createdBy: String, lastEventAt: Millis, lastEventBy: String, archivedAt: Millis?) {
        self.id = id; self.parentId = parentId; self.kind = kind; self.title = title; self.status = status
        self.priority = priority; self.dueAt = dueAt; self.assigneeId = assigneeId; self.body = body
        self.sortKey = sortKey; self.createdAt = createdAt; self.createdBy = createdBy
        self.lastEventAt = lastEventAt; self.lastEventBy = lastEventBy; self.archivedAt = archivedAt
    }

    // Optionals must encode as explicit null to match the TypeScript shape.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(parentId, forKey: .parentId); try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title); try c.encode(status, forKey: .status); try c.encode(priority, forKey: .priority)
        try c.encode(dueAt, forKey: .dueAt); try c.encode(assigneeId, forKey: .assigneeId); try c.encode(body, forKey: .body)
        try c.encode(sortKey, forKey: .sortKey); try c.encode(createdAt, forKey: .createdAt); try c.encode(createdBy, forKey: .createdBy)
        try c.encode(lastEventAt, forKey: .lastEventAt); try c.encode(lastEventBy, forKey: .lastEventBy); try c.encode(archivedAt, forKey: .archivedAt)
    }
}

/// Raw sensor data at capture time; written once, never derived. DESIGN.md §9.
public struct CaptureSidecar: Codable, Equatable, Sendable {
    public struct GPS: Codable, Equatable, Sendable {
        public var lat: Double; public var lon: Double; public var alt: Double?; public var accuracyM: Double?
        public init(lat: Double, lon: Double, alt: Double? = nil, accuracyM: Double? = nil) { self.lat = lat; self.lon = lon; self.alt = alt; self.accuracyM = accuracyM }
    }
    public struct Attitude: Codable, Equatable, Sendable {
        public var roll: Double; public var pitch: Double; public var yaw: Double
        public init(roll: Double, pitch: Double, yaw: Double) { self.roll = roll; self.pitch = pitch; self.yaw = yaw }
    }
    public struct Intrinsics: Codable, Equatable, Sendable {
        public var focalLengthMm: Double?; public var sensorWidthMm: Double?; public var imageWidth: Int; public var imageHeight: Int
        public init(focalLengthMm: Double? = nil, sensorWidthMm: Double? = nil, imageWidth: Int, imageHeight: Int) { self.focalLengthMm = focalLengthMm; self.sensorWidthMm = sensorWidthMm; self.imageWidth = imageWidth; self.imageHeight = imageHeight }
    }
    public struct ARKit: Codable, Equatable, Sendable {
        public var sessionId: String; public var transform: [Double]
        public init(sessionId: String, transform: [Double]) { self.sessionId = sessionId; self.transform = transform }
    }
    public var capturedAt: Millis?
    public var gps: GPS?
    public var headingDeg: Double?
    public var attitude: Attitude?
    public var intrinsics: Intrinsics?
    public var arkit: ARKit?
    public var barometricAltM: Double?
    public var depthMapSha256: String?
    public init(capturedAt: Millis? = nil, gps: GPS? = nil, headingDeg: Double? = nil, attitude: Attitude? = nil,
                intrinsics: Intrinsics? = nil, arkit: ARKit? = nil, barometricAltM: Double? = nil, depthMapSha256: String? = nil) {
        self.capturedAt = capturedAt; self.gps = gps; self.headingDeg = headingDeg; self.attitude = attitude
        self.intrinsics = intrinsics; self.arkit = arkit; self.barometricAltM = barometricAltM; self.depthMapSha256 = depthMapSha256
    }
}

public struct Attachment: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var nodeId: String
    public var kind: AttachmentKind
    public var mime: String
    public var filename: String
    public var byteSize: Int
    public var sha256: String?
    public var url: String?
    public var width: Int?
    public var height: Int?
    public var durationMs: Int?
    public var caption: String
    public var sortKey: String
    public var capture: CaptureSidecar?
    public var createdAt: Millis
    public var createdBy: String
    public var removedAt: Millis?

    public init(id: String, nodeId: String, kind: AttachmentKind, mime: String, filename: String, byteSize: Int,
                sha256: String?, url: String?, width: Int?, height: Int?, durationMs: Int?, caption: String,
                sortKey: String, capture: CaptureSidecar?, createdAt: Millis, createdBy: String, removedAt: Millis?) {
        self.id = id; self.nodeId = nodeId; self.kind = kind; self.mime = mime; self.filename = filename
        self.byteSize = byteSize; self.sha256 = sha256; self.url = url; self.width = width; self.height = height
        self.durationMs = durationMs; self.caption = caption; self.sortKey = sortKey; self.capture = capture
        self.createdAt = createdAt; self.createdBy = createdBy; self.removedAt = removedAt
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(nodeId, forKey: .nodeId); try c.encode(kind, forKey: .kind)
        try c.encode(mime, forKey: .mime); try c.encode(filename, forKey: .filename); try c.encode(byteSize, forKey: .byteSize)
        try c.encode(sha256, forKey: .sha256); try c.encode(url, forKey: .url); try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height); try c.encode(durationMs, forKey: .durationMs); try c.encode(caption, forKey: .caption)
        try c.encode(sortKey, forKey: .sortKey); try c.encode(capture, forKey: .capture); try c.encode(createdAt, forKey: .createdAt)
        try c.encode(createdBy, forKey: .createdBy); try c.encode(removedAt, forKey: .removedAt)
    }
}

/// The client-authored part of an attachment, as carried by attachment.added.
public struct AttachmentInput: Codable, Equatable, Sendable {
    public var id: String
    public var kind: AttachmentKind
    public var mime: String
    public var filename: String
    public var byteSize: Int
    public var sha256: String?
    public var url: String?
    public var width: Int?
    public var height: Int?
    public var durationMs: Int?
    public var caption: String
    public var sortKey: String
    public var capture: CaptureSidecar?
    public init(id: String, kind: AttachmentKind, mime: String, filename: String, byteSize: Int, sha256: String?,
                url: String?, width: Int?, height: Int?, durationMs: Int?, caption: String, sortKey: String, capture: CaptureSidecar?) {
        self.id = id; self.kind = kind; self.mime = mime; self.filename = filename; self.byteSize = byteSize
        self.sha256 = sha256; self.url = url; self.width = width; self.height = height; self.durationMs = durationMs
        self.caption = caption; self.sortKey = sortKey; self.capture = capture
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(kind, forKey: .kind); try c.encode(mime, forKey: .mime)
        try c.encode(filename, forKey: .filename); try c.encode(byteSize, forKey: .byteSize); try c.encode(sha256, forKey: .sha256)
        try c.encode(url, forKey: .url); try c.encode(width, forKey: .width); try c.encode(height, forKey: .height)
        try c.encode(durationMs, forKey: .durationMs); try c.encode(caption, forKey: .caption); try c.encode(sortKey, forKey: .sortKey)
        try c.encode(capture, forKey: .capture)
    }
}

public struct Member: Codable, Equatable, Sendable, Identifiable {
    public var id: String { userId }
    public var userId: String
    public var role: Role
    public var displayName: String
    public var joinedAt: Millis
    public init(userId: String, role: Role, displayName: String, joinedAt: Millis) {
        self.userId = userId; self.role = role; self.displayName = displayName; self.joinedAt = joinedAt
    }
}
