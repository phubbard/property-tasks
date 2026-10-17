import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { MemoryStore, replay, serialize, type Event, type Serialized } from "../src/index.js";

const dir = join(import.meta.dirname, "..", "fixtures");
const files = readdirSync(dir).filter((f: string) => f.endsWith(".json")).sort();

describe("fixtures replay to their expected projection", () => {
  it("has fixtures", () => expect(files.length).toBeGreaterThanOrEqual(3));
  for (const file of files) {
    it(file, () => {
      const fx = JSON.parse(readFileSync(join(dir, file), "utf8")) as { events: Event[]; expected: Serialized };
      const store = new MemoryStore();
      replay(store, fx.events);
      expect(serialize(store)).toEqual(fx.expected);
    });
  }
});
