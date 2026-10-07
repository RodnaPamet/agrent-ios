# CLAUDE.md — agrent-ios

Native SwiftUI client for Agrent (Bulgarian farm-operations SaaS); server is `RodnaPamet/agri-saas`. This repo is public. iOS 17, Swift 5.9 mode, XcodeGen: `project.yml` is the source of truth; never commit the generated `Agrent.xcodeproj` or `Agrent/Info.plist`.

## Build and test

`xcode-select` points at CommandLineTools here, so every command needs `DEVELOPER_DIR`:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate --quiet   # after adding/removing files
scripts/check.sh            # build + XCTest + CI warnings gate
DESTINATION="platform=iOS Simulator,name=iPhone 17 Pro" scripts/check.sh
```

- Pass = `0 failures` + `source warnings: 2 / 2 allowed` (the two known `ISO8601DateFormatter` captures in `APIClient`). Incremental builds may print `0 / 2`; only a clean build proves the count.
- XCTest only. Source-reading tests (`#filePath`) are fine where no runtime hook exists — give each a positive control.
- `check.sh` skips the Guards job: run the guard steps from `.github/workflows/ci.yml` yourself before pushing.
- Limited memory → one `xcodebuild` at a time.
- `scripts/a11y-shots.sh` screenshots the app on synthetic fixtures (launch arg `AGRENT_UITEST_FIXTURES`); output stays outside the repo.

## CI guards

| Guard | Rule |
|---|---|
| Dates, chart axes | Format via `BgDate` only; add new forms inside `BgDate.swift` |
| Commodity names | A file using `.commodity` must also use `CommodityName` |
| Colours | Semantic colours from `Palette` only (no `.red`, `.secondary`, …) |
| Sheet actions | Each `.confirmationAction` / `.cancellationAction` has `.accessibilityInputLabels` |
| Interpunct | `·` only via `MetaSeparator` |
| Test targets | Every unit-test target is in the scheme — add files, not targets |
| UI test seam | Code naming `UITestSeam` / `FixtureURLProtocol` / `FixtureCatalogue` sits under exactly `#if DEBUG`; the seam never reaches Release |
| Credentials | No token- or JWT-shaped strings anywhere, fixtures included |
| Warnings | No new source warnings: no deprecated APIs, nothing iOS 18-only |

## House rules

| Rule | Detail |
|---|---|
| Server contract from the spec | agri-saas `src/generated/openapi.json`, plus route code where the spec is thin. Peer sessions describe intent; spec and code are what shipped |
| Client headers on every request | All requests go through `ClientHeader.stamp`: `X-Agrent-Client: ios/<major>.<minor>` (telemetry) and `x-agrent-client-version: <contract>` (the server's 426 gate). Raise `ClientHeader.contractVersion` only in a release that understands the newer contract. A test fails on any unstamped `URLRequest` |
| No URL disk cache | Sessions use `NoURLCache`. The only on-disk cache is `ResponseCache`, keyed by user + farm; messaging and admin data never touch disk |
| Every built path exists on the server | `RouteContractTests` checks against `Tests/Contract/agri-saas-routes.txt`; refresh via `scripts/refresh-agri-saas-routes.sh` |
| Outward-facing writes ship unfired | Never send a message, open a thread, create a listing or write to production from development, CI or A11yShots — the owner makes the first real send |
| Synthetic fixtures | No real names, geometry, conversations, national IDs or emails (public repo) |
| Sign-out resets per-user state | Via `SessionReset.resetUserState()`; a test fails if a new `static let shared` singleton isn't accounted for |
| Bulgarian UI | Error text via `UserMessage` (Cyrillic, ends with a full stop); Voice Control names via `A11y.Spoken`, Cyrillic first |
| Comments | Explain *why* in full, matching the surrounding density |

## Workflow

- Branch → PR → squash-merge yourself once every CI check reads `pass` (standing approval). "No failures yet" is not green.
- Record decisions and unverified items in `PARITY.md` / `ROADMAP.md`; file new work as GitHub issues.
- After writing Swift, review it with `swiftui-pro`, `swift-concurrency-pro` and `ios-accessibility`.
