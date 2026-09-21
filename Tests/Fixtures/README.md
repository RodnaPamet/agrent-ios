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
