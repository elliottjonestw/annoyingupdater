# Browser companion (preview)

Connect a browser profile once. Annoying Updater can then discover its installed extensions automatically, check public store metadata, and record version changes in local history. No individual extension sources are configured.

The companion is not published in browser stores yet. Chromium browsers can load the unpacked companion; Firefox can load it temporarily for testing. A permanent Firefox package requires Mozilla signing. Safari extensions continue to be checked through their containing Mac apps.

## Connect a profile

1. Install Annoying Updater in Applications. Open **Settings → Set Up Browser Companion**.
2. Choose the browser and click **Prepare Connection**. This registers a local native messaging host for that browser and enables monitoring in the app.
3. Click **Show Companion Folder**.
4. For Chrome, Brave, or Chromium: open the browser's Extensions page, enable Developer mode, click **Load unpacked**, and select the `chromium` folder.
5. For Firefox testing: open `about:debugging`, choose **This Firefox → Load Temporary Add-on**, and select `manifest.json` in the `firefox` folder. Firefox removes temporary add-ons when it closes.
6. Open the companion's toolbar popup. Select the correct browser, give the profile a recognizable name, and click **Save and check connection**.

Repeat in each profile to monitor. The companion refreshes every minute and when extensions change. Annoying Updater detects changes without treating every heartbeat as a new network scan. Inventories older than three minutes become unverified; reopen the profile to refresh them.

Browsers manage installation. **Open Browser Extensions** opens the correct browser, but its selected profile may differ; choose the profile named in the result. The companion cannot force updates to other extensions. Enterprise policy, staged rollouts, browser compatibility, unlisted add-ons, and custom update sources can limit coverage. Unsupported or uncertain results do not trigger update reminders.

## Privacy and permissions

The companion requests `management`, `nativeMessaging`, `storage`, and `alarms`. Browsers describe `management` broadly as permission to manage apps, extensions, and themes; this companion uses it only to read the inventory and observe changes, and never calls install, uninstall, enable, or disable methods. It has no content scripts, host permissions, tabs, cookies, history, or password access. It shares extension identifiers, names, versions, enabled state, update service, install type, browser version, and a locally generated profile identifier/name with Annoying Updater on this Mac.

The Mac app queries Google or Mozilla using extension identifiers. Chromium update queries also include the installed extension and browser versions for compatibility. Names and profile labels are not sent to those services. No inventory is sent to an Annoying Updater server. Local snapshots use files accessible only to your macOS account.

Disabling **Monitor browser extensions** stops the app's extension checks. Remove the companion from a browser profile to stop its local inventory sharing. To remove the local connection, delete `com.annoyingupdater.browser.json` from that browser's user `NativeMessagingHosts` folder. Local snapshots are in `~/Library/Application Support/Annoying Updater/Browser Profiles`.

## Development and verification

`python3 scripts/package-companion.py build/BrowserCompanion` assembles both companion folders. The normal app build includes them and a universal native messaging helper. The Chromium manifest's public key keeps the unpacked extension ID stable; its origin must match the helper's allowlist. No private signing key is included or required for the unpacked build.

- `scripts/test.sh` checks store identity, compatibility, stale profiles, history, data validation, and native message framing.
- `node --test BrowserCompanion/bridge.test.cjs` checks inventory collection and the native connection with browser API fixtures.
- `python3 -m unittest discover -s scripts/tests -v` checks companion packaging and permissions alongside release tooling.

Implementation references: [Chrome native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging), [Chrome extension management](https://developer.chrome.com/docs/extensions/reference/api/management), [Mozilla extension management](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/management/getAll), and [Mozilla Add-ons API](https://mozilla.github.io/addons-server/topics/api/addons.html).
