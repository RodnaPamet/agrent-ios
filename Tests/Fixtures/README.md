# Fixtures

## `calculator-sample.json`

A calculator payload **with rows**, for building and testing the Phase 1 client.

`GET /api/t/agrent/grain/calculator` against production returns an empty
payload — 616 bytes, `rows: []`, `seasonId: null`. That is **correct
behaviour, not a bug**: the `agrent` tenant has zero Seasons, zero Plantings
and zero CropPlans (counted directly in the production database). There is
nothing to report, so nothing is reported.

So the wire cannot exercise `rows`, and every element type inside the payload
is unobservable in production today.

### How this was produced, and why it matters

**Not hand-written.** It is the output of the real
`buildCalculatorPayload()` — the same mapper the web page and the API route
both call — run over a synthetic usecase result. A hand-written fixture would
reproduce whatever the author got wrong by *reading* the server, which is
precisely the failure this is meant to protect against.

Two defects in the first attempt prove the point, and both were caught only by
printing the derived fields next to the inputs:

- `cashCostCurrencies: ['BGN', 'UNKNOWN_RENT_CURRENCY']` — the sentinel's value
  is `'UNKNOWN'` (`cost-metrics.ts:156`), not the constant's *name*. The filter
  silently did nothing.
- `netWorth` was never set, so `netWorthUncertainty()` returned `refused` for
  **both** rows — by accident, looking exactly like intent.

### v2 — four defects, all in the INPUT, none in the mapper

The first version had **four**. Every one was in the synthetic input I wrote;
the mapper faithfully rendered each into something plausible.

| | defect | caught by |
|---|---|---|
| 1 | sentinel written as `'UNKNOWN_RENT_CURRENCY'`; its value is `'UNKNOWN'` | printing derived fields |
| 2 | `netWorth` unset → both rows `refused` **by accident** | printing derived fields |
| 3 | row 1 carried row 0's `standingCropAreaHa` (12.34ha) beside its own `areaDca` (45) | the iOS peer, reading it |
| 4 | `uncertainty` hand-written UPPERCASE; the real vocabulary is lowercase | investigating (3) |

**Defect 4 matters beyond this file**: it made the payload look like it carried
*two casing conventions*, and a reader could reasonably have "fixed" the server
to match. It does not. `UNCERTAINTY` (`uncertainty.ts:31-44`) is one lowercase
vocabulary — `exact`, `atLeast`, `atMost`, `allocated`, `partial`, `refused` —
and `per-area.ts:111` / `break-even.ts:91` assign from it like everything else.

**The root cause of 2 and 4 was a cast.** The emitter said
`as unknown as CommodityNetWorthRow`, which disabled the one instrument that
would have caught both: `UncertaintyState` is a literal union, so `'EXACT'` is
a type error, and a missing required `netWorth` is too. A fixture generated
through a real mapper is only as trustworthy as its inputs, and casting the
inputs throws away the check.

v2 therefore: **no casts on the seed**, and `perArea`/`breakEven` are COMPUTED
by the real `computePerArea` / `computeBreakEven` rather than hand-written, so
a row cannot carry an area its own figures disagree with.

### What it exercises

| | row 0 (WHEAT) | row 1 (SUNFLOWER) |
|---|---|---|
| area | 12.34 ha → 123.4 dca | 4.5 ha → 45 dca (its own) |
| `netUncertainty` | `exact` | `refused`, with code + params |
| `priceObservedAt` | `"2026-09-18"` — **yyyy-mm-dd** | `null` |
| `showProduceRent` | `false` | `true` |
| `costCurrencyCodes` | `["BGN"]` | `["BGN"]` — sentinel filtered |
| `rentCurrencyUnknown` | `false` | `true` |

### Two traps it demonstrates

1. **Two date spellings in one payload.** `generatedAt` is
   `"2026-09-21T15:04:09.618Z"` (full ISO, always fractional seconds);
   `priceObservedAt` is `"2026-09-18"` (date only). Neither is a Swift `Date` —
   both are `string` server-side. Typing `priceObservedAt` as `Date` fails the
   **whole** payload decode, not just that field.
2. **`perArea.areaDca` is already rounded** (`round2`, `per-area.ts:82`). The
   web client separately computes an *unrounded* `haToDca()` for display, so
   two values of that name exist with different results. Use the payload's.

Regenerate by re-running the emitter against `buildCalculatorPayload` in the
`agri-saas` repo — never by editing this file, which would make it a
hand-written fixture again.

## `locations-list.json` / `locations-parcels.json`

**Synthetic, and deliberately so.** The real endpoints return the owner's
actual field boundaries with cadastral identifiers attached, and this repo is
public. Publishing them is the owner's decision to make, and the default is no.

What is NOT invented is the STRUCTURE. It was measured off the live wire on
2026-09-21 and reproduces what was found there:

- `/locations` is a **bare array**, not an envelope. The fixture also carries
  the seven unmodelled fields (`tenantId`, `retentionUntil`, `deletedAt` …) so
  the tests prove `Decodable` ignores them rather than assuming it.
- `/locations/{id}/parcels` is an **object** `{locationId, bounds, parcels}`.
- `bounds` is `[minLon, minLat, maxLon, maxLat]` — **longitude first**.
- Geometry nests four deep: `coordinates[polygon][ring][point][lon, lat]`.
- Parcel `SYNTH-1` has **one polygon with five rings** — an outer boundary and
  four holes — matching the owner's real parcel `15655-19`. An earlier plan
  for this fixture had a single hole; production disagreed.
- Parcel `SYNTH-3` has `geometry: null`, exercising the server's fail-soft
  path, which production does **not** currently exercise on this tenant.

Coordinates are in central Bulgaria (~42.5°N 25.1°E) rather than the real farm
(~43.1°N 24.2°E, Pleven): inside the country so latitude/longitude bounds
assertions are meaningful, and nowhere near the real boundaries.

## `exchange-threads.json` / `exchange-thread.json`

**Synthetic, and there is no other option.** These are exchange MESSAGES —
private conversations between two farms — and a real one is not publishable
in a public repo, whoever's it is. Nothing was captured off the wire: no
production thread was opened, read or written to produce them (the standing
rule that every messaging write ships built and unfired, agrent-ios#114).

What is NOT invented is the SHAPE. It is taken from agri-saas
`src/generated/openapi.json` (`ExchangeThreadSummary`, `ExchangeThread`,
`ExchangeMessage`, and the `listExchangeThreads` envelope) and checked against
the usecase that builds the payloads,
`src/app-layer/usecases/exchange-messaging.ts`. Every key the schemas list as
`required` is present, including the ones that are present-and-null. Names,
ids and texts are made up; the ids follow no real format beyond being
strings, and nothing here is JWT-shaped (the CI credential scan covers
fixtures).

The hard cases, each on purpose:

| case | where |
|---|---|
| tombstone — `deleted: true`, `body: null` | `exchange-thread.json`, `msg_synthetic_3` |
| all THREE speakers (agri-saas #1323): me (`mine`), a colleague (`fromMyFarm`, not `mine`), the other side (neither) | `msg_synthetic_2` / `msg_synthetic_5` / `msg_synthetic_1` |
| `senderName` (agri-saas #1399): a name on the other side's messages and on mine, and `null` on the colleague's — the fallback caption's case | `msg_synthetic_1`, `_2`, `_3`, `_4` / `msg_synthetic_5` |
| two rows on ONE listing — two people, as from one buyer farm (#1323: a thread is per inquirer person) | `thr_synthetic_1` and `thr_synthetic_4`, both `lst_synthetic_1` |
| a role this build does not know (`broker`) → `.unknown` | `exchange-threads.json`, `thr_synthetic_3` |
| `sellerDisplayName: null` | `thr_synthetic_2` and `thr_synthetic_3` |
| `olderCursor: null` (the start is on this page) | `exchange-thread.json` |
| `hasUnread: true` and `false` | `thr_synthetic_1`, `_3` / `thr_synthetic_2`, `_4` |
| `closed: true` | `thr_synthetic_2` |
| `blocked: true` | `exchange-thread.json` |
| a multi-line body, and one with `<` that must render verbatim | `msg_synthetic_2`, `msg_synthetic_4` |
| a decimal-string quantity with a fraction (`"12.5"`) | `thr_synthetic_2` |
| `lastMessageAt` with and without non-zero milliseconds | `thr_synthetic_1` and `thr_synthetic_2` |

The summary carries nothing about the inquirer, so the fixture cannot — and
does not — say that `thr_synthetic_1` and `thr_synthetic_4` come from the same
buyer farm; that is the story the synthetic ids (`usr_synthetic_buyer`, a
second buyer) tell, not a field. The sender ids are opaque strings like the
server's, and the colleague is `usr_synthetic_admin`: the seller farm's admin
answering for the listing's creator, who is the reader (`usr_synthetic_creator`).

`olderCursor` is null because the UI test seam matches on the PATH alone: a
`before=` request would be answered with this same page, and a cursor here
would send the conversation after an older page that is the newest one again.
`thr_synthetic_1` is the thread both files share, and `FixtureCatalogue`
serves the conversation under that id — `FixtureSeamTests` holds the two
against each other.

`listingRegionName` is in English because that is what the server sends — the
listing's `regionName` is the English oblast name.

## The screenshot harness's fixtures (agrent-ios#115)

`admin-members.json`, `admin-farm-profile.json`, `insurance-leads.json`,
`risk-analysis-{holes,simple,nogeom}.json`, `dashboard-ag.json`,
`dashboard-task-trend.json`, `dashboard-field-briefing.json`,
`trends-prices.json`, `trends-news.json`, and **row 1** of
`exchange-listings.json`.

**Synthetic, all of them.** They exist because `A11yShots` now launches
through the UI test seam (`AGRENT_UITEST_FIXTURES`) instead of against the
production tenant, and the screens it photographs from the menu — Админ, Риск,
Табло, Новини — had no payload, so each capture would have been a 501. Nothing
was captured off the wire to make them and no production route was called.

What is NOT invented is the SHAPE: each file is written against the Swift
model that decodes it (`Membership`, `FarmProfile`, `ParcelRisk`,
`InsuranceLeads`, `AgDashboard`, `FarmTaskTrend`, `FieldBriefingPayload`,
`PricesResponse`, `NewsResponse`), and `FixtureSeamTests` puts each through the
app's own decode for that route. The models were themselves measured off the
wire when they were written, so this is one step removed from the server —
weaker than the calculator fixture's provenance, and said so here.

Rules held, because this repo is public:

- **Names** are invented and read as such («Иван Фикстуров», «Мария
  Примерова», «Примерна кооперация»). E-mail addresses are on `.invalid`, the
  TLD reserved never to resolve. News links are on `news.example.invalid`.
- **The ЕГН is ten zeros.** Month 00 is not a date, so it is nobody's number.
  The harness still never taps «Покажи»; the capture shows dots. The ЕИК is
  nine zeros and the УРН is spelled `URN-SYNTHETIC-0001`.
- **No geometry.** The Риск readings are per-parcel numbers for the three
  parcels `locations-parcels.json` already holds, keyed by their ids.
- **Nothing JWT-shaped**, which the CI credential scan checks anyway.

The cases, each on purpose:

| case | where |
|---|---|
| the LAST active owner (no deactivate action, #99) and an admin (the positive control) | `admin-members.json` rows 0 and 1 |
| `INVITED` with `name: null` and a role `MECHANISATOR`; a `DEACTIVATED` row | rows 2 and 3 |
| dates with and without fractional seconds | `admin-members.json`, `risk-analysis-simple.json` |
| all three Риск levels plus `unknown` with `configured: true` (a parcel with no boundary) | `risk-analysis-*` |
| a reading 30 days older than its `generatedAt` — past `Staleness.concerning` | `risk-analysis-simple.json` |
| a parcel already asked about (`par_simple`) | `insurance-leads.json` |
| a journal row with a date-only `occurredAt`, and one with null | `dashboard-ag.json` |
| two price series in one unit/currency group and a third, pointless one in another (USD) | `trends-prices.json` |
| `unit: "t"` — the EC grain feed's spelling, not `EUR/t`: Табло prints `currency/unit`, so `EUR/t` rendered «EUR/EUR/t» | `trends-prices.json` |
| a news summary carrying the feed's attribution line (`cleanedSummary` strips it), a null summary, and a category this build does not name | `trends-news.json` |
| a listing that is NOT yours — the only way to reach «Съобщение до продавача» | `exchange-listings.json` row 1 |
| `eikVerification: "DISPUTED"` (agri-saas#1355) — the longest status line and the only `warning` one, so the capture shows the wrap and the contrast that can fail; the other three values and unknown/absent are unit tests (`EikStatusTests`) | `admin-farm-profile.json` |

`exchange-listings.json` row 0 is still the scrubbed production row the file
was captured with; `ExchangeModelsTests` reads it through `.first`. Row 1 was
appended for the harness and is invented from end to end. Its `lat`/`lon` is
a point inside Ruse oblast, not any farm's location.

`trends-prices.json` and `trends-news.json` answer ONE query each —
`commodity=wheat&range=3m` and `limit=50` with no category — because the
query names the commodity and the category, and a path-only match would draw
wheat under «Царевица». See `FixtureCatalogue.byPathAndQuery`.

## A field operation and its parcel lines (agrent-ios#138)

`task-detail-fieldop.json`, `field-operation-detail.json`, and **row 2** of
`tasks-list.json` (`tsk_fixture_fieldop`, «Пръскане срещу плевели»).

**Synthetic, all of them**, added so A11yShots can photograph a task with its
parcel lines (`ONLY=08b-task-parcel-lines`). Nothing was captured off the
wire, and no line was ever marked to make them: a real mark deducts stock and
files a ДНЕВНИК entry, and the first one is the owner's.

What is NOT invented is the SHAPE. `field-operation-detail.json` follows the
spec's `FieldOperationDetail` and `OperationParcel` and, where the spec is
thin, the route itself (`getFieldOperation`): the raw Prisma row of each line
with its five includes, Decimal columns as STRINGS (`doseValue`,
`parcel.areaHa`), the location's parcels with the geometry
`locations-parcels.json` gives the same three ids (copied, not invented again —
the task map draws them since agrent-ios#177; before that they carried
`geometry: null`, since nothing drew them), and the line's `version` — which
the route sends and the spec's schema does not list.
`task-detail-fieldop.json` follows `WorkItem`, like the task it shadows.

| case | where |
|---|---|
| all three line states — PENDING (version 0), DONE and SKIPPED (version 1) | `field-operation-detail.json` lines 0–2 |
| a target note on a skipped line, a null water rate, a null `completedBy` | lines 2, 2, 0 |
| an `areaHa` of `"5"` with no fractional part | line 2 |
| the assignee is the operator, the viewer (`auth-me.json`) the owner — so the buttons show because the OWNER may write, not because they are assigned | `task.assigneeUserId` |
| a task map with a parcel to do (four holes), a done one, and a skipped one with no outline — two drawn, one noted under the map | `parcels`, against lines 0–2 |

The parcels are the three `locations-parcels.json` holds, by id and name; the
product is the dashboard's «Примерен хербицид». The line ids (`opl_synthetic_*`)
follow no real format.

## Any other task's parcels (agrent-ios#177)

`task-detail-task.json`, `task-parcels.json`, and **row 1** of
`tasks-list.json` (`tsk_fixture_2`, «Заявка за анализ на почвата»).

**Synthetic, both**, added so A11yShots can photograph a task that is not a
field operation with its parcels (`ONLY=08d-task-parcels`).

- `task-parcels.json` follows the spec's `TaskParcelsResponse` (agri-saas
  #1410): `{ parcels: [{ id, name, geometry }] }`, ordered by name. The three
  parcels are `field-operation-detail.json`'s, copied: SYNTH-1 with four
  holes, SYNTH-2, and SYNTH-3 with `geometry: null`. So the map draws two
  parcels and notes the third, and the list marks SYNTH-3 «без очертания».
- `task-detail-task.json` is `task-detail-fieldop.json` made into a plain
  `TASK`: no key (as its list row has none), no operation, and three `PARCEL`
  links shaped as the spec's `TaskLink`. The app reads no `links`; they are
  there so the detail says what the parcels route answers.
- `task-detail-task.json` also holds two `comments`, shaped as the spec's
  `TaskComment` (agrent-ios#225), with PLAIN-TEXT bodies, as the server
  stores them (`sanitizePlainText`): the operator's, with a newline that
  must stay a line break, and the owner's, with a literal `<` that must
  stay a `<`. Nobody posted them: the first real comment is the owner's.

## `auth-me.json`: the fixture person's farm and flags (agrent-ios#179)

**Synthetic.** `tenant` is the fixture world's one farm («Синтетично
стопанство», slug `agrent`, the slug every fixture path was recorded under).
It is there because `/me` always carries the block, nullable but present, and
`FarmStore` reads it for a first sign-in. Under the seam the farm is opened
directly and never remembered, so this only names it.

`featureFlags` turns `social.farm-registration` on, so A11yShots can
photograph «Добави стопанство» and the wizard's first steps
(`ONLY=17-farm-wizard`). It never taps «Готово»: that would create a real
farm. Under the seam it would get a 501, but the suite doesn't rely on that.

## `me-farms.json`: the fixture person's farms (agrent-ios#179, stage 3)

**Synthetic.** Two farms, oldest first as the contract orders them. The first
is the fixture world's one farm («Синтетично стопанство», slug `agrent`,
`OWNER` — the farm and role `auth-me.json` names, as the spec says `farms[0]`
always is). The second is invented, with the fixture person as a
`MECHANISATOR`, so Профил shows a list with a tick, two roles and a farm to
switch to.

The first entry must stay slug `agrent`: `FarmStore` CLOSES an open farm the
list does not have, and under the seam the open farm is always `agrent`.

The second farm has no fixtures of its own. A11yShots never taps it; a tap
under the seam would open a farm whose every path is `NO_FIXTURE`, which is a
true report of a fixture world with one farm in it.
