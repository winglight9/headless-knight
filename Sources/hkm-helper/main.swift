import Foundation
import HKMKit

/// Root daemon: executes the handful of privileged commands the app needs over a
/// unix socket, and only for the uid that installed it.
final class HelperDaemon {
    private let socketPath: String
    private let allowedUID: uid_t
    private let runner: any CommandRunning = ShellRunner()

    private static let allowedPmsetKeys: Set<String> = [
        "disablesleep", "sleep", "womp", "powernap", "tcpkeepalive", "standby", "displaysleep", "disksleep"
    ]

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

        guard let line = readLine(client: client) else { return }
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
            return .success(id: request.id, output: "pong")

        case .pmsetSet:
            guard let key = request.arguments["key"], let value = request.arguments["value"] else {
                return .failure(id: request.id, message: "缺少 key/value")
            }
            guard HelperDaemon.allowedPmsetKeys.contains(key) else {
                return .failure(id: request.id, message: "不允许修改 \(key)")
            }
            // `-a` 全部、`-c` 插电、`-b` 电池。默认 a。
            //
            // 之所以要能分开写：`displaysleep` 在两套电源里经常不一样（用户的机器
            // 插电是 0 = 永不关屏，电池是 2）。只用 `-a` 还原，会把电池那套也改成
            // 插电的值，用户下次用电池就再也不关屏了。
            let scope = request.arguments["scope"] ?? "a"
            guard ["a", "c", "b"].contains(scope) else {
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
            guard let label = request.arguments["label"] else {
                return .failure(id: request.id, message: "缺少 label")
            }
            return run(request.id, "/bin/launchctl", ["disable", "system/\(label)"])

        case .launchctlEnable:
            guard let label = request.arguments["label"] else {
                return .failure(id: request.id, message: "缺少 label")
            }
            return run(request.id, "/bin/launchctl", ["enable", "system/\(label)"])

        case .launchctlBootout:
            guard let label = request.arguments["label"] else {
                return .failure(id: request.id, message: "缺少 label")
            }
            return run(request.id, "/bin/launchctl", ["bootout", "system/\(label)"], ignoreFailure: true)

        case .launchctlBootstrap:
            guard let label = request.arguments["label"] else {
                return .failure(id: request.id, message: "缺少 label")
            }
            let plist = "/System/Library/LaunchDaemons/\(label).plist"
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

    private func readLine(client: Int32) -> String? {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
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

HelperDaemon().run()
