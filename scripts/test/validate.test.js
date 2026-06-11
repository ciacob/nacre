// scripts/test/validate.test.js
// Tests for lib/validate.js
//
// Run: node --test test/validate.test.js  (from scripts/)
//   or: npm test                          (from scripts/)

'use strict';

const { test } = require('node:test');
const assert   = require('node:assert/strict');
const { loadConfig, validateConfig, normaliseConfig } = require('../lib/validate');

// ── loadConfig ────────────────────────────────────────────────────────────────

test('loadConfig: returns parsed object for valid JSON', () => {
  const fakeFs = {
    readFileSync: () => '{"app":{"name":"Test"}}'
  };
  const result = loadConfig('/fake/path.json', fakeFs);
  assert.deepEqual(result, { app: { name: 'Test' } });
});

test('loadConfig: throws on unreadable file', () => {
  const fakeFs = {
    readFileSync: () => { throw new Error('ENOENT'); }
  };
  assert.throws(
    () => loadConfig('/fake/path.json', fakeFs),
    /cannot read config file/
  );
});

test('loadConfig: throws on invalid JSON', () => {
  const fakeFs = { readFileSync: () => 'not json {{{' };
  assert.throws(
    () => loadConfig('/fake/path.json', fakeFs),
    /not valid JSON/
  );
});

// ── validateConfig ────────────────────────────────────────────────────────────

function validConfig() {
  return {
    app: {
      name:     'My App',
      bundleId: 'com.example.myapp',
      version:  '1.0.0',
      icon:     './assets/MyApp.icns',
    },
    browser: {
      executablePath: '/path/to/Chromium.app',
    },
    output: {
      dir: './dist',
    },
  };
}

test('validateConfig: accepts a valid config', () => {
  assert.doesNotThrow(() => validateConfig(validConfig()));
});

test('validateConfig: throws when config is not an object', () => {
  assert.throws(() => validateConfig(null),       /must be a JSON object/);
  assert.throws(() => validateConfig('string'),   /must be a JSON object/);
  assert.throws(() => validateConfig(42),         /must be a JSON object/);
});

test('validateConfig: throws when a top-level section is missing', () => {
  const cfg = validConfig();
  delete cfg.browser;
  assert.throws(() => validateConfig(cfg), /missing required section "browser"/);
});

test('validateConfig: throws when a required field is missing', () => {
  const cfg = validConfig();
  delete cfg.app.name;
  assert.throws(() => validateConfig(cfg), /config\["app"\]\["name"\]/);
});

test('validateConfig: throws when a required field is empty string', () => {
  const cfg = validConfig();
  cfg.app.name = '   ';
  assert.throws(() => validateConfig(cfg), /config\["app"\]\["name"\]/);
});

test('validateConfig: throws on invalid bundleId — single segment', () => {
  const cfg = validConfig();
  cfg.app.bundleId = 'myapp';
  assert.throws(() => validateConfig(cfg), /reverse-DNS/);
});

test('validateConfig: throws on invalid bundleId — spaces', () => {
  const cfg = validConfig();
  cfg.app.bundleId = 'com.example.my app';
  assert.throws(() => validateConfig(cfg), /reverse-DNS/);
});

test('validateConfig: accepts bundleId with hyphens', () => {
  const cfg = validConfig();
  cfg.app.bundleId = 'com.my-company.my-app';
  assert.doesNotThrow(() => validateConfig(cfg));
});

test('validateConfig: throws on non-numeric version', () => {
  const cfg = validConfig();
  cfg.app.version = '1.0.0-beta';
  assert.throws(() => validateConfig(cfg), /dot-separated number/);
});

test('validateConfig: accepts single-digit version', () => {
  const cfg = validConfig();
  cfg.app.version = '2';
  assert.doesNotThrow(() => validateConfig(cfg));
});

test('validateConfig: accepts multi-part version', () => {
  const cfg = validConfig();
  cfg.app.version = '10.2.33';
  assert.doesNotThrow(() => validateConfig(cfg));
});

// ── normaliseConfig ───────────────────────────────────────────────────────────

test('normaliseConfig: resolves relative paths against config file dir', () => {
  // Use a config with genuinely relative paths so isAbsolute() returns false
  // and the resolve branch actually fires.
  const cfg = {
    app:     { name: 'X', bundleId: 'a.b', version: '1',
               icon: './assets/icon.icns' },
    browser: { executablePath: './browsers/Chromium.app' },
    output:  { dir: './dist' },
  };
  const fakePath = {
    dirname:    () => '/config/dir',
    // When called with (base, relative) resolve joins them
    resolve:    (...parts) => parts.length === 1
      ? parts[0]
      : '/config/dir/' + parts[parts.length - 1].replace(/^\.\//, ''),
    isAbsolute: (p) => p.startsWith('/'),
  };
  const result = normaliseConfig(cfg, '/config/dir/nacre.config.json', fakePath);
  assert.match(result.app.icon,               /^\/config\/dir/);
  assert.match(result.browser.executablePath,  /^\/config\/dir/);
  assert.match(result.output.dir,             /^\/config\/dir/);
});

test('normaliseConfig: leaves absolute paths unchanged', () => {
  const cfg = validConfig();
  cfg.app.icon              = '/absolute/icon.icns';
  cfg.browser.executablePath = '/absolute/Chromium.app';
  cfg.output.dir            = '/absolute/dist';

  const fakePath = {
    dirname:    () => '/config/dir',
    resolve:    (...parts) => parts[parts.length - 1], // identity for absolute
    isAbsolute: (p) => p.startsWith('/'),
  };
  const result = normaliseConfig(cfg, '/config/dir/nacre.config.json', fakePath);
  assert.equal(result.app.icon,               '/absolute/icon.icns');
  assert.equal(result.browser.executablePath,  '/absolute/Chromium.app');
  assert.equal(result.output.dir,             '/absolute/dist');
});

test('normaliseConfig: does not mutate the input config', () => {
  const cfg      = validConfig();
  const original = JSON.parse(JSON.stringify(cfg));
  const fakePath = {
    dirname:    () => '/config/dir',
    resolve:    (...parts) => '/resolved/' + parts[parts.length - 1],
    isAbsolute: () => false,
  };
  normaliseConfig(cfg, '/config/dir/nacre.config.json', fakePath);
  assert.deepEqual(cfg, original);
});
