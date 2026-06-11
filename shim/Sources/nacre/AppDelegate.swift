// AppDelegate.swift
// nacre (executable target)
//
// Wires ArgvParser + WindowController + WebViewController + SocketServer
// + MenuBuilder together.
//
// Lifecycle
// ─────────
// 1. applicationDidFinishLaunching
//      a. Parse argv → NacreArgs
//      b. Create WebViewController + WindowController
//      c. Install default menu
//      d. Start SocketServer (path from --nacre-socket or default)
//      e. If --app= URL is already in argv, load it immediately
//      f. Show window
//
// 2. Socket messages (all delivered on main thread)
//      set_menu     → rebuild NSApplication.shared.mainMenu
//      patch_menu   → mutate existing items in place
//      set_url      → load URL in WebViewController
//      set_script   → inject WKUserScript
//      set_devtools → toggle developer tools
//
// 3. Menu item activation → emit menu_action over socket
//
// 4. Window close → emit window_closed over socket
//
// 5. applicationOpenFiles → emit file_open over socket
//
// 6. applicationShouldHandleReopen → emit app_reopen over socket

import AppKit
import nacreLib

final class AppDelegate: NSObject, NSApplicationDelegate, MenuActionReceiver {

    // MARK: – Owned objects

    private var webVC:    WebViewController?
    private var winCtrl:  WindowController?
    private var server:   SocketServer?
    private var menuBar:  NSMenu?
    private var parsedArgs = NacreArgs()

    // MARK: – NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {

        // 1. Parse argv
        parsedArgs = ArgvParser.parse(CommandLine.arguments)
        if !parsedArgs.ignored.isEmpty {
            NSLog("[nacre] ignored argv: %@", parsedArgs.ignored.joined(separator: " "))
        }

        // 2. Create web + window layers
        let wvc = WebViewController()
        wvc.onWindowClosed = { [weak self] in
            self?.handleWindowClosed()
        }
        webVC = wvc

        let wc = WindowController(args: parsedArgs, webViewController: wvc)
        winCtrl = wc

        // 3. Default menu
        installDefaultMenu()

        // 4. Start socket server
        let socketPath = parsedArgs.nacreSocket
            ?? SocketPathHelper.defaultPath()
        let srv = SocketServer(
            socketPath:    socketPath,
            callbackQueue: DispatchQueue.main
        )
        srv.onMessage    = { [weak self] msg in self?.handle(message: msg) }
        srv.onDisconnect = { [weak self] in self?.handleDisconnect() }
        srv.onError      = { err in
            NSLog("[nacre] socket error: %@", err.localizedDescription)
        }
        do {
            try srv.start()
            NSLog("[nacre] socket listening at %@", socketPath)
        } catch {
            NSLog("[nacre] socket start failed: %@", error.localizedDescription)
        }
        server = srv

        // 5. Load URL from --app= if provided (Node.js may also send set_url)
        if let urlString = parsedArgs.appURL {
            wvc.load(urlString: urlString)
        }

        // 6. Show window
        wc.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        server?.send(.fileOpen(paths: filenames))
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        server?.send(.appReopen)
        return false
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
                NSLog("[nacre] set_menu warnings: %@", errors.joined(separator: "; "))
            }
            let bar = MenuBuilder.buildMenuBar(from: descriptors, target: self)
            NSApplication.shared.mainMenu = bar
            menuBar = bar

        case .patchMenu(let patches):
            guard let bar = menuBar else {
                NSLog("[nacre] patch_menu before set_menu — ignored")
                return
            }
            let missing = MenuBuilder.applyPatches(patches, to: bar)
            if !missing.isEmpty {
                NSLog("[nacre] patch_menu: missing IDs: %@",
                      missing.joined(separator: ", "))
            }

        case .setURL(let urlString):
            webVC?.load(urlString: urlString)

        case .setScript(let script):
            webVC?.setUserScript(script)

        case .setDevTools(let enabled):
            webVC?.setDevToolsEnabled(enabled)
        }
    }

    private func handleDisconnect() {
        NSLog("[nacre] Node.js disconnected")
        installDefaultMenu()
    }

    // MARK: – Window close

    private func handleWindowClosed() {
        server?.send(.windowClosed)
    }

    // MARK: – Default menu

    private func installDefaultMenu() {
        let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "App"
        let bar     = NSMenu(title: "MainMenu")

        // App menu
        let appItem = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: appName)
        appMenu.autoenablesItems = false
        let quitItem = NSMenuItem(
            title:          "Quit \(appName)",
            action:         #selector(NSApplication.terminate(_:)),
            keyEquivalent:  "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        bar.addItem(appItem)

        // Edit menu (needed for standard text field behaviour in WKWebView)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.autoenablesItems = true
        for (title, sel, key) in [
            ("Undo",  #selector(UndoManager.undo),  "z"),
            ("Redo",  #selector(UndoManager.redo),  "Z"),
            ("Cut",   #selector(NSText.cut(_:)),    "x"),
            ("Copy",  #selector(NSText.copy(_:)),   "c"),
            ("Paste", #selector(NSText.paste(_:)),  "v"),
        ] as [(String, Selector, String)] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            item.keyEquivalentModifierMask = .command
            editMenu.addItem(item)
        }
        editItem.submenu = editMenu
        bar.addItem(editItem)

        NSApplication.shared.mainMenu = bar
        menuBar = nil
    }
}
