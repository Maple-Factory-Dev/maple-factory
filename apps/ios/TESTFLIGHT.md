# The iPhone app on TestFlight

Getting `apps/ios` to testers: part 1 is the one-time setup only a person with the Apple account can do,
part 2 is the command that uploads a build, part 3 is optional testing outside the team.

What's already done in the repo: device builds sign with team `TU4485Z3KR` (project.yml), the Info.plist says
`ITSAppUsesNonExemptEncryption = false` (HTTPS only, so no export-compliance question per build),
`Resources/PrivacyInfo.xcprivacy` declares UserDefaults (reason CA92.1) and Sentry's crash and diagnostic
data, and `scripts/testflight.sh` archives, signs and uploads.

| | |
|---|---|
| App name | Maple Factory |
| Bundle ID | `dev.maplefactory.ios` |
| Team | Andrea Fomera, `TU4485Z3KR` |
| Version | `MARKETING_VERSION` in project.yml (0.1.0); the build number is a UTC timestamp per upload |
| Signing | Automatic: the Apple Distribution certificate in the login keychain, profiles made on demand |

## Part 1: the steps only you can do

Do these once, in order. Each takes a few minutes.

### 1.1 Confirm the Apple Developer membership

[developer.apple.com/account](https://developer.apple.com/account) → Membership details: the Apple Developer
Program is active for team `TU4485Z3KR`, and you're the Account Holder or an Admin. Accept any pending
agreements there and under App Store Connect → Business (an unsigned agreement blocks uploads with no
clear error).

Check the keychain has the distribution certificate: `security find-identity -v -p codesigning` lists
`Apple Distribution: Andrea Fomera (TU4485Z3KR)`. If it doesn't, Xcode → Settings → Accounts → the team →
Manage Certificates → + → Apple Distribution.

### 1.2 Register the App ID

[Certificates, Identifiers & Profiles → Identifiers](https://developer.apple.com/account/resources/identifiers/list) → + → App IDs → App:

- Description: `Maple Factory iOS`
- Bundle ID: Explicit, `dev.maplefactory.ios`
- Capabilities: none needed (the app uses no push, iCloud or app groups yet).

`testflight.sh` runs with `-allowProvisioningUpdates`, so it registers the ID and makes the profiles itself
when the account allows. On 2026-10-31 the first `--no-upload` run did exactly that, making "iOS Team Store
Provisioning Profile: dev.maplefactory.ios", so check the list and skip this step if the ID is already there.
1.3 needs the ID registered.

### 1.3 Create the app in App Store Connect

[App Store Connect → Apps](https://appstoreconnect.apple.com/apps) → + → New App:

- Platforms: iOS
- Name: `Maple Factory` (must be unique on the App Store; if it's taken, `Maple Factory: Agents` or similar;
  the name on the home screen stays `CFBundleDisplayName`)
- Primary language: English (U.S.)
- Bundle ID: `dev.maplefactory.ios` (from 1.2)
- SKU: `maple-factory-ios` (private, anything unique)
- User access: Full access

### 1.4 Make an App Store Connect API key

App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys → + :

- Name: `maple-factory testflight`
- Access: **App Manager** (enough to upload and manage TestFlight; Admin also works)

Download the `AuthKey_<KEY_ID>.p8` straight away: Apple lets you download it only once. Put it in
`~/.appstoreconnect/private_keys/` (outside the repo; `*.p8` is gitignored anyway). Note the **Key ID**
(in the key's row) and the **Issuer ID** (the UUID above the list).

If you already have a team key with App Manager access (there's an `AuthKey_8BA9U6GLF4.p8` in
`~/.appstoreconnect/private_keys/` on this Mac), you can use that instead.

### 1.5 Fill in .env.testflight

```sh
cp apps/ios/.env.testflight.example apps/ios/.env.testflight
```

Set `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_PATH` (from 1.4). `BUILD_NUMBER` can stay empty.
`SENTRY_AUTH_TOKEN` is optional: with it (and `brew install getsentry/tools/sentry-cli`) the script uploads
the dSYMs to the `maple-ios` Sentry project so crash reports are symbolicated. The same variables in the
environment win over the file, which is how CI would pass them.

### 1.6 Fill in TestFlight's Test Information

App Store Connect → the app → TestFlight → Test Information:

- Beta app description: what Maple Factory is and what to try (the inbox, approving a plan, a task's diff).
- Feedback email: where testers' screenshots and comments go.
- Privacy policy URL (see 1.8).
- Beta App Review information (needed for part 3, harmless to fill now): a contact name, phone and email,
  and **sign-in information**. A reviewer has no factory, so say: *"Tap **Try the demo** on the first
  screen: it runs a sample factory with no account."* If you'd rather they see a live factory, give a test
  factory's URL and a GitHub account that's a member of it, and untick "Sign-in required" only if the demo
  covers everything.

### 1.7 Answer the App Privacy questionnaire

App Store Connect → the app → App Privacy → Get Started. Answer to match `Resources/PrivacyInfo.xcprivacy`:

- Do you collect data? **Yes**.
- Diagnostics → **Crash Data** and **Other Diagnostic Data**: used for **App Functionality**; **not linked**
  to the user's identity; **not used for tracking**.
- Nothing else (no contact info, identifiers, usage data or location; the GitHub sign-in token stays in the
  Keychain and goes only to the factory you sign in to, which you run, not Apple or us).

This is required before external testing and the App Store, not for internal TestFlight.

### 1.8 Add a privacy policy URL

App Store Connect → the app → App Information → Privacy Policy URL. maplefactory.dev has no privacy page
yet; `security.html` covers what each app reports and how to turn it off, so either point at
`https://maplefactory.dev/security` for now or publish a `/privacy` page from it. Required for external
testing (part 3).

### 1.9 Create an internal testers group

App Store Connect → the app → TestFlight → Internal Testing → + → name it `Team`. Add testers: they must be
users in Users and Access (any role) and get an email to install the TestFlight app. Turn on
"Enable automatic distribution" so every processed build reaches them. Internal testing needs no Beta App
Review; up to 100 testers.

## Part 2: upload a build

```sh
apps/ios/scripts/testflight.sh
```

It runs `xcodegen generate`, archives a Release build for `generic/platform=iOS` with build number
`BUILD_NUMBER` (default: the UTC time, e.g. `202610312130`), signs it for App Store Connect and uploads it,
then uploads the dSYMs to Sentry if `SENTRY_AUTH_TOKEN` is set. Logs go to `apps/ios/build/testflight.log`.

- `--no-upload` stops at a signed `apps/ios/build/Maple Factory.ipa` (handy to check signing; it can use the
  account signed in to Xcode instead of the API key).
- After the upload, App Store Connect processes the build for 5–30 minutes and emails you. It then shows
  under TestFlight → Builds, and the internal group gets it (with automatic distribution on, or add it to the
  group by hand).
- A new version for testers is just another run. Bump `MARKETING_VERSION` in project.yml when you want testers
  to see a new version number; the build number takes care of itself.

## Part 3 (optional): external testers

For people outside App Store Connect (up to 10,000, by email or a public link):

1. 1.6, 1.7 and 1.8 must be complete.
2. TestFlight → External Testing → + → a group (e.g. `Early access`), add the build. The first build of each
   version goes to **Beta App Review** (usually under a day); later builds of the same version usually don't.
3. Once approved, add testers by email or turn on the public link.

## Troubleshooting

| Error | Fix |
|---|---|
| `Missing App Store Connect API key settings` | 1.4 and 1.5: set `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`. |
| `The bundle version must be higher than the previously uploaded version` / `has already been used` | A duplicate build number. Leave `BUILD_NUMBER` empty (the timestamp always goes up) or set a higher one. |
| `Invalid large app icon … can't be transparent or contain an alpha channel` | `Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png` must have no alpha: `sips -g hasAlpha` it; fix with `sips -s format jpeg AppIcon.png --out /tmp/i.jpg && sips -s format png /tmp/i.jpg --out AppIcon.png`. (Today's icon has none.) |
| `No profiles for 'dev.maplefactory.ios' were found` / `requires a provisioning profile` | The App ID isn't registered or the key can't make profiles: do 1.2, and check the key has App Manager or Admin access. Signing in to Xcode (Settings → Accounts) also lets `--no-upload` make them. |
| `No signing certificate "iOS Distribution" found` | 1.1: the Apple Distribution certificate isn't in this Mac's keychain. |
| `No Accounts` / `No account for team "TU4485Z3KR"` | Neither an API key nor an Xcode account: fill in 1.5, or sign in to Xcode. |
| `ITMS-91053: Missing API declaration` email after upload | A dependency or new code uses a required-reason API not in `PrivacyInfo.xcprivacy`: add the category and reason the email names. |
| `Cannot be used with TestFlight because the build is missing an export compliance` | `ITSAppUsesNonExemptEncryption` dropped out of project.yml's `info.properties`; put it back. |
| `value of type … has no member` / `unable to type-check this expression in reasonable time`, but the Mac app and the simulator build fine | The checkout changed mid-archive (a `git pull`, or the release loop fast-forwarding it), so part of the app was compiled from the old sources and part from the new. The script now archives a snapshot at `build/src` (the `Snapshot:` line names the commit), so a pull can't do that any more; rerun it. Untracked files aren't in the snapshot: `git add` them. |
| Agreements, tax or banking warnings block the upload | 1.1: accept them in App Store Connect → Business. |
