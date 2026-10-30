/* Metadata only: no content scripts, tabs, cookies, history, or site permissions. */
(function (root) {
  const host = 'com.annoyingupdater.browser';
  async function collect(api, environment) {
    const stored = await api.storage.local.get(['profileID', 'label', 'browser']);
    const profileID = stored.profileID || environment.uuid();
    if (!stored.profileID) await api.storage.local.set({ profileID });
    const firefox = typeof api.runtime.getBrowserInfo === 'function';
    const info = firefox ? await api.runtime.getBrowserInfo() : null;
    let engineVersion;
    if (!firefox && environment.userAgentData) {
      try {
        const hints = await environment.userAgentData.getHighEntropyValues(['fullVersionList']);
        engineVersion = hints.fullVersionList.find(item => ['Chromium', 'Google Chrome'].includes(item.brand))?.version;
      } catch (_) { /* A reduced UA remains a conservative compatibility query. */ }
    }
    const version = info ? info.version : (engineVersion || (environment.userAgent.match(/Chrome\/([0-9.]+)/) || [])[1]);
    if (!version || !/^[0-9]+(?:\.[0-9]+){0,5}$/.test(version)) throw new Error('Browser version could not be read');
    const browser = firefox ? 'firefox' : (stored.browser || (environment.brave ? 'brave' : 'chrome'));
    const all = await api.management.getAll();
    const extensions = all.filter(item => item.type === 'extension' && item.id !== api.runtime.id).map(item => ({
      id: item.id, name: item.name, version: item.version, enabled: item.enabled,
      installType: item.installType || 'normal', ...(item.updateUrl ? { updateURL: item.updateUrl } : {})
    }));
    return { protocolVersion: 1, profileID, label: (stored.label || 'Default profile').slice(0, 80), browser, browserVersion: version, extensions };
  }
  async function sync(api, environment) {
    const snapshot = await collect(api, environment);
    const reply = await api.runtime.sendNativeMessage(host, snapshot);
    if (!reply || !reply.ok) throw new Error((reply && reply.error) || 'Native bridge did not accept the inventory');
    return snapshot.extensions.length;
  }
  const bridge = { collect, sync };
  root.AnnoyingBrowserBridge = bridge;
  if (typeof module !== 'undefined') module.exports = bridge;
})(globalThis);
