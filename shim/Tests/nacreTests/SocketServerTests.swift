// SocketServerTests.swift
// nacreTests
//
// Tests for SocketServer framing and message dispatch.
// MockSocketIO replaces all POSIX calls so no real sockets are opened.
//
// The threading model: SocketServer runs its accept/read loops on a private
// DispatchQueue.  Our mock uses a pipe to synchronise "data available" events
// so tests can feed data and then wait for callbacks on the main queue.

import XCTest
@testable import nacreLib

// ── MockSocketIO ──────────────────────────────────────────────────────────────
//
// Simulates a single client connection backed by in-memory buffers.
//
// How it works:
//  • createAndBind / listen / accept are instant no-ops that return fake fds.
//  • read() blocks on a DispatchSemaphore until `feed(data:)` is called.
//  • write() appends to `sentData` and signals a semaphore.
//  • The fake fds are just constants (server=1, client=2).

final class MockSocketIO: SocketIO {

    // Data queued for the server to read
    private var inboundChunks:  [Data] = []
    private let inboundLock   = NSLock()
    private let dataAvailable = DispatchSemaphore(value: 0)

    // Data the server has written back to the client
    private(set) var sentFrames: [Data] = []
    private let sentLock        = NSLock()

    var isClosed  = false
    var isUnlinked = false

    private static let serverFd: Int32 = 1
    private static let clientFd: Int32 = 2

    // ── Feed helpers (called by test code) ───────────────────────────────

    /// Feed a raw Data chunk; the server's read() will return it.
    func feed(data: Data) {
        inboundLock.lock()
        inboundChunks.append(data)
        inboundLock.unlock()
        dataAvailable.signal()
    }

    /// Feed a newline-terminated JSON string.
    func feedJSON(_ json: String) {
        let raw = (json + "\n").data(using: .utf8)!
        feed(data: raw)
    }

    /// Signal EOF (empty read) to terminate the read loop.
    func feedEOF() {
        inboundLock.lock()
        inboundChunks.append(Data())  // empty = EOF
        inboundLock.unlock()
        dataAvailable.signal()
    }

    // ── SocketIO protocol ─────────────────────────────────────────────────

    func createAndBind(path: String) throws -> Int32 { Self.serverFd }
    func listen(fd: Int32) throws {}

    func accept(serverFd: Int32) throws -> Int32 {
        // Block until at least one chunk is available (simulates blocking accept)
        // We just return the client fd immediately; data arrives via read().
        return Self.clientFd
    }

    func read(fd: Int32, maxBytes: Int) throws -> Data {
        dataAvailable.wait()
        inboundLock.lock()
        defer { inboundLock.unlock() }
        guard !inboundChunks.isEmpty else { return Data() }
        return inboundChunks.removeFirst()
    }

    func write(fd: Int32, data: Data) throws {
        sentLock.lock()
        defer { sentLock.unlock() }
        // Each write call is one frame; split on newline for convenience
        sentFrames.append(data)
    }

    func close(fd: Int32) { isClosed = true }
    func unlink(path: String) { isUnlinked = true }
}

// ── SocketServerTests ─────────────────────────────────────────────────────────

final class SocketServerTests: XCTestCase {

    // ── Helpers ───────────────────────────────────────────────────────────

    /// Build a SocketServer backed by a MockSocketIO, already started.
    /// Callbacks are delivered on `DispatchQueue.main` for determinism.
    private func makeServer(
        mock: MockSocketIO = MockSocketIO()
    ) throws -> (SocketServer, MockSocketIO) {
        let server = SocketServer(
            socketPath:    "/tmp/nacre-test.sock",
            io:            mock,
            callbackQueue: DispatchQueue.main
        )
        try server.start()
        // Give the accept loop a moment to park in accept()
        Thread.sleep(forTimeInterval: 0.05)
        return (server, mock)
    }

    // ── Message dispatch ──────────────────────────────────────────────────

    func test_set_menu_message_is_dispatched() throws {
        let (server, mock) = try makeServer()
        defer { server.stop() }

        let exp = XCTestExpectation(description: "set_menu dispatched")
        var received: InboundMessage?

        server.onMessage = { msg in
            received = msg
            exp.fulfill()
        }

        mock.feedJSON("""
        {"type":"set_menu","menus":[{"label":"File","items":[]}]}
        """)

        wait(for: [exp], timeout: 2.0)

        guard case .setMenu(let menus) = received else {
            return XCTFail("Expected .setMenu, got \(String(describing: received))")
        }
        XCTAssertEqual(menus.count, 1)
        XCTAssertEqual(menus[0].label, "File")
    }

    func test_patch_menu_message_is_dispatched() throws {
        let (server, mock) = try makeServer()
        defer { server.stop() }

        let exp = XCTestExpectation(description: "patch_menu dispatched")
        var received: InboundMessage?

        server.onMessage = { msg in
            received = msg
            exp.fulfill()
        }

        mock.feedJSON("""
        {"type":"patch_menu","patches":[{"id":"file.save","enabled":false}]}
        """)

        wait(for: [exp], timeout: 2.0)

        guard case .patchMenu(let patches) = received else {
            return XCTFail("Expected .patchMenu, got \(String(describing: received))")
        }
        XCTAssertEqual(patches.count, 1)
        XCTAssertEqual(patches[0].id, "file.save")
    }

    func test_malformed_json_calls_onError_not_onMessage() throws {
        let (server, mock) = try makeServer()
        defer { server.stop() }

        let exp = XCTestExpectation(description: "error callback")
        var errorFired   = false
        var messageFired = false

        server.onError   = { _ in errorFired = true; exp.fulfill() }
        server.onMessage = { _ in messageFired = true }

        mock.feedJSON("this is not json at all {{{")

        wait(for: [exp], timeout: 2.0)
        XCTAssertTrue(errorFired)
        XCTAssertFalse(messageFired)
    }

    func test_multiple_frames_in_one_chunk() throws {
        let (server, mock) = try makeServer()
        defer { server.stop() }

        let exp = XCTestExpectation(description: "two messages")
        exp.expectedFulfillmentCount = 2
        var messages: [InboundMessage] = []

        server.onMessage = { msg in
            messages.append(msg)
            exp.fulfill()
        }

        // Two newline-delimited JSON frames in one Data chunk
        let combined = """
        {"type":"set_menu","menus":[{"label":"File","items":[]}]}
        {"type":"patch_menu","patches":[{"id":"x","enabled":true}]}
        """.data(using: .utf8)!

        mock.feed(data: combined)

        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(messages.count, 2)
    }

    // ── Disconnect ────────────────────────────────────────────────────────

    func test_eof_triggers_onDisconnect() throws {
        let (server, mock) = try makeServer()
        defer { server.stop() }

        let exp = XCTestExpectation(description: "disconnect")
        server.onDisconnect = { exp.fulfill() }

        mock.feedEOF()

        wait(for: [exp], timeout: 2.0)
    }

    // ── Sending ───────────────────────────────────────────────────────────

    func test_send_menuAction_encodes_newline_terminated_json() throws {
        let (server, mock) = try makeServer()
        defer { server.stop() }

        // Give the server a clientFd by feeding then draining a message
        mock.feedJSON("""
        {"type":"set_menu","menus":[{"label":"X","items":[]}]}
        """)
        let msgExp = XCTestExpectation(description: "msg received before send test")
        server.onMessage = { _ in msgExp.fulfill() }
        wait(for: [msgExp], timeout: 2.0)

        server.send(.menuAction(id: "file.new"))
        Thread.sleep(forTimeInterval: 0.05)

        let frame = mock.sentFrames.last
        XCTAssertNotNil(frame)

        // Must end with newline
        XCTAssertEqual(frame?.last, 0x0A, "Frame must be newline-terminated")

        // Must be valid JSON containing the right type and id
        let json = try JSONSerialization.jsonObject(
            with: frame!.dropLast()
        ) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "menu_action")
        XCTAssertEqual(json["id"]   as? String, "file.new")
    }

    func test_send_before_client_connects_does_not_crash() throws {
        let mock   = MockSocketIO()
        let server = SocketServer(socketPath: "/tmp/nacre-test.sock", io: mock)
        try server.start()
        defer { server.stop() }

        // No client connected yet (accept is blocking waiting for signal)
        // send() should silently no-op
        server.send(.appReopen)
    }

    // ── Cleanup ───────────────────────────────────────────────────────────

    func test_stop_unlinks_socket_file() throws {
        let mock   = MockSocketIO()
        let server = SocketServer(socketPath: "/tmp/nacre-test.sock", io: mock)
        try server.start()
        server.stop()
        XCTAssertTrue(mock.isUnlinked)
    }
}
