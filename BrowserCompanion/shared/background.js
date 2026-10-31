if (typeof importScripts === 'function') importScripts('bridge.js');
const api = typeof browser !== 'undefined' ? browser : chrome;
let pending = null;
function refresh() {
  if (pending) return pending;
  pending = upd8erBrowserBridge.sync(api, {
    userAgent: navigator.userAgent, userAgentData: navigator.userAgentData, brave: !!navigator.brave, uuid: () => crypto.randomUUID()
  }).then(() => api.action.setBadgeText({ text: '' })).catch(() => api.action.setBadgeText({ text: '!' })).finally(() => { pending = null; });
  return pending;
}
api.runtime.onInstalled.addListener(() => { api.alarms.create('inventory', { periodInMinutes: 1 }); refresh(); });
api.runtime.onStartup.addListener(() => { api.alarms.create('inventory', { periodInMinutes: 1 }); refresh(); });
api.alarms.onAlarm.addListener(alarm => { if (alarm.name === 'inventory') refresh(); });
for (const event of ['onInstalled', 'onUninstalled', 'onEnabled', 'onDisabled']) api.management[event].addListener(refresh);
api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type !== 'refresh') return false;
  refresh().then(() => sendResponse({ ok: true })); return true;
});
