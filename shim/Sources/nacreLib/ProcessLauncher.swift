// ProcessLauncher.swift
// nacreLib
//
// Launches and monitors the embedded Chromium child process.
//
// Testability design
// ──────────────────
// The real spawn is hidden behind the `ProcessFactory` protocol.
// Tests inject `MockProcessFactory` to exercise argument forwarding,
// path resolution, and exit-code relay without touching the filesystem
// or spawning a real process.
//
// Responsibilities
// ────────────────
// 1. Locate the embedded Chromium binary relative to the running executable.
// 2. Forward all of the shim's own argv (minus argv[0]) to Chromium.
// 3. Relay Chromium's exit code when it terminates.
// 4. Call a termination handler so AppDelegate can react (autoexit, etc.).

import Foundation

// ── Injectable process factory ────────────────────────────────────────────────

/// Abstracts `Process` creation so tests can substitute a mock.
public protocol ProcessFactory {
    func makeProcess(executablePath: String, arguments: [String]) -> ProcessHandle
}

/// Abstracts the subset of `Process` we actually use.
public protocol ProcessHandle: AnyObject {
    var onTermination: ((Int32) -> Void)? { get set }
    func launch() throws
    func terminate()
    var isRunning: Bool { get }
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

// ── ProcessLauncher ───────────────────────────────────────────────────────────

public final class ProcessLauncher {

    // MARK: – Configuration

    /// Relative path from the shim binary to the embedded Chromium executable.
    /// Default matches the bundle layout produced by the Node.js build script:
    ///
    ///   MyApp.app/Contents/MacOS/nacre          ← shim (this process)
    ///   MyApp.app/Contents/Frameworks/Chromium.app/Contents/MacOS/Chromium
    ///                                           ← target
    public static let defaultChromiumRelativePath =
        "../Frameworks/Chromium.app/Contents/MacOS/Chromium"

    // MARK: – Callbacks

    /// Called when the child process exits.  Receives the exit code.
    /// Delivered on `DispatchQueue.main`.
    public var onTermination: ((Int32) -> Void)?

    // MARK: – Private state

    private let factory:     ProcessFactory
    private var handle:      ProcessHandle?
    private let relativePath: String

    // MARK: – Init

    /// - Parameters:
    ///   - relativePath: Relative path from the shim binary to Chromium.
    ///   - factory:      Injectable process factory.
    public init(
        relativePath: String        = defaultChromiumRelativePath,
        factory:      ProcessFactory = RealProcessFactory()
    ) {
        self.relativePath = relativePath
        self.factory      = factory
    }

    // MARK: – Public API

    /// Resolve the absolute path to the embedded Chromium binary.
    ///
    /// - Parameter shimBinaryPath: Path to the running shim executable.
    ///                             Defaults to `CommandLine.arguments[0]`.
    /// - Returns: Absolute path, or nil if the resolved path does not exist.
    public func resolveChromiumPath(
        shimBinaryPath: String = CommandLine.arguments[0]
    ) -> String? {
        let shimURL    = URL(fileURLWithPath: shimBinaryPath).resolvingSymlinksInPath()
        let chromiumURL = shimURL
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
            .standardized
        let path = chromiumURL.path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    /// Launch the child process, forwarding `argv[1...]` from the shim.
    ///
    /// - Parameters:
    ///   - chromiumPath: Absolute path to the Chromium binary.
    ///   - argv:         Arguments to forward (typically `CommandLine.arguments`).
    ///                   `argv[0]` (the shim path) is dropped automatically.
    /// - Throws: If the process cannot be launched.
    public func launch(chromiumPath: String, argv: [String]) throws {
        let forwarded = Array(argv.dropFirst()) // drop argv[0] (shim path)
        let proc      = factory.makeProcess(executablePath: chromiumPath,
                                             arguments: forwarded)
        proc.onTermination = { [weak self] code in
            DispatchQueue.main.async {
                self?.onTermination?(code)
            }
        }
        try proc.launch()
        handle = proc
    }

    /// Terminate the child process (sends SIGTERM).
    public func terminate() {
        handle?.terminate()
    }

    /// Whether the child process is currently running.
    public var isRunning: Bool {
        handle?.isRunning ?? false
    }
}
