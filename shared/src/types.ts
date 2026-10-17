/**
 * Core vocabulary of the property-tasks model. See DESIGN.md §1, §2, §5.
 * Nothing here knows about Cloudflare, the DOM or a particular domain
 * (buildings, boats); domain names live in vocabulary packs.
 */

export const KINDS = ["container", "task", "note"] as const;
export type Kind = (typeof KINDS)[number];

export const STATUSES = ["open", "in_progress", "blocked", "done", "cancelled"] as const;
export type Status = (typeof STATUSES)[number];

export const PRIORITIES = ["none", "low", "normal", "high", "urgent"] as const;
export type Priority = (typeof PRIORITIES)[number];
export const PRIORITY_RANK: Record<Priority, number> = { none: 0, low: 1, normal: 2, high: 3, urgent: 4 };

export const ROLES = ["owner", "editor", "viewer"] as const;
export type Role = (typeof ROLES)[number];

export const ATTACHMENT_KINDS = ["image", "video", "pdf", "document", "spreadsheet", "link", "other"] as const;
export type AttachmentKind = (typeof ATTACHMENT_KINDS)[number];

/** Milliseconds since the Unix epoch. */
export type Millis = number;

export interface Node {
  id: string;
  parentId: string | null;
  kind: Kind;
  title: string;
  /** Only tasks carry a status; containers and notes have null. */
  status: Status | null;
  priority: Priority;
  dueAt: Millis | null;
  assigneeId: string | null;
  /** Rich text for notes; null for other kinds. */
  body: string | null;
  /** Lexicographic ordering among siblings. */
  sortKey: string;
  createdAt: Millis;
  createdBy: string;
  lastEventAt: Millis;
  lastEventBy: string;
  archivedAt: Millis | null;
}

/** Fields of Node that node.field_changed may touch. */
export const MUTABLE_FIELDS = ["title", "status", "priority", "dueAt", "assigneeId", "sortKey"] as const;
export type MutableField = (typeof MUTABLE_FIELDS)[number];

/** Raw sensor data recorded at capture time; written once, never derived. See DESIGN.md §9. */
export interface CaptureSidecar {
  capturedAt?: Millis;
  gps?: { lat: number; lon: number; alt?: number; accuracyM?: number };
  headingDeg?: number;
  attitude?: { roll: number; pitch: number; yaw: number };
  intrinsics?: { focalLengthMm?: number; sensorWidthMm?: number; imageWidth: number; imageHeight: number };
  arkit?: { sessionId: string; transform: number[] };
  barometricAltM?: number;
  depthMapSha256?: string;
}

export interface Attachment {
  id: string;
  nodeId: string;
  kind: AttachmentKind;
  mime: string;
  filename: string;
  byteSize: number;
  /** Hex SHA-256 of the original bytes; the blob key. Null for links. */
  sha256: string | null;
  /** For links only. */
  url: string | null;
  width: number | null;
  height: number | null;
  durationMs: number | null;
  caption: string;
  sortKey: string;
  capture: CaptureSidecar | null;
  createdAt: Millis;
  createdBy: string;
  removedAt: Millis | null;
}

export interface Member {
  userId: string;
  role: Role;
  displayName: string;
  joinedAt: Millis;
}

/** The client-authored part of an event; the server adds seq and receivedAt. */
interface EventBase {
  /** UUIDv7 generated on the client, so retries are idempotent. */
  id: string;
  spaceId: string;
  /** Null for member events, which concern the Space rather than a node. */
  nodeId: string | null;
  actorId: string;
  deviceId: string;
  /** Client clock at authoring time. Displayed, never used for ordering. */
  at: Millis;
}

export interface ServerStamp {
  /** Monotonic per Space, assigned by the server. Ordering truth. */
  seq: number;
  receivedAt: Millis;
}

export interface NodeCreatedPayload {
  parentId: string | null;
  kind: Kind;
  title: string;
  status?: Status | null;
  priority?: Priority;
  dueAt?: Millis | null;
  assigneeId?: string | null;
  body?: string | null;
  sortKey?: string;
}

export type FieldChangedPayload =
  | { field: "title"; before: string; after: string }
  | { field: "status"; before: Status | null; after: Status | null }
  | { field: "priority"; before: Priority; after: Priority }
  | { field: "dueAt"; before: Millis | null; after: Millis | null }
  | { field: "assigneeId"; before: string | null; after: string | null }
  | { field: "sortKey"; before: string; after: string };

export type AttachmentInput = Omit<Attachment, "nodeId" | "createdAt" | "createdBy" | "removedAt">;

export type EventBody =
  | { type: "node.created"; payload: NodeCreatedPayload }
  | { type: "node.field_changed"; payload: FieldChangedPayload }
  | { type: "node.moved"; payload: { fromParentId: string | null; toParentId: string | null } }
  | { type: "node.archived"; payload: Record<string, never> }
  | { type: "node.restored"; payload: Record<string, never> }
  | { type: "label.added"; payload: { label: string } }
  | { type: "label.removed"; payload: { label: string } }
  | { type: "attachment.added"; payload: { attachment: AttachmentInput } }
  | { type: "attachment.removed"; payload: { attachmentId: string } }
  | { type: "attachment.captioned"; payload: { attachmentId: string; caption: string } }
  | { type: "note.edited"; payload: { body: string } }
  | { type: "member.joined"; payload: { userId: string; role: Role; displayName: string } }
  | { type: "member.role_changed"; payload: { userId: string; role: Role } };

export type EventType = EventBody["type"];

export type Event = EventBase & EventBody;
export type StampedEvent = Event & ServerStamp;

export const NODE_EVENT_TYPES: ReadonlySet<EventType> = new Set([
  "node.created", "node.field_changed", "node.moved", "node.archived", "node.restored",
  "label.added", "label.removed", "attachment.added", "attachment.removed", "attachment.captioned", "note.edited",
]);
