import Foundation

public struct ProcessResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// 執行外部程式的抽象層，方便測試時替換。
public protocol ProcessRunner: Sendable {
    /// - Parameters:
    ///   - executable: 絕對路徑，例如 `/usr/bin/lp`。
    ///   - arguments: 參數陣列；**不經過 shell**，因此檔名中的空白、引號、`;` 都不會被解讀。
    func run(_ executable: String, _ arguments: [String]) async throws -> ProcessResult
}

public struct SystemProcessRunner: ProcessRunner {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 30) {
        self.timeout = timeout
    }

    public func run(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
        let timeout = self.timeout
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                // 固定英文輸出，讓解析器不受系統語言影響。
                var env = ProcessInfo.processInfo.environment
                env["LANG"] = "C"
                env["LC_ALL"] = "C"
                process.environment = env
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

                // 兩個 pipe 同時讀，避免任一邊塞滿造成死結。
                let group = DispatchGroup()
                nonisolated(unsafe) var errData = Data()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                killer.cancel()

                continuation.resume(returning: ProcessResult(
                    status: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                ))
            }
        }
    }
}
