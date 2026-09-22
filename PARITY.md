# Parity with the web app

What each iOS screen does **not** yet do that its web counterpart does.

Written 2026-09-22 by reading both codebases. It answers the owner's
"make sure all current pages function as in the web app" with a checklist
instead of an impression.

## Scope — what "all pages" means

The web app has **70** tenant-scoped pages. This app is not going to have
70 screens, and the owner narrowed it explicitly: **calculator, exchange,
locations, and the admin panel**. Journal came along because auth needed
something real to render against. `ROADMAP.md` carries the same list.

So "all pages" here means the screens *we* have scoped. Anything outside
that list is not a gap; it is out of scope, and this document does not
enumerate it.

## How to read this

Two different questions get confused, so they are separate columns:

| | meaning |
|---|---|
| **Design applied** | palette, type scale and state treatments are on the screen, verified on device at DEFAULT text size |
| **Design complete** | also survives `DESIGN.md`'s own acceptance test — outdoors, arm's length, Dynamic Type at accessibility3 |
| **Functional parity** | does what the web page does |

As of 2026-09-22 **every screen is "applied" and none is "complete"** —
the acceptance test was run for the first time on the journal and it
failed (see *Design status* below). Do not let a screen's polished
appearance at default size stand in for the test.

A note on provenance, because it affects how much this document is worth:
`DESIGN.md` was authored by me, so auditing against it is not an
independent check. The device findings below are the peer's, made on
hardware I cannot see.

Every claim here was read out of source. Nothing below was observed
running, which is exactly the limit this document has and the device does
not.

---

## Calculator

Web `grain/calculator` (1705 lines) · iOS `Calculator/CalculatorView.swift`

Both clients consume the **same payload** — `src/lib/grain/calculator-payload.ts`
in agri-saas, served to the app by `GET /api/t/:slug/grain/calculator`.
That makes parity here measurable exactly: which payload fields does each
side render?

### Gap 1 — refusal text renders in English

`CalculatorModels.swift` decodes `netWorthUnavailableReason` but **not**
`netWorthUnavailableCode` or `netWorthUnavailableParams`. The payload's own
comments say what each is for:

- `netWorthUnavailableReason` — *"English, authored by the usecase — the
  FALLBACK for an unknown code"*
- `netWorthUnavailableCode` — *"Machine-readable reason, translated by the
  consumer when recognised"*

So the app shows the English fallback on a Bulgarian screen, every time net
worth cannot be computed — which is a normal state, not an edge case. The
web translates it (`CalculatorClient.tsx:497-499`) via the shared helper
`explainRefusal(code, params, fallbackEnglish, translate)` in
`src/lib/grain/uncertainty.ts`:

```
if (isKnownRefusalCode(code)) return translate(`refusal.${code}`, params ?? {});
return fallbackEnglish;
```

Four codes are known and already have Bulgarian strings in
`messages/bg.json` under `refusal`:

```
NO_MARKET_PRICE
MIXED_COST_CURRENCY
RENT_CURRENCY_UNRECORDED
COST_PRICE_CURRENCY_MISMATCH
```

**To close:** decode both fields, carry the four strings, apply the same
fallback rule. Keep the fallback — an unknown future code must still say
something rather than nothing.

---

## Exchange

Web `exchange` (1159) + `exchange/my-listings` (394) + `exchange/my-interests`
(213) · iOS `Exchange/ExchangeView.swift` (254) + `ListingDetailView.swift` (137)

**Structurally ahead of the web, and right.** Three web pages are three
tabs — Обяви / Моите обяви / Моите заявки — which is the correct mobile
shape, not a shortfall.

### Gap 2 — no search, no filter, no pagination

The web drives the listings query with `q`, `minTonnes`, `maxTonnes`,
`limit` and `cursor`. `ExchangeAPI.listingsPath` sends **no query string at
all**, so the app shows an unfiltered first page with no way to search and
no way to reach page two.

On a board that grows, "no way to reach page two" degrades silently: the
screen keeps looking correct while holding less and less of the truth.

### Gap 3 — cannot create a listing

The web posts to `/exchange/listings`. The app has `createInquiry` only, so
**Моите обяви is read-only** — you can see your listings but not make one.
The endpoint exists; the client does not call it.

### Note — the inquiry write is still unexercised

`POST /exchange/inquiries` creates a production row **and emails another
tenant's admins**. It has never been fired. That is a deliberate standing
decision, not an oversight; it is recorded here so nobody closes it by
accident while working through this list.

---

## Locations

Web `locations` (225) + `locations/[locationId]` (1342, with
`apiPost`/`apiPatch`/`apiDelete`) · iOS `Locations/LocationsView.swift` (59)
+ `ParcelMapView.swift` (218) + `SchematicParcelMap.swift`

### Gap 4 — read-only

The web location detail creates, edits and deletes; the app renders. For
field work that is arguably the right split — drawing a parcel boundary on
a phone in a field is not obviously a feature anyone wants — but it is a
difference, and it should be a **decision recorded in `ROADMAP.md`**
rather than an omission nobody has named.

The schematic renderer and the MapKit toggle are ahead of the web here,
which has no schematic view at all.

---

## Journal

Web `journal` (1785, `apiPost`/`apiPatch`) + `journal/[id]` (904,
`apiDelete`) · iOS `Journal/JournalListView.swift` (126) +
`NewEntryView.swift` (76)

### Gap 5 — there is no entry detail

`JournalListView` has a `.sheet` for composing and **no `NavigationLink`**.
The list is terminal: an entry cannot be opened, so it cannot be read in
full, corrected, or deleted. The web has a 904-line detail page.

This is the largest functional gap in the app. The journal is the legally
filed record — the ДНЕВНИК PDF is generated from exactly these rows — and
an operator standing in a field cannot check what was recorded.

### Gap 6 — the list is capped at 50 with no paging

`JournalAPI.listPath` is `"\(base)?limit=50"`. No cursor, no "load more".
A tenant past 50 entries silently sees a truncated history, and nothing on
screen says so.

---

## Admin — Phase 4, not started

Web `admin/members` + `admin/farm-profile` · iOS `ComingSoonView(title: "Админ")`
(the only remaining stub, and a deliberate one)

Server side is verified present and reachable from the app:

```
GET  /api/t/:slug/admin/members                       list
GET  /api/t/:slug/admin/members?view=invites          pending invites
POST /api/t/:slug/admin/invites                       invite   <- NOT under members
POST /api/t/:slug/admin/members/:id/deactivate
POST /api/t/:slug/admin/members/:id/reactivate
     /api/t/:slug/admin/farm-profile
```

Two things checked to ground rather than assumed, because either would
have blocked the phase:

1. **The admin root has a CSRF guard** — `middleware.ts:245` rejects
   cross-site requests to admin mutations via `Sec-Fetch-Site`. URLSession
   sends that header not at all. The guard's documented allowlist includes
   `null/undefined: Old browser or non-browser client (allowed, since auth
   token is still validated by auth middleware)`, so native passes **by
   design, not by luck**.
2. **These routes use `requirePermission('admin.members')`**, not the
   plain context helper the other screens use. That path is
   `requirePermission → getTenantCtx → getSessionOrThrow → auth()`, and
   `src/auth.ts:863` falls back to `resolveBearerSession()` for native —
   the same chain the journal already proves end to end.

Two shapes the screen has to get right:

- **Membership status has THREE values** — `ACTIVE`, `INVITED`,
  `DEACTIVATED`. A two-state control mislabels INVITED as one of the
  others, and "has my invite actually gone out?" is the main reason
  somebody opens this screen.
- **A READER-role user gets 403**, and that is a real state — the web app
  has viewer accounts. It needs a screen that says so, not an empty list
  that reads as "no members".

---

## Design status

Owned by the peer, on hardware. Recorded here so the two halves of the
owner's request sit in one place.

`DESIGN.md` ends: *"Take a phone outside, in sun, and read the journal at
arm's length with Dynamic Type at accessibility3. Everything above is
downstream of that."* Run for the first time on 2026-09-22, on the
journal — the most-worked screen — it **fails**:

- navigation title truncates (`Земеделски…`)
- the entry-type chip wraps to three lines; the chip shape assumes short
  text and `Внасяне на препарат` at AX3 is not short
- the date breaks mid-word (`септемвр / и`) — a broken word, not a wrap
- chip and date share an `HStack` that does not reflow, so they wrap
  independently and fight
- roughly two entries fit on screen

`DESIGN.md` §5 (accessibility) is essentially unstarted, measured across
the whole app: 2 `.accessibilityLabel`, 2 `.accessibilityElement`, 1
`.accessibilityHint`, zero `accessibilityReduceMotion`, zero
`colorSchemeContrast`.

---

## Suggested order

1. **The AX3 failures**, because `DESIGN.md` says everything is downstream
   of that test and it is currently red. A screen that cannot be read
   outdoors fails before any parity gap matters.
2. **Journal entry detail (Gap 5)** — the largest functional hole, on the
   legally-filed record.
3. **Calculator refusal text (Gap 1)** — small, self-contained, and it
   removes English from a Bulgarian screen.
4. **Exchange create + filters (Gaps 2, 3)**.
5. **Phase 4 admin**, against the contract above.
6. **Record the Locations read-only split (Gap 4) as a decision**, or close
   it. Either is fine; leaving it unnamed is not.
