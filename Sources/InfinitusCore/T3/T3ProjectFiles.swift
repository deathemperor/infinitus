import Foundation

/// The phone's file browser (#223, spec E `…/files/:path*`): a session's
/// workspace as one flat list, and one file's text.
///
/// Upstream answers `projects.listEntries` / `projects.readFile`
/// (`packages/contracts/src/project.ts`) and the phone builds the tree from
/// the flat list (`fileTree.ts`) — so one round trip fills the browser and
/// its search stays local. Foundation only: the phone links this too, and the
/// listing reuses `T3FileMention`'s source (`git ls-files` + the bounded walk
/// behind it) rather than growing a second one.
public enum T3ProjectFiles: Sendable {
    // MARK: - The wire

    /// `GET /sessions/<pid>/files` — the whole workspace, flat.
    public static func filesPath(pid: Int32) -> String { "/sessions/\(pid)/files" }
    /// `GET /sessions/<pid>/file?path=<rel>` — one file's text.
    public static func filePath(pid: Int32) -> String { "/sessions/\(pid)/file" }
    /// The cwd-relative path the read route asks for.
    public static let pathQueryName = "path"

    /// A monorepo's checkout is listed to here and no further; past it the
    /// reply says `truncated` and the phone's search stays honest about it.
    public static let entryCap = 20_000
    /// 256 KiB of one file — enough for any source file the phone previews.
    public static let readCap = 256 * 1024
    /// How much of the head decides "binary" (upstream's own sniff window).
    static let sniffBytes = 8 * 1024

    public enum Kind: String, Codable, Sendable { case file, directory }

    public struct Entry: Codable, Sendable, Equatable {
        /// cwd-relative, `/`-separated, no leading `./`.
        public let path: String
        public let kind: Kind
        /// Bytes, files only.
        public let size: Int?
        public init(path: String, kind: Kind, size: Int? = nil) {
            self.path = path; self.kind = kind; self.size = size
        }
    }

    public struct Listing: Codable, Sendable, Equatable {
        public let cwd: String
        public let entries: [Entry]
        public let truncated: Bool
        public init(cwd: String, entries: [Entry], truncated: Bool) {
            self.cwd = cwd; self.entries = entries; self.truncated = truncated
        }
    }

    public struct FileRead: Codable, Sendable, Equatable {
        public let path: String
        public let contents: String
        /// The whole file's size, even when `contents` was cut at the cap.
        public let byteLength: Int
        public let truncated: Bool
        public let mime: String
        public init(path: String, contents: String, byteLength: Int, truncated: Bool, mime: String) {
            self.path = path; self.contents = contents; self.byteLength = byteLength
            self.truncated = truncated; self.mime = mime
        }
    }

    /// Every non-200 body on the two routes: `{"error": "…"}`.
    public struct Failure: Codable, Sendable, Equatable {
        public let error: String
        public init(error: String) { self.error = error }
    }

    /// The listing's own failures; `status`/`message` are what the route answers.
    public enum ListError: Error, Sendable, Equatable {
        /// The session's cwd no longer exists.
        case rootGone
        case failed(String)

        public var status: Int {
            switch self {
            case .rootGone: return 404
            case .failed: return 500
            }
        }
        public var message: String {
            switch self {
            case .rootGone: return "cwd gone"
            case .failed(let message): return message
            }
        }
    }

    /// The read's failures, in the order they are checked.
    public enum ReadError: Error, Sendable, Equatable {
        /// Missing, absolute, `..`, or a symlink leaving the workspace.
        case outsideRoot
        case notFound
        /// A NUL in the head, or an image/video/pdf extension.
        case binary
        case failed(String)

        public var status: Int {
            switch self {
            case .outsideRoot: return 400
            case .notFound: return 404
            case .binary: return 415
            case .failed: return 500
            }
        }
        public var message: String {
            switch self {
            case .outsideRoot: return "path outside workspace"
            case .notFound: return "no such file"
            case .binary: return "binary file"
            case .failed(let message): return message
            }
        }
    }

    // MARK: - Listing

    /// Every file under `root` plus each of their ancestor directories, sorted
    /// by path and capped. Blocking (a `git` spawn or a tree walk): the caller
    /// runs it off the serving queue.
    public static func list(root: String, cap: Int = entryCap,
                            fileManager: FileManager = .default) -> Result<Listing, ListError> {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(.rootGone)
        }
        // One file over the cap is all it takes to know the answer is
        // truncated; under it, every ancestor directory can be derived exactly.
        let files = T3FileMention.list(cwd: root, fileManager: fileManager, limit: cap + 1)
        var truncated = files.count > cap
        var entries: [Entry] = []
        var directories: Set<String> = []
        entries.reserveCapacity(files.count)
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        for relative in files {
            var components = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard let name = components.popLast(), !isSkipped(components) else { continue }
            let url = components.reduce(rootURL) { $0.appendingPathComponent($1) }
                .appendingPathComponent(name)
            // A tracked-but-deleted path stats nowhere: it is not in the
            // workspace, so it is not in the listing either.
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { continue }
            entries.append(Entry(path: relative, kind: .file, size: size))
            var prefix = ""
            for component in components {
                prefix = prefix.isEmpty ? component : prefix + "/" + component
                guard directories.insert(prefix).inserted else { continue }
                entries.append(Entry(path: prefix, kind: .directory))
            }
        }
        entries.sort { $0.path < $1.path }
        if entries.count > cap {
            truncated = true
            entries = Array(entries.prefix(cap))
        }
        return .success(Listing(cwd: root, entries: entries, truncated: truncated))
    }

    // MARK: - Reading

    /// One file's text under `root`. `path` is cwd-relative; symlinks are
    /// resolved and anything outside `root` refused.
    public static func read(root: String, path: String, cap: Int = readCap,
                            fileManager: FileManager = .default) -> Result<FileRead, ReadError> {
        guard let relative = normalized(path) else { return .failure(.outsideRoot) }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let target = relative.split(separator: "/", omittingEmptySubsequences: true)
            .reduce(rootURL) { $0.appendingPathComponent(String($1)) }
        // `fileExists` follows symlinks, so a dangling one is missing, not
        // an escape — 404 before the prefix check has anything to compare.
        guard fileManager.fileExists(atPath: target.path) else { return .failure(.notFound) }
        // The same canonicalizer on both sides: on macOS `/var` resolves to
        // `/private/var`, so a root that skipped this would never match.
        let resolvedRoot = rootURL.resolvingSymlinksInPath().path
        let resolved = target.resolvingSymlinksInPath()
        let prefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        guard resolved.path.hasPrefix(prefix) else { return .failure(.outsideRoot) }
        guard (try? resolved.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
            return .failure(.notFound)
        }
        let mime = self.mime(for: relative)
        if binaryExtensions.contains(extensionName(of: relative)) { return .failure(.binary) }
        guard let handle = try? FileHandle(forReadingFrom: resolved) else {
            return .failure(.failed("cannot open \(relative)"))
        }
        defer { try? handle.close() }
        let head: Data
        do { head = try handle.read(upToCount: cap) ?? Data() } catch {
            return .failure(.failed("cannot read \(relative)"))
        }
        if head.prefix(sniffBytes).contains(0) { return .failure(.binary) }
        let byteLength = (try? resolved.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? head.count
        let truncated = byteLength > cap
        let body = truncated ? utf8Prefix(head) : head
        return .success(FileRead(path: relative, contents: String(decoding: body, as: UTF8.self),
                                 byteLength: byteLength, truncated: truncated, mime: mime))
    }

    /// The build and vendor trees the browser never lists (#223 names
    /// `.git`, `node_modules`, `.build`). The walk already skips them; this
    /// is for the `git ls-files` source, which lists an un-gitignored
    /// `node_modules` like any other untracked file.
    static func isSkipped(_ directories: [String]) -> Bool {
        directories.contains { T3FileMention.skippedDirectories.contains($0) }
    }

    /// The requested path as this module accepts it: cwd-relative,
    /// `/`-separated, `.` segments dropped. `nil` is a refusal — empty,
    /// absolute, or reaching up out of the workspace.
    static func normalized(_ path: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/") else { return nil }
        var parts: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { return nil }
            parts.append(String(component))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "/")
    }

    /// `data` cut back to the last complete UTF-8 scalar, so the cap never
    /// hands the phone a replacement character it invented. At most three
    /// bytes go: a scalar is four bytes at most.
    static func utf8Prefix(_ data: Data) -> Data {
        var end = data.count
        var back = 0
        while end > 0, back < 4 {
            let byte = data[data.startIndex + end - 1]
            if byte & 0b1100_0000 == 0b1000_0000 {   // a continuation byte: keep walking back
                end -= 1; back += 1
                continue
            }
            let expected: Int
            switch byte {
            case 0x00...0x7F: expected = 1
            case 0xC0...0xDF: expected = 2
            case 0xE0...0xEF: expected = 3
            default: expected = 4
            }
            // The lead byte plus the continuation bytes already walked past:
            // a complete scalar stays, an incomplete one goes with them.
            return data.prefix(expected == back + 1 ? end + back : end - 1)
        }
        return data.prefix(end)
    }

    /// The extension, lowercased, without the dot.
    static func extensionName(of path: String) -> String {
        guard let name = path.split(separator: "/", omittingEmptySubsequences: true).last,
              let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    /// What the phone branches its preview on. Everything unlisted is text:
    /// the NUL sniff, not the extension, is what says otherwise.
    public static func mime(for path: String) -> String {
        mimeByExtension[extensionName(of: path)] ?? "text/plain"
    }

    static let mimeByExtension: [String: String] = [
        "md": "text/markdown", "markdown": "text/markdown", "mdx": "text/markdown",
        "json": "application/json", "xml": "application/xml",
        "yml": "application/yaml", "yaml": "application/yaml", "toml": "application/toml",
        "js": "text/javascript", "mjs": "text/javascript", "cjs": "text/javascript",
        "jsx": "text/javascript", "ts": "text/typescript", "tsx": "text/typescript",
        "swift": "text/x-swift", "py": "text/x-python", "rb": "text/x-ruby",
        "rs": "text/x-rust", "go": "text/x-go", "java": "text/x-java", "kt": "text/x-kotlin",
        "c": "text/x-c", "h": "text/x-c", "cpp": "text/x-c++", "hpp": "text/x-c++",
        "m": "text/x-objcsrc", "mm": "text/x-objcsrc",
        "sh": "text/x-shellscript", "bash": "text/x-shellscript", "zsh": "text/x-shellscript",
        "html": "text/html", "css": "text/css", "txt": "text/plain",
    ]

    /// No preview on the phone, so the read route refuses them outright
    /// (an image is served by the images route, not as text).
    static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif", "ico", "icns",
        "pdf", "mp4", "mov", "m4v", "avi", "mkv", "webm",
    ]
}
