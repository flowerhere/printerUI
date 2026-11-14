import Foundation
import MFConnectCore

/// `lpoptions -p <佇列> -l` 解析結果。
public struct PrinterCapabilities: Sendable, Equatable {
    /// option key → 可用值（已去掉預設值前的 `*`）。
    public var options: [String: [String]]

    public init(options: [String: [String]]) {
        self.options = options
    }

    /// 解析如下格式的每一行：
    /// `Duplex/Two-Sided: *None DuplexNoTumble DuplexTumble`
    public static func parse(lpoptionsOutput: String) -> PrinterCapabilities {
        var result: [String: [String]] = [:]
        for rawLine in lpoptionsOutput.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let keyPart = line[..<colon]
            let key = String(keyPart.split(separator: "/", maxSplits: 1).first ?? keyPart)
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let values = line[line.index(after: colon)...]
                .split(separator: " ", omittingEmptySubsequences: true)
                .map { $0.hasPrefix("*") ? String($0.dropFirst()) : String($0) }
            result[key] = values
        }
        return PrinterCapabilities(options: result)
    }

    private func values(_ key: String) -> [String] {
        // PPD key 大小寫不一，做不分大小寫比對。
        if let v = options[key] { return v }
        return options.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value ?? []
    }

    public func supportsDuplex(_ mode: DuplexMode) -> Bool {
        switch mode {
        case .none:
            return true
        case .long:
            return values("sides").contains("two-sided-long-edge") || values("Duplex").contains("DuplexNoTumble")
        case .short:
            return values("sides").contains("two-sided-short-edge") || values("Duplex").contains("DuplexTumble")
        }
    }

    /// 是否有任何雙面相關選項（用來判斷「單面」參數要不要送）。
    public var hasDuplexOption: Bool {
        !values("sides").isEmpty || !values("Duplex").isEmpty
    }

    public var supportsMonochrome: Bool {
        if values("print-color-mode").contains(where: { $0.lowercased() == "monochrome" }) { return true }
        let grayNames: Set<String> = ["gray", "grayscale", "mono", "monochrome", "kgray", "black"]
        return values("ColorModel").contains { grayNames.contains($0.lowercased()) }
    }
}

/// 組合 `/usr/bin/lp` 的參數陣列。純函式，方便單元測試。
public enum LpArguments {
    public struct Result: Equatable, Sendable {
        public var arguments: [String]
        public var notes: [String]
    }

    /// - Parameter capabilities: `nil` 代表無法讀取佇列選項；此時照原樣送出，並在紀錄中註明。
    public static func build(
        printer: String,
        fileURL: URL,
        title: String,
        options: JobOptions,
        capabilities: PrinterCapabilities?
    ) -> Result {
        var args: [String] = ["-d", printer, "-n", String(min(max(options.copies, 1), MFConnectConstants.maxCopies))]
        var notes: [String] = []

        // 標題只用於印表機佇列顯示；限制長度並移除換行。
        let safeTitle = String(title.filter { !$0.isNewline }.prefix(100))
        if !safeTitle.isEmpty { args += ["-t", safeTitle] }

        if capabilities == nil {
            notes.append("無法讀取印表機選項，已直接送出請求的設定")
        }

        // 雙面
        let duplexValue: String
        switch options.duplex {
        case .none: duplexValue = "one-sided"
        case .long: duplexValue = "two-sided-long-edge"
        case .short: duplexValue = "two-sided-short-edge"
        }
        if let caps = capabilities {
            if options.duplex == .none {
                if caps.hasDuplexOption { args += ["-o", "sides=one-sided"] }
            } else if caps.supportsDuplex(options.duplex) {
                args += ["-o", "sides=\(duplexValue)"]
            } else {
                notes.append("印表機佇列不支援「\(options.duplex.displayName)」，已改為單面")
                if caps.hasDuplexOption { args += ["-o", "sides=one-sided"] }
            }
        } else {
            args += ["-o", "sides=\(duplexValue)"]
        }

        // 色彩
        if options.color == .mono {
            if let caps = capabilities, !caps.supportsMonochrome {
                notes.append("印表機佇列沒有黑白選項，已依印表機預設色彩列印")
            } else {
                args += ["-o", "print-color-mode=monochrome"]
            }
        }

        // 檔案一律是 spool 資料夾內的絕對路徑（以 / 開頭），不會被 lp 誤認為選項。
        args.append(fileURL.path)
        return Result(arguments: args, notes: notes)
    }
}

/// `lp` / `lpstat` 的輸出解析。
public enum LpstatParser {
    /// `lpstat -e`：每行一個佇列名稱。
    public static func queues(from output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains(" ") }
    }

    /// `lpstat -d`：`system default destination: Canon_MF642C`
    public static func defaultQueue(from output: String) -> String? {
        guard let range = output.range(of: "system default destination:") else { return nil }
        let name = output[range.upperBound...].split(whereSeparator: \.isNewline).first?
            .trimmingCharacters(in: .whitespaces)
        return name?.isEmpty == false ? name : nil
    }

    /// `lp` 的輸出：`request id is Canon_MF642C-42 (1 file(s))`
    public static func requestID(from output: String) -> String? {
        guard let range = output.range(of: "request id is ") else { return nil }
        let rest = output[range.upperBound...]
        let id = rest.prefix { !$0.isWhitespace }
        return id.isEmpty ? nil : String(id)
    }

    /// `lpstat -o <佇列>`：第一欄是工作編號。
    public static func jobIsListed(_ jobID: String, in output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { line in
            line.split(separator: " ", maxSplits: 1).first.map(String.init) == jobID
        }
    }

    /// `lpstat -l -p <佇列>` 中需要人處理的錯誤；回傳繁體中文描述，沒有錯誤時回傳 `nil`。
    public static func blockingAlert(from output: String) -> String? {
        let lower = output.lowercased()
        var reasons: [String] = []
        // 從 "Alerts:" 行取出 IPP printer-state-reasons
        for line in lower.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("alerts:") {
                reasons += trimmed.dropFirst("alerts:".count).split(separator: " ").map(String.init)
            }
        }
        let table: [(keys: [String], text: String)] = [
            (["media-jam", "paper jam"], "印表機卡紙"),
            (["media-empty", "media-needed", "out of paper", "paper out"], "印表機缺紙"),
            (["door-open", "cover-open", "door open", "cover open"], "印表機蓋子未關"),
            (["toner-empty", "marker-supply-empty"], "碳粉用盡"),
            (["input-tray-missing"], "紙匣未裝好"),
        ]
        for entry in table {
            for key in entry.keys {
                // printer-state-reasons 以 -report / -warning 結尾的只是提醒，不算阻塞錯誤。
                let hitInAlerts = reasons.contains { $0.hasPrefix(key) && !$0.hasSuffix("-report") && !$0.hasSuffix("-warning") }
                let hitInMessage = !key.contains("-") && lower.contains(key)
                if hitInAlerts || hitInMessage { return entry.text }
            }
        }
        if lower.contains("disabled since") || lower.contains(" is disabled") {
            return "印表機佇列已停用（請到「系統設定 → 印表機與掃描器」恢復）"
        }
        return nil
    }
}
