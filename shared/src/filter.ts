import type { ProjectionStore } from "./store.js";
import { PRIORITY_RANK, type Kind, type Millis, type Node, type Priority, type Status } from "./types.js";

const DAY = 86_400_000;

/** One filter bar for tree and list. Every field is optional and they AND together. See DESIGN.md §4. */
export interface Filter {
  /** Default when omitted: open, in_progress, blocked. Pass [] for "any status". */
  status?: Status[];
  /** Exact set of priorities, or a minimum. */
  priority?: Priority[];
  priorityMin?: Priority;
  kind?: Kind[];
  /** Node must carry all of these labels. */
  labels?: string[];
  /** Node must be a strict descendant of at least one of these. */
  under?: string[];
  /** Created within the last N days / at least N days ago. */
  ageMaxDays?: number;
  ageMinDays?: number;
  /** No event in the last N days. */
  staleDays?: number;
  createdBy?: string;
  lastTouchedBy?: string;
  assigneeId?: string;
  has?: Array<"photos" | "documents" | "due" | "children">;
  due?: "overdue" | "week" | "month";
  includeArchived?: boolean;
  /** Case-insensitive substring over title and note body. */
  text?: string;
}

export const DEFAULT_OPEN_STATUSES: Status[] = ["open", "in_progress", "blocked"];

export function matches(store: ProjectionStore, node: Node, f: Filter, now: Millis): boolean {
  if (!f.includeArchived && node.archivedAt !== null) return false;
  if (f.kind && !f.kind.includes(node.kind)) return false;

  const statuses = f.status ?? DEFAULT_OPEN_STATUSES;
  if (statuses.length > 0 && node.kind === "task" && (node.status === null || !statuses.includes(node.status))) return false;

  if (f.priority && !f.priority.includes(node.priority)) return false;
  if (f.priorityMin && PRIORITY_RANK[node.priority] < PRIORITY_RANK[f.priorityMin]) return false;

  if (f.labels && f.labels.length > 0) {
    const have = new Set(store.getLabels(node.id));
    if (!f.labels.every((l) => have.has(l))) return false;
  }
  if (f.under && f.under.length > 0) {
    const ancestors = new Set(store.getAncestors(node.id).map((a) => a.id));
    if (!f.under.some((u) => ancestors.has(u))) return false;
  }
  const ageDays = (now - node.createdAt) / DAY;
  if (f.ageMaxDays !== undefined && ageDays > f.ageMaxDays) return false;
  if (f.ageMinDays !== undefined && ageDays < f.ageMinDays) return false;
  if (f.staleDays !== undefined && (now - node.lastEventAt) / DAY < f.staleDays) return false;

  if (f.createdBy && node.createdBy !== f.createdBy) return false;
  if (f.lastTouchedBy && node.lastEventBy !== f.lastTouchedBy) return false;
  if (f.assigneeId && node.assigneeId !== f.assigneeId) return false;

  if (f.has) {
    for (const h of f.has) {
      if (h === "due" && node.dueAt === null) return false;
      if (h === "children" && store.getChildren(node.id).length === 0) return false;
      if (h === "photos" || h === "documents") {
        const live = store.getAttachmentsForNode(node.id).filter((a) => a.removedAt === null);
        const ok = h === "photos"
          ? live.some((a) => a.kind === "image" || a.kind === "video")
          : live.some((a) => a.kind === "pdf" || a.kind === "document" || a.kind === "spreadsheet");
        if (!ok) return false;
      }
    }
  }
  if (f.due) {
    if (node.dueAt === null) return false;
    const horizon = f.due === "overdue" ? now : f.due === "week" ? now + 7 * DAY : now + 30 * DAY;
    if (f.due === "overdue" ? node.dueAt >= now : node.dueAt > horizon || node.dueAt < now) return false;
  }
  if (f.text) {
    const q = f.text.toLowerCase();
    const hay = `${node.title}\n${node.body ?? ""}`.toLowerCase();
    if (!hay.includes(q)) return false;
  }
  return true;
}

export type SortBy = "priority" | "created" | "lastActivity" | "due" | "tree";

export function compare(sortBy: SortBy, a: Node, b: Node, path: (n: Node) => string): number {
  switch (sortBy) {
    case "priority":
      return PRIORITY_RANK[b.priority] - PRIORITY_RANK[a.priority] || b.lastEventAt - a.lastEventAt;
    case "created":
      return b.createdAt - a.createdAt;
    case "lastActivity":
      return b.lastEventAt - a.lastEventAt;
    case "due":
      return (a.dueAt ?? Number.MAX_SAFE_INTEGER) - (b.dueAt ?? Number.MAX_SAFE_INTEGER);
    case "tree": {
      const pa = path(a), pb = path(b);
      return pa < pb ? -1 : pa > pb ? 1 : 0;
    }
  }
}

/** Sort key for tree order: ancestors' sortKeys joined root-first. */
export function treePath(store: ProjectionStore, node: Node): string {
  const parts = store.getAncestors(node.id).reverse().map((n) => n.sortKey);
  parts.push(node.sortKey);
  return parts.join("\u0000");
}

/** Flat list: every node matching the filter, sorted. */
export function query(
  store: ProjectionStore & { allNodes(): Node[] },
  f: Filter,
  now: Millis,
  sortBy: SortBy = "priority",
): Node[] {
  const out = store.allNodes().filter((n) => matches(store, n, f, now));
  out.sort((a, b) => compare(sortBy, a, b, (n) => treePath(store, n)));
  return out;
}

/**
 * Tree: matching nodes plus their non-matching ancestors (marked dimmed),
 * so the path to every hit survives. Non-matching subtrees are dropped.
 */
export interface TreeRow { node: Node; depth: number; dimmed: boolean }

export function tree(store: ProjectionStore & { allNodes(): Node[] }, f: Filter, now: Millis): TreeRow[] {
  const hits = new Set(store.allNodes().filter((n) => matches(store, n, f, now)).map((n) => n.id));
  const keep = new Set(hits);
  for (const id of hits) for (const a of store.getAncestors(id)) keep.add(a.id);
  const rows: TreeRow[] = [];
  const bySort = (a: Node, b: Node) => (a.sortKey < b.sortKey ? -1 : a.sortKey > b.sortKey ? 1 : 0);
  const walk = (parentId: string | null, depth: number) => {
    for (const child of store.getChildren(parentId).sort(bySort)) {
      if (!keep.has(child.id)) continue;
      rows.push({ node: child, depth, dimmed: !hits.has(child.id) });
      walk(child.id, depth + 1);
    }
  };
  walk(null, 0);
  return rows;
}
