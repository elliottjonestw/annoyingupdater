# upd8er

### A little persistence. A more up-to-date Mac.

AI agents are finding vulnerabilities at lightning speed. Keeping software updated matters more than ever.

**upd8er bugs you every 15 minutes by default until the updates it finds on your Mac are installed.** A native macOS app with one job: making “I'll update it later” a little harder to forget.

[**Download for macOS →**](https://github.com/elliottjonestw/annoyingupdater/releases/latest)

macOS 14 or later · Apple silicon and Intel

![upd8er showing available updates](docs/images/updates.jpg)

## Update. Snooze. Repeat.

When an update is available, upd8er brings a reminder to the front. Update now, or snooze for your chosen duration (15 minutes by default). If updates remain, it'll be back.

<p align="center">
  <img src="docs/images/reminder.jpg" width="400" alt="The live update reminder with Update and Snooze buttons">
</p>

- **Finds updates automatically.** Checks macOS, App Store apps, developer feeds, Homebrew, public app catalogs, and more. No per-app setup.
- **Checks command-line tools too.** Monitors Homebrew formulae and global npm packages, including standard and nvm Node installations. Copy an update command to run in Terminal when you're ready.
- **Finds portable apps.** Discovers apps in Downloads, running apps, and connected drives, using Spotlight where available. Locations are shown so you can identify each copy.
- **Checks apps from Finder.** Select apps and choose **Services → Check with upd8er** to see their results.
- **Can watch browser extensions.** An optional companion connects Chromium and Firefox profiles and checks supported public store versions. [Preview setup and coverage](BrowserCompanion/README.md).
- **Keeps everything in one place.** See available updates first, apps that need a manual check next, and up-to-date software last.
- **Shows what an update changes.** When published notes are available, **What’s New** shows releases between your installed version and the selected update, newest first. Read just the target release, load older history, or open the original notes. Missing history and sources that provide only the latest notes are clearly labelled.
- **Shows how long updates have been waiting.** Uses the earliest newer dated publisher release it can find, labelled “Outdated for at least …”. When publication dates aren’t available, “Detected … ago” uses local tracking instead. Dates and sources are explained in the update’s details.
- **Highlights known vulnerabilities.** Matches supported desktop apps to NVD product and affected-version records, and verified public npm packages to OSV advisories. See CVE details, reported fixes and CISA known-exploitation flags. Uncertain identities and unsupported conditions are labelled clearly; an empty result isn’t a claim of safety.
- **Remembers what changed.** Local update history records installed version and build changes, including updates made outside upd8er. Pending updates show when they were first detected.
- **Helps you finish the job.** Installs supported Homebrew updates or takes you to the app, App Store, system updater, or developer's site.
- **Choose your snooze duration.** Select 5, 15 or 30 minutes, 1, 2, 4 or 8 hours, or 1 day. The reminder, menu bar and window-close action use that setting. Changing it leaves an active snooze deadline intact.
- **Choose whether to be reminded.** Turn update reminders on or off in Settings. Turning them off closes an open reminder while update checks continue.
- **Choose how often to check.** Scan every 15 or 30 minutes, 1, 2, 4 or 8 hours, or daily. The default is hourly, with extra checks at launch, after waking and when monitored software changes. Reminders use the latest completed scan; publisher catalogs and vulnerability data may refresh less often.
- **Starts with your Mac.** Open at login is on by default. Close the window and it keeps watch from the menu bar.
- **Keeps itself updated.** Downloads and verifies its own updates from GitHub, then installs them when you quit or choose Install and Relaunch.

Some apps don't expose a reliable way to check for updates. upd8er clearly marks those as **Couldn't check** or **Couldn't verify**.

## See what changed

History gives you a searchable timeline of installed version and build changes, including updates made by other apps or installed manually. Open an entry to see the before and after, when the change was detected, and when its update was first detected, if known.

Tracking starts with your first scan. History stays on your Mac, and you can clear it at any time.

## Known vulnerabilities

A vulnerability badge means an advisory matches the installed product and version. Open it for the advisory, severity when published, reported affected versions, and whether the offered update is outside those ranges. New updates can still be affected; an update is never labelled safe just because it is newer.

Checks run separately in the background and reuse advisory data for up to a day. Product matching is automatic and deliberately conservative. Similar names alone do not qualify. Unsupported editions, version formats, platform conditions, private npm origins, browser extensions, and Homebrew patch/revision applicability may be unassessable. This checks whole-app advisories and verified public npm packages; it does not audit bundled libraries or npm dependencies. A missing badge does not mean there are no vulnerabilities.

NVD receives supported product names and versions; OSV receives verified public npm package names and versions. Local paths and usernames are not included in requests. CISA's public catalog adds known-exploitation information. You can turn these lookups off in Settings. Updates and 15-minute reminders continue independently.

This product uses the [NVD API](https://nvd.nist.gov/) but is not endorsed or certified by the NVD. Package advisories come from [OSV](https://osv.dev/), and known-exploitation flags from [CISA KEV](https://github.com/cisagov/kev-data).

## Check from Finder

In Finder, select one or more apps and choose **Services → Check with upd8er**. Install upd8er in Applications first. If the service is hidden, enable it in System Settings → Keyboard → Keyboard Shortcuts → Services. Selected apps are checked with the same automatic sources and remain monitored when accessible.

## Install

1. Download the latest `.dmg` from [Releases](https://github.com/elliottjonestw/annoyingupdater/releases/latest).
2. Open it and drag **upd8er** to **Applications**.
3. Eject the disk image and open the app.

The app isn't Developer ID signed or notarized yet. If macOS blocks it, follow [Apple's instructions to open an app from an unidentified developer](https://support.apple.com/en-us/102445).

## Private by design

No account. No upd8er server. App matching happens on your Mac; your installed-app inventory isn't uploaded to the public app catalogs. Update checks contact Apple, the catalogs, and the relevant developers or GitHub. Vulnerability lookups additionally contact NVD, OSV and CISA’s official data mirror on GitHub as described above. If you connect the optional browser companion, extension checks send identifiers and, when needed, installed/browser versions to Google or Mozilla; browsing history, tabs, cookies, and passwords are never accessed.

## Build it yourself

With a Swift 6 toolchain and macOS SDK:

```sh
scripts/build.sh
open "build/upd8er.app"
```

The app was previously called Annoying Updater. Its bundle identifier, local data directories, browser connection identifiers and GitHub update feed remain unchanged so existing settings, history and update signatures continue to work. Existing browser host connections are refreshed to the current installed app path at launch. If an unpacked browser companion was loaded from the old app's folder, load it again from **Settings → Set Up Browser Companion → Show Companion Folder** after moving to `upd8er.app`.

Run `scripts/test.sh` for Swift tests and `node --test BrowserCompanion/bridge.test.cjs` for companion tests. To create a universal disk image, run `scripts/build.sh release universal`, then `scripts/package.sh`. The [release workflow](.github/workflows/release.yml) builds and publishes the version in `VERSION` when its matching tag (such as `v1.4`) is pushed.

All rights reserved. See [LICENSE](LICENSE). Third-party licenses are included in the app and in [ThirdPartyNotices.txt](Resources/ThirdPartyNotices.txt).
