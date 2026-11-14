import Foundation

public enum DuplexMode: String, Codable, Sendable, CaseIterable {
    case none
    case long
    case short

    public var displayName: String {
        switch self {
        case .none: "單面"
        case .long: "雙面（長邊翻頁）"
        case .short: "雙面（短邊翻頁）"
        }
    }
}

public enum ColorMode: String, Codable, Sendable, CaseIterable {
    case color
    case mono

    public var displayName: String {
        switch self {
        case .color: "彩色"
        case .mono: "黑白"
        }
    }
}

/// 單一列印工作的選項。
public struct JobOptions: Codable, Sendable, Equatable {
    public var copies: Int
    public var duplex: DuplexMode
    public var color: ColorMode

    public init(copies: Int = 1, duplex: DuplexMode = .none, color: ColorMode = .color) {
        self.copies = copies
        self.duplex = duplex
        self.color = color
    }

    public enum ParseError: Error, Equatable, Sendable {
        case invalidCopies(String)
        case invalidDuplex(String)
        case invalidColor(String)

        public var message: String {
            switch self {
            case .invalidCopies(let v): "份數必須是 1–\(MFConnectConstants.maxCopies) 的整數（收到「\(v.prefix(20))」）"
            case .invalidDuplex(let v): "X-Duplex 只接受 none、long、short（收到「\(v.prefix(20))」）"
            case .invalidColor(let v): "X-Color 只接受 color、mono（收到「\(v.prefix(20))」）"
            }
        }
    }

    /// 由 HTTP header 值解析選項；header 不存在時採用預設值，存在但格式錯誤則丟出錯誤。
    public static func parse(copies: String?, duplex: String?, color: String?) throws(ParseError) -> JobOptions {
        var options = JobOptions()
        if let raw = copies?.trimmingCharacters(in: .whitespaces) {
            guard raw.count <= 2, raw.allSatisfy(\.isASCII), let value = Int(raw),
                  (1...MFConnectConstants.maxCopies).contains(value) else {
                throw .invalidCopies(raw)
            }
            options.copies = value
        }
        if let raw = duplex?.trimmingCharacters(in: .whitespaces) {
            guard let value = DuplexMode(rawValue: raw.lowercased()) else { throw .invalidDuplex(raw) }
            options.duplex = value
        }
        if let raw = color?.trimmingCharacters(in: .whitespaces) {
            guard let value = ColorMode(rawValue: raw.lowercased()) else { throw .invalidColor(raw) }
            options.color = value
        }
        return options
    }

    /// 選單列等處使用的簡短摘要，例如「2 份・雙面（長邊翻頁）・黑白」。
    public var summary: String {
        "\(copies) 份・\(duplex.displayName)・\(color.displayName)"
    }
}
