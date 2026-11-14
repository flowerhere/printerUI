import Foundation

/// 檔名清理。清理後的檔名**只用於顯示**；磁碟上一律以 UUID 命名。
public enum FilenameSanitizer {
    public static let maxLength = 120
    public static let fallbackName = "未命名"

    /// 解碼 `X-Filename`（百分比編碼）並清理。
    public static func decodeHeader(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return fallbackName }
        // 先限制長度，避免超長 header 浪費運算。
        let limited = String(raw.prefix(1024))
        let decoded = limited.removingPercentEncoding ?? limited
        return sanitize(decoded)
    }

    public static func sanitize(_ name: String) -> String {
        // 1. 只取最後一個路徑元件（同時處理 / 與 \），消除 ../ 之類的路徑。
        let lastComponent = name
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last
            .map(String.init) ?? ""

        // 2. 移除控制字元、NUL、雙向文字覆寫字元（可用來偽造副檔名，例如 "gpj.exe"）與其他格式字元。
        var scalars = String.UnicodeScalarView()
        for scalar in lastComponent.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned:
                continue
            default:
                break
            }
            // Windows / macOS 檔名中具特殊意義的字元
            if ":*?\"<>|".unicodeScalars.contains(scalar) {
                scalars.append("_")
            } else {
                scalars.append(scalar)
            }
        }
        var cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)

        // 3. 去掉開頭的點，避免變成隱藏檔或 "." / ".."。
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)

        // 4. 限制長度（以字元計），盡量保留副檔名。
        if cleaned.count > maxLength {
            let ext = (cleaned as NSString).pathExtension
            if !ext.isEmpty, ext.count < 10 {
                let base = cleaned.dropLast(ext.count + 1).prefix(maxLength - ext.count - 1)
                cleaned = "\(base).\(ext)"
            } else {
                cleaned = String(cleaned.prefix(maxLength))
            }
        }
        return cleaned.isEmpty ? fallbackName : cleaned
    }

    /// 給 `X-Filename` 用的百分比編碼（只保留非保留字元）。
    public static func encodeHeader(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return name.addingPercentEncoding(withAllowedCharacters: allowed) ?? "file"
    }
}
