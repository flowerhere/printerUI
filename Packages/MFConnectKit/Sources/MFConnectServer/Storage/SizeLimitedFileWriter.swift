import Foundation

/// 邊收邊寫入磁碟，持續計數；一旦超過上限立即丟出錯誤。
/// 只保留前 16 bytes 供 magic bytes 判斷，不會把整個檔案讀進記憶體。
public final class SizeLimitedFileWriter {
    public enum WriteError: Error, Equatable {
        case limitExceeded(limit: Int64)
        case io(String)
    }

    public let limit: Int64
    public private(set) var bytesWritten: Int64 = 0
    public private(set) var header: [UInt8] = []
    private let handle: FileHandle
    private let headerCapacity: Int

    /// 建立檔案（權限 0600）並開啟寫入。呼叫端一律傳入以 UUID 命名的新路徑。
    public init(url: URL, limit: Int64, headerCapacity: Int = 16) throws {
        let created = FileManager.default.createFile(
            atPath: url.path, contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        guard created else { throw WriteError.io("無法建立暫存檔") }
        self.handle = try FileHandle(forWritingTo: url)
        self.limit = limit
        self.headerCapacity = headerCapacity
    }

    /// 寫入一段資料。超過上限時**不寫入**該段並丟出錯誤。
    public func append<C: Collection>(_ chunk: C) throws where C.Element == UInt8 {
        let count = Int64(chunk.count)
        guard bytesWritten + count <= limit else {
            throw WriteError.limitExceeded(limit: limit)
        }
        if header.count < headerCapacity {
            header.append(contentsOf: chunk.prefix(headerCapacity - header.count))
        }
        do {
            try handle.write(contentsOf: Data(chunk))
        } catch {
            throw WriteError.io(String(describing: error))
        }
        bytesWritten += count
    }

    private var closed = false

    public func close() {
        guard !closed else { return }
        closed = true
        try? handle.close()
    }

    deinit {
        if !closed { try? handle.close() }
    }
}
