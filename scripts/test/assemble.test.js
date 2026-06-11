// scripts/test/assemble.test.js

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

function validConfig() {
  return {
    app:    { name: 'My App', bundleId: 'com.example.myapp', version: '1.0.0',
              icon: '/abs/assets/MyApp.icns' },
    output: { dir: '/abs/dist' },
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

test('buildPaths: no chromiumDest or frameworks path', () => {
  const paths = buildPaths(validConfig(), REPO_ROOT);
  assert.equal(paths.chromiumDest, undefined);
  assert.equal(paths.frameworks,   undefined);
});

// ── ensureShimBinary ──────────────────────────────────────────────────────────

test('ensureShimBinary: skips compile when binary exists', () => {
  let compiled = false;
  ensureShimBinary('/fake/nacre', '/fake/shim',
    { exists: () => true, run: () => { compiled = true; } });
  assert.equal(compiled, false);
});

test('ensureShimBinary: compiles when binary is missing', () => {
  let ranCmd, ranArgs, ranCwd;
  let callCount = 0;
  ensureShimBinary('/fake/nacre', '/fake/shim', {
    exists: () => ++callCount > 1,
    run: (cmd, args, opts) => { ranCmd = cmd; ranArgs = args; ranCwd = opts.cwd; },
  });
  assert.equal(ranCmd, 'swift');
  assert.deepEqual(ranArgs, ['build', '-c', 'release']);
  assert.equal(ranCwd, '/fake/shim');
});

test('ensureShimBinary: throws if binary still missing after compile', () => {
  assert.throws(
    () => ensureShimBinary('/fake/nacre', '/fake/shim',
      { exists: () => false, run: () => {} }),
    /binary not found/
  );
});

// ── validateSources ───────────────────────────────────────────────────────────

test('validateSources: passes when all sources exist', () => {
  const paths = buildPaths(validConfig(), REPO_ROOT);
  assert.doesNotThrow(() => validateSources(paths, { exists: () => true }));
});

test('validateSources: throws when shim binary is missing', () => {
  const paths = buildPaths(validConfig(), REPO_ROOT);
  assert.throws(
    () => validateSources(paths, { exists: (p) => p !== paths.shimBinarySrc }),
    /shim binary/
  );
});

test('validateSources: throws when plist template is missing', () => {
  const paths = buildPaths(validConfig(), REPO_ROOT);
  assert.throws(
    () => validateSources(paths, { exists: (p) => p !== paths.plistTemplateSrc }),
    /Info\.plist template/
  );
});

test('validateSources: throws when icon is missing', () => {
  const paths = buildPaths(validConfig(), REPO_ROOT);
  assert.throws(
    () => validateSources(paths, { exists: (p) => p !== paths.iconSrc }),
    /app icon/
  );
});

// ── assembleBundle ────────────────────────────────────────────────────────────

function makeMockOps(plistTemplate = '<string>{{APP_NAME}}</string>') {
  const log = { mkdirp: [], copyRecursive: [], makeExecutable: [], writeFile: [] };
  return {
    log,
    mkdirp:         (p)        => log.mkdirp.push(p),
    copyRecursive:  (src, dst) => log.copyRecursive.push({ src, dst }),
    makeExecutable: (p)        => log.makeExecutable.push(p),
    writeFile:      (p, c)     => log.writeFile.push({ path: p, content: c }),
    readFile:       ()         => plistTemplate,
    exists:         ()         => true,
  };
}

test('assembleBundle: creates MacOS and Resources dirs (no Frameworks)', () => {
  const ops = makeMockOps();
  assembleBundle(buildPaths(validConfig(), REPO_ROOT), validConfig(), plistLib, ops);
  assert.ok(ops.log.mkdirp.some((p) => p.endsWith('MacOS')));
  assert.ok(ops.log.mkdirp.some((p) => p.endsWith('Resources')));
  assert.ok(!ops.log.mkdirp.some((p) => p.endsWith('Frameworks')),
    'Frameworks dir must not be created');
});

test('assembleBundle: copies shim binary to MacOS/nacre', () => {
  const config = validConfig();
  const paths  = buildPaths(config, REPO_ROOT);
  const ops    = makeMockOps();
  assembleBundle(paths, config, plistLib, ops);
  const copy = ops.log.copyRecursive.find((c) => c.dst === paths.shimBinaryDest);
  assert.ok(copy);
  assert.equal(copy.src, paths.shimBinarySrc);
});

test('assembleBundle: makes shim binary executable', () => {
  const config = validConfig();
  const paths  = buildPaths(config, REPO_ROOT);
  const ops    = makeMockOps();
  assembleBundle(paths, config, plistLib, ops);
  assert.ok(ops.log.makeExecutable.includes(paths.shimBinaryDest));
});

test('assembleBundle: copies icon to Resources/AppIcon.icns', () => {
  const config = validConfig();
  const paths  = buildPaths(config, REPO_ROOT);
  const ops    = makeMockOps();
  assembleBundle(paths, config, plistLib, ops);
  const copy = ops.log.copyRecursive.find((c) => c.dst === paths.iconDest);
  assert.ok(copy);
  assert.equal(copy.src, paths.iconSrc);
});

test('assembleBundle: no browser copy step', () => {
  const config = validConfig();
  const paths  = buildPaths(config, REPO_ROOT);
  const ops    = makeMockOps();
  assembleBundle(paths, config, plistLib, ops);
  const browserCopy = ops.log.copyRecursive.find(
    (c) => c.dst && c.dst.includes('Frameworks')
  );
  assert.equal(browserCopy, undefined, 'No copy into Frameworks should occur');
});

test('assembleBundle: writes patched plist', () => {
  const config   = validConfig();
  const paths    = buildPaths(config, REPO_ROOT);
  const ops      = makeMockOps('<string>{{APP_NAME}}</string><string>{{BUNDLE_ID}}</string>');
  assembleBundle(paths, config, plistLib, ops);
  const write = ops.log.writeFile.find((w) => w.path === paths.plistDest);
  assert.ok(write);
  assert.ok(write.content.includes('My App'));
  assert.ok(write.content.includes('com.example.myapp'));
  assert.ok(!write.content.includes('{{APP_NAME}}'));
});

test('assembleBundle: mkdir precedes copy', () => {
  const config = validConfig();
  const paths  = buildPaths(config, REPO_ROOT);
  const order  = [];
  const ops = {
    mkdirp:         (p)        => order.push({ op: 'mkdir', p }),
    copyRecursive:  (src, dst) => order.push({ op: 'copy',  dst }),
    makeExecutable: (p)        => order.push({ op: 'chmod', p }),
    writeFile:      (p, c)     => order.push({ op: 'write', p }),
    readFile:       ()         => '{{APP_NAME}}',
    exists:         ()         => true,
  };
  assembleBundle(paths, config, plistLib, ops);
  const firstMkdir = order.findIndex((e) => e.op === 'mkdir');
  const firstCopy  = order.findIndex((e) => e.op === 'copy');
  assert.ok(firstMkdir < firstCopy);
});
