# property-tasks

Shared, hierarchical tracking of property tasks with photos and an attributed
audit log. Web first, then SwiftUI for iPhone, iPad and Mac. Read
[DESIGN.md](DESIGN.md) for the model and architecture and
[RESEARCH.md](RESEARCH.md) for the prior-art survey.

## Layout

```
shared/   TypeScript model: event types, projection (applyEvent), filter, fixtures. No runtime deps.
worker/   Cloudflare Worker: SpaceDO (one Durable Object per Space), API routes, blobs on R2, identity on D1.
web/      Static assets served by the Worker (CSS, manifest). Pages are rendered by the Worker.
apple/    (later) Swift package + SwiftUI app; ports shared/ against the same fixtures.
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

## Tests

- `shared/fixtures/*.json`: event lists with the expected projection.
  Regenerate with `npm run fixtures:regen -w shared` after changing the
  projection on purpose. Any other implementation of the projection (the
  Durable Object's SQL store, the Swift port) must reproduce these.
- `worker/test/space.test.ts`: push/pull round-trip, idempotent retry,
  snapshot equals replay, atomic rejection, membership refusal, blob upload
  with sha verification. Runs inside workerd via `@cloudflare/vitest-plugin`.

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
