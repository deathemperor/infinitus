import ExpoModulesCore
import UIKit

/// `InfinitusMarkup.markUpImage(uri, title)`: Quick Look markup over a copy of a draft
/// image; resolves with the edited file's URL string, or null when the sheet closed
/// without saving. One session at a time.
public final class InfinitusMarkupModule: Module {
  private var presentation: InfinitusMarkupPresentation?

  public func definition() -> ModuleDefinition {
    Name("InfinitusMarkup")

    AsyncFunction("markUpImage") { (url: URL, title: String, promise: Promise) in
      guard self.presentation == nil else {
        throw NSError(
          domain: "InfinitusMarkup", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Another image is already open for markup."])
      }
      guard let presenter = self.appContext?.utilities?.currentViewController() else {
        throw NSError(
          domain: "InfinitusMarkup", code: 2,
          userInfo: [NSLocalizedDescriptionKey: "The presenting screen is no longer open."])
      }
      let presentation = InfinitusMarkupPresentation { [weak self] result in
        self?.presentation = nil
        switch result {
        case .success(let edited): promise.resolve(edited?.absoluteString)
        case .failure(let error): promise.reject(error)
        }
      }
      self.presentation = presentation
      do {
        try presentation.present(source: url, title: title, from: presenter)
      } catch {
        self.presentation = nil
        throw error
      }
    }.runOnQueue(.main)
  }
}
