// AppDelegate.swift
// nacre (executable target)
//
// Wires MenuBuilder + SocketServer + ProcessLauncher together.
// This file is intentionally thin — all real logic lives in nacreLib
// so it can be unit tested.  AppDelegate is the untestable Cocoa glue.
//
// Lifecycle
// ─────────
// 1. applicationDidFinishLaunching
//      a. Install a minimal default menu immediately (so the app is not broken
//         before Node.js connects and sends set_menu).
//      b. Start the SocketServer.
//      c. Launch the embedded Chromium child process.
//
// 2. Socket messages (on main thread, delivered by SocketServer)
//      set_menu   → rebuild NSApplication.shared.mainMenu
//      patch_menu → mutate existing menu items in place
//
// 3. Menu item activation (menuItemActivated(_:))
//      → emit menu_action outbound message over the socket
//
// 4. applicationOpenFiles / applicationShouldHandleReopen
//      → emit file_open / app_reopen outbound messages
//
// 5. Chromium process termination
//      → NSApplication.shared.terminate(nil)  [if --autoexit in argv]

import AppKit
import nacreLib

final class AppDelegate: NSObject, NSApplicationDelegate, MenuActionReceiver {

    // MARK: – Owned objects

    private let launcher = ProcessLauncher()
    private var server:   SocketServer?
    private var menuBar:  NSMenu?

    // MARK: – NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {

        // 1. Default menu — displayed until Node.js sends set_menu
        installDefaultMenu()

        // 2. Start socket server
        let socketPath = SocketPathHelper.defaultPath()
        let srv = SocketServer(
            socketPath:    socketPath,
            callbackQueue: DispatchQueue.main   // NSMenu mutations on main thread
        )
        srv.onMessage    = { [weak self] msg in self?.handle(message: msg) }
        srv.onDisconnect = { [weak self] in self?.handleDisconnect() }
        srv.onError      = { err in
            NSLog("[nacre] socket error: %@", err.localizedDescription)
        }
        do {
            try srv.start()
            NSLog("[nacre] socket server listening at %@", socketPath)
        } catch {
            NSLog("[nacre] failed to start socket server: %@", error.localizedDescription)
        }
        server = srv

        // 3. Launch Chromium
        guard let chromiumPath = launcher.resolveChromiumPath() else {
            NSLog("[nacre] Chromium binary not found at expected relative path")
            showChromiumNotFoundAlert()
            return
        }
        launcher.onTermination = { [weak self] code in
            self?.handleChromiumExit(code: code)
        }
        do {
            try launcher.launch(chromiumPath: chromiumPath,
                                argv: CommandLine.arguments)
            NSLog("[nacre] launched Chromium at %@", chromiumPath)
        } catch {
            NSLog("[nacre] failed to launch Chromium: %@", error.localizedDescription)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        launcher.terminate()
        server?.stop()
    }

    // File open requests from macOS (Finder, registered UTIs, drag-to-Dock)
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        server?.send(.fileOpen(paths: filenames))
        sender.reply(toOpenOrPrint: .success)
    }

    // Dock icon clicked while already running
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        server?.send(.appReopen)
        return false   // we don't manage windows; Chromium does
    }

    // MARK: – MenuActionReceiver

    @objc public func menuItemActivated(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        server?.send(.menuAction(id: id))
    }

    // MARK: – Socket message handling

    private func handle(message: InboundMessage) {
        switch message {

        case .setMenu(let descriptors):
            let errors = MenuBuilder.validateDescriptors(descriptors)
            if !errors.isEmpty {
                NSLog("[nacre] set_menu validation warnings: %@", errors.joined(separator: "; "))
            }
            let bar = MenuBuilder.buildMenuBar(from: descriptors, target: self)
            NSApplication.shared.mainMenu = bar
            menuBar = bar

        case .patchMenu(let patches):
            guard let bar = menuBar else {
                NSLog("[nacre] patch_menu received before set_menu — ignored")
                return
            }
            let missing = MenuBuilder.applyPatches(patches, to: bar)
            if !missing.isEmpty {
                NSLog("[nacre] patch_menu: IDs not found: %@", missing.joined(separator: ", "))
            }
        }
    }

    private func handleDisconnect() {
        NSLog("[nacre] Node.js disconnected")
        // Restore default menu so the app is not left menu-less
        installDefaultMenu()
    }

    // MARK: – Chromium lifecycle

    private func handleChromiumExit(code: Int32) {
        NSLog("[nacre] Chromium exited with code %d", code)
        // --autoexit: terminate the shim when Chromium exits
        if CommandLine.arguments.contains("--autoexit") {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: – Default menu

    /// A minimal menu shown before Node.js sends set_menu.
    /// Provides Quit and standard Edit commands so the app is not broken.
    private func installDefaultMenu() {
        let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "App"

        let bar = NSMenu(title: "MainMenu")

        // App menu
        let appItem = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: appName)
        appMenu.autoenablesItems = false
        let quitItem = NSMenuItem(
            title: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        bar.addItem(appItem)

        // Edit menu (needed for standard text field behaviour in Chromium)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.autoenablesItems = true
        for (title, sel, key) in [
            ("Undo",  #selector(UndoManager.undo),  "z"),
            ("Redo",  #selector(UndoManager.redo),  "Z"),
            ("Cut",   #selector(NSText.cut(_:)),    "x"),
            ("Copy",  #selector(NSText.copy(_:)),   "c"),
            ("Paste", #selector(NSText.paste(_:)),  "v"),
        ] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            item.keyEquivalentModifierMask = .command
            editMenu.addItem(item)
        }
        editItem.submenu = editMenu
        bar.addItem(editItem)

        NSApplication.shared.mainMenu = bar
        menuBar = nil   // mark as "not yet set by Node.js"
    }

    // MARK: – Alerts

    private func showChromiumNotFoundAlert() {
        let alert             = NSAlert()
        alert.messageText     = "Chromium not found"
        alert.informativeText = "The embedded browser binary could not be located. "
            + "Please reinstall the application."
        alert.alertStyle      = .critical
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }
}
