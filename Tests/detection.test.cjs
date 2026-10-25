const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const listeners = {};
const event = name => ({ addListener: fn => listeners[name] = fn });
const chrome = {
  webRequest: { onBeforeRequest: event('request'), onHeadersReceived: event('headers') },
  runtime: { onInstalled: event('installed'), onMessage: event('message') },
  tabs: { onUpdated: event('updated'), onRemoved: event('removed') },
  downloads: { onCreated: event('download') },
  contextMenus: { onClicked: event('context') },
  action: { setBadgeText() {}, setBadgeBackgroundColor() {} },
  scripting: { executeScript: async () => [
    { result: { videos: [{ src: 'https://cdn.test/v.mp4', height: 360 }], blobVideos: 1 } },
    { result: { videos: [{ src: 'https://cdn.test/v.mp4', height: 1080 }, { src: 'https://cdn.test/embed.mp4', height: 720 }], blobVideos: 0 } }
  ] }
};
const context = vm.createContext({ chrome, console, URL, navigator: { userAgent: 'test' }, setTimeout, fetch });
vm.runInContext(fs.readFileSync('chrome-extension/background.js', 'utf8'), context);
(async () => {
  const found = await vm.runInContext('scanTab(1)', context);
  assert.equal(found.videos.length, 2);
  assert.equal(found.videos[0].height, 1080);
  listeners.headers({ tabId: 1, url: 'https://cdn.test/signed?id=42', statusCode: 200, responseHeaders: [{ name: 'Content-Type', value: 'application/dash+xml; charset=utf-8' }] });
  assert.equal(vm.runInContext('streamEntries(1)[0].kind', context), 'DASH');
  listeners.headers({ tabId: 1, url: 'https://cdn.test/hls', statusCode: 200, responseHeaders: [{ name: 'Content-Type', value: 'application/vnd.apple.mpegurl' }] });
  assert.equal(vm.runInContext('streamEntries(1).length', context), 2);
  listeners.updated(1, { status: 'loading' }, {});
  assert.equal(vm.runInContext('streamEntries(1).length', context), 0);
  console.log('PASS: iframe aggregation, deduplication, MIME detection, navigation cleanup');
})().catch(error => { console.error(error); process.exitCode = 1; });
