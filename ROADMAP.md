# Agrent iOS — UI roadmap

Scope set by the owner on 2026-09-21: **calculator, exchange, locations, admin**
— not the full web experience. The web app has 70 operator pages; this plan
covers four areas and deliberately leaves the rest on the laptop.

## How changes land

**Branch → PR → CI → merge.** Not direct pushes to `master`.

Everything before 2026-09-21 went straight to `master` — 24 commits, no pull
requests, no automated gate. The history is clean and each commit is
separately revertible, but nothing was ever checked by anything except the
author running the tests locally.

CI (`.github/workflows/ci.yml`) runs on every PR and every push to `master`:

| | |
|---|---|
| Guards | no committed credentials; `Agrent.xcodeproj` and `Agrent/Info.plist` stay untracked |
| Generate | `xcodegen generate` — the project is derived, so CI builds it the way a developer does |
| Verify | `CFBundleURLSchemes` contains `bg.agrent.app` — the silent failure that only shows at sign-in |
| Test | full suite on a simulator resolved at runtime, not pinned |
| Warnings | fails if more than the 2 known `ISO8601DateFormatter` ones appear |

The credential guard is not hypothetical: a GitHub PAT was pasted into this
file during development. It was caught before it was committed, but only
because someone looked, and this repo is public.

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
- ~~`notes` was displayed nowhere, so nobody knew what was in it.~~
  **CLOSED 2026-09-22 by the device.** The field is rich-text HTML on both
  ends, and the first screen to render it printed `<p>` tags at the operator.
  Of the entries in the live tenant carrying notes, **2 of 2** contain HTML —
  read out of the app's own `ResponseCache`, not assumed from the schema.
  Fixed both directions: `RichText` (#13 read, #14 write).

  **The lesson is worth more than the bug.** A field's format is not known
  until a screen displays it. `JournalRow` renders title, type, date and
  status and never touched `notes`, so the app carried a wrong assumption
  about a column for as long as it had no reason to look. Every remaining
  phase adds screens that display fields nothing has displayed before —
  parcels, members, listings — and each one is the first real test of what
  that field actually holds. Green CI cannot find this class; only rendering
  it can.
- ~~`APIClient`'s status switch has no `304` case.~~
  **CLOSED — it was already closed, and this entry was stale.** `0871eaf`
  took the line ("a 304 is a success, not Грешка от сървъра (304)"). Traced
  end to end 2026-09-23: `case 304 → APIError.notModified`, `CachedResource`
  serves the cached copy as `.fresh` rather than `.stale` — the server has
  just confirmed it is current — and only the 304-with-nothing-cached case
  surfaces, as «Данните не са променени.»
  **The lesson is the staleness, not the line.** This list exists to stop a
  green build laundering unverified work, and an entry that describes a gap
  which no longer exists laundering it just as effectively — it spends the
  reader's attention on a fixed problem and lends false weight to the
  entries beside it. Checking one cost four greps.

- ~~Five `LogEntryType` cases and the removal of `OTHER` were verified by
  READING `enums.prisma`; nothing has exercised them.~~
  **Superseded 2026-09-23.** Still unexercised, and it no longer matters the
  same way: the enum is now `LenientDecodable`, so an unrecognised value
  costs one row a neutral «Друг вид» chip instead of blanking the whole
  ДНЕВНИК. The frequency argument favoured strict — the server enum has
  changed once, at inception — and the asymmetry beat it. See
  `LogEntryType`'s header.

- ~~Sign-in rendered raw JSON and English.~~ **CLOSED 2026-09-23,** and it
  was found while checking the entry above rather than by looking for it.
  `AuthError.server` carried the whole response body and `friendly` returned
  it unchanged, with `error.localizedDescription` as the fallback — so the
  first screen a farmer sees could print `{"error":{"code":…}}` or
  "Could not connect to the server." under a Bulgarian heading. Both are
  defects the rest of the app had already fixed; sign-in was simply never
  revisited when they were.
- ~~The journal list was counted at "at least 10" of an expected 11.~~
  **CLOSED 2026-09-21: 11, confirmed on screen by the owner.** Matches the
  production count exactly (`INPUT_APPLICATION` 9 + `ACTIVITY` 2), so the
  database prediction and the rendered list agree.

## Decisions locked

1. **MapKit, not MapLibre.** No SPM map dependency. Parcel geometry renders as
   `MapPolygon` overlays on Apple's basemap. Consequence accepted: the phone
   will not look pixel-identical to the web, and Apple's rural Bulgarian
   imagery is weaker than the tile route the web uses.

   **AMENDED 2026-09-24 — THREE layers, cycled by one button.** The owner
   saw the satellite view and asked for it in the schematic's place; asked
   again, once the schematic was actually gone, to have it back as a third
   option. The button therefore cycles rather than toggles:

   1. **Точни очертания** — true outlines with holes, over imagery, with the
      vegetation indices. The default, by the owner's choice.
   2. **Опростена** — one rectangle per parcel, its bounding box, over
      imagery, coloured sown or fallow. No index tiles: Earth Engine clips
      them to the true shape, so under a box the colour stops short of the
      corners and reads as missing data.
   3. **Схема** — the 2026-09-21 layer below, unchanged.

   The four bullets below still hold, and now hold for ONE of three modes
   rather than for the default. That is the real change: a farmer with no
   signal has to reach the schematic deliberately instead of opening onto
   it. The stale banner is what speaks first, and it says the data is old
   rather than that the map cannot draw.

   **2026-09-21 — a second, schematic layer, toggled by one button.**
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
   choice per user.

   **REVERSED 2026-09-24 (owner): the PRECISE satellite map opens by
   default.** The schematic is still available, third in the cycle, but it
   is no longer what a farmer lands on. The paragraph below records what the
   first frame used to guarantee and no longer does.

   **Schematic opens by default** (owner, 2026-09-21). The map's first frame
   is therefore the one that cannot fail: no tiles to fetch, nothing to time
   out, no grey squares. A farmer opening Локации with no signal sees their
   fields. MapKit becomes the deliberate second look — for geographic
   context, which is when you actually want the imagery — rather than the
   thing you wait for and then discover is unavailable.

   It also means the app's slowest, most network-dependent screen no longer
   has a network-dependent first paint.

   Parcel fill still encodes state, so the accent-colour constraint in
   `DESIGN.md` holds in both modes: the app's accent cannot be green.
2. **Admin = `members` + `farm-profile` only.** `sso`, `scim`, `roles`,
   `api-keys`, `rbac` stay on the laptop. Nobody configures SAML on a phone.
3. **Read-caching everywhere, no offline writes.** Every screen serves
   last-known data when offline and says so. Writes still require connectivity.
4. **Every English word an operator can see comes from the server.** Measured
   2026-09-22 over every user-visible string constructor in the app: the only
   non-Cyrillic literals are `Agrent`, a `·` separator, `%` and a currency-code
   fallback. There is no hard-coded English on any screen.

   The English that DOES reach the phone arrives in an error body, and today it
   arrives raw:

   ```
   Грешка от сървъра (404): {"error":{"code":"NOT_FOUND","message":"…"}}
   ```

   `readableBody` bounds the body to 300 characters but does not extract
   `.message`, so the operator gets a Bulgarian prefix followed by undecoded
   JSON. The server side is tracking 382 user-facing English messages authored
   below the i18n guards' reach; the client half of the fix is a `code` →
   Bulgarian map, and it belongs in **`Agrent/Core/UserMessage.swift`**, beside
   the mapping that is already there — not in a new module, because a second
   place to answer one question is how the next session finds the wrong one.
   `ConflictEnvelope` already decodes `{ error: { code, message } }` for 409,
   so the shape is proven; it just needs generalising. Waiting on the server's
   code list, which lands in batches.

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

**Locations is READ-ONLY, deliberately** (decision, 2026-09-22). Parcel
geometry is the input to subsidy and lease paperwork, and an edit made on a
phone in a field — with a fingertip, on a schematic whose squares are drawn 5×
larger than life and are not the real shape — is not an edit anyone should be
able to make by accident. The map exaggerates on purpose so it can be read in
sun; that same exaggeration makes it the wrong instrument for defining a
boundary. Recorded here as a choice so a later session does not read the
missing buttons as unfinished work and add them.

Explicitly **out** for now: cadastre import, lease register, parcel merge,
clusters, basemap tile download. Those are desk workflows.

## Phase 5 — Tasks and cost input (2026-09-22)

Задачи took Админ's tab slot (owner): five slots exist before iOS
collapses the rest into "More", and Админ was spending the most valuable
one on a placeholder that said "use the web app". Shipped: task list,
task detail, status change, and cost entry on the calculator.

### Response shapes are PER-ROUTE. There is no house style.

Everything below was measured on this tenant, not inferred:

| route | shape |
|---|---|
| `tasks` list | 11 keys — a projection, no `tenantId`, no `priority` |
| `tasks/:id` | 33 keys — relations, `_count`, `sla` |
| `tasks/:id/status`, real change | 25 keys — bare row |
| `tasks/:id/status`, REPLAY | 32 keys — relations |
| `grain/costs` envelope | `{rows, totalCount, truncated}` |
| `journal` envelope | `{rows, nextCursor}` |

Six variants. The write's two are the dangerous pair: the fatter one is
served on the REPLAY path, which only runs when the connection is bad.
Nothing decodes that response — the caller reloads instead.

**Read the ROUTE, not the model. Then read it again for the ELEMENT.**
The tasks list projection was found by running it and watching a screen
say "неочакван формат", hours after that rule had been written into
`PagedResponse` and applied to the envelope but not to the element inside
it. A lesson learned in one position does not transfer itself.

### Decimals are strings on some endpoints and numbers on others

    grain/costs        amount          → 1        NUMBER  (maps via toDto)
    exchange/listings  quantityTonnes  → "12.5"   STRING  (no DTO)

One database type, two wire types, decided per route by whether it maps
through a DTO. `WireDecimal` accepts both — not defensive vagueness, the
actual contract. Ask per endpoint; a rule derived from one is wrong on
the next.

### Money is always at the currency's scale

`1.00` arrives as `1` and the farm's net worth rendered as `12 691,8 EUR`
where the books say `12 691,80`. Both ends of this: the server drops the
trailing zero and `Num.text`'s `0...2` precision dropped it again. Money
formats at exactly 2; areas and tonnages keep `0...2`.

### A warm cache is not evidence

`imputedLandCharge.totalAmount` is nullable in production and was
modelled non-optional, so the whole calculator payload failed to decode.
`CachedResource` fell back to a 21-hour-old copy exactly as designed, and
the screen said "последно обновено преди 21 часа" — which reads as a
network problem. The calculator had been showing "няма какво да се
изчисли" against a farm with a €12,691 wheat position, and a fresh
install would have shown an error.

**The cache is correct and it is a bad oracle.** When a screen is stale,
find out WHY before believing what it shows.

### Writes: the rule is per-usecase, not global

Idempotency is honoured by four usecases — journal, farm-task,
field-operation, inventory. Grain was not one, so a cost create could not
be safely retried at all: POST twice and the books carry two rows. The
client therefore never auto-retries a cost, and reports a TIMEOUT as
*unknown* rather than as failure — telling an operator it failed invites
the one action that makes it worse. (The server has since added
exactly-once to both grain creates; the client's caution stays until that
is verified from here.)

`setTaskStatus` is the opposite: a replay returns 200 because the server
compares STATE. The `Idempotency-Key` is not the mechanism there — a
brand-new key behaves identically — and the resolution text is part of
the compared state, so a retry that re-trims it stops being a replay.

### Every status change is ONE-WAY

`OPEN` is entry-only; nothing returns to it. No UI may imply otherwise,
and a test plan that assumes a change can be undone is wrong before it
starts.

## Phase 4 — Admin (subset)

`GET /api/t/:slug/admin/members` · `/members/[membershipId]` ·
`/members/[membershipId]/deactivate` · `/admin/farm-profile` ·
`POST /api/t/:slug/admin/invites`

**`/admin/invites` is NOT under `/members`**, and this list said it was. An
invite is its own resource at the admin root. A phone screen built against the
shape written here would have 404'd on the one action the screen exists for,
and "invite" is the whole "someone needs access and I'm not at my desk" case.

- Members: list, invite, deactivate
- Farm profile: the БАБХ identity block

**Membership has THREE statuses, not two:** `ACTIVE`, `INVITED`,
`DEACTIVATED`. A UI that models this as a boolean cannot render a pending
invite — it shows as either a member who is not one, or as nothing at all.
Both are wrong on the screen whose job is to answer "who can get in".

**READER role gets a 403 on these routes**, so the refusal needs a real screen
rather than a generic error. An operator who cannot administer the farm should
be told that, not shown "Грешка от сървъра (403)".

Nothing else from the admin panel.

## Sequencing note

Phase 1's server work is Linux-side and can run in parallel with Phase 0's
client work — different repos, different machines, no collision.
