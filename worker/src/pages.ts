/**
 * Page renderers for the server-rendered web app (DESIGN.md §4, §7a).
 * Each function returns the <main> body; `layout()` in html.ts wraps it.
 */
import {
  KINDS, MemoryStore, PRIORITIES, STATUSES,
  type Attachment, type Node, type Serialized, type StampedEvent, type TreeRow,
} from "@property-tasks/shared";
import { html, raw, relativeTime, type Html } from "./html.js";
import { filterBar, type ParsedQuery } from "./web-filter.js";

export interface SpaceView {
  id: string;
  title: string;
  store: MemoryStore;
  now: number;
  canWrite: boolean;
}

/** Rebuild an in-memory projection from a Durable Object snapshot so the shared tree()/query() can run over it. */
export function storeFromSnapshot(s: Serialized): MemoryStore {
  const m = new MemoryStore();
  for (const n of s.nodes) m.putNode(n);
  for (const [nodeId, labels] of Object.entries(s.labels)) for (const l of labels) m.addLabel(nodeId, l);
  for (const a of s.attachments) m.putAttachment(a);
  for (const mem of s.members) m.putMember(mem);
  return m;
}

const pretty = (s: string): string => s.replace(/_/g, " ");
const nodeHref = (v: SpaceView, id: string): string => `/s/${v.id}/n/${id}`;

/** Notes may have no title; fall back to the first line of the body. */
export function titleOf(node: Node): string {
  if (node.title) return node.title;
  const line = (node.body ?? "").split("\n").find((l) => l.trim());
  return line ? line.trim().slice(0, 80) : `(${node.kind})`;
}

/** "Cabin › Main house › Bathroom": ancestors root-first, excluding the node. */
export function pathOf(store: MemoryStore, node: Node): string {
  return store.getAncestors(node.id).reverse().map(titleOf).join(" › ");
}

function liveAttachments(store: MemoryStore, nodeId: string): Attachment[] {
  return store.getAttachmentsForNode(nodeId).filter((a) => a.removedAt === null);
}

function memberName(v: SpaceView, userId: string): string {
  return v.store.getMember(userId)?.displayName ?? userId;
}

function badges(v: SpaceView, node: Node): Html {
  const atts = liveAttachments(v.store, node.id).length;
  return html`<span class="meta">${node.priority === "none" ? "" : html`<span class="pri pri-${node.priority}">${node.priority}</span>`}${node.status ? html`<span class="st st-${node.status}">${pretty(node.status)}</span>` : ""}${atts > 0 ? html`<span class="att">${atts} ${atts === 1 ? "file" : "files"}</span>` : ""}${node.archivedAt !== null ? html`<span class="muted">archived</span>` : ""}${relativeTime(node.lastEventAt, v.now)}</span>`;
}

function treeRow(v: SpaceView, r: TreeRow): Html {
  return html`<li class="row k-${r.node.kind}${r.dimmed ? " dim" : ""}" data-depth="${r.depth}" style="--depth:${r.depth}"><a href="${nodeHref(v, r.node.id)}">${titleOf(r.node)}</a> ${badges(v, r.node)}</li>`;
}

function listRow(v: SpaceView, node: Node): Html {
  const path = pathOf(v.store, node);
  return html`<li class="row k-${node.kind}"><a href="${nodeHref(v, node.id)}">${titleOf(node)}</a> ${badges(v, node)}${path ? html`<span class="path muted">${path}</span>` : ""}</li>`;
}

function viewNav(v: SpaceView, current: "tree" | "list", search: string): Html {
  const link = (href: string, label: string, on: boolean) =>
    on ? html`<a href="${href}" aria-current="page">${label}</a>` : html`<a href="${href}">${label}</a>`;
  return html`<nav class="views" aria-label="View">${link(`/s/${v.id}${search}`, "Tree", current === "tree")} ${link(`/s/${v.id}/list${search}`, "List", current === "list")}</nav>`;
}

function containersFor(v: SpaceView): Array<{ node: Node; path: string }> {
  return v.store.allNodes()
    .filter((n) => n.kind === "container" && n.archivedAt === null)
    .map((node) => ({ node, path: [pathOf(v.store, node), titleOf(node)].filter(Boolean).join(" › ") }))
    .sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
}

function labelsFor(v: SpaceView): string[] {
  return [...new Set(v.store.allLabels().map((l) => l.label))].sort();
}

function select(name: string, options: readonly string[], chosen: string): Html {
  return html`<select name="${name}" aria-label="${name}">${options.map((o) =>
    html`<option value="${o}"${o === chosen ? raw(" selected") : ""}>${pretty(o)}</option>`)}</select>`;
}

/** The create form. parentId null creates at the root. */
function createForm(v: SpaceView, parentId: string | null): Html {
  if (!v.canWrite) return html``;
  return html`<details class="new"><summary>New item</summary>
<form method="post" action="/s/${v.id}/nodes">
<input type="hidden" name="parent" value="${parentId ?? ""}">
<p><label for="new-title">Title</label> <input name="title" id="new-title" required autocomplete="off"></p>
<p><label for="new-kind">Kind</label> ${select("kind", KINDS, "task")} <label for="new-priority">Priority</label> ${select("priority", PRIORITIES, "normal")} <button type="submit">Create</button></p>
</form></details>`;
}

function spaceHeader(v: SpaceView, current: "tree" | "list", search: string): Html {
  return html`<h1>${v.title}</h1>${viewNav(v, current, search)}`;
}

export function spacesPage(spaces: Array<{ id: string; title: string; role: string }>, canCreate: boolean): Html {
  return html`<h1>Spaces</h1>
${spaces.length === 0 ? html`<p class="muted">No spaces yet.</p>` : html`<ul class="spaces">${spaces.map((s) =>
    html`<li><a href="/s/${s.id}">${s.title}</a> <span class="muted">${s.role}</span></li>`)}</ul>`}
${canCreate ? html`<form method="post" action="/" class="inline-form">
<label for="space-title">New space</label> <input name="title" id="space-title" required placeholder="Cabin"> <button type="submit">Create</button>
</form>` : ""}`;
}

export function treePage(v: SpaceView, q: ParsedQuery, rows: TreeRow[], search: string): Html {
  return html`${spaceHeader(v, "tree", search)}
${filterBar(`/s/${v.id}`, q, containersFor(v), labelsFor(v), false)}
${rows.length === 0 ? html`<p class="muted">Nothing matches.</p>` : html`<ol class="tree">${rows.map((r) => treeRow(v, r))}</ol>`}
${createForm(v, null)}`;
}

export function listPage(v: SpaceView, q: ParsedQuery, nodes: Node[], search: string): Html {
  return html`${spaceHeader(v, "list", search)}
${filterBar(`/s/${v.id}/list`, q, containersFor(v), labelsFor(v), true)}
<p class="muted count">${nodes.length} ${nodes.length === 1 ? "item" : "items"}</p>
${nodes.length === 0 ? "" : html`<ol class="rows">${nodes.map((n) => listRow(v, n))}</ol>`}`;
}

function attachmentItem(v: SpaceView, a: Attachment): Html {
  const alt = a.caption || a.filename;
  if (a.kind === "link" && a.url) return html`<li><a href="${a.url}" rel="noopener">${alt}</a></li>`;
  if (!a.sha256) return html`<li>${alt}</li>`;
  const original = `/api/spaces/${v.id}/blobs/${a.sha256}`;
  if (a.kind === "image" || a.kind === "video") {
    return html`<li><a href="${original}"><img src="${original}/thumb" alt="${alt}" loading="lazy"></a>${a.caption ? html`<span class="caption">${a.caption}</span>` : ""}</li>`;
  }
  return html`<li><a href="${original}">${alt}</a> <span class="muted">${a.kind}</span></li>`;
}

function describe(v: SpaceView, ev: StampedEvent): Html {
  switch (ev.type) {
    case "node.created": return html`created ${ev.payload.kind} “${ev.payload.title || "(untitled)"}”`;
    case "node.field_changed": {
      const p = ev.payload;
      const show = (x: unknown) => (x === null || x === "" ? "none" : pretty(String(x)));
      return html`changed ${p.field === "dueAt" ? "due date" : p.field === "assigneeId" ? "assignee" : p.field} from ${show(p.before)} to ${show(p.after)}`;
    }
    case "node.moved": {
      const to = ev.payload.toParentId ? v.store.getNode(ev.payload.toParentId) : null;
      return html`moved under ${to ? html`<a href="${nodeHref(v, to.id)}">${titleOf(to)}</a>` : "the root"}`;
    }
    case "node.archived": return html`archived`;
    case "node.restored": return html`restored`;
    case "label.added": return html`added label ${ev.payload.label}`;
    case "label.removed": return html`removed label ${ev.payload.label}`;
    case "attachment.added": return html`added ${ev.payload.attachment.kind} ${ev.payload.attachment.filename}`;
    case "attachment.removed": return html`removed ${v.store.getAttachment(ev.payload.attachmentId)?.filename ?? "an attachment"}`;
    case "attachment.captioned": return html`captioned ${v.store.getAttachment(ev.payload.attachmentId)?.filename ?? "an attachment"}: “${ev.payload.caption}”`;
    case "note.edited": return html`edited the note`;
    case "member.joined": return html`joined as ${ev.payload.role}`;
    case "member.role_changed": return html`changed role to ${ev.payload.role}`;
  }
}

function actionForm(action: string, inner: Html, cls = "inline-form"): Html {
  return html`<form method="post" action="${action}" class="${cls}">${inner}</form>`;
}

export function nodePage(v: SpaceView, node: Node, events: StampedEvent[]): Html {
  const labels = v.store.getLabels(node.id);
  const attachments = liveAttachments(v.store, node.id);
  const children = v.store.getChildren(node.id).sort((a, b) => (a.sortKey < b.sortKey ? -1 : a.sortKey > b.sortKey ? 1 : 0));
  const base = nodeHref(v, node.id);
  const w = v.canWrite;

  const actions = !w ? html`` : html`<section class="actions" aria-label="Actions">
${node.kind === "task" ? actionForm(`${base}/status`, html`<label>Status ${select("status", STATUSES, node.status ?? "open")}</label> <button type="submit">Set</button>`) : ""}
${actionForm(`${base}/priority`, html`<label>Priority ${select("priority", PRIORITIES, node.priority)}</label> <button type="submit">Set</button>`)}
${actionForm(`${base}/label`, html`<label>Label <input name="label" list="labels" required autocomplete="off" size="12"></label><datalist id="labels">${labelsFor(v).map((l) => html`<option value="${l}">`)}</datalist> <button type="submit">Add</button>`)}
${node.archivedAt === null
    ? actionForm(`${base}/archive`, html`<button type="submit">Archive</button>`)
    : actionForm(`${base}/restore`, html`<button type="submit">Restore</button>`)}
</section>`;

  return html`<h1 class="k-${node.kind}">${titleOf(node)}</h1>
<p class="meta facts"><span>${node.kind}</span>${node.status ? html`<span class="st st-${node.status}">${pretty(node.status)}</span>` : ""}${node.priority === "none" ? "" : html`<span class="pri pri-${node.priority}">${node.priority}</span>`}${node.dueAt !== null ? html`<span>due ${new Date(node.dueAt).toISOString().slice(0, 10)}</span>` : ""}${node.assigneeId ? html`<span>assigned to ${memberName(v, node.assigneeId)}</span>` : ""}${node.archivedAt !== null ? html`<span class="muted">archived ${relativeTime(node.archivedAt, v.now)}</span>` : ""}</p>
<p class="meta muted">created by ${memberName(v, node.createdBy)} ${relativeTime(node.createdAt, v.now)} · last activity by ${memberName(v, node.lastEventBy)} ${relativeTime(node.lastEventAt, v.now)}</p>
${labels.length > 0 ? html`<ul class="labels" aria-label="Labels">${labels.map((l) =>
    html`<li><a href="/s/${v.id}/list?label=${encodeURIComponent(l)}">${l}</a>${w ? actionForm(`${base}/label`, html`<input type="hidden" name="label" value="${l}"><input type="hidden" name="op" value="remove"><button type="submit" aria-label="Remove label ${l}">×</button>`, "x") : ""}</li>`)}</ul>` : ""}
${node.kind === "note" && node.body ? html`<p class="body">${node.body}</p>` : ""}
${actions}
${attachments.length > 0 ? html`<section aria-labelledby="h-att"><h2 id="h-att">Attachments <span class="muted">${attachments.length}</span></h2><ul class="thumbs">${attachments.map((a) => attachmentItem(v, a))}</ul></section>` : ""}
<section aria-labelledby="h-children"><h2 id="h-children">Children <span class="muted">${children.length}</span></h2>
${children.length > 0 ? html`<ol class="rows">${children.map((c) => listRowNoPath(v, c))}</ol>` : ""}
${createForm(v, node.id)}</section>
<section aria-labelledby="h-history"><h2 id="h-history">History</h2>
<ol class="history">${events.map((ev) => html`<li><b>${memberName(v, ev.actorId)}</b> ${describe(v, ev)} ${relativeTime(ev.at, v.now)}</li>`)}</ol></section>`;
}

function listRowNoPath(v: SpaceView, node: Node): Html {
  return html`<li class="row k-${node.kind}"><a href="${nodeHref(v, node.id)}">${titleOf(node)}</a> ${badges(v, node)}</li>`;
}

export function messagePage(heading: string, text: string, back?: string): Html {
  return html`<h1>${heading}</h1><p>${text}</p>${back ? html`<p><a href="${back}">Back</a></p>` : ""}`;
}
