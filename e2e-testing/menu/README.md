# nacre menu E2E fixture

Manual end-to-end test fixture for nacre's menu management system.
Spawns the nacre binary, connects over the Unix socket, and provides
a live REPL for driving the menu while observing events in real time.

## Prerequisites

Build the nacre shim binary first:

```bash
cd ../../shim
swift build -c release
```

## Running

```bash
# Basic — uses the debug binary, example.com, default menu
node fixture.js

# Custom nacre binary (debug build, or a packaged .app)
node fixture.js --nacre ../../shim/.build/release/nacre
node fixture.js --nacre /path/to/Sample\ App\ 1.app

# Custom URL (point at a locally running task-primer app)
node fixture.js --url http://127.0.0.1:3000

# Custom menu file
node fixture.js --menu ./my-menu.json

# Custom bundle ID (must match the .app's CFBundleIdentifier)
node fixture.js --bundle-id com.example.myapp
```

## REPL commands

Once running, type commands at the `nacre>` prompt:

| Command | What it tests |
|---|---|
| `patch file.new label New Window` | Live label update |
| `patch file.close enable` | Enable a disabled item |
| `patch file.close disable` | Disable an item (greyed out) |
| `patch view.fullscreen check` | Add a checkmark |
| `patch view.fullscreen uncheck` | Remove a checkmark |
| `menu` | Replace entire menu bar (reloads current file) |
| `menu ./menu.json` | Replace from a specific file |
| `url https://webkit.org` | Navigate WKWebView |
| `devtools on` | Enable Web Inspector (right-click → Inspect) |
| `devtools off` | Disable Web Inspector |
| `reload` | Re-send the current menu (simulate reconnect) |
| `quit` | Kill nacre and exit |

## What to verify manually

- [ ] Menu bar shows all four top-level menus (File, Edit, View, Help)
- [ ] File menu: New (⌘N), Open… (⌘O), separator, Save (⌘S), Save As… (⇧⌘S), separator, Close (greyed, ⌘W)
- [ ] View → Zoom submenu appears on hover with three items
- [ ] `patch file.new label New Window` → menu item label changes live
- [ ] `patch file.close enable` → Close item becomes clickable
- [ ] `patch view.fullscreen check` → checkmark appears next to Full Screen
- [ ] Clicking a menu item → terminal prints `← menu_action  id: "..."`
- [ ] `devtools on` → right-clicking the WKWebView shows Inspect Element
- [ ] `url https://webkit.org` → WKWebView navigates
- [ ] Closing the nacre window (red button) → terminal prints `← window_closed` and fixture exits

## Menu file format

`menu.json` must be a `set_menu` message:

```json
{
  "type": "set_menu",
  "menus": [
    {
      "label": "File",
      "items": [
        { "id": "file.new", "label": "New", "key": "n", "modifiers": ["cmd"] },
        { "type": "separator" },
        { "id": "file.quit", "label": "Quit", "key": "q", "modifiers": ["cmd"] }
      ]
    }
  ]
}
```

Valid `modifiers`: `"cmd"`, `"shift"`, `"option"`, `"control"`

Item fields: `id` (required), `label` (required), `key`, `modifiers`, `enabled` (default true), `checked` (default false), `submenu` (array of items)
