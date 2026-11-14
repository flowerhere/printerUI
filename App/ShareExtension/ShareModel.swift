import Foundation
import ImageIO
import MFConnectClient
import MFConnectCore
import Observation
import UIKit
import UniformTypeIdentifiers

/// 分享面板的狀態。檔案一律以「複製到暫存資料夾 → 以檔案 URL 串流上傳」處理，
/// 不把整個檔案載入記憶體（Share Extension 的記憶體上限很低）。
@MainActor
@Observable
final class ShareModel {
    enum Phase: Equatable {
        case loading
        case ready
        case uploading
        case finished
    }

    enum ItemState: Equatable {
        case waiting
        case uploading(Double)
        case sent(JobStatus)
        case failed(String)
    }

    struct Item: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var fileURL: URL?
        var size: Int64
        var kind: FileKind?
        var state: ItemState
        var problem: String?
    }

    private(set) var phase: Phase = .loading
    private(set) var items: [Item] = []
    private(set) var serverInfo: ServerInfoDTO?
    private(set) var configurationProblem: String?
    var options: JobOptions

    let serverURL: URL?
    let serverName: String?
    private let token: String?
    private let providers: [NSItemProvider]
    private let workDirectory: URL
    private let onFinish: () -> Void
    private let onCancel: () -> Void
    private var uploadTask: Task<Void, Never>?

    init(providers: [NSItemProvider], onFinish: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.providers = providers
        self.onFinish = onFinish
        self.onCancel = onCancel
        let settings = SharedSettings.shared
        self.serverURL = settings.serverURL
        self.serverName = settings.serverName
        self.options = settings.lastOptions
        self.token = SharedTokenStore().load()
        self.workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MFConnectShare", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        if serverURL == nil {
            configurationProblem = "尚未設定伺服器。請先開啟 MFConnect App，搜尋或輸入伺服器位址並儲存。"
        } else if token?.isEmpty ?? true {
            configurationProblem = "尚未設定 token。請先開啟 MFConnect App 輸入 token。"
        }
    }

    var sendableItems: [Item] { items.filter { $0.problem == nil && $0.fileURL != nil } }

    var canSend: Bool {
        phase == .ready && configurationProblem == nil && !sendableItems.isEmpty
    }

    var overallProgress: Double {
        let total = sendableItems.reduce(Int64(0)) { $0 + max($1.size, 1) }
        guard total > 0 else { return 0 }
        var done: Double = 0
        for item in sendableItems {
            let weight = Double(max(item.size, 1))
            switch item.state {
            case .sent, .failed: done += weight
            case .uploading(let p): done += weight * p
            case .waiting: break
            }
        }
        return done / Double(total)
    }

    // MARK: - 載入附件

    func loadAttachments() async {
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        async let info: Void = fetchServerInfo()
        for (index, provider) in providers.enumerated() {
            var item = await load(provider: provider, index: index)
            if let size = serverInfo?.maxUploadBytes, item.size > size {
                item.problem = "檔案太大（上限 \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))）"
            }
            items.append(item)
        }
        _ = await info
        // 伺服器資訊較晚取得時，補做大小檢查
        if let limit = serverInfo?.maxUploadBytes {
            for i in items.indices where items[i].problem == nil && items[i].size > limit {
                items[i].problem = "檔案太大（上限 \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))）"
            }
        }
        phase = .ready
    }

    private func fetchServerInfo() async {
        guard configurationProblem == nil, let client = makeClient() else { return }
        do {
            serverInfo = try await client.info()
        } catch let error as ClientError where error == .unauthorized {
            configurationProblem = "token 錯誤，請到 MFConnect App 重新輸入。"
        } catch {
            // 連不上時不阻擋：讓使用者按「傳送」時再看到明確錯誤
        }
    }

    private func load(provider: NSItemProvider, index: Int) async -> Item {
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        let baseName = provider.suggestedName.map { FilenameSanitizer.sanitize($0) }

        // 1. PDF
        if let pdfType = types.first(where: { $0.conforms(to: .pdf) }) {
            return await makeItem(provider: provider, type: pdfType, baseName: baseName ?? "文件-\(index + 1)", fallbackExt: "pdf")
        }
        // 2. 圖片：優先使用伺服器直接支援的格式（HEIC、JPEG、PNG）
        let preferred: [UTType] = [.heic, .jpeg, .png]
        if let imageType = preferred.first(where: { p in types.contains { $0 == p } })
            ?? types.first(where: { $0.conforms(to: .image) }) {
            return await makeItem(provider: provider, type: imageType, baseName: baseName ?? "圖片-\(index + 1)",
                                  fallbackExt: imageType.preferredFilenameExtension ?? "jpg")
        }
        return Item(name: baseName ?? "項目 \(index + 1)", fileURL: nil, size: 0, kind: nil, state: .waiting,
                    problem: "不支援的項目（只接受 PDF 與圖片）")
    }

    private func makeItem(provider: NSItemProvider, type: UTType, baseName: String, fallbackExt: String) async -> Item {
        var name = baseName
        if (name as NSString).pathExtension.isEmpty { name += ".\(fallbackExt)" }
        do {
            var url = try await copyFile(from: provider, type: type)
            var kind = FileSniffer.detect(fileAt: url)
            // 其他圖片格式（GIF、TIFF、WebP…）在本機轉成 JPEG
            if kind == nil, type.conforms(to: .image) {
                url = try Self.convertToJPEG(url, in: workDirectory)
                kind = .jpeg
                name = (name as NSString).deletingPathExtension + ".jpg"
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard let kind else {
                return Item(name: name, fileURL: nil, size: size, kind: nil, state: .waiting, problem: "格式不支援")
            }
            return Item(name: name, fileURL: url, size: size, kind: kind, state: .waiting, problem: nil)
        } catch {
            return Item(name: name, fileURL: nil, size: 0, kind: nil, state: .waiting, problem: "無法讀取檔案：\(error.localizedDescription)")
        }
    }

    /// 取得檔案並複製到暫存資料夾（系統提供的 URL 只在 callback 期間有效）。
    private func copyFile(from provider: NSItemProvider, type: UTType) async throws -> URL {
        let directory = workDirectory
        do {
            return try await withCheckedThrowingContinuation { continuation in
                _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                    guard let url else {
                        continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                        return
                    }
                    let dest = directory.appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(url.pathExtension.isEmpty ? "bin" : url.pathExtension)
                    do {
                        try FileManager.default.copyItem(at: url, to: dest)
                        continuation.resume(returning: dest)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            // 有些來源（例如截圖編輯器）只提供 UIImage 或 Data，沒有檔案表示
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, error in
                    let dest = directory.appendingPathComponent(UUID().uuidString)
                    do {
                        switch item {
                        case let url as URL:
                            let target = dest.appendingPathExtension(url.pathExtension)
                            try FileManager.default.copyItem(at: url, to: target)
                            continuation.resume(returning: target)
                        case let data as Data:
                            try data.write(to: dest.appendingPathExtension("bin"))
                            continuation.resume(returning: dest.appendingPathExtension("bin"))
                        case let image as UIImage:
                            guard let data = image.jpegData(compressionQuality: 0.92) else {
                                throw CocoaError(.fileReadCorruptFile)
                            }
                            try data.write(to: dest.appendingPathExtension("jpg"))
                            continuation.resume(returning: dest.appendingPathExtension("jpg"))
                        default:
                            throw error ?? CocoaError(.fileReadUnknown)
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// 以 ImageIO 轉成 JPEG（限制最大邊長，避免記憶體不足）。
    private nonisolated static func convertToJPEG(_ url: URL, in directory: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 4096,
              ] as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let dest = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        guard let writer = CGImageDestinationCreateWithURL(dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw CocoaError(.fileWriteUnknown) }
        try? FileManager.default.removeItem(at: url)
        return dest
    }

    // MARK: - 傳送

    private func makeClient() -> MFConnectClient? {
        guard let serverURL, let token, !token.isEmpty else { return nil }
        return MFConnectClient(baseURL: serverURL, token: token, clientName: "\(UIDevice.current.model) 分享選單")
    }

    func send() {
        guard canSend, let client = makeClient() else { return }
        SharedSettings.shared.lastOptions = options
        phase = .uploading
        let options = self.options
        uploadTask = Task {
            for item in sendableItems {
                guard let url = item.fileURL, !Task.isCancelled else { continue }
                update(item.id) { $0.state = .uploading(0) }
                let id = item.id
                do {
                    let created = try await client.upload(fileURL: url, filename: item.name, options: options) { progress in
                        Task { @MainActor [weak self] in
                            self?.update(id) { item in
                                if case .uploading = item.state { item.state = .uploading(progress) }
                            }
                        }
                    }
                    update(id) { $0.state = .sent(created.status) }
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    update(id) { $0.state = .failed(message) }
                    if (error as? ClientError) == .unauthorized { break } // token 錯誤：其餘檔案也會失敗
                }
            }
            phase = .finished
            cleanUp()
        }
    }

    var summary: (sent: Int, failed: Int, needsApproval: Bool) {
        var sent = 0, failed = 0, approval = false
        for item in items {
            switch item.state {
            case .sent(let status):
                sent += 1
                if status == .pendingApproval { approval = true }
            case .failed: failed += 1
            default: break
            }
        }
        return (sent, failed, approval)
    }

    func done() {
        cleanUp()
        onFinish()
    }

    func cancel() {
        uploadTask?.cancel()
        cleanUp()
        onCancel()
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: workDirectory)
    }
}
