import SwiftUI
import VisionKit

struct PairingView: View {
    @EnvironmentObject private var model: DSHAppModel
    @State private var showScanner = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: "macbook.and.iphone")
                        .font(.system(size: 64, weight: .light))
                        .foregroundStyle(.tint)
                        .padding(.top, 24)

                    VStack(spacing: 8) {
                        Text("Connect to DeepSeek Harness")
                            .font(.system(size: 24, weight: .bold))
                        Text("Run DSH Anywhere Connector on your Mac, then scan the pairing code it prints, or enter the machine details by hand.")
                            .font(.system(size: 16))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button { showScanner = true } label: {
                        Label("Scan pairing code", systemImage: "qrcode.viewfinder")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Capsule())

                    HStack(spacing: 10) {
                        Rectangle().fill(Color.secondary.opacity(0.22)).frame(height: 1)
                        Text("Or enter manually")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Rectangle().fill(Color.secondary.opacity(0.22)).frame(height: 1)
                    }
                    .padding(.vertical, 2)

                    VStack(spacing: 12) {
                        TextField("https://dsh.example.com", text: $model.serverAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .happyFieldStyle()
                        TextField("Machine ID", text: $model.machineID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .happyFieldStyle()
                        SecureField("Pairing code or secret", text: $model.pairingSecret)
                            .happyFieldStyle()
                    }

                    Button { model.pair() } label: {
                        ZStack {
                            Label("Pair with Mac", systemImage: "link")
                                .font(.system(size: 17, weight: .semibold))
                                .opacity(model.isPairing ? 0 : 1)
                            if model.isPairing { ProgressView().tint(.white) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Capsule())
                    .disabled(model.isPairing || model.machineID.isEmpty
                              || DSHPairingCredential.detect(model.pairingSecret) == nil
                              || model.serverAddress.isEmpty)

                    Text("Your API keys stay on your Mac.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .background(Color(.systemBackground))
            .safeAreaInset(edge: .top, spacing: 0) { pairingHeader }
            .toolbar(.hidden, for: .navigationBar)
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

    private var pairingHeader: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 44, height: 44)
            Spacer(minLength: 0)
            Text("DSH Anywhere")
                .font(.system(size: 17, weight: .semibold))
            Spacer(minLength: 0)
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .background(Color(.systemBackground).opacity(0.96))
    }
}

private extension View {
    /// Shared field geometry for pairing and settings surfaces: 52pt touch
    /// target, 16pt horizontal inset and a quiet rounded material background.
    func happyFieldStyle() -> some View {
        self
            .textFieldStyle(.plain)
            .font(.system(size: 17))
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
            .background(Color.black)
            .safeAreaInset(edge: .top, spacing: 0) { scannerHeader }
            .toolbar(.hidden, for: .navigationBar)
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

    private var scannerHeader: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay { Circle().stroke(Color.white.opacity(0.2), lineWidth: 0.75) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel")

            Spacer(minLength: 0)
            Text("Scan pairing code")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .background(Color.black.opacity(0.72))
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
