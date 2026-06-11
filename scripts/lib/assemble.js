// scripts/lib/assemble.js
// nacre build script — .app bundle assembly
//
// Constructs the nacre.app directory tree:
//
//   <output.dir>/
//     nacre.app/
//       Contents/
//         Info.plist                  ← patched from template
//         MacOS/
//           nacre                     ← shim binary (compiled or cached)
//         Frameworks/
//           Chromium.app/             ← copied from browser.executablePath
//         Resources/
//           AppIcon.icns              ← copied from app.icon
//
// All filesystem operations are injected so the module is unit-testable
// without touching disk.  The real `ops` object (module.exports.realOps)
// uses Node built-ins.

'use strict';

const nodeFs        = require('node:fs');
const nodePath      = require('node:path');
const nodeChildProc = require('node:child_process');

// ── Real filesystem/process operations ───────────────────────────────────────

const realOps = {
  /** Check whether a path exists on disk. */
  exists(p) {
    return nodeFs.existsSync(p);
  },

  /** Create a directory (and all parents). No-op if it already exists. */
  mkdirp(p) {
    nodeFs.mkdirSync(p, { recursive: true });
  },

  /** Write a string to a file, creating parent dirs as needed. */
  writeFile(p, content) {
    nodeFs.mkdirSync(nodePath.dirname(p), { recursive: true });
    nodeFs.writeFileSync(p, content, 'utf8');
  },

  /** Read a file as a UTF-8 string. */
  readFile(p) {
    return nodeFs.readFileSync(p, 'utf8');
  },

  /**
   * Copy a file or directory recursively.
   * Uses the native `cp -R` on macOS for speed and fidelity
   * (preserves symlinks, resource forks, extended attributes).
   */
  copyRecursive(src, dest) {
    // Remove destination first so cp -R doesn't nest inside an existing dir
    if (nodeFs.existsSync(dest)) {
      nodeFs.rmSync(dest, { recursive: true, force: true });
    }
    nodeChildProc.execFileSync('cp', ['-R', src, dest]);
  },

  /**
   * Make a file executable (chmod +x).
   */
  makeExecutable(p) {
    nodeFs.chmodSync(p, 0o755);
  },

  /**
   * Run a command synchronously, inheriting stdio so build output is visible.
   * Throws on non-zero exit.
   */
  run(cmd, args, options = {}) {
    nodeChildProc.execFileSync(cmd, args, { stdio: 'inherit', ...options });
  },
};

// ── Path helpers ──────────────────────────────────────────────────────────────

/**
 * Compute all paths relevant to building nacre.app.
 *
 * @param {object} config   - Normalised nacre config.
 * @param {string} repoRoot - Absolute path to the nacre repo root.
 * @param {object} [path]   - Injectable path module.
 * @returns {object}          Map of named paths.
 */
function buildPaths(config, repoRoot, path = nodePath) {
  const safeName      = config.app.name.replace(/[/\\:*?"<>|]/g, '_');
  const appBundle     = path.join(config.output.dir, `${safeName}.app`);
  const contents      = path.join(appBundle, 'Contents');

  return {
    // Source paths
    shimBinarySrc:    path.join(repoRoot, 'shim', '.build', 'release', 'nacre'),
    plistTemplateSrc: path.join(repoRoot, 'shim', 'Resources', 'Info.plist'),
    chromiumSrc:      config.browser.executablePath,
    iconSrc:          config.app.icon,

    // Destination paths
    appBundle,
    contents,
    macOS:            path.join(contents, 'MacOS'),
    frameworks:       path.join(contents, 'Frameworks'),
    resources:        path.join(contents, 'Resources'),
    shimBinaryDest:   path.join(contents, 'MacOS',      'nacre'),
    plistDest:        path.join(contents, 'Info.plist'),
    chromiumDest:     path.join(contents, 'Frameworks', 'Chromium.app'),
    iconDest:         path.join(contents, 'Resources',  'AppIcon.icns'),
  };
}

// ── ensureShimBinary ──────────────────────────────────────────────────────────

/**
 * Compile the shim binary if it is not already present.
 *
 * @param {string} shimBinarySrc - Expected path of the compiled binary.
 * @param {string} shimDir       - Path to the shim/ Swift package directory.
 * @param {object} ops           - Injectable operations.
 */
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

/**
 * Verify that all source paths exist before starting assembly.
 * Throws on the first missing path with a clear message.
 *
 * @param {object} paths - Output of buildPaths().
 * @param {object} ops   - Injectable operations.
 */
function validateSources(paths, ops = realOps) {
  const required = [
    [paths.shimBinarySrc,    'shim binary (.build/release/nacre)'],
    [paths.plistTemplateSrc, 'Info.plist template (shim/Resources/Info.plist)'],
    [paths.chromiumSrc,      'Chromium.app (browser.executablePath)'],
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
 * Build the nacre.app bundle from validated sources.
 *
 * Steps:
 *   1. Create directory skeleton.
 *   2. Copy shim binary → MacOS/nacre (chmod +x).
 *   3. Copy Chromium.app → Frameworks/Chromium.app.
 *   4. Copy icon → Resources/AppIcon.icns.
 *   5. Patch Info.plist and write to Contents/Info.plist.
 *
 * @param {object} paths      - Output of buildPaths().
 * @param {object} config     - Normalised config.
 * @param {object} plistLib   - { applyTokens, findUnreplacedTokens, buildTokenMap }
 * @param {object} ops        - Injectable operations.
 */
function assembleBundle(paths, config, plistLib, ops = realOps) {
  const { applyTokens, findUnreplacedTokens, buildTokenMap } = plistLib;

  // 1. Directory skeleton
  console.log(`[nacre] assembling bundle at ${paths.appBundle}`);
  for (const dir of [paths.macOS, paths.frameworks, paths.resources]) {
    ops.mkdirp(dir);
  }

  // 2. Shim binary
  console.log('[nacre] copying shim binary…');
  ops.copyRecursive(paths.shimBinarySrc, paths.shimBinaryDest);
  ops.makeExecutable(paths.shimBinaryDest);

  // 3. Chromium.app
  console.log('[nacre] copying Chromium.app…');
  ops.copyRecursive(paths.chromiumSrc, paths.chromiumDest);

  // 4. Icon
  console.log('[nacre] copying icon…');
  ops.copyRecursive(paths.iconSrc, paths.iconDest);

  // 5. Info.plist
  console.log('[nacre] patching Info.plist…');
  const template = ops.readFile(paths.plistTemplateSrc);
  const tokens   = buildTokenMap(config);
  const patched  = applyTokens(template, tokens);

  const unreplaced = findUnreplacedTokens(patched);
  if (unreplaced.length > 0) {
    console.warn(
      `[nacre] warning: Info.plist still contains unreplaced tokens: ` +
      unreplaced.map((t) => `{{${t}}}`).join(', ')
    );
  }

  ops.writeFile(paths.plistDest, patched);
  console.log('[nacre] bundle assembly complete');
}

module.exports = {
  realOps,
  buildPaths,
  ensureShimBinary,
  validateSources,
  assembleBundle,
};
