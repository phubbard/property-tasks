import type { Attachment, Member, Node } from "./types.js";

/**
 * What a projection needs from its storage. `applyEvent` is written against
 * this interface so the same event semantics run over an in-memory map
 * (browser, tests) and over SQLite tables in the Durable Object.
 */
export interface ProjectionStore {
  getNode(id: string): Node | undefined;
  /** Insert or replace. Implementations maintain any closure/index on parent change. */
  putNode(node: Node): void;
  getChildren(parentId: string | null): Node[];
  /** Ancestors nearest first, excluding the node itself. */
  getAncestors(id: string): Node[];
  getLabels(nodeId: string): string[];
  addLabel(nodeId: string, label: string): void;
  removeLabel(nodeId: string, label: string): void;
  getAttachment(id: string): Attachment | undefined;
  putAttachment(attachment: Attachment): void;
  getAttachmentsForNode(nodeId: string): Attachment[];
  getMember(userId: string): Member | undefined;
  putMember(member: Member): void;
}

export interface ReadableStore {
  allNodes(): Node[];
  allLabels(): Array<{ nodeId: string; label: string }>;
  allAttachments(): Attachment[];
  allMembers(): Member[];
}

/** Stable, sorted, JSON-friendly view of a projection. Fixtures compare this. */
export interface Serialized {
  nodes: Node[];
  labels: Record<string, string[]>;
  attachments: Attachment[];
  members: Member[];
}

export function serialize(store: ReadableStore): Serialized {
  const labels: Record<string, string[]> = {};
  for (const { nodeId, label } of store.allLabels()) {
    (labels[nodeId] ??= []).push(label);
  }
  for (const list of Object.values(labels)) list.sort();
  const byId = <T extends { id: string }>(a: T, b: T) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
  return {
    nodes: [...store.allNodes()].sort(byId),
    labels: Object.fromEntries(Object.entries(labels).sort(([a], [b]) => (a < b ? -1 : 1))),
    attachments: [...store.allAttachments()].sort(byId),
    members: [...store.allMembers()].sort((a, b) => (a.userId < b.userId ? -1 : 1)),
  };
}

export class MemoryStore implements ProjectionStore, ReadableStore {
  private nodes = new Map<string, Node>();
  private labels = new Map<string, Set<string>>();
  private attachments = new Map<string, Attachment>();
  private members = new Map<string, Member>();

  getNode(id: string): Node | undefined {
    return this.nodes.get(id);
  }
  putNode(node: Node): void {
    this.nodes.set(node.id, { ...node });
  }
  getChildren(parentId: string | null): Node[] {
    return [...this.nodes.values()].filter((n) => n.parentId === parentId);
  }
  getAncestors(id: string): Node[] {
    const out: Node[] = [];
    let cur = this.nodes.get(id);
    const seen = new Set<string>([id]);
    while (cur && cur.parentId !== null) {
      if (seen.has(cur.parentId)) break; // defensive against cycles
      seen.add(cur.parentId);
      const parent = this.nodes.get(cur.parentId);
      if (!parent) break;
      out.push(parent);
      cur = parent;
    }
    return out;
  }
  getLabels(nodeId: string): string[] {
    return [...(this.labels.get(nodeId) ?? [])].sort();
  }
  addLabel(nodeId: string, label: string): void {
    let set = this.labels.get(nodeId);
    if (!set) this.labels.set(nodeId, (set = new Set()));
    set.add(label);
  }
  removeLabel(nodeId: string, label: string): void {
    this.labels.get(nodeId)?.delete(label);
  }
  getAttachment(id: string): Attachment | undefined {
    return this.attachments.get(id);
  }
  putAttachment(attachment: Attachment): void {
    this.attachments.set(attachment.id, { ...attachment });
  }
  getAttachmentsForNode(nodeId: string): Attachment[] {
    return [...this.attachments.values()].filter((a) => a.nodeId === nodeId);
  }
  getMember(userId: string): Member | undefined {
    return this.members.get(userId);
  }
  putMember(member: Member): void {
    this.members.set(member.userId, { ...member });
  }

  allNodes(): Node[] {
    return [...this.nodes.values()];
  }
  allLabels(): Array<{ nodeId: string; label: string }> {
    const out: Array<{ nodeId: string; label: string }> = [];
    for (const [nodeId, set] of this.labels) for (const label of set) out.push({ nodeId, label });
    return out;
  }
  allAttachments(): Attachment[] {
    return [...this.attachments.values()];
  }
  allMembers(): Member[] {
    return [...this.members.values()];
  }
}
