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

    /// 装着的后台服务和 App 里带的这份是不是同一个二进制。
    ///
    /// 改了 helper 的参数却还在跑旧进程，新参数会被**静默忽略**——2026-10-25 就差点
    /// 这样把用户的「用电池 2 分钟关屏」永久改成「永不关屏」：App 以为自己在按电源
    /// 分开还原，旧 helper 只管 `-a`。
    ///
    /// helper 以 root 运行，只能请用户重新授权一次才能换掉，所以这个判断必须准。
    /// 比对的是文件内容（`swift build` 对同一份源码是确定的，实测两次构建哈希一致），
    /// 不是签名——ad-hoc 签名每次打包都会变。
    public func isStale(bundledBinary: URL?, installedPath: String = HelperPaths.binaryPath) -> Bool {
        guard let bundledBinary else { return false }
        guard let installed = try? Data(contentsOf: URL(fileURLWithPath: installedPath)),
              let bundled = try? Data(contentsOf: bundledBinary) else {
            return false
        }
        return installed != bundled
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
