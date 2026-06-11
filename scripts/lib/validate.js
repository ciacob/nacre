// scripts/lib/validate.js
// nacre build script — configuration validation
//
// All public functions are pure (or accept injectable fs/path for testing).
// No side effects beyond throwing on invalid input.
//
// Usage:
//   const { loadConfig, validateConfig, normaliseConfig } = require('./validate');
//   const config = normaliseConfig(validateConfig(loadConfig(filePath)));

'use strict';

const nodePath = require('node:path');
const nodeFs   = require('node:fs');

// ── Schema ────────────────────────────────────────────────────────────────────
// Describes the expected shape of a nacre config file.

const REQUIRED_STRINGS = [
  ['app', 'name'],
  ['app', 'bundleId'],
  ['app', 'version'],
  ['app', 'icon'],
  ['browser', 'executablePath'],
  ['output', 'dir'],
];

// ── loadConfig ────────────────────────────────────────────────────────────────

/**
 * Read and JSON-parse a config file from disk.
 *
 * @param {string}   filePath  - Absolute or relative path to the JSON config.
 * @param {object}   [fs]      - Injectable fs module (default: node:fs).
 * @returns {object}             Parsed config object.
 * @throws  {Error}              If the file cannot be read or is not valid JSON.
 */
function loadConfig(filePath, fs = nodeFs) {
  let raw;
  try {
    raw = fs.readFileSync(filePath, 'utf8');
  } catch (err) {
    throw new Error(`nacre: cannot read config file "${filePath}": ${err.message}`);
  }
  try {
    return JSON.parse(raw);
  } catch (err) {
    throw new Error(`nacre: config file "${filePath}" is not valid JSON: ${err.message}`);
  }
}

// ── validateConfig ────────────────────────────────────────────────────────────

/**
 * Validate a parsed config object.
 * Returns the same object if valid; throws a descriptive Error if not.
 *
 * Checks:
 *   • All required fields are present and non-empty strings.
 *   • app.bundleId matches reverse-DNS format.
 *   • app.version is a semver-ish string (digits and dots only).
 *
 * Does NOT check that paths exist on disk — that is assemble.js's job,
 * so that validate.js remains pure and testable without a real filesystem.
 *
 * @param {object} config - Parsed config object.
 * @returns {object}        The same config object.
 * @throws  {Error}         On the first validation failure found.
 */
function validateConfig(config) {
  if (config === null || typeof config !== 'object') {
    throw new Error('nacre: config must be a JSON object');
  }

  // Required string fields
  for (const [section, key] of REQUIRED_STRINGS) {
    const sectionObj = config[section];
    if (sectionObj === null || typeof sectionObj !== 'object') {
      throw new Error(`nacre: config missing required section "${section}"`);
    }
    const value = sectionObj[key];
    if (typeof value !== 'string' || value.trim() === '') {
      throw new Error(
        `nacre: config["${section}"]["${key}"] must be a non-empty string`
      );
    }
  }

  // Bundle ID format: at least two dot-separated segments, alphanumeric + hyphens
  const bundleId = config.app.bundleId;
  if (!/^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+){1,}$/.test(bundleId)) {
    throw new Error(
      `nacre: config.app.bundleId "${bundleId}" does not look like a valid ` +
      `reverse-DNS bundle identifier (e.g. "com.example.myapp")`
    );
  }

  // Version: digits and dots only (1.0, 1.0.0, 1.2.3, etc.)
  const version = config.app.version;
  if (!/^\d+(\.\d+)*$/.test(version)) {
    throw new Error(
      `nacre: config.app.version "${version}" must be a dot-separated number ` +
      `string (e.g. "1.0.0")`
    );
  }

  return config;
}

// ── normaliseConfig ───────────────────────────────────────────────────────────

/**
 * Resolve all relative paths in the config to absolute paths, anchored to
 * the directory containing the config file.
 *
 * Returns a new object — does not mutate the input.
 *
 * @param {object} config         - Validated config object.
 * @param {string} configFilePath - Path to the config file (used as base for
 *                                  relative path resolution).
 * @param {object} [path]         - Injectable path module (default: node:path).
 * @returns {object}                New config object with absolute paths.
 */
function normaliseConfig(config, configFilePath, path = nodePath) {
  const base = path.dirname(path.resolve(configFilePath));

  const resolve = (p) =>
    path.isAbsolute(p) ? p : path.resolve(base, p);

  return {
    ...config,
    app: {
      ...config.app,
      icon: resolve(config.app.icon),
    },
    browser: {
      ...config.browser,
      executablePath: resolve(config.browser.executablePath),
    },
    output: {
      ...config.output,
      dir: resolve(config.output.dir),
    },
  };
}

module.exports = { loadConfig, validateConfig, normaliseConfig };
