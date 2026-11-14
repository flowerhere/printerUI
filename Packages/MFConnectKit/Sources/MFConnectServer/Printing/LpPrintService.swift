import Foundation
import MFConnectCore

/// 透過 CUPS 指令列工具列印：`/usr/bin/lp`、`/usr/bin/lpstat`、`/usr/bin/lpoptions`、`/usr/bin/cancel`。
///
/// 所有指令都以 `Process` + 參數陣列執行，絕不經過 shell 字串拼接。
public struct LpPrintService: PrintService {
    public struct Paths: Sendable {
        public var lp = "/usr/bin/lp"
        public var lpstat = "/usr/bin/lpstat"
        public var lpoptions = "/usr/bin/lpoptions"
        public var cancel = "/usr/bin/cancel"
        public init() {}
    }

    public var isDryRun: Bool { false }
    private let runner: any ProcessRunner
    private let paths: Paths

    public init(runner: any ProcessRunner = SystemProcessRunner(), paths: Paths = Paths()) {
        self.runner = runner
        self.paths = paths
    }

    // MARK: - 印表機清單

    /// `lpstat -e` 列出的所有佇列。
    public func availableQueues() async -> [String] {
        guard let result = try? await runner.run(paths.lpstat, ["-e"]), result.status == 0 else { return [] }
        return LpstatParser.queues(from: result.stdout)
    }

    public func defaultQueue() async -> String? {
        guard let result = try? await runner.run(paths.lpstat, ["-d"]), result.status == 0 else { return nil }
        return LpstatParser.defaultQueue(from: result.stdout)
    }

    /// `lpoptions -p <佇列> -l`；失敗時回傳 `nil`。
    public func capabilities(of printer: String) async -> PrinterCapabilities? {
        guard let result = try? await runner.run(paths.lpoptions, ["-p", printer, "-l"]), result.status == 0 else {
            return nil
        }
        return PrinterCapabilities.parse(lpoptionsOutput: result.stdout)
    }

    // MARK: - PrintService

    public func submit(fileURL: URL, title: String, options: JobOptions, printer: String?) async throws -> PrintSubmission {
        guard let printer, !printer.isEmpty else {
            throw PrintServiceError("尚未選擇印表機，請在選單列的設定中選擇")
        }
        let queues = await availableQueues()
        guard queues.contains(printer) else {
            throw PrintServiceError("找不到印表機佇列「\(printer)」，請確認已在「系統設定 → 印表機與掃描器」加入")
        }
        let caps = await capabilities(of: printer)
        let built = LpArguments.build(printer: printer, fileURL: fileURL, title: title, options: options, capabilities: caps)
        let result = try await runner.run(paths.lp, built.arguments)
        guard result.status == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PrintServiceError("lp 執行失敗（\(result.status)）：\(detail.prefix(200))")
        }
        return PrintSubmission(cupsJobID: LpstatParser.requestID(from: result.stdout), notes: built.notes)
    }

    public func progress(of submission: PrintSubmission, printer: String?) async -> PrintProgress {
        guard let jobID = submission.cupsJobID, let printer else {
            return .done
        }
        // 1. 還在未完成清單中 → 檢查印表機是否有錯誤
        if let pending = try? await runner.run(paths.lpstat, ["-o", printer]), pending.status == 0,
           LpstatParser.jobIsListed(jobID, in: pending.stdout) {
            if let status = try? await runner.run(paths.lpstat, ["-l", "-p", printer]),
               let alert = LpstatParser.blockingAlert(from: status.stdout) {
                return .blocked(alert)
            }
            return .printing
        }
        // 2. 已離開未完成清單 → 視為完成（CUPS 已把資料交給印表機）
        return .done
    }

    public func cancel(_ submission: PrintSubmission, printer: String?) async {
        guard let jobID = submission.cupsJobID else { return }
        _ = try? await runner.run(paths.cancel, [jobID])
    }
}
