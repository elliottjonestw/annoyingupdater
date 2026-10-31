const api = typeof browser !== 'undefined' ? browser : chrome;
async function load() {
  const stored = await api.storage.local.get(['label', 'browser']);
  document.getElementById('label').value = stored.label || '';
  const firefox = typeof api.runtime.getBrowserInfo === 'function';
  document.getElementById('browser').value = firefox ? 'firefox' : (stored.browser || (navigator.brave ? 'brave' : 'chrome'));
  document.getElementById('browser').disabled = firefox;
}
document.getElementById('sync').addEventListener('click', async () => {
  const status = document.getElementById('status'); status.textContent = 'Connecting…';
  try {
    await api.storage.local.set({ label: document.getElementById('label').value.trim() || 'Default profile', browser: document.getElementById('browser').value });
    const count = await upd8erBrowserBridge.sync(api, { userAgent: navigator.userAgent, userAgentData: navigator.userAgentData, brave: !!navigator.brave, uuid: () => crypto.randomUUID() });
    status.textContent = `Connected. ${count} extensions shared with upd8er.`;
  } catch (error) { status.textContent = `Couldn't connect. Prepare the bridge in upd8er Settings first. ${error.message}`; }
});
load();
