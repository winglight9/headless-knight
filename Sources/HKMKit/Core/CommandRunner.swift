import Foundation

public struct CommandResult: Sendable, Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { status == 0 }
}

public protocol CommandRunning: Sendable {
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> CommandResult
    /// Declared as a requirement (not just a convenience) so it dispatches
    /// through `any CommandRunning`.
    func run(_ executable: String, arguments: [String]) throws -> CommandResult
}

public extension CommandRunning {
    func run(_ executable: String, arguments: [String]) throws -> CommandResult {
        try run(executable, arguments: arguments, timeout: 20)
    }
}

/// Runs a child process and collects both pipes without deadlocking on large
/// output (``pmset -g log`` is tens of thousands of lines).
public struct ShellRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw HKMError.unavailable("找不到可执行文件 \(executable)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        try process.run()

        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: group) {
            outBox.set(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        }
        DispatchQueue.global(qos: .utility).async(group: group) {
            errBox.set(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        _ = group.wait(timeout: .now() + 5)

        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: outBox.value, as: UTF8.self),
            stderr: String(decoding: errBox.value, as: UTF8.self)
        )
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func set(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
