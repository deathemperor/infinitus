import Foundation
import WinSDK

/// Start-with-Windows via the per-user Run key:
/// HKCU\Software\Microsoft\Windows\CurrentVersion\Run -> "Infinitus Tray"
enum TrayAutostart {
    private static let subKey = #"Software\Microsoft\Windows\CurrentVersion\Run"#
    private static let valueName = "Infinitus Tray"

    static func isEnabled() -> Bool {
        var hKey: HKEY?
        let status = subKey.withCString(encodedAs: UTF16.self) { pSubKey in
            RegOpenKeyExW(HKEY_CURRENT_USER, pSubKey, 0, REGSAM(KEY_QUERY_VALUE), &hKey)
        }
        guard status == ERROR_SUCCESS, let hKey else { return false }
        defer { RegCloseKey(hKey) }

        return valueName.withCString(encodedAs: UTF16.self) { pValName in
            var type: DWORD = 0
            var size: DWORD = 0
            let queryStatus = RegQueryValueExW(hKey, pValName, nil, &type, nil, &size)
            return queryStatus == ERROR_SUCCESS && type == DWORD(REG_SZ) && size > 0
        }
    }

    /// Returns whether the change stuck.
    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        var hKey: HKEY?
        let openStatus = subKey.withCString(encodedAs: UTF16.self) { pSubKey in
            RegOpenKeyExW(hKeyRoot, pSubKey, 0, REGSAM(KEY_SET_VALUE), &hKey)
        }
        guard openStatus == ERROR_SUCCESS, let hKey else {
            return !on && !isEnabled()
        }
        defer { RegCloseKey(hKey) }

        if on {
            var buffer = [WCHAR](repeating: 0, count: 1024)
            let len = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
            guard len > 0 && len < buffer.count else { return false }
            let exePath = String(decodingCString: buffer, as: UTF16.self)
            let quoted = "\"\(exePath)\""
            let units = Array(quoted.utf16) + [0]
            let byteCount = DWORD(units.count * MemoryLayout<WCHAR>.size)

            let setStatus = valueName.withCString(encodedAs: UTF16.self) { pValName in
                units.withUnsafeBytes { raw in
                    RegSetValueExW(
                        hKey,
                        pValName,
                        0,
                        DWORD(REG_SZ),
                        raw.baseAddress?.assumingMemoryBound(to: BYTE.self),
                        byteCount
                    )
                }
            }
            return setStatus == ERROR_SUCCESS && isEnabled()
        } else {
            let delStatus = valueName.withCString(encodedAs: UTF16.self) { pValName in
                RegDeleteValueW(hKey, pValName)
            }
            return (delStatus == ERROR_SUCCESS || delStatus == ERROR_FILE_NOT_FOUND) && !isEnabled()
        }
    }

    private static var hKeyRoot: HKEY {
        HKEY_CURRENT_USER
    }
}
