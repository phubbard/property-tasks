import type { ProjectionStore } from "./store.js";
import {
  KINDS, PRIORITIES, ROLES, STATUSES,
  type Attachment, type Event, type Member, type Node,
} from "./types.js";

/** Thrown when an event cannot be applied. The server rejects the whole batch. */
export class ProjectionError extends Error {
  constructor(message: string, public readonly eventId: string) {
    super(message);
    this.name = "ProjectionError";
  }
}

function requireNode(store: ProjectionStore, ev: Event): Node {
  if (ev.nodeId === null) throw new ProjectionError(`${ev.type} requires nodeId`, ev.id);
  const node = store.getNode(ev.nodeId);
  if (!node) throw new ProjectionError(`unknown node ${ev.nodeId}`, ev.id);
  return node;
}

function touch(node: Node, ev: Event): Node {
  return { ...node, lastEventAt: ev.at, lastEventBy: ev.actorId };
}

function isOneOf<T extends string>(list: readonly T[], v: unknown): v is T {
  return typeof v === "string" && (list as readonly string[]).includes(v);
}

/**
 * Apply one event to a store. Pure with respect to everything but the store.
 * Events are applied in server `seq` order; later events win per field.
 */
export function applyEvent(store: ProjectionStore, ev: Event): void {
  switch (ev.type) {
    case "node.created": {
      if (ev.nodeId === null) throw new ProjectionError("node.created requires nodeId", ev.id);
      if (store.getNode(ev.nodeId)) return; // duplicate create: first one wins
      const p = ev.payload;
      if (!isOneOf(KINDS, p.kind)) throw new ProjectionError(`bad kind ${String(p.kind)}`, ev.id);
      if (p.parentId !== null && !store.getNode(p.parentId)) {
        throw new ProjectionError(`unknown parent ${p.parentId}`, ev.id);
      }
      const priority = p.priority ?? "none";
      if (!isOneOf(PRIORITIES, priority)) throw new ProjectionError(`bad priority ${String(priority)}`, ev.id);
      let status = p.status ?? null;
      if (p.kind === "task") status = status ?? "open";
      else status = null;
      if (status !== null && !isOneOf(STATUSES, status)) throw new ProjectionError(`bad status ${String(status)}`, ev.id);
      store.putNode({
        id: ev.nodeId,
        parentId: p.parentId,
        kind: p.kind,
        title: p.title,
        status,
        priority,
        dueAt: p.dueAt ?? null,
        assigneeId: p.assigneeId ?? null,
        body: p.kind === "note" ? (p.body ?? "") : null,
        sortKey: p.sortKey ?? ev.id,
        createdAt: ev.at,
        createdBy: ev.actorId,
        lastEventAt: ev.at,
        lastEventBy: ev.actorId,
        archivedAt: null,
      });
      return;
    }
    case "node.field_changed": {
      const node = requireNode(store, ev);
      const p = ev.payload;
      const next = touch(node, ev);
      switch (p.field) {
        case "title":
          next.title = p.after;
          break;
        case "status":
          if (node.kind !== "task") throw new ProjectionError("only tasks have status", ev.id);
          if (p.after !== null && !isOneOf(STATUSES, p.after)) throw new ProjectionError(`bad status ${String(p.after)}`, ev.id);
          next.status = p.after;
          break;
        case "priority":
          if (!isOneOf(PRIORITIES, p.after)) throw new ProjectionError(`bad priority ${String(p.after)}`, ev.id);
          next.priority = p.after;
          break;
        case "dueAt":
          next.dueAt = p.after;
          break;
        case "assigneeId":
          next.assigneeId = p.after;
          break;
        case "sortKey":
          next.sortKey = p.after;
          break;
        default:
          throw new ProjectionError(`bad field ${String((p as { field: unknown }).field)}`, ev.id);
      }
      store.putNode(next);
      return;
    }
    case "node.moved": {
      const node = requireNode(store, ev);
      const to = ev.payload.toParentId;
      if (to !== null) {
        if (to === node.id) throw new ProjectionError("cannot move a node under itself", ev.id);
        const target = store.getNode(to);
        if (!target) throw new ProjectionError(`unknown parent ${to}`, ev.id);
        if (store.getAncestors(to).some((a) => a.id === node.id)) {
          throw new ProjectionError("cannot move a node under its own descendant", ev.id);
        }
      }
      store.putNode({ ...touch(node, ev), parentId: to });
      return;
    }
    case "node.archived": {
      const node = requireNode(store, ev);
      store.putNode({ ...touch(node, ev), archivedAt: node.archivedAt ?? ev.at });
      return;
    }
    case "node.restored": {
      const node = requireNode(store, ev);
      store.putNode({ ...touch(node, ev), archivedAt: null });
      return;
    }
    case "label.added": {
      const node = requireNode(store, ev);
      store.addLabel(node.id, ev.payload.label);
      store.putNode(touch(node, ev));
      return;
    }
    case "label.removed": {
      const node = requireNode(store, ev);
      store.removeLabel(node.id, ev.payload.label);
      store.putNode(touch(node, ev));
      return;
    }
    case "attachment.added": {
      const node = requireNode(store, ev);
      const a = ev.payload.attachment;
      if (store.getAttachment(a.id)) return; // duplicate add: first one wins
      const attachment: Attachment = {
        ...a,
        nodeId: node.id,
        createdAt: ev.at,
        createdBy: ev.actorId,
        removedAt: null,
      };
      store.putAttachment(attachment);
      store.putNode(touch(node, ev));
      return;
    }
    case "attachment.removed": {
      const node = requireNode(store, ev);
      const a = store.getAttachment(ev.payload.attachmentId);
      if (!a || a.nodeId !== node.id) throw new ProjectionError(`unknown attachment ${ev.payload.attachmentId}`, ev.id);
      store.putAttachment({ ...a, removedAt: a.removedAt ?? ev.at });
      store.putNode(touch(node, ev));
      return;
    }
    case "attachment.captioned": {
      const node = requireNode(store, ev);
      const a = store.getAttachment(ev.payload.attachmentId);
      if (!a || a.nodeId !== node.id) throw new ProjectionError(`unknown attachment ${ev.payload.attachmentId}`, ev.id);
      store.putAttachment({ ...a, caption: ev.payload.caption });
      store.putNode(touch(node, ev));
      return;
    }
    case "note.edited": {
      const node = requireNode(store, ev);
      if (node.kind !== "note") throw new ProjectionError("only notes have a body", ev.id);
      store.putNode({ ...touch(node, ev), body: ev.payload.body });
      return;
    }
    case "member.joined": {
      const p = ev.payload;
      if (!isOneOf(ROLES, p.role)) throw new ProjectionError(`bad role ${String(p.role)}`, ev.id);
      if (store.getMember(p.userId)) return;
      const member: Member = { userId: p.userId, role: p.role, displayName: p.displayName, joinedAt: ev.at };
      store.putMember(member);
      return;
    }
    case "member.role_changed": {
      const p = ev.payload;
      if (!isOneOf(ROLES, p.role)) throw new ProjectionError(`bad role ${String(p.role)}`, ev.id);
      const m = store.getMember(p.userId);
      if (!m) throw new ProjectionError(`unknown member ${p.userId}`, ev.id);
      store.putMember({ ...m, role: p.role });
      return;
    }
    default: {
      const t: never = ev;
      throw new ProjectionError(`unknown event type ${String((t as { type: unknown }).type)}`, (t as { id: string }).id);
    }
  }
}

export function replay(store: ProjectionStore, events: Iterable<Event>): void {
  for (const ev of events) applyEvent(store, ev);
}
