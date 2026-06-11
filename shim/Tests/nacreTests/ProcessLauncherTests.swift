// ProcessLauncherTests.swift
// nacreTests
//
// Tests for ProcessLauncher.  Uses MockProcessFactory so no real processes
// are spawned and no filesystem paths need to exist.

import XCTest
@testable import nacreLib

// ── Mock process handle ───────────────────────────────────────────────────────

final class MockProcessHandle: ProcessHandle {

    var onTermination: ((Int32) -> Void)?

    private(set) var launchCalled = false
    private(set) var terminateCalled = false
    private(set) var launchError: Error?

    var isRunning: Bool = false

    func launch() throws {
        if let err = launchError { throw err }
        launchCalled = true
        isRunning = true
    }

    func terminate() {
        terminateCalled = true
        isRunning = false
    }

    /// Simulate the child process exiting with `code`.
    func simulateExit(code: Int32) {
        isRunning = false
        onTermination?(code)
    }
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

// ── ProcessLauncherTests ──────────────────────────────────────────────────────

final class ProcessLauncherTests: XCTestCase {

    // ── resolveChromiumPath ───────────────────────────────────────────────

    func test_resolveChromiumPath_returns_nil_for_nonexistent_path() {
        let launcher = ProcessLauncher(
            relativePath: "../Frameworks/Chromium.app/Contents/MacOS/Chromium"
        )
        // Pass a fake shim path; the resolved Chromium path won't exist on disk.
        let result = launcher.resolveChromiumPath(
            shimBinaryPath: "/Applications/FakeApp.app/Contents/MacOS/nacre"
        )
        XCTAssertNil(result, "Should return nil when Chromium binary doesn't exist on disk")
    }

    func test_resolveChromiumPath_constructs_correct_relative_path() {
        // We can't assert the file exists in CI, but we can verify the path
        // arithmetic is correct by using a known directory that does exist.
        //
        // Strategy: use /usr/bin as the "shim directory" and resolve to
        // a known sibling (/usr/lib).  We fabricate a relativePath that
        // traverses from /usr/bin → /usr (via ..) → /usr/lib/nacre-test.
        // Since /usr/lib itself exists, we stop one level up and check the
        // computed string rather than FileManager existence.
        //
        // This tests the path arithmetic without depending on the real bundle.

        let launcher = ProcessLauncher(relativePath: "../lib")
        // /usr/bin/../lib → /usr/lib  (exists on macOS)
        let result = launcher.resolveChromiumPath(shimBinaryPath: "/usr/bin/fake-shim")
        // /usr/lib exists on macOS, so result should be non-nil
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.hasSuffix("lib") == true)
    }

    // ── launch ────────────────────────────────────────────────────────────

    func test_launch_forwards_argv_minus_argv0() throws {
        let factory  = MockProcessFactory()
        let launcher = ProcessLauncher(relativePath: "unused", factory: factory)
        let argv     = ["/path/to/nacre", "--app=http://localhost:3000",
                        "--remote-debugging-port=9222", "--autoexit"]
        try launcher.launch(chromiumPath: "/fake/Chromium", argv: argv)

        XCTAssertEqual(factory.lastExecutablePath, "/fake/Chromium")
        XCTAssertEqual(factory.lastArguments, [
            "--app=http://localhost:3000",
            "--remote-debugging-port=9222",
            "--autoexit"
        ])
    }

    func test_launch_with_empty_argv_forwards_nothing() throws {
        let factory  = MockProcessFactory()
        let launcher = ProcessLauncher(relativePath: "unused", factory: factory)
        try launcher.launch(chromiumPath: "/fake/Chromium", argv: ["/path/to/nacre"])

        XCTAssertEqual(factory.lastArguments, [])
    }

    func test_launch_makes_process_running() throws {
        let factory  = MockProcessFactory()
        let launcher = ProcessLauncher(relativePath: "unused", factory: factory)
        try launcher.launch(chromiumPath: "/fake/Chromium", argv: ["/shim"])

        XCTAssertTrue(launcher.isRunning)
    }

    func test_launch_propagates_factory_error() {
        let factory  = MockProcessFactory()
        factory.handle.launchError = CocoaError(.fileNoSuchFile)
        let launcher = ProcessLauncher(relativePath: "unused", factory: factory)

        XCTAssertThrowsError(
            try launcher.launch(chromiumPath: "/fake/Chromium", argv: ["/shim"])
        )
    }

    // ── termination callback ──────────────────────────────────────────────

    func test_termination_callback_receives_exit_code() throws {
        let factory  = MockProcessFactory()
        let launcher = ProcessLauncher(relativePath: "unused", factory: factory)

        let expectation = XCTestExpectation(description: "termination callback")
        var receivedCode: Int32?

        launcher.onTermination = { code in
            receivedCode = code
            expectation.fulfill()
        }

        try launcher.launch(chromiumPath: "/fake/Chromium", argv: ["/shim"])
        factory.handle.simulateExit(code: 42)

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(receivedCode, 42)
    }

    func test_termination_callback_fires_for_zero_exit() throws {
        let factory  = MockProcessFactory()
        let launcher = ProcessLauncher(relativePath: "unused", factory: factory)

        let expectation = XCTestExpectation(description: "clean exit")
        var receivedCode: Int32 = -1

        launcher.onTermination = { code in
            receivedCode = code
            expectation.fulfill()
        }

        try launcher.launch(chromiumPath: "/fake/Chromium", argv: ["/shim"])
        factory.handle.simulateExit(code: 0)

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(receivedCode, 0)
    }

    // ── terminate ────────────────────────────────────────────────────────

    func test_terminate_calls_through_to_handle() throws {
        let factory  = MockProcessFactory()
        let launcher = ProcessLauncher(relativePath: "unused", factory: factory)
        try launcher.launch(chromiumPath: "/fake/Chromium", argv: ["/shim"])

        launcher.terminate()
        XCTAssertTrue(factory.handle.terminateCalled)
    }

    func test_terminate_before_launch_does_not_crash() {
        let launcher = ProcessLauncher()
        // Should be a no-op, not a crash
        launcher.terminate()
    }
}
