import Foundation
import WinSDK

/// Balloon notifications via Shell_NotifyIconW with NIF_INFO.
enum TrayNotify {
    /// Sends a balloon. Safe to call when the shell suppresses balloons.
    static func balloon(_ hwnd: HWND, title: String, body: String) {
        var data = NOTIFYICONDATAW()
        data.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
        data.hWnd = hwnd
        data.uID = 1
        data.uFlags = UINT(NIF_INFO)
        data.dwInfoFlags = DWORD(NIIF_INFO)

        withUnsafeMutableBytes(of: &data.szInfo) { raw in
            let slot = raw.bindMemory(to: WCHAR.self)
            let text = Array(body.utf16.prefix(slot.count - 1)) + [0]
            for (index, unit) in text.enumerated() { slot[index] = unit }
        }

        withUnsafeMutableBytes(of: &data.szInfoTitle) { raw in
            let slot = raw.bindMemory(to: WCHAR.self)
            let text = Array(title.utf16.prefix(slot.count - 1)) + [0]
            for (index, unit) in text.enumerated() { slot[index] = unit }
        }

        _ = Shell_NotifyIconW(DWORD(NIM_MODIFY), &data)
    }

    /// Decides what (if anything) to announce given the previous and current
    /// session snapshot — pure, testable, no Win32.
    ///
    /// Announce:
    /// - session transitioning to `waiting` (needs user).
    /// - session disappearing while it was `busy` (stopped unexpectedly).
    ///
    /// Quiet about:
    /// - routine `busy` <-> `idle` churn.
    /// - sessions disappearing from `idle` or other non-busy states.
    /// - existing sessions staying in `waiting` across ticks.
    static func transitions(previous: [Int32: String], current: [Int32: String],
                            names: [Int32: String] = [:]) -> [String] {
        // An empty `previous` is the first tick, not a world where every
        // session just changed: announcing then would greet the user with
        // a balloon per already-waiting session at every launch.
        guard !previous.isEmpty else { return [] }
        let label = { (pid: Int32) in names[pid].map { "\($0) (\(pid))" } ?? "Session \(pid)" }
        var lines: [String] = []

        // Announce a session transitioning to waiting
        for (pid, status) in current.sorted(by: { $0.key < $1.key }) {
            if status == "waiting" && previous[pid] != nil && previous[pid] != "waiting" {
                lines.append("\(label(pid)) is waiting for input")
            }
        }

        // Announce a session disappearing while it was busy
        for (pid, prevStatus) in previous.sorted(by: { $0.key < $1.key }) {
            if current[pid] == nil && prevStatus == "busy" {
                lines.append("\(label(pid)) stopped while busy")
            }
        }

        return lines
    }
}
