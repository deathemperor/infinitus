import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The host's up, non-loopback IPv4 interfaces with their netmasks —
/// the driver's "is that LAN address in one of my own subnets" check
/// (#220 §5.3). Empty where getifaddrs is not available.
public enum InterfaceAddresses {
    public static func ipv4() -> [TeamControl.Interface] {
        #if canImport(Darwin) || canImport(Glibc)
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var found: [TeamControl.Interface] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            // IFF_UP/IFF_LOOPBACK import as differently-sized integer
            // types across libcs — Int is the common ground.
            let flags = Int(pointer.pointee.ifa_flags)
            guard flags & Int(IFF_UP) == Int(IFF_UP), flags & Int(IFF_LOOPBACK) == 0,
                  let address = pointer.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  let mask = pointer.pointee.ifa_netmask,
                  let a = text(address), let m = text(mask) else { continue }
            let entry = TeamControl.Interface(address: a, mask: m)
            if !found.contains(entry) { found.append(entry) }
        }
        return found
        #else
        return []
        #endif
    }

    #if canImport(Darwin) || canImport(Glibc)
    private static func text(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count),
                          nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: host)
    }
    #endif
}
