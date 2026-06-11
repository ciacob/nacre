// scripts/lib/validate.js
// nacre build script — configuration validation

'use strict';

const nodePath = require('node:path');
const nodeFs   = require('node:fs');

const REQUIRED_STRINGS = [
  ['app', 'name'],
  ['app', 'bundleId'],
  ['app', 'version'],
  ['app', 'icon'],
  ['output', 'dir'],
];

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

function validateConfig(config) {
  if (config === null || typeof config !== 'object') {
    throw new Error('nacre: config must be a JSON object');
  }

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

  const bundleId = config.app.bundleId;
  if (!/^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+){1,}$/.test(bundleId)) {
    throw new Error(
      `nacre: config.app.bundleId "${bundleId}" does not look like a valid ` +
      `reverse-DNS bundle identifier (e.g. "com.example.myapp")`
    );
  }

  const version = config.app.version;
  if (!/^\d+(\.\d+)*$/.test(version)) {
    throw new Error(
      `nacre: config.app.version "${version}" must be a dot-separated number ` +
      `string (e.g. "1.0.0")`
    );
  }

  return config;
}

function normaliseConfig(config, configFilePath, path = nodePath) {
  const base    = path.dirname(path.resolve(configFilePath));
  const resolve = (p) => path.isAbsolute(p) ? p : path.resolve(base, p);

  return {
    ...config,
    app: {
      ...config.app,
      icon: resolve(config.app.icon),
    },
    output: {
      ...config.output,
      dir: resolve(config.output.dir),
    },
  };
}

module.exports = { loadConfig, validateConfig, normaliseConfig };
