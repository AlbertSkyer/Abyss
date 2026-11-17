import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join, isAbsolute } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import vm from 'node:vm';
import { extensionId } from '../../tool/build_abyss_extension.mjs';

const root = fileURLToPath(new URL('../../', import.meta.url));
const source = join(root, 'browser_extension');
const builder = join(root, 'tool', 'build_abyss_extension.mjs');
const config = JSON.parse(readFileSync(join(source, 'abyss.json'), 'utf8'));
const originalManifest = JSON.parse(readFileSync(join(source, 'manifest.json'), 'utf8'));
const originalId = 'jfjagocghaaheooicmdnhcholmgdkngk';
const help = 'https://github.com/AlbertSkyer/Abyss/blob/edition/abyss/docs/abyss-browser-extension.md';

function run(command, args) {
  const result = spawnSync(command, args, {
    cwd: root,
    encoding: 'utf8',
    windowsHide: true,
    timeout: 60_000,
  });
  assert.equal(result.status, 0, `${command} ${args.join(' ')}\n${result.stdout}\n${result.stderr}`);
  return result.stdout;
}

function runPowerShell(script, args) {
  const result = spawnSync('powershell.exe', [
    '-NoLogo', '-NoProfile', '-NonInteractive',
    '-EncodedCommand', Buffer.from(script, 'utf16le').toString('base64'),
  ], {
    cwd: root,
    encoding: 'utf8',
    windowsHide: true,
    timeout: 60_000,
    env: { ...process.env, ABYSS_EXTENSION_TEST_PATH: args[0] },
  });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout;
}

function zipEntries(path) {
  const script = [
    'Add-Type -AssemblyName System.IO.Compression.FileSystem',
    '$archive = [System.IO.Compression.ZipFile]::OpenRead($env:ABYSS_EXTENSION_TEST_PATH)',
    'try { @($archive.Entries | ForEach-Object { $_.FullName }) | ConvertTo-Json -Compress }',
    'finally { $archive.Dispose() }',
  ].join('\n');
  const text = runPowerShell(script, [path]).trim();
  return text ? JSON.parse(text) : [];
}

function zipManifest(path) {
  const script = [
    'Add-Type -AssemblyName System.IO.Compression.FileSystem',
    '$archive = [System.IO.Compression.ZipFile]::OpenRead($env:ABYSS_EXTENSION_TEST_PATH)',
    'try {',
    '  $entry = $archive.GetEntry("manifest.json")',
    '  if ($null -eq $entry) { throw "manifest.json missing" }',
    '  $reader = [System.IO.StreamReader]::new($entry.Open())',
    '  try { $reader.ReadToEnd() } finally { $reader.Dispose() }',
    '} finally { $archive.Dispose() }',
  ].join('\n');
  return JSON.parse(runPowerShell(script, [path]));
}

function filesBelow(directory, prefix = '') {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const relative = prefix ? `${prefix}/${entry.name}` : entry.name;
    return entry.isDirectory()
      ? filesBelow(join(directory, entry.name), relative)
      : [relative];
  }).sort();
}

function pngSize(path) {
  const bytes = readFileSync(path);
  assert.equal(bytes.toString('ascii', 1, 4), 'PNG');
  assert.equal(bytes.toString('ascii', 12, 16), 'IHDR');
  return [bytes.readUInt32BE(16), bytes.readUInt32BE(20)];
}

class ChromeEvent {
  listeners = [];
  addListener(listener) {
    this.listeners.push(listener);
  }
}

// Only the APIs the worker uses at startup or in the calls exercised below.
// A small fake keeps this a node:test, without a browser or a new framework.
function mockChrome(groupName) {
  const calls = { hosts: [], updates: [], groups: [], debugger: [], titles: [], creates: [] };
  const events = Object.fromEntries([
    'onCreated', 'onUpdated', 'onActivated', 'onMoved', 'onRemoved', 'onReplaced',
    'onAttached', 'onDetached', 'onZoomChange',
  ].map((name) => [name, new ChromeEvent()]));
  const groups = [
    { id: 11, title: 'Personal', color: 'blue', collapsed: false, windowId: 21 },
    { id: 12, title: groupName, color: 'yellow', collapsed: false, windowId: 21 },
    { id: 13, title: groupName === 'Abyss' ? 'BaoCode' : 'Abyss', color: 'red', collapsed: false, windowId: 21 },
  ];
  const tabs = [
    { id: 1, groupId: 11, windowId: 21, title: 'Private', url: 'https://private.invalid', active: true, status: 'complete', index: 0, pinned: false },
    { id: 2, groupId: 12, windowId: 21, title: 'Shared', url: 'https://shared.invalid', active: false, status: 'complete', index: 1, pinned: false },
    { id: 3, groupId: 13, windowId: 21, title: 'Other product', url: 'https://other.invalid', active: false, status: 'complete', index: 2, pinned: false },
  ];
  const port = {
    onMessage: new ChromeEvent(),
    onDisconnect: new ChromeEvent(),
    messages: [],
    postMessage(message) { this.messages.push(message); },
  };
  const chrome = {
    runtime: {
      connectNative(host) { calls.hosts.push(host); return port; },
      getManifest() { return { version: '0.1.0' }; },
      onStartup: new ChromeEvent(),
      onInstalled: new ChromeEvent(),
    },
    extension: { isAllowedFileSchemeAccess: async () => true },
    action: {
      onClicked: new ChromeEvent(),
      setBadgeText() {},
      setBadgeBackgroundColor() {},
      setTitle({ title }) { calls.titles.push(title); },
    },
    alarms: { create() {}, onAlarm: new ChromeEvent() },
    tabs: {
      ...events,
      async get(id) {
        const tab = tabs.find((item) => item.id === id);
        if (!tab) throw new Error(`No tab ${id}`);
        return { ...tab };
      },
      async query(query) {
        return tabs.filter((tab) =>
          (query.groupId === undefined || tab.groupId === query.groupId) &&
          (query.windowId === undefined || tab.windowId === query.windowId));
      },
      async update(...args) { calls.updates.push(args); return { ...tabs[0] }; },
      async group(...args) { calls.groups.push(args); return args[0].groupId ?? 12; },
      async ungroup() {},
      async remove() {},
      async create(options) { calls.creates.push(options); return { ...tabs[1] }; },
    },
    windows: {
      onCreated: new ChromeEvent(), onRemoved: new ChromeEvent(),
      onFocusChanged: new ChromeEvent(), onBoundsChanged: new ChromeEvent(),
      async update() {},
      async get() { return { id: 21, tabs: [...tabs] }; },
      async getLastFocused() { return { id: 21 }; },
      async create() { return { id: 21, tabs: [tabs[1]] }; },
    },
    tabGroups: {
      onUpdated: new ChromeEvent(),
      async get(id) {
        const group = groups.find((item) => item.id === id);
        if (!group) throw new Error(`No group ${id}`);
        return { ...group };
      },
      async query({ title }) { return groups.filter((group) => group.title === title); },
      async update(id) { calls.updates.push(['tabGroups', id]); },
    },
    debugger: {
      onEvent: new ChromeEvent(), onDetach: new ChromeEvent(),
      async attach(...args) { calls.debugger.push(['attach', ...args]); },
      async detach(...args) { calls.debugger.push(['detach', ...args]); },
      async sendCommand(...args) { calls.debugger.push(['sendCommand', ...args]); return {}; },
    },
  };
  return { chrome, calls, port };
}

function loadBackground(groupName, abyss) {
  const mock = mockChrome(groupName);
  const context = {
    chrome: mock.chrome,
    navigator: { userAgentData: { brands: [{ brand: 'Chromium' }] } },
    setTimeout,
    clearTimeout,
    console,
  };
  if (abyss) {
    context.ABYSS_BROWSER_IDENTITY = Object.freeze({
      name: 'Abyss', host: 'dev.abyss.browser', group: 'Abyss', help,
    });
  }
  vm.createContext(context);
  vm.runInContext(readFileSync(join(source, 'background.js'), 'utf8'), context, {
    filename: 'background.js',
  });
  return {
    ...mock,
    async request(id, method, params = {}) {
      await mock.port.onMessage.listeners[0]({ id, method, params });
      return mock.port.messages.findLast((message) => message.id === id);
    },
    async ready() {
      await mock.port.onMessage.listeners[0]({ type: 'bridge', connected: true });
    },
  };
}

test('public keys derive the fixed Abyss and original BaoCode ids', () => {
  const expected = [...createHash('sha256')
    .update(Buffer.from(config.publicKey, 'base64')).digest().subarray(0, 16)]
    .map((byte) => `${(byte >> 4).toString(16)}${(byte & 15).toString(16)}`)
    .join('').replace(/[0-9a-f]/g, (digit) => String.fromCharCode(97 + Number.parseInt(digit, 16)));
  assert.equal(expected, 'kecjiojfloffimkeghgongilhienkdlh');
  assert.equal(extensionId(config.publicKey), expected);
  assert.equal(extensionId(originalManifest.key), originalId);
  assert.notEqual(config.publicKey, originalManifest.key);
  assert.throws(() => extensionId('not a key'), /canonical base64/);
});

test('new-directory build has the Abyss identity, references and a loadable zip', (t) => {
  const temporary = mkdtempSync(join(tmpdir(), 'abyss-extension-test-'));
  t.after(() => rmSync(temporary, { recursive: true, force: true }));
  const out = join(temporary, 'new-build');
  const unpacked = join(out, 'unpacked');
  const zip = join(out, 'Abyss-browser-0.1.0.zip');
  run(process.execPath, [builder, '--out', out]);
  assert.ok(existsSync(zip));
  assert.ok(statSync(zip).size > 0);
  const manifest = JSON.parse(readFileSync(join(unpacked, 'manifest.json'), 'utf8'));
  assert.equal(manifest.name, '__MSG_name__');
  assert.equal(manifest.version, '0.1.0');
  assert.equal(manifest.key, config.publicKey);
  assert.equal(extensionId(manifest.key), config.extensionId);
  assert.equal(manifest.background.service_worker, 'identity.js');
  assert.equal(manifest.action.default_title, 'Abyss');
  assert.deepEqual(manifest.permissions, originalManifest.permissions);
  assert.deepEqual(manifest.host_permissions, originalManifest.host_permissions);
  assert.deepEqual(manifest.permissions, [
    'nativeMessaging', 'debugger', 'activeTab', 'tabs', 'tabGroups', 'alarms',
  ]);
  for (const reference of [
    manifest.background.service_worker,
    ...Object.values(manifest.icons),
    ...Object.values(manifest.action.default_icon),
  ]) {
    assert.ok(existsSync(join(unpacked, reference)), `missing ${reference}`);
    assert.ok(!isAbsolute(reference) && !reference.startsWith('..'), reference);
  }
  for (const size of [16, 32, 48, 128]) {
    assert.deepEqual(pngSize(join(unpacked, 'icons', `icon-${size}.png`)), [size, size]);
  }
  const icon128 = readFileSync(join(unpacked, 'icons', 'icon-128.png'));
  const appIcon = readFileSync(join(root, 'assets', 'branding', 'app_icon.png'));
  assert.ok(!icon128.equals(appIcon), '128px icon must use the extension framing');
  for (const locale of ['en', 'zh_CN']) {
    const messages = JSON.parse(readFileSync(join(unpacked, '_locales', locale, 'messages.json'), 'utf8'));
    assert.equal(messages.name.message, 'Abyss');
    assert.ok(messages.description.message.includes('Abyss'));
    assert.ok(!messages.description.message.includes('BaoCode'));
  }
  const identity = readFileSync(join(unpacked, 'identity.js'), 'utf8');
  assert.ok(identity.includes(help));
  assert.ok(identity.includes('dev.abyss.browser'));
  assert.ok(identity.includes("importScripts('background.js')"));
  const expectedFiles = [
    'LICENSE', 'NOTICE.txt',
    '_locales/en/messages.json', '_locales/zh_CN/messages.json',
    'background.js', 'identity.js', 'manifest.json',
    ...[16, 32, 48, 128].map((size) => `icons/icon-${size}.png`),
  ].sort();
  assert.deepEqual(filesBelow(unpacked), expectedFiles);
  assert.deepEqual(zipEntries(zip).sort(), expectedFiles);
  assert.deepEqual(zipManifest(zip), manifest);
  assert.ok(!filesBelow(unpacked).some((path) => /(?:^|\/)(?:key\.pem|.*\.pem|.*\.key)$/i.test(path)));
  for (const path of expectedFiles.filter((path) => /\.(?:js|json)$/.test(path))) {
    const contents = readFileSync(join(unpacked, path), 'utf8');
    assert.ok(!contents.includes(originalId), `${path} contains BaoCode's extension id`);
    assert.ok(!/PRIVATE KEY/.test(contents), `${path} contains private-key material`);
  }
  // Refusal, not overwrite or deletion, on every subsequent build attempt.
  const second = spawnSync(process.execPath, [builder, '--out', out], { cwd: root, encoding: 'utf8' });
  assert.notEqual(second.status, 0);
  assert.match(second.stderr, /Refusing to use an existing output path/);
  assert.deepEqual(filesBelow(unpacked), expectedFiles);
  assert.ok(existsSync(zip));
  // The ordinary package's source manifest is not staged or rewritten.
  assert.equal(originalManifest.background.service_worker, 'background.js');
  assert.equal(originalManifest.action.default_title, 'BaoCode');
  assert.equal(originalManifest.version, '0.2.0');
  assert.ok(!existsSync(join(source, 'icons', 'identity.js')));
});

for (const [name, abyss] of [['Abyss', true], ['BaoCode', false]]) {
  test(`${name} background keeps its host and shared-tab boundary`, async () => {
    const browser = loadBackground(name, abyss);
    assert.deepEqual(browser.calls.hosts, [abyss ? 'dev.abyss.browser' : 'dev.baocode.browser']);
    await browser.ready();
    assert.deepEqual(browser.calls.titles.at(-1), `${name}: connected`);
    const list = await browser.request('list', 'tabs.list');
    assert.deepEqual([...list.result].map((tab) => tab.tabId), [2]);
    assert.equal(list.error, undefined);

    for (const [id, method, params] of [
      ['private-update', 'call', { api: 'tabs.update', args: [1, { url: 'https://attacker.invalid' }] }],
      ['other-product', 'tabs.close', { tabId: 3 }],
      ['outside-group', 'call', { api: 'tabGroups.update', args: [11, { title: name }] }],
      ['other-group', 'call', { api: 'tabGroups.update', args: [13, { title: name }] }],
      ['private-cdp', 'cdp', { tabId: 1, method: 'Runtime.evaluate', params: { expression: '1' } }],
      ['other-cdp', 'cdp', { tabId: 3, method: 'Runtime.evaluate', params: { expression: '1' } }],
      ['private-move', 'call', { api: 'tabs.move', args: [1, { index: 0 }] }],
    ]) {
      const response = await browser.request(id, method, params);
      assert.ok(response.error, `${id}: ${JSON.stringify(response)}`);
      assert.match(response.error, new RegExp(name));
      assert.equal(response.result, undefined);
    }
    assert.deepEqual(browser.calls.updates, []);
    assert.deepEqual(browser.calls.groups, []);
    assert.deepEqual(browser.calls.debugger, []);
    assert.deepEqual(browser.calls.creates, []);

    await browser.port.onMessage.listeners[0]({ type: 'bridge', connected: false });
    await browser.chrome.action.onClicked.listeners[0]({ id: 1, groupId: 11, index: 0 });
    assert.equal(JSON.stringify(browser.calls.creates), JSON.stringify([{ url: abyss ? help : 'https://baocode.dev/download#browser', index: 1 }]));
  });
}
