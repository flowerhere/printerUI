import Foundation
import Testing
@testable import MFConnectCore
@testable import MFConnectServer

/// 測試用：把事件收集起來。
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [JobQueue.Event] = []
    func append(_ e: JobQueue.Event) { lock.withLock { events.append(e) } }
    var needsApproval: Int { lock.withLock { events.filter { if case .needsApproval = $0 { true } else { false } }.count } }
    var failed: [PrintJob] { lock.withLock { events.compactMap { if case .failed(let j) = $0 { j } else { nil } } } }
}

/// 一律回報「卡紙」的列印服務，用來測試失敗流程。
actor JammedPrintService: PrintService {
    nonisolated var isDryRun: Bool { false }
    var cancelled: [String] = []
    func submit(fileURL: URL, title: String, options: JobOptions, printer: String?) async throws -> PrintSubmission {
        PrintSubmission(cupsJobID: "P-1", notes: ["測試"])
    }
    func progress(of submission: PrintSubmission, printer: String?) async -> PrintProgress { .blocked("印表機卡紙") }
    func cancel(_ submission: PrintSubmission, printer: String?) async { cancelled.append(submission.cupsJobID ?? "") }
}

func makeTempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("mfc-test-\(UUID().uuidString)", isDirectory: true)
}

/// 把假 PDF 放進 spool，模擬 UploadHandler 完成接收。
func stageUpload(_ store: JobStore, kind: FileKind = .pdf, name: String = "test.pdf") throws -> IncomingUpload {
    let id = UUID()
    try Data("%PDF-1.4\n%%EOF\n".utf8).write(to: store.fileURL(for: id, kind: kind))
    return IncomingUpload(id: id, displayName: name, kind: kind, byteCount: 15, sourceIP: "192.168.1.20", client: "test", options: JobOptions(copies: 2))
}

func waitUntil(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

@Suite("工作佇列")
struct JobQueueTests {
    @Test func approvalModeWaitsForApprovalThenPrints() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JobStore(rootDirectory: root)
        let printer = DryRunPrintService()
        let log = EventLog()
        let queue = JobQueue(store: store, printService: printer, configuration: .init(requireApproval: true, printerName: "Canon"), onEvent: log.append)
        await queue.start()

        let upload = try stageUpload(store)
        let job = try await queue.submit(upload)
        #expect(job.status == .pendingApproval)
        #expect(log.needsApproval == 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await printer.records.isEmpty) // 沒核准就不印

        try await queue.approve(job.id)
        #expect(await waitUntil { await queue.job(job.id)?.status == .done })
        let records = await printer.records
        #expect(records.count == 1)
        #expect(records.first?.options.copies == 2)
        #expect(records.first?.printer == "Canon")
        // 預設保留 0 小時 → 完成後立即刪除檔案
        #expect(await queue.job(job.id)?.fileDeleted == true)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: job.id, kind: .pdf).path))
    }

    @Test func autoModePrintsImmediately() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JobStore(rootDirectory: root)
        let printer = DryRunPrintService()
        let queue = JobQueue(store: store, printService: printer, configuration: .init(requireApproval: false, fileRetentionHours: 2))
        await queue.start()
        let job = try await queue.submit(try stageUpload(store))
        #expect(job.status == .queued)
        #expect(await waitUntil { await queue.job(job.id)?.status == .done })
        // 保留 2 小時 → 檔案仍在
        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: job.id, kind: .pdf).path))
        await queue.purgeExpired(now: Date().addingTimeInterval(3 * 3600))
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: job.id, kind: .pdf).path))
        // 紀錄保留 30 天
        await queue.purgeExpired(now: Date().addingTimeInterval(31 * 86400))
        #expect(await queue.job(job.id) == nil)
    }

    @Test func rejectDeletesFile() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JobStore(rootDirectory: root)
        let queue = JobQueue(store: store, printService: DryRunPrintService())
        await queue.start()
        let job = try await queue.submit(try stageUpload(store))
        try await queue.reject(job.id)
        #expect(await queue.job(job.id)?.status == .rejected)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: job.id, kind: .pdf).path))
        await #expect(throws: QueueError.invalidTransition(from: .rejected, to: .queued)) { try await queue.approve(job.id) }
        await #expect(throws: QueueError.notFound) { try await queue.approve(UUID()) }
    }

    @Test func queueFull() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JobStore(rootDirectory: root)
        let queue = JobQueue(store: store, printService: DryRunPrintService(), configuration: .init(requireApproval: true, maxQueueLength: 2))
        await queue.start()
        _ = try await queue.submit(try stageUpload(store))
        _ = try await queue.submit(try stageUpload(store))
        #expect(await queue.hasCapacity == false)
        await #expect(throws: QueueError.queueFull) { _ = try await queue.submit(try stageUpload(store)) }
    }

    @Test func printerErrorMarksFailedCancelsAndAllowsRetry() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JobStore(rootDirectory: root)
        let jammed = JammedPrintService()
        let log = EventLog()
        let queue = JobQueue(store: store, printService: jammed,
                             configuration: .init(requireApproval: false, pollInterval: .milliseconds(10), blockedPollsBeforeFailure: 3),
                             onEvent: log.append)
        await queue.start()
        let job = try await queue.submit(try stageUpload(store))
        #expect(await waitUntil { await queue.job(job.id)?.status == .failed })
        let failed = await queue.job(job.id)
        #expect(failed?.message?.contains("卡紙") == true)
        #expect(failed?.notes == ["測試"])
        #expect(await jammed.cancelled == ["P-1"])
        #expect(log.failed.count == 1)
        // 失敗的檔案保留以便重試
        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: job.id, kind: .pdf).path))

        await queue.setPrintService(DryRunPrintService())
        try await queue.retry(job.id)
        #expect(await waitUntil { await queue.job(job.id)?.status == .done })
    }

    @Test func recordsPersistAndInterruptedJobsBecomeFailed() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JobStore(rootDirectory: root)
        let queue = JobQueue(store: store, printService: DryRunPrintService())
        await queue.start()
        let pending = try await queue.submit(try stageUpload(store, name: "保留.pdf"))
        await queue.flush()

        // 模擬重新啟動：寫入一筆「列印中」的紀錄
        var printing = PrintJob(displayName: "中斷.pdf", fileKind: .pdf, byteCount: 1, sourceIP: "x", client: "x", status: .queued, options: JobOptions())
        try printing.transition(to: .printing)
        try await store.saveJobs(await queue.snapshot() + [printing])
        // 殘留的 .part 檔應被清除
        let orphan = store.partialURL(for: UUID())
        try Data("x".utf8).write(to: orphan)

        let store2 = try JobStore(rootDirectory: root)
        let queue2 = JobQueue(store: store2, printService: DryRunPrintService())
        await queue2.start()
        #expect(await queue2.job(pending.id)?.status == .pendingApproval)
        #expect(await queue2.job(pending.id)?.displayName == "保留.pdf")
        #expect(await queue2.job(printing.id)?.status == .failed)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: store2.fileURL(for: pending.id, kind: .pdf).path))
    }
}
