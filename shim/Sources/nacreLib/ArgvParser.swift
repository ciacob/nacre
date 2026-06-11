// ArgvParser.swift
// nacreLib
//
// Parses a CfT-style argv array into a typed NacreArgs struct.
//
// Design
// ──────
// • Pure function — no side effects, no globals, no Cocoa.
// • Unknown flags are collected in `ignored` rather than causing errors,
//   preserving forward-compatibility when task-primer passes CfT-specific
//   flags that nacre has no equivalent for.
// • nacre-specific flags (--nacre-socket=) are parsed alongside CfT flags
//   so the caller never needs to pre-filter argv.
//
// Supported flags
// ───────────────
//   --app=<url>                 URL to load in WKWebView (required for UI)
//   --window-size=<W>,<H>       Initial window size in CSS pixels
//   --window-position=<X>,<Y>   Initial window position from screen top-left
//   --nacre-socket=<path>       Unix socket path for the nacre protocol
//
// Silently ignored flags (CfT-specific, no nacre equivalent)
// ───────────────────────────────────────────────────────────
//   --remote-debugging-port=*
//   --no-first-run
//   --no-default-browser-check
//   --disable-extensions
//   --disable-translate
//   --disable-infobars
//   --no-sandbox
//   --disable-setuid-sandbox
//   (and any other unrecognised flag)

import Foundation

// ── Parsed result ─────────────────────────────────────────────────────────────

public struct NacreArgs: Equatable {

    /// URL to load in WKWebView, from --app=<url>.
    public var appURL: String?

    /// Initial window width in points, from --window-size=W,H.
    public var windowWidth: Double?

    /// Initial window height in points, from --window-size=W,H.
    public var windowHeight: Double?

    /// Initial window X position in points, from --window-position=X,Y.
    public var windowX: Double?

    /// Initial window Y position in points, from --window-position=X,Y.
    public var windowY: Double?

    /// Unix socket path for the nacre protocol, from --nacre-socket=<path>.
    public var nacreSocket: String?

    /// Flags that were present but not acted upon.
    public var ignored: [String]

    public init(
        appURL:       String? = nil,
        windowWidth:  Double? = nil,
        windowHeight: Double? = nil,
        windowX:      Double? = nil,
        windowY:      Double? = nil,
        nacreSocket:  String? = nil,
        ignored:      [String] = []
    ) {
        self.appURL       = appURL
        self.windowWidth  = windowWidth
        self.windowHeight = windowHeight
        self.windowX      = windowX
        self.windowY      = windowY
        self.nacreSocket  = nacreSocket
        self.ignored      = ignored
    }
}

// ── Parser ────────────────────────────────────────────────────────────────────

public enum ArgvParser {

    // Flags that are known-harmless CfT passthrough — silently dropped,
    // not added to `ignored`. Keeping these out of `ignored` prevents
    // log noise in production.
    private static let knownIgnored: Set<String> = [
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-extensions",
        "--disable-translate",
        "--disable-infobars",
        "--no-sandbox",
        "--disable-setuid-sandbox",
    ]

    private static let knownIgnoredPrefixes: [String] = [
        "--remote-debugging-port=",
    ]

    /// Parse an argv array (including or excluding argv[0]) into a NacreArgs.
    ///
    /// argv[0] is automatically detected and dropped if it looks like a
    /// binary path (does not start with "--").
    ///
    /// - Parameter argv: Raw argument strings, typically CommandLine.arguments.
    /// - Returns: Populated NacreArgs struct.
    public static func parse(_ argv: [String]) -> NacreArgs {
        var result  = NacreArgs()
        var ignored = [String]()

        // Drop argv[0] if it's the binary path
        let args = argv.first.map { $0.hasPrefix("--") ? argv : Array(argv.dropFirst()) }
                   ?? argv

        for arg in args {
            // --app=<url>
            if let url = value(of: "--app=", in: arg) {
                result.appURL = url
                continue
            }

            // --window-size=W,H
            if let pair = value(of: "--window-size=", in: arg) {
                let parts = pair.split(separator: ",", maxSplits: 1)
                if parts.count == 2,
                   let w = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                   let h = Double(parts[1].trimmingCharacters(in: .whitespaces)) {
                    result.windowWidth  = w
                    result.windowHeight = h
                } else {
                    ignored.append(arg)
                }
                continue
            }

            // --window-position=X,Y
            if let pair = value(of: "--window-position=", in: arg) {
                let parts = pair.split(separator: ",", maxSplits: 1)
                if parts.count == 2,
                   let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                   let y = Double(parts[1].trimmingCharacters(in: .whitespaces)) {
                    result.windowX = x
                    result.windowY = y
                } else {
                    ignored.append(arg)
                }
                continue
            }

            // --nacre-socket=<path>
            if let path = value(of: "--nacre-socket=", in: arg) {
                result.nacreSocket = path
                continue
            }

            // Known-ignored exact flags
            if knownIgnored.contains(arg) { continue }

            // Known-ignored prefix flags
            if knownIgnoredPrefixes.contains(where: { arg.hasPrefix($0) }) { continue }

            // Anything else — record for diagnostics
            ignored.append(arg)
        }

        result.ignored = ignored
        return result
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    /// Extract the value after `prefix=` from `arg`, or nil if not matching.
    private static func value(of prefix: String, in arg: String) -> String? {
        guard arg.hasPrefix(prefix) else { return nil }
        let v = String(arg.dropFirst(prefix.count))
        return v.isEmpty ? nil : v
    }
}
