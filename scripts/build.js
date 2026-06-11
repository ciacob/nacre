#!/usr/bin/env node
// scripts/build.js
// nacre build script — entry point
//
// Usage:
//   node scripts/build.js --config <path-to-nacre.config.json>
//
// Config format:
//   {
//     "app": {
//       "name":     "My App",
//       "bundleId": "com.example.myapp",
//       "version":  "1.0.0",
//       "icon":     "./assets/MyApp.icns"
//     },
//     "output": { "dir": "./dist" }
//   }
//
// No browser binary is required — nacre uses WKWebView (system WebKit).

'use strict';

const nodePath = require('node:path');
const { loadConfig, validateConfig, normaliseConfig } = require('./lib/validate');
const { buildPaths, ensureShimBinary, validateSources, assembleBundle } = require('./lib/assemble');
const plistLib = require('./lib/plist');

function parseArgs(argv) {
  const args = argv.slice(2);
  const result = {};
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--config' && args[i + 1]) result.config = args[++i];
  }
  return result;
}

function main() {
  const { config: configArg } = parseArgs(process.argv);
  if (!configArg) {
    console.error('Usage: node scripts/build.js --config <path-to-nacre.config.json>');
    process.exit(1);
  }

  const configFilePath = nodePath.resolve(process.cwd(), configArg);
  const repoRoot       = nodePath.resolve(__dirname, '..');
  const shimDir        = nodePath.join(repoRoot, 'shim');

  let config;
  try {
    config = normaliseConfig(
      validateConfig(loadConfig(configFilePath)),
      configFilePath
    );
  } catch (err) {
    console.error(err.message);
    process.exit(1);
  }

  const paths = buildPaths(config, repoRoot);

  try {
    ensureShimBinary(paths.shimBinarySrc, shimDir);
    validateSources(paths);
    assembleBundle(paths, config, plistLib);
    console.log(`\n✓ ${nodePath.basename(paths.appBundle)} → ${paths.appBundle}\n`);
  } catch (err) {
    console.error(`\n✗ ${err.message}\n`);
    process.exit(1);
  }
}

main();
