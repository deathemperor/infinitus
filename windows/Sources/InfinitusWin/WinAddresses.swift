import Foundation
import WinSDK

/// IPv4 interface addresses for `pair` — the GetAdaptersAddresses twin of
/// `PosixInterfaceAddresses.ipv4()` (same filters, same first-match wins:
/// `MirrorPairing.lanAddress` takes the first real private address).
enum WinAddresses {
    /// Every IPv4 address on an up, non-loopback adapter, in adapter
    /// order, de-duplicated. No Winsock init needed: the addresses are
    /// read out of the sockaddr bytes directly.
    static func ipv4() -> [String] {
        var size: ULONG = 16 * 1024
        for _ in 0..<3 {
            // Allocate AT LEAST `size` bytes: the API writes up to *size
            // and returns ERROR_BUFFER_OVERFLOW with `size` set to what it
            // needs (reported low on a busy box, so retry with headroom).
            let stride = MemoryLayout<IP_ADAPTER_ADDRESSES_LH>.stride
            let buffer = UnsafeMutablePointer<IP_ADAPTER_ADDRESSES_LH>.allocate(
                capacity: (Int(size) + stride - 1) / stride)
            defer { buffer.deallocate() }
            let flags = ULONG(GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST
                                | GAA_FLAG_SKIP_DNS_SERVER)
            let error = GetAdaptersAddresses(DWORD(AF_INET), flags, nil, buffer, &size)
            guard error != DWORD(ERROR_BUFFER_OVERFLOW) else { size *= 2; continue }
            guard error == DWORD(ERROR_SUCCESS) else { return [] }
            var found: [String] = []
            var adapter: UnsafeMutablePointer<IP_ADAPTER_ADDRESSES_LH>? = buffer
            while let current = adapter {
                let info = current.pointee
                if info.OperStatus == IfOperStatusUp,
                   info.IfType != DWORD(IF_TYPE_SOFTWARE_LOOPBACK) {
                    var unicast = info.FirstUnicastAddress
                    while let entry = unicast {
                        if let text = ipv4(entry.pointee.Address.lpSockaddr),
                           !found.contains(text) { found.append(text) }
                        unicast = entry.pointee.Next
                    }
                }
                adapter = info.Next
            }
            return found
        }
        return []
    }

    /// The dotted quad of a `sockaddr_in` — family occupies the first two
    /// bytes, the address the four from offset 4.
    static func ipv4(_ address: UnsafeMutablePointer<SOCKADDR>?) -> String? {
        guard let address else { return nil }
        let raw = UnsafeRawPointer(address)
        guard raw.load(fromByteOffset: 0, as: UInt16.self) == UInt16(AF_INET) else { return nil }
        let octets = (4...7).map { raw.load(fromByteOffset: $0, as: UInt8.self) }
        return octets.map(String.init).joined(separator: ".")
    }
}
