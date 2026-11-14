import Foundation
import Testing
@testable import MFConnectCore

@Suite("Magic bytes 判斷")
struct FileSnifferTests {
    @Test func pdf() {
        #expect(FileSniffer.detect(Array("%PDF-1.7\n%âãÏÓ".utf8)) == .pdf)
    }

    @Test func png() {
        #expect(FileSniffer.detect([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D]) == .png)
    }

    @Test func jpeg() {
        #expect(FileSniffer.detect([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46]) == .jpeg)
        #expect(FileSniffer.detect([0xFF, 0xD8, 0xFF, 0xE1]) == .jpeg)
    }

    @Test(arguments: ["heic", "heix", "mif1", "hevc"])
    func heic(brand: String) {
        let bytes: [UInt8] = [0, 0, 0, 0x18] + Array("ftyp".utf8) + Array(brand.utf8) + [0, 0, 0, 0]
        #expect(FileSniffer.detect(bytes) == .heic)
    }

    @Test func rejectsOtherISOBMFF() {
        // MP4 / AVIF 都是 ftyp，但 brand 不在允許清單
        let mp4: [UInt8] = [0, 0, 0, 0x18] + Array("ftypisom".utf8) + [0, 0, 0, 0]
        let avif: [UInt8] = [0, 0, 0, 0x18] + Array("ftypavif".utf8) + [0, 0, 0, 0]
        #expect(FileSniffer.detect(mp4) == nil)
        #expect(FileSniffer.detect(avif) == nil)
    }

    @Test func rejectsUnknownAndShortInput() {
        #expect(FileSniffer.detect([UInt8]()) == nil)
        #expect(FileSniffer.detect([0xFF, 0xD8]) == nil)                 // JPEG 開頭不完整
        #expect(FileSniffer.detect(Array("%PD".utf8)) == nil)
        #expect(FileSniffer.detect(Array("PK\u{03}\u{04}word".utf8)) == nil) // docx / zip
        #expect(FileSniffer.detect(Array("<html><script>".utf8)) == nil)
        #expect(FileSniffer.detect(Array("GIF89a......".utf8)) == nil)
    }

    @Test func extensionIsIgnored() throws {
        // 副檔名是 .pdf，但內容是 HTML → 不接受
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data("<html>not a pdf</html>".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FileSniffer.detect(fileAt: url) == nil)
    }
}

@Suite("檔名清理與路徑穿越")
struct FilenameSanitizerTests {
    @Test func keepsNormalNames() {
        #expect(FilenameSanitizer.sanitize("報告 2026.pdf") == "報告 2026.pdf")
        #expect(FilenameSanitizer.sanitize("IMG_0001.HEIC") == "IMG_0001.HEIC")
    }

    @Test(arguments: [
        ("../../etc/passwd", "passwd"),
        ("..\\..\\Windows\\system32\\cmd.exe", "cmd.exe"),
        ("/Users/someone/Library/x.pdf", "x.pdf"),
        ("..", FilenameSanitizer.fallbackName),
        ("../", FilenameSanitizer.fallbackName),
        (".hidden.pdf", "hidden.pdf"),
        ("", FilenameSanitizer.fallbackName),
    ])
    func stripsPaths(input: String, expected: String) {
        #expect(FilenameSanitizer.sanitize(input) == expected)
    }

    @Test func removesControlAndBidiCharacters() {
        #expect(FilenameSanitizer.sanitize("a\u{0}b\nc\u{7}.pdf") == "abc.pdf")
        // U+202E RIGHT-TO-LEFT OVERRIDE 可用來偽造副檔名
        #expect(FilenameSanitizer.sanitize("invoice\u{202E}fdp.exe") == "invoicefdp.exe")
    }

    @Test func replacesReservedCharacters() {
        #expect(FilenameSanitizer.sanitize("a:b*c?.pdf") == "a_b_c_.pdf")
    }

    @Test func limitsLengthKeepingExtension() {
        let long = String(repeating: "很", count: 300) + ".pdf"
        let result = FilenameSanitizer.sanitize(long)
        #expect(result.count <= FilenameSanitizer.maxLength)
        #expect(result.hasSuffix(".pdf"))
    }

    @Test func decodesPercentEncodedHeader() {
        let encoded = FilenameSanitizer.encodeHeader("../期末 報告.pdf")
        #expect(!encoded.contains("/"))
        #expect(encoded.allSatisfy { $0.isASCII })
        #expect(FilenameSanitizer.decodeHeader(encoded) == "期末 報告.pdf")
        #expect(FilenameSanitizer.decodeHeader("%2E%2E%2F%2E%2E%2Fsecret") == "secret")
        #expect(FilenameSanitizer.decodeHeader(nil) == FilenameSanitizer.fallbackName)
        // 不合法的百分比編碼：保留原文再清理
        #expect(FilenameSanitizer.decodeHeader("100%.pdf") == "100%.pdf")
    }
}

@Suite("工作選項")
struct JobOptionsTests {
    @Test func defaults() throws {
        let options = try JobOptions.parse(copies: nil, duplex: nil, color: nil)
        #expect(options == JobOptions(copies: 1, duplex: .none, color: .color))
    }

    @Test func parsesValidValues() throws {
        let options = try JobOptions.parse(copies: "99", duplex: "LONG", color: "mono")
        #expect(options == JobOptions(copies: 99, duplex: .long, color: .mono))
    }

    @Test(arguments: ["0", "100", "-1", "abc", "1.5", "", "１"])
    func rejectsInvalidCopies(value: String) {
        #expect(throws: JobOptions.ParseError.self) { try JobOptions.parse(copies: value, duplex: nil, color: nil) }
    }

    @Test func rejectsInvalidEnums() {
        #expect(throws: JobOptions.ParseError.invalidDuplex("both")) { try JobOptions.parse(copies: nil, duplex: "both", color: nil) }
        #expect(throws: JobOptions.ParseError.invalidColor("gray")) { try JobOptions.parse(copies: nil, duplex: nil, color: "gray") }
    }
}

@Suite("狀態機")
struct JobStatusTests {
    @Test func happyPathWithApproval() throws {
        var job = PrintJob(displayName: "a.pdf", fileKind: .pdf, byteCount: 10, sourceIP: "1.2.3.4", client: "t", status: .pendingApproval, options: JobOptions())
        try job.transition(to: .queued)
        try job.transition(to: .printing)
        try job.transition(to: .done)
        #expect(job.status == .done)
    }

    @Test func rejectAndRetry() throws {
        var job = PrintJob(displayName: "a.pdf", fileKind: .pdf, byteCount: 10, sourceIP: "1.2.3.4", client: "t", status: .pendingApproval, options: JobOptions())
        try job.transition(to: .rejected, message: "不印")
        #expect(job.message == "不印")
        #expect(throws: InvalidTransitionError(from: .rejected, to: .queued)) { try job.transition(to: .queued) }

        var failed = PrintJob(displayName: "b.pdf", fileKind: .pdf, byteCount: 10, sourceIP: "1.2.3.4", client: "t", status: .queued, options: JobOptions())
        try failed.transition(to: .printing)
        try failed.transition(to: .failed)
        try failed.transition(to: .queued) // 重試
        #expect(failed.status == .queued)
    }

    @Test func illegalTransitionsLeaveJobUntouched() {
        var job = PrintJob(displayName: "a.pdf", fileKind: .pdf, byteCount: 10, sourceIP: "1.2.3.4", client: "t", status: .pendingApproval, options: JobOptions())
        let before = job
        #expect(throws: InvalidTransitionError.self) { try job.transition(to: .printing) }
        #expect(throws: InvalidTransitionError.self) { try job.transition(to: .done) }
        #expect(job == before)
    }

    @Test func fullTransitionTable() {
        let allowed: [JobStatus: Set<JobStatus>] = [
            .pendingApproval: [.queued, .rejected],
            .queued: [.printing, .failed, .rejected],
            .printing: [.done, .failed],
            .failed: [.queued],
            .done: [],
            .rejected: [],
        ]
        for from in JobStatus.allCases {
            for to in JobStatus.allCases {
                #expect(from.canTransition(to: to) == (allowed[from]?.contains(to) ?? false), "\(from) → \(to)")
            }
        }
    }

    @Test func dtoUsesChineseText() {
        let job = PrintJob(displayName: "a.pdf", fileKind: .pdf, byteCount: 10, sourceIP: "1.2.3.4", client: "t", status: .pendingApproval, options: JobOptions())
        #expect(job.statusDTO.statusText == "等待核准")
    }
}
