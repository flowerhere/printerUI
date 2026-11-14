import MFConnectCore
import SwiftUI

struct ShareView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                filesSection
                if model.phase != .finished { optionsSection }
                resultSection
            }
            .navigationTitle("傳送到印表機")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if model.phase != .finished {
                        Button("取消") { model.cancel() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.phase == .finished {
                        Button("完成") { model.done() }.bold()
                    } else {
                        Button("傳送") { model.send() }
                            .bold()
                            .disabled(!model.canSend)
                    }
                }
            }
        }
    }

    private var serverSection: some View {
        Section("目標伺服器") {
            if let problem = model.configurationProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.serverInfo?.serverName ?? model.serverName ?? "MFConnect")
                    Text(model.serverURL?.absoluteString ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                    if let info = model.serverInfo {
                        Text(info.requiresApproval ? "需要管理者核准後才會列印" : "上傳後自動列印")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var filesSection: some View {
        Section("檔案（\(model.items.count)）") {
            if model.phase == .loading {
                HStack {
                    ProgressView()
                    Text("正在準備檔案…").foregroundStyle(.secondary)
                }
            }
            ForEach(model.items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: item.kind == .pdf ? "doc.richtext" : "photo")
                            .foregroundStyle(.secondary)
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        stateIcon(for: item)
                    }
                    if let problem = item.problem {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    } else {
                        stateText(for: item)
                    }
                }
            }
            if model.phase == .uploading {
                ProgressView(value: model.overallProgress) {
                    Text("上傳中… \(Int(model.overallProgress * 100))%").font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private func stateIcon(for item: ShareModel.Item) -> some View {
        switch item.state {
        case .sent: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .uploading: ProgressView().controlSize(.small)
        case .waiting:
            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func stateText(for item: ShareModel.Item) -> some View {
        switch item.state {
        case .sent(let status):
            Text(status == .pendingApproval ? "已送出，等待核准" : "已送出，\(status.displayName)")
                .font(.caption).foregroundStyle(.green)
        case .failed(let message):
            Text("失敗：\(message)").font(.caption).foregroundStyle(.red)
        case .uploading(let progress):
            ProgressView(value: progress)
        case .waiting:
            EmptyView()
        }
    }

    private var optionsSection: some View {
        Section("列印選項（套用到全部檔案）") {
            Stepper("份數：\(model.options.copies)", value: $model.options.copies, in: 1...MFConnectConstants.maxCopies)
            Picker("雙面", selection: $model.options.duplex) {
                ForEach(DuplexMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            Picker("色彩", selection: $model.options.color) {
                ForEach(ColorMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
        .disabled(model.phase == .uploading)
    }

    @ViewBuilder
    private var resultSection: some View {
        if model.phase == .finished {
            let summary = model.summary
            Section {
                if summary.failed == 0 {
                    Label(summary.needsApproval
                          ? "已送出 \(summary.sent) 個檔案，等待管理者核准後列印"
                          : "已送出 \(summary.sent) 個檔案",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("\(summary.sent) 個成功、\(summary.failed) 個失敗", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(summary.sent == 0 ? Color.red : Color.orange)
                }
            }
        }
    }
}
