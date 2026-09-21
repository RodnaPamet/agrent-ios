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

### What it exercises

| | row 0 (WHEAT) | row 1 (SUNFLOWER) |
|---|---|---|
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
