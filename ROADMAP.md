# Agrent iOS — UI roadmap

Scope set by the owner on 2026-09-21: **calculator, exchange, locations, admin**
— not the full web experience. The web app has 70 operator pages; this plan
covers four areas and deliberately leaves the rest on the laptop.

## Where we are

Shipped and proven end to end on a device simulator (2026-09-21):

| | |
|---|---|
| Auth | PKCE → system browser → code exchange → Keychain → bearer on `/api/t/**` |
| Journal | list renders live tenant data |
| Build | `xcodegen generate` → `xcodebuild` clean, 0 errors |

**Known-unverified, carried deliberately** — do not let a green build launder these:

- `LogEntryType`'s five added cases (`SEEDING`, `TRANSPLANTING`, `IRRIGATION`,
  `LAB_TEST`, `GRAZING`) and the removal of `OTHER`. The live tenant holds only
  `INPUT_APPLICATION` and `ACTIVITY`, so nothing has ever exercised them. Set
  equality against `enums.prisma` was checked by READING. First real `Сеитба`
  entry is the first live test.
- `APIClient`'s status switch has no `304` case. URLSession converts 304→200
  below us today, so it is unreachable — but `default:` would render
  "Server error 304." on a screen whose data is fine. One line, not yet taken.
- The journal list was counted at "at least 10" of an expected 11. Not settled.

## Decisions locked

1. **MapKit, not MapLibre.** No SPM map dependency. Parcel geometry renders as
   `MapPolygon` overlays on Apple's basemap. Consequence accepted: the phone
   will not look pixel-identical to the web, and Apple's rural Bulgarian
   imagery is weaker than the tile route the web uses. Revisit only if parcel
   work proves unusable on Apple's base layer.
2. **Admin = `members` + `farm-profile` only.** `sso`, `scim`, `roles`,
   `api-keys`, `rbac` stay on the laptop. Nobody configures SAML on a phone.
3. **Read-caching everywhere, no offline writes.** Every screen serves
   last-known data when offline and says so. Writes still require connectivity.

## Phase 0 — Foundations — DONE (2a8f6f1..d6d8798)

Shipped and proven on the simulator: five-tab shell, `os_log` diagnostics with
the three prohibitions enforced by SHAPE, `ResponseCache` + `LoadState`, and
the journal refactored onto it with a staleness banner. All four mutation
proofs ran; see the commits for each.

**Carried forward as gaps, neither blocking:**

- **The cache is unbounded.** No size cap, no entry limit, no TTL — only
  explicit `remove`/`removeAll`. It lives in `Library/Caches`, which iOS purges
  under storage pressure, so it cannot fill a disk. But that cuts both ways:
  the purge is the system's decision and can land right before an operator goes
  into a field. Bound it before Phase 3 puts map and parcel data in there.
- **No staleness ceiling.** Six-month-old data is served with its age shown.
  The age display is the mitigation and is probably right for a person who can
  judge — but it is a decision, not an oversight, and Phase 3 should revisit it
  for parcels.
- **A query string is never safe on iOS.** CFNetwork writes the full request
  URL, query included, to the unified log from Apple's own subsystems — the app
  cannot suppress it. Our logging is clean (verified: zero hits for JWT
  prefixes, bearer keys, body substrings, ids), but eight Apple lines carry the
  query anyway. **Bodies and the `Authorization` header are NOT logged.** So any
  future endpoint passing an id or anything personal must use a header or a
  body, never a query parameter. Bites Phase 2 filters and Phase 3 parcels.
- **The sign-in path has never run WITH logging attached.** Logging landed 25
  minutes after the only sign-in; every relaunch since has used an existing
  token. Verified by construction, not execution. Closing it needs a real
  sign-out and sign-in.
- `.debug` lines (request start, cache hit/miss/write) never persist to disk —
  good for privacy, but they can only be watched live, not audited with
  `log show`.

### What it built (for reference)

- **Navigation.** The app is currently `if signedIn { JournalListView }`. Needs
  a `TabView`: Journal · Calculator · Exchange · Locations · Admin (exactly 5,
  the iOS limit before "More").
- **Diagnostics.** The app has **no logging at all** — no `os_log`, no `print`,
  in any path. That cost a full day twice over: `no_handoff` surfaced as a raw
  JSON blob in a browser sheet, and a 404 surfaced as a blank screen. Both
  times the truth existed only in the OS network log. `os_log` through
  `APIClient` and `AuthClient`, subsystem `bg.agrent.app`, is foundation work.
- **`ResponseCache`.** Disk-backed, keyed by tenant + path. A `Loaded<T>` phase
  carrying `.fresh` / `.stale(Date)` so every screen can show age. Retrofitting
  this into five screens later is strictly worse than building it now.
- **Refactor `JournalStore` onto it** — proves the pattern on a screen already
  known to work, so a cache bug cannot hide behind a new feature.

## Phase 1 — Calculator

Smallest UI, no writes, no map. Proves the cache layer on a read-only surface.

**Server work first — the endpoint does not exist.** `/grain/calculator` is a
Server Component that calls the usecase directly (`force-dynamic` + a server
read *is* the data path). There is no API route. Needs
`GET /api/t/:slug/grain/calculator` returning the payload the client island
already receives — the page maps it deliberately, so mirror that mapping rather
than the usecase's 30-field row.

Client: one formatted report. `CalculatorClient.tsx` is 1,175 lines of web
layout; the native version is a fraction of that.

## Phase 2 — Exchange

First real write path beyond the journal. All endpoints exist.

`GET/POST /api/exchange/listings` · `/listings/[listingId]` ·
`/inquiries` · `/my-listings`

- Listings list + detail
- Create inquiry (write — reuse the journal's `Idempotency-Key` discipline)
- My listings / my interests

Cross-tenant GLOBAL tables — no tenant scoping on these routes, unlike
everything else in the app. Read `exchange.prisma`'s header before touching it.

## Phase 3 — Locations

Biggest lift, best native payoff — GPS and field use are what a phone is for.

`GET /api/t/:slug/locations` · `/locations/[id]` · `/locations/[id]/parcels` ·
`/parcels/[parcelId]`

- Location list → detail
- Parcels as `MapPolygon` overlays (MapKit)
- Parcel detail
- Read-cache matters most here: this is the screen that gets opened in a field
  with no signal.

Explicitly **out** for now: cadastre import, lease register, parcel merge,
clusters, basemap tile download. Those are desk workflows.

## Phase 4 — Admin (subset)

`GET /api/t/:slug/admin/members` · `/members/[membershipId]` ·
`/members/[membershipId]/deactivate` · `/admin/farm-profile`

- Members: list, invite, deactivate — the "someone needs access and I'm not at
  my desk" case
- Farm profile: the БАБХ identity block

Nothing else from the admin panel.

## Sequencing note

Phase 1's server work is Linux-side and can run in parallel with Phase 0's
client work — different repos, different machines, no collision.
