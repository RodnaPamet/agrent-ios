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

### Divergence — «Всички» or one crop, from a dropdown (owner, 2026-10-24)

**The web** shows the farm's net worth on top, then ONE crop at a time
picked from a strip of crops, plus a margin-per-decare comparison card.

**The phone**, as the owner asked, has a stateful dropdown at the top:
**«Всички»**, then every crop. It's remembered per farm on this phone, and
falls back to «Всички» when the remembered crop is no longer grown. With
one crop the dropdown isn't shown.
- **«Всички»:** the whole-farm block, then every crop listed as before, then
  «Разходи» and «Извън изчислението».
  - The farm block is the net worth (the server's totals per currency), the
    area, and value, cost and margin per дка (`FarmFigures`).
  - Each figure is weighted by the area it is per: value and margin by the
    yield-covered area, cost by the land, as the server divides them (#1606).
  - It is never mixed across currencies: one line per currency.
  - It says which crops it leaves out, once when every figure leaves out the
    same ones.
- **One crop:** its figures (the dropdown names it), then the farm's
  «Разходи», which carry no crop to split them by.
- **Crop names** in the list are gold, not the header grey.

The farm figures per дка are the phone's own arithmetic over the payload's
rows. The server doesn't publish them, so the web has nothing to compare
them against.

### Matched — a margin the cost can't be subtracted from (agri-saas #2259, #2272)

A crop's «Марж / дка» is not shown when its cost can't be subtracted from
its value:
- the cost rate was refused (costs in two currencies, the lease currency
  unrecorded, no parcel with the crop);
- or the costs are all in ONE currency that isn't the price's. The cost rate
  still shows in its own currency.

The farm block's margin leaves such a crop out and names it. A server from
#2272 on sends the reason as `marginRefusalCode`. With an older one the phone
works out the same reason from the cost refusal and the two currencies, so
build 18.1 already hid the two-currency margin. The farm fold on the web
(`farm-per-area.ts`) makes the same checks.

**One divergence in where the reason is said.** The web says it once, on the
margin line, for all six codes. The phone says the value side's reason above
the figures, as before, in a sentence that names the margin too. So its
margin line adds the web's sentence only for the four other codes, and never
says the same thing twice.

### «Нов разход»: «Култура» or «Общи» first (#245, owner 2026-10-09)

«Общи», the farm's overheads, was «Режийни» until the owner renamed it the
same day.

The owner's design: choose crop or overhead first. The crop side becomes
per-decare lines (rent, seed, fuel, ПРЗ, fertilisers) with the farm's last
values as defaults. Overheads are yearly, salaries can be people × salary, and
everything spreads over the WHOLE farm. The web is to work the same way
(agri-saas).

**iOS now — the «Общи» half** (`OverheadSheet`, `OverheadFields`):
- **The lines.** Заплати (a total, or «По хора»: people × yearly salary, with
  the total editable), Кредитни разходи, Амортизация and Друго. Each is sent as
  its own cost with `allocationBasis: HOLDING`, «Цялото стопанство» on the web.
- **Defaults.** Lines are prefilled from the farm's last values (agri-saas
  #1523, `GET /grain/costs/defaults`), with the date each was entered. A line
  with no history stays empty, never zero.
- **Amortisation** is offered from the machine register (`GET /costs/machinery`,
  documented #1506). Its caveats are said: «not computed» is not zero, machines
  without a useful life understate the total, and a truncated register is
  partial.
- **Saving.** The whole sheet as one write (`POST /grain/costs/batch`, agri-saas
  #1604, #260): every line lands or none does, under the sheet's one key. A lost
  answer locks the sheet; a refusal, or a request that never left the phone
  (#265), leaves it editable.

**iOS now — the «Култура» half** (`CropSheet`, `CropFields`, #245):
- **The crop.** Chosen from the calculator's crops with land
  (`occupiedAreaHa`, agri-saas #1606); one with none is not offered, and a farm
  with no crop on its land is told so and pointed at «Общи».
- **The lines.** Рента, Семена, Горива — one rate each; Препарати, Торове and
  Услуги — named rows, as many as wanted («total or manually added rows»). All
  per decare. **Услуги** was not in the owner's list; it kept the place it had
  in the one-line form, so a harvest contract still has a home, and the owner
  confirmed keeping it (2026-10-10).
- **Sent as** `allocationBasis: CROP` with `commodityCanonical`, `amountPerDca`
  as typed, and `amount` = rate × the crop's decares to the cent (agri-saas
  #1583); no land link, no season (the server takes the one containing the
  date). The same batch as «Общи», bounded at 25 lines.
- **Defaults** from the crop's last sheet (`GET /grain/costs/defaults?commodity=`,
  agri-saas #1611), row for row. Leva converted at 1.95583 and said so; a line
  entered as a total keeps its name and is left unfilled; another currency is
  left unfilled and said; `UNKNOWN_COMMODITY` is said beside the crop.
- **Supplier and notes are gone** from the crop side: a per-decare plan figure
  has no supplier, and a row's name is its description.

**Unverified:** no crop or overhead sheet has been saved from the app. The web
has neither sheet yet.

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

### Matched — tap an oblast on the map to filter the board (#417, owner 2026-10-24)

The owner asked for the exchange map to be "clickable to filter like the web
one". **The web** (`ExchangeMap.tsx`) toggles an oblast in its region filter on
a click, paints the chosen ones emerald, and narrows the listings to them.

**iOS:**
- **Tapping an oblast toggles it,** and several can be on at once. The tap is
  hit-tested against the bundled geometry, using the drawing's own transform
  run backwards.
- **Chosen oblasti are drawn in green.** The server answers
  `GET /exchange/listings?region=BG-15,…`, the spec's CSV of ISO codes, sorted
  so the same choice is the same request.
- **The filter carries to the list.** Above both, «Област: Плевен» /
  «Области: …» says so, with «Изчисти». It also counts for «Изчисти
  филтрите».
- **An empty result keeps the map,** so the oblast that was tapped on can be
  tapped off.
- **The map's accessibility elements carry the same toggle as an action.**
  VoiceOver, Switch Control and Voice Control («Плевен») can filter, and the
  selected trait says which oblasti are on. An oblast chosen with nothing left
  in it still has an element, so it can be turned off.
- **Not ported:** the web's zoom, its aggregated price chips, and its
  cheapest-offer ring.

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

### Divergence — «Съобщения» on Борса's bar, three sections in the row (owner, 2026-10-24)

The web has «Съобщения» as a fourth section beside «Обяви / Моите обяви /
Моите заявки». The owner moved it to Борса's bar, in the place «Ферми» had.
- **Pushed as its own screen** (`ExchangeInboxScreen`, `AppRoute.exchangeInbox`),
  with the unread count beside the icon. A badge over the icon's corner was
  clipped by the bar's capsule.
- **VoiceOver:** the count is the button's value, so Voice Control's
  «Съобщения» keeps matching as it changes.
- **Three sections fit a phone** as segments now. Four needed chips.
- **The inbox polls only while on screen,** as it did as a section, and an
  empty inbox's «Към обявите» goes back to the board.

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

- ~~**A sender name on `ExchangeMessage`.**~~ **Shipped** as `senderName`
  (agri-saas #1399, live 2026-10-08; agrent-ios#187) — for EVERY sender, the
  other side included (owner's decision, agri-saas #1348), present-and-null.
  The caption names the person when there is a name, and falls back to
  «Колега от стопанството» / «Отсрещната страна» when there is none.
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

### «Блокове», fields only (owner, 2026-10-16)

The owner's words for a Location, one per `LocationKind` (agri-saas #1966):
«блок» for a group of parcels (FIELD), «силоз» for a grain bin, «склад» for
a warehouse. The web retired «Локация» and «Обект» for the entity in
agri-saas #1985.

- **The tab:** asked directly, the owner chose «Блокове», fields only, as on
  the web, where silos and warehouses have a page of their own. The list
  asks for `kind=FIELD`. So do the journal's block filter, the farm record
  and the risk picker, which share the path and were field contexts already.
- **Fixed on the way:** each row printed the server's `kind` as sent, so
  every row read «FIELD». The line now shows only the parcel count.
- **Wording:** pickers, empty states and the two refusals of the phone's own
  that said «локация» (`INVALID_LOCATION`, `PARCEL_LOCATION_MISMATCH`) now
  say «блок». Silos and warehouses don't appear on the phone.

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

### Divergence — a spray refused with a 426 is kept for the updated app (#169, owner 2026-10-07)

**The web.** `ParcelDetailSheet` saves through `useOfflineSync.submit`,
which throws on every 4xx except 408 and 429 (`isTerminalClientError`). On a
426 the sheet shows the error and keeps nothing. In practice the web never
meets one: it ships with the server and sends no `x-agrent-client-version`,
and the gate serves an absent header as compatible.

**iOS, deliberately different.** The app declares its contract on every
request (`x-agrent-client-version: 3` since 2026-10-09; 2 since #185, after
agri-saas #1390 went live; 1 before it; ROADMAP, «Decisions locked» 7). So
once the server's floor passes that number, the spray sheet's save meets a
426. The sheet then offers «Запази за по-късно», as it does with no signal,
under the line «Записът остава на устройството и се изпраща след обновяване
на приложението.» The record is queued under the same `Idempotency-Key` and
the same owner (parked while anyone else is signed in, #142). It waits while
`OutboxStore.isClientTooOld` holds, which is the rest of this process: no
request goes out, and the banner shows its «…остаряла…» line in place of
«Изпрати» (#168). The updated app's first flush sends it. A farmer who
recorded a spray in a field does not have to retype it after updating.

Unchanged: a parcel line's tap on a 426 still queues nothing, as on the web
(#168); the 429 pause and the key behave as before.

**Unverified**: no 426 has been met, because the server's floor is 1 too,
and the sheet's 426 line has never rendered (ROADMAP, the #112 entry).

### The spray sheet takes the product as typed text (#237, owner 2026-10-09)

**The problem.** 22 of the farm's 24 catalogue products were the seeded
«Generic …» archetypes. agri-saas accepts one on a plan, then refuses the
line's DONE (#1078), deliberately: completion is when the row becomes
evidence. So a job planned with a sample product could never be completed.

**Now, on the web and here alike.** The owner asked for all sample products
removed and the product as free text only. The web dropped its dropdowns, and
the sheet here dropped its picker and «Нов продукт» form.
- **The name.** It travels as `productName` / `fertilizerName`. The server
  finds the farm's product of that name, case-insensitively, or creates it. A
  record made with no signal still queues and is resolved when it is sent.
- **Registration.** A new name on the spray path asks what it is,
  «Препарат за РЗ» or «Тор» (`newProductCategory`, agri-saas #1499), since a
  fertiliser can be sprayed. Only a new PESTICIDE needs its ПРЗ № and
  quarantine period, so they are asked for then, and only then.
- **Matching.** It is the server's unique index, `lower(name)`, with no
  diacritic folding.
- **Refused before sending.** A non-fertiliser on the fertiliser path, or a
  sample's name, is refused before the request (`TypedProduct`). A fertiliser
  on the spray path is NOT refused: liquid nitrogen goes through a sprayer,
  and the server's rule is one-sided (`FERTILIZER_EXPECTED` only).
- **Suggestions.** The farm's own products that contain the typed text are
  offered, so a near-copy is not created by a typo.

**Unverified**: no operation has been sent with a typed name. The first is
the owner's (agri-saas's typed-name contract, merged after this was built).

---

## Journal

Web `journal` (1785, `apiPost`/`apiPatch`) + `journal/[id]` (904,
`apiDelete`) · iOS `Journal/JournalListView.swift` (126) +
`NewEntryView.swift` (76; replaced by `Treatment/TreatmentEntryFlow.swift`, #293)

### Gap 5 — there is no entry detail — CLOSED 2026-09-22

`JournalListView` has a `.sheet` for composing and **no `NavigationLink`**.
The list is terminal: an entry cannot be opened, so it cannot be read in
full, corrected, or deleted. The web has a 904-line detail page.

This is the largest functional gap in the app. The journal is the legally
filed record — the ДНЕВНИК PDF is generated from exactly these rows — and
an operator standing in a field cannot check what was recorded.

### Divergence — «Дневник (PDF)» on the page, not on an entry (#246, owner 2026-10-09)

**The web** offers «Дневник (PDF)» on a journal entry that records a field
operation (`journal/[id]`, where `entry.fieldOperation.locationId` is computed
server-side) and on a location's page. Both use «От» / «До» (1 January to
today by default) and `POST /locations/{id}/farm-record` `{ from, to }`, which
returns the PDF's bytes.

**iOS** offers it on the Дневник page itself, as the owner asked, and since
2026-10-25 (#436) it is «ДНЕВНИК НА СТОПАНСТВОТО», no longer the БАБХ
register for a block:
- **What:** the owner's own paper template (agri-saas #2316,
  `POST /reports/campaign-diary?campaign=YYYY-YYYY`): the whole farm, every
  recorded activity, one landscape table, one row per activity with its total
  area in ха. The owner chose it to REPLACE the БАБХ period download, so the
  phone no longer asks `POST /locations/{id}/farm-record`. The БАБХ register
  stays per treatment (below).
- **Which:** a campaign, 1 October to 30 September, picked from a menu: the
  current one first, then the four before it. The phone works campaigns out
  itself (`FarmRecordAPI.Campaign`, by Bulgaria's day). The server derives the
  same window, so there is no Season row to keep in step. There is no block
  and there are no dates.
- **Waiting:** it travels on `APIClient`'s document session, which waits 90 s
  rather than 15 s. A campaign's rows are uncapped by design, so a long one
  takes a while.
- **Checked:** a 200 that is not `%PDF` is refused.
- **A campaign with nothing in it** gets no document. The server answers 404 `REGISTER_EMPTY_FOR_PERIOD`, and the sheet says «Няма записи за тази кампания.» as a plain note, not an error, until the campaign changes.
- **Opening:** the PDF opens in Quick Look, which shares it or saves it to
  Files.
- **Storage:** it is written under complete file protection to a temporary
  folder of its own, which is removed when the sheet closes and on sign-out.

**The web** still offers the per-location БАБХ download described above. The owner's replacement is for both products; the web's half is backend's.

**And on a treatment's own entry (#320, owner 2026-10-14).** A folded
treatment row (agri-saas #1799) carries its `treatmentGroupId`, which is the
location-free handle the paragraph above lacked. Its entry screen shows what
was done, read from the row, and offers «Изтегли PDF» for that treatment
alone (`GET /journal/treatments/{id}/farm-record`, agri-saas #1822). This is
the same document as the screen right after a save, and the same storage and
Quick Look, removed when Quick Look closes. Entries that are not treatments
print only in the farm's diary.

**Unverified:** no ДНЕВНИК has been downloaded from this app. Under the
UI-test seam the POST is a 501, so the first real one is the owner's.

### Matched — «Нов запис» with no signal waits in the outbox (#324, owner 2026-10-14)

**The web** submits the treatment through its outbox (`useOfflineSync().submit`,
agri-saas #1841, on the owner's ruling "queue the treatment"). The outbox id
is minted before the first attempt and is the `Idempotency-Key`, so it is the
handle. A queued treatment is an optimistic row with no document until it is
delivered.

**iOS** tries the save live. When that fails in a way a later send can fix
(no signal, 5xx, 408, 429), it keeps the entry in the outbox under the key
it went out under, which is the handle. It does the same on a 426, which
waits for the updated app, as a queued spray does. The owner chose this on
2026-10-14, asked directly. The facts:

- **What it is:** a third kind of queued row (`PendingOperation.treatment`).
  It replays `POST /journal/treatments` to the farm it was made on. A 201
  holding fewer parcels than were sent is not a delivery: the row stays,
  and the same key writes the rest (agri-saas #1765).
- **Step three:** says «Мероприятието чака изпращане.» with no «Изтегли PDF»,
  since the server has no pages for a handle it has not seen.
- **The journal:** shows the farm's kept treatments in a section above the
  entries, under any filter. A delivered one leaves the queue, the list is
  read again, and the server's row with its document takes its place. One
  the reload already holds under the same handle is not shown twice.
- **One divergence in the save's path:** the phone does not queue while an
  earlier save under a different key is unsettled and the server can't be
  asked about it. Sending the changed entry could record the treatment twice
  (`TreatmentAttempt`), so the error stays on screen as before.
- **Cached reads, where the two differ (owner 2026-10-15, both asked
  directly):** both clients now open the form with no signal. They differ
  in how old the lists may be.
  - **The phone** (`ResponseCache`) keeps step two's crops and parcels
    (`/parcels/by-crop`) and the form's product and unit lists with no age
    limit. An entry stays until the 8 MB budget, an iOS purge or sign-out.
    **Kept that way on the owner's choice**, as every other cached screen
    is. So a phone opens the form after days without signal.
    - **Warmed, not only kept (#384, 2026-10-21):** the owner found offline
      that only crops opened earlier with signal had parcels. `OfflinePrefetch`
      now reads the crop list and every crop's parcels at launch and on each
      return to the foreground, beside the product and unit lists it already
      warmed. It reads one crop at a time, and an unchanged crop costs a 304
      (#329). Not for an operator, whose path lockdown refuses the route.
    - **«Проверка» with no signal (#384):** it opened as an empty page with
      only a back arrow, because the read-back sat in separate state that the
      pushed page could read before it was set. Online, a later network answer
      redrew the page and hid the bug. The read-back now travels in the
      navigation path. A11yShots `testTreatmentCheckWithNoSignal` walks to it
      with signal, then again on a launch where every request fails.
    - **«Нов запис» whatever the list is doing (#384):** it used to wait for
      the journal's entries, so with no signal and nothing cached it wasn't
      offered at all, though the form queues offline.
  - **The web** persists the same four reads since agri-saas #1890 (#1845),
    geometry included. It drops its whole bucket after 24 hours, the owner
    having declined a longer window. After a day without signal it opens
    the form empty.
  - **ETags:** since #1890 the three reads that lacked one (`/items`,
    `/units`, `/parcels/by-crop`) answer with one, so the web's
    revalidation is a 304. The phone sends no `If-None-Match` (`APIClient`;
    there has been no HTTP cache since #134). Every online read is the full
    body, which for `/parcels/by-crop` is up to 5000 parcel geometries.
    Filed as #329.
  - **What a farmer is told:** neither client says how old the lists are.
    The phone has said nothing since #70.
  - **A parcel deleted meanwhile** comes back `REFERENCE_NOT_IN_TENANT` on
    replay. The row is then kept as refused, with the server's sentence.
- **A treatment an administrator abandoned (#326, agri-saas #1860/#1869):**
  a row that keeps coming back short is resent under its handle, which is
  how a passing cause gets finished. When the cause doesn't pass, an ADMIN
  can abandon the treatment on the web. The server then answers that handle
  410 `TREATMENT_ABANDONED`, instead of writing the whole treatment again
  under it. The phone refuses the row with a Bulgarian sentence saying an
  administrator stopped it and that a new entry is the way to record the
  work. Since agri-saas #1870 (#1892, live 2026-10-15) the web's outbox
  resends a short treatment too, under the same key, and silently, as the
  phone does (owner ruling, asked explicitly there). So both clients meet
  the 410 the same way.
- **A treatment the server can't finish (#326, owner 2026-10-15, asked
  directly):** the phone says so, and an ADMIN ends it from the phone.
  - A queued row notes each short answer.
  - The journal row says «Записани 2 от 3 парцела.», then «Останалите се
    изпращат отново.» or, once a resend holds no more parcels than the last,
    «Останалите не могат да бъдат записани.».
  - The entry's screen asks the server (`GET /journal/treatments/{handle}`)
    and, for an incomplete treatment, offers «Прекрати мероприятието» to
    whoever the farm's `canAdmin` allows. The confirmation names the
    ДНЕВНИК entries that go with it.
  - Everyone else is told only an administrator can.
  - The abandon also drops the phone's own copy, so nothing resends it.
  - **«Довърши мероприятието»** (owner, 2026-10-25, asked interactively). It sits beside «Прекрати», for whoever may correct the treatment (`mayCorrect`), and isn't shown while this phone is still resending its own copy. It reads `GET …/definition` and sends it again to `POST …/journal/treatments` under the treatment's own handle. The server then finishes a treatment that isn't complete (agri-saas #2318): blocks already written are recognised and left alone, and only the lines still pending are marked.
  - **The journal row** says «Записани 2 от 3 парцела. Останалите не са записани.» for any treatment the server holds in part (`pendingCount > 0`, agri-saas #2318), whoever recorded it. Before that, only this phone's own short saves said so. `parcelCount` counts only finished lines.
  - **Until #428 (2026-10-24) the entry's screen never asked.** The section read
    from a `.task` on a `Group` that held no view before the answer, so the
    read never ran and no build showed the warning or the button. That was
    found on the fixture seam, not on a device. The screen now reads it, and
    `EmptyGroupTaskTests` fails on that shape anywhere in the app.
  - **The web:** has no button for the abandon as of 2026-10-15; the route
    is API-only. Its outbox now resends a short treatment (#1870), but says
    nothing about it: a web farmer sees the server's row with fewer parcels
    and no note.

**Unverified:** no treatment has been queued on a device. The check is
airplane mode → «Нов запис» → save → close the app → signal back → open
it: one entry in the journal, with its PDF.

### Matched — «Продължи» reads the treatment back before «Добави» (#362, owner 2026-10-20; the web since agri-saas #2174)

The owner compared the journal with PRZ (app.prz.center, manual v2.1.0)
and chose to bring the **form** closer to PRZ's. In PRZ, «Продължи» opens a
check screen with the amount of product and the end of the quarantine
period, then «Добави», or «Редактирай данните» to go back.

**iOS** puts that check between the parcels and the save:
- **Step two** says «Продължи» instead of «Запази».
- **Step three, «Проверка»**, lists:
  - kind, day, product, pest, dose and technique;
  - crop, blocks, parcels and treated area;
  - the **amount needed**: the dose × the area, in the dose's own unit, with a thousand мл or г shown as л or кг;
  - on a spraying, the **quarantine period** and the **earliest harvest day**.
- **No amount:** with no area, or a dose that isn't per area, there is no amount. The screen says why, rather than guessing.
- **«Добави»** is the same save as before: same key, same outbox. «Редактирай данните» goes back to step one with everything kept.
- **The target button on step two's map** (#398, owner 2026-10-22): each press frames the next parcel with an outline, and VoiceOver says which. It's the same control as on Блокове (`ParcelTargetButton`), and «Нова задача»'s «Парцели» map has it too.
- **«Виж на картата» on a recorded treatment** (#399, owner 2026-10-22), on its journal entry and on the saved screen: the treated parcels on a map, all highlighted, with the target button, and listed by block below. A row frames its parcel. The parcels come from the treatment's tasks (`taskIds`, then each `/field-operations/{taskId}`), cache first. The saved screen already holds them and makes no read.
- **Above «Добави»:** «Проверете данните.», word for word as the website's step 3 (#2174). Until 2026-10-24 it went on «След записване вписването в ДНЕВНИКА не може да се редактира.». The owner then made recorded treatments correctable (#392) and had that sentence dropped from both surfaces in the same release. The web's half is backend 1's. There's no confirmation tick, the owner's choice for both surfaces.
- **Not shown: remaining stock.** A ДНЕВНИК treatment deducts none (agri-saas #1740), and the owner didn't choose it.

**The web** has had the same step since agri-saas #2174, live at f8a1e65 on 2026-10-22. It shows the same sentence, and neither surface has a tick, as the owner chose. Two differences remain, both deliberate: the web titles the step «Нов запис — проверка» to match its sibling steps (the phone's navigation bar gives that context), and only the phone shows the amount of product needed.

### «Коригирай» on a recorded treatment (#392, owner 2026-10-24)

The owner reversed "recorded treatments stay final" (2026-10-22) on
2026-10-24, with backend 1 (agri-saas #2279) and then here, asked
interactively.

**iOS**: «Коригирай» on a treatment's journal entry, below «Виж на картата»:
- **Who:** the treatment's creator and the farm's administrators, as the server rules it (creator or admin, one author). Decided from the row's own `mayCorrect` (agri-saas #2292), and never from `mayDelete`. The two agree today, but agri-saas #2280 may narrow the withdrawal again, and a fallback would then hide «Коригирай» from creators who may still correct. Only an explicit `false` hides it; an absent field is a page cached before it existed. It is never decided by probing `GET …/definition`, which 403s for anyone who may not correct.
- **Step one** is the treatment as recorded, read from `GET …/definition`, in «Ново мероприятие»'s order. Since agri-saas #2293 everything it recorded is correctable:
  - the date, pest, Фенофаза/BBCH, quarantine period (with the earliest harvest worked out again) and technique;
  - **the product**, typed and matched against the farm's catalogue with its suggestions, as on «Ново мероприятие». A correction sends it by id, so only a product the farm has can be chosen. A new name says «… не е в каталога на стопанството». The kind isn't corrected, so a fertilising takes a fertiliser;
  - **the dose**, its amount and unit, which «Проверка» reads back as one line;
  - **the parcels** (agri-saas #2304): a ticked list per block, as on «Ново мероприятие»'s parcel step. A recorded parcel can be unticked, and the block's other parcels can be ticked to add them. Only the treatment's own blocks are listed, read from the definition's `lines[].locationId`, because the ДНЕВНИК prints one table per block and a parcel of another block would be a treatment never recorded (`TREATMENT_CORRECTION_NEW_BLOCK` can't come from the phone). Unticking every parcel is said («Остава поне един парцел…») and points to «Изтрий»;
  - **each ticked parcel's treated area**, in decares, where empty is the whole parcel and so is the parcel's own size typed back. A larger area than the parcel is said before the save.
- **Kept as recorded:** the kind, and the water rate, which the phone never recorded and leaves out of the body. Before #2293 the product, dose and parcels were shown locked; before #2304 the set was.
- **No parcel step:** the parcels are on step one.
- **Step two, «Проверка»**, lists only the changes, each as «Беше: …» and «Става: …», above «Проверете данните.» and «Запази».
- **What goes out:** `PUT …/definition` under `If-Match: <group version>`, carrying ONLY the changed fields. A cleared field goes out as an explicit `null`; an untouched one is left out, which the server reads as unchanged. So a stored technique outside the seven isn't rewritten. «Напред» stays dimmed until something changes («Няма промени за запазване.»).
- **Someone else corrected it first** (409 `STALE_DATA`): said, «Запази» is disabled, and «Зареди отново» loads the current values, dropping this correction's changes as the sentence says.
- **After the save:** the entry shows the corrected values at once, and the journal reads again.
- A field a spraying requires (the pest, the period) may not be emptied if it was filled. One an older record never captured may stay empty.

**«Корекции»** on the entry, under its facts (agri-saas #2292, `GET …/corrections`). It is what the owner asked for on 2026-10-22:
- one line per correction, newest first: «Коригирано на 24 октомври 2026 г. в 21:40 от …», with no «от …» when the server can't name anyone (it never sends an id);
- each changed field with «Беше: …», read from the correction's `previous` definition. A treated area lists every parcel's area as it was. The dose and water rate are said with their unit, «Беше: 0,15 л/дка», from the symbols the definition carries since agri-saas #2298. A correction filed before then stored no symbol, and is only named («Променено»), since a rate without its unit could be any unit. A field this build has no name for is left out;
- readable by anyone who can see the treatment, an inspector included (a read gate, where the prefill is a write gate);
- nothing shown while it loads, if it can't be read, or when nobody has corrected the treatment. Read again after «Запази».

**The web:** the route has been on the server since agri-saas #2287. The website's editor is backend 1's, and drops its «Проверка» sentence in the same release.

**Фенофаза/BBCH** (#363, agri-saas #2083, live 2026-10-20) is optional on
every spraying, after the dose, as in PRZ. It's free text up to 64
characters, because the register takes a BBCH code or a stage name. It's
stored on every line, read back on the entry and on «Проверка», and never
sent blank. It **prints** (agri-saas #2089, live 2026-10-20) in column 2,
«Фенофаза/BBCH», of the scouting table, not in Приложение 1's chemical
table, which has no such column. It goes on a row derived from the
treatment, as the owner ruled (agri-saas #1740 Q2):
- one row per spraying that recorded a stage;
- the date marked with an asterisk, and a caption saying such rows are derived from the treatments and aren't a separate inspection;
- «Болест», «Неприятел» and the four measurement columns left blank.

The form's note says that.

**Other work on the journal row** (agri-saas #2339, owner 2026-10-25): pruning, cultivation, sowing and harvest are lines on parcels like a treatment, and share the journal row. The phone keeps a treatment's own controls off them: «Коригирай», «Изтегли PDF» and the unfinished section. Only a row whose `kind` is a spraying or a fertilising gets those, or one with no kind, which is from before the field. The correction route refuses a bare activity (`NOT_A_TREATMENT`). «Изтрий» is offered on them, on the same `mayDelete`: the treatment withdrawal removes a bare activity too (backend 1's test, 2026-10-25). **Recording it on the phone (#439, owner 2026-10-25):**
- «Нов запис»'s «Вид» is a menu of «Пръскане», «Торене», «Резитба», «Обработка на почвата» and «Прибиране на реколтата», with the server's labels (`ACTIVITY_LABELS_BG`) word for word.
- Other work asks only for its one day (no range, owner), then the same parcel step and «Проверка», with the area as «Площ».
- A harvest also asks for one total in kg, never split by parcel (owner).
- It is posted to `POST …/journal/activities` under the same key, landing and replay rules as a treatment, and waits in the outbox the same way without signal.
- The saved screen offers no ДНЕВНИК PDF: other work prints in the farm's diary (#436).
- Not sowing. A sowing applies a seed product at a rate, so it isn't bare work (owner with backend 1, 2026-10-25), and the activities route takes only the three. It comes to «Нов запис» once the treatments route takes a seed product (asked).

**Treated area per parcel** (#363, agri-saas #2086, live 2026-10-20): step
two lists each chosen parcel's area under «Третирана площ, дка». An empty
field means the whole parcel. Each parcel goes out as
`parcels: [{parcelId, treatedAreaHa}]` beside `parcelIds`.
- **A whole parcel is its area, as a number** (owner, 2026-10-25, asked interactively; #435). An empty field, or the parcel's own size typed back, goes out as the parcel's own exact area, so the register keeps the number and an old ДНЕВНИК row doesn't change if the parcel is re-measured later. Only a parcel with no recorded area is left out, as the whole parcel. Until then the phone sent a whole parcel as "whole" (null) while the web kept numbers. «Коригирай» does the same (#433).
- **The bound:** a figure within the register's tolerance of the parcel's own area counts as the whole parcel, since the field shows that area rounded, and goes out as the exact area, never the rounded figure. A larger one is refused on the phone before the server's inclusive bound would refuse it. Widening that bound for rounding, and what to do with the rows stored as null before, is agri-saas #2308.
- **The total:** the check, the saved screen and the outbox row show what was treated.
- **The save key:** the areas are part of the draft, so a changed area mints a new key, as the replay rule needs (agri-saas #1765).

**Retired:** pest, dose and quarantine-period suggestions from the БАБХ
register (owner, 2026-10-21). Asked where they would sit, since step one
asks for the product before step two picks the crop, the owner chose to drop
them. Nothing was built for them on the phone. The free-text pest, dose and
quarantine fields stay the only source, with the quarantine still prefilled
from the product. Seed treatment: not now.
- **The server keeps the register's loader, which nothing reads** (owner to
  backend 1, 2026-10-21: "keep the loader, drop the suggestions"). agri-saas
  #2110 stays: an operator upload of the national register, with no read
  route and no consumer. That is deliberate, not unfinished, so don't build
  a read against it. agri-saas #2077 is closed as not planned.
- **Also declined:** filling a product's quarantine period and registration
  number from the register (backend 1 asked the owner, who dropped the idea).

Offered and **not** chosen: PRZ's per-field layout by farming year, a crop
record per block, and other activities with yield and cloning.

### Matched — a swipe removes the whole treatment, with «Отмени» and no way back after it (#395, owner 2026-10-22; #411, owner 2026-10-24; agri-saas #2184)

The owner asked for the website's swipe-to-delete, on the phone too, and
ruled what it removes: the **whole treatment**, every parcel and block,
never one parcel's row. The ДНЕВНИК it prints leaves it out as well, as if it
had never been recorded. The treatment's creator and the farm's
administrators may do it. backend 1 confirmed this with the owner directly
before building the routes.

**iOS:**
- **«Изтрий»** sits behind a left swipe on a Дневник row that stands for a treatment. It isn't a full swipe: removing a record takes the tap. VoiceOver lists it among the row's actions.
- **It's offered** where the row's `mayDelete` says the server would allow it. The server computes that from the same predicate its route asserts with: the creator or an administrator, and a single author across the treatment's tasks. That last part refuses administrators too, so no creator field could express it. A cached row from before the field offers it to anyone who may write, and the server's refusal is shown.
- **The row leaves the list at once.** A bar above «Нов запис» says what went and how much of the register that was, «Изтрито: Препарат, 3 парцела в 2 блока», since one row can stand for a dozen parcels (the web's toast names the count too, agri-saas #2192). It offers «Отмени» for five seconds, as on the web, and twenty under VoiceOver or Switch Control. Nothing is sent until the window closes, so «Отмени» needs no signal and leaves no audit event. A second swipe sends the first at once, so «Отмени» only ever stands for the treatment the bar names.
- **Then** `DELETE /journal/treatments/{handle}` goes out. The phone's own copy in the outbox goes with it, because the server releases an unfinished treatment's key and a resend would record it again. A refusal brings the row back with the server's sentence. A 404 counts as done.
- **No «Кошче»** (owner, 2026-10-24: "what's deleted is deleted", #411). The trash list and its restore are gone from the phone, and the 5-second «Отмени» is the only way back. On the server the owner chose to have the DELETE erase the treatment from the database, keeping only the audit line. That's agri-saas's to build, confirmed with the owner directly.

**The server** has the routes since agri-saas #2184, live at 683d52a on
2026-10-22. The web's swipe row and Trash view are still to come.

Asked of backend 1 and added to #2184 (6fac369): `mayDelete` on the row,
the summary and `mayRestore` on «Кошче», and a DELETE description that no
longer says ADMIN-only and INCOMPLETE-only. backend 1 also found that the
listing's `occurredOn` had come from a column the treatment write never
sets, so it was null on every row. It now comes from the entry's day, which
is the one the journal list prints.

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

## Tasks — a field operation's parcel lines

Web `FieldOperationPanel` (on a FIELD_OPERATION task's overview) and the PWA's
`OfflineFieldPanel` · iOS `Tasks/FieldOperationSection.swift` +
`FieldOperationStore.swift`, on the task detail.

### Matched — «Ново мероприятие» names its operator (#371, owner 2026-10-20)

**Before:** the parcel's operation sheet assigned the work to whoever
filled it. Now an **«Изпълнител»** row offers the farm's active members,
from `/users/assignable`, the server's own list. It defaults to the person
filling it, as before.
- **Kept in memory:** the list carries colleagues' emails, so it's read when the sheet opens and never cached.
- **A failed read** leaves the person filling it, says so, and never blocks the record.
- **Someone else** gets the assignment email, notice and push. A self-assignment notifies nobody.

### Divergence — «Нова задача» from a + on «Задачи» (#372, owner 2026-10-20)

**The web's** `NewTaskModal` asks for a title, description, type, severity,
priority, due date, assignee and links. **iOS** asks what a phone needs:
- **The fields:** title (required), description, a due day and the assignee.
  - **Assignee:** from `/users/assignable`, «Без изпълнител» by default as on the web, kept in memory only.
  - **Due day:** sent as UTC midnight of the day, as the web's `ymdToInstant` sends it.
  - **Type and severity:** the web's defaults, `TASK` and `MEDIUM`, sent as the web sends them. No priority (owner, 2026-10-09).
- **Opened from:** a **+ at the bottom right** of «Задачи», the owner's choice, offered only to someone who may write in the farm.
- **After a save:** the list reloads and the new task opens.
- **Not idempotent:** the route honours no key, so a lost answer is said as possibly created, never retried.
- **A second step, «Парцели» (#388, owner 2026-10-21):** «Напред» opens the task's parcels, chosen by block, on a map and in a list, and «Създай» is there. They are optional. A choice in one block stays when another block is opened.
  - **Sent as links**, `POST /tasks/{id}/links` `PARCEL`, one per parcel after the create, as the web's `pendingLinks` does. A 409 (already linked) counts as linked.
  - **Never created twice:** the create and the links are separate requests. A link that fails leaves the task as created; «Опитай пак» sends only the parcels not linked yet, and «Готово, без тях» finishes without them.
  - **Reads:** Блокове's blocks and their parcels, cache first, both warmed by `OfflinePrefetch`.

### Divergence — «Редактирай» on a task, for its creator and administrators (#382, owner 2026-10-21)

**The web's** task page has an edit form (`FarmTaskDetailClient`) with title,
description, priority, type and due date. Since agri-saas #2191 it's offered
on the same rule as the phone's. **iOS** opens the «Нова задача» form on the task:
- **The fields:** title, description, due day and assignee (owner, 2026-10-21). No priority and no type, as in «Нова задача».
- **Who sees it:** the task's creator and the farm's administrators, and only someone who may write there. This is the owner's rule.
  - **The server enforces it** since agri-saas #2182, live at 168ee9a on 2026-10-22 (owner, confirmed directly): `assertCanEditTask` narrows the write gate, and anyone else gets 403 `TASK_EDIT_NOT_PERMITTED`. The phone shows that in the server's words.
  - **Reassignment is not gated by it.** `POST /tasks/{id}/assign` still takes any writer, which #2182 chose knowingly, since "who may edit" was the question asked. The phone reaches the assignee only through «Редактирай», so it's offered on the stricter rule.
  - **When the tier is unknown,** the button shows, as every write does, and the server's answer is read out.
- **What is sent:** only what changed.
  - The fields go by `PATCH /tasks/{id}`. A cleared description or due day is an explicit `null`.
  - The assignee goes by `POST /tasks/{id}/assign`, which records it and tells the assignee. It is sent only if the assignee changed.
  - The due DAY is compared, not the instant, so an untouched day set elsewhere at another hour is not rewritten to midnight.
- **No lock and no key:** the task row has no version and neither route reads a key. Both set a state, so last write wins, as on the web.
- **A description the server couldn't decrypt** opens empty. It isn't sent unless somebody types over it.

### Matched — a tapped notification opens its task (#368)

**The web** opens a push's `url` when it is clicked (`tag: task-{id}`
coalesces repeats). **iOS** reads the same path, which agri-saas #2076 sends
as `link` beside `aps`:
- **A tap** on `/t/{slug}/farm-tasks/{id}` opens that task on «Задачи».
  - If the task is in another of the person's farms, that farm opens first.
  - If the farm is no longer theirs, the app says so instead of opening another farm.
- **Ignored:** any other path, a missing link, or a tap from a session that has since ended. The app then opens as it is.
- **In the foreground**, a notification is shown as a banner, with sound, and kept in the list, as it would be with the app closed.

**Unverified:** nothing has been delivered yet. That needs #317's ask, the
transport (#2076) and the owner's APNs key on the server.

### Gap 8 — parcel lines could not be marked — CLOSED 2026-10-07 (#138)

The web lets an operator mark each prescription line of a spray job
«Готово», «Пропусни» or «Отвори отново», including with no signal. iOS showed
the task and nothing of its lines. Ported, read from the spec and the route
(`PATCH /field-operations/{taskId}/parcels/{lineId}`, `markOperationParcel`)
rather than from the issue:

- **The lines**: parcel, product, dose, area in decares, status — the web's
  wording, verbatim from `messages/bg.json` (`ag.status.operationParcel`,
  `ag.map.fieldOp.*`, «{done} / {total} парцела завършени»). DONE is the web's
  success badge, the rest neutral; `Palette.Chip.success*` is the measured pair.
- **Who may mark**: the route's rule — `canWrite`, or the job's assignee
  without it — as an affordance (`FieldOperationRules.mayMark`, the house
  `CurrentUser.mayWrite`, failing open on an unknown role). Anyone else sees
  the lines and a sentence saying who marks them. The 403
  (`OPERATION_NOT_ASSIGNED_TO_YOU`) is still handled, in the web's
  `markForbidden` words.
- **The lock (#138's requirement)**: each line's `version` is read with it and
  sent as `If-Match`, the BARE integer, on every mark — live and replayed. A
  line the server sent without a version is shown and not markable: an absent
  `If-Match` is a silent last-write-wins on this route. The web's in-app panel
  sends no `If-Match` online; its offline panel does, and so does this.
- **A 409 on a tap** is said in Bulgarian, the job is re-read, and nothing is
  retried or queued: the operator looks at the line as it now is.
- **No signal** (or a 5xx, 408, 429): the mark is QUEUED with the version it
  saw, owned by whoever tapped, and replayed with that `If-Match`, as the PWA
  does. A newer tap on the same line REPLACES the unsent one (the web's #934),
  never bumping the version on the phone.
- **A replay that meets 409** is a CONFLICT, not a refusal: parked, counted
  apart in the outbox banner («N отбелязване чака вашето решение.»), and shown
  on its line with the web's resolver — «Запази моята» re-sends at the
  server's reported version, «Използвай сървъра» discards it. «Запази моята»
  is not offered when the 409 carried no version.
- **Haptics** (#155's two words): `.success` when a «Готово» lands or is kept
  on the phone, `.warning` on a refusal or a conflict. Skip and reopen play
  nothing — the web's `tap` has no iOS word.

Where iOS goes further, deliberately:

- **Undoing a queued mark sends nothing.** «Готово» then «Отвори отново» with
  no signal leaves the server's status as the target, so the queued mark is
  cancelled on the phone. The web sends PENDING over PENDING, which bumps the
  version and files an audit row for nothing.
- **A read asked before a write cannot undo it.** On a slow connection the
  screen's opening read can answer after the mark's re-read; it is disowned.
- **The drain re-reads each row before sending it**, so a mark replaced
  mid-pass is not sent from the pass's old list. The web's `flushOutbox`
  walks its snapshot.

**The map — ported 2026-10-07 (#177), and it marks more than the web's.**
The web draws every parcel of the job's location alike and shades the
finished ones. iOS (`TaskParcelMap`, read-only, under the progress line as on
the web) marks EVERY parcel of the job by its lines as shown — to do, done,
skipped — so a mark waiting on the phone colours its parcel as it changes its
line. The location's other parcels are thin outlines for context, and the
camera frames the job's parcels, not the location. A job parcel with no
outline is counted under the map, not silently missing from it.
`FieldOperationDetail.parcels` is decoded as the parcel shape of
`GET /locations/{id}/parcels`; agri-saas is documenting it as `ParcelGeo`
(backend 1, 2026-10-07).

**Every other task — 2026-10-08 (#177, agri-saas #1410).** A task that is not
a field operation has a «Парцели» section in the same place: its parcels from
`GET /tasks/{taskId}/parcels` on the same map, all marked alike with no
legend, and their names under it, one marked «без очертания» when it has no
outline. There is no backdrop, because the route sends no location. The
section is absent for a task without parcels. Not covered:

- A task linked to a whole LOCATION shows no parcels. The route does not
  expand that link; «its parcels now» or «the ones it had when linked» is
  undecided server-side.
- A parcel name is not a link to its location: the route's parcels carry no
  location id.

**Live since 2026-10-08, 17:31 UTC**: `/api/health` read 48b36050f, #1410's
merge commit. **Unverified:** a real task with parcels on a phone; fixtures
only so far.

**Comments — 2026-10-08 (#225, owner: «for the mechanisator to leave a
comment»).** Every task has «Коментари» at its foot.

- **Reading:** the comments come with the task (`TaskDetail.comments`, oldest
  first), so they're cached with it and shown offline.
- **Writing:** a composer for everyone but a READER. A comment goes as the
  plain text typed, because the route is plain text (`sanitizePlainText`
  strips every tag). #225 first sent rich text, which would have lost its
  line breaks; fixed before any real comment was sent. A refused comment
  keeps its draft.
- **Shown as stored:** the server keeps literal text («a < b» stays so), and
  the app shows it verbatim, as the web does.
- **Retried, safely:** since agri-saas #1441 (live 2026-10-08) the route
  honours `Idempotency-Key`, so a comment that hits no signal or a 5xx is
  tried twice more with the same key (#232), and a lost answer can't post
  it twice.
- **Unverified:** no comment has been sent from this app; the first is the
  owner's.

**The green tick — 2026-10-08 (#226, owner's decisions).** The status menu is
gone. iOS offered every legal move (`WorkItemStatus.allowedNext`), and the web
still does; the app now has one move, a green ✓ that only CLOSES. This is a
deliberate divergence from the web: «В процес», «Блокирана» and «Отказана» are
made on the web. The tick is there for a writer or the task's assignee
(`setTaskStatus`'s own rule), while the task can still be closed.

It opens a form:

1. «Задачата изпълнена ли е успешно?» Да / Не, required. «Не» still closes.
2. «Какви плевели срещнахте?» Asked when the task has parcels, and required
   then. The choices are the server's 13 (agri-saas `weed-options.ts`, with
   the Bulgarian names from `messages/bg.json`), «Друг плевел» as free text,
   and «Няма плевели».
3. An optional comment.

Where the answers go:

- **The closing note** (the resolution `CLOSED` expects) gets every answer,
  a line each.
- **The weeds** are also recorded on each of the task's parcels through
  `POST /tasks/{taskId}/weed-observations`, agri-saas's task-scoped route.
  It lets the assignee record on the task's own parcels (backend 1's PR A,
  owner-confirmed with them directly).
- **Order:** the close goes first. A refused observation leaves the close
  standing and is said under the task. Each observation is retried twice
  more with its own key on no signal or a 5xx (#232, agri-saas #1441).

**Unverified:** no task has been closed from this app. The first close and the
first weed record are the owner's. The weed route (agri-saas #1434) is live
since 2026-10-08, 19:45 UTC: `/api/health` read a11e72163.

**Wording, dates and one urgency field — 2026-10-09 (#236, owner's
decisions).**

- **«Завършена», not «Затворена».** CLOSED reads «Завършена». The tick and
  the form's button say «Завърши», and the form is titled «Завършване». The
  web's `taskEnums.status.CLOSED` still says «Затворена»; the owner asked
  for the web to follow, on agri-saas's side. Until it does, that one word
  differs.
- **No «Приоритет».** Priority overlapped importance («Важност», which the
  web calls «Сериозност»), so the detail screen dropped it and the model no
  longer reads it. The web still shows it, until agri-saas removes it.
- **A date on every row.** «Отворена на <createdAt>», or «Завършена на
  <completedAt>» once the task is complete; the web's detail label is
  «Завършена на». The list projection has no `completedAt`. agri-saas is
  asked to add it, and until then a completed row shows its opened date,
  labelled as such. The due date on the row is now named, «Срок …».

**Not ported:** the «Необходимо: …» and «… вода» amounts (rate × area — the web's `totalLabel`,
which also skips the ml→L promotion for Cyrillic unit symbols); the spray-job
completion card; the reviewer's approve / request-changes on PENDING_REVIEW
(`POST …/review`, admin-only). The job's move to PENDING_REVIEW after the
last line IS shown: the task above re-reads.

**Unverified**: everything above against the real server. No line has been
marked from this app — the first real mark is the owner's (ROADMAP,
known-unverified). Under the UI-test seam every mark is a 501.

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
  written only at verification. ~~**Server gap:** the PUT answered
  `project(row)` without the derived status, so its response always said
  `NONE`, and the store kept the status it held before the save —
  agri-saas#1358.~~ **Closed** by agri-saas #1375 (live 2026-10-08): the
  PUT derives the status as the GET does, and the store shows it as sent
  (agrent-ios#172). Checked in the deployed code and the server's own
  test, not by a live save — that would be a production write.
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

### Matched — pending invitations, and the ones that never arrived (#365, 2026-10-20)

Членове listed only memberships, so an invitation sent by email to someone
without an account didn't appear until they accepted it. It now opens with
**«Покани»**, from `?view=invites` (agri-saas `PendingInvite`):
- **Each row:** the address, the role and the last day.
- **Not delivered:** **«Поканата не е доставена»**, with the date it was learned, when the server's `inviteDelivery` is set (agri-saas #2084). Every token, known or not, counts.
- **Pending isn't delivered:** `null` means nothing came back. Only invitations sent from 2026-10-20 can be joined to a bounce, and the section's note says so.
- **Network only:** the rows carry addresses, as the members do.

### Профил — every role, since 2026-10-06 (agri-saas#1193 P2.8)

Web `/account` (P2.7: «Вашият акаунт», sections «Профил» and «Сигурност»,
works with zero farms) · iOS `ProfileView`, pushed from the Админ account
card (one `AccountCard`), for every role.

- Shown: the picture or initials, the name, the email — what `/api/auth/me`
  sends — and «Изход», behind a confirmation (`SignOutConfirmation`).
- **Differs from the web on purpose (owner, 2026-10-07):** the app menu has
  no «Профил» or «Изход» rows; the web's user menu keeps both. On iOS the
  menu's «Админ», in a section of its own where they were, is the way to
  both. Админ draws the account row for every role and in every state: above
  «Нямате достъп» for a reader, and as a plain «Профил» row before `/me`
  answers. `UserMessage`'s session-expired text says where Изход is now.
- **The picture (#333, agri-saas #1903/#1951):** «Качване на снимка» /
  «Смяна на снимката» and «Премахване» under the card, the web's words. As
  on the web, a pick uploads at once and removal asks nothing. The web makes
  a 256×256 WebP in its canvas; iOS can't encode WebP, so the phone makes a
  256×256 JPEG the same way: orientation applied, centre cover-crop, pixels
  only. The server takes JPEG or WebP and re-encodes either (owner,
  2026-10-16: no HEIC, so a camera HEIC is converted on the phone). No EXIF
  or GPS leaves the phone. The upload is tens of kilobytes. The card shows
  the JPEG it sent: the serve URL is the same for every upload, so a refetch
  could only show the same picture. A picture changed on the web shows the
  next time the card appears, at most a minute later: the card asks again
  with the server's ETag, and an unchanged picture costs a bodyless 304
  (#345, agri-saas #1958). The server's refusals are said in its
  own Bulgarian; the phone words only its own two failures (a photo the
  library couldn't hand over, a file that isn't a picture).
- Not ported, and why: name editing (`PATCH /api/account/profile`) is route
  code absent from openapi.json, a follow-up once documented. «Сигурност»
  (password change) is for credential accounts; this app signs in through the
  browser. The web's sound/haptics preferences are device-local web settings.

**Unverified (the picture):** no picture has been uploaded or removed from
this app. The first real upload is the owner's, from the phone, once
agri-saas #1951 is live.

### «Цени» — the superuser's daily prices (#258, owner 2026-10-10)

The owner's fallback for the market feeds: a superuser types the day's prices
and they win over the API, for every farm, until cleared. Server: agri-saas
#1587 (contract), built in #1618 (live e4f567145, 2026-10-11).

**iOS:**
- **Offered only** on the platform farm, to its owner or an admin: the farm
  row's `isPlatform` (absent means false) and `role`. Every route still
  enforces its own gate and answers 404 elsewhere.
- **The form** reads `GET …/admin/market-prices/overrides`: per commodity, the
  typed price, the feed's, and whether a feed exists at all (`apiFeed: none`
  is said apart from `api: null`). The unit to type in is the row's
  `entryUnit` (EUR/t; diesel EUR/l), never a phone copy.
- **Saving** sends the day, all or nothing (`{date, prices, clientMutationId}`);
  the server takes no unit from the phone. A retry is safe because each price
  upserts on its series and date. Clearing is per commodity, and clearing
  nothing is not an error.
- **Табло and Тенденции** put the typed series (`source: "platform"`) first,
  across unit groups (#266). Since #409 it's simply THE price on both: see
  «Тенденции and Табло's price».

**Unverified:** no price has been typed from the app. Nothing can be until
the owner creates the platform farm and `PLATFORM_TENANT_SLUG` names it; the
owner makes the first entry. The web console is agri-saas's.

### «Публичен профил» (#323, owner 2026-10-15)

**The phone and the web each have an editor.** The owner chose to build the
phone's now, behind the flag. The web's is agri-saas #1815, shipped in
#1895 and extended in #1930, #1933 and #1939. Both clients write the same
draft, so a field saved on one shows on the other.

- **Where:** Админ → «Публичен профил», right after «Стопанство». Shown
  only when `social.public-profile` is on for the person. The server
  answers 404 on every P6 route while the flag is off (agri-saas #1888),
  and it's off by default.
- **What:** the page's facts read-only, «Редактирай» for name, tagline,
  «За стопанството», oblast and crops, and the web address. A save sends
  only the changed fields (left out is untouched, `null` clears). The
  address is the server's normalised one; when it's taken, the server's
  suggestions are buttons. A published page can be shared (the web share
  kit's URL, agri-saas #1885), opened and withdrawn. Renaming a published
  address asks first.
- **What the page withholds (agri-saas #1933):** «Показва се публично», a
  switch for each of tagline, «За стопанството», oblast and crops, ON
  meaning visible, as on the web. Each switch saves at once and sends only
  its own flag. The text stays stored, so switching a field back on needs
  no retyping. A hidden fact is marked «Не се показва публично» in «Какво
  показва страницата», and said so to VoiceOver. The name and the address
  have no switch: a published page needs both.
- **The A6 card (P6.7, agri-saas #1910):** a published page offers
  «Карта за печат (A6)». It's the server's PDF (name, address, QR code),
  opened in Quick Look to print or share, and deleted when Quick Look
  closes. The phone draws no QR of its own: the server keeps one encoder,
  so a printed code and an on-screen one can't differ. The server refuses
  the card for a page that isn't published, and the phone says why.
- **Publishing, with the web's consent (owner):** «Публикувай» asks for
  consent to the web's text first: agri-saas #1895, version v2 (v2 is the
  owner's review of v1). The phone holds that text word for word, pinned
  by a hash in the tests. The farm agrees with a switch, and the button
  stays disabled until it's on. The phone then records consent and
  publishes, as two calls in that order, as the web does. If publishing
  is then refused, the consent stands and the page stays private. A farm
  that already agreed to v2 publishes straight away. One that agreed to
  another version is told the text changed and asked again. When the web
  moves to v3, the phone's copy follows: text and version together.
  Taking the page down never asks.
- **Oblast:** one of the 28 Bulgarian names the server uses for regions
  (`BulgarianRegion.names`), the form its tests and farm search use
  («Добрич»). The web's editor takes free text instead (up to 80
  characters), and the directory ignores only case (agri-saas #2069). So
  a farm that types «добрич» on the web is found by the phone's «Добрич»
  filter, but one that types «Добричка» is not. Raised on agri-saas
  #1909 (2026-10-16); the fix is the web's, tracked in agri-saas #2068.
- **Not on the phone:** `indexable` (the search-engine toggle, agri-saas
  #1873) and the web's live preview (agri-saas #1939, which renders the
  real page's markup from unsaved edits). Neither was in the owner's choice.
  On the phone, «Какво показва страницата» lists the facts as they'll
  appear, and a published page opens in the app.
- **Admin data, so not cached:** the draft is read on every open, and with
  no signal the page says it couldn't load.

**Unverified:** nothing has been saved, claimed, consented to, published or
withdrawn from this app, and no card has been printed. The flag is off,
and the first real write is the owner's.

### Ahead of the web — «Ферми», the farm directory (#323, owner 2026-10-15)

**The phone lists the published farms; the web has no directory screen.**
The server's directory is `GET /api/public/farms` (P6.8, agri-saas #1817,
live since 12.31.0). It's anonymous and behind the same flag.

- **Where (owner, 2026-10-24):** in Борса's one search, «Култура, регион или
  ферма». The separate «Ферми» screen behind a bar button is gone. The farms
  the search finds sit in a «Ферми» section above the listings, and under
  the map in the map view. With nothing typed and no oblast chosen there is
  no farm section. It only searches while `social.public-profile` is on.
- **Narrowed by the board's own filters (owner):** the directory's `q`
  matches only a farm's name, so the typed text is read first
  (`BoardFarmSearch`):
  - a crop («пшеница», `wheat`, a unique prefix) goes as `crop=`;
  - an oblast goes as `oblast=`;
  - anything else goes as `q=`.

  The oblasti tapped on the map narrow the farms too. The directory takes
  one, so it's one request per oblast, merged. The «Ферми» screen's own
  oblast and crop menus went with it.
- **A farm opens as its web page (owner):** `/f/{handle}` in Safari's view
  inside the app. The server has no JSON read of one farm's page, so a
  native screen would have had no description.
- **At most 50, no paging:** the server's bound. A full answer says to
  narrow the search.
- **Not cached:** a farm that withdraws leaves the directory at once.

**Unverified:** no published farm has been listed. The flag is off and no
farm can publish yet (consent, above).

### «Публикувай от името на стопанството» on a listing (#336, agri-saas #1922)

**A listing can be published as the farm, as on the web.** The server
stores only the choice. The farm's verified name and address are read live
on every read (`farmHandle`), so a farm that renames its address or takes
its page down changes every attributed listing at once.

- **«Нова обява»:** the switch, with the web's footer word for word, sent as
  `publishAsFarm: true` only when on. It's always enabled, as on the web:
  whether the farm's page is public takes an admin-only read, and the
  server accepts the choice either way.
- **A listing's page:** an attributed listing shows «Страницата на
  стопанството» under the seller, opening `/f/{handle}` in the in-app
  browser, as «Ферми» does.
- **Behind `social.public-profile` on the phone, unlike the web:** `/f/`
  answers only while the flag is on (it's checked server-wide), so outside
  it the switch can't attribute anything and the link wouldn't open. The
  web offers the switch to everyone: agri-saas #1929.

**Unverified:** no listing has been posted from the phone (the owner makes
the first send), and no attributed listing has been seen on the real server.

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
  with the screen saying what to do. Five sites: a field operation saved or
  kept, a task status changed, a message sent, the farm profile saved, and
  — since 2026-10-07 (#138) — a parcel line marked: «Готово» `.success`,
  a refusal or a conflict `.warning`, skip and reopen nothing (the web's
  `tap`). The other writes close onto a list showing the new row; each is a
  one-line addition if wanted. `HapticSiteTests` lists the sites exactly.
- Never from the app's own work: polls, refreshes, cache revalidation and
  the outbox drain record nothing. The pull-to-refresh tick comes from the
  system's refresh control, not from this.
- Not ported: the web's «Звук и вибрация» card (`FeedbackPrefsCard`:
  «Звук при успех», «Тактилна обратна връзка») is browser localStorage with
  no API, and the web also gates haptics on
  reduced motion. iOS's System Haptics setting governs instead; an in-app
  switch is a follow-up only if the preference ever reaches the server.

---

## Risk by parcel

### Divergence — one «Застраховай», bottom right; «История» works (#386, owner 2026-10-21)

- **One way to ask:** the screen's floating «Застраховай» at the bottom right. It opens the enquiry form with no parcel chosen, and the person picks it there. The per-row «Запитай за оферта» / «Запитай отново» is removed. A row still shows «Изпраща се…» while an ask is out, and «Заявено запитване» once one was made.
- **The floating button moved** from bottom-left to bottom-right, where Задачи's + is. The risk page is its only user.
- **«История» on a row opens the parcel's history.** It did nothing before, because the button read `pushRoute` from outside the stack it pushes onto.

## Blocks (Блокове)

### Divergence — a parcel on the map opens its history (#387, owner 2026-10-21)

- **A tap on a parcel** (either map, or a row of the list under it) opens the parcel's history for every role, where it used to open «Ново мероприятие» for those who may record. Overlapping shapes still ask which parcel first.
- **«Ново мероприятие» moved to the history**, as a bottom button for that parcel, shown to someone who may create an operation (`mayCreateOperations`). The route carries the parcel and its block (`ParcelInBlock`), so the button works while the history loads or fails. A history opened from Риск has no such button, as before.

## Тенденции and Табло's price

### Matched, with one divergence — one price, one line, one row (#409, owner 2026-10-23)

The owner asked for "a clear price above the graph" and "max 1 info row
below a graph". The screen used to draw three lines with no number above
them, and listed every quotation in the payload underneath: 24 for wheat,
each with a price, a day and an amber age. Some of those names were in the
EC feed's English.

**Which price, as on the web.** It follows agri-saas `trends-helpers.ts`
(`selectPrimaryGroup`, `chartSeriesFor`, `leadSeriesOf`), implemented once as
`Array.lead()`:
1. Agrent's typed price comes first (#1587).
2. Then one (region, currency, unit) group: Bulgaria, then the EU average,
   then whichever reported last. A group of only our own listings is a last
   resort.
3. Inside the group, the national average where EC publishes one (wheat,
   maize, barley). The owner chose it over the freshest quotation.
4. Otherwise the freshest.

Табло quotes the same series, so the two screens show one number.

**The screen:**
- The commodity, then the range, then a card.
- The card shows the price large («208,62 евро на тон») and its change over
  the chosen period («▲ 1,8 % за 1 година»), as an arrow and words, never a
  colour.
- Under it, one line, and one row: «Средна за България · 27 юли», amber with
  «преди 88 дни» past three weeks.
- The other quotations aren't on the screen, which is the owner's choice, as
  on the web.

**Never the feed's English** (`SeriesSource`):
- EC stages are recognised loosely, the way the web's `isNationalAverage` is,
  because EC has renamed them once already.
- Delivery points become Bulgarian city names, and «Departure from farm…»
  becomes «франко стопанство».
- Anything unrecognised is left out rather than shown.
- Табло's line under the price used to print the region code and the English
  stage. It now uses the same name, and its «1 от N серии — вижте Тенденции за
  всички» is gone, since Тенденции no longer lists them.

**Divergence:** the web's tile shows the week-over-week change. The phone
shows the change over the range on screen, which is the owner's choice
(2026-10-23), so the number agrees with the line being looked at.

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
3. ~~**Gap 8 — marking a field operation's parcel lines.**~~ Closed
   2026-10-07 (#138). Ships unfired too: a mark deducts stock and files a
   ДНЕВНИК row, and the first real one is the owner's. The map and the
   per-parcel amounts are follow-ups, not part of it.

Everything else on this list is closed. The order the original version
suggested held up: the AX3 failures first, because a screen that cannot
be read outdoors fails before any parity gap matters.
