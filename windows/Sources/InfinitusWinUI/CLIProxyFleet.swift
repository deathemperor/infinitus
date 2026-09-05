import Foundation
import InfinitusCore

/// CLIProxyAPI fleet cache and operations for Windows, paralleling NineRouterFleet.
public enum CLIProxyFleet {
    public static let cacheSeconds: TimeInterval = 30
    public static let timeout: TimeInterval = 20

    public enum SwitchOutcome: Sendable, Equatable {
        case switched(to: Int)
        case noEngine
        case failed(detail: String)

        public var message: String {
            switch self {
            case .switched(let number): return "switched to account \(number)"
            case .noEngine: return "no swap engine installed"
            case .failed(let detail):
                return detail.isEmpty ? "engine refused the switch" : detail
            }
        }
    }

    public struct StoredConfig: Codable, Sendable {
        public var baseURL: String
        public var encryptedKey: Data

        public init(baseURL: String, encryptedKey: Data) {
            self.baseURL = baseURL
            self.encryptedKey = encryptedKey
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cachedFleets: [EngineFleet]?
    private nonisolated(unsafe) static var cachedAt: Date?
    private nonisolated(unsafe) static var isRefreshing = false

    public static var configURL: URL {
        let roaming = ProcessInfo.processInfo.environment["APPDATA"]
            ?? "\(NSHomeDirectory())\\AppData\\Roaming"
        return URL(fileURLWithPath: roaming)
            .appendingPathComponent("Infinitus")
            .appendingPathComponent("cliproxy.json")
    }

    public static func isAvailable() -> Bool {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return false }
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(StoredConfig.self, from: data),
              let key = WinSecret.unprotect(config.encryptedKey), !key.isEmpty else {
            return false
        }
        return true
    }

    public static func loadConfig() -> (baseURL: URL, key: String)? {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(StoredConfig.self, from: data),
              let url = URL(string: config.baseURL),
              let key = WinSecret.unprotect(config.encryptedKey), !key.isEmpty else {
            return nil
        }
        return (url, key)
    }

    /// Marks the cache stale WITHOUT dropping the last known fleets —
    /// the next read refetches and swaps the data in when it lands, so a
    /// panel open across an invalidate keeps its rows instead of wiping.
    public static func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cachedAt = nil
    }

    public static func fleets(now: Date = Date(), wait: Bool = false) -> [EngineFleet]? {
        guard isAvailable() else { return nil }
        lock.lock()
        let fleets = cachedFleets
        let at = cachedAt
        lock.unlock()

        // Cold or stale: refetch. Stale rows keep rendering meanwhile
        // (stale-while-revalidate) instead of collapsing to empty.
        if at == nil || now.timeIntervalSince(at!) >= cacheSeconds {
            refresh(now: now, wait: wait)
        }
        return fleets
    }

    public static func refresh(now: Date = Date(), wait: Bool = false, force: Bool = false) {
        guard isAvailable() else { return }
        lock.lock()
        if isRefreshing && !wait {
            lock.unlock()
            return
        }
        if !force, let at = cachedAt, now.timeIntervalSince(at) < cacheSeconds, cachedFleets != nil {
            lock.unlock()
            return
        }
        isRefreshing = true
        lock.unlock()

        let block = {
            defer {
                lock.lock()
                isRefreshing = false
                lock.unlock()
            }
            guard let cfg = loadConfig() else { return }
            let engine = CLIProxyEngine(baseURL: cfg.baseURL, managementKey: cfg.key)
            let sem = DispatchSemaphore(value: 0)
            var fetched: [EngineFleet]? = nil
            Task {
                fetched = try? await engine.snapshot()
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + timeout)

            lock.lock()
            if let fetched {
                cachedFleets = fetched
                cachedAt = Date()
            }
            lock.unlock()
        }

        if wait {
            block()
        } else {
            Thread.detachNewThread(block)
        }
    }

    public static func switchTo(_ number: Int, provider: Provider) -> SwitchOutcome {
        guard let cfg = loadConfig() else { return .noEngine }
        let engine = CLIProxyEngine(baseURL: cfg.baseURL, managementKey: cfg.key)
        let sem = DispatchSemaphore(value: 0)
        var outcome: SwitchOutcome = .failed(detail: "switch timed out")

        Task {
            do {
                try await engine.switchTo(fleet: provider, number: number)
                outcome = .switched(to: number)
            } catch {
                let msg = (error as? EngineError)?.errorDescription ?? error.localizedDescription
                outcome = .failed(detail: msg)
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
        invalidate()
        refresh(now: Date(), wait: true, force: true)
        return outcome
    }

    public static func setHold(_ number: Int, provider: Provider, held: Bool) -> Bool {
        guard let cfg = loadConfig() else { return false }
        let engine = CLIProxyEngine(baseURL: cfg.baseURL, managementKey: cfg.key)
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        Task {
            do {
                try await engine.setHold(fleet: provider, number: number, held: held)
                ok = true
            } catch {
                ok = false
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
        invalidate()
        refresh(now: Date(), wait: true, force: true)
        return ok
    }

    public static func rename(_ number: Int, provider: Provider, name: String) -> Bool {
        guard let cfg = loadConfig() else { return false }
        let engine = CLIProxyEngine(baseURL: cfg.baseURL, managementKey: cfg.key)
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        Task {
            do {
                try await engine.rename(fleet: provider, number: number, name)
                ok = true
            } catch {
                ok = false
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
        invalidate()
        refresh(now: Date(), wait: true, force: true)
        return ok
    }

    public static func setPreferred(_ number: Int, provider: Provider, on: Bool) -> Bool {
        guard let cfg = loadConfig() else { return false }
        let engine = CLIProxyEngine(baseURL: cfg.baseURL, managementKey: cfg.key)
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        Task {
            do {
                try await engine.setPreferred(fleet: provider, number: number, on)
                ok = true
            } catch {
                ok = false
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
        invalidate()
        refresh(now: Date(), wait: true, force: true)
        return ok
    }

    public static func remove(_ number: Int, provider: Provider) -> Bool {
        guard let cfg = loadConfig() else { return false }
        let engine = CLIProxyEngine(baseURL: cfg.baseURL, managementKey: cfg.key)
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        Task {
            do {
                try await engine.remove(fleet: provider, number: number)
                ok = true
            } catch {
                ok = false
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
        invalidate()
        refresh(now: Date(), wait: true, force: true)
        return ok
    }
}
