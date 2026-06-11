// scripts/test/assemble.test.js
// Tests for lib/assemble.js
//
// All filesystem and process operations are injected via mock `ops` objects.
// No real disk access occurs.
//
// Run: node --test test/assemble.test.js  (from scripts/)

'use strict';

const { test } = require('node:test');
const assert   = require('node:assert/strict');
const nodePath  = require('node:path');
const {
  buildPaths,
  ensureShimBinary,
  validateSources,
  assembleBundle,
} = require('../lib/assemble');
const plistLib = require('../lib/plist');

// ── Fixtures ──────────────────────────────────────────────────────────────────

function validConfig() {
  return {
    app: {
      name:     'My App',
      bundleId: 'com.example.myapp',
      version:  '1.0.0',
      icon:     '/abs/assets/MyApp.icns',
    },
    browser: { executablePath: '/abs/browsers/Chromium.app' },
    output:  { dir: '/abs/dist' },
  };
}

const REPO_ROOT = '/repo/nacre';

// ── buildPaths ────────────────────────────────────────────────────────────────

test('buildPaths: shimBinarySrc is inside shim/.build/release', () => {
  const paths = buildPaths(validConfig(), REPO_ROOT);
  assert.ok(paths.shimBinarySrc.includes('shim'));
  assert.ok(paths.shimBinarySrc.includes('.build'));
  assert.ok(paths.shimBinarySrc.endsWith('nacre'));
});

test('buildPaths: appBundle is <AppName>.app inside output.dir', () => {
  const paths = buildPaths(validConfig(), REPO_ROOT);
  assert.equal(paths.appBundle, nodePath.join('/abs/dist', 'My App.app'));
});

test('buildPaths: shimBinaryDest is MacOS/nacre inside bundle', () => {
  const paths = buildPaths(validConfig(), REPO_ROOT);
  assert.ok(paths.shimBinaryDest.includes('MacOS'));
  assert.ok(paths.shimBinaryDest.endsWith('nacre'));
});

test('buildPaths: chromiumDest preserves original browser bundle name', () => {
  const paths = buildPaths(validConfig(), REPO_ROOT);
  // config has executablePath ending in "Chromium.app" — that name is preserved
  assert.ok(paths.chromiumDest.includes('Frameworks'));
  assert.ok(paths.chromiumDest.endsWith('Chromium.app'));
});

test('buildPaths: chromiumDest preserves bundle name with spaces', () => {
  const cfg = validConfig();
  cfg.browser.executablePath = '/path/to/Google Chrome for Testing.app';
  const paths = buildPaths(cfg, REPO_ROOT);
  assert.ok(paths.chromiumDest.endsWith('Google Chrome for Testing.app'));
});

test('buildPaths: iconDest is Resources/AppIcon.icns', () => {
  const paths = buildPaths(validConfig(), REPO_ROOT);
  assert.ok(paths.iconDest.includes('Resources'));
  assert.ok(paths.iconDest.endsWith('AppIcon.icns'));
});

test('buildPaths: plistDest is Contents/Info.plist', () => {
  const paths = buildPaths(validConfig(), REPO_ROOT);
  assert.ok(paths.plistDest.includes('Contents'));
  assert.ok(paths.plistDest.endsWith('Info.plist'));
});

// ── ensureShimBinary ──────────────────────────────────────────────────────────

test('ensureShimBinary: skips compile when binary exists', () => {
  let compileCalled = false;
  const ops = {
    exists: () => true,
    run: () => { compileCalled = true; },
  };
  ensureShimBinary('/fake/nacre', '/fake/shim', ops);
  assert.equal(compileCalled, false);
});

test('ensureShimBinary: compiles when binary is missing', () => {
  let ranCmd, ranArgs, ranCwd;
  // exists() returns false first (pre-build), then true (post-build)
  let callCount = 0;
  const ops = {
    exists: () => { return ++callCount > 1; },
    run: (cmd, args, opts) => { ranCmd = cmd; ranArgs = args; ranCwd = opts.cwd; },
  };
  ensureShimBinary('/fake/nacre', '/fake/shim', ops);
  assert.equal(ranCmd, 'swift');
  assert.deepEqual(ranArgs, ['build', '-c', 'release']);
  assert.equal(ranCwd, '/fake/shim');
});

test('ensureShimBinary: throws if binary still missing after compile', () => {
  const ops = {
    exists: () => false,
    run: () => {},   // compile appears to succeed but binary never appears
  };
  assert.throws(
    () => ensureShimBinary('/fake/nacre', '/fake/shim', ops),
    /binary not found/
  );
});

// ── validateSources ───────────────────────────────────────────────────────────

function allExistOps() {
  return { exists: () => true };
}

function missingOps(missingPath) {
  return { exists: (p) => p !== missingPath };
}

test('validateSources: passes when all sources exist', () => {
  const paths = buildPaths(validConfig(), REPO_ROOT);
  assert.doesNotThrow(() => validateSources(paths, allExistOps()));
});

test('validateSources: throws when shim binary is missing', () => {
  const paths = buildPaths(validConfig(), REPO_ROOT);
  assert.throws(
    () => validateSources(paths, missingOps(paths.shimBinarySrc)),
    /shim binary/
  );
});

test('validateSources: throws when plist template is missing', () => {
  const paths = buildPaths(validConfig(), REPO_ROOT);
  assert.throws(
    () => validateSources(paths, missingOps(paths.plistTemplateSrc)),
    /Info\.plist template/
  );
});

test('validateSources: throws when Chromium.app is missing', () => {
  const paths = buildPaths(validConfig(), REPO_ROOT);
  assert.throws(
    () => validateSources(paths, missingOps(paths.chromiumSrc)),
    /Chromium\.app/
  );
});

test('validateSources: throws when icon is missing', () => {
  const paths = buildPaths(validConfig(), REPO_ROOT);
  assert.throws(
    () => validateSources(paths, missingOps(paths.iconSrc)),
    /app icon/
  );
});

// ── assembleBundle ────────────────────────────────────────────────────────────

function makeMockOps(plistTemplate = '<string>{{APP_NAME}}</string>') {
  const log = { mkdirp: [], copyRecursive: [], makeExecutable: [], writeFile: [] };
  const ops = {
    log,
    mkdirp:        (p)       => log.mkdirp.push(p),
    copyRecursive: (src, dst) => log.copyRecursive.push({ src, dst }),
    makeExecutable:(p)       => log.makeExecutable.push(p),
    writeFile:     (p, c)    => log.writeFile.push({ path: p, content: c }),
    readFile:      ()        => plistTemplate,
    exists:        ()        => true,
  };
  return ops;
}

test('assembleBundle: creates MacOS, Frameworks, Resources dirs', () => {
  const paths = buildPaths(validConfig(), REPO_ROOT);
  const ops   = makeMockOps();
  assembleBundle(paths, validConfig(), plistLib, ops);
  assert.ok(ops.log.mkdirp.some((p) => p.endsWith('MacOS')));
  assert.ok(ops.log.mkdirp.some((p) => p.endsWith('Frameworks')));
  assert.ok(ops.log.mkdirp.some((p) => p.endsWith('Resources')));
});

test('assembleBundle: copies shim binary to MacOS/nacre', () => {
  const config = validConfig();
  const paths  = buildPaths(config, REPO_ROOT);
  const ops    = makeMockOps();
  assembleBundle(paths, config, plistLib, ops);
  const copy = ops.log.copyRecursive.find((c) => c.dst === paths.shimBinaryDest);
  assert.ok(copy, 'expected a copy to shimBinaryDest');
  assert.equal(copy.src, paths.shimBinarySrc);
});

test('assembleBundle: makes shim binary executable', () => {
  const config = validConfig();
  const paths  = buildPaths(config, REPO_ROOT);
  const ops    = makeMockOps();
  assembleBundle(paths, config, plistLib, ops);
  assert.ok(ops.log.makeExecutable.includes(paths.shimBinaryDest));
});

test('assembleBundle: copies Chromium.app to Frameworks', () => {
  const config = validConfig();
  const paths  = buildPaths(config, REPO_ROOT);
  const ops    = makeMockOps();
  assembleBundle(paths, config, plistLib, ops);
  const copy = ops.log.copyRecursive.find((c) => c.dst === paths.chromiumDest);
  assert.ok(copy, 'expected a copy to chromiumDest');
  assert.equal(copy.src, paths.chromiumSrc);
});

test('assembleBundle: copies icon to Resources/AppIcon.icns', () => {
  const config = validConfig();
  const paths  = buildPaths(config, REPO_ROOT);
  const ops    = makeMockOps();
  assembleBundle(paths, config, plistLib, ops);
  const copy = ops.log.copyRecursive.find((c) => c.dst === paths.iconDest);
  assert.ok(copy, 'expected a copy to iconDest');
  assert.equal(copy.src, paths.iconSrc);
});

test('assembleBundle: writes patched plist to Contents/Info.plist', () => {
  const config   = validConfig();
  const paths    = buildPaths(config, REPO_ROOT);
  const template = `<string>{{APP_NAME}}</string><string>{{BUNDLE_ID}}</string>`;
  const ops      = makeMockOps(template);
  assembleBundle(paths, config, plistLib, ops);

  const write = ops.log.writeFile.find((w) => w.path === paths.plistDest);
  assert.ok(write, 'expected a writeFile to plistDest');
  assert.ok(write.content.includes('My App'));
  assert.ok(write.content.includes('com.example.myapp'));
  assert.ok(!write.content.includes('{{APP_NAME}}'),  'token APP_NAME should be replaced');
  assert.ok(!write.content.includes('{{BUNDLE_ID}}'), 'token BUNDLE_ID should be replaced');
});

test('assembleBundle: operations happen in correct order', () => {
  // Dirs must be created before files are written/copied into them.
  const config = validConfig();
  const paths  = buildPaths(config, REPO_ROOT);
  const order  = [];
  const ops = {
    mkdirp:        (p)        => order.push({ op: 'mkdir', p }),
    copyRecursive: (src, dst) => order.push({ op: 'copy',  dst }),
    makeExecutable:(p)        => order.push({ op: 'chmod', p }),
    writeFile:     (p, c)     => order.push({ op: 'write', p }),
    readFile:      ()         => '{{APP_NAME}}',
    exists:        ()         => true,
  };
  assembleBundle(paths, config, plistLib, ops);

  const firstMkdir = order.findIndex((e) => e.op === 'mkdir');
  const firstCopy  = order.findIndex((e) => e.op === 'copy');
  assert.ok(firstMkdir < firstCopy, 'mkdir must precede copy');
});
