import Foundation
import MFConnectCore
#if canImport(PDFKit) && canImport(ImageIO) && canImport(UniformTypeIdentifiers)
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers
#endif

/// 把上傳的檔案轉成可送印的 PDF。
public protocol DocumentPreparing: Sendable {
    /// - Returns: 實際要送印的檔案（PDF）。轉換產生的檔案放在 `outputDirectory` 內。
    func preparePrintableFile(source: URL, kind: FileKind, outputBase: URL) async throws -> URL
}

public struct DocumentPreparationError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// A4 尺寸（點，1/72 英吋）。
public enum PaperSize {
    public static let a4Width: Double = 595.2756
    public static let a4Height: Double = 841.8898
    /// 四周留白（約 10 mm），避免被印表機的不可列印邊界裁切。
    public static let margin: Double = 28.35

    /// 圖片在 A4 上的置中、等比例縮放位置（縮放到可容納的最大尺寸）。
    /// 寬大於高的圖片自動轉成橫向頁面，讓圖片盡量大。
    public static func layout(imageWidth: Double, imageHeight: Double) -> (page: (w: Double, h: Double), rect: (x: Double, y: Double, w: Double, h: Double)) {
        let landscape = imageWidth > imageHeight
        let pageW = landscape ? a4Height : a4Width
        let pageH = landscape ? a4Width : a4Height
        let availW = pageW - margin * 2
        let availH = pageH - margin * 2
        guard imageWidth > 0, imageHeight > 0 else {
            return ((pageW, pageH), (margin, margin, availW, availH))
        }
        let scale = min(availW / imageWidth, availH / imageHeight)
        let w = imageWidth * scale
        let h = imageHeight * scale
        return ((pageW, pageH), ((pageW - w) / 2, (pageH - h) / 2, w, h))
    }
}

public struct DocumentPreparer: DocumentPreparing {
    /// 解碼圖片時的最大邊長（像素），防止超大圖片耗盡記憶體（decompression bomb）。
    public var maxImagePixelSize: Int

    public init(maxImagePixelSize: Int = 7000) {
        self.maxImagePixelSize = maxImagePixelSize
    }

    public func preparePrintableFile(source: URL, kind: FileKind, outputBase: URL) async throws -> URL {
        switch kind {
        case .pdf:
            try validatePDF(source)
            return source
        case .jpeg, .png:
            let pdfURL = outputBase.appendingPathExtension("pdf")
            try imageToA4PDF(source: source, destination: pdfURL)
            return pdfURL
        case .heic:
            // 依需求：HEIC 先以 ImageIO 轉成 JPEG，再走一般圖片流程。
            let jpegURL = outputBase.deletingPathExtension().appendingPathExtension("converted.jpg")
            try heicToJPEG(source: source, destination: jpegURL)
            let pdfURL = outputBase.appendingPathExtension("pdf")
            try imageToA4PDF(source: jpegURL, destination: pdfURL)
            try? FileManager.default.removeItem(at: jpegURL)
            return pdfURL
        }
    }

    #if canImport(PDFKit) && canImport(ImageIO) && canImport(UniformTypeIdentifiers)

    func validatePDF(_ url: URL) throws {
        guard let document = PDFDocument(url: url) else {
            throw DocumentPreparationError("PDF 檔案損毀或無法開啟")
        }
        if document.isLocked {
            throw DocumentPreparationError("PDF 有密碼保護，無法列印")
        }
        if document.pageCount == 0 {
            throw DocumentPreparationError("PDF 沒有任何頁面")
        }
    }

    /// 以 ImageIO 解碼（自動套用 EXIF 方向、限制最大尺寸）。
    func loadImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw DocumentPreparationError("無法讀取圖片")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImagePixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw DocumentPreparationError("圖片格式損毀或無法解碼")
        }
        return image
    }

    func heicToJPEG(source: URL, destination: URL) throws {
        let image = try loadImage(source)
        guard let dest = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw DocumentPreparationError("無法建立 JPEG 檔案")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw DocumentPreparationError("HEIC 轉 JPEG 失敗")
        }
    }

    /// 產生單頁 A4 PDF，圖片等比例縮放並置中；產生後用 PDFKit 開啟驗證。
    ///
    /// 以 Core Graphics 的 PDF context 繪製（行為明確、可控制版面），PDFKit 負責驗證結果。
    func imageToA4PDF(source: URL, destination: URL) throws {
        let image = try loadImage(source)
        let layout = PaperSize.layout(imageWidth: Double(image.width), imageHeight: Double(image.height))
        var mediaBox = CGRect(x: 0, y: 0, width: layout.page.w, height: layout.page.h)
        let imageRect = CGRect(x: layout.rect.x, y: layout.rect.y, width: layout.rect.w, height: layout.rect.h)
        guard let context = CGContext(destination as CFURL, mediaBox: &mediaBox, [
            kCGPDFContextCreator: "MFConnect",
        ] as CFDictionary) else {
            throw DocumentPreparationError("無法建立 PDF")
        }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(mediaBox)
        context.interpolationQuality = .high
        context.draw(image, in: imageRect)
        context.endPDFPage()
        context.closePDF()

        guard let check = PDFDocument(url: destination), check.pageCount == 1 else {
            throw DocumentPreparationError("產生的 PDF 無法開啟")
        }
    }

    #else

    // Linux（只用於跑測試）：無 PDFKit / ImageIO，只做最基本的檢查。
    func validatePDF(_ url: URL) throws {
        guard FileSniffer.detect(fileAt: url) == .pdf else {
            throw DocumentPreparationError("PDF 檔案損毀或無法開啟")
        }
    }

    func heicToJPEG(source: URL, destination: URL) throws {
        throw DocumentPreparationError("此平台不支援 HEIC 轉換")
    }

    func imageToA4PDF(source: URL, destination: URL) throws {
        throw DocumentPreparationError("此平台不支援圖片轉 PDF")
    }

    #endif
}
