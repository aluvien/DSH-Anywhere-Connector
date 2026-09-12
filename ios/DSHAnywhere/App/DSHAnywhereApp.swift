import SwiftUI

@main
struct DSHAnywhereApp: App {
    @StateObject private var model = DSHAppModel()

    var body: some Scene {
        WindowGroup {
            DSHRootView()
                .environmentObject(model)
        }
    }
}

struct DSHRootView: View {
    @EnvironmentObject private var model: DSHAppModel

    var body: some View {
        Group {
            if model.isPaired {
                SessionListView()
            } else {
                PairingView()
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: {
            model.errorMessage != nil
        }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
        .task {
            if model.isPaired { model.connect() }
        }
    }
}

struct DSHRootView_Previews: PreviewProvider {
    static var previews: some View {
        DSHRootView().environmentObject(DSHAppModel.preview())
    }
}
