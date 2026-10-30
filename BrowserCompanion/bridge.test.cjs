const { test } = require('node:test');
const assert = require('node:assert/strict');
const { collect, sync } = require('./shared/bridge.js');
function fixture(firefox = false) {
  const saved = {};
  const api = {
    storage: { local: { get: async () => saved, set: async value => Object.assign(saved, value) } },
    runtime: { id: 'self', sendNativeMessage: async (host, message) => { api.sent = { host, message }; return { ok: true }; },
      ...(firefox ? { getBrowserInfo: async () => ({ version: '156.0' }) } : {}) },
    management: { getAll: async () => [
      { id: 'self', name: 'Companion', version: '1.0', type: 'extension' },
      { id: 'other', name: 'Other', version: '2.0', type: 'extension', enabled: false, updateUrl: 'https://example.org/update', permissions: ['history'], description: 'do not send' },
      { id: 'theme', name: 'Theme', version: '3.0', type: 'theme' } ] }
  };
  return { api, saved, environment: { uuid: () => 'test-uuid', userAgent: 'Chrome/156.0.1.2', brave: true } };
}
test('collects metadata only, including disabled extensions, excluding itself and themes', async () => {
  const { api, environment } = fixture();
  const result = await collect(api, environment);
  assert.equal(result.browser, 'brave'); assert.equal(result.browserVersion, '156.0.1.2');
  assert.deepEqual(result.extensions, [{ id: 'other', name: 'Other', version: '2.0', enabled: false, installType: 'normal', updateURL: 'https://example.org/update' }]);
  assert.equal((await collect(api, environment)).profileID, result.profileID);
  assert.equal(JSON.stringify(result).includes('permissions'), false);
});
test('Firefox uses its own browser version and retains independent profile labels', async () => {
  const { api, saved, environment } = fixture(true); saved.label = 'Personal'; saved.browser = 'chrome';
  const result = await collect(api, environment);
  assert.equal(result.browser, 'firefox'); assert.equal(result.browserVersion, '156.0'); assert.equal(result.label, 'Personal');
});
test('sync uses the fixed native host and surfaces denied or unavailable connections', async () => {
  const { api, environment } = fixture();
  assert.equal(await sync(api, environment), 1);
  assert.equal(api.sent.host, 'com.annoyingupdater.browser');
  api.runtime.sendNativeMessage = async () => ({ ok: false, error: 'Invalid inventory' });
  await assert.rejects(() => sync(api, environment), /Invalid inventory/);
  api.runtime.sendNativeMessage = async () => { throw new Error('Host missing'); };
  await assert.rejects(() => sync(api, environment), /Host missing/);
});
test('an unknown browser version does not report a guessed inventory', async () => {
  const { api, environment } = fixture(); environment.userAgent = 'Unknown Browser';
  await assert.rejects(() => collect(api, environment), /Browser version/);
});
test('uses the full Chromium engine version rather than a Brave product version', async () => {
  const { api, environment } = fixture();
  environment.userAgentData = { getHighEntropyValues: async () => ({ fullVersionList: [
    { brand: 'Brave', version: '1.95.102' }, { brand: 'Chromium', version: '153.0.7855.0' }
  ] }) };
  assert.equal((await collect(api, environment)).browserVersion, '153.0.7855.0');
  environment.userAgentData.getHighEntropyValues = async () => { throw new Error('Unavailable'); };
  assert.equal((await collect(api, environment)).browserVersion, '156.0.1.2');
});
