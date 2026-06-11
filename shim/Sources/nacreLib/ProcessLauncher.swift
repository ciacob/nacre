// ProcessLauncher.swift
// nacreLib
//
// Launches and monitors the embedded browser child process.
//
// Discovery strategy
// ──────────────────
// Rather than hardcoding "Chromium.app/Contents/MacOS/Chromium", the launcher
// discovers the browser at runtime by:
//   1. Locating the Frameworks/ directory relative to the running shim binary.
//   2. Finding the first *.app bundle inside Frameworks/.
//   3. Reading that bundle's Info.plist to get CFBundleExecutable.
//   4. Constructing the final executable path from those two pieces.
//
// This works regardless of what the browser bundle is named
// ("Google Chrome for Testing.app", "Chromium.app", etc.).
//
// Testability design
// ──────────────────
// The real spawn and filesystem access are hidden behind injectable protocols.
// Tests supply mocks to exercise argument forwarding and path resolution
// without touching the real filesystem or spawning a real process.

import Foundation

// ── Injectable process factory ────────────────────────────────────────────────

public protocol ProcessFactory {
    func makeProcess(executablePath: String, arguments: [String]) -> ProcessHandle
}

public protocol ProcessHandle: AnyObject {
    var onTermination: ((Int32) -> Void)? { get set }
    func launch() throws
    func terminate()
    var isRunning: Bool { get }
}

// ── Injectable filesystem access ──────────────────────────────────────────────

/// Abstracts the filesystem queries used during browser discovery.
public protocol BrowserDiscoveryFS {
    /// Return names of items directly inside `directory`, or nil on error.
    func contentsOfDirectory(at directory: String) -> [String]?
    /// Return true if a file (not directory) exists at `path`.
    func fileExists(at path: String) -> Bool
    /// Read a plist file and return its top-level dictionary, or nil on error.
    func readPlist(at path: String) -> [String: Any]?
}

// ── Production implementations ────────────────────────────────────────────────

public final class RealProcessFactory: ProcessFactory {
    public init() {}
    public func makeProcess(executablePath: String, arguments: [String]) -> ProcessHandle {
        return RealProcessHandle(executablePath: executablePath, arguments: arguments)
    }
}

final class RealProcessHandle: ProcessHandle {
    var onTermination: ((Int32) -> Void)?
    private let process: Process

    init(executablePath: String, arguments: [String]) {
        process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments     = arguments
    }

    func launch() throws {
        process.terminationHandler = { [weak self] p in
            self?.onTermination?(p.terminationStatus)
        }
        try process.run()
    }

    func terminate() { process.terminate() }
    var isRunning: Bool { process.isRunning }
}

public final class RealBrowserDiscoveryFS: BrowserDiscoveryFS {
    public init() {}

    public func contentsOfDirectory(at directory: String) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: directory)
    }

    public func fileExists(at path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && !isDir.boolValue
    }

    public func readPlist(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        )) as? [String: Any]
    }
}

// ── ProcessLauncher ───────────────────────────────────────────────────────────

public final class ProcessLauncher {

    // MARK: – Callbacks

    /// Called when the child process exits. Delivered on `DispatchQueue.main`.
    public var onTermination: ((Int32) -> Void)?

    // MARK: – Private state

    private let factory:  ProcessFactory
    private let discFS:   BrowserDiscoveryFS
    private var handle:   ProcessHandle?

    // MARK: – Init

    public init(
        factory: ProcessFactory       = RealProcessFactory(),
        discFS:  BrowserDiscoveryFS   = RealBrowserDiscoveryFS()
    ) {
        self.factory = factory
        self.discFS  = discFS
    }

    // MARK: – Browser discovery

    /// Locate the browser executable by inspecting the Frameworks/ directory
    /// next to the running shim binary.
    ///
    /// Algorithm:
    ///   MacOS/nacre → MacOS/ → Contents/ → Frameworks/
    ///   Find first *.app in Frameworks/
    ///   Read its Info.plist → CFBundleExecutable
    ///   Return Frameworks/<bundle>.app/Contents/MacOS/<CFBundleExecutable>
    ///
    /// - Parameter shimBinaryPath: Path to the running shim executable.
    ///                             Defaults to `CommandLine.arguments[0]`.
    /// - Returns: Absolute path to the browser executable, or nil if not found.
    public func resolveBrowserPath(
        shimBinaryPath: String = CommandLine.arguments[0]
    ) -> String? {
        let shimURL      = URL(fileURLWithPath: shimBinaryPath).resolvingSymlinksInPath()
        // MacOS/ → Contents/ → Frameworks/
        let frameworksURL = shimURL
            .deletingLastPathComponent()          // drop "nacre" → MacOS/
            .deletingLastPathComponent()          // drop "MacOS" → Contents/
            .appendingPathComponent("Frameworks")
            .standardized
        let frameworksPath = frameworksURL.path

        // Find the first *.app bundle in Frameworks/
        guard let entries = discFS.contentsOfDirectory(at: frameworksPath) else {
            return nil
        }
        guard let bundleName = entries.first(where: { $0.hasSuffix(".app") }) else {
            return nil
        }

        let bundlePath  = frameworksURL.appendingPathComponent(bundleName).path
        let plistPath   = (bundlePath as NSString)
            .appendingPathComponent("Contents/Info.plist")

        // Read CFBundleExecutable from the browser's own Info.plist
        guard
            let plist      = discFS.readPlist(at: plistPath),
            let execName   = plist["CFBundleExecutable"] as? String
        else {
            return nil
        }

        let execPath = ((bundlePath as NSString)
            .appendingPathComponent("Contents/MacOS") as NSString)
            .appendingPathComponent(execName)

        guard discFS.fileExists(at: execPath) else { return nil }
        return execPath
    }

    // MARK: – Launch

    /// Launch the browser, forwarding `argv[1...]` from the shim.
    public func launch(browserPath: String, argv: [String]) throws {
        let forwarded = Array(argv.dropFirst())
        let proc      = factory.makeProcess(executablePath: browserPath,
                                             arguments: forwarded)
        proc.onTermination = { [weak self] code in
            DispatchQueue.main.async { self?.onTermination?(code) }
        }
        try proc.launch()
        handle = proc
    }

    /// Terminate the child process.
    public func terminate() { handle?.terminate() }

    /// Whether the child process is currently running.
    public var isRunning: Bool { handle?.isRunning ?? false }
}
