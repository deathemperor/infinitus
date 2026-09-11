import SwiftUI
import VisionKit
import InfinitusCore

/// Scans the pairing QR the Mac's Devices settings show (#9 remote access).
/// VisionKit does the whole job — camera, focus, detection — so the app
/// only has to hand the payload back and dismiss.
struct PairScanner: UIViewControllerRepresentable {
    /// Called with the raw QR payload; the caller decides whether it's a
    /// pair URL (MirrorPairing.parsePairURL) and dismisses.
    let onFound: (String) -> Void

    /// False in the simulator (no camera) and on devices without the
    /// neural engine VisionKit wants — the token can still be typed.
    static var isSupported: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController,
                                context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onFound: (String) -> Void
        /// One payload per presentation: the delegate fires per frame.
        private var done = false

        init(onFound: @escaping (String) -> Void) { self.onFound = onFound }

        func dataScanner(_ scanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            handle(addedItems)
        }

        func dataScanner(_ scanner: DataScannerViewController,
                         didTapOn item: RecognizedItem) {
            handle([item])
        }

        private func handle(_ items: [RecognizedItem]) {
            guard !done else { return }
            for case .barcode(let barcode) in items {
                guard let payload = barcode.payloadStringValue else { continue }
                done = true
                onFound(payload)
                return
            }
        }
    }
}

/// The scanner as a sheet: the camera, a hint, and a way out.
struct PairScannerSheet: View {
    let onFound: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                PairScanner { payload in
                    guard MirrorPairing.parsePairURL(payload) != nil else {
                        failed = true
                        return
                    }
                    onFound(payload)
                    dismiss()
                }
                .ignoresSafeArea()
                Text(failed ? "That QR isn't an Infinitus pairing code."
                     : "Point at the QR in the Mac's Settings → Devices.")
                    .font(.callout)
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding()
            }
            .navigationTitle("Scan to pair")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel") { dismiss() } }
        }
    }
}
