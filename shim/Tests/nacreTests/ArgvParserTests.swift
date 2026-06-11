// ArgvParserTests.swift
// nacreTests

import XCTest
@testable import nacreLib

final class ArgvParserTests: XCTestCase {

    // ── --app= ────────────────────────────────────────────────────────────

    func test_app_url_is_parsed() {
        let args = ArgvParser.parse(["/bin/nacre", "--app=http://127.0.0.1:3000"])
        XCTAssertEqual(args.appURL, "http://127.0.0.1:3000")
    }

    func test_app_url_with_path() {
        let args = ArgvParser.parse(["--app=http://localhost:8080/index.html"])
        XCTAssertEqual(args.appURL, "http://localhost:8080/index.html")
    }

    func test_no_app_url_gives_nil() {
        let args = ArgvParser.parse(["/bin/nacre", "--no-first-run"])
        XCTAssertNil(args.appURL)
    }

    // ── --window-size= ────────────────────────────────────────────────────

    func test_window_size_parsed() {
        let args = ArgvParser.parse(["--window-size=1280,800"])
        XCTAssertEqual(args.windowWidth,  1280)
        XCTAssertEqual(args.windowHeight, 800)
    }

    func test_window_size_with_spaces_around_comma() {
        let args = ArgvParser.parse(["--window-size=1024, 768"])
        XCTAssertEqual(args.windowWidth,  1024)
        XCTAssertEqual(args.windowHeight, 768)
    }

    func test_window_size_fractional() {
        let args = ArgvParser.parse(["--window-size=1366.5,768.0"])
        XCTAssertEqual(args.windowWidth,  1366.5)
        XCTAssertEqual(args.windowHeight, 768.0)
    }

    func test_window_size_invalid_goes_to_ignored() {
        let args = ArgvParser.parse(["--window-size=abc,def"])
        XCTAssertNil(args.windowWidth)
        XCTAssertNil(args.windowHeight)
        XCTAssertTrue(args.ignored.contains("--window-size=abc,def"))
    }

    func test_window_size_missing_height_goes_to_ignored() {
        let args = ArgvParser.parse(["--window-size=1280"])
        XCTAssertNil(args.windowWidth)
        XCTAssertTrue(args.ignored.contains("--window-size=1280"))
    }

    // ── --window-position= ───────────────────────────────────────────────

    func test_window_position_parsed() {
        let args = ArgvParser.parse(["--window-position=100,200"])
        XCTAssertEqual(args.windowX, 100)
        XCTAssertEqual(args.windowY, 200)
    }

    func test_window_position_invalid_goes_to_ignored() {
        let args = ArgvParser.parse(["--window-position=left,top"])
        XCTAssertNil(args.windowX)
        XCTAssertNil(args.windowY)
        XCTAssertTrue(args.ignored.contains("--window-position=left,top"))
    }

    // ── --nacre-socket= ───────────────────────────────────────────────────

    func test_nacre_socket_parsed() {
        let args = ArgvParser.parse(["--nacre-socket=/tmp/com.example.app/menu.sock"])
        XCTAssertEqual(args.nacreSocket, "/tmp/com.example.app/menu.sock")
    }

    func test_nacre_socket_with_spaces_in_path() {
        let args = ArgvParser.parse(["--nacre-socket=/tmp/my app/menu.sock"])
        XCTAssertEqual(args.nacreSocket, "/tmp/my app/menu.sock")
    }

    // ── Known-ignored CfT flags ───────────────────────────────────────────

    func test_no_first_run_is_silently_ignored() {
        let args = ArgvParser.parse(["--no-first-run"])
        XCTAssertTrue(args.ignored.isEmpty)
    }

    func test_no_default_browser_check_is_silently_ignored() {
        let args = ArgvParser.parse(["--no-default-browser-check"])
        XCTAssertTrue(args.ignored.isEmpty)
    }

    func test_disable_extensions_is_silently_ignored() {
        let args = ArgvParser.parse(["--disable-extensions"])
        XCTAssertTrue(args.ignored.isEmpty)
    }

    func test_remote_debugging_port_is_silently_ignored() {
        let args = ArgvParser.parse(["--remote-debugging-port=9222"])
        XCTAssertTrue(args.ignored.isEmpty)
    }

    func test_no_sandbox_is_silently_ignored() {
        let args = ArgvParser.parse(["--no-sandbox"])
        XCTAssertTrue(args.ignored.isEmpty)
    }

    // ── Unknown flags ──────────────────────────────────────────────────────

    func test_unknown_flag_goes_to_ignored() {
        let args = ArgvParser.parse(["--some-future-flag=value"])
        XCTAssertEqual(args.ignored, ["--some-future-flag=value"])
    }

    func test_multiple_unknown_flags_all_collected() {
        let args = ArgvParser.parse(["--flag-a", "--flag-b=x"])
        XCTAssertEqual(args.ignored.sorted(), ["--flag-a", "--flag-b=x"])
    }

    // ── argv[0] stripping ─────────────────────────────────────────────────

    func test_binary_path_argv0_is_dropped() {
        let args = ArgvParser.parse(["/path/to/nacre", "--app=http://localhost:3000"])
        XCTAssertEqual(args.appURL, "http://localhost:3000")
        XCTAssertFalse(args.ignored.contains("/path/to/nacre"))
    }

    func test_flag_as_argv0_is_not_dropped() {
        // If argv[0] starts with "--" it's treated as a flag, not a binary path
        let args = ArgvParser.parse(["--app=http://localhost:3000"])
        XCTAssertEqual(args.appURL, "http://localhost:3000")
    }

    // ── Full realistic argv ───────────────────────────────────────────────

    func test_full_task_primer_argv() {
        // Typical argv task-primer passes to CfT, now received by nacre
        let argv = [
            "/path/to/Sample App 1.app/Contents/MacOS/nacre",
            "--app=http://127.0.0.1:6321",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-extensions",
            "--disable-translate",
            "--disable-infobars",
            "--remote-debugging-port=8120",
            "--window-size=1280,800",
            "--window-position=50,50",
            "--nacre-socket=/tmp/com.example.myapp/menu.sock",
        ]
        let args = ArgvParser.parse(argv)

        XCTAssertEqual(args.appURL,       "http://127.0.0.1:6321")
        XCTAssertEqual(args.windowWidth,  1280)
        XCTAssertEqual(args.windowHeight, 800)
        XCTAssertEqual(args.windowX,      50)
        XCTAssertEqual(args.windowY,      50)
        XCTAssertEqual(args.nacreSocket,  "/tmp/com.example.myapp/menu.sock")
        // All CfT flags silently ignored, nothing in ignored array
        XCTAssertTrue(args.ignored.isEmpty,
                      "Unexpected ignored flags: \(args.ignored)")
    }

    func test_empty_argv_gives_empty_result() {
        let args = ArgvParser.parse([])
        XCTAssertNil(args.appURL)
        XCTAssertNil(args.windowWidth)
        XCTAssertNil(args.nacreSocket)
        XCTAssertTrue(args.ignored.isEmpty)
    }
}
