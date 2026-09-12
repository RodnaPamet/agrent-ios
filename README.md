# Agrent iOS — journal slice

A native SwiftUI client for the Field Journal, talking to the existing
`app.agrent.bg` API. No web code is reused and none is touched.

**688 lines of Swift, 11 files. Written on Linux and never compiled** — expect
to fix a few small things in Xcode on the first build. Everything it talks to
was read from the server source, not guessed.

---

## Before the app can sign in — a server change is required

The native auth endpoints already exist (`/api/auth/native/*`, shipped in
#601/#603), but **the redirect allowlist is empty by default and fails
closed**. Until it is set, every sign-in returns `redirect_uri_not_allowed`.

On the VM, add to `/opt/agrent/.env`:

```
NATIVE_AUTH_REDIRECT_ALLOWLIST=bg.agrent.app://auth/callback
```

then restart the app container. It is comma-separated, so a second scheme for
a debug build can be appended later.

This is the only server-side change the slice needs.

---

## On the Mac mini

1. **Xcode → File → New → Project → iOS → App.**
   - Product Name: `Agrent`
   - Interface: **SwiftUI**, Language: **Swift**
   - Uncheck Core Data and Tests for now.
   - Save it somewhere outside this folder.

2. **Replace the generated sources with these.** Delete the `ContentView.swift`
   and `AgrentApp.swift` Xcode made, then drag the `Agrent/` folder from this
   repo into the project navigator with *Copy items if needed* ticked and
   *Create groups* selected.

3. **Register the URL scheme.** Target → Info → *URL Types* → **+**
   - Identifier: `bg.agrent.app`
   - URL Schemes: `bg.agrent.app`

   This must match `Config.redirectScheme` and the server allowlist. All three
   agree or sign-in fails.

4. **Set your tenant.** In `Config.swift` replace
   `REPLACE_WITH_YOUR_TENANT_SLUG` with the slug from your web URL —
   `app.agrent.bg/t/<slug>/journal`.

5. **Signing.** Target → Signing & Capabilities → your Apple team. Bundle
   identifier `bg.agrent.app`.

6. **Minimum deployment: iOS 17.** The code uses `@Observable` and
   `ContentUnavailableView`, both iOS 17+.

7. Plug the iPhone in, pick it as the run destination, **⌘R**.

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

Every create sends an **`Idempotency-Key`**. The server dedupes on it
(`LogEntry.clientMutationId`, unique per tenant), so a request whose *response*
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

`LogEntry.version` and `lastMutationId` exist on the model and are being wired
into the write path right now by the session working the offline lane. The
model here carries `version` but does not yet send `If-Match` — that lands when
the server contract settles.

`public/openapi.json` has component schemas but **zero paths**, so it could not
be used to generate this. Worth fixing separately: an API document that
describes no endpoints is not much of a document.
