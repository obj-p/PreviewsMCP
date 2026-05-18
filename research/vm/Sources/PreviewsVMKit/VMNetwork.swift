import Foundation

/// macOS's NAT attachment serves DHCP via the system `bootpd`. Every lease
/// is recorded in `/var/db/dhcpd_leases` in a stanza format:
///
///     {
///         name=guest-host
///         ip_address=192.168.64.42
///         hw_address=1,52:54:0:12:34:56
///         identifier=1,52:54:0:12:34:56
///         lease=0x67200000
///     }
///
/// `hw_address` is `<htype>,<mac>` where htype=1 means Ethernet. MAC octets
/// are NOT zero-padded in the lease file, so `52:54:0:12:34:56` matches a
/// configured `52:54:00:12:34:56`. `normalize(_:)` reconciles the two forms.
public enum VMNetwork {
    public static let defaultLeasesPath = "/var/db/dhcpd_leases"

    public struct Lease: Sendable, Equatable {
        public var name: String?
        public var ipAddress: String
        public var macAddress: String
    }

    /// Return the IP currently leased to `mac`, or nil if no lease is recorded.
    public static func ipAddress(
        forMAC mac: String,
        leasesPath: String = defaultLeasesPath
    ) -> String? {
        guard let leases = readLeases(at: leasesPath) else { return nil }
        let target = normalize(mac)
        return leases.first { normalize($0.macAddress) == target }?.ipAddress
    }

    /// Poll for an IP with a timeout. Used by `boot` after VM start.
    public static func waitForIP(
        mac: String,
        timeout: TimeInterval = 120,
        pollInterval: TimeInterval = 1,
        leasesPath: String = defaultLeasesPath
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var lastErr: String?
        while Date() < deadline {
            if let ip = ipAddress(forMAC: mac, leasesPath: leasesPath) {
                return ip
            } else {
                lastErr = "no lease yet for \(mac)"
            }
            try await Task.sleep(for: .seconds(pollInterval))
        }
        throw VMError(
            "no DHCP lease appeared for MAC \(mac) within \(Int(timeout))s (\(lastErr ?? "unknown reason"))"
        )
    }

    public static func readLeases(at path: String) -> [Lease]? {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return parseLeases(text)
    }

    static func parseLeases(_ text: String) -> [Lease] {
        var leases: [Lease] = []
        var name: String?
        var ip: String?
        var mac: String?

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "{" {
                name = nil; ip = nil; mac = nil
            } else if trimmed == "}" {
                if let ip, let mac {
                    leases.append(Lease(name: name, ipAddress: ip, macAddress: mac))
                }
                name = nil; ip = nil; mac = nil
            } else if let eq = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                switch key {
                case "name":
                    name = value
                case "ip_address":
                    ip = value
                case "hw_address":
                    if let comma = value.firstIndex(of: ",") {
                        mac = String(value[value.index(after: comma)...])
                    } else {
                        mac = value
                    }
                default:
                    break
                }
            }
        }
        return leases
    }

    /// Lowercase + zero-pad each octet to two hex digits. `52:54:0:1:2:3` becomes
    /// `52:54:00:01:02:03`. Needed because dhcpd_leases strips leading zeros but
    /// VZMACAddress/our config retain them.
    static func normalize(_ mac: String) -> String {
        mac.lowercased().split(separator: ":").map { part -> String in
            part.count == 1 ? "0\(part)" : String(part)
        }.joined(separator: ":")
    }
}
