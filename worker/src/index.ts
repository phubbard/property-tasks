import type { Event } from "@property-tasks/shared";
import { authenticate, type User } from "./auth.js";
import { getBlob, putBlob, validBlobPath } from "./blobs.js";
import { createSpace, listSpaces } from "./spaces.js";
import { isWebPath, webRoute } from "./web.js";

export { SpaceDO } from "./space-do.js";

const json = (body: unknown, status = 200): Response => Response.json(body, { status });

function log(level: "info" | "warn" | "error", message: string, data?: Record<string, unknown>): void {
  console.log(JSON.stringify({ level, message, timestamp: new Date().toISOString(), ...data }));
}

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url);
    const isApi = url.pathname.startsWith("/api/");
    if (!isApi && !isWebPath(url.pathname)) {
      // Static assets are served before the Worker runs; anything left is a 404 from the assets binding.
      return env.ASSETS.fetch(request);
    }
    try {
      return isApi ? await route(request, env, url) : await webRoute(request, env, url);
    } catch (e) {
      log("error", "request failed", { path: url.pathname, method: request.method, error: String(e) });
      return isApi
        ? json({ error: "internal error" }, 500)
        : new Response("Something went wrong.", { status: 500, headers: { "content-type": "text/plain; charset=utf-8" } });
    }
  },
} satisfies ExportedHandler<Env>;

async function route(request: Request, env: Env, url: URL): Promise<Response> {
  const parts = url.pathname.split("/").filter(Boolean); // ["api", ...]
  if (parts[1] === "health") return json({ ok: true });

  const user = authenticate(request, env);
  if (!user) return json({ error: "unauthenticated" }, 401);

  if (parts[1] !== "spaces") return json({ error: "not found" }, 404);

  // /api/spaces
  if (parts.length === 2) {
    if (request.method === "POST") {
      const body = (await request.json().catch(() => ({}))) as { title?: unknown };
      const created = await createSpace(env, user, body.title);
      return created ? json(created, 201) : json({ error: "space id collision" }, 500);
    }
    if (request.method === "GET") return json({ spaces: await listSpaces(env, user) });
    return json({ error: "method not allowed" }, 405);
  }

  const spaceId = parts[2]!;
  const stub = env.SPACES.getByName(spaceId);
  const member = await stub.getMember(user.id);
  if (!member) return json({ error: "not a member" }, 403);
  const canWrite = member.role === "owner" || member.role === "editor";

  const resource = parts[3];
  switch (resource) {
    case "events": {
      if (request.method === "GET") {
        const since = Number(url.searchParams.get("since") ?? "0");
        const limit = Math.min(Number(url.searchParams.get("limit") ?? "500"), 1000);
        return json(await stub.pullEvents(Number.isFinite(since) ? since : 0, limit));
      }
      if (request.method === "POST") {
        if (!canWrite) return json({ error: "read-only member" }, 403);
        const body = (await request.json()) as { events?: unknown };
        if (!Array.isArray(body.events) || !body.events.every(isEventShaped)) {
          return json({ error: "events must be an array of events" }, 400);
        }
        const result = await stub.pushEvents(user.id, body.events as Event[]);
        return result.ok ? json(result) : json(result, 409);
      }
      return json({ error: "method not allowed" }, 405);
    }
    case "snapshot":
      return json(await stub.snapshot());
    case "ws": {
      if (request.headers.get("Upgrade") !== "websocket") return json({ error: "expected websocket upgrade" }, 426);
      const headers = new Headers(request.headers);
      headers.set("x-user-id", user.id);
      headers.set("x-device-id", url.searchParams.get("device") ?? "unknown");
      return stub.fetch(new Request(request, { headers }));
    }
    case "blobs": {
      const sha = parts[4] ?? "";
      const variant = parts[5] ?? null;
      if (!validBlobPath(sha, variant)) return json({ error: "bad blob path" }, 400);
      if (request.method === "PUT") {
        if (!canWrite) return json({ error: "read-only member" }, 403);
        return putBlob(request, env, spaceId, sha, variant, user);
      }
      if (request.method === "GET") return getBlob(env, spaceId, sha, variant);
      return json({ error: "method not allowed" }, 405);
    }
    default:
      return json({ error: "not found" }, 404);
  }
}

function isEventShaped(e: unknown): e is Event {
  if (typeof e !== "object" || e === null) return false;
  const o = e as Record<string, unknown>;
  return typeof o.id === "string" && typeof o.spaceId === "string" && typeof o.actorId === "string"
    && typeof o.deviceId === "string" && typeof o.at === "number" && typeof o.type === "string"
    && typeof o.payload === "object" && o.payload !== null && (o.nodeId === null || typeof o.nodeId === "string");
}
