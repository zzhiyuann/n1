import SwiftUI

@main
struct N1App: App {
    @StateObject private var experiments = ExperimentsStore()
    @StateObject private var snapshot = SnapshotStore()
    @StateObject private var agent = AskAgent()
    @StateObject private var collection = CollectionStore()
    @StateObject private var history = InvestigationStore()
    @StateObject private var groundTruth = GroundTruthStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(experiments)
                .environmentObject(snapshot)
                .environmentObject(agent)
                .environmentObject(collection)
                .environmentObject(history)
                .environmentObject(groundTruth)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var experiments: ExperimentsStore
    @EnvironmentObject var snap: SnapshotStore
    @EnvironmentObject var agent: AskAgent
    @EnvironmentObject var collection: CollectionStore
    @EnvironmentObject var history: InvestigationStore
    @EnvironmentObject var groundTruth: GroundTruthStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var didLoad = false

    var body: some View {
        TabView(selection: $snap.activeTab) {
            AskView().tabItem { Label("Ask", systemImage: "questionmark.circle") }.tag(0)
            ExperimentsView().tabItem { Label("Experiments", systemImage: "flask") }.tag(1)
            ArchiveView().tabItem { Label("Archive", systemImage: "archivebox") }.tag(2)
        }
        .tint(N1Design.signal)
        .background(N1Design.bg)
        .task {
            agent.store = history
            agent.profile = groundTruth
            // Don't request HealthKit auth at launch — that races with the onboarding cover and
            // silently fails. Onboarding's "Connect Apple Health" requests it from inside the cover.
            await snap.loadData(requestAuth: false)
            await collection.reconcile(days: snap.days)
            experiments.ingestRealData(days: snap.days)   // pull real sensor values into running experiments
            didLoad = true
            handleLaunchArguments()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && didLoad {
                Task {
                    await snap.refreshFromHealth()            // re-fetch real data (e.g. after granting Health)
                    experiments.ingestRealData(days: snap.days)
                }
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: {
                guard didLoad, !groundTruth.onboarded,
                      !ProcessInfo.processInfo.arguments.contains("-skipOnboarding")
                else { return false }
                // On a real device, always show onboarding so the user can connect Apple Health
                // (even before any data exists). On the simulator, only once demo data is loaded.
                return HealthKitSource.isAvailable || !snap.days.isEmpty
            },
            set: { _ in })) {
            OnboardingView()
        }
    }

    /// Demo / screenshot automation:
    /// `-demoask`: auto-ask a snapshot question; `-tab N`: jump straight to a screen.
    private func handleLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-demoask") {
            snap.questionText = "Working overtime affect my mood and sleep quality?"
            Task { await agent.run(question: snap.questionText, days: snap.days) }
        }
        if let i = args.firstIndex(of: "-tab"), args.count > i + 1, let t = Int(args[i + 1]) {
            snap.activeTab = t
        }
    }
}

/// Shared screen scaffold: title + content, scientific-instrument styling.
/// `toolbar` is an optional trailing navigation-bar slot (e.g. a Settings gear).
struct ScreenScaffold<Content: View, Toolbar: View>: View {
    let stage: String
    let title: String
    @ViewBuilder var content: Content
    @ViewBuilder var toolbar: Toolbar

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SectionLabel(text: stage)
                    Text(title)
                        .font(.n1Serif(26))
                        .foregroundStyle(N1Design.ink)
                    content
                }
                .padding(20)
            }
            .background(N1Design.bg)
            .scrollContentBackground(.hidden)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { toolbar }
            }
            .toolbarBackground(N1Design.bg, for: .navigationBar)
        }
    }
}

extension ScreenScaffold where Toolbar == EmptyView {
    /// Convenience initializer for screens with no trailing toolbar.
    init(stage: String, title: String, @ViewBuilder content: () -> Content) {
        self.stage = stage
        self.title = title
        self.content = content()
        self.toolbar = EmptyView()
    }
}
