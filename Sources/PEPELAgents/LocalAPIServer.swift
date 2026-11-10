import Darwin
import Foundation
import PEPELCore

/// Wire format: one JSON object per line in each direction.
/// Request  `{"token": "…", "op": "lease.acquire", "args": {"owner": "…", "path": "…"}}`
/// Response `{"ok": true, "result": …}` or `{"ok": false, "error": "…"}`
enum Wire {
    static let maxRequestBytes = 64 * 1024

    static func makeAddress(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= capacity else { return nil }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for (index, byte) in bytes.enumerated() { destination[index] = byte }
            }
        }
        return address
    }

    static func readLine(_ fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= maxRequestBytes {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
            if buffer[0..<count].contains(0x0A) { break }
        }
        guard !data.isEmpty, data.count <= maxRequestBytes else { return nil }
        return data.prefix { $0 != 0x0A }
    }

    static func write(_ fd: Int32, _ data: Data) {
        var payload = data
        payload.append(0x0A)
        payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    static func failure(_ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": message])) ?? Data()
    }

    static func success(_ result: Data) -> Data {
        var data = Data(#"{"ok":true,"result":"#.utf8)
        data.append(result)
        data.append(Data("}".utf8))
        return data
    }
}

public enum APIToken {
    /// Reads the token, creating it (owner-only) on first use.
    public static func loadOrCreate(at path: String) throws -> String {
        if let existing = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), existing.count >= 32 {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw APIError("cannot generate a token") }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw APIError("cannot write the token file") }
        defer { close(fd) }
        fchmod(fd, 0o600)
        Wire.write(fd, Data(token.utf8))
        return token
    }

    static func matches(_ candidate: String, _ token: String) -> Bool {
        let a = Array(candidate.utf8), b = Array(token.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }
}

/// Unix-domain socket server for the agent API. Access requires three things: filesystem
/// permission to the owner-only socket, the same user id as PEPEL, and the bearer token.
public final class LocalAPIServer: @unchecked Sendable {
    private let socketPath: String
    private let token: String
    private let service: AgentAPIService
    private let lock = NSLock()
    private var listener: Int32 = -1

    public init(socketPath: String, token: String, service: AgentAPIService) {
        self.socketPath = socketPath
        self.token = token
        self.service = service
    }

    deinit { stop() }

    public func start() throws {
        guard var address = Wire.makeAddress(socketPath) else { throw APIError("socket path is too long") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw APIError("cannot create a socket") }
        unlink(socketPath)
        // The process umask is deliberately left alone: changing it would affect every other
        // thread for a moment. The socket sits in PEPEL's owner-only support directory and is
        // restricted to its owner before the server starts listening.
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(socketPath, 0o600) == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw APIError("cannot listen on \(socketPath): \(String(cString: strerror(errno)))")
        }
        lock.lock()
        listener = fd
        lock.unlock()
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "pepel.agent-api"
        thread.qualityOfService = .utility
        thread.start()
    }

    public func stop() {
        lock.lock()
        let fd = listener
        listener = -1
        lock.unlock()
        guard fd >= 0 else { return }
        close(fd)
        unlink(socketPath)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let service = service
            let token = token
            Task.detached(priority: .utility) {
                let response = await Self.respond(client: client, token: token, service: service)
                Wire.write(client, response)
                close(client)
            }
        }
    }

    private static func respond(client: Int32, token: String, service: AgentAPIService) async -> Data {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return Wire.failure("forbidden") }
        guard let line = Wire.readLine(client),
            let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        else { return Wire.failure("malformed request") }
        guard let candidate = object["token"] as? String, APIToken.matches(candidate, token) else { return Wire.failure("unauthorized") }
        guard let op = object["op"] as? String else { return Wire.failure("missing 'op'") }
        var args: [String: String] = [:]
        for (key, value) in (object["args"] as? [String: Any]) ?? [:] {
            if let text = value as? String { args[key] = text } else if let number = value as? NSNumber { args[key] = number.stringValue }
        }
        do {
            return Wire.success(try await service.handle(op: op, args: args))
        } catch {
            return Wire.failure(String(describing: error))
        }
    }
}

public struct LocalAPIClient: Sendable {
    public let socketPath: String
    public let token: String

    public init(socketPath: String, token: String) {
        self.socketPath = socketPath
        self.token = token
    }

    /// Returns the raw JSON `result`, or throws with the server's error. Throws `APIError("unreachable")`
    /// when no server is listening.
    public func send(op: String, args: [String: String] = [:]) throws -> Data {
        guard var address = Wire.makeAddress(socketPath) else { throw APIError("socket path is too long") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw APIError("unreachable") }
        defer { close(fd) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw APIError("unreachable") }
        var timeout = timeval(tv_sec: 120, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let request = try JSONSerialization.data(withJSONObject: ["token": token, "op": op, "args": args])
        Wire.write(fd, request)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw APIError("malformed response") }
        guard object["ok"] as? Bool == true else { throw APIError(object["error"] as? String ?? "request failed") }
        return try JSONSerialization.data(withJSONObject: object["result"] ?? [:], options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys])
    }
}
