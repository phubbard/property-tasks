import { describe, expect, it } from "vitest";
import { MemoryStore, ProjectionError, applyEvent, replay, type Event } from "../src/index.js";
import { cases } from "../scripts/fixture-cases.js";

const byName = (n: string) => cases.find((c) => c.name === n)!.events;

function load(name: string): MemoryStore {
  const s = new MemoryStore();
  replay(s, byName(name));
  return s;
}

describe("create-tree", () => {
  const s = load("create-tree");
  it("builds the hierarchy", () => {
    expect(s.getAncestors("ac").map((n) => n.id)).toEqual(["bath", "house", "cabin"]);
    expect(s.getChildren("bath").map((n) => n.id)).toEqual(["ac"]);
  });
  it("defaults task status to open and applies the later change", () => {
    expect(s.getNode("ac")?.status).toBe("in_progress");
    expect(s.getNode("bath")?.status).toBeNull();
  });
  it("notes carry a body, containers do not", () => {
    expect(s.getNode("ac-note")?.body).toBe("Error code P6 on the display");
    expect(s.getNode("cabin")?.body).toBeNull();
  });
  it("records attribution and last activity", () => {
    const ac = s.getNode("ac")!;
    expect(ac.createdBy).toBe("paul");
    expect(ac.lastEventAt).toBeGreaterThan(ac.createdAt);
    expect(s.getAttachmentsForNode("ac")).toHaveLength(1);
    expect(s.getLabels("ac")).toEqual(["Repair"]);
  });
});

describe("move-subtree", () => {
  const s = load("move-subtree");
  it("reparents and the descendants follow", () => {
    expect(s.getNode("bath")?.parentId).toBe("barn");
    expect(s.getAncestors("ac").map((n) => n.id)).toEqual(["bath", "barn", "cabin"]);
    expect(s.getNode("bath")?.lastEventBy).toBe("wife");
  });
  it("refuses a move under itself or its descendant", () => {
    const ev = byName("move-subtree")[5] as Extract<Event, { type: "node.moved" }>;
    expect(() => applyEvent(s, { ...ev, id: "x1", payload: { fromParentId: "barn", toParentId: "bath" } })).toThrow(ProjectionError);
    expect(() => applyEvent(s, { ...ev, id: "x2", nodeId: "cabin", payload: { fromParentId: null, toParentId: "ac" } })).toThrow(/descendant/);
  });
});

describe("archive-restore", () => {
  const s = load("archive-restore");
  it("restores and keeps later changes", () => {
    const g = s.getNode("gutter")!;
    expect(g.archivedAt).toBeNull();
    expect(g.status).toBe("done");
  });
});

describe("duplicate-and-retry", () => {
  const s = load("duplicate-and-retry");
  it("first create wins and labels are a set", () => {
    expect(s.getNode("cabin")?.title).toBe("The cabin");
    expect(s.getLabels("cabin")).toEqual([]);
  });
});

describe("validation", () => {
  it("rejects unknown parent, bad enum, status on a container", () => {
    const s = new MemoryStore();
    const base = { spaceId: "sp", actorId: "a", deviceId: "d", at: 1 };
    expect(() => applyEvent(s, { ...base, id: "e1", nodeId: "n", type: "node.created", payload: { parentId: "nope", kind: "task", title: "t" } })).toThrow(/unknown parent/);
    applyEvent(s, { ...base, id: "e2", nodeId: "c", type: "node.created", payload: { parentId: null, kind: "container", title: "c" } });
    const bad = { ...base, id: "e3", nodeId: "c", type: "node.field_changed", payload: { field: "status", before: null, after: "open" } } as Event;
    expect(() => applyEvent(s, bad)).toThrow(/only tasks/);
    const badPrio = { ...base, id: "e4", nodeId: "c", type: "node.field_changed", payload: { field: "priority", before: "none", after: "mega" } } as unknown as Event;
    expect(() => applyEvent(s, badPrio)).toThrow(/bad priority/);
  });
});
