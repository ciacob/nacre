// WebViewController.swift
// nacreLib
//
// Owns the WKWebView and everything directly related to web content:
//   • URL loading
//   • WKUserScript injection (navigation guard, delivered via set_script)
//   • Navigation policy (block foreign-origin navigations as a belt-and-
//     suspenders complement to the JS guard)
//   • window.open() suppression (WKUIDelegate)
//   • Developer tools toggle (WKPreferences.developerExtrasEnabled)
//   • window_closed notification when the view's window is closed
//
// AppDelegate owns this object and wires it to the socket server.

import AppKit
import WebKit

public final class WebViewController: NSObject {

    // MARK: – Public properties

    /// Called on the main thread when the web view's window is closed.
    public var onWindowClosed: (() -> Void)?

    /// The managed web view. Add to a view hierarchy after init.
    public private(set) var webView: WKWebView!

    // MARK: – Private state

    private var configuration:  WKWebViewConfiguration
    private var pendingURL:     URL?
    private var pendingScript:  String?
    private var devToolsEnabled = false

    // MARK: – Init

    public override init() {
        configuration = WKWebViewConfiguration()
        super.init()
        buildWebView()
    }

    // MARK: – Public API

    /// Load a URL. If the web view is not yet in a window, the load is
    /// deferred until viewDidMoveToWindow (not applicable here — call after
    /// the view is in a window, which AppDelegate guarantees).
    public func load(urlString: String) {
        guard let url = URL(string: urlString) else {
            NSLog("[nacre] WebViewController: invalid URL: %@", urlString)
            return
        }
        webView.load(URLRequest(url: url))
    }

    /// Inject a WKUserScript that runs at document start on every navigation.
    /// Replaces any previously injected user script.
    /// Safe to call before or after a URL is loaded — WebKit re-injects on
    /// each new document.
    public func setUserScript(_ source: String) {
        // Remove any existing nacre-injected scripts
        let ctrl = webView.configuration.userContentController
        ctrl.removeAllUserScripts()

        let script = WKUserScript(
            source:            source,
            injectionTime:     .atDocumentStart,
            forMainFrameOnly:  false
        )
        ctrl.addUserScript(script)
    }

    /// Enable or disable the WebKit developer tools (Web Inspector).
    /// Defaults to disabled (production-safe).
    public func setDevToolsEnabled(_ enabled: Bool) {
        devToolsEnabled = enabled
        // developerExtrasEnabled is readable/writable at any time on macOS.
        webView.configuration.preferences.setValue(enabled, forKey: "developerExtrasEnabled")
    }

    // MARK: – Private

    private func buildWebView() {
        // developerExtrasEnabled defaults to false
        configuration.preferences.setValue(false, forKey: "developerExtrasEnabled")

        // Allow inspecting local content served over localhost
        configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate         = self
        webView.allowsBackForwardNavigationGestures = false

        // Fill the containing view
        webView.autoresizingMask = [.width, .height]
    }
}

// MARK: – WKNavigationDelegate

extension WebViewController: WKNavigationDelegate {

    /// Belt-and-suspenders: block foreign-origin navigations at the native
    /// level, complementing the JS guard injected via set_script.
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // Always allow: initial load, same-origin, local
        let scheme = url.scheme ?? ""
        if scheme == "about" || scheme == "blob" {
            decisionHandler(.allow)
            return
        }

        // If we have a loaded URL, enforce same-origin for navigations
        if let currentURL = webView.url ?? webView.url,
           let currentHost = currentURL.host,
           let targetHost  = url.host,
           targetHost != currentHost {
            NSLog("[nacre] Blocked cross-origin navigation to %@", url.absoluteString)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("[nacre] Navigation failed: %@", error.localizedDescription)
    }
}

// MARK: – WKUIDelegate

extension WebViewController: WKUIDelegate {

    /// Block all window.open() calls — returns nil so WebKit discards them.
    /// Mirrors task-primer's CDP target lifecycle management behaviour.
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        NSLog("[nacre] Suppressed window.open() to %@",
              navigationAction.request.url?.absoluteString ?? "(nil)")
        return nil
    }
}

// MARK: – NSWindowDelegate (window close → socket event)

extension WebViewController: NSWindowDelegate {

    public func windowWillClose(_ notification: Notification) {
        NSLog("[nacre] App window closed")
        onWindowClosed?()
    }
}
