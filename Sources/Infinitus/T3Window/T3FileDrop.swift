import AppKit

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
