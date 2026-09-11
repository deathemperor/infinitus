import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// On-phone translation of a non-English dictation (user 2026-09-04:
/// "an option to translate into English"). Apple's Translation
/// framework, iOS 18, on-device once the language pack is installed —
/// the text never leaves the phone. Below iOS 18, or when the pack is
/// missing, the caller falls back to the "note" policy.
struct DictationTranslateRequest: Equatable {
    let text: String
    let from: Locale
    let id = UUID()
}

struct DictationTranslate: ViewModifier {
    let request: DictationTranslateRequest?
    let onResult: (Result<String, Error>) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.modifier(Bridge(request: request, onResult: onResult))
        } else {
            content.onChange(of: request) { _, r in
                if r != nil { onResult(.failure(Unavailable())) }
            }
        }
    }

    struct Unavailable: Error {}

    @available(iOS 18.0, *)
    private struct Bridge: ViewModifier {
        let request: DictationTranslateRequest?
        let onResult: (Result<String, Error>) -> Void
        @State private var configuration: TranslationSession.Configuration?

        func body(content: Content) -> some View {
            content
                .onChange(of: request) { _, r in
                    guard let r else { configuration = nil; return }
                    configuration = TranslationSession.Configuration(
                        source: r.from.language, target: Locale.Language(identifier: "en"))
                }
                .translationTask(configuration) { session in
                    guard let r = request else { return }
                    // A pair that isn't installed yet: `prepareTranslation`
                    // puts up the download sheet; without it `translate`
                    // can sit forever (the "Translating…" that never
                    // ended, user 2026-09-04 21:21). Either way the
                    // caller's timeout is the last word.
                    do {
                        try await session.prepareTranslation()
                        let out = try await session.translate(r.text)
                        onResult(.success(out.targetText))
                    } catch {
                        onResult(.failure(error))
                    }
                }
        }
    }
}

extension View {
    func dictationTranslate(_ request: DictationTranslateRequest?,
                            onResult: @escaping (Result<String, Error>) -> Void) -> some View {
        modifier(DictationTranslate(request: request, onResult: onResult))
    }
}
