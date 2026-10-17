# Prior-art survey — property task tracker (2026-10-17)

Idea: web + iOS + iPadOS + Android + Mac. Hierarchical, shared tracking of
property tasks (location > building > task > subtask), any node can become a
parent, nodes hold photos/text/docs/spreadsheets, every change has an
attributed audit log.

## Verdict

Nothing found that combines all of: arbitrary-depth tree, heterogeneous node
content, per-change attributed audit log, multi-person sharing, all five
platforms, household pricing. Every category below has a fixed 2–3 level schema
(property > asset > work order) or weak sharing/history.

## Closest matches by category

### Pro CMMS (functionally closest)
- MaintainX — location + asset hierarchies, work orders w/ photos, web+iOS+Android,
  data never deleted. Free tier: 5 photo work orders/month. Essential $20/user/mo.
  https://www.getmaintainx.com/pricing
- Limble — unlimited asset hierarchy on all tiers, photo capture, work request
  history, mobile app. No free tier; price via calculator. https://limble.com/pricing
- UpKeep — similar; no free plan.
- Atlas CMMS — self-hosted AGPL CMMS (web+mobile, Docker). https://github.com/auliaharvy/cmms-atlas

### Consumer home-maintenance apps (single home, appliance/reminder-centric)
- Minicastle (ex-Camelot) — issues w/ before/during/after photos, grouped by area
  or project, offline-first, cloud sync + web app for partner sharing. iPhone/iPad/
  Mac/visionOS, no Android. No audit log. https://apps.apple.com/app/id6751024112
- HomeZada (finance-heavy), Centriq (manuals/appliances; still active as of 2025),
  HomeBinder, Upkeepy, HomeKeep, Essentify, HomeRepairDiary (by room, photos).
  All flat or by-room, mostly iOS-only, little/no sharing or history.

### Construction punch-list / photo documentation
- Fieldwire — free: 5 users, 3 projects, photos, iOS/Android/web. Project-centric.
  https://www.fieldwire.com/pricing/
- CompanyCam — photos by project+location, timestamped/geotagged; ~$79/mo, contractor-oriented.
- Punch List Pro — floor > room > trade hierarchy, iPhone only.
- SiteMate — web/iOS/Android, location tagging, photo markup.

### Landlord property management (property > unit > work order; tenant-facing)
- DoorLoop, Avail, TenantCloud — maintenance requests with photos and history.
  Overkill, per-unit pricing.

### Self-hosted / open source
- HomeBox (Go+SQLite, web UI, items w/ images, locations/labels) — inventory, not tasks.
- DumbAssets (GPL-3, Docker) — asset > sub-component hierarchy, photos/receipts,
  maintenance alerts, single-PIN auth, no multi-user. https://github.com/DumbWareio/DumbAssets
- HomeCenter (MIT, Docker) — homes/vehicles/equipment, reminders, receipts.
- micasa — Go TUI, single home, no attachments/multi-user. https://github.com/cpcloud/micasa

### Generic hierarchical tools (DIY route)
- Notion — database with sub-items (nestable), relation to a Locations DB, files
  property, page history with editor attribution. Apps on every platform. Closest
  "exists today" answer, but no immutable audit log and not offline-first.
- Tana / Workflowy / Anytype — outliners; Anytype local-first + E2E sync but
  weak multi-user attribution.

## Differentiators left open
1. Any node can become a tree (no fixed schema).
2. Heterogeneous node payloads (image, text, doc, sheet) as first-class.
3. Append-only, attributed audit log per node.
4. Household/family sharing on all Apple platforms + Android + web.
5. Household pricing (CMMS is per-seat business pricing).

Note: verify Mac Catalyst status — Apple signalled deprecation at WWDC25 in
favour of SwiftUI multiplatform / iPad-apps-on-Mac.
