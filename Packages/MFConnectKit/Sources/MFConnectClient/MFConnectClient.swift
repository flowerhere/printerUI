import Foundation
import MFConnectCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ClientError: Error, Equatable, Sendable, LocalizedError {
    case invalidServerURL
    case missingToken
    case unauthorized
    case payloadTooLarge(String?)
    case unsupportedMediaType
    case tooManyRequests(String?)
    case queueFull
    case server(status: Int, message: String?)
    case network(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL: "伺服器位址格式不正確"
        case .missingToken: "尚未設定 token"
        case .unauthorized: "token 錯誤，請到 MFConnect App 重新設定"
        case .payloadTooLarge(let m): m ?? "檔案太大"
        case .unsupportedMediaType: "格式不支援（只接受 PDF、JPEG、PNG、HEIC）"
        case .tooManyRequests(let m): m ?? "嘗試次數太多，請稍後再試"
        case .queueFull: "列印佇列已滿，請稍後再試"
        case .server(let status, let m): m ?? "伺服器錯誤（\(status)）"
        case .network(let m): "連線失敗：\(m)"
        case .invalidResponse: "伺服器回應格式不正確"
        }
    }

    static func from(status: Int, body: Data) -> ClientError {
        let message = (try? JSONDecoder.mfConnect().decode(APIErrorDTO.self, from: body))?.message
        switch status {
        case 401: return .unauthorized
        case 413: return .payloadTooLarge(message)
        case 415: return .unsupportedMediaType
        case 429: return .tooManyRequests(message)
        case 503: return .queueFull
        default: return .server(status: status, message: message)
        }
    }
}

/// MFConnect 伺服器的 HTTP 用戶端（iOS 主 App、Share Extension 與測試共用）。
/// 所有屬性都是建立後不再變動的 `let`，因此可安全跨執行緒使用。
public final class MFConnectClient: @unchecked Sendable {
    public let baseURL: URL
    private let token: String
    private let clientName: String
    private let configuration: URLSessionConfiguration

    /// - Parameters:
    ///   - baseURL: 例如 `http://mac-mini.local:8631`
    ///   - clientName: 寫入 `X-Client`，讓伺服器紀錄顯示來源。
    public init(baseURL: URL, token: String, clientName: String = "MFConnect App",
                configuration: URLSessionConfiguration = .ephemeral) {
        self.baseURL = baseURL
        self.token = token
        self.clientName = clientName
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 30 * 60
        self.configuration = configuration
    }

    /// 解析使用者輸入的位址：可省略 `http://` 與連接埠。
    public static func normalizeServerURL(_ input: String, defaultPort: Int = MFConnectConstants.defaultPort) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty,
              components.scheme == "http" || components.scheme == "https" else { return nil }
        if components.port == nil { components.port = defaultPort }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func request(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: APIHeader.authorization)
        // header 值只能是 ASCII：中文名稱以百分比編碼傳送，伺服器端解碼
        request.setValue(FilenameSanitizer.encodeHeader(clientName), forHTTPHeaderField: APIHeader.client)
        return request
    }

    // MARK: - API

    /// `GET /api/info`（「測試連線」使用）
    public func info() async throws -> ServerInfoDTO {
        let (data, status) = try await send(request(path: "api/info", method: "GET"))
        guard status == 200 else { throw ClientError.from(status: status, body: data) }
        guard let dto = try? JSONDecoder.mfConnect().decode(ServerInfoDTO.self, from: data) else {
            throw ClientError.invalidResponse
        }
        return dto
    }

    /// `GET /api/jobs/{id}`
    public func jobStatus(id: UUID) async throws -> JobStatusDTO {
        let (data, status) = try await send(request(path: "api/jobs/\(id.uuidString)", method: "GET"))
        guard status == 200 else { throw ClientError.from(status: status, body: data) }
        guard let dto = try? JSONDecoder.mfConnect().decode(JobStatusDTO.self, from: data) else {
            throw ClientError.invalidResponse
        }
        return dto
    }

    /// `POST /api/jobs`：以檔案 URL 串流上傳，不會把整個檔案載入記憶體。
    /// - Parameter progress: 0...1，於背景執行緒呼叫。
    public func upload(fileURL: URL, filename: String, options: JobOptions,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> JobCreatedDTO {
        var req = request(path: "api/jobs", method: "POST")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue(FilenameSanitizer.encodeHeader(filename), forHTTPHeaderField: APIHeader.filename)
        req.setValue(String(options.copies), forHTTPHeaderField: APIHeader.copies)
        req.setValue(options.duplex.rawValue, forHTTPHeaderField: APIHeader.duplex)
        req.setValue(options.color.rawValue, forHTTPHeaderField: APIHeader.color)
        let (data, status) = try await send(req, uploadFile: fileURL, progress: progress)
        guard status == 201 else { throw ClientError.from(status: status, body: data) }
        guard let dto = try? JSONDecoder.mfConnect().decode(JobCreatedDTO.self, from: data) else {
            throw ClientError.invalidResponse
        }
        return dto
    }

    // MARK: - 傳輸

    private func send(_ request: URLRequest, uploadFile: URL? = nil,
                      progress: (@Sendable (Double) -> Void)? = nil) async throws -> (Data, Int) {
        let delegate = TaskDelegate(progress: progress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, Int), any Error>) in
                delegate.continuation = continuation
                let task: URLSessionTask
                if let uploadFile {
                    task = session.uploadTask(with: request, fromFile: uploadFile)
                } else {
                    task = session.dataTask(with: request)
                }
                delegate.task = task
                task.resume()
            }
        } onCancel: {
            delegate.cancel()
        }
    }
}

/// 收集回應並回報上傳進度。同時適用於 Apple 平台與 Linux 的 FoundationNetworking。
private final class TaskDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let progress: (@Sendable (Double) -> Void)?
    private var data = Data()
    private var _continuation: CheckedContinuation<(Data, Int), any Error>?
    private var _task: URLSessionTask?

    init(progress: (@Sendable (Double) -> Void)?) {
        self.progress = progress
    }

    var continuation: CheckedContinuation<(Data, Int), any Error>? {
        get { lock.withLock { _continuation } }
        set { lock.withLock { _continuation = newValue } }
    }

    var task: URLSessionTask? {
        get { lock.withLock { _task } }
        set { lock.withLock { _task = newValue } }
    }

    func cancel() { task?.cancel() }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        progress?(min(Double(totalBytesSent) / Double(totalBytesExpectedToSend), 1))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock {
            // 回應只會是小型 JSON；設上限避免異常伺服器灌爆記憶體。
            if self.data.count < 1_000_000 { self.data.append(data) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (cont, body): (CheckedContinuation<(Data, Int), any Error>?, Data) = lock.withLock {
            let c = _continuation
            _continuation = nil
            return (c, data)
        }
        guard let cont else { return }
        if let error {
            cont.resume(throwing: ClientError.network((error as NSError).localizedDescription))
            return
        }
        guard let http = task.response as? HTTPURLResponse else {
            cont.resume(throwing: ClientError.invalidResponse)
            return
        }
        cont.resume(returning: (body, http.statusCode))
    }
}
