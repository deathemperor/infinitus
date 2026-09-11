import Foundation
import Speech
import AVFoundation

/// On-device dictation into the composer (user 2026-09-03 "build a smart
/// dictation for mobile"): Apple's speech recognizer with partial results
/// streamed into the draft as you speak — on the phone when the language
/// supports it, no server of ours, no tokens. A "Tidy" pass through
/// Foundation Models needs Apple Intelligence hardware (A17 Pro and up);
/// the paired phone hasn't got it, so it isn't built.
@MainActor
final class Dictation: ObservableObject {
    @Published private(set) var listening = false
    /// What's been recognized since `start()`; grows as you speak.
    @Published private(set) var transcript = ""
    @Published var error: String?
    /// The locale the running (or last) recognizer used.
    @Published private(set) var locale: Locale = .current

    static var isAvailable: Bool { SFSpeechRecognizer() != nil }

    // MARK: preferences (user 2026-09-04: "can it accept Vietnamese? …
    // build them configurable")
    /// "" = the phone's language; else a speech locale id ("vi-VN").
    static let localeKey = "dictation_locale"
    /// What happens to a non-English dictation: "phone" translates it on
    /// the phone (iOS 18, on-device); "note" sends it as spoken with a
    /// line asking for an English reply; "none" sends it as spoken.
    static let policyKey = "dictation_policy"
    /// Session vocabulary (repo, branch, tool names…) handed to the
    /// recognizer so English terms survive a Vietnamese pass.
    static let hintsKey = "dictation_hints"

    static var preferredLocale: Locale {
        let id = UserDefaults.standard.string(forKey: localeKey) ?? ""
        return id.isEmpty ? .current : Locale(identifier: id)
    }
    static var policy: String { UserDefaults.standard.string(forKey: policyKey) ?? "phone" }
    static var hintsEnabled: Bool { UserDefaults.standard.object(forKey: hintsKey) as? Bool ?? true }

    /// Languages Apple's recognizer offers, sorted by their own names.
    static var supportedLocales: [Locale] {
        SFSpeechRecognizer.supportedLocales()
            .sorted { displayName($0) < displayName($1) }
    }
    static func displayName(_ locale: Locale) -> String {
        locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
    static func isEnglish(_ locale: Locale) -> Bool {
        locale.language.languageCode?.identifier == "en"
    }

    /// Words worth recognising verbatim in this session (set by the feed).
    var hints: [String] = []

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// A stop we asked for: the task's trailing "no speech"/cancelled
    /// error isn't news then.
    private var stopping = false

    func toggle() { listening ? stop() : start() }

    func start() {
        error = nil
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else {
                    self.error = "speech recognition isn't allowed — Settings → Infinitus"
                    return
                }
                AVAudioApplication.requestRecordPermission { ok in
                    Task { @MainActor in
                        guard ok else {
                            self.error = "microphone access isn't allowed — Settings → Infinitus"
                            return
                        }
                        self.begin()
                    }
                }
            }
        }
    }

    private func begin() {
        guard !listening else { return }
        let wanted = Self.preferredLocale
        guard let recognizer = SFSpeechRecognizer(locale: wanted) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            error = "speech recognition isn't available right now"
            return
        }
        locale = recognizer.locale
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            self.error = "couldn't open the microphone"
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        if Self.hintsEnabled, !hints.isEmpty { request.contextualStrings = Array(hints.prefix(100)) }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.error = "couldn't start the microphone"
            return
        }
        self.request = request
        transcript = ""
        stopping = false
        listening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, err in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result { self.transcript = result.bestTranscription.formattedString }
                if err != nil || result?.isFinal == true { self.finished(err) }
            }
        }
    }

    func stop() {
        guard listening else { return }
        stopping = true
        listening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()   // the task delivers its final transcript, then ends
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func finished(_ err: Error?) {
        if let err, !stopping {
            error = transcript.isEmpty ? "didn't catch that — \(err.localizedDescription)" : nil
        }
        if listening { stop() }
        request = nil
        task = nil
    }
}
