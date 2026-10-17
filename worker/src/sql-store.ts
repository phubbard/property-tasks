import type { Attachment, CaptureSidecar, Member, Node, ProjectionStore, ReadableStore } from "@property-tasks/shared";

type NodeRow = {
  id: string; parent_id: string | null; kind: string; title: string; status: string | null; priority: string;
  due_at: number | null; assignee_id: string | null; body: string | null; sort_key: string; created_at: number;
  created_by: string; last_event_at: number; last_event_by: string; archived_at: number | null;
};
type AttachmentRow = {
  id: string; node_id: string; kind: string; mime: string; filename: string; byte_size: number; sha256: string | null;
  url: string | null; width: number | null; height: number | null; duration_ms: number | null; caption: string;
  sort_key: string; capture: string | null; created_at: number; created_by: string; removed_at: number | null;
};
type MemberRow = { user_id: string; role: string; display_name: string; joined_at: number };

const nodeFromRow = (r: NodeRow): Node => ({
  id: r.id, parentId: r.parent_id, kind: r.kind as Node["kind"], title: r.title,
  status: r.status as Node["status"], priority: r.priority as Node["priority"], dueAt: r.due_at,
  assigneeId: r.assignee_id, body: r.body, sortKey: r.sort_key, createdAt: r.created_at, createdBy: r.created_by,
  lastEventAt: r.last_event_at, lastEventBy: r.last_event_by, archivedAt: r.archived_at,
});
const attachmentFromRow = (r: AttachmentRow): Attachment => ({
  id: r.id, nodeId: r.node_id, kind: r.kind as Attachment["kind"], mime: r.mime, filename: r.filename,
  byteSize: r.byte_size, sha256: r.sha256, url: r.url, width: r.width, height: r.height, durationMs: r.duration_ms,
  caption: r.caption, sortKey: r.sort_key, capture: r.capture ? (JSON.parse(r.capture) as CaptureSidecar) : null,
  createdAt: r.created_at, createdBy: r.created_by, removedAt: r.removed_at,
});
const memberFromRow = (r: MemberRow): Member => ({
  userId: r.user_id, role: r.role as Member["role"], displayName: r.display_name, joinedAt: r.joined_at,
});

export const SCHEMA = `
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS events (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT NOT NULL UNIQUE,
  node_id TEXT,
  actor_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  at INTEGER NOT NULL,
  received_at INTEGER NOT NULL,
  type TEXT NOT NULL,
  payload TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS nodes (
  id TEXT PRIMARY KEY, parent_id TEXT, kind TEXT NOT NULL, title TEXT NOT NULL, status TEXT,
  priority TEXT NOT NULL, due_at INTEGER, assignee_id TEXT, body TEXT, sort_key TEXT NOT NULL,
  created_at INTEGER NOT NULL, created_by TEXT NOT NULL, last_event_at INTEGER NOT NULL,
  last_event_by TEXT NOT NULL, archived_at INTEGER
);
CREATE INDEX IF NOT EXISTS nodes_parent ON nodes(parent_id);
CREATE TABLE IF NOT EXISTS node_closure (
  ancestor_id TEXT NOT NULL, descendant_id TEXT NOT NULL, depth INTEGER NOT NULL,
  PRIMARY KEY (ancestor_id, descendant_id)
);
CREATE INDEX IF NOT EXISTS closure_desc ON node_closure(descendant_id);
CREATE TABLE IF NOT EXISTS node_labels (node_id TEXT NOT NULL, label TEXT NOT NULL, PRIMARY KEY (node_id, label));
CREATE TABLE IF NOT EXISTS attachments (
  id TEXT PRIMARY KEY, node_id TEXT NOT NULL, kind TEXT NOT NULL, mime TEXT NOT NULL, filename TEXT NOT NULL,
  byte_size INTEGER NOT NULL, sha256 TEXT, url TEXT, width INTEGER, height INTEGER, duration_ms INTEGER,
  caption TEXT NOT NULL, sort_key TEXT NOT NULL, capture TEXT, created_at INTEGER NOT NULL,
  created_by TEXT NOT NULL, removed_at INTEGER
);
CREATE INDEX IF NOT EXISTS attachments_node ON attachments(node_id);
CREATE TABLE IF NOT EXISTS members (
  user_id TEXT PRIMARY KEY, role TEXT NOT NULL, display_name TEXT NOT NULL, joined_at INTEGER NOT NULL
);
`;

/**
 * ProjectionStore over the Durable Object's SQLite. The closure table is
 * maintained here on insert and reparent, so "under X" and roll-ups are
 * single joins. All methods are synchronous; callers wrap a batch in
 * `transactionSync` so a rejected event rolls the whole batch back.
 */
export class SqlStore implements ProjectionStore, ReadableStore {
  constructor(private readonly sql: SqlStorage) {}

  getNode(id: string): Node | undefined {
    const rows = this.sql.exec<NodeRow>("SELECT * FROM nodes WHERE id = ?", id).toArray();
    return rows[0] ? nodeFromRow(rows[0]) : undefined;
  }

  putNode(n: Node): void {
    const existing = this.getNode(n.id);
    this.sql.exec(
      `INSERT OR REPLACE INTO nodes (id, parent_id, kind, title, status, priority, due_at, assignee_id, body, sort_key,
         created_at, created_by, last_event_at, last_event_by, archived_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      n.id, n.parentId, n.kind, n.title, n.status, n.priority, n.dueAt, n.assigneeId, n.body, n.sortKey,
      n.createdAt, n.createdBy, n.lastEventAt, n.lastEventBy, n.archivedAt,
    );
    if (!existing) {
      this.sql.exec("INSERT INTO node_closure (ancestor_id, descendant_id, depth) VALUES (?, ?, 0)", n.id, n.id);
      if (n.parentId !== null) {
        this.sql.exec(
          `INSERT INTO node_closure (ancestor_id, descendant_id, depth)
           SELECT ancestor_id, ?, depth + 1 FROM node_closure WHERE descendant_id = ?`,
          n.id, n.parentId,
        );
      }
    } else if (existing.parentId !== n.parentId) {
      // Detach the subtree from every ancestor outside it...
      this.sql.exec(
        `DELETE FROM node_closure
         WHERE descendant_id IN (SELECT descendant_id FROM node_closure WHERE ancestor_id = ?)
           AND ancestor_id NOT IN (SELECT descendant_id FROM node_closure WHERE ancestor_id = ?)`,
        n.id, n.id,
      );
      // ...and attach it under the new parent's ancestor chain.
      if (n.parentId !== null) {
        this.sql.exec(
          `INSERT INTO node_closure (ancestor_id, descendant_id, depth)
           SELECT a.ancestor_id, d.descendant_id, a.depth + d.depth + 1
           FROM node_closure a, node_closure d
           WHERE a.descendant_id = ? AND d.ancestor_id = ?`,
          n.parentId, n.id,
        );
      }
    }
  }

  getChildren(parentId: string | null): Node[] {
    const rows = parentId === null
      ? this.sql.exec<NodeRow>("SELECT * FROM nodes WHERE parent_id IS NULL ORDER BY sort_key, id").toArray()
      : this.sql.exec<NodeRow>("SELECT * FROM nodes WHERE parent_id = ? ORDER BY sort_key, id", parentId).toArray();
    return rows.map(nodeFromRow);
  }

  getAncestors(id: string): Node[] {
    return this.sql
      .exec<NodeRow>(
        `SELECT n.* FROM node_closure c JOIN nodes n ON n.id = c.ancestor_id
         WHERE c.descendant_id = ? AND c.depth > 0 ORDER BY c.depth`,
        id,
      )
      .toArray()
      .map(nodeFromRow);
  }

  getLabels(nodeId: string): string[] {
    return this.sql.exec<{ label: string }>("SELECT label FROM node_labels WHERE node_id = ? ORDER BY label", nodeId)
      .toArray().map((r) => r.label);
  }
  addLabel(nodeId: string, label: string): void {
    this.sql.exec("INSERT OR IGNORE INTO node_labels (node_id, label) VALUES (?, ?)", nodeId, label);
  }
  removeLabel(nodeId: string, label: string): void {
    this.sql.exec("DELETE FROM node_labels WHERE node_id = ? AND label = ?", nodeId, label);
  }

  getAttachment(id: string): Attachment | undefined {
    const rows = this.sql.exec<AttachmentRow>("SELECT * FROM attachments WHERE id = ?", id).toArray();
    return rows[0] ? attachmentFromRow(rows[0]) : undefined;
  }
  putAttachment(a: Attachment): void {
    this.sql.exec(
      `INSERT OR REPLACE INTO attachments (id, node_id, kind, mime, filename, byte_size, sha256, url, width, height,
         duration_ms, caption, sort_key, capture, created_at, created_by, removed_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      a.id, a.nodeId, a.kind, a.mime, a.filename, a.byteSize, a.sha256, a.url, a.width, a.height,
      a.durationMs, a.caption, a.sortKey, a.capture ? JSON.stringify(a.capture) : null, a.createdAt, a.createdBy, a.removedAt,
    );
  }
  getAttachmentsForNode(nodeId: string): Attachment[] {
    return this.sql.exec<AttachmentRow>("SELECT * FROM attachments WHERE node_id = ? ORDER BY sort_key, id", nodeId)
      .toArray().map(attachmentFromRow);
  }

  getMember(userId: string): Member | undefined {
    const rows = this.sql.exec<MemberRow>("SELECT * FROM members WHERE user_id = ?", userId).toArray();
    return rows[0] ? memberFromRow(rows[0]) : undefined;
  }
  putMember(m: Member): void {
    this.sql.exec(
      "INSERT OR REPLACE INTO members (user_id, role, display_name, joined_at) VALUES (?, ?, ?, ?)",
      m.userId, m.role, m.displayName, m.joinedAt,
    );
  }

  allNodes(): Node[] {
    return this.sql.exec<NodeRow>("SELECT * FROM nodes").toArray().map(nodeFromRow);
  }
  allLabels(): Array<{ nodeId: string; label: string }> {
    return this.sql.exec<{ node_id: string; label: string }>("SELECT node_id, label FROM node_labels").toArray()
      .map((r) => ({ nodeId: r.node_id, label: r.label }));
  }
  allAttachments(): Attachment[] {
    return this.sql.exec<AttachmentRow>("SELECT * FROM attachments").toArray().map(attachmentFromRow);
  }
  allMembers(): Member[] {
    return this.sql.exec<MemberRow>("SELECT * FROM members").toArray().map(memberFromRow);
  }
}
