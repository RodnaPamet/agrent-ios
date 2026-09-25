# Agrent iOS — journal slice

A native SwiftUI client for the Field Journal, talking to the existing
`app.agrent.bg` API. No web code is reused and none is touched.

**771 lines of Swift, 11 files. Written on Linux and never compiled** — expect
to fix a few small things in Xcode on the first build. Everything it talks to
was read from the server source, not guessed.

---

## Before the app can sign in — server state

**The redirect allowlist is SET (2026-09-17).** `/opt/agrent/.env` now carries:

```
NATIVE_AUTH_REDIRECT_ALLOWLIST=bg.agrent.app://auth/callback
```

The container was **recreated, not restarted** — `env_file` is read at container
creation, so `docker restart` would have silently applied nothing. Verified with
both controls: the start endpoint went **400 → 307**, and an unlisted scheme
still returns **400**, so the allowlist is enforcing rather than disabled. It is
comma-separated, so a debug scheme can be appended later.

**One blocker remains, and it is in the web app rather than the VM.** Getting
past the 400 revealed that `/api/auth/native/start` builds its redirect from
`new URL(req.url).origin` (`route.ts:35`, `:98-99`) instead of the configured
public origin, so it hands the browser `https://0.0.0.0:3000/...`, which a phone
cannot reach. This is not a deployment problem: `APP_URL`, `NEXTAUTH_URL` and
`AUTH_URL` are all `https://app.agrent.bg` inside the container, and Caddy
forwards `Host {host}` and `X-Forwarded-Proto {scheme}`. The route discards
them. The sibling route `sso/oidc/callback/route.ts:107` already does it right —
`env.APP_URL || req.nextUrl.origin`. Fixed separately in agri-saas; until that
ships, the app builds and runs but sign-in cannot complete.

---

## On the Mac mini

```bash
gh repo clone RodnaPamet/agrent-ios
cd agrent-ios

brew install xcodegen      # once
xcodegen generate          # writes Agrent.xcodeproj from project.yml
open Agrent.xcodeproj
```

`project.yml` is the source of truth; the `.xcodeproj` is derived and
gitignored, so regenerate rather than hand-edit it. Generating it already sets
the three things most easily got wrong by hand:

| | |
|---|---|
| Bundle identifier | `bg.agrent.app` |
| URL type | `bg.agrent.app` — must match `Config.redirectScheme` **and** the server allowlist |
| Deployment target | iOS 17.0 — `@Observable`, `@Environment(_.self)`, `MainActor.assumeIsolated`, `ContentUnavailableView` |

Then:

1. **Check the tenant.** `Agrent/Config.swift` is set to `agrent`, the slug
   from `app.agrent.bg/t/agrent/journal`. Production has exactly two tenants
   (`agrent`, 4 members; `pwc-mt6a7ff0`, 1), so this is almost certainly right
   — but confirm it against your own address bar. A wrong slug fails *after*
   sign-in, with an empty or 404ing journal list, not at the sign-in step.

   Hard-coded on purpose for the slice. `GET /api/auth/me` returns it for the
   signed-in user, and reading it from there is one of the listed
   not-yet-done items below.

2. **Build for the simulator first** — ⌘R against any iPhone simulator. No
   signing, no Apple ID, no device. This code was written on Linux and has
   never been compiled, so proving it *builds* is the milestone worth having
   before signing enters the picture.

3. **Then a device**, once it compiles: Signing & Capabilities → your team.
   A free Apple ID gives a 7-day provisioning profile; a paid account a year.
   Plug the iPhone in, pick it as the run destination, ⌘R.

### What is most likely to fail on that first compile

Two shapes, both in `AuthClient.swift`, flagged from reading rather than from a
build — there is no macOS on the machine this was written on:

- **`@Observable` + `@MainActor` on an `NSObject` subclass** (`:11-13`). The
  macro and `NSObject` together are the fiddliest thing in the file.
- **`nonisolated func presentationAnchor` calling `MainActor.assumeIsolated`**
  (`:132-141`). Fine under Swift 5; Swift 6 strict concurrency may reject it.
  `project.yml` pins `SWIFT_STRICT_CONCURRENCY: minimal` for exactly this
  reason — if Xcode offers to migrate to Swift 6, decline until it runs.

---

## What it does

- **Sign in** through the system browser with PKCE — not a webview, because
  Google refuses OAuth in embedded webviews (`disallowed_useragent`). If you
  are already signed in to `app.agrent.bg` in Safari, it is one tap.
- **List** the 50 most recent journal entries, pull to refresh.
- **Create** an entry: type, date, title, notes.
- Tokens in the **Keychain**, refreshed automatically on 401, single-flight so
  three concurrent requests cause one refresh.

## Writes, and why they are shaped this way

**Six writes send an `Idempotency-Key`**, and this said "every create" — which
was aspirational and journal-scoped, and is contradicted by five `nil` call
sites. The ones that send it: journal create, journal edit, farm-task,
field-operation, task status, the exchange message send, and the grain cost
create. The ones that do not: the parcel-history creates, exchange listings,
admin, `POST /grain/contracts` and `POST /locations/:id/parcels` — the last of
which says outright that a replayed create draws a second parcel. The rule is
per ROUTE; see `ROADMAP.md` for the table.

Where it is sent, the server dedupes on it
(`clientMutationId`, unique per tenant), so a request whose *response*
was lost — the ordinary case on a tractor — replays without writing a second
entry. The key is minted once per logical create and reused across retries;
minting it per attempt would defeat the whole mechanism.

This matters more here than in most apps: the journal is the БАБХ ДНЕВНИК, a
regulatory record. A duplicated entry is not a cosmetic bug.

The create form **stays open when a write fails**. Closing a form after a
refused write reads as success and loses the operator's work — that is a real
defect currently filed against the web app (#921).

## What it deliberately does not do yet

- **No offline queue.** The web app has a 1,066-line service worker and an
  outbox that is actively being corrected (ten open issues). Reimplementing
  that natively is the expensive part of the migration and should not be
  guessed at — it is the next decision, not the next commit.
- No photos, no locations/equipment pickers, no edit or delete, no harvest
  fields. The create form covers four fields of a modal that has sixteen.
- Tenant is hard-coded rather than read from `/api/auth/me`.
- One page of results, no paging.

## Contract notes

Read from the server source, current as of this writing:

| | |
|---|---|
| `GET /api/t/:slug/journal?limit=50` | list |
| `POST /api/t/:slug/journal` | create, honours `Idempotency-Key` |
| `GET /api/auth/native/start` | `redirect_uri`, `code_challenge`, `code_challenge_method=S256`, `provider` |
| `POST /api/auth/native/exchange` | `{code, code_verifier}` → `{accessToken, refreshToken, expiresIn}` |
| `POST /api/auth/token/refresh` | `{refreshToken}` → same shape |

### Write rules, confirmed with the session that owns the write path

The wire contract is **settled**; what is still moving is client-side only.

- **`Idempotency-Key` on the writes that honour it** (not on every write — see
  above), minted *before the first attempt* and
  reused for every retry of that same write. Mint it per attempt instead and a
  response lost after the server committed creates a **second record** —
  traced, two rows every time, on all three create routes.
- A replay returns the **original entry, 200/201** — not a 409.
- **Edits must send `If-Match: <version>`**, digits only. The version
  increment sits *inside* the If-Match guard, so an unguarded PATCH changes
  content without moving version and every later optimistic lock is wrong.
  Mandatory, not an optimisation.
- **The 409 body is nested**: `error.details.currentVersion`, not
  `currentVersion`. The web client read it one level too shallow for months
  and its keep-mine retry silently sent no If-Match at all.
- **426 means the client is too old**, not that the write was refused. Show an
  upgrade prompt; do not park the queue.

Four behaviours in the web client are defects, not the contract, and are
deliberately not mirrored here: a 409 closing a form like a success, 426 as a
terminal refusal, `markOperationParcel` answering 409 vs 200 for the same
state by timing, and `PlantingBoard` creating entries through a keyless post.

When this was written `public/openapi.json` had component schemas but **zero
paths**, so it could not be used to generate this client. That has since been
fixed (#947/#948/#953): the document moved to `src/generated/openapi.json` and
now describes **26 paths and 87 schemas**. A later version of this client could
be generated from it rather than hand-written — the hand-written contract notes
above are what it replaces.
