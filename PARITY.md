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

**UPDATED 2026-09-22, later the same day.** The AX3 failures are fixed
and gaps 1, 2, 4, 5 and 6 are closed. What remains is gap 3 and Phase 4
admin. Each section below carries its own status; this header no longer
speaks for all of them.

The original line read: *"every screen is applied and none is complete"*.
That was true when written and is kept because the reason it was written
still holds — a screen's polished appearance at default text size is not
the acceptance test, and treating it as one is how the AX3 failures
survived a design pass.

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

**CLOSED 2026-09-22.** `netWorthUnavailableCode` and `…Params` are
decoded, `RefusalText` applies `explainRefusal`'s rule, and the fallback
is kept.

Two things found on the way that the original entry did not anticipate:

1. **Three of the four strings INTERPOLATE.** This app had written its
   own four sentences under a comment claiming they came from the web.
   They had not, and they lost `{commodity}` and both currency codes —
   so they were not merely differently worded, they were missing
   information. The comment was the worse half: asserting a provenance
   converts a reader's check into a skip. Corrected in place, strings
   replaced verbatim.
2. **`{commodity}` is a canonical SLUG, and the web renders it raw** —
   "Няма налична пазарна цена за **wheat**", a Bulgarian sentence with
   an English slug in it. The app deliberately DIVERGES: the wording is
   the web's, the substitution is not. `{commodity}` goes through
   `CommodityName.canonical`.

---

## Exchange

Web `exchange` (1159) + `exchange/my-listings` (394) + `exchange/my-interests`
(213) · iOS `Exchange/ExchangeView.swift` (254) + `ListingDetailView.swift` (137)

**Structurally ahead of the web, and right.** Three web pages are three
tabs — Обяви / Моите обяви / Моите заявки — which is the correct mobile
shape, not a shortfall.

### Gap 2 — no search, no filter, no pagination — CLOSED 2026-09-22

Search on submit, tonnage bands, and "Покажи още". Three decisions worth
recording because none is obvious from the endpoint:

- **Only the UNFILTERED first page is cached.** `CachedResource` keys on
  the path, so every search term would mint its own entry — and an
  operator offline in a field would be shown whatever they last searched
  for, presented as the board.
- **Search fires on SUBMIT, not per keystroke.** A round trip per
  character on a connection this app assumes is bad, and every keystroke
  is also a line in the unified log.
- **A filtered no-result says "Няма съвпадения", not "Няма активни
  обяви".** The second is a claim about the market rather than about the
  search, and it would send an operator away from a board that has
  offers on it.

Two defects found while doing it: the price rendered `51.13 EUR` on a
Bulgarian screen — the raw wire string, printed under a comment arguing
that reformatting needs `Double` and would round. The premise was right
and the conclusion was not: `Decimal` is exact. And `quantityTonnes`
parsed with `Decimal(string:)` and no locale, which reads "12.5" as 125
where `.` groups.

### Gap 3 — cannot create a listing — STILL OPEN

The web posts to `/exchange/listings`. The app has `createInquiry` only, so
**Моите обяви is read-only** — you can see your listings but not make one.

**Deliberately not built on a guess.** A listing is published to every
tenant in the platform, so the write needs its schema read rather than
inferred — field names, which are required, the `side`/`kind` enums, and
whether the decimals go out as numbers or strings. That last one is not
inferable: the exchange READS are strings because those routes have no
DTO, and `grain/costs` sends numbers because it has one.

When it is built it ships **unfired**, like `createInquiry`. The owner
authorising one cost row on his own books does not extend to posting an
offer other farms can see.

### Note — the inquiry write is still unexercised

`POST /exchange/inquiries` creates a production row **and emails another
tenant's admins**. It has never been fired. That is a deliberate standing
decision, not an oversight; it is recorded here so nobody closes it by
accident while working through this list.

---

## Locations

Web `locations` (225) + `locations/[locationId]` (1342, with
`apiPost`/`apiPatch`/`apiDelete`) · iOS `Locations/LocationsView.swift` (59)
+ `ParcelMapView.swift` + `SatelliteParcelMap.swift` (two modes, one map view)

### Gap 4 — read-only — CLOSED 2026-09-22 as a DECISION

Recorded in `ROADMAP.md` rather than built. The geometry feeds subsidy
and lease paperwork, and neither map is an instrument for defining a
boundary — the simplified one draws a field as its bounding box, which
is deliberately not its border.

The gap was never "the app cannot edit"; it was that nobody had said so.

**Updated 2026-09-24.** The claim that this app was ahead of the web
here reversed with the schematic's deletion. The two clients converge
instead: the target button that walks the parcels is the web's
«Намери моето поле», adopted here, and the simplified/precise toggle has
no web counterpart.

---

## Journal

Web `journal` (1785, `apiPost`/`apiPatch`) + `journal/[id]` (904,
`apiDelete`) · iOS `Journal/JournalListView.swift` (126) +
`NewEntryView.swift` (76)

### Gap 5 — there is no entry detail — CLOSED 2026-09-22

`JournalListView` has a `.sheet` for composing and **no `NavigationLink`**.
The list is terminal: an entry cannot be opened, so it cannot be read in
full, corrected, or deleted. The web has a 904-line detail page.

This is the largest functional gap in the app. The journal is the legally
filed record — the ДНЕВНИК PDF is generated from exactly these rows — and
an operator standing in a field cannot check what was recorded.

### Gap 6 — the list is capped at 50 with no paging — CLOSED 2026-09-22

Cursor paging with an explicit "Покажи още", and the header count now
reads "Показани N" while more exists — the old copy claimed N was the
tenant's history, which was wrong for any farm past fifty entries.

Pages are de-duplicated by id: a cursor is positional, so an entry
created between two fetches shifts the window and can repeat a row. A
diary showing one entry twice is not cosmetic — it reads as a register
that recorded the same operation twice.

Later pages are NOT cached. Page one is the offline case; caching page
three would give an offline reader a history with holes in it,
presented as continuous.

**It also refined a rule rather than breaking it.** `ROADMAP.md` said
"never a query parameter", which read literally forbids a cursor. The
rule drew the wrong line: CFNetwork logs the whole URL *including the
path*, and the tenant slug is already in every path. A query parameter
is not more exposed than a path segment. The honest rule is "nothing
personal in a URL at all" — an opaque cursor is not, a free-text search
term can be.

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

- **Membership status has FOUR values** — `INVITED`, `ACTIVE`,
  `DEACTIVATED`, `REMOVED`. This document said three; `REMOVED` was
  missing, and the only place the full set was written outside the
  schema was the web's status-variant map. "Has my invite actually gone
  out?" is the main reason somebody opens this screen, so INVITED
  rendered as any of the others answers it wrongly.
- **There are SIX roles** — `OWNER`, `ADMIN`, `EDITOR`, `READER`,
  `AUDITOR`, `MECHANISATOR`. The live tenant returns two.
  `MECHANISATOR` is the restricted machine-operator persona; a `switch`
  that omits it silently inherits READER's "view everything".
- **Neither had a Bulgarian vocabulary on EITHER client.** The web
  rendered the raw enum, so a Bulgarian admin read "OWNER" and "ACTIVE"
  on an otherwise translated screen — the calculator's "wheat" again, on
  a different screen. Canonical now at `authEnums.*`.
- **A READER-role user gets 403**, and that is a real state — the web app
  has viewer accounts. It needs a screen that says so, not an empty list
  that reads as "no members".

---

## Design status — the AX3 failures are FIXED

Owned by the peer, on hardware. Recorded here so the two halves of the
owner's request sit in one place.

`DESIGN.md` ends: *"Take a phone outside, in sun, and read the journal at
arm's length with Dynamic Type at accessibility3. Everything above is
downstream of that."* Run for the first time on 2026-09-22, on the journal — the most-worked
screen — it **failed**. All five are fixed; the list is kept because the
failures are more instructive than the fixes:

- navigation title truncates (`Земеделски…`)
- the entry-type chip wraps to three lines; the chip shape assumes short
  text and `Внасяне на препарат` at AX3 is not short
- the date breaks mid-word (`септемвр / и`) — a broken word, not a wrap
- chip and date share an `HStack` that does not reflow, so they wrap
  independently and fight
- roughly two entries fit on screen

`DESIGN.md` §5 (accessibility) was essentially unstarted — 2
`.accessibilityLabel`, 2 `.accessibilityElement`, 1 `.accessibilityHint`,
zero `colorSchemeContrast`. Done: every row speaks from its VALUES rather
than its rendered text (a `·` separator was being read as "middle dot"),
and `colorSchemeContrast` is honoured where colour carries meaning.

**Regressed 2026-09-24.** The schematic map exposed one element per
parcel with a compass bearing, and it has been deleted. `MKMapView`
builds no accessibility tree, so both maps are now a single unlabelled
rectangle to VoiceOver; the target button announces the field it moves
to, which is a button speaking rather than a map that can be explored.
Per-parcel elements over MapKit is owed work, not a closed gap.

**No `reduceMotion`**, deliberately: the app has zero animations, so
reading the environment to gate nothing would be an accessibility feature
in name only.

---

## What is left

1. **Gap 3 — create a listing.** Blocked on the write schema, by choice
   rather than by circumstance. Ships unfired when built.
2. **Phase 4 admin**, against the contract above. The only remaining
   stub screen, and it now has a home in the app menu rather than a tab.

Everything else on this list is closed. The order the original version
suggested held up: the AX3 failures first, because a screen that cannot
be read outdoors fails before any parity gap matters.
