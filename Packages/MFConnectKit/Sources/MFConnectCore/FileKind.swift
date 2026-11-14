import Foundation

/// 支援的檔案格式。一律以檔頭 magic bytes 判斷，不信任副檔名或 Content-Type。
public enum FileKind: String, Codable, Sendable, CaseIterable {
    case pdf
    case jpeg
    case png
    case heic

    public var fileExtension: String {
        switch self {
        case .pdf: "pdf"
        case .jpeg: "jpg"
        case .png: "png"
        case .heic: "heic"
        }
    }

    public var mimeType: String {
        switch self {
        case .pdf: "application/pdf"
        case .jpeg: "image/jpeg"
        case .png: "image/png"
        case .heic: "image/heic"
        }
    }

    public var displayName: String {
        switch self {
        case .pdf: "PDF"
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        }
    }

    public var isImage: Bool { self != .pdf }
}

public enum FileSniffer {
    /// 判斷所需的最少位元組數。
    public static let headerLength = 16

    /// HEIF 家族中，ImageIO 可解碼為靜態影像的 major brand。
    static let heifBrands: Set<String> = ["heic", "heix", "heim", "heis", "hevc", "hevx", "hevm", "hevs", "mif1", "msf1"]

    /// 依檔頭判斷格式；無法辨識時回傳 `nil`。
    public static func detect<C: Collection>(_ header: C) -> FileKind? where C.Element == UInt8 {
        let bytes = Array(header.prefix(headerLength))

        // PDF：%PDF-
        if bytes.starts(with: [0x25, 0x50, 0x44, 0x46, 0x2D]) { return .pdf }
        // PNG：89 50 4E 47 0D 0A 1A 0A
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        // JPEG：FF D8 FF
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        // HEIC：ISO BMFF，第 4–7 bytes 為 "ftyp"，第 8–11 bytes 為 major brand
        if bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8) {
            let brand = String(decoding: bytes[8..<12], as: UTF8.self)
            if heifBrands.contains(brand) { return .heic }
        }
        return nil
    }

    public static func detect(fileAt url: URL) -> FileKind? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headerLength) else { return nil }
        return detect(data)
    }
}
