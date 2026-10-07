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

**UPDATED 2026-09-30.** Gap 3 was closed by #30 on 2026-09-22 and this
document was never told; it says so now. Gap 7, exchange messaging, is
new and closed the same day it was opened.

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

Web `exchange` (683) + `exchange/my-listings` (367) + `exchange/my-interests`
(192) + `exchange/threads` (121) + `exchange/threads/[threadId]` (321) · iOS
`Exchange/ExchangeView.swift` (601) + `ListingDetailView.swift` (209) +
`NewListingView.swift` (269) + `ExchangeInboxView.swift` (141) +
`ConversationView.swift` (417) + `MessagingStores.swift` (576) +
`ExchangeMessaging.swift` (370). Line counts re-read 2026-09-30; the old
header's (1159/394/213 and 254/137) had drifted.

**Structurally ahead of the web, and right.** The web's four sections are
four sections here — Обяви / Моите обяви / Моите заявки / Съобщения — which
is the correct mobile shape, not a shortfall. Four do not fit a phone's
segmented control (measured: they ask for 464pt where an iPhone 17 has
370), so on a phone they are a scrolling row of chips, the parcel map's
precedent; see `ExchangeSectionPicker`.

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

### Gap 3 — cannot create a listing — CLOSED 2026-09-22, recorded 2026-09-30

Built, wired, and **ships unfired**: `NewListingView` behind «Нова обява»
on Моите обяви, posting through `ExchangeAPI.createListing` (#30, bccf95b).
This entry went on saying STILL OPEN for eight days because #30 landed
after this document was written and nothing in that PR touched it — the
laundering `ROADMAP.md` warns about, in the other direction: a closed gap
reading as open is also a document that stopped being checked.

What it said while open, kept because it is why the write took the shape
it did: the web posts to `/exchange/listings`, and the app had
`createInquiry` only.

**Deliberately not built on a guess.** A listing is published to every
tenant in the platform, so the write needs its schema read rather than
inferred — field names, which are required, the `side`/`kind` enums, and
whether the decimals go out as numbers or strings. That last one is not
inferable: the exchange READS are strings because those routes have no
DTO, and `grain/costs` sends numbers because it has one.

When it is built it ships **unfired**, like the inquiry did. The owner
authorising one cost row on his own books does not extend to posting an
offer other farms can see.

### Note — every messaging write is unexercised from development

The app no longer SENDS inquiries (removed 2026-10-01, see Gap 7); it still
lists the ones already sent under «Моите заявки». `POST /exchange/inquiries`
was never fired from development while it existed.

The same decision covers every messaging write (Gap 7), each of which the
OTHER farm sees:

- **open a thread** — a row in the listing owner's inbox at once, unread
  and empty, before a word is written; there is no way to delete it;
- **send** — a message, plus a bell row and an email to exactly the people
  who can open the conversation (agri-saas #1323; it was every owner and
  admin of the other farm);
- **close** — either party; **block** and **unblock** — the listing owner
  only, and a block covers every listing between the two farms (still
  farm-to-farm after #1323; person-level is agri-saas #1314);
- **retract** — a tombstone the other side sees where the message was;
- **read** — fired by OPENING a conversation, not by a button, and it
  moves the reader's OWN pointer to the server's now (per person since
  #1323; it used to move every member's). So
  even viewing a real conversation from development is a production write,
  and none has been opened. Under the UI test seam every one of these is
  answered 501, which is the backstop, not the rule.

### Gap 7 — no messaging — CLOSED 2026-09-30

Web `exchange/threads` (121) + `exchange/threads/[threadId]` (321) · iOS
`ExchangeInboxView.swift`, `ConversationView.swift`, `MessagingStores.swift`,
`ExchangeMessaging.swift`, `ExchangeMessagingModels.swift`, and the nine
operations in `ExchangeAPI.swift` (agrent-ios#114).

**FULL PARITY, by the owner's ruling (#114):** the inbox as Борса's fourth
section, the conversation with scrollback, reply, «message the other party»
from a listing, close, block (the listing owner only) and unblock, and
retract your own message — the ninth operation, `DELETE
/exchange/messages/{id}`, which the issue's list of eight missed and the
web offers as «Премахни».

**The one-shot inquiry is GONE from the app — a deliberate divergence
(owner, 2026-10-01).** It first stood beside messaging, as on the web,
which renders both on someone else's listing. The owner then ruled it
redundant: a conversation does what an inquiry did and goes on, so the
listing offers one way to contact the other farm, «Съобщение до …».
Inquiries already sent are still listed under «Моите заявки», read-only.
The web keeps both; this app does not.

Read out of agri-saas at 11b00118 — the spec, `exchange-messaging.ts`,
`ThreadsClient.tsx`, `ThreadClient.tsx` — not observed running. No real
conversation has been opened (see the note above).

**Conversations are private to PEOPLE, not the farm — adopted 2026-10-06
(agri-saas #1323, the owner's rulings on #1298).** Read out of agri-saas
at 7af43f9: `ExchangeMessage`, `ExchangeThread`, `ExchangeThreadSummary`
and the nine paths in `openapi.json`, cross-checked in
`exchange-messaging.ts`. What changed for this app:

- **Three speakers.** `ExchangeMessage` gained `senderUserId` and
  `fromMyFarm`. `mine` is me, the PERSON (it meant "my farm");
  `fromMyFarm` and not `mine` is a colleague — e.g. the seller admin
  answering for the listing's creator; neither is the other side
  (`MessageSpeaker`). A colleague's bubble has its own caption, «Колега от
  стопанството», and its own style: mine is solid gold, a colleague's a gold
  tint with a gold edge — both trailing, my farm's side — and the other
  side's a neutral tint, leading. All three pairs measured in
  `PaletteTokenTests`. VoiceOver says the speaker first. Both new fields
  are decoded tolerantly: absent means a server from before #1323, where a
  colleague's message already arrived as `mine`.
- **«Вие» is the person.** Every messaging string was re-read. Where the
  server checks the person — the audience, retract
  (`MESSAGE_NOT_SENDER`), the read pointer — the text says «Вас». Where it
  still checks the farm — your own listing (`THREAD_OWN_LISTING`), the
  block — it says the farm. The inbox's role chips became «Наша обява» /
  «Наше запитване» (were «Вашата обява» / «Вие питате»): an admin on a
  colleague's listing does not own it, and a buyer-side admin on a
  colleague's thread is not the one asking.
- **The block is unchanged on the server** (farm-to-farm, every listing of
  the blocking farm, every person at the blocked one) until #1314. The app
  says that scope as what happens and never as «блокирахте това
  стопанство», which would read as "this person" and turn false when #1314
  lands.
- **Unread is per person.** `mine`, `unreadCount` and `hasUnread` moved
  without changing type. The badge logic holds unchanged; what it means
  changed: a colleague reading a thread no longer clears my badge, and a
  colleague's reply now raises it — so a reply from a colleague arriving
  on screen marks read like the other side's (`Arrival.fromSomeoneElse`).
- **Several threads per buyer farm.** A thread is per (listing, inquirer
  PERSON), so a listing owner may see several rows on one listing, and a
  buyer-side admin a colleague's beside their own. The summary carries the
  listing and nothing about the other person — deliberately on the seller
  side (the inquiry contact-reveal gate) — so the app cannot say WHO. It
  says what is true: «Един от N разговора по тази обява» on each such row.
  Never merged.
- **404, not 403,** for anyone outside the audience, a colleague
  included. A 404 on a conversation is its own state, «Разговорът не е
  достъпен», with both possibilities («между други хора от стопанството или
  вече да не съществува») — not the error state and its retry. It clears
  what was shown, stops polling, drops the thread from the badge and is
  announced to VoiceOver; a write's 404 asks the conversation once to
  confirm.

**Server follow-ups (none invented client-side):**

- **A sender name on `ExchangeMessage`.** Only the opaque `senderUserId`
  ships, so a colleague is «Колега от стопанството», never by name, and two
  colleagues read alike. A display name for same-farm senders (no
  contact-reveal concern inside one farm) would let the caption name them.
- **Something to tell sibling inbox rows apart.** `ExchangeThreadSummary`
  has nothing per inquirer. An opaque, stable per-listing ordinal (or the
  thread's `createdAt`, so a client can number «разговор 1, 2» stably)
  would separate them without revealing the buyer; the last message's
  preview would also do it.
- **The person-level block, #1314** — the block strings will need
  re-reading when it lands.

**Owner decisions (2026-09-29, asked directly):**

- **An unread badge on Борса** — the number of conversations with
  something unread, refreshed at launch, on every return to the app and
  whenever the inbox loads — plus the count in the «Съобщения» label and
  «Ново» on each row. The web has only the row badge and the bell. When
  Борса is off the bar, the app menu's row carries the count.
- **Mark read on the first load AND again whenever a poll brings a message
  from the other farm while the conversation is on screen.** The web marks
  once per page mount, so a reply read on screen leaves «Ново» behind.
  Failures are swallowed — the seam answers 501, and a failed mark is
  nothing a farmer can act on.
- **Confirmation before retract** (irreversible) **and before block** (it
  covers every listing between the two farms, which the web neither
  confirms nor says). Close stays one tap: the next message reopens it.
  Unblock is not confirmed; it undoes itself.

**Decisions taken in the work:**

- **Nothing is cached on disk.** The web keeps `/exchange/threads` out of
  its persistent cache on purpose — another farm's words must not outlive a
  lost phone — and `ResponseCache` survives sign-out and is keyed on a
  hard-coded tenant. Inbox and conversation are network-only, held in
  memory; offline is an honest «Няма интернет връзка.», not yesterday's
  copy. This is the one exchange read that does not follow the house's
  cache-first rule, and a test holds it.
  Until #134 that was only true of `ResponseCache`: URLSession's default
  disk cache could still store a thread's 200 in `Cache.db`. It is now off
  app-wide (`NoURLCache`), which is what makes "nothing on disk" true.
- **Polling at the web's cadence** — 5 s for an open conversation, 30 s for
  the inbox — but ONLY while the screen is on screen and the app active;
  locked or backgrounded, nothing polls. A 429 waits the server's
  `Retry-After` instead of the interval, never less than the interval.
- **Wording is side-neutral wherever the side is unknown.** The payloads
  carry no listing side, and «Вие продавате» / «Блокирай купувача» are
  false on every BUY listing. So the inbox says «Наша обява» / «Наше
  запитване» (farm-level since #1323, see above), the action is «Блокирай» / «Отблокирай», and the blocked notices
  name neither buyer nor seller. On the listing the side IS known:
  «Съобщение до продавача» on a SELL listing, «Съобщение до купувача» on a
  BUY one. The button is not tied to the listing being active — it is the
  way back to a conversation on a listing that has closed.
- **The web's localisation defects are not copied:** the commodity through
  `CommodityName` (the web prints the slug), the region in Bulgarian
  (`BulgarianRegion.name(english:)` — the inbox row has no code, so the
  English is resolved through the bundled geometry), «т» (the web prints a
  Latin «t»), times through `BgDate` in the phone's zone (the web: en-GB,
  in UTC, two to three hours early), and a Bulgarian error state.
- **4000, not 8000.** The spec says `maxLength: 8000`; the usecase refuses
  anything over 4000 UTF-16 units after sanitising and trimming. The
  composer counts the server's way — «👍🏽» is four — and shows a counter
  only near the limit.
- **`body` is plain text**, rendered verbatim: never markdown, never HTML.
  A tombstone keeps its place and reads «Съобщението е премахнато».
- **Sending:** one `Idempotency-Key` per (conversation, exact text), kept
  across retries and dropped on any 201 — the web sends none, and its Send
  button accepts a second click while the first is in flight. The draft
  stays until the 201; there is no optimistic bubble; the conversation is
  refetched after. A timeout says the outcome is unknown and that sending
  again is safe, rather than «not sent». A 429 pauses the FARM's message
  budget (60 a minute, every colleague) and the composer says until when;
  nothing is ever sent automatically. `reopened` clears the closed notice.
- **Merging, not replacing.** A poll merges the newest page into what is
  loaded, by id, so scrollback survives it — the web loses messages from
  the middle of a long conversation after loading older ones. One failed
  poll does not replace the conversation with an error, as the web's does.
- **The interim read race rule:** `POST …/read` takes no body and moves the
  pointer to the server's now, so it can mark a message nobody saw. Until
  the server accepts `{upTo}`, a mark whose `readAt` is after the newest
  message shown is followed by one refetch.
- **Write affordances are hidden from roles that cannot write** (READER,
  AUDITOR; a MECHANISATOR has no Борса at all) — the composer, the actions,
  «Премахни» and the listing's button. The server's 403 is still rendered:
  `role` is the oldest membership's, and custom roles make it unreliable.
- **Retract says what failed** when it fails; the web shows its SEND
  failure. A message retracted from scrollback becomes a tombstone where it
  is, where the web leaves it readable until the screen is reopened.
- **A blocked inquirer cannot press Send.** The web lets them, and the
  server refuses with `THREAD_BLOCKED` after spending the farm's budget.
- **Scrolls to the newest message** on open and when one arrives — the
  first animation in this app, so Reduce Motion turns it into a jump. The
  web does no scroll management.

**Not built, deliberately:** the bell and the email (the notification
list is its own screen, and it does not exist on iOS); inbox paging past
the server's first hundred (the web ignores `nextCursor` too); a draft or
send key that survives leaving the conversation.

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

**Updated 2026-09-24.** Still ahead, and by more: three map modes where
the web has one. The schematic survives as the third, and the simplified
rectangles have no web counterpart either. Traffic runs the other way
too — the target button that walks the parcels is the web's «Намери моето
поле», adopted here.

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

### Farm profile — editable since 2026-10-01, ported from the web/server plan

The profile was read-only on iOS (#28, #111). It is now editable, and that is
a PORT, not a new design: the write path was agreed with the agri-saas backend
and already shipped there — agri-saas#1141 (web editor + usecase) and #1145
(`PUT /admin/farm-profile` documented). The web page
`src/app/t/[tenantSlug]/(app)/admin/farm-profile/page.tsx` is the spec for the
fields, their order, labels, hints and save behaviour; the route's zod schema
is the spec for limits. No separate written iOS plan exists in agri-saas
(confirmed by both backend sessions).

What the client must get right, read from the route and usecase:

- **Merge semantics since agri-saas#1181** (fixing #1176): an ABSENT field
  is left alone and an explicit null (or blank) clears. Before that an absent
  field was nulled. The app still reads, merges the edits and PUTs every
  writable key with explicit nulls — correct under both. The request is
  documented now (`UpdateFarmProfileRequest`, #1178).
- **ЕИК is read-only and never sent** (agri-saas#1352, enforced by P3.9 —
  merged as #1355, e9ec42574; client since 2026-10-07). The PUT refuses a
  body whose `eik` DIFFERS from the stored one — null included, which would
  clear it — with 400 `FARM_PROFILE_EIK_NOT_EDITABLE`; as merged, an
  unchanged echo is a no-op (#1352's plan refused the key outright, and the
  client was built to that stricter reading). The ЕИК is written only by
  Agrent staff verifying the farm's identity claim (P3.4/P3.9). So the body
  carries exactly TWELVE keys (`FarmProfileText.writable` + `sizeHa` +
  `grainProduced`), and absent leaves the stored ЕИК alone under #1181
  (`Object.hasOwn` in `upsertFarmProfile`). The editor shows the ЕИК
  read-only with «ЕИК се променя само след проверка от екипа на Agrent.» —
  iOS wording: agri-saas `messages/bg.json` has none for P3.4/P3.9. The code
  maps to a Bulgarian `UserMessage` in case an older payload trips it. The
  409 reload (`FarmProfileRebase`) takes the stored ЕИК and never carries a
  draft one into the body.
- **Verification state is shown** (agri-saas#1355, client since
  2026-10-07). `FarmProfile.eikVerification` is `NONE | PENDING | VERIFIED |
  DISPUTED`, read-only and derived on the GET from the farm's own claims,
  precedence VERIFIED > PENDING > DISPUTED (`deriveEikVerification`, read
  in the usecase, not taken from the summary). Beside the read-only ЕИК on
  the page and in the editor (`EikStatus`): NONE «Непроверен», PENDING «В
  процес на проверка», VERIFIED «Проверен» with a tick, DISPUTED «Не съвпада
  със съществуващ запис — свържете се с екипа на Agrent.» — iOS wording,
  `bg.json` has none; DISPUTED is `warning`, never `error`, and a test holds
  it free of accusatory words, as the spec demands. Decoded leniently:
  absent, null or an unknown value shows nothing. NONE without a number
  shows nothing; PENDING/DISPUTED show with or without one, since `eik` is
  written only at verification. **Server gap:** the PUT answers
  `project(row)` without the derived status, so its response always says
  `NONE`; the store keeps the status it held before the save (a save cannot
  move it) — agri-saas#1358.
- **`admin.manage` on GET and PUT** — OWNER and ADMIN. The edit action shows
  only over a profile the GET returned.
- **The response can differ from the request** (trim, `sanitizePlainText`,
  grain de-duplication, Decimal(12,3) rounding), so the screen shows what the
  server returned and says what moved.
- **A negative `sizeHa` is a 400** from zod, not a stored null as the summary
  says — the usecase's null branch is unreachable over HTTP.
- **Optimistic lock** (agri-saas#1184, client since 2026-10-01). GET
  returns `version` (0 = no row yet; `If-Match: 0` creates). The save sends
  `If-Match: <version the sheet opened on>` as a bare integer — carried on
  the built body, not read from the store, so a refresh behind the sheet
  cannot lend it a newer version. A 409 `STALE_DATA` (versions nested under
  `error.details`) is never a save and never retried: the sheet says the
  profile was changed by someone else and offers «Презареди», which
  re-reads and re-applies the farmer's edits over the new profile, naming
  any field both people changed (`FarmProfileRebase`). The response's
  version is the next save's `If-Match`. `version` is decoded as optional:
  a server without the lock is saved unguarded, as the route documents for
  an absent header. The former "last write wins" limit is gone.

iOS-only, on purpose: ЕГН masked with a reveal in view and edit (#110); an
unparseable size refused instead of sent as null (the web's null clears it);
a privacy cover in the app switcher on the profile screens.

### Members — their own page since 2026-10-01

Owner's request: Админ is now an index of three rows — «Стопанство» (the
profile), «Долна лента», «Потребители» (with a count). The member list moved
unchanged to its own pushed page.

### Профил — every role, since 2026-10-06 (agri-saas#1193 P2.8)

Web `/account` (P2.7: «Вашият акаунт», sections «Профил» and «Сигурност»,
works with zero farms) · iOS `ProfileView`, from the menu for every role,
and from the Админ account card, which now links to it (one `AccountCard`).

- Shown: the picture or initials, the name, the email — what `/api/auth/me`
  sends — and «Изход», behind a confirmation.
- Изход stays in the menu too, as on the web's user menu, behind the SAME
  confirmation (`SignOutConfirmation`); `UserMessage`'s session-expired text
  sends people to the menu for it.
- Not ported, and why: name editing (`PATCH /api/account/profile`) and the
  picture upload/removal (`POST`/`DELETE /api/account/avatar`) are route code
  absent from openapi.json — follow-ups once documented. «Сигурност»
  (password change) is for credential accounts; this app signs in through the
  browser. The web's sound/haptics preferences are device-local web settings.

### Haptics — since 2026-10-06 (agri-saas#1193 P2.8)

Web `src/lib/haptics.ts` (Vibration API; Android browsers only — iOS Safari
has none) · iOS `WriteFeedback` in `Agrent/Design/Haptics.swift`, the one
caller of `.sensoryFeedback`.

- The web fires on ACTION COMPLETION: a field-operation parcel line marked
  (DONE `success`, skip/reopen `tap`, failure `error`), a journal photo
  uploaded (`success` / `error`, `tap` on the shutter), a write queued
  offline (`tap`), and `tap` when a pull-to-refresh triggers. No picker or
  segment ticks, nothing on navigation.
- iOS keeps two words: `.success` for the person's write landing (or, for a
  field operation, kept on the device to send), `.warning` for it refused
  with the screen saying what to do. Four sites: a field operation saved or
  kept, a task status changed, a message sent, the farm profile saved. The
  other writes close onto a list showing the new row; each is a one-line
  addition if wanted. `HapticSiteTests` lists the sites exactly.
- Never from the app's own work: polls, refreshes, cache revalidation and
  the outbox drain record nothing. The pull-to-refresh tick comes from the
  system's refresh control, not from this.
- Not ported: the web's «Звук и вибрация» card (`FeedbackPrefsCard`:
  «Звук при успех», «Тактилна обратна връзка») is browser localStorage with
  no API, and the web also gates haptics on
  reduced motion. iOS's System Haptics setting governs instead; an in-app
  switch is a follow-up only if the preference ever reaches the server.

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

**Narrowed 2026-09-24.** The schematic exposes one element per parcel
with a compass bearing and still does — it is the third map mode. The two
SATELLITE modes have no accessibility tree at all, because `MKMapView`
builds none, so to VoiceOver they are one unlabelled rectangle. The
target button announces the field it moves to, which is a button
speaking rather than a map that can be explored.

So a blind operator has a map that works, and has to know to cycle to it.
Per-parcel elements over MapKit is owed work.

**No `reduceMotion`**, deliberately: the app has zero animations, so
reading the environment to gate nothing would be an accessibility feature
in name only.

**Superseded 2026-09-30, for one screen.** The conversation (Gap 7)
scrolls to a new message with an animation — the app's first — and reads
`accessibilityReduceMotion`: with it on, the list jumps instead.

---

## What is left

1. ~~**Gap 3 — create a listing.**~~ Closed by #30; recorded 2026-09-30.
   Ships unfired. So does **Gap 7, messaging**, closed 2026-09-30 — every
   write in it, and opening a conversation, is still the owner's first.
2. **Phase 4 admin**, against the contract above. The only remaining
   stub screen, and it now has a home in the app menu rather than a tab.

Everything else on this list is closed. The order the original version
suggested held up: the AX3 failures first, because a screen that cannot
be read outdoors fails before any parity gap matters.
