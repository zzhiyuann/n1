import SwiftUI

/// Onboarding ground-truth pass: after data permission, the agent proposes a few facts about the
/// user's routines (from their actual data) for the user to confirm/edit/skip. Confirmed facts
/// persist and are injected into every future investigation — replacing any hardcoded heuristic.
struct OnboardingView: View {
    @EnvironmentObject var snap: SnapshotStore
    @EnvironmentObject var agent: AskAgent
    @EnvironmentObject var groundTruth: GroundTruthStore
    @Environment(\.dismiss) private var dismiss

    @State private var started = false
    @State private var handled: Set<String> = []
    @State private var edits: [String: String] = [:]
    @State private var editing: Set<String> = []

    // Apple Health connection state.
    @State private var healthConnecting = false
    @State private var healthOutcome: HealthAuthResult?
    /// On the simulator HealthKit is unavailable, so we treat health as already "handled" (demo).
    @State private var healthDone = !HealthKitSource.isAvailable

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Let me get to know you")
                        .font(.n1Serif(28)).foregroundStyle(N1Design.ink)
                    Text("I'll take a quick look at your data and check a few things with you, so I don't have to guess later. Your data stays on this device.")
                        .font(.callout).foregroundStyle(N1Design.muted).lineSpacing(4)

                    if HealthKitSource.isAvailable {
                        healthConnectStep
                    }

                    if (healthDone || !HealthKitSource.isAvailable) && !started {
                        Button {
                            started = true
                            Task { await agent.runOnboarding(days: snap.days) }
                        } label: {
                            Text("Take a look")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 15)
                        }
                        .background(N1Design.signal.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(N1Design.signal)
                    }

                    if agent.onboardingRunning {
                        AgentTimelineView(steps: agent.onboardingSteps, isRunning: true)
                    }

                    if !agent.onboardingCandidates.isEmpty {
                        SectionLabel(text: "Does this look right?")
                        ForEach(agent.onboardingCandidates) { c in
                            candidateCard(c)
                        }
                    } else if started && !agent.onboardingRunning {
                        InstrumentCard {
                            Text("Nothing confident enough to confirm yet")
                                .font(.body).foregroundStyle(N1Design.ink)
                            Text("That's fine — I'll learn as more data comes in.")
                                .font(.footnote).foregroundStyle(N1Design.muted)
                        }
                    }

                    if started && !agent.onboardingRunning {
                        Button {
                            groundTruth.finishOnboarding(); dismiss()
                        } label: {
                            Text("Done")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 15)
                        }
                        .background(N1Design.signal.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(N1Design.signal)
                    }

                    Button { groundTruth.finishOnboarding(); dismiss() } label: {
                        Text("Skip for now").font(.footnote).foregroundStyle(N1Design.faint)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.top, 4)
                }
                .padding(20)
            }
            .background(N1Design.bg)
            .scrollContentBackground(.hidden)
        }
    }

    /// Step 1: connect Apple Health. Requesting from inside this already-presented cover avoids the
    /// present-sheet-on-sheet race that silently fails at launch.
    @ViewBuilder
    private var healthConnectStep: some View {
        InstrumentCard {
            HStack(spacing: 8) {
                Image(systemName: "heart.text.square.fill").foregroundStyle(N1Design.signal)
                Text("Connect Apple Health")
                    .font(.n1Serif(19)).foregroundStyle(N1Design.ink)
            }
            Text("N1 reads your sleep, heart, and activity history to find patterns. Nothing leaves this device without your say-so.")
                .font(.callout).foregroundStyle(N1Design.muted).lineSpacing(4)

            if let outcome = healthOutcome, healthDone {
                if outcome.requested {
                    Label("Apple Health connected", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium)).foregroundStyle(N1Design.signal)
                    if snap.isDemo == false {
                        Text(snap.sourceLabel)
                            .font(.footnote).foregroundStyle(N1Design.faint)
                    }
                } else {
                    Label("Couldn't connect", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium)).foregroundStyle(N1Design.warn)
                    Text(outcome.error ?? "Open Settings → Health → Data Access & Devices → N1 to allow categories, then come back.")
                        .font(.footnote).foregroundStyle(N1Design.muted)
                }
            } else {
                Button {
                    connectHealth()
                } label: {
                    HStack {
                        if healthConnecting { ProgressView().tint(N1Design.signal) }
                        Text(healthConnecting ? "Connecting…" : "Connect Apple Health")
                            .font(.body.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                }
                .background(N1Design.signal.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(N1Design.signal)
                .disabled(healthConnecting)
            }
        }
    }

    private func connectHealth() {
        healthConnecting = true
        Task {
            let hk = HealthKitSource()
            let outcome = await hk.requestAuthorizationResult()
            // Now that permission has been presented from within the cover, load real data.
            await snap.loadData(requestAuth: false)
            healthOutcome = outcome
            healthConnecting = false
            healthDone = true
        }
    }

    @ViewBuilder
    private func candidateCard(_ c: AskAgent.GroundTruthSpec) -> some View {
        InstrumentCard {
            Text(c.statement)
                .font(.n1Serif(19)).foregroundStyle(N1Design.ink).lineSpacing(4)
            Text(c.question)
                .font(.callout).foregroundStyle(N1Design.muted)

            if handled.contains(c.id) {
                Label("Got it", systemImage: "checkmark.circle.fill")
                    .font(.footnote).foregroundStyle(N1Design.signal)
            } else if editing.contains(c.id) {
                let binding = Binding(get: { edits[c.id] ?? c.statement },
                                     set: { edits[c.id] = $0 })
                TextField("Fix it…", text: binding, axis: .vertical)
                    .textFieldStyle(.plain).padding(12)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(N1Design.ink)
                Button {
                    groundTruth.confirm(id: c.id, statement: edits[c.id] ?? c.statement)
                    handled.insert(c.id)
                } label: {
                    Text("Save").font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                }
                .background(N1Design.signal.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(N1Design.signal)
            } else {
                let options = c.options ?? ["Yes", "No"]
                HStack(spacing: 8) {
                    ForEach(Array(options.enumerated()), id: \.offset) { i, opt in
                        Button {
                            if i == 0 { groundTruth.confirm(id: c.id, statement: c.statement) }
                            handled.insert(c.id)
                        } label: {
                            Text(opt).font(.callout.weight(i == 0 ? .semibold : .regular))
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                        }
                        .background((i == 0 ? N1Design.signal.opacity(0.16) : Color.white.opacity(0.06)),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(i == 0 ? N1Design.signal : N1Design.muted)
                    }
                }
                if c.allowCustom != false {
                    Button { editing.insert(c.id) } label: {
                        Text("Not quite — let me fix it")
                            .font(.footnote).foregroundStyle(N1Design.faint)
                    }
                }
            }
        }
    }
}
