import { describe, expect, it } from "vitest";
import { MemoryStore, query, replay, tree } from "../src/index.js";
import { cases } from "../scripts/fixture-cases.js";

const s = new MemoryStore();
replay(s, cases.find((c) => c.name === "create-tree")!.events);
const now = 1_760_000_000_000 + 10 * 60_000;

describe("filter", () => {
  it("default hides done tasks but keeps containers and notes", () => {
    expect(query(s, {}, now).map((n) => n.id).sort()).toEqual(["ac", "ac-note", "bath", "cabin", "house"]);
  });
  it("under + kind + label + has photos", () => {
    expect(query(s, { under: ["house"], kind: ["task"] }, now).map((n) => n.id)).toEqual(["ac"]);
    expect(query(s, { under: ["cabin"], labels: ["Repair"] }, now).map((n) => n.id)).toEqual(["ac"]);
    expect(query(s, { has: ["photos"] }, now).map((n) => n.id)).toEqual(["ac"]);
    expect(query(s, { under: ["bath"], has: ["photos"] }, now)).toHaveLength(1);
    expect(query(s, { under: ["ac"] }, now).map((n) => n.id)).toEqual(["ac-note"]);
  });
  it("priority, stale, text", () => {
    expect(query(s, { priorityMin: "high" }, now).map((n) => n.id)).toEqual(["ac"]);
    expect(query(s, { staleDays: 1 }, now)).toHaveLength(0);
    expect(query(s, { text: "p6" }, now).map((n) => n.id)).toEqual(["ac-note"]);
  });
  it("tree keeps dimmed ancestors of hits", () => {
    const rows = tree(s, { kind: ["task"] }, now);
    expect(rows.map((r) => [r.node.id, r.depth, r.dimmed])).toEqual([
      ["cabin", 0, true], ["house", 1, true], ["bath", 2, true], ["ac", 3, false],
    ]);
  });
});
