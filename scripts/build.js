#!/usr/bin/env node
// scripts/build.js
// nacre build script — entry point
//
// Usage:
//   node scripts/build.js --config <path-to-nacre.config.json>
//
// The config file path may be absolute or relative to cwd.
// See README.md for the config file format.

'use strict';

const nodePath = require('node:path');
const { loadConfig, validateConfig, normaliseConfig } = require('./lib/validate');
const { buildPaths, ensureShimBinary, validateSources, assembleBundle } = require('./lib/assemble');
const plistLib = require('./lib/plist');

// ── CLI argument parsing ──────────────────────────────────────────────────────

function parseArgs(argv) {
  const args = argv.slice(2); // drop 'node' and script path
  const result = {};
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--config' && args[i + 1]) {
      result.config = args[++i];
    }
  }
  return result;
}

// ── Main ──────────────────────────────────────────────────────────────────────

function main() {
  const { config: configArg } = parseArgs(process.argv);

  if (!configArg) {
    console.error('Usage: node scripts/build.js --config <path-to-nacre.config.json>');
    process.exit(1);
  }

  const configFilePath = nodePath.resolve(process.cwd(), configArg);

  // nacre repo root is one level up from scripts/
  const repoRoot = nodePath.resolve(__dirname, '..');
  const shimDir  = nodePath.join(repoRoot, 'shim');

  let config;
  try {
    config = normaliseConfig(
      validateConfig(
        loadConfig(configFilePath)
      ),
      configFilePath
    );
  } catch (err) {
    console.error(err.message);
    process.exit(1);
  }

  const paths = buildPaths(config, repoRoot);

  try {
    // Compile shim if needed
    ensureShimBinary(paths.shimBinarySrc, shimDir);

    // Verify all sources exist before touching the output directory
    validateSources(paths);

    // Build the bundle
    assembleBundle(paths, config, plistLib);

    console.log(`\n✓ nacre.app → ${paths.appBundle}\n`);
  } catch (err) {
    console.error(`\n✗ ${err.message}\n`);
    process.exit(1);
  }
}

main();
