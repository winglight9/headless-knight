import Foundation
import HKMKit

/// Root daemon: executes the handful of privileged commands the app needs over a
/// unix socket, and only for the uid that installed it.
final class HelperDaemon {
    private let socketPath: String
    private let allowedUID: uid_t
    private let runner: any CommandRunning = ShellRunner()

    /// 一个连接最多占多久。客户端是连上就写一行 JSON，正常是毫秒级；
    /// 留 5 秒是给「机器刚醒、调度被冻住」那种情况。
    ///
    /// 这个值以前不存在：`read` 是阻塞的，谁连上来不发换行，整个 helper 就
    /// 永远卡在那个连接上（连接是串行处理的），后面所有请求都进不来。
    /// 而进程还活着，`KeepAlive` 也不会重启它 —— 从外面看就是「后台服务在，
    /// 但什么都不做」。
    private static let requestTimeout: TimeInterval = 5

    init(socketPath: String = HelperPaths.socketPath) {
        self.socketPath = socketPath
        self.allowedUID = HelperDaemon.resolveAllowedUID()
    }

    /// Prefer the uid recorded at install time; fall back to whoever owns the
    /// console, which is the user who is actually using the machine.
    private static func resolveAllowedUID() -> uid_t {
        if let text = try? String(contentsOfFile: HelperPaths.allowedUIDPath, encoding: .utf8),
           let value = uid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return value
        }
        var info = stat()
        if stat("/dev/console", &info) == 0 {
            return info.st_uid
        }
        return 0
    }

    func run() -> Never {
        signal(SIGPIPE, SIG_IGN)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            HKMLog.error("socket() 失败：\(String(cString: strerror(errno)))")
            exit(1)
        }

        unlink(socketPath)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            HKMLog.error("socket 路径过长")
            exit(1)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        let bound = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            HKMLog.error("bind() 失败：\(String(cString: strerror(errno)))")
            exit(1)
        }

        // The socket must be connectable by the user, so the uid check below is
        // what actually gates access.
        chmod(socketPath, 0o666)

        guard listen(fd, 8) == 0 else {
            HKMLog.error("listen() 失败：\(String(cString: strerror(errno)))")
            exit(1)
        }
        HKMLog.info("helper 已启动，socket=\(socketPath)，允许 uid=\(allowedUID)")

        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            handle(client: client)
            close(client)
        }
    }

    private func handle(client: Int32) {
        var peerUID = uid_t(0)
        var peerGID = gid_t(0)
        guard getpeereid(client, &peerUID, &peerGID) == 0 else {
            HKMLog.error("getpeereid 失败：\(String(cString: strerror(errno)))")
            return
        }
        guard peerUID == allowedUID || peerUID == 0 else {
            HKMLog.error("拒绝来自 uid \(peerUID) 的连接")
            respond(client: client, response: HelperResponse(id: "", ok: false, errorMessage: "uid 不被允许"))
            return
        }

        // 对端不读响应时，别让 write 把 helper 也堵死。
        var sendTimeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))

        let deadline = Date().addingTimeInterval(HelperDaemon.requestTimeout)
        guard let line = readLine(client: client, deadline: deadline) else {
            HKMLog.error("连接在 \(Int(HelperDaemon.requestTimeout)) 秒内没有发完请求，断开")
            return
        }
        guard let data = line.data(using: .utf8),
              let request = try? JSONDecoder().decode(HelperRequest.self, from: data) else {
            respond(client: client, response: HelperResponse(id: "", ok: false, errorMessage: "无法解析请求"))
            return
        }

        let response = execute(request)
        respond(client: client, response: response)
    }

    private func execute(_ request: HelperRequest) -> HelperResponse {
        switch request.operation {
        case .ping:
            // 带上协议版本：App 靠它判断「装的是不是这一版」。
            return .success(id: request.id, output: "pong \(HelperProtocol.apiVersion)")

        case .pmsetSet:
            guard let key = request.arguments["key"], let value = request.arguments["value"] else {
                return .failure(id: request.id, message: "缺少 key/value")
            }
            guard HelperPolicy.isAllowedPmsetKey(key) else {
                return .failure(id: request.id, message: "不允许修改 \(key)")
            }
            guard HelperPolicy.isAllowedPmsetValue(value) else {
                return .failure(id: request.id, message: "不允许的值 \(value)")
            }
            // `-a` 全部、`-c` 插电、`-b` 电池。默认 a。
            //
            // 之所以要能分开写：`displaysleep` 在两套电源里经常不一样（用户的机器
            // 插电是 0 = 永不关屏，电池是 2）。只用 `-a` 还原，会把电池那套也改成
            // 插电的值，用户下次用电池就再也不关屏了。
            let scope = request.arguments["scope"] ?? "a"
            guard HelperPolicy.isAllowedPmsetScope(scope) else {
                return .failure(id: request.id, message: "不支持的电源类型 \(scope)")
            }
            return run(request.id, "/usr/bin/pmset", ["-\(scope)", key, value])

        case .pmsetSleepNow:
            return run(request.id, "/usr/bin/pmset", ["sleepnow"])

        case .pmsetScheduleCancelAll:
            return run(request.id, "/usr/bin/pmset", ["schedule", "cancelall"])

        case .timeMachineDisable:
            return run(request.id, "/usr/bin/tmutil", ["disable"])

        case .timeMachineEnable:
            return run(request.id, "/usr/bin/tmutil", ["enable"])

        case .launchctlDisable:
            return launchctl(request.id, verb: "disable", label: request.arguments["label"])

        case .launchctlEnable:
            return launchctl(request.id, verb: "enable", label: request.arguments["label"])

        case .launchctlBootout:
            return launchctl(request.id, verb: "bootout", label: request.arguments["label"], ignoreFailure: true)

        case .launchctlBootstrap:
            guard let label = request.arguments["label"] else {
                return .failure(id: request.id, message: "缺少 label")
            }
            // 路径只从白名单里生成，绝不用客户端给的字符串拼——
            // `../../tmp/evil` 会让 launchd 以 root 去 bootstrap 任意 plist。
            guard let plist = HelperPolicy.launchDaemonPlistPath(for: label) else {
                HKMLog.error("拒绝 bootstrap 未授权的服务 \(label)")
                return .failure(id: request.id, message: "不允许操作 \(label)")
            }
            return run(request.id, "/bin/launchctl", ["bootstrap", "system", plist], ignoreFailure: true)

        case .bluetoothSetPower:
            let state = request.arguments["state"] ?? "0"
            let write = run(request.id, "/usr/bin/defaults", [
                "write", "/Library/Preferences/com.apple.Bluetooth", "ControllerPowerState", "-int", state
            ])
            guard write.ok else { return write }
            return run(request.id, "/usr/bin/killall", ["bluetoothd"], ignoreFailure: true)

        case .bluetoothReadPower:
            let result = run(request.id, "/usr/bin/defaults", [
                "read", "/Library/Preferences/com.apple.Bluetooth", "ControllerPowerState"
            ])
            guard result.ok else { return result }
            let value = Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
            return HelperResponse(id: request.id, ok: true, output: result.output, intValue: value)
        }
    }

    /// disable / enable / bootout 共用一条路：label 必须先过白名单。
    ///
    /// 以前这四种操作只检查「参数在不在」，label 是什么都照做。socket 是 0666，
    /// 同一登录用户下任何进程都能连，等于把一个「停/启任意系统服务」的 root
    /// 开关摆在了桌面上。
    private func launchctl(
        _ id: String,
        verb: String,
        label: String?,
        ignoreFailure: Bool = false
    ) -> HelperResponse {
        guard let label else {
            return .failure(id: id, message: "缺少 label")
        }
        guard HelperPolicy.isAllowedLaunchctlLabel(label) else {
            HKMLog.error("拒绝 \(verb) 未授权的服务 \(label)")
            return .failure(id: id, message: "不允许操作 \(label)")
        }
        return run(id, "/bin/launchctl", [verb, "system/\(label)"], ignoreFailure: ignoreFailure)
    }

    private func run(_ id: String, _ executable: String, _ arguments: [String], ignoreFailure: Bool = false) -> HelperResponse {
        do {
            let result = try runner.run(executable, arguments: arguments, timeout: 60)
            let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.succeeded || ignoreFailure {
                return .success(id: id, output: output)
            }
            let message = result.stderr.isEmpty ? output : result.stderr
            HKMLog.error("\(executable) \(arguments.joined(separator: " ")) 失败：\(message)")
            return .failure(id: id, message: message.isEmpty ? "退出码 \(result.status)" : message)
        } catch {
            return .failure(id: id, message: error.localizedDescription)
        }
    }

    private func respond(client: Int32, response: HelperResponse) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer -> Int in
                let base = buffer.baseAddress!.advanced(by: offset)
                return Darwin.write(client, base, bytes.count - offset)
            }
            if written <= 0 { return }
            offset += written
        }
    }

    /// 读到换行为止，最多等到 `deadline`。
    ///
    /// 分片 `poll` 而不是直接阻塞 `read`：截止时间是**绝对**的，客户端一个字节
    /// 一个字节地慢慢发（每片都「有数据」）也拖不过这个时间，不会出现
    /// 「设了 SO_RCVTIMEO 但每读一次就重置」那种假超时。
    private func readLine(client: Int32, deadline: Date) -> String? {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            var descriptor = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            let slice = Int32(max(1, min(remaining, 1) * 1000))
            let ready = poll(&descriptor, 1, slice)
            if ready == 0 { continue }              // 一秒一片，回到上面重新看截止时间
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            let count = read(client, &chunk, chunk.count)
            if count <= 0 { break }
            for index in 0..<count {
                if chunk[index] == 0x0A {
                    return String(decoding: buffer, as: UTF8.self)
                }
                buffer.append(chunk[index])
            }
            if buffer.count > 1_048_576 { return nil }
        }
        return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
    }
}

// 测试时用 `HKM_SOCKET_PATH` 把 socket 挪到 /tmp，免得把正在运行的那个顶掉。
// 装成 launchd 服务时环境变量来自 root 拥有的 plist，普通进程设不了它。
let socketPath = ProcessInfo.processInfo.environment["HKM_SOCKET_PATH"] ?? HelperPaths.socketPath
HelperDaemon(socketPath: socketPath).run()
