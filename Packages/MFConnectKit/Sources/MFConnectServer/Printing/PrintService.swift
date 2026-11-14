import Foundation
import MFConnectCore

/// 送印後取得的識別資訊。
public struct PrintSubmission: Sendable, Equatable {
    public var cupsJobID: String?
    /// 選項降級等說明，會寫入工作紀錄。
    public var notes: [String]

    public init(cupsJobID: String?, notes: [String] = []) {
        self.cupsJobID = cupsJobID
        self.notes = notes
    }
}

public enum PrintProgress: Sendable, Equatable {
    /// 還在印表機佇列中。
    case printing
    /// 印表機回報需要人處理的錯誤（缺紙、卡紙…）。由佇列決定持續多久才判定失敗。
    case blocked(String)
    case done
    case failed(String)
}

public struct PrintServiceError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// 列印的抽象層。
///
/// - ``LpPrintService``：呼叫 `/usr/bin/lp`（目前的實作，需要關閉 App Sandbox）。
/// - ``DryRunPrintService``：不列印，只寫紀錄。
///
/// 若要上 Mac App Store，需新增以 `NSPrintOperation` / `PDFDocument.printOperation` 實作的版本並開啟沙盒。
public protocol PrintService: Sendable {
    var isDryRun: Bool { get }
    func submit(fileURL: URL, title: String, options: JobOptions, printer: String?) async throws -> PrintSubmission
    func progress(of submission: PrintSubmission, printer: String?) async -> PrintProgress
    func cancel(_ submission: PrintSubmission, printer: String?) async
}

/// 不真的列印，只記錄收到的工作。給測試與開發使用，避免浪費紙和碳粉。
public actor DryRunPrintService: PrintService {
    public struct Record: Sendable, Equatable {
        public var fileURL: URL
        public var title: String
        public var options: JobOptions
        public var printer: String?
        public var fileSize: Int64
        public var date: Date
    }

    public nonisolated var isDryRun: Bool { true }
    public private(set) var records: [Record] = []
    private let log: (@Sendable (String) -> Void)?
    private var counter = 0

    public init(log: (@Sendable (String) -> Void)? = nil) {
        self.log = log
    }

    public func submit(fileURL: URL, title: String, options: JobOptions, printer: String?) async throws -> PrintSubmission {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw PrintServiceError("找不到要列印的檔案")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        records.append(Record(fileURL: fileURL, title: title, options: options, printer: printer, fileSize: size, date: Date()))
        counter += 1
        log?("[試跑] 假裝列印「\(title)」：\(options.summary)，印表機 \(printer ?? "（未選擇）")，\(size) bytes")
        return PrintSubmission(cupsJobID: "dryrun-\(counter)", notes: ["試跑模式：沒有實際列印"])
    }

    public func progress(of submission: PrintSubmission, printer: String?) async -> PrintProgress { .done }

    public func cancel(_ submission: PrintSubmission, printer: String?) async {}
}
