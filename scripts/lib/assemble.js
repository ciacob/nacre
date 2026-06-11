// scripts/lib/assemble.js
// nacre build script — .app bundle assembly
//
// Constructs the <AppName>.app directory tree:
//
//   <output.dir>/
//     <AppName>.app/
//       Contents/
//         Info.plist          ← patched from template
//         MacOS/
//           nacre             ← shim binary (compiled or cached)
//         Resources/
//           AppIcon.icns      ← copied from app.icon
//
// No browser binary is embedded — nacre uses WKWebView (system WebKit),
// so there is nothing to download or vendor.
//
// All filesystem operations are injected so the module is unit-testable
// without touching disk.

'use strict';

const nodeFs        = require('node:fs');
const nodePath      = require('node:path');
const nodeChildProc = require('node:child_process');

// ── Real filesystem/process operations ───────────────────────────────────────

const realOps = {
  exists(p)            { return nodeFs.existsSync(p); },
  mkdirp(p)            { nodeFs.mkdirSync(p, { recursive: true }); },
  writeFile(p, content) {
    nodeFs.mkdirSync(nodePath.dirname(p), { recursive: true });
    nodeFs.writeFileSync(p, content, 'utf8');
  },
  readFile(p)          { return nodeFs.readFileSync(p, 'utf8'); },
  copyRecursive(src, dest) {
    if (nodeFs.existsSync(dest)) {
      nodeFs.rmSync(dest, { recursive: true, force: true });
    }
    nodeChildProc.execFileSync('cp', ['-R', src, dest]);
  },
  makeExecutable(p)    { nodeFs.chmodSync(p, 0o755); },
  run(cmd, args, options = {}) {
    nodeChildProc.execFileSync(cmd, args, { stdio: 'inherit', ...options });
  },
};

// ── Path helpers ──────────────────────────────────────────────────────────────

/**
 * Compute all paths relevant to building <AppName>.app.
 *
 * @param {object} config   - Normalised nacre config.
 * @param {string} repoRoot - Absolute path to the nacre repo root.
 * @param {object} [path]   - Injectable path module.
 * @returns {object}          Map of named paths.
 */
function buildPaths(config, repoRoot, path = nodePath) {
  const safeName  = config.app.name.replace(/[/\\:*?"<>|]/g, '_');
  const appBundle = path.join(config.output.dir, `${safeName}.app`);
  const contents  = path.join(appBundle, 'Contents');

  return {
    // Source paths
    shimBinarySrc:    path.join(repoRoot, 'shim', '.build', 'release', 'nacre'),
    plistTemplateSrc: path.join(repoRoot, 'shim', 'Resources', 'Info.plist'),
    iconSrc:          config.app.icon,

    // Destination paths
    appBundle,
    contents,
    macOS:          path.join(contents, 'MacOS'),
    resources:      path.join(contents, 'Resources'),
    shimBinaryDest: path.join(contents, 'MacOS',     'nacre'),
    plistDest:      path.join(contents, 'Info.plist'),
    iconDest:       path.join(contents, 'Resources', 'AppIcon.icns'),
  };
}

// ── ensureShimBinary ──────────────────────────────────────────────────────────

function ensureShimBinary(shimBinarySrc, shimDir, ops = realOps) {
  if (ops.exists(shimBinarySrc)) {
    console.log(`[nacre] shim binary found at ${shimBinarySrc}, skipping compile`);
    return;
  }
  console.log('[nacre] shim binary not found — compiling (swift build -c release)…');
  ops.run('swift', ['build', '-c', 'release'], { cwd: shimDir });
  if (!ops.exists(shimBinarySrc)) {
    throw new Error(
      `nacre: swift build completed but binary not found at "${shimBinarySrc}"`
    );
  }
  console.log('[nacre] compile complete');
}

// ── validateSources ───────────────────────────────────────────────────────────

function validateSources(paths, ops = realOps) {
  const required = [
    [paths.shimBinarySrc,    'shim binary (.build/release/nacre)'],
    [paths.plistTemplateSrc, 'Info.plist template (shim/Resources/Info.plist)'],
    [paths.iconSrc,          'app icon (app.icon)'],
  ];
  for (const [p, label] of required) {
    if (!ops.exists(p)) {
      throw new Error(`nacre: source not found — ${label}\n  expected: ${p}`);
    }
  }
}

// ── assembleBundle ────────────────────────────────────────────────────────────

/**
 * Build the <AppName>.app bundle from validated sources.
 *
 * Steps:
 *   1. Create directory skeleton (MacOS/, Resources/).
 *   2. Copy shim binary → MacOS/nacre (chmod +x).
 *   3. Copy icon → Resources/AppIcon.icns.
 *   4. Patch Info.plist and write to Contents/Info.plist.
 *
 * @param {object} paths    - Output of buildPaths().
 * @param {object} config   - Normalised config.
 * @param {object} plistLib - { applyTokens, findUnreplacedTokens, buildTokenMap }
 * @param {object} ops      - Injectable operations.
 */
function assembleBundle(paths, config, plistLib, ops = realOps) {
  const { applyTokens, findUnreplacedTokens, buildTokenMap } = plistLib;

  // 1. Directory skeleton — no Frameworks/ needed (WKWebView is system-provided)
  console.log(`[nacre] assembling bundle at ${paths.appBundle}`);
  for (const dir of [paths.macOS, paths.resources]) {
    ops.mkdirp(dir);
  }

  // 2. Shim binary
  console.log('[nacre] copying shim binary…');
  ops.copyRecursive(paths.shimBinarySrc, paths.shimBinaryDest);
  ops.makeExecutable(paths.shimBinaryDest);

  // 3. Icon
  console.log('[nacre] copying icon…');
  ops.copyRecursive(paths.iconSrc, paths.iconDest);

  // 4. Info.plist
  console.log('[nacre] patching Info.plist…');
  const template   = ops.readFile(paths.plistTemplateSrc);
  const tokens     = buildTokenMap(config);
  const patched    = applyTokens(template, tokens);
  const unreplaced = findUnreplacedTokens(patched);
  if (unreplaced.length > 0) {
    console.warn(
      `[nacre] warning: unreplaced tokens in Info.plist: ` +
      unreplaced.map((t) => `{{${t}}}`).join(', ')
    );
  }
  ops.writeFile(paths.plistDest, patched);

  console.log('[nacre] bundle assembly complete');
}

module.exports = { realOps, buildPaths, ensureShimBinary, validateSources, assembleBundle };
