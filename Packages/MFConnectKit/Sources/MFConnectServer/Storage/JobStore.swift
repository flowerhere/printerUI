import Foundation
import MFConnectCore

/// 管理 Application Support 底下的專屬資料夾：
///
/// ```
/// <root>/jobs.json        工作紀錄
/// <root>/spool/<UUID>.ext 待印檔案（一律 UUID 命名）
/// <root>/spool/<UUID>.part 上傳中的暫存檔
/// ```
public actor JobStore {
    public nonisolated let rootDirectory: URL
    public nonisolated let spoolDirectory: URL
    private nonisolated let recordsURL: URL

    public enum StoreError: Error, CustomStringConvertible {
        case pathEscapesSpool
        public var description: String { "檔案路徑不在 spool 資料夾內" }
    }

    /// macOS 預設位置：~/Library/Application Support/MFConnect
    public static func defaultRootDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MFConnect", isDirectory: true)
    }

    public init(rootDirectory: URL = JobStore.defaultRootDirectory()) throws {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.spoolDirectory = self.rootDirectory.appendingPathComponent("spool", isDirectory: true)
        self.recordsURL = self.rootDirectory.appendingPathComponent("jobs.json")
        let fm = FileManager.default
        try fm.createDirectory(at: spoolDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.rootDirectory.path)
    }

    // MARK: - 檔案路徑（只接受 UUID，杜絕路徑穿越）

    public nonisolated func fileURL(for id: UUID, kind: FileKind) -> URL {
        spoolDirectory.appendingPathComponent("\(id.uuidString).\(kind.fileExtension)", isDirectory: false)
    }

    public nonisolated func partialURL(for id: UUID) -> URL {
        spoolDirectory.appendingPathComponent("\(id.uuidString).part", isDirectory: false)
    }

    /// 轉換後的 PDF（圖片→PDF、HEIC→JPEG）也放在 spool 內。
    public nonisolated func derivedURL(for id: UUID, suffix: String, ext: String) -> URL {
        spoolDirectory.appendingPathComponent("\(id.uuidString)-\(suffix).\(ext)", isDirectory: false)
    }

    /// 二次防線：確認路徑解析後仍在 spool 資料夾內。
    public nonisolated func validateInsideSpool(_ url: URL) throws {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        let spool = spoolDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(spool + "/") else { throw StoreError.pathEscapesSpool }
    }

    /// 刪除某個工作在 spool 內的所有檔案（原檔、暫存檔、轉換檔）。
    public nonisolated func deleteFiles(for id: UUID) {
        let fm = FileManager.default
        let prefix = id.uuidString
        guard let items = try? fm.contentsOfDirectory(atPath: spoolDirectory.path) else { return }
        for name in items where name.hasPrefix(prefix) {
            let url = spoolDirectory.appendingPathComponent(name)
            if (try? validateInsideSpool(url)) != nil {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// 啟動時清掉沒有對應紀錄的殘留檔（例如上傳到一半時當機）。
    public func removeOrphanFiles(keeping ids: Set<UUID>) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: spoolDirectory.path) else { return }
        for name in items {
            let idPart = String(name.prefix(36))
            if let id = UUID(uuidString: idPart), ids.contains(id), !name.hasSuffix(".part") { continue }
            try? fm.removeItem(at: spoolDirectory.appendingPathComponent(name))
        }
    }

    // MARK: - 紀錄

    public func loadJobs() -> [PrintJob] {
        guard let data = try? Data(contentsOf: recordsURL) else { return [] }
        return (try? JSONDecoder.mfConnect().decode([PrintJob].self, from: data)) ?? []
    }

    public func saveJobs(_ jobs: [PrintJob]) throws {
        let encoder = JSONEncoder.mfConnect()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(jobs)
        try data.write(to: recordsURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordsURL.path)
    }
}
