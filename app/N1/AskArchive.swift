import SwiftUI
import Charts

// MARK: - Snapshot state layer

@MainActor
final class SnapshotStore: ObservableObject {
    @Published var days: [DailyMetric] = []
    @Published var questionText = ""
    @Published var sourceLabel = ""
    @Published var activeTab = 0
    @Published var isDemo = true

    /// Real-data-only policy: on a real device (HealthKit available) we ALWAYS use real data and
    /// never substitute demo, even if the real data is thin — we just surface that honestly.
    /// Demo is used ONLY when HealthKit is unavailable (the simulator).
    ///
    /// `requestAuth` is true on the initial load (so we present the authorization sheet) and false
    /// on background refreshes (we just re-fetch). The sheet is best presented from onboarding to
    /// avoid the present-sheet-on-sheet race, but requesting here too is harmless and idempotent.
    func loadData(requestAuth: Bool = true) async {
        guard HealthKitSource.isAvailable else {
            // Simulator / no HealthKit: demo data only.
            days = await DemoSource().fetchDailyMetrics(daysBack: 180)
            isDemo = true
            sourceLabel = "Demo data (HealthKit isn't available on this device)"
            return
        }

        let hk = HealthKitSource()
        var auth = HealthAuthResult(available: true, requested: false, error: nil)
        if requestAuth {
            auth = await hk.requestAuthorizationResult()
        }
        let real = await hk.fetchDailyMetrics(daysBack: 180)
        let usable = real.filter { $0.hrv != nil || $0.sleepMinutes != nil }.count

        // ALWAYS keep real data on a real device — never fall back to demo.
        days = real
        isDemo = false
        sourceLabel = Self.realDataLabel(usable: usable)

        HealthKitSource.writeDiagnostic(auth: auth, days: real)
    }

    /// Honest label for real data, including the thin/empty states (no demo substitution).
    private static func realDataLabel(usable: Int) -> String {
        if usable >= 14 {
            return "Apple Health connected — \(usable) days so far"
        } else if usable > 0 {
            return "Apple Health connected — \(usable) days so far (still gathering)"
        } else {
            return "No Health data yet — open Settings → Health → N1 to allow categories"
        }
    }

    /// Called when the app returns to the foreground. On a real device, re-fetch real data
    /// (never demo). On the simulator there is nothing to refresh.
    func refreshFromHealth() async {
        guard HealthKitSource.isAvailable else { return }
        await loadData(requestAuth: false)
    }
}

/// Mapping from a snapshot grouping to a "two-week mini-experiment" (weekend can't be experimented on).
extension GroupingRule {
    var experimentPlan: (hypothesis: String, intervention: String, control: String)? {
        switch self {
        case .lateNight: ("Would an earlier bedtime improve my nightly recovery?", "Asleep before 00:30", "Stick to my usual routine")
        case .exerciseDay: ("Would daytime exercise improve my nightly recovery?", "Exercise ≥ 20 min during the day", "No planned exercise")
        case .highSteps: ("Would walking more improve how I feel?", "≥ 9,000 steps that day", "Carry on as usual")
        case .weekend: nil
        }
    }
}

// MARK: - Ask

struct AskView: View {
    @EnvironmentObject var snap: SnapshotStore
    @EnvironmentObject var agent: AskAgent
    @EnvironmentObject var history: InvestigationStore
    @EnvironmentObject var groundTruth: GroundTruthStore
    @FocusState private var focused: Bool
    @State private var followupText = ""

    private let genericSuggestions = [
        "Do late nights hurt my recovery?",
        "Do I sleep better on days I work out?",
        "Does afternoon coffee affect my sleep?",
    ]
    /// Personalized starter questions from onboarding, else generic fallbacks.
    private var suggestions: [String] {
        groundTruth.suggestedQuestions.isEmpty ? genericSuggestions : groundTruth.suggestedQuestions
    }

    var body: some View {
        ScreenScaffold(stage: "Ask", title: "What do you want to figure out?") {
            HStack(spacing: 10) {
                TextField("Ask in your own words, in any language...", text: $snap.questionText, axis: .vertical)
                    .focused($focused)
                    .textFieldStyle(.plain)
                    .padding(14)
                    .background(N1Design.card, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(N1Design.ink)
                Button { submit(snap.questionText) } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(N1Design.signal)
                }
                .disabled(agent.isRunning)
            }

            if history.active == nil {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: groundTruth.suggestedQuestions.isEmpty ? "You might ask" : "Worth asking, based on your data")
                    ForEach(suggestions, id: \.self) { s in
                        Button { snap.questionText = s; submit(s) } label: {
                            Text(s)
                                .font(.callout)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(N1Design.muted)
                                .padding(.vertical, 9).padding(.horizontal, 13)
                                .background(Color.white.opacity(0.05),
                                            in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }

            if let thread = history.active {
                let turns = Array(thread.turns.enumerated())
                ForEach(turns, id: \.element.id) { idx, turn in
                    if idx == thread.turns.count - 1 {
                        TurnBodyView(turn: turn, isLast: true)
                    } else {
                        DisclosureGroup {
                            TurnBodyView(turn: turn, isLast: false)
                                .padding(.top, 6)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(turn.prompt)
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(N1Design.ink)
                                    .lineLimit(1)
                                Text("\(turn.steps.count) steps · \(turn.findings.count) findings")
                                    .font(.footnote).foregroundStyle(N1Design.faint)
                            }
                        }
                        .tint(N1Design.muted)
                        .padding(14)
                        .background(N1Design.card, in: RoundedRectangle(cornerRadius: 12))
                    }
                }

                if !agent.isRunning, let last = thread.turns.last, last.pendingAsk == nil {
                    HStack(spacing: 10) {
                        TextField("Ask a follow-up...", text: $followupText, axis: .vertical)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(N1Design.ink)
                        Button { sendFollowup() } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 28)).foregroundStyle(N1Design.signal)
                        }
                        .disabled(followupText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }

            Text(snap.sourceLabel)
                .font(.footnote).foregroundStyle(N1Design.faint)
        }
    }

    private func submit(_ text: String) {
        focused = false
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        Task {
            await agent.run(question: q, days: snap.days)
        }
    }

    private func sendFollowup() {
        let q = followupText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        followupText = ""
        focused = false
        Task {
            await agent.dig(question: q, days: snap.days)
        }
    }
}

/// Renders one turn of an investigation: timeline, narration, findings, unmeasured factors,
/// collection plan, pending clarification, and "keep digging" chips.
struct TurnBodyView: View {
    @EnvironmentObject var snap: SnapshotStore
    @EnvironmentObject var agent: AskAgent
    let turn: Turn
    let isLast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !turn.steps.isEmpty {
                AgentTimelineView(steps: turn.steps, isRunning: turn.isRunning)
            }

            if let narration = turn.narration {
                InstrumentCard {
                    SectionLabel(text: "AI summary")
                    Text(narration)
                        .font(.n1Serif(19))
                        .foregroundStyle(N1Design.ink)
                        .lineSpacing(5)
                    Text("The narrative comes from the AI; every number comes from the cards.")
                        .font(.footnote).foregroundStyle(N1Design.faint)
                }
            }

            ForEach(turn.findings) { finding in
                GenericFindingCard(finding: finding)
            }

            ForEach(Array(turn.unmeasured.enumerated()), id: \.offset) { _, u in
                NeedsExperimentCard(exposure: u.factor, suggestion: u.suggestion)
            }

            if let plan = turn.plan {
                CollectionPlanCard(plan: plan)
            }

            if isLast, turn.pendingAsk != nil {
                ClarifyCard(turn: turn)
            }

            if !turn.followups.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Keep digging")
                    ForEach(turn.followups, id: \.self) { f in
                        Button {
                            Task {
                                await agent.dig(question: f, days: snap.days)
                            }
                        } label: {
                            Text(f)
                                .font(.callout)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(N1Design.signal)
                                .padding(.vertical, 9).padding(.horizontal, 13)
                                .background(N1Design.signal.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 10))
                        }
                        .disabled(agent.isRunning)
                    }
                }
            }
        }
    }
}

/// The agent's clarifying question (a general mechanism): multiple-choice options + a custom answer; the answer enters the context and reasoning continues.
struct ClarifyCard: View {
    @EnvironmentObject var snap: SnapshotStore
    @EnvironmentObject var agent: AskAgent
    let turn: Turn
    @State private var answer = ""

    private func send(_ a: String) {
        let trimmed = a.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        answer = ""
        Task {
            await agent.clarify(answer: trimmed, days: snap.days)
        }
    }

    var body: some View {
        InstrumentCard {
            SectionLabel(text: "The agent wants to check with you")
            Text(turn.pendingAsk ?? "")
                .font(.n1Serif(19))
                .foregroundStyle(N1Design.ink)
                .lineSpacing(5)

            // Structured options: tap one to answer
            ForEach(turn.pendingOptions, id: \.self) { opt in
                Button { send(opt) } label: {
                    HStack {
                        Text(opt).font(.callout).foregroundStyle(N1Design.ink)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(N1Design.faint)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(N1Design.warn.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                .disabled(agent.isRunning)
            }

            // Custom answer
            if turn.pendingAllowCustom {
                HStack(spacing: 10) {
                    TextField(turn.pendingOptions.isEmpty ? "Your answer..." : "Or say it yourself...",
                              text: $answer, axis: .vertical)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(N1Design.ink)
                    Button { send(answer) } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28)).foregroundStyle(N1Design.warn)
                    }
                    .disabled(answer.isEmpty || agent.isRunning)
                }
            }
        }
    }
}

/// Card for a finding the agent analyzed on its own (generic rendering: headline / caveat / two-group scatter / experiment suggestion, all decided by the agent).
struct GenericFindingCard: View {
    @EnvironmentObject var snap: SnapshotStore
    @EnvironmentObject var experiments: ExperimentsStore
    let finding: FindingRec

    var body: some View {
        InstrumentCard {
            TierBadge(tier: .snapshot)
            Text(finding.headline)
                .font(.n1Serif(21))
                .foregroundStyle(N1Design.ink)
                .lineSpacing(5)
            if let caveat = finding.caveat, !caveat.isEmpty {
                Text(caveat).font(.callout).foregroundStyle(N1Design.muted)
            }
            if let plot = finding.plot {
                NightlyStripPlot(points:
                    plot.valuesA.map { ($0, plot.labelA) } +
                    plot.valuesB.map { ($0, plot.labelB) })
            }
            if let e = finding.experiment {
                Button {
                    experiments.create(title: e.hypothesis, hypothesis: e.hypothesis,
                                       intervention: e.intervention, control: e.control,
                                       selfReports: e.selfReports, baselineFrom: snap.days)
                    snap.activeTab = 1
                } label: {
                    Text("Want to confirm it's causal? Run an experiment over about two weeks")
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .background(N1Design.signal.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(N1Design.signal)
            }
        }
    }
}

/// Collection-plan card: when data is insufficient, "start tracking today" + a bedtime reminder.
struct CollectionPlanCard: View {
    @EnvironmentObject var collection: CollectionStore
    @EnvironmentObject var snap: SnapshotStore
    let plan: CollectionPlan
    @State private var started = false

    var body: some View {
        InstrumentCard {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.clock").foregroundStyle(N1Design.warn)
                SectionLabel(text: "Too soon for a long-term conclusion")
            }
            Text(plan.rationale)
                .font(.n1Serif(19)).foregroundStyle(N1Design.ink).lineSpacing(5)

            VStack(alignment: .leading, spacing: 6) {
                row("Start logging today", plan.signalLabels.joined(separator: ", "))
                row("For", "\(plan.durationDays) days")
                row("Nightly reminder", String(format: "%02d:%02d", plan.reminderHour, plan.reminderMinute))
            }
            Text("“\(plan.reminderText)”")
                .font(.footnote).foregroundStyle(N1Design.muted)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

            if started {
                Label("Tracking started. We'll remind you to wear your watch each night, and if we notice a missed log, we'll nudge you again before bed.",
                      systemImage: "checkmark.circle.fill")
                    .font(.footnote).foregroundStyle(N1Design.signal)
            } else {
                Button {
                    started = true
                    Task { await collection.activate(plan) }
                } label: {
                    Text("Sounds good, start tracking today")
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                }
                .background(N1Design.signal.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(N1Design.signal)
                Text("We'll ask for notification permission to send bedtime reminders. Your data still never leaves your device.")
                    .font(.footnote).foregroundStyle(N1Design.faint)
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.callout).foregroundStyle(N1Design.muted)
            Spacer()
            Text(v).font(.n1Mono(13)).foregroundStyle(N1Design.signal)
        }
    }
}

/// Active tracking (top of the Archive screen): adherence progress + missed-log prompts.
struct ActiveTrackingCard: View {
    @EnvironmentObject var collection: CollectionStore
    @EnvironmentObject var snap: SnapshotStore
    let plan: CollectionPlan

    var body: some View {
        let a = collection.adherence(plan, days: snap.days)
        InstrumentCard {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(N1Design.signal)
                SectionLabel(text: "Tracking")
            }
            Text(plan.goal).font(.body.weight(.medium)).foregroundStyle(N1Design.ink)
            ProgressView(value: Double(plan.daysElapsed), total: Double(plan.durationDays))
                .tint(N1Design.signal)
            HStack {
                Text("\(a.recorded) nights logged · about \(max(plan.durationDays - plan.daysElapsed, 0)) days to go")
                    .font(.n1Mono(12)).foregroundStyle(N1Design.muted)
                Spacer()
                Button("Stop") { collection.cancel(plan) }
                    .font(.footnote).foregroundStyle(N1Design.faint)
            }
            if a.missedYesterday {
                Label("Looks like no data was logged last night — remember to wear your watch tonight.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(N1Design.warn)
            }
            if plan.isComplete {
                Label("Tracking period's up — you can come back and ask me that question now.", systemImage: "checkmark.seal")
                    .font(.footnote).foregroundStyle(N1Design.signal)
            }
        }
    }
}

/// Behavioral-rhythm discovery card: visualize hourly weekday activity + ask the user to confirm the work schedule.
/// Analysis-process timeline: surface, step by step, what the AI is doing for you.
struct AgentTimelineView: View {
    let steps: [StepRec]
    var isRunning = false

    var body: some View {
        InstrumentCard {
            SectionLabel(text: "How we got here")
            ForEach(Array(steps.enumerated()), id: \.element.id) { idx, step in
                let isLastRunning = isRunning && idx == steps.count - 1
                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        Circle()
                            .fill((isLastRunning ? N1Design.warn : N1Design.signal).opacity(0.14))
                            .frame(width: 26, height: 26)
                        if isLastRunning {
                            ProgressView().scaleEffect(0.5).tint(N1Design.warn)
                        } else {
                            Image(systemName: step.icon)
                                .font(.system(size: 11))
                                .foregroundStyle(N1Design.signal)
                        }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.title)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(N1Design.ink)
                        if !step.detail.isEmpty {
                            Text(step.detail)
                                .font(.footnote)
                                .foregroundStyle(N1Design.faint)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .animation(.easeOut(duration: 0.2), value: steps.count)
    }
}

/// Exposure can't be measured (coffee/overtime/mood, ...): tell the user honestly, and an experiment is the only way.
struct NeedsExperimentCard: View {
    @EnvironmentObject var snap: SnapshotStore
    @EnvironmentObject var experiments: ExperimentsStore
    let exposure: String
    var suggestion: String = "Spend a few days each way and compare directly."

    var body: some View {
        InstrumentCard {
            Text("Your watch can't see \"\(exposure)\"")
                .font(.n1Serif(21)).foregroundStyle(N1Design.ink)
            Text(suggestion)
                .font(.callout).foregroundStyle(N1Design.muted).lineSpacing(4)
            Button {
                experiments.create(
                    title: "Does \(exposure) affect my recovery?",
                    hypothesis: "Does \(exposure) affect my nightly recovery?",
                    intervention: "Days with \(exposure)",
                    control: "Days avoiding \(exposure)",
                    baselineFrom: snap.days)
                snap.activeTab = 1
            } label: {
                Text("Run an experiment over about two weeks")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .background(N1Design.signal.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(N1Design.signal)
        }
    }
}

struct TierBadge: View {
    let tier: EvidenceTier
    var body: some View {
        Text(tier.badge)
            .font(.n1Mono(11, weight: .semibold))
            .padding(.vertical, 3).padding(.horizontal, 10)
            .background((tier == .confirmed ? N1Design.signal : N1Design.warn).opacity(0.14),
                        in: Capsule())
            .foregroundStyle(tier == .confirmed ? N1Design.signal : N1Design.warn)
    }
}

// MARK: - Archive

struct ArchiveView: View {
    @EnvironmentObject var snap: SnapshotStore
    @EnvironmentObject var experiments: ExperimentsStore
    @EnvironmentObject var history: InvestigationStore
    @EnvironmentObject var collection: CollectionStore
    @EnvironmentObject var groundTruth: GroundTruthStore

    @State private var showSettings = false

    private var completed: [Experiment] { experiments.experiments.filter { $0.status == .completed } }

    var body: some View {
        ScreenScaffold(stage: "Archive", title: "Your findings", content: {
            if !groundTruth.facts.isEmpty {
                GroundTruthCard()
            }
            ForEach(collection.plans) { plan in
                ActiveTrackingCard(plan: plan)
            }
            ForEach(completed) { e in
                InstrumentCard {
                    TierBadge(tier: e.analysis?.evidence == "strong" ? .confirmed : .tested)
                    Text(e.title)
                        .font(.n1Serif(20)).foregroundStyle(N1Design.ink)
                        .multilineTextAlignment(.leading)
                    if let headline = e.analysis?.headline {
                        Text(headline)
                            .font(.callout).foregroundStyle(N1Design.muted)
                            .multilineTextAlignment(.leading)
                    }
                }
            }

            if history.threads.isEmpty && collection.plans.isEmpty && completed.isEmpty {
                InstrumentCard {
                    Text("No findings yet")
                        .font(.n1Serif(20)).foregroundStyle(N1Design.ink)
                    Text("Head to Ask and pose a question. Every investigation lands here, ready to revisit.")
                        .font(.callout).foregroundStyle(N1Design.muted)
                }
            }

            ForEach(history.threads) { thread in
                Button {
                    history.open(thread.id)
                    snap.activeTab = 0
                } label: {
                    InstrumentCard {
                        Text(thread.title)
                            .font(.n1Serif(20)).foregroundStyle(N1Design.ink)
                            .multilineTextAlignment(.leading)
                        if let last = thread.lastFinding, !last.isEmpty {
                            Text(last)
                                .font(.callout).foregroundStyle(N1Design.muted)
                                .multilineTextAlignment(.leading)
                        }
                        HStack {
                            Text("\(thread.turns.count) turns · \(thread.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.n1Mono(11)).foregroundStyle(N1Design.faint)
                            Spacer()
                            Button {
                                history.delete(thread.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.footnote).foregroundStyle(N1Design.faint)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }, toolbar: {
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(N1Design.muted)
            }
            .accessibilityLabel("Settings")
        })
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }
}

/// "What I know about you" — the confirmed ground truth as one editable knowledge card.
/// Editable because life changes (people move, switch jobs, change habits).
struct GroundTruthCard: View {
    @EnvironmentObject var groundTruth: GroundTruthStore
    @State private var editingID: String?
    @State private var draft = ""
    @State private var adding = false
    @State private var newText = ""

    /// A small icon hint inferred from the fact text — purely cosmetic.
    private func icon(for s: String) -> String {
        let t = s.lowercased()
        if t.contains("work") || t.contains("office") || t.contains("job") { return "briefcase" }
        if t.contains("home") || t.contains("live") || t.contains("neighborhood") { return "house" }
        if t.contains("sleep") || t.contains("bed") || t.contains("wake") { return "bed.double" }
        if t.contains("exercise") || t.contains("workout") || t.contains("active") || t.contains("run") { return "figure.run" }
        if t.contains("time zone") || t.contains("timezone") || t.contains("pacific") || t.contains("location") || t.contains("city") || t.contains("area") { return "mappin.and.ellipse" }
        return "person.text.rectangle"
    }

    var body: some View {
        InstrumentCard {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .foregroundStyle(N1Design.signal)
                Text("What I know about you")
                    .font(.n1Serif(18)).foregroundStyle(N1Design.ink)
                Spacer()
                Button { adding = true; newText = "" } label: {
                    Image(systemName: "plus.circle").foregroundStyle(N1Design.signal)
                }
                .buttonStyle(.plain)
            }
            Text("Tap a fact to update it — people move, switch jobs, change habits.")
                .font(.footnote).foregroundStyle(N1Design.faint)

            VStack(spacing: 0) {
                ForEach(Array(groundTruth.facts.enumerated()), id: \.element.id) { idx, fact in
                    if idx > 0 { Divider().overlay(N1Design.faint.opacity(0.3)) }
                    if editingID == fact.id {
                        editor(id: fact.id)
                    } else {
                        Button { editingID = fact.id; draft = fact.statement } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: icon(for: fact.statement))
                                    .font(.system(size: 13)).foregroundStyle(N1Design.signal)
                                    .frame(width: 18)
                                Text(fact.statement)
                                    .font(.callout).foregroundStyle(N1Design.ink)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 6)
                                Image(systemName: "pencil")
                                    .font(.caption2).foregroundStyle(N1Design.faint)
                            }
                            .padding(.vertical, 11)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if adding {
                Divider().overlay(N1Design.faint.opacity(0.3))
                HStack(spacing: 8) {
                    TextField("Add something I should know…", text: $newText, axis: .vertical)
                        .textFieldStyle(.plain).padding(10)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                        .foregroundStyle(N1Design.ink)
                    Button {
                        let t = newText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { groundTruth.confirm(id: "user_\(UUID().uuidString.prefix(8))", statement: t) }
                        adding = false; newText = ""
                    } label: { Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(N1Design.signal) }
                    .buttonStyle(.plain)
                }
                .padding(.top, 8)
            }

            Button { groundTruth.resetOnboarding() } label: {
                Label("Re-run setup", systemImage: "arrow.clockwise")
                    .font(.footnote).foregroundStyle(N1Design.muted)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private func editor(id: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Update this fact…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain).padding(10)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                .foregroundStyle(N1Design.ink)
            HStack(spacing: 10) {
                Button {
                    let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { groundTruth.confirm(id: id, statement: t) }
                    editingID = nil
                } label: {
                    Text("Save").font(.footnote.weight(.semibold))
                        .padding(.vertical, 8).padding(.horizontal, 18)
                        .background(N1Design.signal.opacity(0.16), in: Capsule())
                        .foregroundStyle(N1Design.signal)
                }
                .buttonStyle(.plain)
                Button { editingID = nil } label: {
                    Text("Cancel").font(.footnote).foregroundStyle(N1Design.muted)
                }
                .buttonStyle(.plain)
                Spacer()
                Button { groundTruth.remove(id: id); editingID = nil } label: {
                    Image(systemName: "trash").font(.footnote).foregroundStyle(N1Design.faint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10)
    }
}
