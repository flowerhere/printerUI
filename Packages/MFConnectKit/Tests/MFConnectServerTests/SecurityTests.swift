import Foundation
import Testing
@testable import MFConnectServer

@Suite("Token 驗證與鎖定")
struct AccessGuardTests {
    let token = "correct-token-0123456789abcdefghijklmnopq"

    @Test func generatedTokensAreRandomAndLongEnough() {
        let a = TokenGenerator.generate()
        let b = TokenGenerator.generate()
        #expect(a != b)
        #expect(a.count == 43) // 32 bytes base64url，無 padding
        #expect(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test func constantTimeEquals() {
        #expect(ConstantTime.equals(Array("abc".utf8), Array("abc".utf8)))
        #expect(!ConstantTime.equals(Array("abc".utf8), Array("abd".utf8)))
        #expect(!ConstantTime.equals(Array("abc".utf8), Array("abcd".utf8)))
        #expect(!ConstantTime.equals(Array("".utf8), Array("a".utf8)))
        #expect(ConstantTime.equals([UInt8](), [UInt8]()))
    }

    @Test func acceptsCorrectBearer() async {
        let guardian = AccessGuard(token: token)
        #expect(await guardian.authorize(authorizationHeader: "Bearer \(token)", ip: "10.0.0.2") == .allowed)
        #expect(await guardian.authorize(authorizationHeader: "bearer \(token)", ip: "10.0.0.2") == .allowed)
    }

    @Test(arguments: [nil, "", "Bearer", "Bearer ", "Basic \("x")", "Bearer wrong", "Token correct-token"])
    func rejectsBadHeaders(header: String?) async {
        let guardian = AccessGuard(token: token)
        #expect(await guardian.authorize(authorizationHeader: header, ip: "10.0.0.2") == .unauthorized)
    }

    @Test func locksAfterFiveFailuresForTenMinutes() async {
        let guardian = AccessGuard(token: token)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<4 {
            #expect(await guardian.authorize(authorizationHeader: "Bearer nope", ip: "10.0.0.9", now: t0 + Double(i)) == .unauthorized)
        }
        // 第 5 次失敗 → 鎖定
        #expect(await guardian.authorize(authorizationHeader: "Bearer nope", ip: "10.0.0.9", now: t0 + 5) == .tooManyRequests(retryAfter: 600))
        // 鎖定期間，即使 token 正確也拒絕
        let locked = await guardian.authorize(authorizationHeader: "Bearer \(token)", ip: "10.0.0.9", now: t0 + 300)
        #expect(locked == .tooManyRequests(retryAfter: 305))
        // 其他 IP 不受影響
        #expect(await guardian.authorize(authorizationHeader: "Bearer \(token)", ip: "10.0.0.10", now: t0 + 300) == .allowed)
        #expect(await guardian.lockedIPs(now: t0 + 300) == ["10.0.0.9"])
        // 10 分鐘後解鎖
        #expect(await guardian.authorize(authorizationHeader: "Bearer \(token)", ip: "10.0.0.9", now: t0 + 606) == .allowed)
    }

    @Test func successResetsFailureCount() async {
        let guardian = AccessGuard(token: token)
        for _ in 0..<4 { _ = await guardian.authorize(authorizationHeader: "Bearer x", ip: "1.1.1.1") }
        #expect(await guardian.authorize(authorizationHeader: "Bearer \(token)", ip: "1.1.1.1") == .allowed)
        for _ in 0..<4 {
            #expect(await guardian.authorize(authorizationHeader: "Bearer x", ip: "1.1.1.1") == .unauthorized)
        }
    }

    @Test func rotationInvalidatesOldTokenImmediately() async {
        let guardian = AccessGuard(token: token)
        let newToken = TokenGenerator.generate()
        await guardian.rotate(to: newToken)
        #expect(await guardian.authorize(authorizationHeader: "Bearer \(token)", ip: "1.1.1.1") == .unauthorized)
        #expect(await guardian.authorize(authorizationHeader: "Bearer \(newToken)", ip: "1.1.1.1") == .allowed)
    }

    @Test func uploadRateLimit() async {
        let guardian = AccessGuard(token: token, policy: .init(maxUploadsPerWindow: 3, uploadWindow: 60))
        let t0 = Date(timeIntervalSince1970: 0)
        for i in 0..<3 {
            #expect(await guardian.registerUpload(ip: "2.2.2.2", now: t0 + Double(i)) == .allowed)
        }
        #expect(await guardian.registerUpload(ip: "2.2.2.2", now: t0 + 10) == .tooManyRequests(retryAfter: 50))
        #expect(await guardian.registerUpload(ip: "2.2.2.2", now: t0 + 61) == .allowed)
    }

    @Test func inMemoryTokenStoreRoundTrip() throws {
        let store = InMemoryTokenStore()
        #expect(try store.load() == nil)
        try store.save("abc")
        #expect(try store.load() == "abc")
    }
}

@Suite("大小限制（串流）")
struct SizeLimitTests {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mfc-\(UUID().uuidString).part")
    }

    @Test func writesWithinLimitAndKeepsHeader() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try SizeLimitedFileWriter(url: url, limit: 100)
        try writer.append(Array("%PDF-1.4".utf8))
        try writer.append([UInt8](repeating: 0x41, count: 92))
        writer.close()
        #expect(writer.bytesWritten == 100)
        #expect(writer.header.count == 16)
        #expect(Array(writer.header.prefix(5)) == Array("%PDF-".utf8))
        #expect(try Data(contentsOf: url).count == 100)
    }

    @Test func throwsWhenStreamExceedsLimitMidway() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try SizeLimitedFileWriter(url: url, limit: 1000)
        // 模擬沒有 Content-Length（chunked）的串流：每塊 300 bytes
        let chunks = AsyncStream<[UInt8]> { continuation in
            for _ in 0..<10 { continuation.yield([UInt8](repeating: 0x42, count: 300)) }
            continuation.finish()
        }
        var received = 0
        await #expect(throws: SizeLimitedFileWriter.WriteError.limitExceeded(limit: 1000)) {
            for await chunk in chunks {
                received += 1
                try writer.append(chunk)
            }
        }
        writer.close()
        // 第 4 塊（累計 1200）時就停止，不會讀完整個串流
        #expect(received == 4)
        #expect(writer.bytesWritten == 900)
        #expect(try Data(contentsOf: url).count == 900)
    }

    @Test func exactLimitIsAllowed() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try SizeLimitedFileWriter(url: url, limit: 10)
        try writer.append([UInt8](repeating: 1, count: 10))
        #expect(throws: SizeLimitedFileWriter.WriteError.limitExceeded(limit: 10)) { try writer.append([1]) }
    }
}

@Suite("儲存路徑")
struct JobStoreTests {
    @Test func filesAreNamedByUUIDInsideSpool() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mfc-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JobStore(rootDirectory: root)
        let id = UUID()
        let url = store.fileURL(for: id, kind: .pdf)
        #expect(url.lastPathComponent == "\(id.uuidString).pdf")
        #expect(url.deletingLastPathComponent().standardizedFileURL == store.spoolDirectory.standardizedFileURL)
        try store.validateInsideSpool(url)
        #expect(throws: JobStore.StoreError.self) {
            try store.validateInsideSpool(store.spoolDirectory.appendingPathComponent("../jobs.json"))
        }
        #expect(throws: JobStore.StoreError.self) {
            try store.validateInsideSpool(URL(fileURLWithPath: "/etc/passwd"))
        }
    }
}
