import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import MFConnectCore
import MFConnectServer
import Observation
import ServiceManagement
import SystemConfiguration

/// macOS 選單列 App 的狀態中心：組合伺服器、佇列、列印服務、Bonjour 與系統整合。
@MainActor
@Observable
final class AppModel {
    enum ServerStatus: Equatable {
        case stopped
        case starting
        case running(port: Int)
        case failed(String)

        var text: String {
            switch self {
            case .stopped: "已停止"
            case .starting: "啟動中…"
            case .running(let port): "執行中（連接埠 \(port)）"
            case .failed(let message): "無法啟動：\(message)"
            }
        }

        var isRunning: Bool { if case .running = self { true } else { false } }
    }

    private(set) var settings: ServerSettings
    private(set) var token: String
    private(set) var jobs: [PrintJob] = []
    private(set) var status: ServerStatus = .stopped
    private(set) var printers: [String] = []
    private(set) var lockedIPs: [String] = []
    private(set) var interfaces: [NetworkInterface] = NetworkInterfaces.ipv4Interfaces()
    private(set) var localHostName: String = AppModel.currentLocalHostName()
    private(set) var startupError: String?
    var lastError: String?

    private let runtime: ServerRuntimeState
    private let accessGuard: AccessGuard
    private let queue: JobQueue
    private let server: MFConnectHTTPServer
    private let bonjour = BonjourAdvertiser()
    private let tokenStore = KeychainTokenStore()
    private let lpService = LpPrintService()
    private var sleepActivity: (any NSObjectProtocol)?
    private var maintenanceTask: Task<Void, Never>?

    private static let settingsKey = "serverSettings"

    init() {
        // 1. 設定
        var loaded = ServerSettings()
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(ServerSettings.self, from: data) {
            loaded = decoded
        } else {
            loaded.serverName = Host.current().localizedName ?? "MFConnect"
        }
        settings = loaded.clamped()

        // 2. token：首次啟動產生 32 bytes 隨機 token，存在 Keychain
        var startupProblems: [String] = []
        var currentToken: String
        let keychain = KeychainTokenStore()
        do {
            if let saved = try keychain.load(), !saved.isEmpty {
                currentToken = saved
            } else {
                currentToken = TokenGenerator.generate()
                try keychain.save(currentToken)
            }
        } catch {
            currentToken = TokenGenerator.generate()
            startupProblems.append("無法存取鑰匙圈，本次使用暫時 token：\(error)")
        }
        token = currentToken

        // 3. 儲存位置（Application Support/MFConnect）
        let store: JobStore
        do {
            store = try JobStore()
        } catch {
            let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("MFConnect", isDirectory: true)
            // 暫存資料夾一定可以建立；若連這裡都失敗就無法繼續執行
            store = try! JobStore(rootDirectory: fallback)
            startupProblems.append("無法建立 Application Support 資料夾，改用暫存資料夾：\(error)")
        }
        startupError = startupProblems.isEmpty ? nil : startupProblems.joined(separator: "\n")

        runtime = ServerRuntimeState(settings: settings)
        accessGuard = AccessGuard(token: currentToken)
        let printService: any PrintService = settings.dryRun ? DryRunPrintService() : LpPrintService()
        let eventSink = EventSink()
        queue = JobQueue(store: store, printService: printService,
                         configuration: JobQueue.Configuration(settings: settings),
                         onEvent: { event in eventSink.handle(event) })
        server = MFConnectHTTPServer(state: runtime, accessGuard: accessGuard, queue: queue)
        eventSink.model = self

        Notifier.shared.configure(approve: { [weak self] id in self?.approve(id) },
                                  reject: { [weak self] id in self?.reject(id) })

        Task {
            await queue.start()
            await refreshPrinters()
            await startServer()
        }
        applySleepPrevention()
        startMaintenance()
    }

    // MARK: - 事件

    fileprivate func handle(_ event: JobQueue.Event) {
        switch event {
        case .jobsChanged(let all):
            jobs = all
        case .needsApproval(let job):
            Notifier.shared.notifyNeedsApproval(job)
        case .failed(let job):
            Notifier.shared.notifyFailed(job)
        case .completed:
            break
        }
    }

    // MARK: - 伺服器

    func startServer() async {
        status = .starting
        guard let host = NetworkInterfaces.bindAddress(forInterface: settings.bindInterface) else {
            status = .failed("找不到介面 \(settings.bindInterface ?? "")，請到設定改為「所有網卡」或其他介面")
            return
        }
        do {
            let port = try await server.start(host: host, port: settings.port)
            status = .running(port: port)
            localHostName = Self.currentLocalHostName()
            interfaces = NetworkInterfaces.ipv4Interfaces()
            bonjour.start(serverName: settings.serverName, port: port,
                          requiresApproval: settings.requireApproval, host: localHostName)
        } catch {
            status = .failed(Self.describe(startError: error, port: settings.port))
        }
    }

    func stopServer() async {
        bonjour.stop()
        await server.stop()
        status = .stopped
    }

    func setServerEnabled(_ enabled: Bool) {
        Task {
            if enabled { await startServer() } else { await stopServer() }
        }
    }

    private static func describe(startError error: any Error, port: Int) -> String {
        let text = String(describing: error)
        if text.contains("Address already in use") || text.contains("errno: 48") {
            return "連接埠 \(port) 已被其他程式使用，請在設定中更換"
        }
        return text
    }

    // MARK: - 上傳網址與 QR code

    var currentPort: Int {
        if case .running(let port) = status { return port }
        return settings.port
    }

    /// `http://<主機名>.local:<port>` 以及各介面的 IP 版本。
    var uploadURLs: [String] {
        var urls = ["http://\(localHostName):\(currentPort)"]
        let candidates: [NetworkInterface]
        if let bound = settings.bindInterface {
            candidates = interfaces.filter { $0.name == bound }
        } else {
            candidates = interfaces.filter { !$0.name.hasPrefix("utun") && !$0.name.hasPrefix("bridge") }
        }
        urls += candidates.map { "http://\($0.ipv4):\(currentPort)" }
        return urls
    }

    func qrPayload(for url: String) -> String {
        settings.qrIncludesToken ? "\(url)/#token=\(token)" : url
    }

    func qrImage(for url: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(qrPayload(for: url).utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    static func currentLocalHostName() -> String {
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty {
            return "\(name).local"
        }
        return ProcessInfo.processInfo.hostName
    }

    // MARK: - 工作操作

    func approve(_ id: UUID) {
        Task { await perform { try await queue.approve(id) } }
    }

    func reject(_ id: UUID) {
        Task { await perform { try await queue.reject(id) } }
    }

    func approveAll() {
        Task { await queue.approveAll() }
    }

    func retry(_ id: UUID) {
        Task { await perform { try await queue.retry(id) } }
    }

    func removeRecord(_ id: UUID) {
        Task { await queue.removeRecord(id) }
    }

    private func perform(_ body: () async throws -> Void) async {
        do {
            try await body()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    var pendingJobs: [PrintJob] { jobs.filter { $0.status == .pendingApproval }.sorted { $0.createdAt < $1.createdAt } }
    var activeJobs: [PrintJob] { jobs.filter { $0.status == .queued || $0.status == .printing }.sorted { $0.createdAt < $1.createdAt } }
    var historyJobs: [PrintJob] { jobs.filter { $0.status.isTerminal } }

    // MARK: - token

    /// 重新產生 token；舊 token 立即失效。
    func regenerateToken() {
        let newToken = TokenGenerator.generate()
        do {
            try tokenStore.save(newToken)
        } catch {
            lastError = "無法寫入鑰匙圈：\(error)"
            return
        }
        token = newToken
        Task { await accessGuard.rotate(to: newToken) }
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func refreshLockedIPs() async {
        lockedIPs = await accessGuard.lockedIPs()
    }

    func unlockAllIPs() {
        Task {
            await accessGuard.unlockAll()
            await refreshLockedIPs()
        }
    }

    // MARK: - 印表機

    func refreshPrinters() async {
        printers = await lpService.availableQueues()
        // 尚未選擇印表機時，自動選系統預設或名稱含 Canon 的佇列
        if settings.printerName == nil, !printers.isEmpty {
            var updated = settings
            if let def = await lpService.defaultQueue(), printers.contains(def) {
                updated.printerName = def
            } else {
                updated.printerName = printers.first { $0.localizedCaseInsensitiveContains("canon") } ?? printers.first
            }
            apply(updated)
        }
    }

    // MARK: - 設定

    /// 套用新設定；需要時重新啟動伺服器。
    func apply(_ newValue: ServerSettings) {
        let new = newValue.clamped()
        let old = settings
        guard new != old else { return }
        settings = new
        runtime.settings = new
        if let data = try? JSONEncoder().encode(new) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }

        Task {
            await queue.update(configuration: JobQueue.Configuration(settings: new))
            if new.dryRun != old.dryRun {
                await queue.setPrintService(new.dryRun ? DryRunPrintService() : LpPrintService())
            }
        }

        if new.launchAtLogin != old.launchAtLogin { applyLaunchAtLogin(new.launchAtLogin) }
        if new.preventIdleSleep != old.preventIdleSleep { applySleepPrevention() }

        let needsRestart = new.port != old.port || new.bindInterface != old.bindInterface
            || new.maxConnections != old.maxConnections || new.idleTimeoutSeconds != old.idleTimeoutSeconds
        if needsRestart, status != .stopped {
            Task {
                await stopServer()
                await startServer()
            }
        } else if status.isRunning, new.serverName != old.serverName || new.requireApproval != old.requireApproval {
            // 更新 Bonjour TXT 記錄
            bonjour.start(serverName: new.serverName, port: currentPort, requiresApproval: new.requireApproval, host: localHostName)
        }
    }

    var loginItemStatusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: "已啟用"
        case .requiresApproval: "需要到「系統設定 → 一般 → 登入項目」允許"
        case .notRegistered: "未啟用"
        case .notFound: "找不到 App（請把 App 放到「應用程式」資料夾）"
        @unknown default: "未知"
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = "無法變更登入項目：\(error.localizedDescription)"
        }
    }

    /// 防止閒置睡眠：只阻止「閒置自動睡眠」，手動睡眠、闔上螢幕（筆電）仍會睡眠。
    private func applySleepPrevention() {
        if settings.preventIdleSleep {
            guard sleepActivity == nil else { return }
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled],
                reason: "MFConnect 列印伺服器需要持續接收檔案"
            )
        } else if let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }

    // MARK: - 定期維護

    private func startMaintenance() {
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15 * 60))
                guard let self else { return }
                await self.queue.purgeExpired()
                await self.refreshLockedIPs()
                self.interfaces = NetworkInterfaces.ipv4Interfaces()
                self.localHostName = Self.currentLocalHostName()
            }
        }
    }
}

/// 把佇列事件（在 actor 上產生）轉送到主執行緒的 AppModel。
private final class EventSink: @unchecked Sendable {
    @MainActor weak var model: AppModel?

    func handle(_ event: JobQueue.Event) {
        Task { @MainActor [weak self] in
            self?.model?.handle(event)
        }
    }
}
