// 開發用伺服器：以「試跑模式」（DryRunPrintService）啟動，不會真的列印。
//
//   swift run mfconnect-devserver [--host 127.0.0.1] [--port 8631] [--auto] [--lp <佇列名稱>]
//
//   --host   綁定位址（預設 127.0.0.1，只有本機能連；區網測試請用 0.0.0.0）
//   --port   連接埠（預設 8631）
//   --auto   不需核准，上傳後立即處理
//   --lp     改用 LpPrintService 真的列印到指定 CUPS 佇列（僅 macOS）
//
// token 每次啟動隨機產生並印在終端機；工作紀錄存在暫存資料夾，結束後即可丟棄。
import Foundation
import MFConnectCore
import MFConnectServer

var host = "127.0.0.1"
var port = MFConnectConstants.defaultPort
var autoPrint = false
var lpQueue: String?

var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--host": host = args.next() ?? host
    case "--port": port = args.next().flatMap(Int.init) ?? port
    case "--auto": autoPrint = true
    case "--lp": lpQueue = args.next()
    default:
        FileHandle.standardError.write(Data("未知參數：\(arg)\n".utf8))
        exit(2)
    }
}

var settings = ServerSettings(serverName: "MFConnect 開發伺服器", port: port)
settings.requireApproval = !autoPrint
settings.printerName = lpQueue
settings.dryRun = lpQueue == nil

let root = FileManager.default.temporaryDirectory.appendingPathComponent("mfconnect-devserver", isDirectory: true)
let store = try JobStore(rootDirectory: root)
let printService: any PrintService = lpQueue == nil
    ? DryRunPrintService(log: { print($0) })
    : LpPrintService()

let queue = JobQueue(store: store, printService: printService, configuration: .init(settings: settings)) { event in
    switch event {
    case .needsApproval(let job):
        print("［待核准］\(job.displayName)（\(job.options.summary)）來自 \(job.sourceIP)；輸入 a 核准全部、r <id> 拒絕")
    case .completed(let job):
        print("［完成］\(job.displayName)")
    case .failed(let job):
        print("［失敗］\(job.displayName)：\(job.message ?? "")")
    case .jobsChanged:
        break
    }
}
await queue.start()

let token = ProcessInfo.processInfo.environment["MFC_TOKEN"] ?? TokenGenerator.generate()
let server = MFConnectHTTPServer(state: ServerRuntimeState(settings: settings), accessGuard: AccessGuard(token: token), queue: queue)
let boundPort = try await server.start(host: host, port: port)

print("""
MFConnect 開發伺服器已啟動（\(lpQueue == nil ? "試跑模式，不會列印" : "列印到 \(lpQueue!)")）
  上傳頁：http://\(host == "0.0.0.0" ? "localhost" : host):\(boundPort)/
  token ：\(token)
  資料夾：\(root.path)
指令：a = 核准全部、r <id> = 拒絕、l = 列出工作、q = 結束
""")

while let line = readLine() {
    let parts = line.split(separator: " ")
    switch parts.first {
    case "a":
        await queue.approveAll()
    case "r" where parts.count > 1:
        if let id = UUID(uuidString: String(parts[1])) {
            do { try await queue.reject(id) } catch { print(error) }
        }
    case "l":
        for job in await queue.snapshot() {
            print("\(job.id.uuidString)  \(job.status.displayName)  \(job.displayName)  \(job.options.summary)")
        }
    case "q":
        await server.stop()
        exit(0)
    default:
        print("指令：a = 核准全部、r <id> = 拒絕、l = 列出工作、q = 結束")
    }
}
// stdin 關閉（例如背景執行）時保持運作
while true { try await Task.sleep(for: .seconds(3600)) }
