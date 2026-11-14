import AppKit
import MFConnectCore
import SwiftUI

struct MenuContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var selectedURL: String?
    @State private var showToken = false
    @State private var confirmRegenerate = false
    @State private var showAllHistory = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let error = model.startupError ?? model.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.status.isRunning { urlSection }
                Divider()
                pendingSection
                if !model.activeJobs.isEmpty {
                    Divider()
                    activeSection
                }
                Divider()
                historySection
                Divider()
                tokenSection
                Divider()
                footer
            }
            .padding(14)
        }
        .frame(width: 380)
        .frame(maxHeight: 640)
        .task { await model.refreshLockedIPs() }
    }

    // MARK: - 標題與開關

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.status.isRunning ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(model.settings.serverName).font(.headline)
                    if model.settings.dryRun {
                        Text("試跑模式")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                            .help("不會真的列印；到設定中關閉「試跑模式」才會送到印表機")
                    }
                }
                Text(model.status.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.settings.requireApproval ? "需核准後才列印" : "全自動列印")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("伺服器", isOn: Binding(
                get: { model.status != .stopped },
                set: { model.setServerEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .help("開啟或關閉列印伺服器")
        }
    }

    // MARK: - 上傳網址

    private var urlSection: some View {
        let urls = model.uploadURLs
        let current = selectedURL.flatMap { urls.contains($0) ? $0 : nil } ?? urls.first ?? ""
        return VStack(alignment: .leading, spacing: 8) {
            Text("上傳網址").font(.subheadline.bold())
            ForEach(urls, id: \.self) { url in
                HStack {
                    Button {
                        selectedURL = url
                    } label: {
                        Text(url)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(url == current ? Color.accentColor : Color.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .help("顯示此網址的 QR code")
                    Spacer()
                    Button("複製") { model.copyToPasteboard(url) }
                        .controlSize(.small)
                }
            }
            if let image = model.qrImage(for: current) {
                HStack {
                    Spacer()
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 160, height: 160)
                        .accessibilityLabel("上傳網址的 QR code")
                    Spacer()
                }
                Text(model.settings.qrIncludesToken
                     ? "QR code 內含 token，掃描即可直接使用；請只給信任的人看。"
                     : "掃描後需輸入 token。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 待核准

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("待核准（\(model.pendingJobs.count)）").font(.subheadline.bold())
                Spacer()
                if model.pendingJobs.count > 1 {
                    Button("全部核准") { model.approveAll() }.controlSize(.small)
                }
            }
            if model.pendingJobs.isEmpty {
                Text("目前沒有待核准的工作").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.pendingJobs) { job in
                VStack(alignment: .leading, spacing: 4) {
                    JobSummary(job: job)
                    HStack {
                        Spacer()
                        Button("拒絕", role: .destructive) { model.reject(job.id) }
                            .controlSize(.small)
                        Button("核准") { model.approve(job.id) }
                            .controlSize(.small)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - 佇列

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("佇列（\(model.activeJobs.count)）").font(.subheadline.bold())
            ForEach(model.activeJobs) { job in
                HStack {
                    JobSummary(job: job)
                    Spacer()
                    if job.status == .printing { ProgressView().controlSize(.small) }
                    if job.status == .queued {
                        Button("取消") { model.reject(job.id) }.controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - 歷史紀錄

    private var historySection: some View {
        let history = model.historyJobs
        let shown = showAllHistory ? history : Array(history.prefix(5))
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("歷史紀錄").font(.subheadline.bold())
                Spacer()
                if history.count > 5 {
                    Button(showAllHistory ? "收合" : "顯示全部（\(history.count)）") { showAllHistory.toggle() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            }
            if history.isEmpty {
                Text("尚無紀錄").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(shown) { job in
                HStack(alignment: .top) {
                    JobSummary(job: job)
                    Spacer()
                    if job.status == .failed, !job.fileDeleted {
                        Button("重試") { model.retry(job.id) }.controlSize(.small)
                    }
                    Button {
                        model.removeRecord(job.id)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("刪除這筆紀錄")
                }
            }
        }
    }

    // MARK: - token

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Token").font(.subheadline.bold())
            Text(showToken ? model.token : String(repeating: "•", count: 24))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
            HStack {
                Button(showToken ? "隱藏" : "顯示") { showToken.toggle() }
                Button("複製") { model.copyToPasteboard(model.token) }
                Spacer()
                Button("重新產生…", role: .destructive) { confirmRegenerate = true }
            }
            .controlSize(.small)
            if !model.lockedIPs.isEmpty {
                Text("已鎖定的 IP：\(model.lockedIPs.joined(separator: "、"))")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .confirmationDialog("重新產生 token？", isPresented: $confirmRegenerate) {
            Button("重新產生", role: .destructive) { model.regenerateToken() }
        } message: {
            Text("舊 token 會立即失效，所有裝置（網頁與 iPhone / iPad）都需要重新輸入新 token。")
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack {
            Button("設定…") {
                openWindow(id: "settings")
                NSApp.activate()
            }
            .keyboardShortcut(",")
            Spacer()
            Button("結束 MFConnect") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

/// 一筆工作的摘要：檔名、選項、來源、狀態。
struct JobSummary: View {
    let job: PrintJob

    /// 一律以台北時間顯示。
    private var timeStyle: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.month(.defaultDigits).day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        style.locale = Locale(identifier: "zh_Hant_TW")
        style.timeZone = TimeZone(identifier: "Asia/Taipei") ?? .current
        return style
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: job.fileKind == .pdf ? "doc.richtext" : "photo")
                    .foregroundStyle(.secondary)
                Text(job.displayName).lineLimit(1).truncationMode(.middle)
            }
            .font(.callout)
            Text("\(job.options.summary)・\(ByteCountFormatter.string(fromByteCount: job.byteCount, countStyle: .file))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(job.sourceIP)・\(job.client)・\(job.createdAt.formatted(timeStyle))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if job.status != .pendingApproval {
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(job.notes, id: \.self) { note in
                Text("・\(note)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var statusLine: String {
        if let message = job.message, !message.isEmpty {
            return "\(job.status.displayName)：\(message)"
        }
        return job.status.displayName
    }

    private var statusColor: Color {
        switch job.status {
        case .done: .green
        case .failed, .rejected: .red
        default: .orange
        }
    }
}
