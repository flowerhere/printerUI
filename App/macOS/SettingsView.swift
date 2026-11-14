import MFConnectCore
import MFConnectServer
import SwiftUI

/// 設定視窗。修改後按「套用」才生效（避免輸入連接埠時伺服器一直重啟）。
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ServerSettings()
    @State private var loaded = false
    @State private var portText = ""

    private var maxUploadMB: Binding<Int> {
        Binding(
            get: { Int(draft.maxUploadBytes / 1_048_576) },
            set: { draft.maxUploadBytes = Int64($0) * 1_048_576 }
        )
    }

    var body: some View {
        Form {
            Section("伺服器") {
                TextField("伺服器名稱", text: $draft.serverName)
                TextField("連接埠", text: $portText)
                    .onChange(of: portText) { _, new in
                        if let value = Int(new.filter(\.isNumber)) { draft.port = value }
                    }
                Picker("綁定介面", selection: $draft.bindInterface) {
                    Text("所有網卡").tag(String?.none)
                    ForEach(model.interfaces) { iface in
                        Text(iface.displayName).tag(Optional(iface.name))
                    }
                }
                Text("只綁定指定介面時，其他網路（例如 VPN、第二張網卡）上的裝置將無法連線。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("印表機") {
                if model.printers.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("找不到任何印表機佇列", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("請先到「系統設定 → 印表機與掃描器」按「＋」，選擇 Canon MF642C/643C 並以「AirPrint」加入，完成後按「重新整理」。")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Picker("印表機", selection: $draft.printerName) {
                        Text("（未選擇）").tag(String?.none)
                        ForEach(model.printers, id: \.self) { name in
                            Text(name).tag(Optional(name))
                        }
                    }
                }
                Button("重新整理印表機清單") { Task { await model.refreshPrinters() } }
                Toggle("試跑模式（不真的列印，只寫紀錄）", isOn: $draft.dryRun)
            }

            Section("列印流程") {
                Toggle("需要我核准才列印", isOn: $draft.requireApproval)
                Stepper("單檔大小上限：\(maxUploadMB.wrappedValue) MB", value: maxUploadMB, in: 1...500, step: 5)
                Stepper("佇列長度上限：\(draft.maxQueueLength)", value: $draft.maxQueueLength, in: 1...200)
            }

            Section("保留期限") {
                Stepper(draft.fileRetentionHours == 0
                        ? "檔案：列印完成後立即刪除"
                        : "檔案：列印完成後保留 \(draft.fileRetentionHours) 小時",
                        value: $draft.fileRetentionHours, in: 0...720)
                Stepper("工作紀錄：保留 \(draft.recordRetentionDays) 天", value: $draft.recordRetentionDays, in: 1...365)
                Text("被拒絕的檔案會立即刪除；失敗的檔案至少保留 24 小時以便重試。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("系統") {
                Toggle("登入時自動啟動", isOn: $draft.launchAtLogin)
                Text("狀態：\(model.loginItemStatusText)").font(.caption).foregroundStyle(.secondary)
                Toggle("防止閒置睡眠", isOn: $draft.preventIdleSleep)
                Text("開啟後，MFConnect 執行期間 Mac 不會因為閒置而自動睡眠（螢幕仍可關閉）；手動選擇「睡眠」仍會睡眠。Mac mini 若已在「系統設定 → 能源」設定為不睡眠，可不開啟。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("安全") {
                Toggle("QR code 內含 token", isOn: $draft.qrIncludesToken)
                Text("方便家人掃描後直接使用，但看到 QR code 的人都能列印。關閉後掃描者需自行輸入 token。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.lockedIPs.isEmpty {
                    Text("目前沒有被鎖定的 IP").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("已鎖定（token 錯誤 5 次，鎖 10 分鐘）：\(model.lockedIPs.joined(separator: "、"))")
                        .font(.caption)
                    Button("解除所有鎖定") { model.unlockAllIPs() }
                }
                Text("連線為明文 HTTP，請只在家中區網使用；不要把連接埠開放到網際網路。")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Button("還原") { load() }
                Spacer()
                Button("套用") { model.apply(draft); load() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.clamped() == model.settings)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 560)
        .onAppear {
            if !loaded { load(); loaded = true }
            Task { await model.refreshLockedIPs() }
        }
    }

    private func load() {
        draft = model.settings
        portText = String(model.settings.port)
    }
}
