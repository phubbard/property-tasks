# Design notes (draft, 2026-10-17)

Companion to RESEARCH.md. Decisions so far are in §0; everything else is a
proposal.

## 0. Decisions

- **Files are attachments on a node, not nodes.** (2026-10-17) A node owns an
  ordered list of attachments. If a single photo ever needs its own children,
  add a note child that references the attachment. The attachments table is
  shaped so a later "promote attachment to node" migration is mechanical.
- **Platforms: web app first, then SwiftUI multiplatform.** (2026-10-17)
  The web app validates the event-sourced model, sync and filters with real
  household data. Then one SwiftUI target with iPhone, iPad and Mac
  destinations owns the camera-first capture flow; "Designed for iPad" covers
  the Mac until the macOS destination is polished. Android stays on the PWA
  until an Android user needs more. Catalyst is not used (§10).
- **Hosting: Cloudflare.** (2026-10-17) One Durable Object per Space holds
  the event log in SQLite; R2 holds blobs; a single Worker serves the web
  app, the API and WebSockets. Details in §11.

## 1. One data model, a domain vocabulary on top

What generalises is not "property" but: **things arranged in a hierarchy,
with work to do on them, documented with media, shared by a few people, with
an attributed history.** Boats, vehicles, a garden, a club's equipment, a
lab's instruments, an estate clean-out and a rental portfolio all fit.

The model knows nothing about buildings or rooms. It knows:

| Model term  | Meaning | Property-domain label |
|-------------|---------|-----------------------|
| Space       | A shared top-level tree with members. | "Home", "Cabin" |
| Node (UI: Item) | The universal unit. Any node can have children. | Location, Building, Room, Task |
| Kind        | Small fixed set that decides behaviour: `container`, `task`, `note`. | see below |
| Label       | User-defined tag, optionally scoped to a kind. Carries the domain names. | Location, Building, Room; Repair, Inspection, Purchase |
| Attachment  | A file owned by a node: image, video, PDF, document, spreadsheet, link. | "Photos & files" |
| Status      | Fixed state machine on tasks: `open`, `in_progress`, `blocked`, `done`, `cancelled`. | same |
| Priority    | Fixed: `none`, `low`, `normal`, `high`, `urgent`. | same |
| Event       | Append-only audit entry: who, when, what changed, on which node. | "History" |
| Member      | A person in a Space with a role. | same |

Kinds:

- `container` — groups things; no status of its own; rolls up descendant
  counts ("3 open below"). Locations, buildings, rooms, appliances and
  projects are containers with different labels.
- `task` — status, priority, optional due date, optional assignee.
- `note` — rich text, child of whatever it describes. Also the comment
  mechanism: a comment is a note child with no title.

A **vocabulary pack** per Space maps labels to names, icons and defaults:

- Property: Location > Building > Area > Fixture; Repair, Inspection,
  Purchase, Recurring, Idea.
- Boat: Marina > Vessel > System > Component; Service, Survey item, Winterise.
- Generic: Group / Item / Task.

The pack is presentation plus default labels; switching packs never migrates
data. The UI says "Room" and "Repair", the code says `container` and `task`.
This is the Tana/Logseq supertag pattern on a narrow domain, and it avoids
the Jira trap: the state machine is fixed, only names and labels vary.

Costs of generality, and the chosen answers:

- "Location" filter becomes "descendants of node X" (needs a subtree query, §4).
- "Type of task" is a label, not an enum.
- Status stays fixed; a seventh state is a label.
- Depth is unbounded; the pack suggests a default depth only to shape the
  new-item picker.

## 2. Attachments

One table, one blob store, content-addressed.

- `attachments`: id, space_id, node_id, kind (`image`, `video`, `pdf`,
  `document`, `spreadsheet`, `link`, `scan`, `other`), mime, filename, byte_size,
  sha256, width, height, duration, captured_at (from EXIF), caption,
  sort_key, created_at, created_by, removed_at.
- Blob stored under its sha256 (dedupe for free; the same manual attached to
  two appliances is one object). Thumbnails and a phone-sized derivative are
  generated server-side and cached on device.
- `link` is an attachment with a URL and no blob: manuals, vendor pages,
  the Amazon order.
- Add, remove and recaption are events on the owning node, so the audit log
  reads "Paul added 3 photos" and "removed photo IMG_2231".
- Documents and spreadsheets are stored and previewed (Quick Look on Apple,
  browser viewer on web), never edited in-app. Editing lives in the native
  app the file belongs to; re-attach to update, and the old version stays in
  history.
- The row in the list shows a thumbnail strip and an attachment count; the
  tree shows a count badge only.

Filters this enables: "Has photos", "Has documents", "Attachments added in
the last N days", "Captured between dates" (EXIF, not upload time).

## 3. The capture flow (the headline UX)

The example in the brief is "notice the bathroom AC has failed, take a few
pictures." That has to be about four taps on a phone, offline.

1. **Camera first.** The new-item button opens the camera, not a form.
   Shoot one or several; each is an attachment on the item about to exist.
2. **Title**, one line. Dictation works here.
3. **Where.** Default is the last-used container; one tap to change via
   recents or search. If the person does not know or care, it lands in the
   Space's **Inbox** container at the root for later triage on the iPad.
4. **Priority** chip, defaulting to normal. Done.

Everything else (labels, due date, assignee, notes) is optional and lives on
the item screen. "Add photo to an existing item" is the same camera from the
item screen. Photos keep EXIF date and GPS; GPS-suggested location is a later
feature, not v1.

Offline: the item and its events exist locally immediately; blobs upload in
the background. Another member sees the item with placeholders until the
bytes arrive, because the event carries the sha256, dimensions and caption
without the bytes.

## 4. Views and filters

Tree view and list view are one query rendered twice, over one filter bar.

**Tree** (structure): outline, collapse/expand, drag to reparent, roll-up
badges on containers (open count, highest priority, newest activity). With a
filter active, non-matching ancestors of a match stay visible but dimmed so
the path survives; non-matching subtrees collapse. Good on iPad, Mac, web.
On a phone the tree is drill-down with a breadcrumb, not an outline.

**List** (work): flat, filtered, sorted, optionally grouped. Every row
carries its ancestor path ("Cabin › Main house › Bathroom"). This is the
primary phone view.

| Filter | Semantics |
|--------|-----------|
| Status | any of the five; default open + in_progress + blocked |
| Priority | at-or-above, or exact set |
| Kind | task / container / note |
| Label | task type or container label |
| Under | subtree of chosen node(s): the generic "location" filter |
| Age | created-at buckets: today, 7d, 30d, 90d, older |
| Stale | no event in N days (from the audit log; usually more useful than Age) |
| Who | created by / last touched by / assigned to |
| Has | photos, documents, due date, children |
| Due | overdue, this week, this month |

Sort: priority, created, last activity, due, tree order.
Group (list only): by container at depth N, priority, status, label.

**Saved views** are a named filter + sort + group + rendering, shared per
Space. The property pack ships: Open everywhere, Urgent, Stale > 30 days,
Recently changed, Needs photos, Inbox. Search is a filter over title and note
text with the same renderings.

## 5. Event log, attribution and sync

The audit log is a headline feature, so make events the source of truth and
project the node table from them (event-sourced), rather than a mutable
table with a log beside it.

- `events`: id (UUIDv7, generated on the client so offline creation works),
  space_id, node_id, actor_id, device_id, at (client clock), received_at
  (server clock), type, payload JSON.
- Types: `node.created`, `node.field_changed` {field, before, after},
  `node.moved` {from_parent, to_parent}, `node.archived`, `node.restored`,
  `label.added`, `label.removed`, `attachment.added`, `attachment.removed`,
  `attachment.captioned`, `note.edited`, `member.joined`, `member.role_changed`.
- No hard delete anywhere; archive is an event. Reparenting is an event, so
  the history explains why a task is now under a different room.
- Conflict policy for a household: last-writer-wins per field, ordered by
  server receipt. Moves: last move wins. Note bodies: whole-text replace per
  save, with each version in history. Collaborative rich-text editing is
  explicitly out of scope.
- Display: order the history by `received_at`, show `at`. Clock skew on a
  phone that was offline for a week is then harmless.

Sync: the server keeps the canonical per-Space event log. Clients push local
events, pull since a cursor, apply to a local SQLite projection. Blobs travel
separately, by hash, in the background. Because the unit is a small
append-only event, the sync is hand-rolled on a Cloudflare Durable Object
per Space (§11) rather than a sync service.

Local projection tables: `nodes` (id, space_id, parent_id, kind, title,
status, priority, due_at, assignee_id, sort_key, created_at, created_by,
last_event_at, archived_at), `node_labels`, `node_closure` (ancestor_id,
descendant_id, depth) for "Under X", roll-ups and group-by-depth as single
joins, `attachments`, `saved_views`. Household scale is thousands of nodes;
SQLite on-device is plenty. Roll-ups computed on read first, cached later if
it hurts.

## 6. Members and identity

Attribution needs accounts. Keep it minimal: Space has members with roles
`owner`, `editor`, `viewer`; invite by link; sign in with passkey, Sign in
with Apple, or emailed magic link. No per-node permissions in v1: if two
people should not see the same things, they get two Spaces.

## 7. Platforms: five targets, four ways to get there

| Option | Codebases | Feel | Effort | Notes |
|--------|-----------|------|--------|-------|
| A. Native each: SwiftUI multiplatform (iPhone, iPad, Mac) + Kotlin/Compose (Android) + web | 3 | best | highest | SwiftUI multiplatform renders through AppKit on the Mac; Catalyst is still supported but adds nothing for a new SwiftUI app (§10). |
| B. Flutter everywhere | 1 | good | medium | Real macOS and web targets; camera, offline SQLite and background upload all solved. Non-native feel on Apple. |
| C. Kotlin Multiplatform core (model, sync, SQLDelight) + SwiftUI and Compose UIs + web | 2 UIs + 1 core | native | high | Shared logic, native UI, web is the weak leg. |
| D. PWA first | 1 | adequate | lowest | Installable on all five, camera and offline work, loses share sheet and background upload. Fastest way to validate the model with a real user. |

Decision (§0): **D then A**. Build the event log, sync and web app first,
since that validates the data model and the filters against real household
data in weeks. Then a SwiftUI multiplatform app for iPhone, iPad and Mac,
which is where the camera-first capture flow has to feel right. Android
keeps the PWA until there is an Android user who needs more. The server and
sync protocol are shared by every option, so nothing is wasted if A becomes B.

## 7a. Web app: small pages, minimal JS, installable (decided 2026-10-17)

Paul's rule for every web project applies here: small fast pages, minimal
JavaScript, a PWA where it helps. Read with the house-style concept in Memento
(`/skills/web-frontend-house-style.md`), that means:

- **Server-rendered HTML from the Worker.** The Worker reads the Space's
  projection from the Durable Object and returns a page. No client-side
  framework, no bundler; `web/` holds static assets only (CSS, manifest,
  service worker, icons) and `build.mjs` just copies them.
- **Filters are query parameters** (`?status=open&under=<id>&sort=priority`),
  so every list and tree is a shareable, bookmarkable URL, as in movielist.
  Saved views are named URLs.
- **Forms, not fetch.** Create, edit, move and photo upload are plain forms
  (`<input type=file accept="image/*" capture>` for the camera). The Worker
  turns a form post into events and redirects back. A few lines of script
  enhance what benefits from it: expanding tree nodes without reload,
  client-side thumbnail generation before upload, optimistic status toggles.
- **PWA for installability and read caching.** `manifest.webmanifest` plus a
  service worker that caches the shell and recently viewed pages. Writes
  stay online-only on the web; the full offline replica with local SQLite
  is the native app's job (§7). That keeps the web client tiny and the sync
  protocol in §11 serves the native clients.
- **Styling** follows House B: tokens on `:root`, dark-first with a light
  override, system font stack, no webfonts, `tabular-nums` on numeric
  columns, native `<details>`/`<dialog>` over div widgets, labels with
  `for=`, landmarks.

The JSON API in §11 remains the contract for native clients and scripts;
the HTML routes are a second front door on the same Durable Object.

## 8. Open questions

- Should containers be allowed a status (a project that is "done")? Current
  answer: no, a project is a task with children.
- One Space per property, or one Space with properties as top-level
  containers? Permissions decide: same people see everything, one Space.
- Debug app icon for the Apple builds: use `blueprint`
  (github.com/MustafaNatur/blueprint, `brew install mustafanatur/tap/blueprint`)
  to generate the blueprint-style Debug icon with a DEV badge once an
  `.icon`/`.appiconset` exists; it needs macOS 14 and Xcode 26. The fastlane
  `badge` plugin does the same job but drags in Ruby, fastlane and ImageMagick.
- Video: upload through the Worker (size-capped) or presigned multipart to
  R2. Photos go through the Worker in v1; decide video when it matters.

## 9. Capture beyond GPS: what the phone can give us

Principle: **capture raw sensor data at the moment of the photo, because it
cannot be recovered later; derive everything else later, because models
improve.** So every attachment gets an immutable `capture` sidecar and a
growable set of `derived` records with provenance.

- `attachments.capture` JSON (written once): EXIF timestamp, GPS lat/lon/alt
  with horizontal accuracy, compass heading, gravity vector / device attitude
  (roll, pitch, yaw), camera intrinsics (focal length, sensor size, image
  size), lens, and when available an ARKit camera transform and session id,
  barometric altitude, and a depth map reference.
- `derived`: id, attachment_id, kind (`ocr_text`, `barcode`, `segment_mask`,
  `labels`, `suggested_title`, `transcript`, `room_scan`, `measurement`),
  producer (model name and version, or `human`), confidence, payload,
  created_at. Recomputable; nothing in the audit log depends on it.
- Anything a model suggests is a **suggestion until accepted**. Acceptance is
  an ordinary event ("Paul accepted suggested title, source: on-device
  Vision 2026"), so the history stays honest about what a person did versus
  what a model did.

What is actually available, ranked by value for this app:

1. **OCR and barcodes** (on-device, Apple Vision `RecognizeText` and
   `DetectBarcodes`, VisionKit live data scanner; ML Kit on Android). Model
   and serial plates, error codes on a display, meter readings, labels on
   breakers. Cheap, reliable, and the single biggest upgrade to "take a few
   pictures": the AC's model number becomes searchable text on the item.
2. **Image understanding for suggestions.** A multimodal model (on-device
   Apple Foundation Models where it suffices, cloud Claude when it does not)
   turns the photo into a suggested title, task label, and container
   ("Mini-split indoor unit, Mitsubishi MSZ-GL, error P6; Repair; probably
   Bathroom"). Subject lifting / segmentation (VisionKit, ML Kit subject
   segmentation) isolates the fixture for a clean thumbnail and better
   classification. Cloud use is a privacy decision per Space; default
   on-device, opt in to cloud.
3. **NFC tags and QR codes per node.** Stick a tag on the furnace, the well
   pump, the breaker panel; tap to open its node with the camera ready. Core
   NFC on iPhone, standard on Android. Cheap and the most "this app knows my
   house" feature available. QR as the printable fallback and for web.
4. **Pose and heading** (view frustum). Outdoors: GPS position (about 5 m)
   plus compass heading (about 10 to 20 degrees) plus pitch from the
   accelerometer gives a usable approximate frustum, enough to put a cone on
   a site map showing where a photo was taken from and which way it faced.
   Indoors GPS collapses; a true 6DoF pose needs ARKit world tracking
   relative to a session origin, and persisting that across visits means a
   saved ARWorldMap per building to relocalise against. Store the raw pose
   now, build the map-with-cones view later, treat indoor relocalisation as
   a research feature. ARKit geo-tracking and ARCore Geospatial give absolute
   pose outdoors but only in covered cities.
5. **LiDAR and RoomPlan** (iPhone Pro and iPad Pro only). RoomPlan returns a
   parametric room (walls, doors, windows, openings, and categorised objects
   such as storage, sink, bathtub, with dimensions) as USDZ plus JSON. One
   scan per room gives a floor plan, lets a task be pinned to a position in
   the room, and gives an object list to seed Fixture containers. Scene
   depth per photo enables measuring in the picture later ("how wide is that
   gap"). Object Capture gives a 3D model of a fixture. High wow, native and
   Apple-only, not v1; the sidecar reserves the fields.
   **Room dimensions (idea, 2026-10-17).** A RoomPlan scan is an attachment
   of kind `scan` on the room's container node (JSON plus USDZ, content
   addressed in R2). Dimensions (width, length, ceiling height, floor area,
   wall list) are a `derived` record on that attachment with producer and
   confidence; accepting them onto the room is an ordinary event, so the
   history says who measured and when, and a re-scan is a second attachment
   and a second derivation. Detected objects become Fixture suggestions,
   never auto-created. The room page draws a small floor plan as inline SVG
   from the wall list; later a task can be pinned to a position in it, and
   multi-room sessions can lay rooms out relative to each other. Non-LiDAR
   iPhones, Android and the web get manual width/length/height fields.
   Accuracy is a few centimetres: fit-a-vanity, not cut-the-trim. Measuring a
   single object (the AC unit) is the smaller ARKit two-tap raycast feature,
   stored as a `measurement` derivation on a photo. Native-only, SwiftUI phase.

6. **Audio.** A voice memo with on-device transcription (Speech framework,
   iOS 26 SpeechAnalyzer) is the fastest way to describe a problem, and a
   recording of the noise a failing compressor makes is evidence a photo
   cannot hold. Transcript is a `derived` record.
7. **Barometer and beacons.** Barometric altitude distinguishes floors;
   iBeacons in rooms identify the room without GPS. Both are cheap to log
   and only matter once there is a map view.

Consequences for the rest of the design:

- Nearly all of this is native-only (ARKit, RoomPlan, Vision, Core NFC, Speech).
  The PWA can do photos, GPS, heading and server-side OCR, nothing else. That
  strengthens §7: the web app validates the model, the SwiftUI app owns capture.
- The `capture` sidecar is small (a few hundred bytes without depth); depth
  maps and room scans are blobs stored like any other attachment.
- A sensor bundle and a 3D scan of a home are sensitive. They stay inside
  the Space, under the self-hosting rules in the privacy policy concept, and
  never leave the device for cloud inference without an explicit per-Space
  opt in.

## 10. Mac Catalyst versus SwiftUI multiplatform

Correction to an earlier note: Apple has **not** deprecated Mac Catalyst.
As of October 2026 it still ships in the SDK alongside iOS and macOS; the
one real change from WWDC25 is that the UIScene life cycle becomes mandatory
in the release after iOS 26, which reaches Catalyst apps on macOS 27. The
recommendation against Catalyst below is about fit, not deprecation.

Three ways an iPhone/iPad codebase reaches the Mac:

| Route | What it is | Mac feel | Work | When it makes sense |
|-------|------------|----------|------|---------------------|
| **Designed for iPad** | The unmodified iPad binary runs on Apple silicon Macs; a checkbox in App Store Connect. | iPad app in a window; touch idioms, no real menu bar beyond defaults. | none | Day-one Mac presence while the real Mac target is unfinished. |
| **Mac Catalyst** | The iPad app compiled against UIKit-on-Mac. Two idioms: "scale to match iPad" or "optimise for Mac" (native control metrics). Gets a menu bar, toolbar, multiple windows; AppKit-only features need a bundled AppKit plugin. | good to very good, with effort | medium, plus the UIScene migration | An existing **UIKit** codebase you do not want to rewrite. |
| **SwiftUI multiplatform** | One target with iOS, iPadOS and macOS destinations. SwiftUI renders through AppKit on the Mac, so `List` with `OutlineGroup` becomes an `NSOutlineView`, `Table` becomes an `NSTableView`, `NavigationSplitView` becomes the three-column Mac layout, and `.commands` populate the menu bar. Platform differences live behind `#if os(macOS)`. | native | the same code, plus Mac-specific polish | A **new** app written in SwiftUI, which is this one. |

Why SwiftUI multiplatform here:

- There is no UIKit codebase to preserve, so Catalyst's only advantage is
  absent. Catalyst would add a translation layer, scaling quirks and a
  lifecycle migration for nothing.
- The Mac and iPad views this app needs are exactly the ones SwiftUI maps
  well: an outline for the tree, a table for the list, a split view for
  both, a toolbar for the filter chips, keyboard shortcuts via `.commands`.
- New platform features (Liquid Glass in the 26 releases, for instance)
  arrive in SwiftUI first and reach Catalyst only through UIKit.
- The capture code is iOS-only no matter what: camera, VisionKit's live
  scanner, RoomPlan, Core NFC and Speech are iPhone and iPad frameworks.
  That code sits behind `#if os(iOS)` and the Mac build gets the review,
  triage and bulk-edit role, which is what a Mac is for in this app anyway.

Practical plan (started 2026-10-17): `apple/Core` is a local Swift package
holding the model, projection, filter and sync client, tested with `swift test`
against `shared/fixtures` so it cannot drift from the TypeScript projection;
`apple/project.yml` (xcodegen) defines one SwiftUI target with iOS and macOS
destinations plus a test bundle, and `apple/Makefile` carries the
Serpentine/mapbook pipeline (gitignored project, local xcconfig for signing,
git-count build numbers, TestFlight upload and notes). Bundle id
`net.phfactor.propertytasks`, chosen like a tattoo. The first app has the
Spaces list, tree and list views with the shared filter, a node page with
status, priority, labels, children, photos and history, photo attach through
the photo picker with client-side derivatives and EXIF into the capture
sidecar, and a JSON-cached offline replica (`SpaceStore`) that queues events
and reconciles on pull. Camera-first capture, SQLite, OCR and RoomPlan are
next. Tick "Designed for iPad" on
day one so the Mac has something, then promote the macOS destination as the
outline, table and menu commands get their polish. Catalyst stays off the
table unless a UIKit dependency forces it.

## 11. Cloudflare architecture

One Worker, one Durable Object class, one R2 bucket, one small D1 database.
Everything is in a single `wrangler.jsonc` and runs locally under
`wrangler dev` (Miniflare emulates the DO, R2 and D1).

### Pieces

| Piece | Role |
|-------|------|
| **Worker** `property-tasks` | Serves the web app as static assets, the HTTP API under `/api`, blob reads and writes, and the WebSocket upgrade per Space. Validates the session, checks membership, then calls the Space's Durable Object by RPC. |
| **`SpaceDO`** (SQLite-backed, one per Space, `getByName(spaceId)`) | The canonical event log plus a server-side projection. Tables: `events` (seq, id, actor_id, device_id, at, received_at, type, payload), `nodes`, `node_closure`, `node_labels`, `attachments`, `members`, `invites`, `saved_views`. Assigns `seq`, enforces idempotency on event id, applies the projection, broadcasts to live sockets. |
| **R2** bucket `blobs` | Content-addressed objects: `spaces/{spaceId}/{sha256}` for originals and `spaces/{spaceId}/{sha256}/{variant}` for the thumbnail and phone-sized derivative. Egress is free, which matters for a photo-heavy app. |
| **D1** `identity` | Users, passkey credentials, sessions, and the user-to-spaces index. Global lookups that do not belong to any one Space. Tiny. |

The DO name is the Space id (UUIDv7), so routing is deterministic and no
id mapping is stored anywhere.

### Sync protocol (hand-rolled, small)

- **Push**: `POST /api/spaces/{id}/events` with a batch of client-authored
  events. Each carries a client-generated UUIDv7 id, so retries are
  idempotent (`INSERT OR IGNORE`). The DO checks the actor matches the
  session, assigns `seq` (monotonic per Space) and `received_at`, applies
  the projection in the same synchronous transaction (no `await` between
  the writes), and returns the assigned seqs.
- **Pull**: `GET /api/spaces/{id}/events?since={seq}` pages forward.
- **Snapshot**: `GET /api/spaces/{id}/snapshot` returns the projection plus
  the current seq, so a new device does not replay years of events. The log
  itself is never truncated; it is the audit trail.
- **Live**: one WebSocket per Space per client, using the Hibernation API
  (`ctx.acceptWebSocket`, `webSocketMessage`, `webSocketClose`) so idle
  phones cost nothing. Per-socket state (user id, last acked seq) goes in
  `serializeAttachment`, under its 16 KB cap. After each committed batch
  the DO sends the new events to every other socket. Deploying a new
  Worker version drops all sockets; clients reconnect and pull since cursor,
  which is the same path as coming back from offline.
- **Ordering**: `seq` is the truth for conflict resolution (last writer per
  field by seq); `at` is what the history screen shows.
- **Sizes**: a SQLite row in a DO is capped at 2 MB, so note bodies are
  capped well below that and anything larger is a blob. Events stay small
  by construction.

Two projections, one truth: the TypeScript projection runs in the browser
and in the DO; the Swift app needs its own. Keep a shared fixture suite
(`shared/fixtures/*.json`: an event list and the expected projection) that
both implementations must pass, or the two apps will drift.

### Blobs

- **Upload** through the Worker: `PUT /api/spaces/{id}/blobs/{sha256}` with
  the bytes as the body; the Worker verifies the hash while streaming to
  `env.BLOBS.put`. Request bodies are capped at 100 MB on the free plan and
  500 MB on paid, which covers photos and short clips. Long video moves to
  presigned multipart later (§8).
- **Derivatives are made on the client**, not the server: the phone (or the
  browser via canvas) produces the thumbnail and a phone-sized JPEG at
  capture and uploads all three. No image library in the Worker, no paid
  image-transform add-on, and the derivatives exist offline immediately.
- **Read** via `GET /api/spaces/{id}/blobs/{sha256}[/{variant}]` after a
  membership check, streamed from R2 with `Cache-Control: immutable`
  because the key is the content hash.
- The `attachment.added` event carries sha, size, mime, dimensions and the
  `capture` sidecar, so another member sees the item with a placeholder
  before the bytes land (§3).

### Identity and sessions

- Web: passkeys (WebAuthn) handled in the Worker, credentials in D1.
- Native: Sign in with Apple, exchanged for the same session token.
- Fallback: emailed magic link via Cloudflare Email Service.
- Session: opaque token in D1, cookie on web, bearer on native.
- Invite: owner mints a token stored in the SpaceDO; `/join/{token}` adds
  the signed-in user as a member and the DO records a `member.joined` event.

### Cost and limits that matter

- SQLite-backed Durable Objects are available on the free plan. Storage is
  5 GB total on free (unlimited on paid); per object the docs say 10 GB,
  with the FAQ saying 1 GB on free. A household event log is megabytes.
- R2 free tier is 10 GB of storage and a million writes a month; a few
  thousand photos fit. Egress is free on any tier.
- Workers Paid at $5 a month is the likely end state for the larger upload
  body cap and headroom, not for traffic.
- Alarms (one per DO) are reserved for a later "stale items" digest; nothing
  in v1 needs them. Note that alarms and timers prevent hibernation.

### Repository layout

```
property-tasks/
  wrangler.jsonc
  worker/      Worker entry, routes, SpaceDO, auth, blob handlers
  web/         the web app (framework per house style, see §8)
  shared/      event types, projection, filter query, fixtures
  apple/       Swift package (model, projection, sync) + SwiftUI app
```

Tests: `@cloudflare/vitest-pool-workers` for the DO (push, pull, snapshot,
idempotent retry, membership refusal), the shared fixture suite for the
projection, and Swift tests that load the same fixtures.
