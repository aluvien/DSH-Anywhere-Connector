import SwiftUI
import VisionKit

struct PairingView: View {
    @EnvironmentObject private var model: DSHAppModel
    @State private var showScanner = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                Image(systemName: "macbook.and.iphone")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.tint)
                VStack(spacing: 8) {
                    Text("Connect to DeepSeek Harness")
                        .font(.title2.bold())
                    Text("Run DSH Anywhere Connector on your Mac, then scan the pairing code it prints, or enter the machine details by hand.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                Button {
                    showScanner = true
                } label: {
                    Label("Scan pairing code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: 320)
                }
                .buttonStyle(.borderedProminent)

                Text("Or enter the details manually")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextField("https://dsh.example.com", text: $model.serverAddress)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(maxWidth: 320)
                    .keyboardType(.URL)
                TextField("Machine ID", text: $model.machineID)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(maxWidth: 320)
                SecureField("Pairing code or secret", text: $model.pairingSecret)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Button {
                    model.pair()
                } label: {
                    Label("Pair with Mac", systemImage: "link")
                        .frame(maxWidth: 320)
                }
                .buttonStyle(.bordered)
                .disabled(model.isPairing || model.machineID.isEmpty
                          || DSHPairingCredential.detect(model.pairingSecret) == nil
                          || model.serverAddress.isEmpty)
                .overlay { if model.isPairing { ProgressView() } }
                Spacer()
                Text("Your API keys stay on your Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .navigationTitle("DSH Anywhere")
            .sheet(isPresented: $showScanner) {
                PairingScannerSheet { link in
                    model.serverAddress = link.relay
                    model.machineID = link.machineId
                    switch link.credential {
                    case .secret(let value): model.pairingSecret = value
                    case .code(let value): model.pairingSecret = value
                    }
                    showScanner = false
                    model.pair()
                }
            }
        }
    }
}

/// Camera sheet used to scan the pairing QR. The scanner reports every code it
/// reads, so the handler returns whether it accepted one: a foreign QR leaves
/// scanning armed instead of silently closing the sheet.
@MainActor
struct PairingScannerSheet: View {
    let onAccept: (DSHPairingLink) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rejectedCode: String?

    private var isCameraReady: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            Group {
                if isCameraReady {
                    PairingScannerRepresentable { code in
                        guard let link = DSHPairingLink(urlString: code) else {
                            rejectedCode = code
                            return false
                        }
                        rejectedCode = nil
                        onAccept(link)
                        return true
                    }
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView(
                        "Camera unavailable",
                        systemImage: "camera.fill",
                        description: Text("Scanning needs a physical iPhone with an available camera. Enter the machine details by hand instead.")
                    )
                }
            }
            .navigationTitle("Scan pairing code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                if let rejectedCode {
                    Text("That is not a DSH Anywhere pairing code.")
                        .font(.footnote)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .accessibilityLabel("Unrecognised code \(rejectedCode.prefix(24))")
                }
            }
        }
    }
}

@MainActor
private struct PairingScannerRepresentable: UIViewControllerRepresentable {
    let onCode: (String) -> Bool

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        // startScanning() throws once the session is already running, so the
        // coordinator tracks whether the first update already armed it.
        guard !context.coordinator.didStart else { return }
        context.coordinator.didStart = true
        try? controller.startScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCode: (String) -> Bool
        var didStart = false

        init(onCode: @escaping (String) -> Bool) {
            self.onCode = onCode
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
                guard case .barcode(let barcode) = item,
                      let payload = barcode.payloadStringValue else { continue }
                if onCode(payload) { return }
            }
        }
    }
}

struct PairingView_Previews: PreviewProvider {
    static var previews: some View {
        PairingView().environmentObject(DSHAppModel())
    }
}
