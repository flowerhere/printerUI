import Foundation
import MFConnectCore

/// 組合 Bonjour TXT 記錄（RFC 6763：每筆為「長度 + key=value」）。**絕不放 token。**
public enum BonjourTXT {
    public static func record(serverName: String, requiresApproval: Bool, host: String?) -> [UInt8] {
        var entries: [String: String] = [
            MFConnectConstants.TXTKey.serverName: serverName,
            MFConnectConstants.TXTKey.requiresApproval: requiresApproval ? "1" : "0",
            MFConnectConstants.TXTKey.apiVersion: String(MFConnectConstants.apiVersion),
        ]
        if let host { entries[MFConnectConstants.TXTKey.host] = host }
        var bytes: [UInt8] = []
        for (key, value) in entries.sorted(by: { $0.key < $1.key }) {
            var pair = Array("\(key)=".utf8) + Array(value.utf8)
            if pair.count > 255 { pair = Array(pair.prefix(255)) }
            bytes.append(UInt8(pair.count))
            bytes.append(contentsOf: pair)
        }
        return bytes
    }
}

#if canImport(dnssd)
import dnssd

/// 用 DNS-SD（mDNSResponder）廣播 `_mfconnect._tcp`。
///
/// 使用 C API `DNSServiceRegister` 而不是 `NetService`（後者已不建議使用），
/// 也不需要另外開一個 `NWListener`（實際的 HTTP 伺服器是 Hummingbird）。
public final class BonjourAdvertiser: @unchecked Sendable {
    private var serviceRef: DNSServiceRef?
    private let queue = DispatchQueue(label: "MFConnect.Bonjour")

    public init() {}

    deinit { stopLocked() }

    /// 開始廣播；重複呼叫會先停止舊的廣播。
    @discardableResult
    public func start(serverName: String, port: Int, requiresApproval: Bool, host: String?) -> Bool {
        queue.sync {
            stopLocked()
            let txt = BonjourTXT.record(serverName: serverName, requiresApproval: requiresApproval, host: host)
            var ref: DNSServiceRef?
            let err = txt.withUnsafeBytes { buffer in
                DNSServiceRegister(
                    &ref,
                    0,                       // flags
                    0,                       // 所有介面
                    serverName,              // 服務名稱（重名時自動加編號）
                    MFConnectConstants.bonjourServiceType,
                    nil,                     // 預設網域 local.
                    nil,                     // 使用本機主機名稱
                    UInt16(port).bigEndian,
                    UInt16(buffer.count),
                    buffer.baseAddress,
                    nil,                     // 不需要 callback（名稱衝突會自動改名）
                    nil
                )
            }
            guard err == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else { return false }
            DNSServiceSetDispatchQueue(ref, queue)
            serviceRef = ref
            return true
        }
    }

    public func stop() {
        queue.sync { stopLocked() }
    }

    private func stopLocked() {
        if let ref = serviceRef {
            DNSServiceRefDeallocate(ref)
            serviceRef = nil
        }
    }
}
#endif
