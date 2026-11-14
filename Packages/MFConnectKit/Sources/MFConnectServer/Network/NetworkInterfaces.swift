import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// 本機的網路介面與 IPv4 位址。
public struct NetworkInterface: Sendable, Hashable, Identifiable {
    public var name: String
    public var ipv4: String
    public var id: String { name + "|" + ipv4 }

    public init(name: String, ipv4: String) {
        self.name = name
        self.ipv4 = ipv4
    }

    public var displayName: String {
        let kind: String
        switch name {
        case "en0": kind = "乙太網路或 Wi‑Fi"
        case let n where n.hasPrefix("en"): kind = "網路介面"
        case let n where n.hasPrefix("bridge"): kind = "橋接"
        case let n where n.hasPrefix("utun"): kind = "VPN"
        default: kind = "介面"
        }
        return "\(name)（\(kind)）\(ipv4)"
    }
}

public enum NetworkInterfaces {
    /// 列出所有已啟用、非 loopback 的 IPv4 介面。
    public static func ipv4Interfaces() -> [NetworkInterface] {
        var result: [NetworkInterface] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & Int32(IFF_UP) != 0, flags & Int32(IFF_LOOPBACK) == 0,
                  let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) || Int32(addr.pointee.sa_family) == AF_INET
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(MemoryLayout<sockaddr_in>.size)
            guard getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let name = String(cString: entry.pointee.ifa_name)
            result.append(NetworkInterface(name: name, ipv4: ip))
        }
        // en0 優先，其次依名稱排序
        return result.sorted { lhs, rhs in
            if lhs.name == "en0" { return rhs.name != "en0" || lhs.ipv4 < rhs.ipv4 }
            if rhs.name == "en0" { return false }
            return (lhs.name, lhs.ipv4) < (rhs.name, rhs.ipv4)
        }
    }

    /// 依設定決定要綁定的位址。指定的介面找不到時回傳 `nil`（不要默默改成全部網卡）。
    public static func bindAddress(forInterface name: String?) -> String? {
        guard let name, !name.isEmpty else { return "0.0.0.0" }
        return ipv4Interfaces().first { $0.name == name }?.ipv4
    }
}
