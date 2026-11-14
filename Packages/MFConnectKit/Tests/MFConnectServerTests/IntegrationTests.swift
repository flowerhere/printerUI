import Foundation
import Testing
@testable import MFConnectClient
@testable import MFConnectCore
@testable import MFConnectServer
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// 在隨機連接埠啟動完整的伺服器（DryRunPrintService），測試結束後關閉。
struct TestServer {
    let server: MFConnectHTTPServer
    let queue: JobQueue
    let store: JobStore
    let printer: DryRunPrintService
    let token: String
    let port: Int
    let root: URL
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    static func start(settings: ServerSettings = ServerSettings(), policy: AccessGuard.Policy = .init()) async throws -> TestServer {
        let root = makeTempRoot()
        let store = try JobStore(rootDirectory: root)
        let printer = DryRunPrintService()
        let queue = JobQueue(store: store, printService: printer, configuration: .init(settings: settings))
        await queue.start()
        let token = TokenGenerator.generate()
        let server = MFConnectHTTPServer(
            state: ServerRuntimeState(settings: settings),
            accessGuard: AccessGuard(token: token, policy: policy),
            queue: queue
        )
        let port = try await server.start(host: "127.0.0.1", port: 0)
        return TestServer(server: server, queue: queue, store: store, printer: printer, token: token, port: port, root: root)
    }

    func stop() async {
        await server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func client(token: String? = nil) -> MFConnectClient {
        MFConnectClient(baseURL: baseURL, token: token ?? self.token, clientName: "整合測試")
    }

    func writeTemp(_ data: Data, ext: String = "pdf") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mfc-upload-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return url
    }

    func spoolFiles() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: store.spoolDirectory.path)) ?? []
    }
}

let fakePDF = Data("%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n".utf8)

/// 最小的原始 TCP 用戶端：送出指定位元組後讀取回應（用來測「只送 header 就被拒」的情境）。
func rawHTTP(port: Int, request: String, body: Data = Data(), readTimeout: Int = 3) -> String {
    #if canImport(Darwin)
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #else
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard fd >= 0 else { return "" }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else { return "" }
    var tv = timeval(tv_sec: readTimeout, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let bytes = Array(request.utf8) + Array(body)
    _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    var response = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = recv(fd, &buffer, buffer.count, 0)
        if n <= 0 { break }
        response.append(contentsOf: buffer[0..<n])
    }
    return String(decoding: response, as: UTF8.self)
}

func statusCode(of request: URLRequest) async throws -> (Int, Data, HTTPURLResponse) {
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = response as! HTTPURLResponse
    return (http.statusCode, data, http)
}

@Suite("整合測試：伺服器 + URLSession + DryRun", .serialized)
struct IntegrationTests {
    @Test func uploadPDFIsPrintedByDryRun() async throws {
        var settings = ServerSettings()
        settings.requireApproval = false
        settings.printerName = "Canon_Test"
        let s = try await TestServer.start(settings: settings)
        defer { Task { await s.stop() } }

        let file = try s.writeTemp(fakePDF)
        defer { try? FileManager.default.removeItem(at: file) }
        let progress = MutableBox<Double>(0)
        let created = try await s.client().upload(
            fileURL: file, filename: "期末報告 (final).pdf",
            options: JobOptions(copies: 3, duplex: .long, color: .mono),
            progress: { progress.value = $0 }
        )
        #expect(created.status == .queued)

        #expect(await waitUntil { (try? await s.client().jobStatus(id: created.id))?.status == .done })
        let status = try await s.client().jobStatus(id: created.id)
        #expect(status.statusText == "完成")
        #expect(status.filename == "期末報告 (final).pdf")

        let records = await s.printer.records
        #expect(records.count == 1)
        #expect(records[0].options == JobOptions(copies: 3, duplex: .long, color: .mono))
        #expect(records[0].printer == "Canon_Test")
        #expect(records[0].fileSize == Int64(fakePDF.count))
        #expect(records[0].fileURL.lastPathComponent == "\(created.id.uuidString).pdf")

        let job = try #require(await s.queue.job(created.id))
        #expect(job.sourceIP == "127.0.0.1")
        #expect(job.client.hasPrefix("整合測試"))
        #expect(s.spoolFiles().isEmpty) // 完成後立即刪除
    }

    @Test func approvalModeKeepsJobPending() async throws {
        let s = try await TestServer.start()
        defer { Task { await s.stop() } }
        let file = try s.writeTemp(fakePDF)
        defer { try? FileManager.default.removeItem(at: file) }

        let created = try await s.client().upload(fileURL: file, filename: "a.pdf", options: JobOptions())
        #expect(created.status == .pendingApproval)
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await s.client().jobStatus(id: created.id).status == .pendingApproval)
        #expect(await s.printer.records.isEmpty)

        try await s.queue.approve(created.id)
        #expect(await waitUntil { (try? await s.client().jobStatus(id: created.id))?.status == .done })
    }

    @Test func infoAndUploadPage() async throws {
        let s = try await TestServer.start()
        defer { Task { await s.stop() } }

        let info = try await s.client().info()
        #expect(info.maxUploadBytes == 50 * 1024 * 1024)
        #expect(info.requiresApproval)
        #expect(info.allowedFormats.contains("application/pdf"))

        let (code, data, response) = try await statusCode(of: URLRequest(url: s.baseURL))
        #expect(code == 200)
        let html = String(decoding: data, as: UTF8.self)
        #expect(html.contains("MFConnect 列印"))
        // 不載入任何外部資源
        #expect(!html.contains("src=\"http"))
        #expect(!html.contains("href=\"http"))
        #expect(!html.contains("@import"))
        #expect(response.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("default-src 'none'") == true)
        #expect(response.value(forHTTPHeaderField: "X-Content-Type-Options") == "nosniff")
    }

    @Test func unauthorizedAndLockout() async throws {
        let s = try await TestServer.start()
        defer { Task { await s.stop() } }

        var noAuth = URLRequest(url: s.baseURL.appendingPathComponent("api/info"))
        noAuth.httpMethod = "GET"
        let (code, body, _) = try await statusCode(of: noAuth)
        #expect(code == 401)
        #expect(try JSONDecoder().decode(APIErrorDTO.self, from: body).error == "unauthorized")

        // 已累計 1 次，再錯 3 次仍是 401，第 5 次變 429
        for _ in 0..<3 {
            await #expect(throws: ClientError.unauthorized) { _ = try await s.client(token: "wrong").info() }
        }
        await #expect(throws: ClientError.self) { _ = try await s.client(token: "wrong").info() }
        // 鎖定後，正確 token 也被擋
        do {
            _ = try await s.client().info()
            Issue.record("應該被鎖定")
        } catch let error as ClientError {
            guard case .tooManyRequests = error else { Issue.record("預期 429，得到 \(error)"); return }
        }
        // 狀態查詢也要驗證
        var statusReq = URLRequest(url: s.baseURL.appendingPathComponent("api/jobs/\(UUID().uuidString)"))
        statusReq.setValue("Bearer \(s.token)", forHTTPHeaderField: "Authorization")
        #expect(try await statusCode(of: statusReq).0 == 429)
    }

    @Test func unsupportedFormatIsRejectedByMagicBytes() async throws {
        let s = try await TestServer.start()
        defer { Task { await s.stop() } }
        // 副檔名與檔名都是 .pdf，但內容是 HTML
        let file = try s.writeTemp(Data("<html><script>alert(1)</script></html>".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        await #expect(throws: ClientError.unsupportedMediaType) {
            _ = try await s.client().upload(fileURL: file, filename: "fake.pdf", options: JobOptions())
        }
        #expect(await s.queue.snapshot().isEmpty)
        #expect(s.spoolFiles().isEmpty)
    }

    @Test func invalidOptionsReturn400() async throws {
        let s = try await TestServer.start()
        defer { Task { await s.stop() } }
        var req = URLRequest(url: s.baseURL.appendingPathComponent("api/jobs"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(s.token)", forHTTPHeaderField: "Authorization")
        req.setValue("100", forHTTPHeaderField: "X-Copies")
        req.httpBody = fakePDF
        let (code, body, _) = try await statusCode(of: req)
        #expect(code == 400)
        #expect(String(decoding: body, as: UTF8.self).contains("份數"))
    }

    @Test func pathTraversalFilenameIsOnlyForDisplay() async throws {
        var settings = ServerSettings()
        settings.fileRetentionHours = 1
        let s = try await TestServer.start(settings: settings)
        defer { Task { await s.stop() } }
        let file = try s.writeTemp(fakePDF)
        defer { try? FileManager.default.removeItem(at: file) }
        let created = try await s.client().upload(fileURL: file, filename: "../../../../etc/passwd", options: JobOptions())
        let job = try #require(await s.queue.job(created.id))
        #expect(job.displayName == "passwd")
        #expect(s.spoolFiles() == ["\(created.id.uuidString).pdf"])
    }

    @Test func contentLengthOverLimitIsRejectedBeforeBody() async throws {
        var settings = ServerSettings()
        settings.maxUploadBytes = 1024 * 1024
        let s = try await TestServer.start(settings: settings)
        defer { Task { await s.stop() } }
        // 只送 header（宣稱 2 GB），伺服器不應等待 body，直接回 413 並斷線
        let response = rawHTTP(port: s.port, request:
            "POST /api/jobs HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer \(s.token)\r\nContent-Length: 2147483648\r\n\r\n")
        #expect(response.hasPrefix("HTTP/1.1 413"))
        #expect(response.lowercased().contains("connection: close"))
        #expect(await s.queue.snapshot().isEmpty)
    }

    @Test func wrongTokenOnUploadDoesNotReadBody() async throws {
        let s = try await TestServer.start()
        defer { Task { await s.stop() } }
        let response = rawHTTP(port: s.port, request:
            "POST /api/jobs HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer nope\r\nContent-Length: 10000000\r\n\r\n")
        #expect(response.hasPrefix("HTTP/1.1 401"))
    }

    @Test func streamExceedingLimitWithoutContentLengthIsCutOff() async throws {
        var settings = ServerSettings()
        settings.maxUploadBytes = 1024 * 1024
        let s = try await TestServer.start(settings: settings)
        defer { Task { await s.stop() } }

        // chunked：沒有 Content-Length，只能邊收邊數
        var body = Data()
        let chunk = Data(repeating: 0x41, count: 64 * 1024)
        var first = fakePDF
        first.append(chunk)
        for piece in [first] + Array(repeating: chunk, count: 40) { // 約 2.6 MB
            body.append(Data(String(piece.count, radix: 16).utf8) + Data("\r\n".utf8) + piece + Data("\r\n".utf8))
        }
        body.append(Data("0\r\n\r\n".utf8))
        let response = rawHTTP(port: s.port, request:
            "POST /api/jobs HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer \(s.token)\r\nTransfer-Encoding: chunked\r\n\r\n", body: body)
        // 伺服器可能在回 413 之後才斷線，也可能在用戶端還在送資料時就斷線（RST），兩者皆可接受
        #expect(response.isEmpty || response.hasPrefix("HTTP/1.1 413"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await s.queue.snapshot().isEmpty)
        #expect(s.spoolFiles().isEmpty) // 暫存檔已刪除
    }

    @Test func queueFullReturns503() async throws {
        var settings = ServerSettings()
        settings.maxQueueLength = 1
        let s = try await TestServer.start(settings: settings)
        defer { Task { await s.stop() } }
        let file = try s.writeTemp(fakePDF)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await s.client().upload(fileURL: file, filename: "1.pdf", options: JobOptions())
        await #expect(throws: ClientError.queueFull) {
            _ = try await s.client().upload(fileURL: file, filename: "2.pdf", options: JobOptions())
        }
        #expect(await s.queue.snapshot().count == 1)
    }

    @Test func unknownJobIs404() async throws {
        let s = try await TestServer.start()
        defer { Task { await s.stop() } }
        await #expect(throws: ClientError.server(status: 404, message: "找不到資源")) {
            _ = try await s.client().jobStatus(id: UUID())
        }
        var req = URLRequest(url: s.baseURL.appendingPathComponent("api/jobs/..%2F..%2Fjobs.json"))
        req.setValue("Bearer \(s.token)", forHTTPHeaderField: "Authorization")
        #expect(try await statusCode(of: req).0 == 404)
    }

    @Test func tokenRotationTakesEffectImmediately() async throws {
        let s = try await TestServer.start()
        defer { Task { await s.stop() } }
        _ = try await s.client().info()
        let newToken = TokenGenerator.generate()
        await s.server.accessGuard.rotate(to: newToken)
        await #expect(throws: ClientError.unauthorized) { _ = try await s.client().info() }
        _ = try await s.client(token: newToken).info()
    }

    @Test func normalizeServerURL() {
        #expect(MFConnectClient.normalizeServerURL("mac-mini.local")?.absoluteString == "http://mac-mini.local:8631")
        #expect(MFConnectClient.normalizeServerURL("192.168.1.5:9000/")?.absoluteString == "http://192.168.1.5:9000")
        #expect(MFConnectClient.normalizeServerURL("http://a.local:8631/api?x=1")?.absoluteString == "http://a.local:8631")
        #expect(MFConnectClient.normalizeServerURL("") == nil)
        #expect(MFConnectClient.normalizeServerURL("ftp://x") == nil)
    }
}
