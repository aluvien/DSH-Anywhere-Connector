import Network
import SwiftUI
import UIKit

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
    @Environment(\.scenePhase) private var scenePhase
    @State private var networkAvailable: Bool?
    @State private var pathRevision = 0

    var body: some View {
        Group {
            if model.isPaired {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--dsh-preview-conversation") {
                    NavigationStack {
                        ConversationView(sessionID: "preview-session")
                    }
                } else {
                    DSHRemoteTabs()
                }
                #else
                DSHRemoteTabs()
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
            // Keep static preview fixtures stable; their data is intentionally
            // self-contained and must not be replaced by a transport snapshot.
            if ProcessInfo.processInfo.arguments.contains("--dsh-preview-home-unreachable")
                || ProcessInfo.processInfo.arguments.contains("--dsh-preview-conversation") {
                return
            }
            #endif
            if model.isPaired { model.connect() }
        }
        .task {
            await watchNetworkPaths()
        }
        .task(id: pathRevision) {
            guard pathRevision > 0, scenePhase == .active else { return }
            await model.recheckConnectivity(networkAvailable: networkAvailable != false)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            pathRevision += 1
        }
    }

    private func watchNetworkPaths() async {
        let monitor = NWPathMonitor()
        let updates = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        monitor.pathUpdateHandler = { path in
            updates.continuation.yield(path.status == .satisfied)
        }
        monitor.start(queue: DispatchQueue(label: "DSHAnywhere.network-path"))
        defer {
            monitor.cancel()
            updates.continuation.finish()
        }
        for await available in updates.stream {
            guard !Task.isCancelled else { return }
            let hadPath = networkAvailable != nil
            networkAvailable = available
            if hadPath && available { pathRevision += 1 }
        }
    }
}

struct DSHRootView_Previews: PreviewProvider {
    static var previews: some View {
        DSHRootView().environmentObject(DSHAppModel.preview())
    }
}


private struct DSHRemoteTabs: View {
    private enum Tab: String, CaseIterable {
        case home, conversation, tools

        var title: LocalizedStringKey {
            switch self {
            case .home: return "首页"
            case .conversation: return "当前会话"
            case .tools: return "工具"
            }
        }

        var icon: String {
            switch self {
            case .home: return "house"
            case .conversation: return "bubble.left.and.bubble.right"
            case .tools: return "square.grid.2x2"
            }
        }
    }

    private struct ConversationRoute {
        let sessionID: String
        let location: DSHSearchHit?
        let revision = UUID()
    }

    @EnvironmentObject private var model: DSHAppModel
    @State private var selection: Tab = .home
    @State private var recentByMachine: [String: ConversationRoute] = [:]
    @State private var keyboardVisible = false
    @State private var showSettings = false
    @State private var showNewTask = false
    @State private var searchText = ""

    var body: some View {
        TabView(selection: $selection) {
            DSHRemoteHomeView(openConversation: openConversation)
                .toolbar(.hidden, for: .tabBar)
                .tabItem { Label(Tab.home.title, systemImage: Tab.home.icon) }
                .tag(Tab.home)

            NavigationStack {
                if let route = recentByMachine[model.machineID] {
                    ConversationView(sessionID: route.sessionID, initialLocation: route.location,
                                     onBack: { selection = .home })
                        .id(route.revision)
                } else {
                    ContentUnavailableView {
                        Label("当前会话", systemImage: Tab.conversation.icon)
                    } actions: {
                        Button("新建任务") { showNewTask = true }
                        Button("返回首页") { selection = .home }
                    }
                }
            }
            .id(model.machineID)
            .toolbar(.hidden, for: .tabBar)
            .tabItem { Label(Tab.conversation.title, systemImage: Tab.conversation.icon) }
            .tag(Tab.conversation)

            NavigationStack {
                List {
                    Button { showSettings = true } label: { Label("设置与电脑管理", systemImage: "gearshape") }
                    NavigationLink {
                        ScrollView {
                            DSHHistorySearchResults(query: searchText) { hit in
                                openConversation(hit.sessionId, hit)
                            }
                            .padding()
                        }
                        .searchable(text: $searchText, prompt: "搜索对话")
                        .navigationTitle("历史搜索")
                    } label: {
                        Label("历史搜索", systemImage: "magnifyingglass")
                    }
                }
                .navigationTitle("工具")
            }
            .id(model.machineID)
            .toolbar(.hidden, for: .tabBar)
            .tabItem { Label(Tab.tools.title, systemImage: Tab.tools.icon) }
            .tag(Tab.tools)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !keyboardVisible { tabBar }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        .onChange(of: model.machineID) { _, _ in
            selection = .home
            searchText = ""
        }
        .onChange(of: model.selectedSessionID) { _, sessionID in
            guard let sessionID else { return }
            openConversation(sessionID, nil)
            model.selectedSessionID = nil
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .fullScreenCover(isPresented: $showNewTask) { NewSessionSheet() }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button { selection = tab } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 19, weight: .semibold))
                        Text(tab.title)
                            .font(.caption2.weight(selection == tab ? .semibold : .regular))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background {
                        if selection == tab {
                            Capsule().fill(Color.accentColor.opacity(0.14))
                        }
                    }
                    .foregroundStyle(selection == tab ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
                .accessibilityIdentifier("remote-tab-\(tab.rawValue)")
            }
        }
        .padding(.horizontal, 16)
        .background(.regularMaterial)
    }

    private func openConversation(_ sessionID: String, _ location: DSHSearchHit?) {
        let machineID = model.machineID
        guard !machineID.isEmpty else { return }
        if recentByMachine[machineID]?.sessionID != sessionID || location != nil {
            recentByMachine[machineID] = ConversationRoute(sessionID: sessionID,
                                                          location: location)
        }
        selection = .conversation
    }
}
