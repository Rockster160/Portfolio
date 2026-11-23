# Buddy for iOS

The native companion to the site: push that doesn't expire, Live Activities and AlarmKit for
timers, widgets, hot links, App Intents ("Tell Buddy …"), an offline command queue, the share
sheet, and native battery / location / workout / calendar / reminders / contacts triggers.

Every screen is the site. The app is one web view, and its own pages are site pages using the
site's styles: the login (`/app/login`), each phone's settings and hot links
(`/account/app_devices/:id`), the command console and queue (`/app/commands`), the quick prompt
(`/app/compose`) and the share sheet (`/app/share`). There are no stock iOS screens. Pages reach
the phone through the `buddy` message handler (`Shared/Core/WebShell.swift`, used by
`app/javascript/src/pages/buddy_app.js`): the queue, permission requests, and what's being
shared.

Settings live on the server, so they can be changed from any browser. The phone reports what iOS
allows, and a silent push tells it the moment something changes on the site. A feature that needs
a permission stays locked on the site until it's allowed with a tap in the app; after that it's
set up from anywhere. What each feature is, its options and its Jil triggers are listed once, in
`app/service/app_devices/features.rb`.

The Buddy page opens with no signal, however long it's been and after a force close. The site's
domains are app-bound (`WKAppBoundDomains`), which lets the page's own service worker
(`public/byte_worker.js`) run in the app and serve it from the phone, and the app asks for
`byte.<server>` directly instead of through a redirect. Buddy shows asleep, and messages wait in
the page's queue. The phone keeps a held copy of that queue and sends it in the background once
the app is closed; the server keeps one message per `local_id`, so nothing doubles.

Widgets and Live Activities can't be web pages, so they draw with the site's palette
(`Shared/Views/SiteStyle.swift`, taken from `_variables.scss` and `forms.scss`).

## Layout

| Path | What |
|---|---|
| `project.yml` | XcodeGen definition; `Buddy.xcodeproj` is generated and gitignored |
| `Config/Shared.xcconfig` | Team ID, bundle id, App Group, server URL — the one place identity lives |
| `Shared/Core` | API client, keychain session, outbox queue, features, models — in every target |
| `Shared/Intents`, `Shared/LiveActivity`, `Shared/Views` | App + widgets |
| `App` | The app: the web view and its bridge, push, device services |
| `Widgets` | Widgets, the timer Live Activity, Control Center controls |
| `NotificationService` | Turns a push's `actions` into real buttons; attaches images |
| `Share` | The share sheet |

## First build

1. `brew install xcodegen` (once), then `ios/buddy/bin/xcode` from anywhere in the repo. It
   regenerates the project and opens it; run it again after a pull that adds or moves files.
2. `Config/Shared.xcconfig` names the signing team (`DEVELOPMENT_TEAM`, the same Ardesian team
   that signs Astra); a gitignored `Config/Local.xcconfig` overrides it per machine.
3. In the developer portal, the App ID `com.ardesian.buddy` needs: Push Notifications, App Groups
   (`group.com.ardesian.buddy`), HealthKit, Time Sensitive Notifications. Automatic signing
   creates the extension App IDs (`.widgets`, `.notification-service`, `.share`); each needs the
   same App Group.
4. Open `Buddy.xcodeproj`, pick a device, run.

A simulator build needs no signing:

```bash
xcodebuild -project Buddy.xcodeproj -scheme Buddy -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

## Shipping a build

Two scripts do it, each a wizard: what Apple's API can do they do, and a step only a person
can take (or only the website offers) pauses with its link until Enter, or asks for what it
needs. Ctrl-C stops either one safely; run it again to carry on.

```bash
ios/buddy/bin/testflight   # a build to the internal testers
ios/buddy/bin/release      # a version to App Review and the App Store
```

The wizards themselves live in `ios/script/app_store` and serve every app under `ios/`; what is
Buddy's (bundle id, team, listing words, review notes, App Privacy answers) is in
`app_store.rb` here. Another app gets its own `app_store.rb` and `bin/` pair.

The first run asks for an App Store Connect API key, or offers the one another app on this Mac
already set up (a team key works for every app on the team). Keys stay in
`~/.appstoreconnect/private_keys`; Buddy's IDs, last build number and the one-time website steps
are remembered in `~/.appstoreconnect/buddy.json`.

**`bin/testflight`** offers to send on the newest build when it is recent; otherwise it
generates the project, archives, and uploads with the next build number after every one Apple
has (the number in `project.yml` is only for runs from Xcode). It waits for Apple's processing
(usually 5 to 30 minutes), asks what to test, makes the internal group `Buddy team` if there is
none (every build reaches it), and offers to add each App Store Connect user who isn't testing
yet. Someone new is invited onto the team (Developer, seeing only Buddy), and added on a later
run once they accept.

**`bin/release`** picks the version (raising `MARKETING_VERSION` in `project.yml` when it
changes, which then needs shipping), takes the build of that version already on TestFlight or
makes one, and fills in the store listing, privacy policy URL, category, content rights,
screenshots (from a folder, uploaded for you) and the App Review contact and demo sign-in,
asking only for what isn't there yet. It pauses once for the website-only steps: age rating,
App Privacy answers, pricing, and the unlisted distribution request. Then it submits; anything
Apple still wants comes back as a list, and it tries again after Enter. A version held for
manual release is released by running it again.

Each target's `PrivacyInfo.xcprivacy` says why it uses what Apple asks about (UserDefaults, for
its own settings and the App Group); App Store Connect refuses an upload without them, and a
new such API needs its reason there. `ITSAppUsesNonExemptEncryption` in the app's `Info.plist`
answers export compliance for every build.

By hand, if ever needed: raise `CURRENT_PROJECT_VERSION`, run `ios/buddy/bin/xcode`, then in
Xcode choose Any iOS Device, Product, Archive, and in the Organizer Distribute App, App Store
Connect, Upload.

## Server side

Everything is under `/api/ios` (see `app/controllers/api/ios`). Native push needs an APNs auth key
(.p8) from developer.apple.com → Keys, with its Key ID and the Team ID, in the server's env. Debug
builds register as `development` and the server sends them to the APNs sandbox.

## The offline queue

Commands, Buddy messages, triggers, task runs, list ticks, notification answers and every piece of
synced device data go through `Outbox`: written to the App Group the instant they happen, carrying
the time they happened, and removed only after the server answers 2xx for that one item. Network
failures hand the item to a background URLSession, which iOS retries until it gets through — even
with the app closed. The server dedupes on each item's UUID, so a retry is never processed twice.
