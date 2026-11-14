import Foundation
import Testing
@testable import MFConnectCore
@testable import MFConnectServer

/// 假的 ProcessRunner：只記錄參數、回傳預先設定的輸出，**絕不真的執行任何程式**。
final class FakeRunner: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(String, [String])] = []
    var responder: @Sendable (String, [String]) -> ProcessResult

    init(responder: @escaping @Sendable (String, [String]) -> ProcessResult) {
        self.responder = responder
    }

    var calls: [(String, [String])] { lock.withLock { _calls } }

    func run(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
        lock.withLock { _calls.append((executable, arguments)) }
        return responder(executable, arguments)
    }
}

let canonLpoptions = """
PageSize/Media Size: *A4 A5 B5 Letter Legal Env10
Duplex/2-Sided Printing: *None DuplexNoTumble DuplexTumble
ColorModel/Color Mode: Gray *RGB
print-quality/Print Quality: 3 *4 5
"""

let ippEverywhereLpoptions = """
sides/2-Sided Printing: *one-sided two-sided-long-edge two-sided-short-edge
print-color-mode/Print Color Mode: monochrome *color
"""

let monoSimplexLpoptions = """
PageSize/Media Size: *A4 Letter
"""

@Suite("lp 參數組合（只驗證參數，不執行）")
struct LpArgumentsTests {
    let file = URL(fileURLWithPath: "/Users/me/Library/Application Support/MFConnect/spool/1A2B.pdf")

    @Test func parsesLpoptions() {
        let caps = PrinterCapabilities.parse(lpoptionsOutput: canonLpoptions)
        #expect(caps.options["Duplex"] == ["None", "DuplexNoTumble", "DuplexTumble"])
        #expect(caps.options["ColorModel"] == ["Gray", "RGB"])
        #expect(caps.supportsDuplex(.long))
        #expect(caps.supportsDuplex(.short))
        #expect(caps.supportsMonochrome)
    }

    @Test func fullOptionsOnCapablePrinter() {
        let result = LpArguments.build(
            printer: "Canon_MF642C_643C", fileURL: file, title: "報告.pdf",
            options: JobOptions(copies: 3, duplex: .long, color: .mono),
            capabilities: PrinterCapabilities.parse(lpoptionsOutput: canonLpoptions)
        )
        #expect(result.arguments == [
            "-d", "Canon_MF642C_643C", "-n", "3", "-t", "報告.pdf",
            "-o", "sides=two-sided-long-edge",
            "-o", "print-color-mode=monochrome",
            file.path,
        ])
        #expect(result.notes.isEmpty)
    }

    @Test func shortEdgeAndColor() {
        let result = LpArguments.build(
            printer: "P", fileURL: file, title: "a",
            options: JobOptions(copies: 1, duplex: .short, color: .color),
            capabilities: PrinterCapabilities.parse(lpoptionsOutput: ippEverywhereLpoptions)
        )
        #expect(result.arguments == ["-d", "P", "-n", "1", "-t", "a", "-o", "sides=two-sided-short-edge", file.path])
    }

    @Test func singleSidedIsExplicitWhenPrinterSupportsDuplex() {
        let result = LpArguments.build(
            printer: "P", fileURL: file, title: "a", options: JobOptions(),
            capabilities: PrinterCapabilities.parse(lpoptionsOutput: ippEverywhereLpoptions)
        )
        #expect(result.arguments.contains("sides=one-sided"))
    }

    @Test func degradesUnsupportedOptionsWithNotes() {
        let result = LpArguments.build(
            printer: "P", fileURL: file, title: "a",
            options: JobOptions(copies: 2, duplex: .long, color: .mono),
            capabilities: PrinterCapabilities.parse(lpoptionsOutput: monoSimplexLpoptions)
        )
        #expect(result.arguments == ["-d", "P", "-n", "2", "-t", "a", file.path])
        #expect(result.notes.count == 2)
        #expect(result.notes.contains { $0.contains("單面") })
        #expect(result.notes.contains { $0.contains("黑白") })
    }

    @Test func unknownCapabilitiesSendRequestedOptionsAndNote() {
        let result = LpArguments.build(
            printer: "P", fileURL: file, title: "a",
            options: JobOptions(copies: 1, duplex: .long, color: .mono), capabilities: nil
        )
        #expect(result.arguments.contains("sides=two-sided-long-edge"))
        #expect(result.arguments.contains("print-color-mode=monochrome"))
        #expect(result.notes.first?.contains("無法讀取") == true)
    }

    @Test func hostileTitleStaysASingleArgument() {
        let title = "a.pdf; rm -rf ~ $(whoami) `id`\n-o evil"
        let result = LpArguments.build(printer: "P", fileURL: file, title: title, options: JobOptions(), capabilities: nil)
        let index = result.arguments.firstIndex(of: "-t")!
        #expect(result.arguments[index + 1] == "a.pdf; rm -rf ~ $(whoami) `id`-o evil")
        #expect(result.arguments.last == file.path)
        #expect(!result.arguments.contains("evil"))
    }

    @Test func copiesAreClamped() {
        let result = LpArguments.build(printer: "P", fileURL: file, title: "", options: JobOptions(copies: 500), capabilities: nil)
        #expect(Array(result.arguments[2...3]) == ["-n", "99"])
        #expect(!result.arguments.contains("-t"))
    }
}

@Suite("lpstat 解析")
struct LpstatParserTests {
    @Test func queues() {
        #expect(LpstatParser.queues(from: "Canon_MF642C_643C\nHP_LaserJet\n\n") == ["Canon_MF642C_643C", "HP_LaserJet"])
        #expect(LpstatParser.queues(from: "") == [])
    }

    @Test func defaultQueue() {
        #expect(LpstatParser.defaultQueue(from: "system default destination: Canon_MF642C_643C\n") == "Canon_MF642C_643C")
        #expect(LpstatParser.defaultQueue(from: "no system default destination\n") == nil)
    }

    @Test func requestID() {
        #expect(LpstatParser.requestID(from: "request id is Canon_MF642C_643C-42 (1 file(s))\n") == "Canon_MF642C_643C-42")
        #expect(LpstatParser.requestID(from: "lp: error") == nil)
    }

    @Test func jobListing() {
        let out = "Canon_MF642C_643C-42    me    10240   Sat Nov 14 15:00:00 2026\nCanon_MF642C_643C-43 me 1 x\n"
        #expect(LpstatParser.jobIsListed("Canon_MF642C_643C-42", in: out))
        #expect(!LpstatParser.jobIsListed("Canon_MF642C_643C-4", in: out))
    }

    @Test func alerts() {
        let empty = """
        printer Canon_MF642C_643C now printing Canon_MF642C_643C-42.  enabled since Sat Nov 14 15:00:00 2026
        \tMedia Empty
        \tAlerts: media-empty-error marker-supply-low-warning
        """
        #expect(LpstatParser.blockingAlert(from: empty) == "印表機缺紙")

        let jam = "printer P is idle.\n\tAlerts: media-jam-error\n"
        #expect(LpstatParser.blockingAlert(from: jam) == "印表機卡紙")

        let lowToner = "printer P now printing P-1.\n\tAlerts: toner-low-warning media-empty-report\n"
        #expect(LpstatParser.blockingAlert(from: lowToner) == nil)

        let disabled = "printer P disabled since Sat Nov 14 15:00:00 2026 -\n\tPaused\n"
        #expect(LpstatParser.blockingAlert(from: disabled)?.contains("停用") == true)

        // 印表機名稱含 jam 也不應誤判
        #expect(LpstatParser.blockingAlert(from: "printer Jammy_Printer is idle.\n") == nil)
    }
}

@Suite("LpPrintService 流程（假 runner）")
struct LpPrintServiceTests {
    @Test func submitChecksQueueAndCapabilitiesThenCallsLp() async throws {
        let runner = FakeRunner { exe, args in
            switch exe {
            case "/usr/bin/lpstat" where args == ["-e"]: ProcessResult(status: 0, stdout: "Canon\n", stderr: "")
            case "/usr/bin/lpoptions": ProcessResult(status: 0, stdout: canonLpoptions, stderr: "")
            case "/usr/bin/lp": ProcessResult(status: 0, stdout: "request id is Canon-7 (1 file(s))\n", stderr: "")
            default: ProcessResult(status: 1, stdout: "", stderr: "unexpected")
            }
        }
        let service = LpPrintService(runner: runner)
        let file = URL(fileURLWithPath: "/tmp/spool/x.pdf")
        let submission = try await service.submit(fileURL: file, title: "x.pdf", options: JobOptions(copies: 2, duplex: .long, color: .mono), printer: "Canon")
        #expect(submission.cupsJobID == "Canon-7")
        let calls = runner.calls
        #expect(calls.map(\.0) == ["/usr/bin/lpstat", "/usr/bin/lpoptions", "/usr/bin/lp"])
        #expect(calls[1].1 == ["-p", "Canon", "-l"])
        #expect(calls[2].1 == ["-d", "Canon", "-n", "2", "-t", "x.pdf", "-o", "sides=two-sided-long-edge", "-o", "print-color-mode=monochrome", "/tmp/spool/x.pdf"])
    }

    @Test func submitFailsForMissingPrinter() async {
        let runner = FakeRunner { _, _ in ProcessResult(status: 0, stdout: "Other\n", stderr: "") }
        let service = LpPrintService(runner: runner)
        await #expect(throws: PrintServiceError.self) {
            _ = try await service.submit(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"), title: "a", options: JobOptions(), printer: "Canon")
        }
        await #expect(throws: PrintServiceError.self) {
            _ = try await service.submit(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"), title: "a", options: JobOptions(), printer: nil)
        }
        #expect(!runner.calls.contains { $0.0 == "/usr/bin/lp" })
    }

    @Test func progressDetectsBlockedAndDone() async {
        let state = MutableBox("Canon-7 me 1 now\n")
        let runner = FakeRunner { exe, args in
            if args == ["-o", "Canon"] { return ProcessResult(status: 0, stdout: state.value, stderr: "") }
            if args == ["-l", "-p", "Canon"] { return ProcessResult(status: 0, stdout: "printer Canon now printing.\n\tAlerts: media-empty-error\n", stderr: "") }
            return ProcessResult(status: 1, stdout: "", stderr: "")
        }
        let service = LpPrintService(runner: runner)
        let submission = PrintSubmission(cupsJobID: "Canon-7")
        #expect(await service.progress(of: submission, printer: "Canon") == .blocked("印表機缺紙"))
        state.value = ""
        #expect(await service.progress(of: submission, printer: "Canon") == .done)
    }
}

final class MutableBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

@Suite("A4 版面")
struct PaperLayoutTests {
    @Test func portraitImageIsCentered() {
        let layout = PaperSize.layout(imageWidth: 1000, imageHeight: 2000)
        #expect(layout.page.w < layout.page.h)
        let r = layout.rect
        #expect(abs((r.x * 2 + r.w) - layout.page.w) < 0.001)
        #expect(abs((r.y * 2 + r.h) - layout.page.h) < 0.001)
        #expect(abs(r.w / r.h - 0.5) < 0.0001)
        #expect(r.x >= PaperSize.margin - 0.001 && r.y >= PaperSize.margin - 0.001)
    }

    @Test func landscapeImageUsesLandscapePage() {
        let layout = PaperSize.layout(imageWidth: 4000, imageHeight: 3000)
        #expect(layout.page.w > layout.page.h)
        #expect(abs(layout.rect.w / layout.rect.h - 4.0 / 3.0) < 0.0001)
    }
}
