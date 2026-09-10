import SwiftUI
import UIKit
import SwiftTerm
import InfinitusCore
import InfinitusUI

/// `…/terminal` (spec §5.1) from the thread header's terminal pill.
struct T3TerminalRoute: Hashable {
    let session: SessionDetail
    let macId: String?
}

/// The emulator and its wire glue: SwiftTerm's `TerminalView` fed by the
/// stream's frames, keystrokes coalesced per 16 ms into one write (#507
/// ruling 4), a resize debounced 100 ms, the Pierre palette upstream's
/// `terminalTheme.ts` paints.
final class T3TerminalController: NSObject, ObservableObject, TerminalViewDelegate {
    enum Phase: Equatable {
        case idle, opening, running
        case exited(Int?)
        case closed(String?)
        case unavailable(String)
    }
    @Published var phase: Phase = .idle
    @Published var title = ""
    @Published var ctrlArmed = false
    let view: TerminalView
    var onSend: ((String) -> Void)?
    var onResize: ((Int, Int) -> Void)?
    private var pending = Data()
    private var flush: Task<Void, Never>?
    private var resizeDebounce: Task<Void, Never>?

    init(font: UIFont) {
        view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), font: font)
        super.init()
        view.terminalDelegate = self
        view.allowMouseReporting = false
    }

    var cols: Int { view.getTerminal().cols }
    var rows: Int { view.getTerminal().rows }

    /// `PIERRE_LIGHT_THEME` / `PIERRE_DARK_THEME` (`terminalTheme.ts`): the
    /// phone's own terminal palette upstream, over the screen background —
    /// not the web tokens' `terminal*` set.
    static func background(dark: Bool) -> SwiftUI.Color { dark ? SwiftUI.Color(red: 0.039, green: 0.039, blue: 0.039) : SwiftUI.Color(red: 0.949, green: 0.949, blue: 0.969) }

    func apply(dark: Bool) {
        let hex = dark
            ? ["141415", "ff2e3f", "0dbe4e", "ffca00", "009fff", "c635e4", "08c0ef", "c6c6c8",
               "141415", "ff2e3f", "0dbe4e", "ffca00", "009fff", "c635e4", "08c0ef", "c6c6c8"]
            : ["1F1F21", "ff2e3f", "0dbe4e", "ffca00", "009fff", "c635e4", "08c0ef", "c6c6c8",
               "1F1F21", "ff2e3f", "0dbe4e", "ffca00", "009fff", "c635e4", "08c0ef", "c6c6c8"]
        view.installColors(hex.map { Self.color($0) })
        view.nativeBackgroundColor = UIColor(Self.background(dark: dark))
        view.nativeForegroundColor = dark ? UIColor(red: 0.678, green: 0.678, blue: 0.694, alpha: 1) : UIColor(red: 0.424, green: 0.424, blue: 0.443, alpha: 1)
        view.caretColor = UIColor(red: 0, green: 0.624, blue: 1, alpha: 1)
        view.selectedTextBackgroundColor = UIColor(red: 0, green: 0.624, blue: 1, alpha: 0.25)
    }

    private static func color(_ hex: String) -> SwiftTerm.Color {
        let v = UInt32(hex, radix: 16) ?? 0
        return SwiftTerm.Color(red8: UInt16((v >> 16) & 0xff), green8: UInt16((v >> 8) & 0xff), blue8: UInt16(v & 0xff))
    }

    /// A (re)connect's first `snapshot` replaces the screen; the chunks
    /// that follow it (16 KB each, the status repeated) only append.
    var awaitingSnapshot = true

    func feed(_ frame: T3Terminal.Frame) {
        switch frame {
        case .snapshot(let s):
            if awaitingSnapshot {
                view.getTerminal().resetToInitialState()
                awaitingSnapshot = false
            }
            view.feed(text: s.history)
            switch s.status {
            case .exited: phase = .exited(s.exitCode)
            case .error: phase = .unavailable("the shell failed to start")
            case .starting, .running: phase = .running
            }
        case .output(let o):
            view.feed(text: o.data)
        case .exited(let e):
            phase = .exited(e.exitCode)
        case .closed(let c):
            phase = .closed(c.reason)
        case .error(let e):
            phase = .unavailable(e.message)
        }
    }

    /// The emulator's own clear: home + erase screen + erase scrollback.
    func clearLocally() { view.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J") }

    /// A key from the accessory row: with ctrl armed, a letter becomes its
    /// control byte (`ctrl` + `c` → 0x03), then ctrl disarms.
    func press(_ text: String) {
        if ctrlArmed, let scalar = text.uppercased().unicodeScalars.first, (64..<96).contains(scalar.value) {
            enqueue(String(UnicodeScalar(UInt8(scalar.value - 64))))
        } else {
            enqueue(text)
        }
        ctrlArmed = false
    }

    private func enqueue(_ text: String) {
        pending.append(contentsOf: text.utf8)
        guard flush == nil else { return }
        flush = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard let self else { return }
            let out = self.pending
            self.pending = Data()
            self.flush = nil
            if !out.isEmpty { self.onSend?(String(decoding: out, as: UTF8.self)) }
        }
    }

    // MARK: TerminalViewDelegate
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        pending.append(contentsOf: data)
        enqueue("")
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        resizeDebounce?.cancel()
        resizeDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            self?.onResize?(newCols, newRows)
        }
    }
    func setTerminalTitle(source: TerminalView, title: String) { self.title = title }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { UIApplication.shared.open(url) }
    }
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) { UIPasteboard.general.string = String(decoding: content, as: UTF8.self) }
    func clipboardRead(source: TerminalView) -> Data? { UIPasteboard.general.string.map { Data($0.utf8) } }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}

struct T3TerminalSurface: UIViewRepresentable {
    let controller: T3TerminalController
    func makeUIView(context: Context) -> TerminalView { controller.view }
    func updateUIView(_ uiView: TerminalView, context: Context) {}
}

/// T3's Terminal (`ThreadTerminalRouteScreen.tsx` at upstream 6c583620f;
/// the emulator is SwiftTerm, spec decision): the session's shell on the
/// Mac, streamed (#507). The keys row is upstream's toolbar — a ctrl
/// modifier, esc, tab, paste, clear, arrows and the four shell characters
/// a phone keyboard hides — always shown here rather than only with the
/// keyboard up.
struct T3TerminalScreen: View {
    @ObservedObject var model: MirrorModel
    let session: SessionDetail
    var macId: String? = nil
    @Environment(\.t3) private var t3
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: T3TerminalController
    @State private var terminalId = T3Terminal.defaultTerminalId
    @State private var sequence: Int?
    @State private var stream: Task<Void, Never>?
    @State private var reconnecting = false
    private let fixture: [T3Terminal.Frame]?

    init(model: MirrorModel, session: SessionDetail, macId: String? = nil) {
        self.model = model; self.session = session; self.macId = macId; fixture = nil
        _controller = StateObject(wrappedValue: T3TerminalController(font: Self.font))
    }

    /// The render harness's canned stream; nothing is opened or fetched.
    init(model: MirrorModel, session: SessionDetail, fixture: [T3Terminal.Frame]) {
        self.model = model; self.session = session; self.fixture = fixture
        _controller = StateObject(wrappedValue: T3TerminalController(font: Self.font))
    }

    /// Upstream's `DEFAULT_TERMINAL_FONT_SIZE` 10.5, under the Text size scale.
    static var font: UIFont {
        UIFont.monospacedSystemFont(ofSize: max(8, 10.5 * T3Font.mobileScale), weight: .regular)
    }

    private var project: String { URL(fileURLWithPath: session.cwd).lastPathComponent }

    var body: some View {
        let p = t3.mobile
        VStack(spacing: 0) {
            switch controller.phase {
            case .unavailable(let message):
                T3EmptyState(title: "Terminal unavailable", message: message)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .opening, .idle where fixture == nil:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                T3TerminalSurface(controller: controller)
                    .background(T3TerminalController.background(dark: scheme == .dark))
                if let strip = statusStrip {
                    HStack(spacing: 12) {
                        Text(strip).font(T3Font.mobile(.xs)).foregroundStyle(p.foregroundMuted.color)
                        Spacer()
                        if fixture == nil {
                            Button("Restart") { Task { await restart() } }.font(T3Font.mobile(.xs, .semibold)).foregroundStyle(p.accent.color)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8).background(p.card.color)
                }
            }
        }
        .background(T3TerminalController.background(dark: scheme == .dark).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .background(InteractivePopGesture())
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { keysRow }
        .task {
            controller.apply(dark: scheme == .dark)
            if let fixture {
                fixture.forEach(controller.feed)
            } else {
                controller.onSend = { data in Task { try? await model.mirror(for: macId).writeTerminal(pid: Int32(session.pid), id: terminalId, data: data) } }
                controller.onResize = { c, r in Task { try? await model.mirror(for: macId).resizeTerminal(pid: Int32(session.pid), id: terminalId, cols: c, rows: r) } }
                await open()
            }
        }
        .onChange(of: scheme) { _, new in controller.apply(dark: new == .dark) }
        .onDisappear { stream?.cancel() }
    }

    private var statusStrip: String? {
        switch controller.phase {
        case .exited(let code): return code.map { "Shell exited (\($0))" } ?? "Shell exited"
        // The Mac's reasons: "idle" (30 min with no phone attached), "app quit".
        case .closed(let reason):
            if reason == T3Terminal.closedReasonBackpressure { return nil }
            return reason.map { "Terminal closed — \($0)" } ?? "Terminal closed"
        default: return reconnecting ? "Reconnecting…" : nil
        }
    }

    private var header: some View {
        let p = t3.mobile
        return HStack(alignment: .center, spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(p.icon.color).frame(width: 32, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Back")
            VStack(alignment: .leading, spacing: 0) {
                Text("Terminal").font(T3Font.mobileLiteral(17, .bold)).lineLimit(1).foregroundStyle(p.foreground.color)
                Text(controller.title.isEmpty ? project : controller.title).font(T3Font.mobile(.xs)).lineLimit(1).foregroundStyle(p.foregroundMuted.color)
            }
            Spacer(minLength: 8)
            Menu {
                Button { controller.clearLocally() } label: { Label("Clear", systemImage: "eraser") }
                if fixture == nil {
                    Button { Task { await restart() } } label: { Label("Restart shell", systemImage: "arrow.clockwise") }
                    Button(role: .destructive) { Task { await close() } } label: { Label("Close terminal", systemImage: "xmark.circle") }
                }
            } label: {
                Image(systemName: "terminal").font(.system(size: 17)).foregroundStyle(p.icon.color).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Terminal options")
        }
        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 10)
        .background(p.sheet.color)
    }

    /// `terminalToolbarActions`: modifiers upper-cased, sends as typed.
    private var keysRow: some View {
        let p = t3.mobile
        let keys: [(label: String, action: () -> Void)] = [
            ("CTRL", { controller.ctrlArmed.toggle() }),
            ("esc", { controller.press("\u{1b}") }),
            ("tab", { controller.press("\t") }),
            ("paste", { if let s = UIPasteboard.general.string { controller.press(s) } }),
            ("CLEAR", { controller.clearLocally() }),
            ("↑", { controller.press("\u{1b}[A") }), ("↓", { controller.press("\u{1b}[B") }),
            ("←", { controller.press("\u{1b}[D") }), ("→", { controller.press("\u{1b}[C") }),
            ("~", { controller.press("~") }), ("|", { controller.press("|") }),
            ("/", { controller.press("/") }), ("-", { controller.press("-") }),
        ]
        return HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                        let armed = key.label == "CTRL" && controller.ctrlArmed
                        Button { key.action() } label: {
                            Text(key.label).font(T3Font.mobile(.xs, .semibold))
                                .foregroundStyle(armed ? p.accentForeground.color : p.foreground.color)
                                .frame(minWidth: key.label.count > 1 ? 56 : 44, minHeight: 34)
                                .background(armed ? p.accent.color : p.subtleStrong.color, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
            }
            Button {
                if controller.view.isFirstResponder { controller.view.resignFirstResponder() } else { controller.view.becomeFirstResponder() }
            } label: {
                Image(systemName: "keyboard").font(.system(size: 16)).foregroundStyle(p.icon.color)
                    .frame(width: 44, height: 34).background(p.subtleStrong.color, in: Capsule())
            }
            .buttonStyle(.plain).accessibilityLabel("Toggle keyboard").padding(.trailing, 12)
        }
        .padding(.vertical, 8)
        .background(p.sheet.color)
    }

    @MainActor
    private func open() async {
        controller.phase = .opening
        do {
            let opened = try await model.mirror(for: macId).openTerminal(pid: Int32(session.pid), cols: max(20, controller.cols), rows: max(5, controller.rows))
            terminalId = opened.terminalId
            controller.phase = .running
            sequence = nil
            startStream()
        } catch MirrorTransportError.http(404) {
            controller.phase = .unavailable("This Mac doesn't host terminals yet — update Infinitus on the Mac.")
        } catch {
            controller.phase = .unavailable(error.localizedDescription)
        }
    }

    /// The attach loop: a dropped stream (network, or the Mac's
    /// backpressure `closed`) resumes from the last byte offset after 1, 2,
    /// 4… 8 s; a stale `since` gets a fresh snapshot from the Mac (#507
    /// ruling 1). A real `closed` or `exited` ends it.
    private func startStream() {
        stream?.cancel()
        stream = Task { @MainActor in
            var delay: UInt64 = 1
            while !Task.isCancelled {
                do {
                    controller.awaitingSnapshot = true
                    for try await frame in model.mirror(for: macId).terminalStream(pid: Int32(session.pid), id: terminalId, since: sequence) {
                        delay = 1
                        reconnecting = false
                        if let s = frame.resumeSequence { sequence = s }
                        controller.feed(frame)
                        if case .exited = frame { return }
                        if case .closed(let c) = frame, c.reason != T3Terminal.closedReasonBackpressure { return }
                    }
                } catch MirrorTransportError.http(404) {
                    controller.phase = .closed("gone")
                    return
                } catch {
                    if Task.isCancelled { return }
                }
                reconnecting = true
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(8, delay * 2)
            }
        }
    }

    @MainActor
    private func restart() async {
        stream?.cancel()
        try? await model.mirror(for: macId).closeTerminal(pid: Int32(session.pid), id: terminalId)
        controller.view.getTerminal().resetToInitialState()
        await open()
    }

    @MainActor
    private func close() async {
        stream?.cancel()
        try? await model.mirror(for: macId).closeTerminal(pid: Int32(session.pid), id: terminalId)
        dismiss()
    }
}
