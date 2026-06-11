// scripts/lib/plist.js
// nacre build script — Info.plist template patching
//
// Intentionally avoids any XML parser.  The template uses simple
// {{TOKEN}} placeholders in string values; we replace them with
// escaped XML character data.
//
// This is sufficient because:
//   • We control the template — it only ever has tokens in <string> values.
//   • The replacement values are app name, bundle ID, and version — none of
//     which can contain XML special characters that would break the document
//     (we validate + escape defensively anyway).
//
// Pure functions throughout — injectable for testing.

'use strict';

// ── XML character escaping ────────────────────────────────────────────────────

/**
 * Escape a string for safe use as XML character data (inside a <string> element).
 *
 * @param {string} value
 * @returns {string}
 */
function escapeXml(value) {
  return String(value)
    .replace(/&/g,  '&amp;')
    .replace(/</g,  '&lt;')
    .replace(/>/g,  '&gt;')
    .replace(/"/g,  '&quot;')
    .replace(/'/g,  '&apos;');
}

// ── Token replacement ─────────────────────────────────────────────────────────

/**
 * Replace all occurrences of `{{TOKEN}}` in `template` with the corresponding
 * value from the `tokens` map.  Values are XML-escaped before substitution.
 *
 * Tokens present in the template but absent from `tokens` are left unchanged.
 * Tokens present in `tokens` but absent from the template are ignored.
 *
 * @param {string}                template - Raw plist template string.
 * @param {Record<string,string>} tokens   - Map of TOKEN_NAME → replacement value.
 * @returns {string}                         Patched plist string.
 */
function applyTokens(template, tokens) {
  let result = template;
  for (const [name, value] of Object.entries(tokens)) {
    const placeholder = `{{${name}}}`;
    const escaped     = escapeXml(value);
    // Replace all occurrences (a token may appear more than once, e.g. APP_NAME)
    result = result.split(placeholder).join(escaped);
  }
  return result;
}

// ── findUnreplacedTokens ──────────────────────────────────────────────────────

/**
 * Return an array of token names that are still present in `plist` after
 * substitution.  Useful for warnings / diagnostics.
 *
 * @param {string} plist - Plist string (after applyTokens).
 * @returns {string[]}     Array of token names, e.g. ["APP_NAME", "VERSION"].
 */
function findUnreplacedTokens(plist) {
  const matches = plist.match(/\{\{([A-Z0-9_]+)\}\}/g) ?? [];
  // De-duplicate and strip the {{ }} wrapper
  return [...new Set(matches.map((m) => m.slice(2, -2)))];
}

// ── buildTokenMap ─────────────────────────────────────────────────────────────

/**
 * Build the token map expected by applyTokens from a normalised nacre config.
 *
 * @param {object} config - Normalised config (output of normaliseConfig).
 * @returns {Record<string,string>}
 */
function buildTokenMap(config) {
  return {
    APP_NAME:  config.app.name,
    BUNDLE_ID: config.app.bundleId,
    VERSION:   config.app.version,
  };
}

module.exports = { escapeXml, applyTokens, findUnreplacedTokens, buildTokenMap };
