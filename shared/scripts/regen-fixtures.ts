import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { MemoryStore, replay, serialize } from "../src/index.js";
import { cases } from "./fixture-cases.js";

const dir = join(dirname(fileURLToPath(import.meta.url)), "..", "fixtures");
mkdirSync(dir, { recursive: true });
for (const c of cases) {
  const store = new MemoryStore();
  replay(store, c.events);
  const out = { name: c.name, events: c.events, expected: serialize(store) };
  writeFileSync(join(dir, `${c.name}.json`), JSON.stringify(out, null, 2) + "\n");
  console.log(`wrote ${c.name}.json (${c.events.length} events, ${out.expected.nodes.length} nodes)`);
}
