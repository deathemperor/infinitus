import QuickLook
import UIKit
import UniformTypeIdentifiers

private final class MarkupItem: NSObject, QLPreviewItem {
  var previewItemURL: URL?
  var previewItemTitle: String?
}

/// One Quick Look session with editing on, over a private copy of a draft image (#269 I).
/// Quick Look's own markup tools (pen, highlighter, shapes, text, magnifier) draw on the
/// copy and flatten into it when the person taps Done; closing the sheet resolves with the
/// edited file's URL, or nil when nothing was saved. The copy lives in its own temporary
/// directory, which the JS side removes once it has read the bytes.
final class InfinitusMarkupPresentation: NSObject, QLPreviewControllerDataSource,
  QLPreviewControllerDelegate, UIAdaptivePresentationControllerDelegate {
  private let item = MarkupItem()
  private var directory: URL?
  private var edited: URL?
  private var finished = false
  private let completion: (Result<URL?, Error>) -> Void

  init(completion: @escaping (Result<URL?, Error>) -> Void) {
    self.completion = completion
    super.init()
  }

  func present(source: URL, title: String, from presenter: UIViewController) throws {
    let (directory, file) = try Self.copyForEditing(source: source, title: title)
    self.directory = directory
    item.previewItemURL = file
    item.previewItemTitle = title
    let controller = QLPreviewController()
    controller.dataSource = self
    controller.delegate = self
    presenter.present(controller, animated: !UIAccessibility.isReduceMotionEnabled)
    controller.presentationController?.delegate = self
  }

  func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    item.previewItemURL == nil ? 0 : 1
  }

  func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
    item
  }

  /// Editing writes back into the private copy, which is the whole point of the copy.
  func previewController(
    _ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem
  ) -> QLPreviewItemEditingMode {
    .updateContents
  }

  func previewController(_ controller: QLPreviewController, didUpdateContentsOf previewItem: QLPreviewItem) {
    edited = item.previewItemURL
  }

  /// Quick Look could not overwrite in place (the edit changed the file's type, say) and
  /// wrote a copy of its own instead; adopt it into the private directory.
  func previewController(
    _ controller: QLPreviewController, didSaveEditedCopyOf previewItem: QLPreviewItem,
    at modifiedContentsURL: URL
  ) {
    guard let directory else { return }
    let name = "edited.\(modifiedContentsURL.pathExtension.isEmpty ? "png" : modifiedContentsURL.pathExtension)"
    let destination = directory.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: destination)
    do {
      try FileManager.default.moveItem(at: modifiedContentsURL, to: destination)
      edited = destination
    } catch {
      edited = modifiedContentsURL
    }
  }

  func previewControllerDidDismiss(_ controller: QLPreviewController) { finish() }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { finish() }

  private func finish() {
    guard !finished else { return }
    finished = true
    if edited == nil, let directory {
      try? FileManager.default.removeItem(at: directory)
    }
    let result = edited
    DispatchQueue.main.async { [completion] in completion(.success(result)) }
  }

  /// The draft's bytes (a file or a data URL) under the attachment's own name, in a fresh
  /// temporary directory, so markup never touches the draft or a workspace file.
  private static func copyForEditing(source: URL, title: String) throws -> (URL, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("infinitus-markup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
      let filename = URL(fileURLWithPath: title).lastPathComponent as NSString
      let stem = String(filename.deletingPathExtension.prefix(60))
        .components(separatedBy: .controlCharacters).joined(separator: "_")
      let fileExtension = filename.pathExtension.isEmpty ? "png" : filename.pathExtension
      let file = directory.appendingPathComponent("\(stem.isEmpty ? "image" : stem).\(fileExtension)")
      if source.isFileURL {
        try FileManager.default.copyItem(at: source, to: file)
      } else if source.scheme == "data" {
        try Data(contentsOf: source).write(to: file, options: .atomic)
      } else {
        throw URLError(.unsupportedURL)
      }
      return (directory, file)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }
}
