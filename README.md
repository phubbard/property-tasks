# property-tasks

Shared, hierarchical tracking of the things a property needs done: notice the
bathroom AC has failed, photograph it, file it under cabin › main house ›
bathroom, break it into subtasks, and see who did what and when. Any item can
hold children, every change is an attributed event, and a household shares one
Space across iPhone, iPad, Mac and the web.

The model is generic on purpose. "Location", "Building" and "Repair" are
labels from a vocabulary pack, not schema, so the same app can track a boat,
a fleet of vehicles or a club's equipment.

**Status (October 2026): early, usable by its author, not yet by anyone
else.** Sign-in is a development stub, so nothing here should be deployed
where strangers can reach it. See [DESIGN.md](DESIGN.md) for the model and
architecture, [RESEARCH.md](RESEARCH.md) for the prior-art survey that found
nothing quite like it, and `apple/CHANGELOG.md` for the app.

## How it works

- **Event-sourced.** An append-only log of small, attributed events is the
  source of truth; node tables are projections. One `applyEvent` in
  TypeScript runs in the browser-less web tier and in the Durable Object, and
  a Swift port is held to the same JSON fixtures, so clients cannot drift.
- **Cloudflare.** One Worker serves the web pages, the JSON API and
  WebSockets. One SQLite-backed Durable Object per Space holds its log and
  projection. R2 holds content-addressed photos with client-made thumbnails.
  D1 holds identity.
- **Web is small pages, minimal JS, installable.** The Worker renders HTML;
  filters are query parameters so every view is a shareable URL; a service
  worker caches the shell.
- **Native app is offline-first.** A JSON-cached replica queues events and
  photo uploads, and reconciles on pull. Capture is camera first: shoot,
  title, place, priority, done, with GPS, heading and attitude recorded in a
  sidecar for later.

## Layout

```
shared/   TypeScript model: event types, projection (applyEvent), filter, fixtures. No runtime deps.
worker/   Cloudflare Worker: SpaceDO (one Durable Object per Space), API routes, blobs on R2, identity on D1.
web/      Static assets served by the Worker (CSS, manifest). Pages are rendered by the Worker.
apple/    Swift: Core package (model, projection, filter, sync client; `swift test` replays shared/fixtures)
          and the SwiftUI app for iPhone, iPad and native macOS (xcodegen + Makefile, see apple/Makefile).
```

## Run

Requires Node 20+.

```bash
npm install
npm test                 # shared projection/filter tests, then worker tests in the Workers runtime
npm run typecheck
```

Local dev server (Durable Object, R2 and D1 are emulated by Miniflare):

```bash
cd worker
npx wrangler d1 migrations apply property-tasks-identity --local   # once
npm run dev                                                         # http://localhost:8787
```

## Web app

The Worker renders HTML pages from the same Durable Object (DESIGN.md §7a):
template literals in `worker/src/html.ts` and `pages.ts`, routes in
`worker/src/web.ts`, no client framework. `web/public/` holds the stylesheet,
manifest and the service worker (`sw.js`: shell cached on install, recently
viewed pages served from cache when offline; writes are online-only).

| Route | Page |
|-------|------|
| `GET /` | the signed-in user's Spaces, with a form to create one |
| `GET /s/:spaceId` | tree view; non-matching ancestors of a hit stay visible but dimmed |
| `GET /s/:spaceId/list` | flat list with breadcrumb paths, sorted |
| `GET /s/:spaceId/n/:nodeId` | one node: fields, labels, attachments, children, history newest first |
| `POST /s/:spaceId/nodes` | create a node (`parent`, `title`, `kind`, `priority`) |
| `POST /s/:spaceId/n/:nodeId/{status,priority,label,archive,restore}` | one event each, then a 303 back to the node |

Tree and list take the same query parameters, which the filter bar mirrors so
every view is a shareable URL: `status` (repeatable; `any` for all), `priority`
(exact set), `priorityMin`, `kind`, `label`, `under` (container id), `ageMax`
and `stale` (days), `who` with `whoRole=touched|created|assigned`, `has`
(`photos`, `documents`, `due`, `children`), `due` (`overdue|week|month`),
`text`, `archived=1`, and on the list `sort`
(`priority|created|lastActivity|due|tree`). Example:
`/s/<id>/list?under=<houseId>&priorityMin=high&stale=30&sort=lastActivity`.

## API round-trip

Auth is a dev stub: with `DEV_USER` set in `wrangler.jsonc` every request is
that user, and `X-Dev-User: <id>` impersonates another user to exercise
membership checks. See `worker/src/auth.ts` for what replaces it.

```bash
# create a Space (the caller becomes owner)
curl -s -X POST localhost:8787/api/spaces -H 'content-type: application/json' -d '{"title":"Cabin"}'
# → {"id":"<spaceId>","title":"Cabin"}

# push a batch of events (ids are client-generated UUIDv7; retries are idempotent)
curl -s -X POST localhost:8787/api/spaces/<spaceId>/events -H 'content-type: application/json' -d '{"events":[
  {"id":"0199d000-0000-7000-8000-000000000001","spaceId":"<spaceId>","nodeId":"cabin","actorId":"paul","deviceId":"curl","at":1760000000000,
   "type":"node.created","payload":{"parentId":null,"kind":"container","title":"Cabin"}},
  {"id":"0199d000-0000-7000-8000-000000000002","spaceId":"<spaceId>","nodeId":"ac","actorId":"paul","deviceId":"curl","at":1760000001000,
   "type":"node.created","payload":{"parentId":"cabin","kind":"task","title":"Bathroom AC failed","priority":"high"}}
]}'
# → {"ok":true,"seqs":{"0199d000-…0001":2,"0199d000-…0002":3}}   (seq 1 is the owner's member.joined)

# pull since a cursor
curl -s 'localhost:8787/api/spaces/<spaceId>/events?since=0'

# projection snapshot for a new device
curl -s localhost:8787/api/spaces/<spaceId>/snapshot

# blobs are content-addressed; the original is verified against the sha in the path
sha=$(shasum -a 256 photo.jpg | cut -d' ' -f1)
curl -s -X PUT localhost:8787/api/spaces/<spaceId>/blobs/$sha -H 'content-type: image/jpeg' --data-binary @photo.jpg
curl -s localhost:8787/api/spaces/<spaceId>/blobs/$sha -o back.jpg
```

Live updates: `GET /api/spaces/<spaceId>/ws?device=<deviceId>` upgrades to a
WebSocket; the Durable Object sends `{"type":"events","events":[…]}` for
every batch committed by another device.

## Apple app

Requires Xcode 27 and `brew install xcodegen`. Signing settings live in a gitignored local xcconfig:

```bash
cd apple
cp PropertyTasks.local.xcconfig.sample PropertyTasks.local.xcconfig   # team id is pre-filled
make core-test     # swift test on Core: replays shared/fixtures through the Swift projection
make build         # iOS Simulator debug build
make build-mac     # native macOS debug build
make test          # core tests, then the app test bundle on a simulator
make run-mac       # launch the Mac app against http://localhost:8787 (Settings changes the server)
```

The app signs in with the same dev stub as the Worker (Settings → Dev user) until real
sessions exist. TestFlight targets (`make upload-testflight`, `make upload-testflight-mac`,
`make testflight-notes`) follow the Serpentine/mapbook pipeline and need App Store Connect key ids
in the local xcconfig.

## Tests

- `shared/fixtures/*.json`: event lists with the expected projection.
  Regenerate with `npm run fixtures:regen -w shared` after changing the
  projection on purpose. Any other implementation of the projection (the
  Durable Object's SQL store, the Swift port) must reproduce these.
- `apple/Core/Tests`: the Swift projection replays the same `shared/fixtures` and must match
  byte-for-byte after decoding; `apple/PropertyTasksTests` covers the local replica store.
- `worker/test/space.test.ts`: push/pull round-trip, idempotent retry,
  snapshot equals replay, atomic rejection, membership refusal, blob upload
  with sha verification. Runs inside workerd via `@cloudflare/vitest-plugin`.
- `worker/test/pages.test.ts`: the HTML pages over a seeded Space: tree rows
  with depth and dimming, list breadcrumbs, filter parameters, the node page,
  form posts that append events and redirect, 403 for non-members and
  viewers, and a size budget on the tree page.

## Deploy

```bash
cd worker
npx wrangler r2 bucket create property-tasks-blobs
npx wrangler d1 create property-tasks-identity      # paste the id into wrangler.jsonc
npx wrangler d1 migrations apply property-tasks-identity --remote
npm run deploy
```

Remove `DEV_USER` from `wrangler.jsonc` before any deploy that is reachable
by anyone else; until real auth lands the Worker has none.
