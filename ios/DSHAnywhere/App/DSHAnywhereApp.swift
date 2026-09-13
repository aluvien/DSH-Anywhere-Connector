import SwiftUI

@main
struct DSHAnywhereApp: App {
    @StateObject private var model = DSHAppModel()

    init() {
        // Plain strings built in helpers read this; keep it correct from launch.
        DSHLocalization.language = DSHAppModel().language
    }

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
        // SwiftUI resolves `Text("…")` against this locale, so switching the
        // preference re-renders every literal without a relaunch and without a
        // bundle-swizzling hack.
        .environment(\.locale, model.language.locale ?? Locale.current)
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
