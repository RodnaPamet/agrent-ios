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
- ~~The journal list was counted at "at least 10" of an expected 11.~~
  **CLOSED 2026-09-21: 11, confirmed on screen by the owner.** Matches the
  production count exactly (`INPUT_APPLICATION` 9 + `ACTIVITY` 2), so the
  database prediction and the rendered list agree.

## Decisions locked

1. **MapKit, not MapLibre.** No SPM map dependency. Parcel geometry renders as
   `MapPolygon` overlays on Apple's basemap. Consequence accepted: the phone
   will not look pixel-identical to the web, and Apple's rural Bulgarian
   imagery is weaker than the tile route the web uses.

   **AMENDED 2026-09-21 — a second, schematic layer, toggled by one button.**
   Alongside the MapKit view, a *tileless* mode that draws the parcels
   directly from their coordinates: flat ground, minimal path strokes, parcel
   fills carrying state, labels. Rendered in SwiftUI (`Canvas` or `Path`) from
   the same GeoJSON, normalised to the view bounds.

   This is not decoration. It is the answer to the consequence accepted above:

   - **It needs no tiles, so it works with no signal.** A field with no
     coverage is the case the cache exists for, and Apple Maps cannot be
     relied on there. The schematic layer has nothing to fetch.
   - **Every colour is ours**, so it stays legible in direct sun where a
     satellite basemap washes out — see `DESIGN.md`, "Who this is for".
   - **Rural Bulgarian imagery quality stops mattering** in this mode.

   The visual spec is the `Локации` artboard in the design canvas, and it is
   binding rather than indicative — the values below are taken from it:

   ```
   ground            #6E6A52
   path (major)      #8C8770, 10px
   path (minor)      #7E7A63, 5–6px
   parcel, sown      fill #3E8E4F @ 0.55, stroke #2C6E3A 2.5px
   parcel, fallow    fill #9A9560 @ 0.55, stroke #6F6B3E 2.5px dashed 7/5
   label             #FFFFFF, 14px, weight 600
   ```

   **The toggle is one button with two states, not a menu.** Two modes only;
   a third would make it a picker and it stops being simple. Remember the
   choice per user. Sensible default: schematic, since the offline case is
   the one that bites — but that is the owner's call, not mine.

   Parcel fill still encodes state, so the accent-colour constraint in
   `DESIGN.md` holds in both modes: the app's accent cannot be green.
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
- **A query string is never safe on iOS — on requests the app SENDS.**
  CFNetwork writes the full request URL, query included, to the unified log
  from Apple's own subsystems — the app
  cannot suppress it. Our logging is clean (verified: zero hits for JWT
  prefixes, bearer keys, body substrings, ids), but eight Apple lines carry the
  query anyway. **Bodies and the `Authorization` header are NOT logged.** So any
  future endpoint passing an id or anything personal must use a header or a
  body, never a query parameter. Bites Phase 2 filters and Phase 3 parcels.

  **Scope — read this before applying the rule.** It covers requests made
  through the networking stack. It does NOT cover the OAuth callback, which is
  also a URL carrying a secret in its query: `ASWebAuthenticationSession`
  returns it in-process, CFNetwork never sees it, and a live sign-in measured
  zero hits for it. Applied unscoped, this rule condemns the
  PKCE-over-custom-scheme design the app is built on, and would push a future
  session to replace a supported iOS pattern with something worse.
- ~~**The sign-in path has never run WITH logging attached.**~~ **CLOSED
  2026-09-21 16:48** by a real sign-out and sign-in from the owner. The auth
  path ran with logging present and the leak check over the live code exchange
  is clean — zero hits in our subsystem AND across the whole process for the
  JWT prefix, `accessToken`, `refreshToken`, `Bearer`, `code_verifier`,
  `code_challenge`, the `bg.agrent.app://` callback, the handoff cookie and
  live body substrings. (One `code=` match process-wide is UIKit's own
  `_UIViewServiceHostSessionErrorDomain Code=4`, not the OAuth code.)
  Verified by EXECUTION, not reading — which matters here because this is the
  one path where a leak would be a real compromise: the callback carries the
  auth code, the exchange body carries `code` + `code_verifier`, and its
  response carries both tokens.

  Also established: **the callback URL does NOT reach the unified log.**
  `ASWebAuthenticationSession` hands it back in-process and CFNetwork never
  sees it, so the CFNetwork query-string exposure noted ABOVE is correctly
  scoped to ordinary outbound requests and does NOT extend to the OAuth
  callback.
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

`GET/POST /api/t/:slug/exchange/listings` · `/listings/[listingId]` ·
`/inquiries` · `/my-listings`

**Measured 2026-09-21, because this line was wrong:** the unprefixed
`/api/exchange/listings` returns **404**. The routes are tenant-scoped in the
URL — but the DATA is not: `ExchangeListing` is a GLOBAL table with no
`tenantId` and no RLS, deliberately, because cross-tenant readability is the
product. The slug is for auth and context only, and `isOwn` is the sole marker
separating your rows. `ExchangeInquiry` is the opposite: RLS-protected and
private. The two must not share a UI that treats them alike.

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
