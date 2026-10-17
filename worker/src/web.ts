/**
 * HTML routes: the second front door on the same Durable Object (DESIGN.md §7a).
 *   GET  /                      the signed-in user's Spaces, and a form to create one
 *   GET  /s/:id                 tree view        } both take the filter query parameters
 *   GET  /s/:id/list            flat list view   } parsed in web-filter.ts
 *   GET  /s/:id/n/:nodeId       one node: fields, labels, attachments, children, history
 *   POST /s/:id/nodes           create a node (parent, title, kind, priority)
 *   POST /s/:id/n/:nodeId/{status,priority,label,archive,restore}
 * Every POST becomes an event pushed through SpaceDO.pushEvents, then a 303 back.
 */
import {
  KINDS, PRIORITIES, STATUSES, query, tree, uuidv7,
  type Event, type EventBody, type Node,
} from "@property-tasks/shared";
import { authenticate, type User } from "./auth.js";
import { html, page, redirect, type Crumb } from "./html.js";
import { listPage, messagePage, nodePage, spacesPage, storeFromSnapshot, titleOf, treePage, type SpaceView } from "./pages.js";
import { createSpace, listSpaces, spaceTitle } from "./spaces.js";
import { parseQuery } from "./web-filter.js";

const DEVICE = "web";

export function isWebPath(pathname: string): boolean {
  return pathname === "/" || pathname.startsWith("/s/");
}

export async function webRoute(request: Request, env: Env, url: URL): Promise<Response> {
  const user = authenticate(request, env);
  if (!user) return page({ title: "Sign in" }, messagePage("Sign in", "No session. Sign-in is not built yet; set DEV_USER for local development."), 401);

  const parts = url.pathname.split("/").filter(Boolean);
  if (parts.length === 0) return home(request, env, user);
  if (parts[0] !== "s" || !parts[1]) return notFound(user);

  const spaceId = parts[1];
  const stub = env.SPACES.getByName(spaceId);
  const member = await stub.getMember(user.id);
  if (!member) return page({ title: "Forbidden", user }, messagePage("Not a member", "You are not a member of this space.", "/"), 403);
  const canWrite = member.role === "owner" || member.role === "editor";
  const rest = parts.slice(2);

  if (request.method === "GET" || request.method === "HEAD") {
    const title = await spaceTitle(env, user, spaceId);
    const view: SpaceView = { id: spaceId, title, store: storeFromSnapshot(await stub.snapshot()), now: Date.now(), canWrite };
    const crumbs: Crumb[] = [{ href: `/s/${spaceId}`, label: title }];
    if (rest.length === 0 || (rest.length === 1 && rest[0] === "list")) {
      const q = parseQuery(url.searchParams);
      const isList = rest[0] === "list";
      const body = isList
        ? listPage(view, q, query(view.store, q.filter, view.now, q.sort), url.search)
        : treePage(view, q, tree(view.store, q.filter, view.now), url.search);
      return page({ title: isList ? `${title} list` : title, crumbs, user }, body);
    }
    if (rest.length === 2 && rest[0] === "n") {
      const node = view.store.getNode(rest[1]!);
      if (!node) return notFound(user);
      const events = await stub.nodeEvents(node.id, 200);
      for (const a of view.store.getAncestors(node.id).reverse()) crumbs.push({ href: `/s/${spaceId}/n/${a.id}`, label: titleOf(a) });
      crumbs.push({ href: `/s/${spaceId}/n/${node.id}`, label: titleOf(node) });
      return page({ title: titleOf(node), crumbs, user }, nodePage(view, node, events));
    }
    return notFound(user);
  }

  if (request.method !== "POST") return new Response("method not allowed", { status: 405, headers: { allow: "GET, POST" } });
  if (!canWrite) return page({ title: "Forbidden", user }, messagePage("Read-only", "Your role in this space cannot make changes.", `/s/${spaceId}`), 403);

  const form = await request.formData();
  const field = (name: string): string => {
    const v = form.get(name);
    return typeof v === "string" ? v.trim() : "";
  };
  const push = async (ev: Event, back: string): Promise<Response> => {
    const result = await stub.pushEvents(user.id, [ev]);
    if (!result.ok) return page({ title: "Rejected", user }, messagePage("Change rejected", result.error, back), 400);
    return redirect(back);
  };
  const event = (nodeId: string, body: EventBody): Event =>
    ({ id: uuidv7(), spaceId, nodeId, actorId: user.id, deviceId: DEVICE, at: Date.now(), ...body });

  if (rest.length === 1 && rest[0] === "nodes") {
    const title = field("title");
    if (!title) return page({ title: "Bad request", user }, messagePage("Missing title", "A title is required.", `/s/${spaceId}`), 400);
    const kind = pick(KINDS, field("kind"), "task");
    const priority = pick(PRIORITIES, field("priority"), "normal");
    const parentId = field("parent") || null;
    if (parentId !== null && !(await stub.getNode(parentId))) return notFound(user);
    const back = parentId ? `/s/${spaceId}/n/${parentId}` : `/s/${spaceId}`;
    return push(event(uuidv7(), { type: "node.created", payload: { parentId, kind, title, priority } }), back);
  }

  if (rest.length === 3 && rest[0] === "n") {
    const node = await stub.getNode(rest[1]!);
    if (!node) return notFound(user);
    const back = `/s/${spaceId}/n/${node.id}`;
    const body = nodeAction(node, rest[2]!, field);
    if (body === "bad") return page({ title: "Bad request", user }, messagePage("Bad request", "That change is not valid for this item.", back), 400);
    if (body === null) return redirect(back); // no-op change
    return push(event(node.id, body), back);
  }
  return notFound(user);
}

/** Translate a form post on a node into the event it means; null when nothing would change. */
function nodeAction(node: Node, action: string, field: (name: string) => string): EventBody | null | "bad" {
  switch (action) {
    case "status": {
      if (node.kind !== "task") return "bad";
      const after = field("status");
      if (!isOneOf(STATUSES, after)) return "bad";
      if (after === node.status) return null;
      return { type: "node.field_changed", payload: { field: "status", before: node.status, after } };
    }
    case "priority": {
      const after = field("priority");
      if (!isOneOf(PRIORITIES, after)) return "bad";
      if (after === node.priority) return null;
      return { type: "node.field_changed", payload: { field: "priority", before: node.priority, after } };
    }
    case "label": {
      const label = field("label");
      if (!label) return "bad";
      return field("op") === "remove" ? { type: "label.removed", payload: { label } } : { type: "label.added", payload: { label } };
    }
    case "archive":
      return node.archivedAt === null ? { type: "node.archived", payload: {} } : null;
    case "restore":
      return node.archivedAt !== null ? { type: "node.restored", payload: {} } : null;
    default:
      return "bad";
  }
}

function isOneOf<T extends string>(list: readonly T[], v: string): v is T {
  return (list as readonly string[]).includes(v);
}
function pick<T extends string>(list: readonly T[], v: string, fallback: T): T {
  return isOneOf(list, v) ? v : fallback;
}

async function home(request: Request, env: Env, user: User): Promise<Response> {
  if (request.method === "POST") {
    const form = await request.formData();
    const created = await createSpace(env, user, form.get("title"));
    if (!created) return page({ title: "Error", user }, messagePage("Could not create the space", "Try again.", "/"), 500);
    return redirect(`/s/${created.id}`);
  }
  const spaces = await listSpaces(env, user);
  return page({ title: "Spaces", user }, spacesPage(spaces, true));
}

function notFound(user: User | null): Response {
  return page({ title: "Not found", user }, html`<h1>Not found</h1><p><a href="/">Spaces</a></p>`, 404);
}
