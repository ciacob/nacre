// SocketServer.swift
// nacreLib
//
// Unix domain socket server that:
//   • Accepts exactly one client connection at a time (Node.js is the sole client).
//   • Reads newline-delimited JSON frames from the client.
//   • Delivers parsed InboundMessages via a callback.
//   • Writes OutboundMessage JSON frames to the client on demand.
//
// Testability design
// ──────────────────
// All real system calls are behind the `SocketIO` protocol.
// Tests inject a `MockSocketIO` that operates on in-memory buffers.
// The parsing / framing / dispatch logic is therefore fully exercisable
// without opening a real socket.
//
// Threading model
// ───────────────
// `SocketServer` runs its accept/read loop on a private DispatchQueue.
// Callbacks are delivered on that same queue unless the caller specifies
// a `callbackQueue`.  AppDelegate passes `DispatchQueue.main` so all
// NSMenu mutations happen on the main thread.

import Foundation

// ── Injectable I/O protocol ───────────────────────────────────────────────────

/// Abstracts the POSIX socket operations used by SocketServer.
/// The production implementation calls the real syscalls.
/// Tests supply a MockSocketIO.
public protocol SocketIO: AnyObject {
    /// Create and bind a UNIX domain socket at `path`.
    /// Returns a file descriptor, or throws on failure.
    func createAndBind(path: String) throws -> Int32

    /// Start listening on `fd`.
    func listen(fd: Int32) throws

    /// Block until a client connects; return the client fd.
    func accept(serverFd: Int32) throws -> Int32

    /// Read up to `maxBytes` from `fd`.  Returns empty Data on EOF.
    func read(fd: Int32, maxBytes: Int) throws -> Data

    /// Write all of `data` to `fd`.
    func write(fd: Int32, data: Data) throws

    /// Close `fd`.
    func close(fd: Int32)

    /// Remove the socket file at `path` (cleanup on shutdown).
    func unlink(path: String)
}

// ── Production SocketIO ───────────────────────────────────────────────────────

public final class PosixSocketIO: SocketIO {

    public init() {}

    public func createAndBind(path: String) throws -> Int32 {
        // Remove stale socket file if present
        Foundation.unlink(path)

        // Ensure the parent directory exists — required when the socket path
        // is supplied via --nacre-socket rather than derived from SocketPathHelper.
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try? FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true
            )
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket()", errno) }

        var addr          = sockaddr_un()
        addr.sun_family   = sa_family_t(AF_UNIX)

        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw SocketError.pathTooLong(path)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            pathBytes.withUnsafeBytes { src in
                ptr.copyMemory(from: src)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw SocketError.system("bind()", errno)
        }
        return fd
    }

    public func listen(fd: Int32) throws {
        guard Darwin.listen(fd, 1) == 0 else {
            throw SocketError.system("listen()", errno)
        }
    }

    public func accept(serverFd: Int32) throws -> Int32 {
        let clientFd = Darwin.accept(serverFd, nil, nil)
        guard clientFd >= 0 else { throw SocketError.system("accept()", errno) }
        return clientFd
    }

    public func read(fd: Int32, maxBytes: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        let n = Darwin.read(fd, &buffer, maxBytes)
        if n < 0  { throw SocketError.system("read()", errno) }
        return Data(buffer.prefix(n))
    }

    public func write(fd: Int32, data: Data) throws {
        var remaining = data
        while !remaining.isEmpty {
            let n = remaining.withUnsafeBytes { ptr in
                Darwin.write(fd, ptr.baseAddress!, ptr.count)
            }
            if n < 0 { throw SocketError.system("write()", errno) }
            remaining = remaining.dropFirst(n)
        }
    }

    public func close(fd: Int32) { Darwin.close(fd) }

    public func unlink(path: String) { Foundation.unlink(path) }
}

// ── Errors ────────────────────────────────────────────────────────────────────

public enum SocketError: Error, Equatable {
    case system(String, Int32)      // syscall name + errno
    case pathTooLong(String)
    case encodingFailure
    case closed
}

// ── SocketServer ──────────────────────────────────────────────────────────────

public final class SocketServer {

    // MARK: – Configuration

    /// Path to the Unix domain socket file.
    public let socketPath: String

    // MARK: – Callbacks

    /// Called on `callbackQueue` when a well-formed InboundMessage arrives.
    public var onMessage: ((InboundMessage) -> Void)?

    /// Called on `callbackQueue` when the client disconnects.
    public var onDisconnect: (() -> Void)?

    /// Called on `callbackQueue` when a non-fatal error occurs (e.g. bad JSON).
    public var onError: ((Error) -> Void)?

    // MARK: – Private state

    private let io:            SocketIO
    private let workerQueue:   DispatchQueue
    private let callbackQueue: DispatchQueue
    private let decoder =      JSONDecoder()
    private let encoder =      JSONEncoder()

    private var serverFd: Int32 = -1
    private var clientFd: Int32 = -1
    private var running  = false

    // MARK: – Init

    /// - Parameters:
    ///   - socketPath:    Path for the Unix domain socket.
    ///   - io:            Injectable I/O provider.  Production code passes
    ///                    `PosixSocketIO()`; tests pass a mock.
    ///   - callbackQueue: Queue on which `onMessage` / `onError` are called.
    ///                    Defaults to a private background queue.
    public init(
        socketPath:    String,
        io:            SocketIO        = PosixSocketIO(),
        callbackQueue: DispatchQueue   = DispatchQueue(label: "nacre.socket.callbacks")
    ) {
        self.socketPath    = socketPath
        self.io            = io
        self.callbackQueue = callbackQueue
        self.workerQueue   = DispatchQueue(label: "nacre.socket.worker")
    }

    // MARK: – Lifecycle

    /// Start listening and accepting connections asynchronously.
    public func start() throws {
        serverFd = try io.createAndBind(path: socketPath)
        try io.listen(fd: serverFd)
        running = true
        workerQueue.async { [weak self] in self?.acceptLoop() }
    }

    /// Stop the server, close all file descriptors, remove the socket file.
    public func stop() {
        running = false
        if clientFd >= 0 { io.close(fd: clientFd); clientFd = -1 }
        if serverFd >= 0 { io.close(fd: serverFd); serverFd = -1 }
        io.unlink(path: socketPath)
    }

    // MARK: – Sending

    /// Encode an OutboundMessage as a newline-terminated JSON frame and send it.
    /// Safe to call from any thread.
    public func send(_ message: OutboundMessage) {
        guard clientFd >= 0 else { return }
        do {
            var data = try encoder.encode(message)
            data.append(0x0A) // newline delimiter
            try io.write(fd: clientFd, data: data)
        } catch {
            callbackQueue.async { [weak self] in self?.onError?(error) }
        }
    }

    // MARK: – Private

    private func acceptLoop() {
        while running {
            guard let fd = try? io.accept(serverFd: serverFd) else { break }
            clientFd = fd
            readLoop(clientFd: fd)
            io.close(fd: fd)
            clientFd = -1
            callbackQueue.async { [weak self] in self?.onDisconnect?() }
        }
    }

    private func readLoop(clientFd: Int32) {
        var buffer = Data()
        while running {
            guard let chunk = try? io.read(fd: clientFd, maxBytes: 4096),
                  !chunk.isEmpty else { break }
            buffer.append(chunk)
            // Process all complete newline-delimited frames in the buffer
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let frame = buffer[buffer.startIndex ..< newlineIndex]
                buffer    = buffer[buffer.index(after: newlineIndex)...]
                dispatch(frame: frame)
            }
        }
    }

    private func dispatch(frame: Data) {
        do {
            let message = try decoder.decode(InboundMessage.self, from: frame)
            callbackQueue.async { [weak self] in self?.onMessage?(message) }
        } catch {
            callbackQueue.async { [weak self] in self?.onError?(error) }
        }
    }
}

// ── Convenience: derive socket path from bundle ID ────────────────────────────

public enum SocketPathHelper {

    /// Returns `/tmp/<bundleID>/menu.sock`, creating the directory if needed.
    /// Falls back to `/tmp/nacre/menu.sock` when no bundle ID is available
    /// (e.g. during unit tests).
    public static func defaultPath(bundleID: String? = nil) -> String {
        let id  = bundleID ?? Bundle.main.bundleIdentifier ?? "nacre"
        let dir = "/tmp/\(id)"
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        return "\(dir)/menu.sock"
    }
}
