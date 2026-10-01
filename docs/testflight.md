# TestFlight

`.github/workflows/testflight.yml` archives a Release build, checks it, and
uploads it to App Store Connect. It runs only when asked (Actions → TestFlight →
Run workflow) or when a `v*` tag is pushed — never on a PR or a merge.

## One-time setup (owner)

All in the Apple Developer / App Store Connect account that will own the app.

1. **Register the bundle ID.** developer.apple.com → Certificates, Identifiers &
   Profiles → Identifiers → **+** → App IDs → App → Explicit, Bundle ID
   `bg.agrent.app`, description "Agrent". No capabilities need ticking.
2. **Create the app record.** appstoreconnect.apple.com → Apps → **+** → New App:
   platform iOS, name "Agrent" (must be unique on the store — any variant works
   for TestFlight), primary language Bulgarian, bundle ID `bg.agrent.app`, SKU
   anything (e.g. `agrent-ios`). Without this record every upload is refused.
3. **Create an API key.** App Store Connect → Users and Access → Integrations →
   App Store Connect API → Team Keys → **+**. Name "GitHub TestFlight", access
   **App Manager**. Download the `.p8` (Apple lets you download it **once**).
   Note the **Key ID** beside it and the **Issuer ID** above the table.
4. **Find the Team ID.** developer.apple.com → Account → Membership details →
   Team ID (10 characters).
5. **Add them to GitHub.** github.com/RodnaPamet/agrent-ios → Settings →
   Secrets and variables → Actions:

   | Kind | Name | Value |
   |---|---|---|
   | Secret | `ASC_KEY_ID` | the Key ID (10 characters) |
   | Secret | `ASC_ISSUER_ID` | the Issuer ID (a UUID) |
   | Secret | `ASC_KEY_P8` | the **whole** `.p8` file, `-----BEGIN PRIVATE KEY-----` to `-----END PRIVATE KEY-----` inclusive |
   | Variable | `APPLE_TEAM_ID` | the Team ID |

   Then delete the downloaded `.p8` or keep it in a password manager — never in
   the repo (it is public, and CI rejects credential-shaped strings).

Optional: Settings → Environments → `testflight` → Required reviewers, to make
every upload wait for your approval. The environment appears after the first run.

## Uploading a build

- **Any time:** Actions → TestFlight → Run workflow → branch `master`.
- **For a release:** bump `MARKETING_VERSION` in `project.yml`, merge, then
  `git tag v0.2.0 && git push origin v0.2.0`. The run fails if the tag and
  `MARKETING_VERSION` disagree.

The build number is `<run number>.<attempt>` (e.g. `14.1`), so it always rises.
After a green run, App Store Connect takes 5–30 minutes to process the build;
it then appears under the app's **TestFlight** tab.

## Testers

- **Internal** (up to 100, people in your App Store Connect team): TestFlight →
  Internal Testing → **+** group → add users. They get every processed build at
  once, no review. Each needs a role in Users and Access first.
- **External** (up to 10,000, anyone by email or public link): TestFlight →
  External Testing → **+** group → add testers or enable a public link → add a
  build. The first build of each version goes through **Beta App Review**
  (usually under a day), which needs Test Information filled in: a
  feedback email, a description, and a **demo account** that can sign in — the
  reviewer cannot get past sign-in otherwise.

Testers install the **TestFlight** app from the App Store and accept the invite.

## Export compliance

Answered in the build: `ITSAppUsesNonExemptEncryption = false` in `project.yml`,
so builds do not stop at "Missing Compliance". That is correct because the app's
only cryptography is Apple's own HTTPS/Keychain (exempt) and SHA-256 hashing
(not encryption). If the app ever encrypts data itself, change it to `true` and
answer the questions in App Store Connect.

## If a run fails

- *"Not configured: …"* — a secret/variable above is missing or misnamed.
- *"No profiles for 'bg.agrent.app' were found"* / *"No Account for Team"* —
  `APPLE_TEAM_ID` is wrong, or step 1 was done in a different team.
- *"Cloud signing permission error"* at export — the key cannot use Apple's
  cloud-managed distribution certificate. Recreate it with **Admin** access
  and replace the three secrets.
- *"The bundle version must be higher than the previously uploaded version"* —
  only if builds were uploaded by other means with larger numbers; raise
  `MARKETING_VERSION`.

Before the App Store (not needed for TestFlight): fill in App Privacy in App
Store Connect to match `Agrent/Resources/PrivacyInfo.xcprivacy` — User ID and
Other User Content, linked to the user, for app functionality, no tracking.
