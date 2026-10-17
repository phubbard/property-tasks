import { SELF } from "cloudflare:test";
import { MemoryStore, replay, serialize, type Event, type StampedEvent } from "@property-tasks/shared";
import { beforeAll, describe, expect, it } from "vitest";

const BASE = "http://test.local";

async function api(path: string, init: RequestInit = {}, user = "paul"): Promise<Response> {
  const headers = new Headers(init.headers);
  headers.set("x-dev-user", user);
  if (init.body && typeof init.body === "string" && !headers.has("content-type")) headers.set("content-type", "application/json");
  return SELF.fetch(BASE + path, { ...init, headers });
}

let n = 0;
function ev(spaceId: string, nodeId: string | null, body: Pick<Event, "type" | "payload">, actor = "paul"): Event {
  n += 1;
  return {
    id: `0199d000-0000-7000-8000-${String(n).padStart(12, "0")}`,
    spaceId, nodeId, actorId: actor, deviceId: `${actor}-test`, at: 1_760_000_000_000 + n * 1000,
    ...body,
  } as Event;
}

async function createSpace(user = "paul"): Promise<string> {
  const res = await api("/api/spaces", { method: "POST", body: JSON.stringify({ title: "Cabin" }) }, user);
  expect(res.status).toBe(201);
  return ((await res.json()) as { id: string }).id;
}

async function pullAll(spaceId: string, user = "paul"): Promise<StampedEvent[]> {
  const res = await api(`/api/spaces/${spaceId}/events?since=0`, {}, user);
  expect(res.status).toBe(200);
  return ((await res.json()) as { events: StampedEvent[] }).events;
}

describe("health and auth", () => {
  it("health is open", async () => {
    const res = await SELF.fetch(`${BASE}/api/health`);
    expect(await res.json()).toEqual({ ok: true });
  });
  it("static asset placeholder is served", async () => {
    const res = await SELF.fetch(`${BASE}/`);
    expect(res.status).toBe(200);
    expect(await res.text()).toContain("Property Tasks");
  });
});

describe("spaces", () => {
  let spaceId: string;
  beforeAll(async () => {
    spaceId = await createSpace();
  });

  it("creation records the owner and lists the space", async () => {
    const list = (await (await api("/api/spaces")).json()) as { spaces: Array<{ id: string; role: string }> };
    expect(list.spaces.some((s) => s.id === spaceId && s.role === "owner")).toBe(true);
    const events = await pullAll(spaceId);
    expect(events.map((e) => e.type)).toEqual(["member.joined"]);
    expect(events[0]!.seq).toBe(1);
  });

  it("push then pull round-trips, and a retry is idempotent", async () => {
    const batch = [
      ev(spaceId, "cabin", { type: "node.created", payload: { parentId: null, kind: "container", title: "Cabin", sortKey: "a" } }),
      ev(spaceId, "ac", { type: "node.created", payload: { parentId: "cabin", kind: "task", title: "AC failed", priority: "high" } }),
      ev(spaceId, "ac", { type: "label.added", payload: { label: "Repair" } }),
    ];
    const res1 = await api(`/api/spaces/${spaceId}/events`, { method: "POST", body: JSON.stringify({ events: batch }) });
    expect(res1.status).toBe(200);
    const r1 = (await res1.json()) as { ok: true; seqs: Record<string, number> };
    expect(Object.values(r1.seqs)).toEqual([2, 3, 4]);

    const res2 = await api(`/api/spaces/${spaceId}/events`, { method: "POST", body: JSON.stringify({ events: batch }) });
    const r2 = (await res2.json()) as { ok: true; seqs: Record<string, number> };
    expect(r2.seqs).toEqual(r1.seqs);

    const all = await pullAll(spaceId);
    expect(all).toHaveLength(4);
    expect(all.map((e) => e.seq)).toEqual([1, 2, 3, 4]);
    expect(all[3]!.receivedAt).toBeGreaterThan(0);

    const page = (await (await api(`/api/spaces/${spaceId}/events?since=2&limit=1`)).json()) as { events: StampedEvent[]; nextSeq: number; hasMore: boolean };
    expect(page.events.map((e) => e.seq)).toEqual([3]);
    expect(page).toMatchObject({ nextSeq: 3, hasMore: true });
  });

  it("snapshot equals a replay of the log through the shared projection", async () => {
    const events = await pullAll(spaceId);
    const mem = new MemoryStore();
    replay(mem, events);
    const snap = (await (await api(`/api/spaces/${spaceId}/snapshot`)).json()) as Record<string, unknown>;
    expect(snap.spaceId).toBe(spaceId);
    expect(snap.seq).toBe(events[events.length - 1]!.seq);
    const { spaceId: _s, seq: _q, ...projection } = snap;
    expect(projection).toEqual(serialize(mem));
  });

  it("rejects a bad batch atomically", async () => {
    const before = (await pullAll(spaceId)).length;
    const batch = [
      ev(spaceId, "shed", { type: "node.created", payload: { parentId: "cabin", kind: "container", title: "Shed" } }),
      ev(spaceId, "cabin", { type: "node.moved", payload: { fromParentId: null, toParentId: "ac" } }),
    ];
    const res = await api(`/api/spaces/${spaceId}/events`, { method: "POST", body: JSON.stringify({ events: batch }) });
    expect(res.status).toBe(409);
    const body = (await res.json()) as { ok: false; error: string; eventId: string };
    expect(body.eventId).toBe(batch[1]!.id);
    expect(body.error).toMatch(/descendant/);
    expect((await pullAll(spaceId)).length).toBe(before);
    const snap = (await (await api(`/api/spaces/${spaceId}/snapshot`)).json()) as { nodes: Array<{ id: string }> };
    expect(snap.nodes.some((nd) => nd.id === "shed")).toBe(false);
  });

  it("refuses non-members and read-only members", async () => {
    expect((await api(`/api/spaces/${spaceId}/snapshot`, {}, "stranger")).status).toBe(403);
    const join = ev(spaceId, null, { type: "member.joined", payload: { userId: "wife", role: "viewer", displayName: "Wife" } });
    expect((await api(`/api/spaces/${spaceId}/events`, { method: "POST", body: JSON.stringify({ events: [join] }) })).status).toBe(200);
    expect((await api(`/api/spaces/${spaceId}/snapshot`, {}, "wife")).status).toBe(200);
    const write = ev(spaceId, "cabin", { type: "label.added", payload: { label: "Location" } }, "wife");
    expect((await api(`/api/spaces/${spaceId}/events`, { method: "POST", body: JSON.stringify({ events: [write] }) }, "wife")).status).toBe(403);
    const spoof = ev(spaceId, "cabin", { type: "label.added", payload: { label: "Location" } }, "paul");
    const res = await api(`/api/spaces/${spaceId}/events`, { method: "POST", body: JSON.stringify({ events: [spoof] }) }, "wife");
    expect(res.status).toBe(403);
  });

  it("stores and serves a blob verified by sha256", async () => {
    const bytes = new TextEncoder().encode("not really a jpeg");
    const sha = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map((b) => b.toString(16).padStart(2, "0")).join("");
    const put = await api(`/api/spaces/${spaceId}/blobs/${sha}`, { method: "PUT", body: bytes, headers: { "content-type": "image/jpeg" } });
    expect(put.status).toBe(201);
    const get = await api(`/api/spaces/${spaceId}/blobs/${sha}`);
    expect(get.status).toBe(200);
    expect(get.headers.get("content-type")).toBe("image/jpeg");
    expect(get.headers.get("cache-control")).toContain("immutable");
    expect(new TextDecoder().decode(await get.arrayBuffer())).toBe("not really a jpeg");

    const wrong = "00".repeat(32);
    const bad = await api(`/api/spaces/${spaceId}/blobs/${wrong}`, { method: "PUT", body: bytes });
    expect(bad.status).toBe(400);
    expect((await api(`/api/spaces/${spaceId}/blobs/${wrong}`)).status).toBe(404);
    expect((await api(`/api/spaces/${spaceId}/blobs/nothex`)).status).toBe(400);
  });
});
