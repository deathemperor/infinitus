import Foundation
import WinSDK

/// DPAPI and Win32 DACL helpers for secrets on Windows.
public enum WinSecret {
    /// Protect plaintext using DPAPI (CryptProtectData) for the current user.
    public static func protect(_ plaintext: String) -> Data? {
        let utf8 = Array(plaintext.utf8)
        guard !utf8.isEmpty else {
            // Empty string protected
            var blobIn = DATA_BLOB()
            blobIn.cbData = 0
            blobIn.pbData = nil
            var blobOut = DATA_BLOB()
            let ok = CryptProtectData(&blobIn, nil, nil, nil, nil, DWORD(CRYPTPROTECT_UI_FORBIDDEN), &blobOut)
            guard ok, let pbOut = blobOut.pbData else { return nil }
            defer { LocalFree(HLOCAL(pbOut)) }
            return Data(bytes: pbOut, count: Int(blobOut.cbData))
        }

        return utf8.withUnsafeBufferPointer { buf in
            var blobIn = DATA_BLOB()
            blobIn.cbData = DWORD(buf.count)
            blobIn.pbData = UnsafeMutablePointer<BYTE>(mutating: buf.baseAddress)
            var blobOut = DATA_BLOB()
            let ok = CryptProtectData(&blobIn, nil, nil, nil, nil, DWORD(CRYPTPROTECT_UI_FORBIDDEN), &blobOut)
            guard ok, let pbOut = blobOut.pbData else { return nil }
            defer { LocalFree(HLOCAL(pbOut)) }
            return Data(bytes: pbOut, count: Int(blobOut.cbData))
        }
    }

    /// Unprotect ciphertext using DPAPI (CryptUnprotectData).
    public static func unprotect(_ blob: Data) -> String? {
        guard !blob.isEmpty else {
            var blobIn = DATA_BLOB()
            blobIn.cbData = 0
            blobIn.pbData = nil
            var blobOut = DATA_BLOB()
            let ok = CryptUnprotectData(&blobIn, nil, nil, nil, nil, DWORD(CRYPTPROTECT_UI_FORBIDDEN), &blobOut)
            guard ok else { return nil }
            if let pbOut = blobOut.pbData {
                defer { LocalFree(HLOCAL(pbOut)) }
                return String(decoding: UnsafeBufferPointer(start: pbOut, count: Int(blobOut.cbData)), as: UTF8.self)
            }
            return ""
        }

        return blob.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return nil }
            var blobIn = DATA_BLOB()
            blobIn.cbData = DWORD(raw.count)
            blobIn.pbData = UnsafeMutablePointer<BYTE>(mutating: base.assumingMemoryBound(to: BYTE.self))
            var blobOut = DATA_BLOB()
            let ok = CryptUnprotectData(&blobIn, nil, nil, nil, nil, DWORD(CRYPTPROTECT_UI_FORBIDDEN), &blobOut)
            guard ok, let pbOut = blobOut.pbData else { return nil }
            defer { LocalFree(HLOCAL(pbOut)) }
            return String(decoding: UnsafeBufferPointer(start: pbOut, count: Int(blobOut.cbData)), as: UTF8.self)
        }
    }

    /// Replace the file's DACL with SYSTEM, Administrators, and the current user (user-only ACL).
    public static func restrictToUser(path: URL) throws {
        guard let sid = currentUserSid() else {
            throw NSError(domain: "WinSecret", code: 1, userInfo: [NSLocalizedDescriptionKey: "No current user SID"])
        }
        let sddl = Array("D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;\(sid))".utf16) + [0]
        var descriptor: PSECURITY_DESCRIPTOR? = nil
        guard ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl, DWORD(SDDL_REVISION_1), &descriptor, nil), let descriptor else {
            throw NSError(domain: "WinSecret", code: 2, userInfo: [NSLocalizedDescriptionKey: "Couldn't build user-only DACL"])
        }
        defer { LocalFree(HLOCAL(descriptor)) }
        let wide = Array(path.path.utf16) + [0]
        guard SetFileSecurityW(wide,
                               DWORD(DACL_SECURITY_INFORMATION) | PROTECTED_DACL_SECURITY_INFORMATION,
                               descriptor) else {
            throw NSError(domain: "WinSecret", code: 3, userInfo: [NSLocalizedDescriptionKey: "Couldn't set DACL on \(path.path)"])
        }
    }

    public static func currentUserSid() -> String? {
        var token: HANDLE? = nil
        guard OpenProcessToken(GetCurrentProcess(), DWORD(TOKEN_QUERY), &token),
              let token else { return nil }
        defer { CloseHandle(token) }
        var needed: DWORD = 0
        _ = GetTokenInformation(token, TokenUser, nil, 0, &needed)
        guard needed > 0 else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(needed), alignment: MemoryLayout<TOKEN_USER>.alignment)
        defer { buffer.deallocate() }
        guard GetTokenInformation(token, TokenUser, buffer, needed, &needed) else { return nil }
        let user = buffer.assumingMemoryBound(to: TOKEN_USER.self).pointee
        var sid: PWSTR? = nil
        guard ConvertSidToStringSidW(user.User.Sid, &sid), let sid else { return nil }
        defer { LocalFree(HLOCAL(sid)) }
        return String(decodingCString: sid, as: UTF16.self)
    }
}
