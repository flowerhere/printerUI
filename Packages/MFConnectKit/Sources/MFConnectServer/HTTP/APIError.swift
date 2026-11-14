import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdCore
import MFConnectCore

/// API 錯誤；由 ``APIErrorMiddleware`` 轉成 JSON 回應。
public struct APIError: Error, Sendable {
    public var status: HTTPResponse.Status
    public var code: String
    public var message: String
    /// 回應後關閉連線（避免繼續接收、或排空超大的上傳內容）。
    public var closeConnection: Bool
    public var retryAfter: Int?

    public init(status: Int, reason: String, code: String, message: String, closeConnection: Bool = false, retryAfter: Int? = nil) {
        self.status = HTTPResponse.Status(code: status, reasonPhrase: reason)
        self.code = code
        self.message = message
        self.closeConnection = closeConnection
        self.retryAfter = retryAfter
    }

    public static func badRequest(_ message: String, close: Bool = false) -> APIError {
        APIError(status: 400, reason: "Bad Request", code: "bad_request", message: message, closeConnection: close)
    }

    public static func unauthorized(close: Bool = false) -> APIError {
        APIError(status: 401, reason: "Unauthorized", code: "unauthorized", message: "token 錯誤或未提供", closeConnection: close)
    }

    public static let notFound = APIError(status: 404, reason: "Not Found", code: "not_found", message: "找不到資源")

    public static func requestTimeout() -> APIError {
        APIError(status: 408, reason: "Request Timeout", code: "timeout", message: "上傳逾時", closeConnection: true)
    }

    public static func payloadTooLarge(limit: Int64) -> APIError {
        let mb = Double(limit) / 1_048_576
        return APIError(status: 413, reason: "Content Too Large", code: "payload_too_large",
                        message: String(format: "檔案超過大小上限 %.0f MB", mb), closeConnection: true)
    }

    public static func unsupportedMediaType() -> APIError {
        APIError(status: 415, reason: "Unsupported Media Type", code: "unsupported_media_type",
                 message: "只支援 PDF、JPEG、PNG、HEIC")
    }

    public static func tooManyRequests(retryAfter: Int, close: Bool = false) -> APIError {
        APIError(status: 429, reason: "Too Many Requests", code: "too_many_requests",
                 message: "嘗試次數太多，請 \(Int((Double(retryAfter) / 60).rounded(.up))) 分鐘後再試",
                 closeConnection: close, retryAfter: retryAfter)
    }

    public static func queueFull(close: Bool = false) -> APIError {
        APIError(status: 503, reason: "Service Unavailable", code: "queue_full",
                 message: "列印佇列已滿，請稍後再試", closeConnection: close, retryAfter: 60)
    }

    public static func internalError(_ message: String) -> APIError {
        APIError(status: 500, reason: "Internal Server Error", code: "internal_error", message: message, closeConnection: true)
    }

    func response() -> Response {
        let dto = APIErrorDTO(error: code, message: message)
        let data = (try? JSONEncoder.mfConnect().encode(dto)) ?? Data("{}".utf8)
        var headers: HTTPFields = [.contentType: "application/json; charset=utf-8"]
        if let retryAfter { headers[.retryAfter] = String(retryAfter) }
        if closeConnection { headers[.connection] = "close" }
        return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }
}
