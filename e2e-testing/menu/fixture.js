#!/usr/bin/env node
'use strict';

/**
 * e2e-testing/menu/fixture.js
 *
 * Manual end-to-end fixture for nacre menu management.
 *
 * Spawns the nacre binary, connects to its socket, sends an initial menu,
 * then accepts live commands from stdin while printing all received nacre
 * events to the terminal.
 *
 * Usage:
 *   node fixture.js [options]
 *
 * Options:
 *   --nacre <path>     Path to the nacre binary or .app bundle.
 *                      Defaults to ../../shim/.build/release/nacre
 *   --menu  <path>     Path to a set_menu JSON file.
 *                      Defaults to ./menu.json
 *   --url   <url>      URL to load in WKWebView on startup.
 *                      Defaults to https://example.com
 *   --bundle-id <id>   Bundle ID used to derive the socket path.
 *                      Defaults to nacre (→ /tmp/nacre/menu.sock)
 *
 * Stdin commands (type and press Enter):
 *   patch <id> label <text>   Relabel a menu item
 *   patch <id> enable         Enable a menu item
 *   patch <id> disable        Disable a menu item
 *   patch <id> check          Add a checkmark to a menu item
 *   patch <id> uncheck        Remove the checkmark from a menu item
 *   menu [path]               Replace entire menu bar (default: ./menu.json)
 *   url <url>                 Navigate WKWebView to a URL
 *   devtools on|off           Toggle WebKit developer tools
 *   reload                    Re-send the current menu (useful after nacre reconnect)
 *   help                      Print available commands
 *   quit                      Kill nacre and exit
 *
 * Received events are printed with a timestamp prefix, e.g.:
 *   [10:23:44] ← menu_action  { id: 'file.new' }
 *   [10:23:51] ← window_closed
 */

const net      = require('node:net');
const path     = require('node:path');
const fs       = require('node:fs');
const readline = require('node:readline');
const { spawn } = require('node:child_process');

// ── Argument parsing ──────────────────────────────────────────────────────────

const args = process.argv.slice(2);
function getArg(flag, def) {
  const i = args.indexOf(flag);
  return i !== -1 && args[i + 1] ? args[i + 1] : def;
}

const SCRIPT_DIR     = __dirname;
const REPO_ROOT      = path.resolve(SCRIPT_DIR, '..', '..');
const DEFAULT_BINARY = path.join(REPO_ROOT, 'shim', '.build', 'release', 'nacre');
const DEFAULT_MENU   = path.join(SCRIPT_DIR, 'menu.json');

const NACRE_PATH  = getArg('--nacre',     DEFAULT_BINARY);
const MENU_PATH   = getArg('--menu',      DEFAULT_MENU);
const INITIAL_URL = getArg('--url',       'https://example.com');
const BUNDLE_ID   = getArg('--bundle-id', 'nacre');
const SOCKET_PATH = `/tmp/${BUNDLE_ID}/menu.sock`;

// ── Helpers ───────────────────────────────────────────────────────────────────

function ts() {
  return new Date().toTimeString().slice(0, 8);
}

function log(...args) {
  console.log(`[${ts()}]`, ...args);
}

function resolveNacreBinary(p) {
  // Accept either a .app bundle path or a raw binary path.
  // If it ends in .app, derive the binary path from the bundle convention.
  if (p.endsWith('.app')) {
    const appName = path.basename(p, '.app');
    return path.join(p, 'Contents', 'MacOS', appName);
  }
  return p;
}

// ── Socket connection ─────────────────────────────────────────────────────────

let sock        = null;
let sendBuffer  = '';   // messages queued before socket connects
let connected   = false;

function socketSend(message) {
  const frame = JSON.stringify(message) + '\n';
  if (connected && sock) {
    sock.write(frame);
  } else {
    sendBuffer += frame;
    log('(queued — not yet connected)');
  }
}

function connectSocket(retries = 30, intervalMs = 333) {
  let attempts = 0;

  function attempt() {
    const s = net.createConnection(SOCKET_PATH);

    s.once('connect', () => {
      sock      = s;
      connected = true;
      log(`✓ Connected to nacre socket at ${SOCKET_PATH}`);

      // Flush queued messages
      if (sendBuffer) {
        s.write(sendBuffer);
        sendBuffer = '';
      }

      // Handle inbound messages
      let buf = '';
      s.on('data', (chunk) => {
        buf += chunk.toString();
        const lines = buf.split('\n');
        buf = lines.pop();
        for (const line of lines) {
          const trimmed = line.trim();
          if (!trimmed) continue;
          try {
            const msg = JSON.parse(trimmed);
            handleNacreEvent(msg);
          } catch (_) {
            log('← (unparseable frame):', trimmed);
          }
        }
      });

      s.on('close', () => {
        connected = false;
        sock      = null;
        log('Socket closed. nacre may have exited.');
      });

      s.on('error', (err) => {
        log('Socket error:', err.message);
      });
    });

    s.once('error', () => {
      s.destroy();
      if (++attempts < retries) {
        setTimeout(attempt, intervalMs);
      } else {
        log(`✗ Could not connect to ${SOCKET_PATH} after ${retries} attempts.`);
        log('  Is nacre running? Check --nacre path and --bundle-id.');
        process.exit(1);
      }
    });
  }

  log(`Connecting to ${SOCKET_PATH}…`);
  attempt();
}

// ── Nacre event handler ───────────────────────────────────────────────────────

function handleNacreEvent(msg) {
  switch (msg.type) {
    case 'menu_action':
      log(`← menu_action   id: "${msg.id}"`);
      break;
    case 'window_closed':
      log('← window_closed  (nacre window was closed by the user)');
      log('  Exiting fixture. Re-run to test again.');
      process.exit(0);
      break;
    case 'app_reopen':
      log('← app_reopen    (Dock icon clicked while app already running)');
      break;
    case 'file_open':
      log(`← file_open     paths: ${JSON.stringify(msg.paths)}`);
      break;
    default:
      log('← (unknown event):', JSON.stringify(msg));
  }
}

// ── Menu loading ──────────────────────────────────────────────────────────────

function loadMenuFile(filePath) {
  const resolved = path.resolve(filePath);
  if (!fs.existsSync(resolved)) {
    log(`✗ Menu file not found: ${resolved}`);
    return null;
  }
  try {
    return JSON.parse(fs.readFileSync(resolved, 'utf8'));
  } catch (err) {
    log(`✗ Failed to parse menu file: ${err.message}`);
    return null;
  }
}

let currentMenuPath = MENU_PATH;

function sendMenu(filePath) {
  const msg = loadMenuFile(filePath);
  if (!msg) return;
  if (msg.type !== 'set_menu' || !Array.isArray(msg.menus)) {
    log('✗ Menu file must be a set_menu message: { "type": "set_menu", "menus": [...] }');
    return;
  }
  currentMenuPath = filePath;
  socketSend(msg);
  log(`→ set_menu       (${msg.menus.length} top-level menus from ${path.basename(filePath)})`);
}

// ── Command parsing ───────────────────────────────────────────────────────────

function printHelp() {
  console.log(`
Commands:
  patch <id> label <text>   Relabel a menu item
  patch <id> enable         Enable a menu item
  patch <id> disable        Disable a menu item
  patch <id> check          Add a checkmark to a menu item
  patch <id> uncheck        Remove the checkmark from a menu item
  menu [path]               Replace entire menu bar (default: current menu file)
  url <url>                 Navigate WKWebView to a URL
  devtools on|off           Toggle WebKit developer tools
  reload                    Re-send the current menu
  help                      Print this message
  quit                      Kill nacre and exit
`);
}

function handleCommand(line) {
  const parts = line.trim().split(/\s+/);
  if (!parts[0]) return;

  const cmd = parts[0].toLowerCase();

  switch (cmd) {

    case 'patch': {
      const id     = parts[1];
      const op     = parts[2]?.toLowerCase();
      if (!id || !op) {
        log('Usage: patch <id> label <text> | enable | disable | check | uncheck');
        return;
      }
      const patch = { id };
      if (op === 'label') {
        const text = parts.slice(3).join(' ');
        if (!text) { log('Usage: patch <id> label <text>'); return; }
        patch.label = text;
        log(`→ patch_menu     id:"${id}" label:"${text}"`);
      } else if (op === 'enable') {
        patch.enabled = true;
        log(`→ patch_menu     id:"${id}" enabled:true`);
      } else if (op === 'disable') {
        patch.enabled = false;
        log(`→ patch_menu     id:"${id}" enabled:false`);
      } else if (op === 'check') {
        patch.checked = true;
        log(`→ patch_menu     id:"${id}" checked:true`);
      } else if (op === 'uncheck') {
        patch.checked = false;
        log(`→ patch_menu     id:"${id}" checked:false`);
      } else {
        log(`Unknown patch op "${op}". Use: label | enable | disable | check | uncheck`);
        return;
      }
      socketSend({ type: 'patch_menu', patches: [patch] });
      break;
    }

    case 'menu': {
      const filePath = parts[1] || currentMenuPath;
      sendMenu(filePath);
      break;
    }

    case 'url': {
      const url = parts[1];
      if (!url) { log('Usage: url <url>'); return; }
      socketSend({ type: 'set_url', url });
      log(`→ set_url        ${url}`);
      break;
    }

    case 'devtools': {
      const val = parts[1]?.toLowerCase();
      if (val !== 'on' && val !== 'off') {
        log('Usage: devtools on|off');
        return;
      }
      const enabled = val === 'on';
      socketSend({ type: 'set_devtools', enabled });
      log(`→ set_devtools   enabled:${enabled}`);
      break;
    }

    case 'reload': {
      sendMenu(currentMenuPath);
      break;
    }

    case 'help': {
      printHelp();
      break;
    }

    case 'quit': {
      log('Quitting…');
      if (nacrePid) {
        try { process.kill(nacrePid, 'SIGTERM'); } catch (_) {}
      }
      process.exit(0);
      break;
    }

    default:
      log(`Unknown command "${cmd}". Type "help" for available commands.`);
  }
}

// ── nacre spawn ───────────────────────────────────────────────────────────────

let nacrePid = null;

function spawnNacre() {
  const binary = resolveNacreBinary(NACRE_PATH);

  if (!fs.existsSync(binary)) {
    log(`✗ nacre binary not found at: ${binary}`);
    log('  Build it first:  cd shim && swift build -c release');
    log('  Or pass:         --nacre /path/to/nacre  or  --nacre /path/to/MyApp.app');
    process.exit(1);
  }

  const nacreArgs = [
    `--app=${INITIAL_URL}`,
    `--nacre-socket=${SOCKET_PATH}`,
    '--no-first-run',
    '--no-default-browser-check',
  ];

  log(`Spawning nacre: ${binary}`);
  log(`  args: ${nacreArgs.join(' ')}`);

  const child = spawn(binary, nacreArgs, {
    detached: false,
    stdio:    'ignore',
  });

  nacrePid = child.pid;
  log(`nacre pid: ${nacrePid}`);

  child.on('exit', (code, signal) => {
    log(`nacre exited (code=${code}, signal=${signal})`);
    process.exit(0);
  });

  child.on('error', (err) => {
    log(`✗ Failed to spawn nacre: ${err.message}`);
    process.exit(1);
  });
}

// ── Initial messages ──────────────────────────────────────────────────────────

function sendInitialMessages() {
  // URL
  socketSend({ type: 'set_url', url: INITIAL_URL });
  log(`→ set_url        ${INITIAL_URL}`);

  // Menu
  sendMenu(MENU_PATH);
}

// ── Stdin REPL ────────────────────────────────────────────────────────────────

function startREPL() {
  const rl = readline.createInterface({
    input:    process.stdin,
    output:   process.stdout,
    prompt:   'nacre> ',
    terminal: true,
  });

  rl.prompt();

  rl.on('line', (line) => {
    handleCommand(line);
    rl.prompt();
  });

  rl.on('close', () => {
    log('stdin closed — exiting');
    process.exit(0);
  });
}

// ── Startup ───────────────────────────────────────────────────────────────────

console.log(`
╔═══════════════════════════════════════════╗
║   nacre menu E2E fixture                  ║
║   type "help" for available commands      ║
╚═══════════════════════════════════════════╝
`);

log(`nacre binary : ${resolveNacreBinary(NACRE_PATH)}`);
log(`socket path  : ${SOCKET_PATH}`);
log(`initial URL  : ${INITIAL_URL}`);
log(`menu file    : ${MENU_PATH}`);
console.log('');

spawnNacre();
connectSocket();

// Wait for socket to connect, then send initial messages.
// connectSocket retries for ~10 s; once connected it flushes the queue.
// We queue immediately so nothing is missed.
sendInitialMessages();

startREPL();
