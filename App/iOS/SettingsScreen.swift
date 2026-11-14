import MFConnectClient
import MFConnectCore
import SwiftUI

/// iOS / iPadOS 主 App：設定伺服器位址與 token，並測試連線。
struct SettingsScreen: View {
    @State private var browser = ServerBrowser()
    @State private var address = ""
    @State private var token = ""
    @State private var serverName: String?
    @State private var testState: TestState = .idle
    @State private var resolvingServer: String?
    @State private var saved = false

    private let settings = SharedSettings.shared
    private let tokenStore = SharedTokenStore()

    enum TestState: Equatable {
        case idle
        case testing
        case success(ServerInfoDTO)
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                discoverySection
                manualSection
                tokenSection
                actionSection
                helpSection
            }
            .navigationTitle("MFConnect")
            .onAppear(perform: load)
            .task { browser.start() }
            .onDisappear { browser.stop() }
        }
    }

    // MARK: - Bonjour

    private var discoverySection: some View {
        Section {
            if browser.servers.isEmpty {
                HStack {
                    if case .failed(let message) = browser.state {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else {
                        ProgressView()
                        Text("正在搜尋區網中的列印伺服器…").foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(browser.servers) { server in
                Button {
                    select(server)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(server.displayName)
                            if let approval = server.requiresApproval {
                                Text(approval ? "需管理者核准" : "自動列印")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if resolvingServer == server.serviceName {
                            ProgressView()
                        } else if serverName == server.displayName {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
            }
        } header: {
            Text("自動搜尋（Bonjour）")
        } footer: {
            Text("找不到時，請確認 iPhone / iPad 與 Mac mini 在同一個 Wi‑Fi，並在「設定 → 隱私權與安全性 → 區域網路」允許 MFConnect。")
        }
    }

    private var manualSection: some View {
        Section {
            TextField("例如 mac-mini.local:8631 或 192.168.1.10", text: $address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
        } header: {
            Text("伺服器位址")
        } footer: {
            Text("可省略 http:// 與連接埠（預設 \(MFConnectConstants.defaultPort)）。")
        }
    }

    private var tokenSection: some View {
        Section {
            SecureField("貼上 Mac mini 選單列中的 token", text: $token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if UIPasteboard.general.hasStrings {
                Button("從剪貼簿貼上") {
                    if let text = UIPasteboard.general.string {
                        token = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        } header: {
            Text("Token")
        } footer: {
            Text("token 存在裝置的鑰匙圈，分享選單也會使用。")
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                save()
            } label: {
                Label(saved ? "已儲存" : "儲存", systemImage: saved ? "checkmark.circle.fill" : "square.and.arrow.down")
            }
            .disabled(MFConnectClient.normalizeServerURL(address) == nil || token.isEmpty)

            Button {
                Task { await testConnection() }
            } label: {
                HStack {
                    Label("測試連線", systemImage: "network")
                    Spacer()
                    if testState == .testing { ProgressView() }
                }
            }
            .disabled(MFConnectClient.normalizeServerURL(address) == nil || token.isEmpty || testState == .testing)

            switch testState {
            case .success(let info):
                VStack(alignment: .leading, spacing: 4) {
                    Label("連線成功", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("伺服器：\(info.serverName)")
                    Text("單檔上限：\(ByteCountFormatter.string(fromByteCount: info.maxUploadBytes, countStyle: .file))")
                    Text(info.requiresApproval ? "列印前需要管理者核准" : "上傳後自動列印")
                }
                .font(.callout)
            case .failure(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            case .idle, .testing:
                EmptyView()
            }
        }
    }

    private var helpSection: some View {
        Section("使用方式") {
            Text("在「照片」、「檔案」或任何 App 中按「分享」，選擇「MFConnect」，設定份數與雙面、黑白後按「傳送」。")
            Text("只支援 PDF 與圖片。Word、Excel 等檔案請先匯出成 PDF。")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    // MARK: - 動作

    private func load() {
        if let url = settings.serverURL {
            address = url.absoluteString.replacingOccurrences(of: "http://", with: "")
        }
        serverName = settings.serverName
        token = tokenStore.load() ?? ""
    }

    private func select(_ server: ServerBrowser.DiscoveredServer) {
        resolvingServer = server.serviceName
        Task {
            defer { resolvingServer = nil }
            do {
                let url = try await browser.resolveURL(for: server)
                address = url.absoluteString.replacingOccurrences(of: "http://", with: "")
                serverName = server.displayName
                saved = false
            } catch {
                testState = .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func save() {
        guard let url = MFConnectClient.normalizeServerURL(address) else { return }
        settings.serverURL = url
        settings.serverName = serverName ?? url.host
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tokenStore.save(trimmed) else {
            testState = .failure("無法寫入鑰匙圈，請確認 App 的簽署與 Keychain Sharing 設定")
            return
        }
        token = trimmed
        saved = true
    }

    private func testConnection() async {
        guard let url = MFConnectClient.normalizeServerURL(address) else { return }
        testState = .testing
        let client = MFConnectClient(baseURL: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines),
                                     clientName: "\(UIDevice.current.model) App")
        do {
            let info = try await client.info()
            serverName = info.serverName
            testState = .success(info)
            save()
        } catch {
            testState = .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

#Preview {
    SettingsScreen()
}
