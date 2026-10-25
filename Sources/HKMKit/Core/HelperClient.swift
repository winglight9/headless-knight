import Foundation

/// Talks to the root daemon over a newline-delimited JSON unix socket.
public struct HelperClient: Sendable {
    public let socketPath: String
    public let timeout: TimeInterval

    public init(socketPath: String = HelperPaths.socketPath, timeout: TimeInterval = 20) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: HelperPaths.binaryPath)
            && FileManager.default.fileExists(atPath: HelperPaths.plistPath)
    }

    /// 装着的后台服务报上来的协议版本。
    ///
    /// `nil` = 连不上（没法判断）；`1` = 连上了但没报版本（很老的版本）。
    ///
    /// 为什么不用「比对二进制内容」：安装脚本会 `codesign --force --sign -` 重新
    /// 签名，文件大 18KB，字节比对永远不相等，用户就会陷入「装一次、报一次旧版本」
    /// 的死循环。协议版本跟签名无关，才是稳的判据。
    public func reportedProtocolVersion() -> Int? {
        guard let response = try? send(HelperRequest(operation: .ping)), response.ok else {
            return nil
        }
        return HelperClient.parseProtocolVersion(response.output)
    }

    /// `"pong 2"` → 2；`"pong"` → 1（很老的版本，那时候还不报版本号）。
    public static func parseProtocolVersion(_ output: String) -> Int {
        if let last = output.split(separator: " ").last, let version = Int(last) {
            return version
        }
        return 1
    }

    /// 装着的后台服务是不是这一版。
    ///
    /// 连不上、或者问不出答案，都返回 true（不拦人）——那两种情况有各自的报错路径，
    /// 不该在这里冒充「版本旧」。只有**明确问出来版本号偏低**才算过期。
    public func isCurrentVersion() -> Bool {
        guard isReachable() else { return true }
        guard let version = reportedProtocolVersion() else { return true }
        return version >= HelperProtocol.apiVersion
    }

    public func isReachable() -> Bool {
        guard let fd = try? connectSocket() else { return false }
        close(fd)
        return true
    }

    public func send(_ request: HelperRequest) throws -> HelperResponse {
        let fd = try connectSocket()
        defer { close(fd) }

        var receiveTimeout = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

        let encoder = JSONEncoder()
        var payload = try encoder.encode(request)
        payload.append(0x0A)
        try writeAll(fd: fd, data: payload)

        let line = try readLine(fd: fd)
        guard let data = line.data(using: .utf8) else {
            throw HelperError.protocolViolation("响应不是 UTF-8")
        }
        do {
            return try JSONDecoder().decode(HelperResponse.self, from: data)
        } catch {
            throw HelperError.protocolViolation(String(describing: error))
        }
    }

    // MARK: - Socket plumbing

    private func connectSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw HelperError.connectionFailed("socket() 失败：\(String(cString: strerror(errno)))")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            close(fd)
            throw HelperError.connectionFailed("socket 路径过长")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        let result = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            if errno == ENOENT || errno == ECONNREFUSED {
                throw HelperError.notInstalled
            }
            throw HelperError.connectionFailed(message)
        }
        return fd
    }

    private func writeAll(fd: Int32, data: Data) throws {
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer -> Int in
                let base = buffer.baseAddress!.advanced(by: offset)
                return Darwin.write(fd, base, bytes.count - offset)
            }
            if written <= 0 {
                throw HelperError.connectionFailed("写入失败：\(String(cString: strerror(errno)))")
            }
            offset += written
        }
    }

    private func readLine(fd: Int32) throws -> String {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw HelperError.timeout
                }
                throw HelperError.connectionFailed("读取失败：\(String(cString: strerror(errno)))")
            }
            if count == 0 { break }
            for index in 0..<count {
                if chunk[index] == 0x0A {
                    return String(decoding: buffer, as: UTF8.self)
                }
                buffer.append(chunk[index])
            }
            if buffer.count > 1_048_576 {
                throw HelperError.protocolViolation("响应过大")
            }
        }
        guard !buffer.isEmpty else {
            throw HelperError.connectionFailed("连接被关闭")
        }
        return String(decoding: buffer, as: UTF8.self)
    }
}
