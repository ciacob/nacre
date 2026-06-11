# nacre

A macOS application shim that wraps an embedded Chromium binary inside a
fully-branded `.app` bundle — custom name, icon, menu bar, and registered
file types — while remaining entirely transparent to the Node.js host that
drives it.

Named after the substance that turns an unfinished irritant into a pearl.

---

## Repository layout

```
nacre/
├── shim/                   Swift package — the native macOS shim binary
│   ├── Package.swift
│   ├── Sources/
│   │   ├── nacreLib/       Testable logic (MenuBuilder, SocketServer, ProcessLauncher)
│   │   └── nacre/          Cocoa glue (AppDelegate — thin, not unit-tested)
│   └── Tests/
│       └── nacreTests/     XCTest suites for nacreLib
├── scripts/                Node.js build + packaging scripts  [Phase 3]
└── LICENSE                 Apache 2.0
```

---

## Architecture overview

```
Node.js host (task-primer or similar)
  │
  ├── spawn ──────────────────────────────────────────→  nacre  (this shim)
  │         all argv forwarded to embedded Chromium          │
  │                                                          ├── Chromium (child process)
  └── net.createConnection(menu.sock) ──────────────→       └── Unix socket listener
            JSON menu descriptors  →                              │
            ←  menu_action / file_open / app_reopen              └── NSMenu (native)
```

nacre is a **passive renderer**.  It has no opinion about what the
application does.  Node.js drives everything; nacre translates between
the Node.js world (JSON over a Unix socket) and the macOS world
(NSMenu, NSApplication delegate events, child process lifecycle).

---

## Socket protocol

All messages are newline-delimited JSON frames.

### Inbound (Node.js → nacre)

**`set_menu`** — replace the entire menu bar:
```json
{
  "type": "set_menu",
  "menus": [
    {
      "label": "File",
      "items": [
        { "id": "file.new",   "label": "New",   "key": "n", "modifiers": ["cmd"] },
        { "id": "file.open",  "label": "Open…", "key": "o", "modifiers": ["cmd"] },
        { "type": "separator" },
        { "id": "file.close", "label": "Close", "key": "w", "modifiers": ["cmd"],
          "enabled": false }
      ]
    }
  ]
}
```

**`patch_menu`** — update specific items by ID (no full rebuild):
```json
{
  "type": "patch_menu",
  "patches": [
    { "id": "file.save",  "enabled": true  },
    { "id": "view.theme", "label": "Dark Mode", "checked": true }
  ]
}
```

Supported patch fields: `label`, `enabled`, `checked`.

### Outbound (nacre → Node.js)

```json
{ "type": "menu_action", "id": "file.new" }
{ "type": "file_open",   "paths": ["/Users/me/doc.myext"] }
{ "type": "app_reopen" }
```

### Socket path

`/tmp/<CFBundleIdentifier>/menu.sock`

The bundle identifier is set in `Info.plist` at packaging time.
Node.js derives the same path from the same bundle ID (available in
`package.json`'s `taskPrimer` config).

---

## Building the shim

Requirements: macOS 13+, Xcode Command Line Tools (`xcode-select --install`).

```bash
cd shim
swift build -c release
# output: .build/release/nacre
```

Run the tests:
```bash
swift test
```

---

## Packaging (per-application)

> Phase 3 — Node.js build scripts are not yet in this repository.
> The manual steps are documented here for reference.

```bash
# 1. Copy the generic shim binary into a new .app bundle
cp -R MyApp.app.template MyApp.app
cp .build/release/nacre MyApp.app/Contents/MacOS/nacre

# 2. Embed a pinned Chrome for Testing build
cp -R .browsers/chromium MyApp.app/Contents/Frameworks/Chromium.app

# 3. Patch Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleName MyApp" MyApp.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.example.myapp" \
    MyApp.app/Contents/Info.plist

# 4. Replace icon
cp MyApp.icns MyApp.app/Contents/Resources/AppIcon.icns

# 5. Sign
codesign --deep --force --sign "Developer ID Application: …" MyApp.app

# 6. Notarize
xcrun notarytool submit MyApp.app --apple-id … --team-id … --password …
xcrun stapler staple MyApp.app
```

---

## License

Apache License 2.0 — see [LICENSE](LICENSE).
