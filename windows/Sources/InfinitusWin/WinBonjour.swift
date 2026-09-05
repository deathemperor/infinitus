import Foundation
import InfinitusCore
import WinSDK
#if os(Windows)
import CRT
#endif

/// Bonjour/mDNS advertising on Windows via DnsServiceRegister (windns.h).
///
/// Advertises `<machineName>._infinitus._tcp.local` on the serving port so
/// the phone's `NWBrowser(for: .bonjour(type: "_infinitus._tcp"))` discovers
/// this host without typing an address (docs/plan-windows/02-feed-readonly.md).
///
/// Graceful degradation: if registration fails (some Windows builds refuse
/// without the mDNS feature), prints a one-line fallback notice and lets
/// `serve` continue. Deregisters on exit via `DnsServiceDeRegister`.
final class WinBonjour: @unchecked Sendable {
    static let shared = WinBonjour()

    private let lock = NSLock()
    private var requestPtr: UnsafeMutablePointer<DNS_SERVICE_REGISTER_REQUEST>?
    private var instancePtr: PDNS_SERVICE_INSTANCE?
    private let deregSemaphore = DispatchSemaphore(value: 0)
    private var isDeregistering = false
    private var isHooked = false

    private init() {}

    /// Advertises `<machineName>._infinitus._tcp.local` on `port`.
    /// Prints a status line on success or a clear fallback line on failure.
    @discardableResult
    static func advertise(port: UInt16) -> Bool {
        shared.start(port: port)
    }

    /// Deregisters any active advertisement.
    static func stop() {
        shared.stop()
    }

    private func setupExitHooks() {
        guard !isHooked else { return }
        isHooked = true
        atexit {
            WinBonjour.stop()
        }
        SetConsoleCtrlHandler({ _ in
            WinBonjour.stop()
            return false
        }, true)
    }

    func start(port: UInt16) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        stopLocked()
        setupExitHooks()

        let rawName = WinProcess.machineName
        let machineName = rawName.isEmpty ? "Windows" : rawName
        let serviceName = "\(machineName).\(MirrorTransport.bonjourType).local"
        let hostName = "\(machineName).local"

        var wideInstance = serviceName.utf16.map { WCHAR($0) } + [0]
        var wideHost = hostName.utf16.map { WCHAR($0) } + [0]

        guard let pInst = DnsServiceConstructInstance(
            &wideInstance,
            &wideHost,
            nil,
            nil,
            port,
            0,
            0,
            0,
            nil,
            nil
        ) else {
            print("discovery is unavailable — type the address into the phone manually")
            return false
        }
        self.instancePtr = pInst

        let pReq = UnsafeMutablePointer<DNS_SERVICE_REGISTER_REQUEST>.allocate(capacity: 1)
        pReq.initialize(to: DNS_SERVICE_REGISTER_REQUEST())
        pReq.pointee.Version = ULONG(DNS_QUERY_REQUEST_VERSION1)
        pReq.pointee.InterfaceIndex = 0
        pReq.pointee.pServiceInstance = pInst
        pReq.pointee.pQueryContext = Unmanaged.passUnretained(self).toOpaque()
        pReq.pointee.pRegisterCompletionCallback = { _, context, _ in
            if let context {
                let selfRef = Unmanaged<WinBonjour>.fromOpaque(context).takeUnretainedValue()
                selfRef.lock.lock()
                let dereg = selfRef.isDeregistering
                selfRef.lock.unlock()
                if dereg {
                    selfRef.deregSemaphore.signal()
                }
            }
        }
        self.requestPtr = pReq
        self.isDeregistering = false

        let status = DnsServiceRegister(pReq, nil)
        if status != DWORD(DNS_REQUEST_PENDING) && status != DWORD(ERROR_SUCCESS) {
            stopLocked()
            print("discovery is unavailable — type the address into the phone manually")
            return false
        }

        print("advertising \(serviceName) on port \(port)")
        return true
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopLocked()
    }

    private func stopLocked() {
        guard let pReq = requestPtr else {
            if let pInst = instancePtr {
                DnsServiceFreeInstance(pInst)
                instancePtr = nil
            }
            return
        }

        isDeregistering = true
        let status = DnsServiceDeRegister(pReq, nil)
        if status == DWORD(DNS_REQUEST_PENDING) {
            _ = deregSemaphore.wait(timeout: .now() + .milliseconds(300))
        }

        requestPtr = nil
        pReq.deallocate()

        if let pInst = instancePtr {
            DnsServiceFreeInstance(pInst)
            instancePtr = nil
        }
    }
}
