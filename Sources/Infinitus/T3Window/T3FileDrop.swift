import AppKit
import UniformTypeIdentifiers

/// The file half of a drop, shared by the composer and the sidebar's thread
/// rows — upstream's one `makeWorkspaceFileDropHandlers`
/// (`components/chat/workspaceFileDrop.ts`) serves `ChatComposer` and
/// `SidebarThreadRow` alike since `bde39d4d7` ("accept file drops into
/// sidebar threads", `Sidebar.tsx:1239-1248`).
///
/// A dropped file arrives as a PROMISE: the item provider resolves the URL on
/// its own queue, so the sink is called back on the main actor once per
/// provider that had one — never in one batch. Both callers are additive
/// (`stage` appends, the window's queue appends), so a per-provider callback
/// is the same result as a batch.
enum T3FileDrop {
    static func loadURLs(_ providers: [NSItemProvider],
                         into sink: @escaping @MainActor ([URL]) -> Void) {
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in sink([url]) }
            }
        }
    }
}

/// The other half: a Files-tab row dragged into the composer, which inserts its
/// mention instead of attaching the file
/// (`createFileTreeDragMentionController`, `fileTreeDragMention.ts:47-94`).
///
/// Upstream tags such a drag with its own transfer type
/// (`COMPOSER_MENTION_DRAG_TYPE`, `composerMentionDrag.ts:8`) precisely so the
/// composer can tell it from an OS file drag (`:18-20`, `:60-68`); the Mac's
/// equivalent is a private UTType with `.ownProcess` visibility — the payload
/// never leaves the app, exactly as upstream's never leaves the page. A plain
/// file URL from Finder still lands on `T3FileDrop` above and still becomes an
/// attachment.
///
/// Upstream drags the whole tree selection when the pressed row is part of it
/// and joins the mentions with a space (`fileTreeDragMention.ts:73-83`); this
/// tree is single-select, so a drag is always exactly one row.
enum T3MentionDrag {
    static let identifier = "run.infinitus.file-mention"
    /// `exportedAs`, not the failable `UTType(_:)`: nothing declares this type
    /// in an Info.plist and the unbundled dev binary has none at all.
    static let type = UTType(exportedAs: identifier)

    static func provider(mention: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: identifier,
                                            visibility: .ownProcess) { done in
            done(Data(mention.utf8), nil)
            return nil
        }
        return provider
    }

    /// The mention a drop carries, handed to `sink` on the main actor once it
    /// resolves (a provider is a promise — `T3FileDrop`'s lesson). False when no
    /// provider had one, which is the caller's cue to treat the drop as files.
    @discardableResult
    static func take(from providers: [NSItemProvider],
                     into sink: @escaping @MainActor (String) -> Void) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(identifier)
        }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
            guard let data, let mention = String(data: data, encoding: .utf8),
                  !mention.isEmpty else { return }
            Task { @MainActor in sink(mention) }
        }
        return true
    }
}
