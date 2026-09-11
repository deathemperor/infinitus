import AppKit
import InfinitusCore
import SwiftUI

/// Desktop capture → a session (#69, the Mac twin of the phone's shake
/// and share sheet): macOS's own `screencapture -i` picks the region or
/// window — no synthetic input — then a small window shows the capture
/// with a session picker and a note; Send posts it through the same
/// session-input path the phone uses, so it lands in the transcript the
/// way a phone message does.
@MainActor
final class DesktopCaptureController {
    struct Target: Identifiable {
        let pid: Int
        let label: String
        var id: Int { pid }
    }

    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) { self.model = model }

    func capture() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitus-capture-\(UUID().uuidString.prefix(8)).png")
        Task.detached(priority: .userInitiated) { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // -i: the region/window picker; -x: no shutter sound.
            process.arguments = ["-i", "-x", url.path]
            do { try process.run() } catch { return }
            process.waitUntilExit()
            defer { try? FileManager.default.removeItem(at: url) }
            // Esc in the picker: nonzero status, no file — nothing to show.
            guard process.terminationStatus == 0, let png = try? Data(contentsOf: url),
                  let jpeg = ImageThumbnail.jpeg(png, maxPixels: 2560, quality: 0.85),
                  jpeg.count <= SessionInput.maxAttachmentBytes else { return }
            await self?.show(jpeg)
        }
    }

    private func show(_ jpeg: Data) {
        guard let image = NSImage(data: jpeg) else { return }
        let targets = (model.liveSessions?.sessions ?? [])
            .sorted { $0.startedAt > $1.startedAt }
            .map { session in
                let name = model.sessionProgress.byPid[session.pid]?.name
                    ?? URL(fileURLWithPath: session.cwd).lastPathComponent
                return Target(pid: session.pid, label: "\(name) · \(session.status)")
            }
        window?.close()
        let view = DesktopCaptureView(image: image, targets: targets,
                                      onSend: { [weak self] pid, note in self?.send(jpeg, note: note, toPid: pid) },
                                      onCancel: { [weak self] in self?.window?.close() })
        let host = NSHostingView(rootView: view)
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Send capture to a session"
        w.contentView = host
        w.setContentSize(host.fittingSize)
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func send(_ jpeg: Data, note: String, toPid pid: Int) {
        window?.close()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let request = SessionInput.Request(
            kind: .message, text: note,
            attachments: [.init(name: "desktop-capture-\(stamp).jpg", mime: "image/jpeg", data: jpeg)])
        Task { [model] in
            let reply = await model.send(request, toPid: pid, icon: "🖥️", what: "desktop capture")
            guard reply.outcome != "delivered" else { return }
            let alert = NSAlert()
            alert.messageText = "The session didn't take the capture"
            alert.informativeText = reply.detail ?? reply.outcome
            alert.runModal()
        }
    }
}

/// The capture, a session, a note, Send.
struct DesktopCaptureView: View {
    let image: NSImage
    let targets: [DesktopCaptureController.Target]
    let onSend: (Int, String) -> Void
    let onCancel: () -> Void
    @State private var pid: Int
    @State private var note = ""

    init(image: NSImage, targets: [DesktopCaptureController.Target],
         onSend: @escaping (Int, String) -> Void, onCancel: @escaping () -> Void) {
        self.image = image
        self.targets = targets
        self.onSend = onSend
        self.onCancel = onCancel
        _pid = State(initialValue: targets.first?.pid ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(nsImage: image)
                .resizable().scaledToFit()
                .frame(maxWidth: 528, maxHeight: 330)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            if targets.isEmpty {
                Text("No live sessions to send this to.").foregroundStyle(.secondary)
            } else {
                Picker("Session", selection: $pid) {
                    ForEach(targets) { Text($0.label).tag($0.pid) }
                }
            }
            TextField("What should the session do with this?", text: $note, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Send") { onSend(pid, note) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(targets.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 560)
    }
}
