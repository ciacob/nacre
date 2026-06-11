// WindowController.swift
// nacreLib
//
// Creates and owns the NSWindow that hosts the WKWebView.
//
// Window style
// ────────────
// Matches what Chrome for Testing produces in --app= mode:
//   • Standard title bar with traffic lights (close / minimise / zoom)
//   • Title bar shows CFBundleName (set in Info.plist at packaging time)
//   • No tab strip, no address bar
//   • Resizable
//
// Geometry
// ────────
// Initial size and position come from NacreArgs (--window-size / --window-position).
// When not supplied, a sensible default (80 % of the primary screen, centred) is used,
// matching Chrome's own default behaviour.

import AppKit

public final class WindowController: NSObject {

    // MARK: – Public properties

    public private(set) var window: NSWindow!

    // MARK: – Init

    /// - Parameters:
    ///   - args:              Parsed argv — provides optional geometry hints.
    ///   - webViewController: Provides the WKWebView to embed.
    public init(args: NacreArgs, webViewController: WebViewController) {
        super.init()
        buildWindow(args: args, webViewController: webViewController)
    }

    // MARK: – Public API

    /// Make the window visible and bring it to front.
    public func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: – Private

    private func buildWindow(args: NacreArgs, webViewController: WebViewController) {
        let frame = initialFrame(args: args)

        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]

        let win = NSWindow(
            contentRect: frame,
            styleMask:   style,
            backing:     .buffered,
            defer:       false
        )

        // Title from bundle name — matches CfT --app= behaviour
        win.title = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? ""

        // Standard macOS memory management for windows
        win.isReleasedWhenClosed = false

        // Restore position/size between launches (like Chrome remembers)
        win.setFrameAutosaveName("NacreMainWindow")

        // Embed the web view
        let webView = webViewController.webView!
        webView.frame = win.contentView!.bounds
        win.contentView?.addSubview(webView)

        // Wire window delegate for close notification
        win.delegate = webViewController

        self.window = win
    }

    /// Compute the initial window frame from argv geometry hints.
    /// Falls back to 80 % of the primary screen, centred.
    private func initialFrame(args: NacreArgs) -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first

        // Default: 80 % of screen, centred
        let defaultFrame: NSRect = {
            guard let screenFrame = screen?.visibleFrame else {
                return NSRect(x: 100, y: 100, width: 1280, height: 800)
            }
            let w = screenFrame.width  * 0.8
            let h = screenFrame.height * 0.8
            let x = screenFrame.minX + (screenFrame.width  - w) / 2
            let y = screenFrame.minY + (screenFrame.height - h) / 2
            return NSRect(x: x, y: y, width: w, height: h)
        }()

        // Apply --window-size if both dimensions provided
        var frame = defaultFrame
        if let w = args.windowWidth, let h = args.windowHeight {
            frame.size.width  = CGFloat(w)
            frame.size.height = CGFloat(h)
        }

        // Apply --window-position if both coordinates provided.
        // CfT uses top-left origin; macOS uses bottom-left.
        // Convert: macOS_y = screenHeight - cft_y - windowHeight
        if let x = args.windowX, let y = args.windowY {
            let screenHeight = screen?.frame.height ?? 1080
            frame.origin.x = CGFloat(x)
            frame.origin.y = CGFloat(screenHeight) - CGFloat(y) - frame.size.height
        }

        return frame
    }
}
