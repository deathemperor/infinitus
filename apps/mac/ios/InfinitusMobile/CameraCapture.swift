import SwiftUI
import UIKit

/// The system camera, for "Take Photo" in the attachment menu (user
/// 2026-09-03 "need camera capture"). SwiftUI has no camera view of its
/// own; this is the thinnest UIImagePickerController bridge that hands
/// the shot back as a UIImage and dismisses itself either way.
struct CameraCapture: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraCapture
        init(_ parent: CameraCapture) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// Full-screen look at a picked photo before it goes (user 2026-09-03
/// "I can view the message once selected"): pinch/drag to zoom, tap
/// Done. Files without a thumbnail show their name and size instead.
struct AttachmentPreview: View {
    let name: String
    let bytes: Int
    let image: UIImage?
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    ScrollView([.horizontal, .vertical], showsIndicators: false) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .containerRelativeFrame([.horizontal, .vertical])
                            .scaleEffect(zoom)
                    }
                    .gesture(MagnifyGesture().onChanged { zoom = max(1, min(5, $0.magnification)) })
                    .background(Color.black)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.fill").font(.largeTitle)
                        Text(name).font(.headline)
                    }
                }
            }
            .navigationTitle("\(name) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
