import Foundation
import Darwin

/// The desktop owner's IPC protocol uses length-prefixed JSON, not app-server JSONL.
/// Connecting as a follower keeps the existing backend as the sole thread writer.
protocol DesktopConnection: AnyObject {
    func owner(of threadID: String) throws -> String?
    func start(threadID: String, prompt: String, owner: String) throws -> String
    func cancel()
}

final class DesktopIPCClient: DesktopConnection {
    private var fd: Int32 = -1
    private var clientID = "initializing-client"
    private let lock = NSLock()
    private var cancelled = false

    init(path: String = CodexEnvironment.home.appendingPathComponent("ipc/ipc.sock").path) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFSOCK else {
            throw CodexConnectionError.server("Codex 桌面连接不可用")
        }
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw CodexConnectionError.invalidResponse }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CodexConnectionError.ended }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { Darwin.close(fd); fd = -1; throw CodexConnectionError.ended }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        do {
            let response = try request("initialize", params: ["clientType": "codex-keeper"], version: 0)
            guard let result = response["result"] as? [String: Any], let id = result["clientId"] as? String else { throw CodexConnectionError.invalidResponse }
            clientID = id
        } catch { Darwin.close(fd); fd = -1; throw error }
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        shutdown(fd, SHUT_RDWR)
    }

    func owner(of threadID: String) throws -> String? {
        let response = try request("thread-owner-discovery", params: ["hostId": "local", "conversationId": threadID], version: 1)
        if response["resultType"] as? String == "error", response["error"] as? String == "no-client-found" { return nil }
        try check(response)
        guard let owner = response["handledByClientId"] as? String else { throw CodexConnectionError.invalidResponse }
        return owner
    }

    func start(threadID: String, prompt: String, owner: String) throws -> String {
        let response = try request("thread-follower-start-turn", params: ["conversationId": threadID,
            "turnStart": ["request": ["threadId": threadID, "input": [["type": "text", "text": prompt, "text_elements": []]]],
                          "context": ["inheritThreadSettings": true]]], version: 2, target: owner)
        try check(response)
        guard let outer = response["result"] as? [String: Any], let result = outer["result"] as? [String: Any],
              let turn = result["turn"] as? [String: Any], let id = turn["id"] as? String else { throw CodexConnectionError.invalidResponse }
        return id
    }

    private func check(_ response: [String: Any]) throws {
        guard response["resultType"] as? String == "success" else {
            throw CodexConnectionError.server(response["error"] as? String ?? "Codex 桌面请求失败")
        }
    }

    private func request(_ method: String, params: [String: Any], version: Int, target: String? = nil) throws -> [String: Any] {
        let id = UUID().uuidString
        var message: [String: Any] = ["type": "request", "requestId": id, "sourceClientId": clientID,
            "version": version, "method": method, "params": params, "timeoutMs": 15000]
        if let target { message["targetClientId"] = target }
        try write(message)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let header = try read(4, deadline: deadline)
            let size = header.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
            guard size > 0, size <= 8 * 1024 * 1024 else { throw CodexConnectionError.invalidResponse }
            let data = try read(Int(size), deadline: deadline)
            guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CodexConnectionError.invalidResponse }
            if response["type"] as? String == "client-discovery-request", let discoveryID = response["requestId"] {
                try write(["type": "client-discovery-response", "requestId": discoveryID, "response": ["canHandle": false]])
            }
            if response["type"] as? String == "response", response["requestId"] as? String == id { return response }
        }
        throw CodexConnectionError.timeout
    }

    private func write(_ object: [String: Any]) throws {
        let payload = try JSONSerialization.data(withJSONObject: object)
        var length = UInt32(payload.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }; frame.append(payload)
        try frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw CodexConnectionError.ended }
                offset += count
            }
        }
    }

    private func read(_ size: Int, deadline: Date) throws -> Data {
        var data = Data()
        while data.count < size {
            lock.lock(); let stopped = cancelled; lock.unlock()
            guard !stopped else { throw CodexConnectionError.ended }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw CodexConnectionError.timeout }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining * 1000, 1000)))
            if ready < 0, errno == EINTR { continue }
            guard ready >= 0 else { throw CodexConnectionError.ended }
            if ready == 0 { continue }
            var buffer = [UInt8](repeating: 0, count: min(8192, size - data.count))
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { throw CodexConnectionError.ended }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
