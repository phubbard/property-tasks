import type { Event } from "../src/index.js";

/**
 * Fixture cases: an event list and a name. `regen-fixtures.ts` replays each
 * through the TypeScript projection and writes the expected projection next
 * to it. Other implementations (the Durable Object's SQL store, Swift) must
 * produce the same serialized projection from the same events.
 */
const SPACE = "space-1";
const t0 = 1_760_000_000_000; // 2025-10-09T08:53:20Z, fixed for determinism

function ev(n: number, nodeId: string | null, body: Omit<Event, "id" | "spaceId" | "nodeId" | "actorId" | "deviceId" | "at">, actor = "paul"): Event {
  return {
    id: `0199c000-0000-7000-8000-${String(n).padStart(12, "0")}`,
    spaceId: SPACE,
    nodeId,
    actorId: actor,
    deviceId: `${actor}-phone`,
    at: t0 + n * 60_000,
    ...body,
  } as Event;
}

export const cases: Array<{ name: string; events: Event[] }> = [
  {
    name: "create-tree",
    events: [
      ev(1, null, { type: "member.joined", payload: { userId: "paul", role: "owner", displayName: "Paul" } }),
      ev(2, "cabin", { type: "node.created", payload: { parentId: null, kind: "container", title: "Cabin", sortKey: "a" } }),
      ev(3, "house", { type: "node.created", payload: { parentId: "cabin", kind: "container", title: "Main house", sortKey: "a" } }),
      ev(4, "bath", { type: "node.created", payload: { parentId: "house", kind: "container", title: "Bathroom", sortKey: "b" } }),
      ev(5, "ac", { type: "node.created", payload: { parentId: "bath", kind: "task", title: "AC failed", priority: "high", sortKey: "a" } }),
      ev(6, "ac", { type: "label.added", payload: { label: "Repair" } }),
      ev(7, "ac", {
        type: "attachment.added",
        payload: {
          attachment: {
            id: "att-1", kind: "image", mime: "image/jpeg", filename: "IMG_2231.jpg", byteSize: 3_200_000,
            sha256: "ab".repeat(32), url: null, width: 4032, height: 3024, durationMs: null, caption: "", sortKey: "a",
            capture: { capturedAt: t0 + 7 * 60_000, gps: { lat: 45.5, lon: -122.6, accuracyM: 5 }, headingDeg: 270 },
          },
        },
      }),
      ev(8, "ac-note", { type: "node.created", payload: { parentId: "ac", kind: "note", title: "", body: "Error code P6 on the display", sortKey: "a" } }),
      ev(9, "ac", { type: "node.field_changed", payload: { field: "status", before: "open", after: "in_progress" } }),
    ],
  },
  {
    name: "move-subtree",
    events: [
      ev(1, "cabin", { type: "node.created", payload: { parentId: null, kind: "container", title: "Cabin", sortKey: "a" } }),
      ev(2, "house", { type: "node.created", payload: { parentId: "cabin", kind: "container", title: "Main house", sortKey: "a" } }),
      ev(3, "barn", { type: "node.created", payload: { parentId: "cabin", kind: "container", title: "Barn", sortKey: "b" } }),
      ev(4, "bath", { type: "node.created", payload: { parentId: "house", kind: "container", title: "Bathroom", sortKey: "a" } }),
      ev(5, "ac", { type: "node.created", payload: { parentId: "bath", kind: "task", title: "AC failed", sortKey: "a" } }),
      // Oops, the AC is in the barn's washroom. Move the whole bathroom subtree.
      ev(6, "bath", { type: "node.moved", payload: { fromParentId: "house", toParentId: "barn" } }, "wife"),
      ev(7, "bath", { type: "node.field_changed", payload: { field: "title", before: "Bathroom", after: "Washroom" } }, "wife"),
    ],
  },
  {
    name: "archive-restore",
    events: [
      ev(1, "cabin", { type: "node.created", payload: { parentId: null, kind: "container", title: "Cabin", sortKey: "a" } }),
      ev(2, "gutter", { type: "node.created", payload: { parentId: "cabin", kind: "task", title: "Clean gutters", priority: "low", sortKey: "a" } }),
      ev(3, "gutter", { type: "node.archived", payload: {} }),
      ev(4, "gutter", { type: "node.archived", payload: {} }), // idempotent: archivedAt keeps the first time
      ev(5, "gutter", { type: "node.restored", payload: {} }, "wife"),
      ev(6, "gutter", { type: "node.field_changed", payload: { field: "status", before: "open", after: "done" } }, "wife"),
    ],
  },
  {
    name: "duplicate-and-retry",
    events: [
      ev(1, "cabin", { type: "node.created", payload: { parentId: null, kind: "container", title: "Cabin", sortKey: "a" } }),
      ev(1, "cabin", { type: "node.created", payload: { parentId: null, kind: "container", title: "Cabin (retry)", sortKey: "a" } }),
      ev(2, "cabin", { type: "node.field_changed", payload: { field: "title", before: "Cabin", after: "The cabin" } }),
      ev(3, "cabin", { type: "label.added", payload: { label: "Location" } }),
      ev(4, "cabin", { type: "label.added", payload: { label: "Location" } }),
      ev(5, "cabin", { type: "label.removed", payload: { label: "Location" } }),
    ],
  },
];
