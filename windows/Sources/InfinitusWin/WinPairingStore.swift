import Foundation
import InfinitusCore
import WinSDK

/// Where `infinitus-win pair`/`serve` keep the phone-companion pairing
/// token — the tray's PairingStore (#9 parity) with a user-only DACL in
/// place of 0600, under the per-user profile. Generated once on first
/// use; `pair --rotate` replaces it.
enum WinPairingStore {
    static var defaultPath: URL {
        let base = ProcessInfo.processInfo.environment["APPDATA"]
            ?? (NSHomeDirectory() + "\\AppData\\Roaming")
        return URL(fileURLWithPath: base)
            .appendingPathComponent("Infinitus")
            .appendingPathComponent("pair-token")
    }

    /// The stored token, generating one on first use. A stored token with
    /// stray paste damage (spaces, dashes, lowercase) still normalizes
    /// back to itself — same rule as the tray's PairingStore.
    static func loadOrCreate(path: URL = defaultPath) throws -> String {
        if let existing = try? String(contentsOf: path, encoding: .utf8) {
            let trimmed = MirrorPairing.normalize(existing)
            if !trimmed.isEmpty { return trimmed }
        }
        let token = MirrorPairing.generateToken()
        try store(token, path: path)
        return token
    }

    /// Write the token (create, import or rotate). Fails loud: a token
    /// that printed but didn't persist would silently de-pair the phone
    /// on the next run.
    static func store(_ token: String, path: URL = defaultPath) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let normalized = MirrorPairing.normalize(token)
        guard FileManager.default.createFile(
            atPath: path.path, contents: Data(normalized.utf8)) else {
            throw StoreFailure(path: path.path)
        }
        try restrictToUser(path: path)
    }

    struct StoreFailure: Error { let path: String }

    // MARK: - The DACL

    /// Replace the file's DACL with exactly three entries — SYSTEM,
    /// Administrators, the current user, full control each — and protect
    /// it so nothing inherited merges back in. This is the 0600 of the
    /// tray's PairingStore: the token is a bearer credential.
    static func restrictToUser(path: URL) throws {
        guard let sid = currentUserSid() else { throw StoreFailure(path: "no current user SID") }
        let sddl = Array("D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;\(sid))".utf16) + [0]
        var descriptor: PSECURITY_DESCRIPTOR? = nil
        guard ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl, DWORD(SDDL_REVISION_1), &descriptor, nil), let descriptor else {
            throw StoreFailure(path: "couldn't build the user-only DACL")
        }
        defer { LocalFree(HLOCAL(descriptor)) }
        let wide = Array(path.path.utf16) + [0]
        guard SetFileSecurityW(wide,
                               DWORD(DACL_SECURITY_INFORMATION) | PROTECTED_DACL_SECURITY_INFORMATION,
                               descriptor) else {
            throw StoreFailure(path: "couldn't set the DACL on \(path.path)")
        }
    }

    /// The current token user's SID as SDDL text (`S-1-5-21-…-1000`), the
    /// trustee the DACL grants to.
    static func currentUserSid() -> String? {
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
