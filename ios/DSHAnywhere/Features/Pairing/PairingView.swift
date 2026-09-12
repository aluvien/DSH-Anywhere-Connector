import SwiftUI

struct PairingView: View {
    @EnvironmentObject private var model: DSHAppModel

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
                    Text("Run DSH Anywhere Connector on your Mac, then enter the machine details shown there.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
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
                SecureField("Pairing secret", text: $model.pairingSecret)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Button {
                    model.pair()
                } label: {
                    Label("Pair with Mac", systemImage: "link")
                        .frame(maxWidth: 320)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isPairing || model.machineID.isEmpty || model.pairingSecret.count < 32 || model.serverAddress.isEmpty)
                .overlay { if model.isPairing { ProgressView().tint(.white) } }
                Spacer()
                Text("Your API keys stay on your Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .navigationTitle("DSH Anywhere")
        }
    }
}

struct PairingView_Previews: PreviewProvider {
    static var previews: some View {
        PairingView().environmentObject(DSHAppModel())
    }
}
