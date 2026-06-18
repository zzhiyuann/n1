import SwiftUI

/// In-app configuration for the analysis backend.
///
/// N1's analysis runs on the user's own Mac via the `n1d` server. This screen lets the
/// user point the app at that server: localhost for the iOS Simulator, or the Mac's
/// Tailscale `100.x.x.x` address from a physical phone. The URL persists via `ServerConfig`
/// (UserDefaults key `n1_server_url`).
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    /// The editable server URL. Seeded from the stored override if present, otherwise
    /// from the localhost fallback so the field always shows a usable example.
    @State private var serverURL: String = UserDefaults.standard
        .string(forKey: ServerConfig.defaultsKey) ?? ServerConfig.fallback

    @State private var testState: TestState = .idle

    /// Optional on-device location collector (off by default; additive to the core).
    @ObservedObject private var location = LocationSource.shared

    private enum TestState: Equatable {
        case idle
        case testing
        case ok(model: String, sources: Int)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    serverCard
                    locationCard
                    helpCard
                }
                .padding(20)
            }
            .background(N1Design.bg)
            .scrollContentBackground(.hidden)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { persistAndDismiss() }
                        .foregroundStyle(N1Design.signal)
                }
            }
            .toolbarBackground(N1Design.bg, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Server URL

    private var serverCard: some View {
        InstrumentCard {
            SectionLabel(text: "Analysis server")

            TextField(ServerConfig.fallback, text: $serverURL)
                .textFieldStyle(.plain)
                .font(.n1Mono(15))
                .foregroundStyle(N1Design.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(12)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                .onChange(of: serverURL) { _, _ in
                    if testState != .idle { testState = .idle }
                }

            Text("Simulator: use \(ServerConfig.fallback). On a phone, point this at your Mac's Tailscale address, e.g. http://100.x.x.x:8787.")
                .font(.footnote).foregroundStyle(N1Design.faint)

            Button { runTest() } label: {
                HStack(spacing: 8) {
                    if case .testing = testState {
                        ProgressView().scaleEffect(0.7).tint(N1Design.signal)
                    } else {
                        Image(systemName: "dot.radiowaves.left.and.right")
                    }
                    Text("Test connection")
                        .font(.callout.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .background(N1Design.signal.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(N1Design.signal)
            .disabled(testState == .testing ||
                      serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            testResultView
        }
    }

    @ViewBuilder
    private var testResultView: some View {
        switch testState {
        case .idle, .testing:
            EmptyView()
        case let .ok(model, sources):
            Label("Connected · model \(model) · \(sources) source\(sources == 1 ? "" : "s")",
                  systemImage: "checkmark.seal.fill")
                .font(.footnote).foregroundStyle(N1Design.signal)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(N1Design.warn)
                .multilineTextAlignment(.leading)
        }
    }

    // MARK: Location (optional, additive)

    private var locationCard: some View {
        InstrumentCard {
            SectionLabel(text: "Location (optional)")

            Text("Optional. Helps answer questions about where behaviors happen — work/home/commute. iOS has no location history, so this starts collecting from now on; data stays on your device.")
                .font(.callout).foregroundStyle(N1Design.muted).lineSpacing(4)

            if location.isAuthorizedNow {
                Label(locationStatusText, systemImage: "mappin.and.ellipse")
                    .font(.footnote).foregroundStyle(N1Design.signal)
            } else {
                Button { location.authorize() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "location")
                        Text("Enable location collection")
                            .font(.callout.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .background(N1Design.signal.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(N1Design.signal)

                Label("Not enabled", systemImage: "circle.dashed")
                    .font(.footnote).foregroundStyle(N1Design.faint)
            }
        }
    }

    /// Honest live status: how many places recorded and since when.
    private var locationStatusText: String {
        let s = location.summary
        guard s.count > 0, let since = s.since else {
            return "Enabled — no places recorded yet (collection starts now)"
        }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        let noun = s.count == 1 ? "place" : "places"
        return "\(s.count) \(noun) recorded since \(df.string(from: since))"
    }

    // MARK: Help

    private var helpCard: some View {
        InstrumentCard {
            SectionLabel(text: "Running your own backend")
            Text("N1's analysis runs on your own Mac via the n1d server. On a phone, the easiest way to reach your Mac is Tailscale (tailscale.com) — install it on both, then use your Mac's 100.x address here.")
                .font(.callout).foregroundStyle(N1Design.muted).lineSpacing(4)
        }
    }

    // MARK: Actions

    private func persistAndDismiss() {
        ServerConfig.set(serverURL)
        dismiss()
    }

    /// GET `<url>/health` and surface the result. Persists the URL first so the test
    /// reflects exactly what the app will use.
    private func runTest() {
        ServerConfig.set(serverURL)
        let base = ServerConfig.baseURL
        guard let url = URL(string: base + "/health") else {
            testState = .failed("That doesn't look like a valid URL.")
            return
        }
        testState = .testing
        Task {
            var req = URLRequest(url: url)
            req.timeoutInterval = 5
            req.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    testState = .failed("No response from the server.")
                    return
                }
                guard http.statusCode == 200 else {
                    testState = .failed("Server returned HTTP \(http.statusCode).")
                    return
                }
                let health = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let model = (health?["model"] as? String) ?? "unknown"
                let sources = Self.sourceCount(from: health)
                testState = .ok(model: model, sources: sources)
            } catch {
                testState = .failed("Couldn't reach \(base): \(error.localizedDescription)")
            }
        }
    }

    /// Best-effort extraction of a "sources" count from the /health payload, tolerant of
    /// whether the backend reports a number or a list.
    private static func sourceCount(from health: [String: Any]?) -> Int {
        guard let health else { return 0 }
        if let n = health["sources"] as? Int { return n }
        if let arr = health["sources"] as? [Any] { return arr.count }
        if let n = health["sourcesCount"] as? Int { return n }
        return 0
    }
}
