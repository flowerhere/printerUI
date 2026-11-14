import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdCore
import MFConnectCore
import NIOCore

/// `POST /api/jobs`：body 為檔案原始內容（不使用 multipart）。
///
/// 處理順序（越便宜的檢查越早做，失敗時不讀取 body）：
/// 1. 上傳頻率限制 → 429
/// 2. Content-Length 超過上限 → 413（斷線）
/// 3. 選項 header 格式 → 400
/// 4. 佇列已滿 → 503
/// 5. 串流寫入 spool/<UUID>.part，持續計數，超過上限 → 413（斷線）
/// 6. magic bytes 判斷格式 → 415
/// 7. 改名為 spool/<UUID>.<ext>，加入佇列 → 201
struct UploadHandler {
    let state: ServerRuntimeState
    let accessGuard: AccessGuard
    let queue: JobQueue

    func handle(request: Request, context: MFRequestContext) async throws -> Response {
        let settings = state.settings
        let ip = context.remoteIP
        let limit = settings.maxUploadBytes

        if case .tooManyRequests(let retry) = await accessGuard.registerUpload(ip: ip) {
            throw APIError.tooManyRequests(retryAfter: retry, close: true)
        }

        if let rawLength = request.headers[.contentLength] {
            guard let length = Int64(rawLength), length >= 0 else {
                throw APIError.badRequest("Content-Length 格式錯誤", close: true)
            }
            if length > limit { throw APIError.payloadTooLarge(limit: limit) }
            if length == 0 { throw APIError.badRequest("檔案是空的", close: true) }
        }

        let options: JobOptions
        do throws(JobOptions.ParseError) {
            options = try JobOptions.parse(
                copies: request.headers[HTTPField.Name(APIHeader.copies)!],
                duplex: request.headers[HTTPField.Name(APIHeader.duplex)!],
                color: request.headers[HTTPField.Name(APIHeader.color)!]
            )
        } catch {
            throw APIError.badRequest(error.message, close: true)
        }
        let displayName = FilenameSanitizer.decodeHeader(request.headers[HTTPField.Name(APIHeader.filename)!])
        let client = Self.describeClient(
            declared: request.headers[HTTPField.Name(APIHeader.client)!],
            userAgent: request.headers[.userAgent]
        )

        guard await queue.hasCapacity else { throw APIError.queueFull(close: true) }

        // 磁碟上一律以 UUID 命名，檔名只用於顯示。
        let id = UUID()
        let store = queue.store
        let partURL = store.partialURL(for: id)
        try store.validateInsideSpool(partURL)

        let writer: SizeLimitedFileWriter
        do {
            writer = try SizeLimitedFileWriter(url: partURL, limit: limit, headerCapacity: FileSniffer.headerLength)
        } catch {
            throw APIError.internalError("無法建立暫存檔")
        }

        // 整個上傳的時間上限：時間到就直接關閉連線，讓下方的讀取迴圈拋出錯誤。
        let channel = context.channel
        let timedOut = TimeoutFlag()
        let timer = Task {
            try await Task.sleep(for: .seconds(settings.requestTimeoutSeconds))
            timedOut.set()
            channel.close(promise: nil)
        }
        defer { timer.cancel() }

        do {
            for try await buffer in request.body {
                try writer.append(buffer.readableBytesView)
            }
            writer.close()
        } catch SizeLimitedFileWriter.WriteError.limitExceeded {
            writer.close()
            store.deleteFiles(for: id)
            throw APIError.payloadTooLarge(limit: limit)
        } catch {
            writer.close()
            store.deleteFiles(for: id)
            if timedOut.isSet { throw APIError.requestTimeout() }
            throw APIError.badRequest("上傳中斷", close: true)
        }

        guard writer.bytesWritten > 0 else {
            store.deleteFiles(for: id)
            throw APIError.badRequest("檔案是空的")
        }
        guard let kind = FileSniffer.detect(writer.header) else {
            store.deleteFiles(for: id)
            throw APIError.unsupportedMediaType()
        }

        let finalURL = store.fileURL(for: id, kind: kind)
        do {
            try store.validateInsideSpool(finalURL)
            try FileManager.default.moveItem(at: partURL, to: finalURL)
        } catch {
            store.deleteFiles(for: id)
            throw APIError.internalError("無法儲存檔案")
        }

        let upload = IncomingUpload(
            id: id, displayName: displayName, kind: kind, byteCount: writer.bytesWritten,
            sourceIP: ip, client: client, options: options
        )
        do {
            let job = try await queue.submit(upload)
            return try jsonResponse(JobCreatedDTO(id: job.id, status: job.status), status: .created)
        } catch {
            store.deleteFiles(for: id)
            throw APIError.queueFull()
        }
    }

    static func describeClient(declared: String?, userAgent: String?) -> String {
        var parts: [String] = []
        if let declared {
            // X-Client 以百分比編碼傳送（header 值只能是 ASCII）
            let decoded = String(declared.prefix(200)).removingPercentEncoding ?? declared
            let clean = FilenameSanitizer.sanitize(String(decoded.prefix(60)))
            if clean != FilenameSanitizer.fallbackName { parts.append(clean) }
        }
        if let ua = userAgent {
            parts.append(summarize(userAgent: ua))
        }
        return parts.isEmpty ? "未知" : parts.joined(separator: "・")
    }

    static func summarize(userAgent ua: String) -> String {
        let device: String
        if ua.contains("iPhone") { device = "iPhone" }
        else if ua.contains("iPad") { device = "iPad" }
        else if ua.contains("Android") { device = "Android" }
        else if ua.contains("Macintosh") { device = "Mac" }
        else if ua.contains("Windows") { device = "Windows" }
        else if ua.hasPrefix("curl/") { device = "curl" }
        else if ua.contains("CFNetwork") { device = "Apple App" }
        else { device = "其他裝置" }
        let browser: String
        if ua.contains("Edg/") { browser = " Edge" }
        else if ua.contains("Chrome/") || ua.contains("CriOS/") { browser = " Chrome" }
        else if ua.contains("Firefox/") || ua.contains("FxiOS/") { browser = " Firefox" }
        else if ua.contains("Safari/") { browser = " Safari" }
        else { browser = "" }
        return device + browser
    }
}

final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
