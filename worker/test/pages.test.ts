import { SELF } from "cloudflare:test";
import type { Event, StampedEvent } from "@property-tasks/shared";
import { beforeAll, describe, expect, it } from "vitest";

const BASE = "http://test.local";

async function get(path: string, user = "paul"): Promise<Response> {
  return SELF.fetch(BASE + path, { headers: { "x-dev-user": user } });
}
async function post(path: string, fields: Record<string, string>, user = "paul"): Promise<Response> {
  return SELF.fetch(BASE + path, {
    method: "POST",
    redirect: "manual",
    headers: { "x-dev-user": user, "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(fields).toString(),
  });
}
async function api(path: string, init: RequestInit = {}, user = "paul"): Promise<Response> {
  const headers = new Headers(init.headers);
  headers.set("x-dev-user", user);
  headers.set("content-type", "application/json");
  return SELF.fetch(BASE + path, { ...init, headers });
}

let n = 0;
function ev(spaceId: string, nodeId: string | null, body: Pick<Event, "type" | "payload">, actor = "paul"): Event {
  n += 1;
  return {
    id: `0199d100-0000-7000-8000-${String(n).padStart(12, "0")}`,
    spaceId, nodeId, actorId: actor, deviceId: `${actor}-test`, at: Date.now() - (100 - n) * 60_000,
    ...body,
  } as Event;
}

/** The create-tree fixture shape: Cabin › Main house › Bathroom › AC failed (high, Repair, one photo, in progress) + a note. */
async function seedSpace(): Promise<string> {
  const res = await api("/api/spaces", { method: "POST", body: JSON.stringify({ title: "Cabin" }) });
  expect(res.status).toBe(201);
  const spaceId = ((await res.json()) as { id: string }).id;
  const batch = [
    ev(spaceId, "cabin", { type: "node.created", payload: { parentId: null, kind: "container", title: "Cabin", sortKey: "a" } }),
    ev(spaceId, "house", { type: "node.created", payload: { parentId: "cabin", kind: "container", title: "Main house", sortKey: "a" } }),
    ev(spaceId, "bath", { type: "node.created", payload: { parentId: "house", kind: "container", title: "Bathroom", sortKey: "b" } }),
    ev(spaceId, "ac", { type: "node.created", payload: { parentId: "bath", kind: "task", title: "AC failed", priority: "high", sortKey: "a" } }),
    ev(spaceId, "ac", { type: "label.added", payload: { label: "Repair" } }),
    ev(spaceId, "ac", {
      type: "attachment.added",
      payload: {
        attachment: {
          id: "att-1", kind: "image", mime: "image/jpeg", filename: "IMG_2231.jpg", byteSize: 3_200_000,
          sha256: "ab".repeat(32), url: null, width: 4032, height: 3024, durationMs: null, caption: "", sortKey: "a", capture: null,
        },
      },
    }),
    ev(spaceId, "ac-note", { type: "node.created", payload: { parentId: "ac", kind: "note", title: "", body: "Error code P6 on the display", sortKey: "a" } }),
    ev(spaceId, "ac", { type: "node.field_changed", payload: { field: "status", before: "open", after: "in_progress" } }),
    ev(spaceId, "gutter", { type: "node.created", payload: { parentId: "cabin", kind: "task", title: "Clean gutters <b>", priority: "low", sortKey: "z" } }),
    ev(spaceId, "gutter", { type: "node.field_changed", payload: { field: "status", before: "open", after: "done" } }),
    ev(spaceId, null, { type: "member.joined", payload: { userId: "wife", role: "viewer", displayName: "Wife" } }),
  ];
  const push = await api(`/api/spaces/${spaceId}/events`, { method: "POST", body: JSON.stringify({ events: batch }) });
  expect(push.status).toBe(200);
  return spaceId;
}

/** Row ids in document order, from the data-depth attribute and the node link. */
function rows(html: string): Array<{ id: string; depth: number | null; dimmed: boolean }> {
  const out: Array<{ id: string; depth: number | null; dimmed: boolean }> = [];
  const re = /<li class="row([^"]*)"(?: data-depth="(\d+)")?[^>]*><a href="\/s\/[^/]+\/n\/([^"]+)"/g;
  for (const m of html.matchAll(re)) out.push({ id: m[3]!, depth: m[2] === undefined ? null : Number(m[2]), dimmed: m[1]!.includes(" dim") });
  return out;
}

describe("pages", () => {
  let spaceId: string;
  beforeAll(async () => {
    spaceId = await seedSpace();
  });

  it("home lists the user's spaces with a create form, and creates one from a form post", async () => {
    const res = await get("/");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/html");
    const html = await res.text();
    expect(html).toContain(`<a href="/s/${spaceId}">Cabin</a>`);
    expect(html).toContain('<form method="post" action="/"');
    expect(html).toContain('<link rel="manifest" href="/manifest.webmanifest">');
    expect(html).toContain("serviceWorker");

    const created = await post("/", { title: "Boat" });
    expect(created.status).toBe(303);
    const loc = created.headers.get("location")!;
    expect(loc).toMatch(/^\/s\/[0-9a-f-]{36}$/);
    expect(await (await get(loc)).text()).toContain("<h1>Boat</h1>");
  });

  it("tree page renders the seeded space with depth and default statuses", async () => {
    const res = await get(`/s/${spaceId}`);
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain("<h1>Cabin</h1>");
    // Default filter hides the done task but keeps containers, the in-progress task and the note.
    expect(rows(html)).toEqual([
      { id: "cabin", depth: 0, dimmed: false },
      { id: "house", depth: 1, dimmed: false },
      { id: "bath", depth: 2, dimmed: false },
      { id: "ac", depth: 3, dimmed: false },
      { id: "ac-note", depth: 4, dimmed: false },
    ]);
    expect(html).toContain('<span class="pri pri-high">high</span>');
    expect(html).toContain('<span class="st st-in_progress">in progress</span>');
    expect(html).toContain('<span class="att">1 file</span>');
    expect(html).toMatch(/<time datetime="[^"]+" title="[^"]+">\d+[mh] ago<\/time>/);
    expect(html).toContain('<main>');
    expect(html).toContain('<nav aria-label="Breadcrumb"');
    const bytes = new TextEncoder().encode(html).length;
    console.log(`tree page for the seeded space: ${bytes} bytes`);
    expect(bytes).toBeLessThan(12_000);
  });

  it("query parameters narrow the tree and dim non-matching ancestors", async () => {
    const html = await (await get(`/s/${spaceId}?kind=task`)).text();
    expect(rows(html)).toEqual([
      { id: "cabin", depth: 0, dimmed: true },
      { id: "house", depth: 1, dimmed: true },
      { id: "bath", depth: 2, dimmed: true },
      { id: "ac", depth: 3, dimmed: false },
    ]);
    // The filter bar mirrors the URL.
    expect(html).toContain('<input type="checkbox" name="kind" value="task" checked>');
    expect(html).toContain('<details class="filters" open>');
    // status=any brings the done task back.
    const any = await (await get(`/s/${spaceId}?status=any`)).text();
    expect(rows(any).map((r) => r.id)).toContain("gutter");
    expect(any).toContain("Clean gutters &lt;b&gt;");
  });

  it("list page shows breadcrumb paths and honours filters and sort", async () => {
    const html = await (await get(`/s/${spaceId}/list?priorityMin=high`)).text();
    expect(rows(html).map((r) => r.id)).toEqual(["ac"]);
    expect(html).toContain('<span class="path muted">Cabin › Main house › Bathroom</span>');
    expect(html).toContain('<option value="high" selected>high</option>');

    const text = await (await get(`/s/${spaceId}/list?text=p6&status=any`)).text();
    expect(rows(text).map((r) => r.id)).toEqual(["ac-note"]);

    const under = await (await get(`/s/${spaceId}/list?under=house&status=any&sort=tree`)).text();
    expect(rows(under).map((r) => r.id)).toEqual(["bath", "ac", "ac-note"]);
    expect(under).toContain(`<option value="house" selected>Cabin › Main house</option>`);

    const label = await (await get(`/s/${spaceId}/list?label=Repair&has=photos`)).text();
    expect(rows(label).map((r) => r.id)).toEqual(["ac"]);
    expect(label).toContain('value="Repair"');
  });

  it("node page shows fields, labels, thumbnail, children and history newest first", async () => {
    const res = await get(`/s/${spaceId}/n/ac`);
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain('<h1 class="k-task">AC failed</h1>');
    expect(html).toContain(`<a href="/s/${spaceId}/n/bath">Bathroom</a>`);
    expect(html).toContain(">Repair</a>");
    expect(html).toContain(`<img src="/api/spaces/${spaceId}/blobs/${"ab".repeat(32)}/thumb" alt="IMG_2231.jpg"`);
    expect(html).toContain(`<a href="/s/${spaceId}/n/ac-note">Error code P6 on the display</a>`);
    const history = html.slice(html.indexOf('<ol class="history">'));
    const items = [...history.matchAll(/<li><b>([^<]+)<\/b> ([^<]+)/g)].map((m) => `${m[1]} ${m[2]!.trim()}`);
    expect(items).toEqual([
      "paul changed status from open to in progress",
      "paul added image IMG_2231.jpg",
      "paul added label Repair",
      "paul created task “AC failed”",
    ]);
    expect((await get(`/s/${spaceId}/n/nope`)).status).toBe(404);
  });

  it("a status-change form post appends an event and redirects back", async () => {
    const res = await post(`/s/${spaceId}/n/ac/status`, { status: "done" });
    expect(res.status).toBe(303);
    expect(res.headers.get("location")).toBe(`/s/${spaceId}/n/ac`);
    const events = ((await (await api(`/api/spaces/${spaceId}/events?since=0`)).json()) as { events: StampedEvent[] }).events;
    const last = events[events.length - 1]!;
    expect(last).toMatchObject({
      type: "node.field_changed", nodeId: "ac", actorId: "paul", deviceId: "web",
      payload: { field: "status", before: "in_progress", after: "done" },
    });
    expect(last.id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
    expect(await (await get(`/s/${spaceId}/n/ac`)).text()).toContain('<span class="st st-done">done</span>');

    // The same value again is a no-op: redirect, no event.
    expect((await post(`/s/${spaceId}/n/ac/status`, { status: "done" })).status).toBe(303);
    const again = ((await (await api(`/api/spaces/${spaceId}/events?since=0`)).json()) as { events: StampedEvent[] }).events;
    expect(again.length).toBe(events.length);
    expect((await post(`/s/${spaceId}/n/ac/status`, { status: "bogus" })).status).toBe(400);
  });

  it("other forms: create child, priority, label add/remove, archive and restore", async () => {
    const created = await post(`/s/${spaceId}/nodes`, { parent: "bath", title: "Replace fan", kind: "task", priority: "urgent" });
    expect(created.status).toBe(303);
    expect(created.headers.get("location")).toBe(`/s/${spaceId}/n/bath`);
    const bath = await (await get(`/s/${spaceId}/n/bath`)).text();
    expect(bath).toContain(">Replace fan</a>");
    expect(bath).toContain('<span class="pri pri-urgent">urgent</span>');

    expect((await post(`/s/${spaceId}/n/ac/priority`, { priority: "urgent" })).status).toBe(303);
    expect((await post(`/s/${spaceId}/n/ac/label`, { label: "Inspection" })).status).toBe(303);
    expect((await post(`/s/${spaceId}/n/ac/label`, { label: "Repair", op: "remove" })).status).toBe(303);
    expect((await post(`/s/${spaceId}/n/ac/archive`, {})).status).toBe(303);
    let ac = await (await get(`/s/${spaceId}/n/ac`)).text();
    expect(ac).toContain('pri-urgent');
    expect(ac).toContain(">Inspection</a>");
    expect(ac).not.toContain(">Repair</a>");
    expect(ac).toContain("<button type=\"submit\">Restore</button>");
    // Archived nodes leave the list; in the tree the archived task survives only as a dimmed ancestor of its live note.
    expect(rows(await (await get(`/s/${spaceId}/list?status=any`)).text()).map((r) => r.id)).not.toContain("ac");
    expect(rows(await (await get(`/s/${spaceId}?status=any`)).text()).find((r) => r.id === "ac")?.dimmed).toBe(true);
    expect(rows(await (await get(`/s/${spaceId}?status=any&archived=1`)).text()).find((r) => r.id === "ac")?.dimmed).toBe(false);

    expect((await post(`/s/${spaceId}/n/ac/restore`, {})).status).toBe(303);
    ac = await (await get(`/s/${spaceId}/n/ac`)).text();
    expect(ac).toContain("<button type=\"submit\">Archive</button>");
  });

  it("non-members get 403 and viewers cannot post", async () => {
    expect((await get(`/s/${spaceId}`, "stranger")).status).toBe(403);
    expect((await get(`/s/${spaceId}/list`, "stranger")).status).toBe(403);
    expect((await get(`/s/${spaceId}/n/ac`, "stranger")).status).toBe(403);
    expect((await post(`/s/${spaceId}/n/ac/status`, { status: "open" }, "stranger")).status).toBe(403);
    expect((await get(`/s/${spaceId}`, "wife")).status).toBe(200);
    const viewer = await (await get(`/s/${spaceId}/n/ac`, "wife")).text();
    expect(viewer).not.toContain('<section class="actions"');
    expect((await post(`/s/${spaceId}/n/ac/status`, { status: "open" }, "wife")).status).toBe(403);
  });

  it("serves the service worker and shell assets", async () => {
    const sw = await SELF.fetch(`${BASE}/sw.js`);
    expect(sw.status).toBe(200);
    expect(await sw.text()).toContain("pages-v1");
    expect((await SELF.fetch(`${BASE}/app.css`)).status).toBe(200);
  });
});
