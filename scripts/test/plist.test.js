// scripts/test/plist.test.js
// Tests for lib/plist.js
//
// Run: node --test test/plist.test.js  (from scripts/)

'use strict';

const { test } = require('node:test');
const assert   = require('node:assert/strict');
const {
  escapeXml,
  applyTokens,
  findUnreplacedTokens,
  buildTokenMap,
} = require('../lib/plist');

// ── escapeXml ─────────────────────────────────────────────────────────────────

test('escapeXml: leaves plain ASCII unchanged', () => {
  assert.equal(escapeXml('hello world'), 'hello world');
});

test('escapeXml: escapes ampersand', () => {
  assert.equal(escapeXml('Cats & Dogs'), 'Cats &amp; Dogs');
});

test('escapeXml: escapes less-than and greater-than', () => {
  assert.equal(escapeXml('<tag>'), '&lt;tag&gt;');
});

test('escapeXml: escapes double quote', () => {
  assert.equal(escapeXml('"quoted"'), '&quot;quoted&quot;');
});

test('escapeXml: escapes single quote', () => {
  assert.equal(escapeXml("it's"), 'it&apos;s');
});

test('escapeXml: escapes multiple special chars in one string', () => {
  assert.equal(escapeXml('<a href="x&y">it\'s</a>'),
    '&lt;a href=&quot;x&amp;y&quot;&gt;it&apos;s&lt;/a&gt;');
});

test('escapeXml: coerces non-string input via String()', () => {
  assert.equal(escapeXml(42),   '42');
  assert.equal(escapeXml(null), 'null');
});

// ── applyTokens ───────────────────────────────────────────────────────────────

test('applyTokens: replaces a single token', () => {
  const result = applyTokens('Hello {{NAME}}!', { NAME: 'World' });
  assert.equal(result, 'Hello World!');
});

test('applyTokens: replaces multiple different tokens', () => {
  const result = applyTokens(
    '<string>{{APP_NAME}}</string><string>{{BUNDLE_ID}}</string>',
    { APP_NAME: 'My App', BUNDLE_ID: 'com.example.app' }
  );
  assert.equal(result,
    '<string>My App</string><string>com.example.app</string>');
});

test('applyTokens: replaces the same token appearing multiple times', () => {
  const result = applyTokens(
    '{{APP_NAME}} — {{APP_NAME}}',
    { APP_NAME: 'Nacre' }
  );
  assert.equal(result, 'Nacre — Nacre');
});

test('applyTokens: XML-escapes replacement values', () => {
  const result = applyTokens('<string>{{NAME}}</string>', { NAME: 'A & B' });
  assert.equal(result, '<string>A &amp; B</string>');
});

test('applyTokens: leaves unknown tokens in template unchanged', () => {
  const result = applyTokens('{{UNKNOWN}}', { OTHER: 'x' });
  assert.equal(result, '{{UNKNOWN}}');
});

test('applyTokens: ignores tokens in map not present in template', () => {
  const result = applyTokens('Hello', { GHOST: 'value' });
  assert.equal(result, 'Hello');
});

test('applyTokens: handles empty template', () => {
  assert.equal(applyTokens('', { APP_NAME: 'x' }), '');
});

test('applyTokens: handles empty tokens map', () => {
  assert.equal(applyTokens('{{APP_NAME}}', {}), '{{APP_NAME}}');
});

// ── findUnreplacedTokens ──────────────────────────────────────────────────────

test('findUnreplacedTokens: returns empty array when no tokens remain', () => {
  assert.deepEqual(findUnreplacedTokens('<string>My App</string>'), []);
});

test('findUnreplacedTokens: finds a single unreplaced token', () => {
  assert.deepEqual(findUnreplacedTokens('{{APP_NAME}}'), ['APP_NAME']);
});

test('findUnreplacedTokens: finds multiple different tokens', () => {
  const tokens = findUnreplacedTokens('{{APP_NAME}} {{BUNDLE_ID}} {{VERSION}}');
  assert.deepEqual(tokens.sort(), ['APP_NAME', 'BUNDLE_ID', 'VERSION']);
});

test('findUnreplacedTokens: de-duplicates repeated tokens', () => {
  const tokens = findUnreplacedTokens('{{APP_NAME}} and {{APP_NAME}}');
  assert.deepEqual(tokens, ['APP_NAME']);
});

// ── buildTokenMap ─────────────────────────────────────────────────────────────

test('buildTokenMap: produces correct map from config', () => {
  const config = {
    app: {
      name:     'My App',
      bundleId: 'com.example.myapp',
      version:  '1.2.3',
      icon:     '/path/to/icon.icns',
    },
    browser: { executablePath: '/path/to/Chromium.app' },
    output:  { dir: '/path/to/dist' },
  };
  const map = buildTokenMap(config);
  assert.deepEqual(map, {
    APP_NAME:  'My App',
    BUNDLE_ID: 'com.example.myapp',
    VERSION:   '1.2.3',
  });
});

test('buildTokenMap: only includes known tokens, not full config', () => {
  const config = {
    app: { name: 'X', bundleId: 'a.b', version: '1', icon: '/i' },
    browser: { executablePath: '/c' },
    output:  { dir: '/d' },
  };
  const map = buildTokenMap(config);
  assert.equal(Object.keys(map).length, 3);
  assert.ok(!('icon' in map));
  assert.ok(!('dir'  in map));
});

// ── Integration: applyTokens with a plist-shaped template ────────────────────

test('integration: full plist template round-trip', () => {
  const template = `<?xml version="1.0"?>
<plist>
<dict>
  <key>CFBundleName</key>
  <string>{{APP_NAME}}</string>
  <key>CFBundleDisplayName</key>
  <string>{{APP_NAME}}</string>
  <key>CFBundleIdentifier</key>
  <string>{{BUNDLE_ID}}</string>
  <key>CFBundleVersion</key>
  <string>{{VERSION}}</string>
</dict>
</plist>`;

  const tokens = { APP_NAME: 'Pearl', BUNDLE_ID: 'com.test.pearl', VERSION: '2.0.1' };
  const result = applyTokens(template, tokens);

  assert.ok(result.includes('<string>Pearl</string>'));
  assert.ok(result.includes('<string>com.test.pearl</string>'));
  assert.ok(result.includes('<string>2.0.1</string>'));
  assert.equal(findUnreplacedTokens(result).length, 0);
});
