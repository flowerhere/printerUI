#if canImport(Network) && canImport(Observation)
import Foundation
import MFConnectCore
import Network
import Observation

/// 以 Bonjour 搜尋區網中的 MFConnect 伺服器（`_mfconnect._tcp`）。
@MainActor
@Observable
public final class ServerBrowser {
    public struct DiscoveredServer: Identifiable, Hashable {
        public var id: String { serviceName }
        public var serviceName: String
        public var displayName: String
        public var requiresApproval: Bool?
        /// TXT 記錄中的 `<主機名>.local`；可能沒有。
        public var host: String?
        let endpoint: NWEndpoint

        public static func == (lhs: Self, rhs: Self) -> Bool { lhs.serviceName == rhs.serviceName }
        public func hash(into hasher: inout Hasher) { hasher.combine(serviceName) }
    }

    public enum State: Equatable {
        case idle
        case searching
        case failed(String)
    }

    public private(set) var servers: [DiscoveredServer] = []
    public private(set) var state: State = .idle
    private var browser: NWBrowser?

    public init() {}

    public func start() {
        stop()
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: MFConnectConstants.bonjourServiceType, domain: nil), using: parameters)
        // browser 在 main queue 上執行，所以 handler 一定在主執行緒被呼叫。
        browser.stateUpdateHandler = { [weak self] newState in
            MainActor.assumeIsolated {
                switch newState {
                case .ready: self?.state = .searching
                case .failed(let error): self?.state = .failed(Self.describe(error))
                case .waiting(let error): self?.state = .failed(Self.describe(error))
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                self?.update(with: results)
            }
        }
        browser.start(queue: .main)
        self.browser = browser
        state = .searching
    }

    private func update(with results: Set<NWBrowser.Result>) {
        let found: [DiscoveredServer] = results.compactMap { result in
            guard case let .service(name, _, _, _) = result.endpoint else { return nil }
            var displayName = name
            var approval: Bool?
            var host: String?
            if case let .bonjour(txt) = result.metadata {
                let dict = txt.dictionary
                if let n = dict[MFConnectConstants.TXTKey.serverName], !n.isEmpty { displayName = n }
                if let a = dict[MFConnectConstants.TXTKey.requiresApproval] { approval = (a == "1") }
                if let h = dict[MFConnectConstants.TXTKey.host], !h.isEmpty { host = h }
            }
            return DiscoveredServer(serviceName: name, displayName: displayName, requiresApproval: approval, host: host, endpoint: result.endpoint)
        }
        servers = found.sorted { $0.displayName < $1.displayName }
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        state = .idle
    }

    /// 取得可用的 base URL：優先使用 TXT 中的 `.local` 主機名（IP 變動也不受影響），
    /// 否則實際連線一次解析出 IP 與連接埠。
    public func resolveURL(for server: DiscoveredServer) async throws -> URL {
        let hostPort = try await Self.resolve(endpoint: server.endpoint)
        var hostName = server.host ?? hostPort.host
        if hostName.contains(":") { hostName = "[\(hostName)]" } // IPv6 位址需加方括號
        var components = URLComponents()
        components.scheme = "http"
        components.host = hostName
        components.port = hostPort.port
        guard let url = components.url else { throw ClientError.invalidServerURL }
        return url
    }

    private nonisolated static func resolve(endpoint: NWEndpoint) async throws -> (host: String, port: Int) {
        let box = ConnectionBox(NWConnection(to: endpoint, using: .tcp))
        let queue = DispatchQueue(label: "MFConnect.resolve")
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeOnce()
            box.connection.stateUpdateHandler = { state in
                let connection = box.connection
                switch state {
                case .ready:
                    defer { connection.cancel() }
                    if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint {
                        var hostString: String
                        switch host {
                        case .ipv4(let a): hostString = "\(a)"
                        case .ipv6(let a): hostString = "\(a)"
                        case .name(let n, _): hostString = n
                        @unknown default: hostString = "\(host)"
                        }
                        // 去掉 IPv6 的 zone（%en0）與 IPv4 的 zone
                        if let percent = hostString.firstIndex(of: "%") { hostString = String(hostString[..<percent]) }
                        if resumed.claim() { continuation.resume(returning: (hostString, Int(port.rawValue))) }
                    } else if resumed.claim() {
                        continuation.resume(throwing: ClientError.invalidServerURL)
                    }
                case .failed(let error), .waiting(let error):
                    connection.cancel()
                    if resumed.claim() { continuation.resume(throwing: ClientError.network(error.localizedDescription)) }
                default:
                    break
                }
            }
            box.connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 8) {
                box.connection.cancel()
                if resumed.claim() { continuation.resume(throwing: ClientError.network("解析逾時")) }
            }
        }
    }

    private nonisolated static func describe(_ error: NWError) -> String {
        if case .dns(let code) = error, code == -65570 /* kDNSServiceErr_PolicyDenied */ {
            return "沒有區域網路權限：請到「設定 → 隱私權與安全性 → 區域網路」允許 MFConnect"
        }
        return error.localizedDescription
    }
}

/// NWConnection 只在自己的 queue 上使用；包裝起來以便放進 @Sendable closure。
private final class ConnectionBox: @unchecked Sendable {
    let connection: NWConnection
    init(_ connection: NWConnection) { self.connection = connection }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}
#endif
