import SwiftUI

@main
struct DSHAnywhereApp: App {
    @StateObject private var model: DSHAppModel

    init() {
        let initialModel: DSHAppModel
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--dsh-preview-home-unreachable") {
            initialModel = DSHAppModel.previewHomeUnreachable()
        } else if ProcessInfo.processInfo.arguments.contains("--dsh-preview-conversation") {
            initialModel = DSHAppModel.preview()
        } else if ProcessInfo.processInfo.arguments.contains("--dsh-preview-new-session") {
            initialModel = DSHAppModel.previewHome()
        } else if ProcessInfo.processInfo.arguments.contains("--dsh-preview-home-grouped") {
            initialModel = DSHAppModel.previewHome(grouped: true)
        } else if ProcessInfo.processInfo.arguments.contains("--dsh-preview-home") {
            initialModel = DSHAppModel.previewHome()
        } else {
            initialModel = DSHAppModel()
        }
        #else
        initialModel = DSHAppModel()
        #endif
        _model = StateObject(wrappedValue: initialModel)
        // Plain strings built in helpers read this; keep it correct from launch.
        DSHLocalization.language = initialModel.language
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
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--dsh-preview-conversation") {
                    NavigationStack {
                        ConversationView(sessionID: "preview-session")
                    }
                } else {
                    SessionListView()
                }
                #else
                SessionListView()
                #endif
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
            #if DEBUG
            // Keep the disconnected fixture stable long enough for visual QA.
            if ProcessInfo.processInfo.arguments.contains("--dsh-preview-home-unreachable") {
                return
            }
            #endif
            if model.isPaired { model.connect() }
        }
    }
}

struct DSHRootView_Previews: PreviewProvider {
    static var previews: some View {
        DSHRootView().environmentObject(DSHAppModel.preview())
    }
}
