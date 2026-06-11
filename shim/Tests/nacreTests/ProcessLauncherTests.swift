// ProcessLauncherTests.swift
// nacreTests
//
// Tests for ProcessLauncher — dynamic browser discovery and argv forwarding.

import XCTest
@testable import nacreLib

// ── Mock process handle ───────────────────────────────────────────────────────

final class MockProcessHandle: ProcessHandle {
    var onTermination: ((Int32) -> Void)?
    private(set) var launchCalled     = false
    private(set) var terminateCalled  = false
    var launchError: Error?
    var isRunning: Bool = false

    func launch() throws {
        if let err = launchError { throw err }
        launchCalled = true
        isRunning    = true
    }
    func terminate() { terminateCalled = true; isRunning = false }
    func simulateExit(code: Int32) { isRunning = false; onTermination?(code) }
}

// ── Mock process factory ──────────────────────────────────────────────────────

final class MockProcessFactory: ProcessFactory {
    private(set) var lastExecutablePath: String?
    private(set) var lastArguments:      [String]?
    let handle = MockProcessHandle()

    func makeProcess(executablePath: String, arguments: [String]) -> ProcessHandle {
        lastExecutablePath = executablePath
        lastArguments      = arguments
        return handle
    }
}

// ── Mock filesystem ───────────────────────────────────────────────────────────

final class MockBrowserDiscoveryFS: BrowserDiscoveryFS {
    /// Map of directory path → list of entry names
    var directories: [String: [String]] = [:]
    /// Set of paths that exist as files
    var files: Set<String> = []
    /// Map of plist path → dictionary contents
    var plists: [String: [String: Any]] = [:]

    func contentsOfDirectory(at directory: String) -> [String]? {
        directories[directory]
    }
    func fileExists(at path: String) -> Bool {
        files.contains(path)
    }
    func readPlist(at path: String) -> [String: Any]? {
        plists[path]
    }
}

// ── ProcessLauncherTests ──────────────────────────────────────────────────────

final class ProcessLauncherTests: XCTestCase {

    // ── resolveBrowserPath ────────────────────────────────────────────────

    func test_resolveBrowserPath_finds_standard_chromium() throws {
        let fs = MockBrowserDiscoveryFS()
        // Simulate: Contents/Frameworks/ contains "Chromium.app"
        let frameworksPath = "/App.app/Contents/Frameworks"
        fs.directories[frameworksPath] = ["Chromium.app"]
        let plistPath = "\(frameworksPath)/Chromium.app/Contents/Info.plist"
        fs.plists[plistPath] = ["CFBundleExecutable": "Chromium"]
        let execPath = "\(frameworksPath)/Chromium.app/Contents/MacOS/Chromium"
        fs.files.insert(execPath)

        let launcher = ProcessLauncher(discFS: fs)
        let result   = launcher.resolveBrowserPath(
            shimBinaryPath: "/App.app/Contents/MacOS/nacre"
        )
        XCTAssertEqual(result, execPath)
    }

    func test_resolveBrowserPath_finds_google_chrome_for_testing() throws {
        let fs = MockBrowserDiscoveryFS()
        let frameworksPath = "/Sample App 1.app/Contents/Frameworks"
        let bundleName     = "Google Chrome for Testing.app"
        fs.directories[frameworksPath] = [bundleName]
        let plistPath = "\(frameworksPath)/\(bundleName)/Contents/Info.plist"
        fs.plists[plistPath] = ["CFBundleExecutable": "Google Chrome for Testing"]
        let execPath = "\(frameworksPath)/\(bundleName)/Contents/MacOS/Google Chrome for Testing"
        fs.files.insert(execPath)

        let launcher = ProcessLauncher(discFS: fs)
        let result   = launcher.resolveBrowserPath(
            shimBinaryPath: "/Sample App 1.app/Contents/MacOS/nacre"
        )
        XCTAssertEqual(result, execPath)
    }

    func test_resolveBrowserPath_returns_nil_when_frameworks_empty() {
        let fs = MockBrowserDiscoveryFS()
        fs.directories["/App.app/Contents/Frameworks"] = []  // empty
        let launcher = ProcessLauncher(discFS: fs)
        XCTAssertNil(launcher.resolveBrowserPath(
            shimBinaryPath: "/App.app/Contents/MacOS/nacre"
        ))
    }

    func test_resolveBrowserPath_returns_nil_when_frameworks_missing() {
        let fs       = MockBrowserDiscoveryFS()  // no directories registered
        let launcher = ProcessLauncher(discFS: fs)
        XCTAssertNil(launcher.resolveBrowserPath(
            shimBinaryPath: "/App.app/Contents/MacOS/nacre"
        ))
    }

    func test_resolveBrowserPath_returns_nil_when_plist_missing_executable_key() {
        let fs = MockBrowserDiscoveryFS()
        let frameworksPath = "/App.app/Contents/Frameworks"
        fs.directories[frameworksPath] = ["Chromium.app"]
        let plistPath = "\(frameworksPath)/Chromium.app/Contents/Info.plist"
        fs.plists[plistPath] = [:]  // no CFBundleExecutable
        let launcher = ProcessLauncher(discFS: fs)
        XCTAssertNil(launcher.resolveBrowserPath(
            shimBinaryPath: "/App.app/Contents/MacOS/nacre"
        ))
    }

    func test_resolveBrowserPath_returns_nil_when_executable_file_missing() {
        let fs = MockBrowserDiscoveryFS()
        let frameworksPath = "/App.app/Contents/Frameworks"
        fs.directories[frameworksPath] = ["Chromium.app"]
        let plistPath = "\(frameworksPath)/Chromium.app/Contents/Info.plist"
        fs.plists[plistPath] = ["CFBundleExecutable": "Chromium"]
        // intentionally NOT adding execPath to fs.files
        let launcher = ProcessLauncher(discFS: fs)
        XCTAssertNil(launcher.resolveBrowserPath(
            shimBinaryPath: "/App.app/Contents/MacOS/nacre"
        ))
    }

    func test_resolveBrowserPath_skips_non_app_entries() {
        let fs = MockBrowserDiscoveryFS()
        let frameworksPath = "/App.app/Contents/Frameworks"
        // Mix of non-.app entries and one valid .app
        fs.directories[frameworksPath] = [
            "SomeFramework.framework",
            "libsomething.dylib",
            "Chromium.app",
        ]
        let plistPath = "\(frameworksPath)/Chromium.app/Contents/Info.plist"
        fs.plists[plistPath] = ["CFBundleExecutable": "Chromium"]
        let execPath = "\(frameworksPath)/Chromium.app/Contents/MacOS/Chromium"
        fs.files.insert(execPath)

        let launcher = ProcessLauncher(discFS: fs)
        XCTAssertEqual(
            launcher.resolveBrowserPath(shimBinaryPath: "/App.app/Contents/MacOS/nacre"),
            execPath
        )
    }

    // ── launch ────────────────────────────────────────────────────────────

    func test_launch_forwards_argv_minus_argv0() throws {
        let factory  = MockProcessFactory()
        let launcher = ProcessLauncher(factory: factory)
        let argv     = ["/path/to/nacre", "--app=http://localhost:3000",
                        "--remote-debugging-port=9222", "--autoexit"]
        try launcher.launch(browserPath: "/fake/browser", argv: argv)

        XCTAssertEqual(factory.lastExecutablePath, "/fake/browser")
        XCTAssertEqual(factory.lastArguments, [
            "--app=http://localhost:3000",
            "--remote-debugging-port=9222",
            "--autoexit",
        ])
    }

    func test_launch_with_empty_argv_forwards_nothing() throws {
        let factory  = MockProcessFactory()
        let launcher = ProcessLauncher(factory: factory)
        try launcher.launch(browserPath: "/fake/browser", argv: ["/path/to/nacre"])
        XCTAssertEqual(factory.lastArguments, [])
    }

    func test_launch_makes_process_running() throws {
        let factory  = MockProcessFactory()
        let launcher = ProcessLauncher(factory: factory)
        try launcher.launch(browserPath: "/fake/browser", argv: ["/shim"])
        XCTAssertTrue(launcher.isRunning)
    }

    func test_launch_propagates_factory_error() {
        let factory  = MockProcessFactory()
        factory.handle.launchError = CocoaError(.fileNoSuchFile)
        let launcher = ProcessLauncher(factory: factory)
        XCTAssertThrowsError(
            try launcher.launch(browserPath: "/fake/browser", argv: ["/shim"])
        )
    }

    // ── termination callback ──────────────────────────────────────────────

    func test_termination_callback_receives_exit_code() throws {
        let factory  = MockProcessFactory()
        let launcher = ProcessLauncher(factory: factory)
        let exp      = XCTestExpectation(description: "termination")
        var received: Int32?
        launcher.onTermination = { code in received = code; exp.fulfill() }
        try launcher.launch(browserPath: "/fake/browser", argv: ["/shim"])
        factory.handle.simulateExit(code: 42)
        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(received, 42)
    }

    func test_termination_callback_fires_for_zero_exit() throws {
        let factory  = MockProcessFactory()
        let launcher = ProcessLauncher(factory: factory)
        let exp      = XCTestExpectation(description: "clean exit")
        var received: Int32 = -1
        launcher.onTermination = { code in received = code; exp.fulfill() }
        try launcher.launch(browserPath: "/fake/browser", argv: ["/shim"])
        factory.handle.simulateExit(code: 0)
        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(received, 0)
    }

    // ── terminate ────────────────────────────────────────────────────────

    func test_terminate_calls_through_to_handle() throws {
        let factory  = MockProcessFactory()
        let launcher = ProcessLauncher(factory: factory)
        try launcher.launch(browserPath: "/fake/browser", argv: ["/shim"])
        launcher.terminate()
        XCTAssertTrue(factory.handle.terminateCalled)
    }

    func test_terminate_before_launch_does_not_crash() {
        ProcessLauncher().terminate()
    }
}
