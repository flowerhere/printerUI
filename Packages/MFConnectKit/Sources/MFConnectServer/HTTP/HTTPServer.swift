import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdCore
import Logging
import MFConnectCore
import NIOCore
import ServiceLifecycle

/// 每個請求的 context：額外保存 channel，以取得來源 IP 與在必要時中斷連線。
public struct MFRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    public let channel: any Channel

    public init(source: ApplicationRequestContextSource) {
        self.coreContext = .init(source: source)
        self.channel = source.channel
    }

    /// 來源 IP（IPv4-mapped IPv6 會轉成一般 IPv4 表示）。
    public var remoteIP: String {
        guard let ip = channel.remoteAddress?.ipAddress else { return "unknown" }
        return ip.hasPrefix("::ffff:") ? String(ip.dropFirst(7)) : ip
    }
}

/// 伺服器在執行期間會讀取的設定與 token（可即時更新，不需重啟）。
public final class ServerRuntimeState: @unchecked Sendable {
    private let lock = NSLock()
    private var _settings: ServerSettings

    public init(settings: ServerSettings) {
        self._settings = settings
    }

    public var settings: ServerSettings {
        get { lock.withLock { _settings } }
        set { lock.withLock { _settings = newValue } }
    }
}

/// HTTP 伺服器（Hummingbird 2）。
///
/// 路由：
/// - `GET /`              內嵌上傳頁
/// - `GET /api/info`      伺服器資訊（需驗證）
/// - `POST /api/jobs`     上傳（原始 body，需驗證）
/// - `GET /api/jobs/{id}` 查詢狀態（需驗證）
public actor MFConnectHTTPServer {
    public nonisolated let state: ServerRuntimeState
    public nonisolated let accessGuard: AccessGuard
    public nonisolated let queue: JobQueue
    private let logger: Logger
    private var serviceGroup: ServiceGroup?
    private var runTask: Task<Void, Never>?
    public private(set) var boundPort: Int?

    public init(state: ServerRuntimeState, accessGuard: AccessGuard, queue: JobQueue, logger: Logger = Logger(label: "MFConnect.HTTP")) {
        self.state = state
        self.accessGuard = accessGuard
        self.queue = queue
        self.logger = logger
    }

    public var isRunning: Bool { runTask != nil }

    /// 啟動伺服器。
    /// - Parameters:
    ///   - host: `0.0.0.0` = 所有網卡；或指定介面的 IP。
    ///   - port: 0 = 隨機連接埠（測試用）。
    /// - Returns: 實際綁定的連接埠。
    @discardableResult
    public func start(host: String, port: Int) async throws -> Int {
        if runTask != nil { await stop() }
        let settings = state.settings
        let router = Self.buildRouter(state: state, accessGuard: accessGuard, queue: queue)
        let (stream, continuation) = AsyncStream<Result<Int, any Error>>.makeStream()

        let app = Application(
            router: router,
            server: .http1(configuration: .init(idleTimeout: .seconds(Int64(settings.idleTimeoutSeconds)))),
            configuration: .init(
                address: .hostname(host, port: port),
                serverName: nil,
                availableConnectionsDelegate: MaximumAvailableConnections(settings.maxConnections)
            ),
            onServerRunning: { channel in
                continuation.yield(.success(channel.localAddress?.port ?? port))
            },
            logger: logger
        )
        let group = ServiceGroup(configuration: .init(services: [app], gracefulShutdownSignals: [], logger: logger))
        serviceGroup = group
        runTask = Task {
            do {
                try await group.run()
            } catch {
                continuation.yield(.failure(error))
            }
            continuation.finish()
        }
        for await result in stream {
            switch result {
            case .success(let bound):
                boundPort = bound
                return bound
            case .failure(let error):
                runTask = nil
                serviceGroup = nil
                throw error
            }
        }
        runTask = nil
        serviceGroup = nil
        throw APIError.internalError("伺服器未能啟動")
    }

    public func stop() async {
        guard let group = serviceGroup, let task = runTask else { return }
        await group.triggerGracefulShutdown()
        // 進行中的上傳最多等 5 秒，之後強制結束。
        let killer = Task {
            try? await Task.sleep(for: .seconds(5))
            task.cancel()
        }
        await task.value
        killer.cancel()
        serviceGroup = nil
        runTask = nil
        boundPort = nil
    }

    // MARK: - Router

    static func buildRouter(state: ServerRuntimeState, accessGuard: AccessGuard, queue: JobQueue) -> Router<MFRequestContext> {
        let router = Router(context: MFRequestContext.self)
        router.add(middleware: SecurityHeadersMiddleware())
        router.add(middleware: APIErrorMiddleware())

        router.get("/") { _, _ -> Response in
            Response(
                status: .ok,
                headers: [
                    .contentType: "text/html; charset=utf-8",
                    .cacheControl: "no-store",
                ],
                body: .init(byteBuffer: ByteBuffer(string: UploadPage.html))
            )
        }

        let api = router.group("api").add(middleware: AuthMiddleware(accessGuard: accessGuard))

        api.get("info") { _, _ -> Response in
            let settings = state.settings
            let dto = ServerInfoDTO(
                serverName: settings.serverName,
                allowedFormats: FileKind.allCases.map(\.mimeType),
                maxUploadBytes: settings.maxUploadBytes,
                requiresApproval: settings.requireApproval
            )
            return try jsonResponse(dto)
        }

        api.post("jobs") { request, context -> Response in
            try await UploadHandler(state: state, accessGuard: accessGuard, queue: queue)
                .handle(request: request, context: context)
        }

        api.get("jobs/:id") { _, context -> Response in
            guard let raw = context.parameters.get("id"), let id = UUID(uuidString: raw),
                  let job = await queue.job(id) else {
                throw APIError.notFound
            }
            return try jsonResponse(job.statusDTO)
        }

        return router
    }
}

func jsonResponse<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
    let data = try JSONEncoder.mfConnect().encode(value)
    return Response(
        status: status,
        headers: [.contentType: "application/json; charset=utf-8", .cacheControl: "no-store"],
        body: .init(byteBuffer: ByteBuffer(bytes: data))
    )
}

// MARK: - Middleware

/// 把 ``APIError`` 轉成 JSON 回應；需要時關閉連線的讀取端，讓伺服器不再接收（或排空）剩餘的上傳內容。
struct APIErrorMiddleware: RouterMiddleware {
    typealias Context = MFRequestContext

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        do {
            return try await next(request, context)
        } catch let error as APIError {
            if error.closeConnection {
                let channel = context.channel
                channel.close(mode: .input).whenFailure { _ in
                    channel.close(promise: nil)
                }
            }
            return error.response()
        } catch let error as HTTPError where error.status == .notFound {
            return APIError.notFound.response()
        }
    }
}

/// 所有回應都加上基本的安全 header。上傳頁的 CSP 禁止載入任何外部資源。
struct SecurityHeadersMiddleware: RouterMiddleware {
    typealias Context = MFRequestContext

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        var response = try await next(request, context)
        response.headers[.contentSecurityPolicy] =
            "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; connect-src 'self'; form-action 'none'; frame-ancestors 'none'; base-uri 'none'"
        response.headers[.xContentTypeOptions] = "nosniff"
        response.headers[HTTPField.Name("X-Frame-Options")!] = "DENY"
        response.headers[HTTPField.Name("Referrer-Policy")!] = "no-referrer"
        return response
    }
}

/// `/api/*` 一律需要 `Authorization: Bearer <token>`。
struct AuthMiddleware: RouterMiddleware {
    typealias Context = MFRequestContext
    let accessGuard: AccessGuard

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        // POST 帶有 body：驗證失敗時直接斷線，不接收內容。
        let hasBody = request.method == .post
        switch await accessGuard.authorize(authorizationHeader: request.headers[.authorization], ip: context.remoteIP) {
        case .allowed:
            return try await next(request, context)
        case .unauthorized:
            throw APIError.unauthorized(close: hasBody)
        case .tooManyRequests(let retryAfter):
            throw APIError.tooManyRequests(retryAfter: retryAfter, close: hasBody)
        }
    }
}
