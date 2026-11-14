import Foundation
import MFConnectCore

/// 已完整接收、通過格式檢查並存到 spool 的上傳檔案。
public struct IncomingUpload: Sendable {
    public var id: UUID
    public var displayName: String
    public var kind: FileKind
    public var byteCount: Int64
    public var sourceIP: String
    public var client: String
    public var options: JobOptions

    public init(id: UUID, displayName: String, kind: FileKind, byteCount: Int64, sourceIP: String, client: String, options: JobOptions) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.byteCount = byteCount
        self.sourceIP = sourceIP
        self.client = client
        self.options = options
    }
}

public enum QueueError: Error, Equatable, Sendable, CustomStringConvertible {
    case queueFull
    case notFound
    case invalidTransition(from: JobStatus, to: JobStatus)
    case fileMissing

    public var description: String {
        switch self {
        case .queueFull: "佇列已滿"
        case .notFound: "找不到工作"
        case .invalidTransition(let from, let to): "無法從「\(from.displayName)」變成「\(to.displayName)」"
        case .fileMissing: "檔案已刪除，無法重新列印"
        }
    }
}

/// 列印工作佇列：一次只印一件，依建立時間先後處理。
public actor JobQueue {
    public enum Event: Sendable {
        case jobsChanged([PrintJob])
        case needsApproval(PrintJob)
        case completed(PrintJob)
        case failed(PrintJob)
    }

    public struct Configuration: Sendable, Equatable {
        public var requireApproval: Bool
        public var maxQueueLength: Int
        public var printerName: String?
        public var fileRetentionHours: Int
        public var recordRetentionDays: Int
        /// 送印後多久查一次狀態。
        public var pollInterval: Duration
        /// 連續幾次偵測到缺紙 / 卡紙等錯誤才判定失敗（避免短暫狀態誤判）。
        public var blockedPollsBeforeFailure: Int
        /// 送印後最長等待時間。
        public var printTimeout: Duration

        public init(requireApproval: Bool = true, maxQueueLength: Int = MFConnectConstants.defaultMaxQueueLength,
                    printerName: String? = nil, fileRetentionHours: Int = 0, recordRetentionDays: Int = 30,
                    pollInterval: Duration = .seconds(3), blockedPollsBeforeFailure: Int = 3,
                    printTimeout: Duration = .seconds(30 * 60)) {
            self.requireApproval = requireApproval
            self.maxQueueLength = maxQueueLength
            self.printerName = printerName
            self.fileRetentionHours = fileRetentionHours
            self.recordRetentionDays = recordRetentionDays
            self.pollInterval = pollInterval
            self.blockedPollsBeforeFailure = blockedPollsBeforeFailure
            self.printTimeout = printTimeout
        }

        public init(settings: ServerSettings) {
            self.init(requireApproval: settings.requireApproval, maxQueueLength: settings.maxQueueLength,
                      printerName: settings.printerName, fileRetentionHours: settings.fileRetentionHours,
                      recordRetentionDays: settings.recordRetentionDays)
        }
    }

    public nonisolated let store: JobStore
    private var printService: any PrintService
    private let preparer: any DocumentPreparing
    private var configuration: Configuration
    private let onEvent: @Sendable (Event) -> Void
    private var jobs: [UUID: PrintJob] = [:]
    private var processingTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var started = false

    public init(store: JobStore, printService: any PrintService, preparer: any DocumentPreparing = DocumentPreparer(),
                configuration: Configuration = Configuration(), onEvent: @escaping @Sendable (Event) -> Void = { _ in }) {
        self.store = store
        self.printService = printService
        self.preparer = preparer
        self.configuration = configuration
        self.onEvent = onEvent
    }

    /// 載入既有紀錄；上次關閉時仍在「列印中」的工作改為失敗（可手動重試）。
    public func start() async {
        guard !started else { return }
        started = true
        for var job in await store.loadJobs() {
            if job.status == .printing {
                try? job.transition(to: .failed, message: "伺服器重新啟動，列印中斷；請確認印表機後重試")
            }
            jobs[job.id] = job
        }
        await store.removeOrphanFiles(keeping: Set(jobs.values.filter { !$0.fileDeleted }.map(\.id)))
        await purgeExpired()
        changed()
        pump()
    }

    // MARK: - 查詢

    public var currentConfiguration: Configuration { configuration }
    public var isDryRun: Bool { printService.isDryRun }

    public func job(_ id: UUID) -> PrintJob? { jobs[id] }

    /// 新的在前。
    public func snapshot() -> [PrintJob] {
        jobs.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// 等待所有排程中的寫入完成（測試與關閉時使用）。
    public func flush() async {
        await saveTask?.value
    }

    public var activeCount: Int { jobs.values.filter { $0.status.occupiesQueue }.count }

    public var hasCapacity: Bool { activeCount < configuration.maxQueueLength }

    // MARK: - 設定

    public func update(configuration newValue: Configuration) {
        configuration = newValue
        pump()
    }

    public func setPrintService(_ service: any PrintService) {
        printService = service
    }

    // MARK: - 新增 / 核准 / 拒絕

    public func submit(_ upload: IncomingUpload, now: Date = Date()) throws(QueueError) -> PrintJob {
        guard hasCapacity else { throw .queueFull }
        let job = PrintJob(
            id: upload.id, displayName: upload.displayName, fileKind: upload.kind, byteCount: upload.byteCount,
            sourceIP: upload.sourceIP, client: upload.client, createdAt: now,
            status: configuration.requireApproval ? .pendingApproval : .queued,
            options: upload.options
        )
        jobs[job.id] = job
        changed()
        if job.status == .pendingApproval {
            onEvent(.needsApproval(job))
        } else {
            pump()
        }
        return job
    }

    public func approve(_ id: UUID) throws(QueueError) {
        try mutate(id) { job throws(QueueError) in try Self.transition(&job, to: .queued) }
        pump()
    }

    public func reject(_ id: UUID, reason: String = "管理者拒絕") throws(QueueError) {
        try mutate(id) { job throws(QueueError) in try Self.transition(&job, to: .rejected, message: reason) }
        // 被拒絕的檔案立即刪除
        deleteFiles(id)
    }

    /// 核准所有待核准的工作。
    public func approveAll() {
        for job in jobs.values where job.status == .pendingApproval {
            try? approve(job.id)
        }
    }

    public func retry(_ id: UUID) throws(QueueError) {
        guard let job = jobs[id] else { throw .notFound }
        guard !job.fileDeleted else { throw .fileMissing }
        try mutate(id) { job throws(QueueError) in
            try Self.transition(&job, to: .queued)
            job.message = nil
            job.cupsJobID = nil
        }
        pump()
    }

    /// 從紀錄中移除已結束的工作。
    public func removeRecord(_ id: UUID) {
        guard let job = jobs[id], job.status.isTerminal else { return }
        deleteFiles(id)
        jobs[id] = nil
        changed()
    }

    /// 依保留設定刪除檔案與舊紀錄。
    public func purgeExpired(now: Date = Date()) async {
        var didChange = false
        let fileTTL = TimeInterval(configuration.fileRetentionHours * 3600)
        // 失敗的工作至少保留檔案 24 小時，方便重試。
        let failedTTL = max(fileTTL, 24 * 3600)
        let recordTTL = TimeInterval(configuration.recordRetentionDays * 86400)
        for (id, job) in jobs {
            if job.status.isTerminal, now.timeIntervalSince(job.createdAt) > recordTTL {
                deleteFiles(id, markDeleted: false)
                jobs[id] = nil
                didChange = true
                continue
            }
            guard !job.fileDeleted else { continue }
            let age = now.timeIntervalSince(job.updatedAt)
            switch job.status {
            case .done where age >= fileTTL, .rejected:
                deleteFiles(id)
                didChange = true
            case .failed where age >= failedTTL:
                deleteFiles(id)
                didChange = true
            default:
                break
            }
        }
        if didChange { changed() }
    }

    // MARK: - 處理

    private func pump() {
        guard started, processingTask == nil else { return }
        guard jobs.values.contains(where: { $0.status == .queued }) else { return }
        processingTask = Task { [weak self] in
            await self?.processLoop()
        }
    }

    private func processLoop() async {
        while let next = jobs.values.filter({ $0.status == .queued }).min(by: { $0.createdAt < $1.createdAt }) {
            await process(next.id)
        }
        processingTask = nil
    }

    private func process(_ id: UUID) async {
        guard jobs[id]?.status == .queued else { return }
        try? mutate(id) { job throws(QueueError) in try Self.transition(&job, to: .printing) }
        guard let job = jobs[id] else { return }

        let source = store.fileURL(for: id, kind: job.fileKind)
        let outputBase = store.derivedURL(for: id, suffix: "print", ext: "out").deletingPathExtension()
        let service = printService
        let printer = configuration.printerName

        do {
            try store.validateInsideSpool(source)
            guard FileManager.default.fileExists(atPath: source.path) else { throw QueueError.fileMissing }
            let printable = try await preparer.preparePrintableFile(source: source, kind: job.fileKind, outputBase: outputBase)
            let submission = try await service.submit(fileURL: printable, title: job.displayName, options: job.options, printer: printer)
            try? mutate(id) { job throws(QueueError) in
                job.cupsJobID = submission.cupsJobID
                job.notes.append(contentsOf: submission.notes)
            }
            let outcome = await waitForCompletion(submission, service: service, printer: printer)
            switch outcome {
            case .done:
                finish(id, as: .done, message: nil)
            case .failed(let reason):
                await service.cancel(submission, printer: printer)
                finish(id, as: .failed, message: reason)
            case .printing, .blocked:
                break // waitForCompletion 不會回傳這兩種
            }
        } catch {
            finish(id, as: .failed, message: String(describing: error))
        }
    }

    private func waitForCompletion(_ submission: PrintSubmission, service: any PrintService, printer: String?) async -> PrintProgress {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: configuration.printTimeout)
        var blockedCount = 0
        while true {
            let progress = await service.progress(of: submission, printer: printer)
            switch progress {
            case .done, .failed:
                return progress
            case .blocked(let reason):
                blockedCount += 1
                if blockedCount >= configuration.blockedPollsBeforeFailure {
                    return .failed("\(reason)；已取消此工作，處理後可在選單列重試")
                }
            case .printing:
                blockedCount = 0
            }
            if clock.now >= deadline {
                return .failed("等待列印逾時；已取消此工作")
            }
            try? await Task.sleep(for: configuration.pollInterval)
        }
    }

    private func finish(_ id: UUID, as status: JobStatus, message: String?) {
        try? mutate(id) { job throws(QueueError) in try Self.transition(&job, to: status, message: message) }
        guard let job = jobs[id] else { return }
        // 轉換產生的中間檔一律刪除；原始檔依保留設定處理
        deleteDerivedFiles(id)
        if status == .done, configuration.fileRetentionHours == 0 {
            deleteFiles(id)
        }
        onEvent(status == .done ? .completed(jobs[id] ?? job) : .failed(jobs[id] ?? job))
    }

    // MARK: - 輔助

    private static func transition(_ job: inout PrintJob, to status: JobStatus, message: String? = nil) throws(QueueError) {
        do {
            try job.transition(to: status, message: message)
        } catch {
            throw .invalidTransition(from: error.from, to: error.to)
        }
    }

    private func mutate(_ id: UUID, _ body: (inout PrintJob) throws(QueueError) -> Void) throws(QueueError) {
        guard var job = jobs[id] else { throw .notFound }
        try body(&job)
        jobs[id] = job
        changed()
    }

    private func deleteFiles(_ id: UUID, markDeleted: Bool = true) {
        store.deleteFiles(for: id)
        if markDeleted, var job = jobs[id] {
            job.fileDeleted = true
            jobs[id] = job
            changed()
        }
    }

    private func deleteDerivedFiles(_ id: UUID) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: store.spoolDirectory.path) else { return }
        for name in items where name.hasPrefix("\(id.uuidString)-") {
            try? fm.removeItem(at: store.spoolDirectory.appendingPathComponent(name))
        }
    }

    private func changed() {
        let all = snapshot()
        let store = self.store
        // 依序寫入，避免較舊的快照晚於新的快照寫入磁碟。
        let previous = saveTask
        saveTask = Task {
            await previous?.value
            try? await store.saveJobs(all)
        }
        onEvent(.jobsChanged(all))
    }
}
