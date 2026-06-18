import SwiftUI

// MARK: - Experiments tab (lists every running / completed / dropped experiment)

struct ExperimentsView: View {
    @EnvironmentObject var experiments: ExperimentsStore
    @EnvironmentObject var snap: SnapshotStore

    /// Running first, then completed, then dropped; newest started first within each group.
    private var sorted: [Experiment] {
        func rank(_ s: ExperimentStatus) -> Int {
            switch s { case .running: 0; case .completed: 1; case .dropped: 2 }
        }
        return experiments.experiments.sorted {
            rank($0.status) != rank($1.status)
                ? rank($0.status) < rank($1.status)
                : $0.startedAt > $1.startedAt
        }
    }

    var body: some View {
        ScreenScaffold(stage: "Experiments", title: "Your experiments") {
            if !experiments.todayTasks.isEmpty {
                SectionLabel(text: "Today")
                ForEach(experiments.todayTasks) { task in
                    TodayTaskCard(task: task)
                }
            }

            SectionLabel(text: "All")
            if experiments.experiments.isEmpty {
                InstrumentCard {
                    Text("No experiments yet")
                        .font(.n1Serif(20)).foregroundStyle(N1Design.ink)
                    Text("When an answer needs confirming, start one from the Ask tab.")
                        .font(.callout).foregroundStyle(N1Design.muted)
                }
            } else {
                ForEach(sorted) { e in
                    NavigationLink {
                        ExperimentDetailView(experimentID: e.id)
                    } label: {
                        ExperimentRowCard(experiment: e)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        // Pull live real data into running experiments whenever this tab appears or the
        // snapshot refreshes. Idempotent and a no-op on demo/empty data.
        .onAppear { experiments.ingestRealData(days: snap.days) }
        .onChange(of: snap.days.count) { _, _ in experiments.ingestRealData(days: snap.days) }
    }
}

/// A single experiment in the "All" list.
private struct ExperimentRowCard: View {
    @EnvironmentObject var experiments: ExperimentsStore
    let experiment: Experiment

    var body: some View {
        InstrumentCard {
            HStack(alignment: .top) {
                Text(experiment.title)
                    .font(.n1Serif(18)).foregroundStyle(N1Design.ink)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                StatusChip(status: experiment.status)
            }
            HStack {
                Text("\(experiment.recordedCount)/\(experiment.measurableDays.count) days")
                    .font(.n1Mono(12)).foregroundStyle(N1Design.muted)
                Spacer()
                Button {
                    experiments.remove(experiment.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.footnote).foregroundStyle(N1Design.faint)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct StatusChip: View {
    let status: ExperimentStatus
    var body: some View {
        let (text, color): (String, Color) = {
            switch status {
            case .running:   ("Running", N1Design.signal)
            case .completed: ("Completed", N1Design.signal)
            case .dropped:   ("Dropped", N1Design.faint)
            }
        }()
        Text(text)
            .font(.n1Mono(10, weight: .semibold))
            .padding(.vertical, 3).padding(.horizontal, 9)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Today task card (inline quick answers for due self-reports)

private struct TodayTaskCard: View {
    @EnvironmentObject var experiments: ExperimentsStore
    let task: ExperimentsStore.TodayTask

    var body: some View {
        InstrumentCard {
            Text(task.experiment.title)
                .font(.n1Mono(11)).foregroundStyle(N1Design.muted)
            Text(task.instruction.title)
                .font(.n1Serif(20)).foregroundStyle(N1Design.ink)
            Text(task.instruction.detail)
                .font(.callout).foregroundStyle(N1Design.muted)

            // Currently-due self-reports: one row per due slot, with a "log now" control.
            ForEach(task.dueReports) { item in
                let slots = task.experiment.dueSlots(for: item)
                ForEach(slots, id: \.self) { slot in
                    QuickAnswerRow(experimentID: task.id, item: item, slot: slot,
                                   slotLabel: "Due · \(SelfReportItem.prettyTime(slot))")
                }
            }

            // Not-yet-due items eligible today: a small "next at HH:mm" hint.
            ForEach(task.upcomingReports) { item in
                if let next = task.experiment.nextDueLabel(for: item) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock").font(.caption2).foregroundStyle(N1Design.faint)
                        Text(item.question).font(.footnote).foregroundStyle(N1Design.muted)
                        Spacer(minLength: 6)
                        Text(next.replacingOccurrences(of: "Next: ", with: ""))
                            .font(.n1Mono(11)).foregroundStyle(N1Design.faint)
                    }
                    .padding(.top, 2)
                }
            }
        }
    }
}

/// One self-report question with an inline answer control.
/// If `slot` is set, the answer is logged against that specific time-slot; otherwise it's an
/// ad-hoc log (the user can log any item at any time). `slotLabel` is optional caption text.
private struct QuickAnswerRow: View {
    @EnvironmentObject var experiments: ExperimentsStore
    let experimentID: UUID
    let item: SelfReportItem
    var slot: String? = nil
    var slotLabel: String? = nil
    /// When true (ad-hoc "log now"), keep the control visible so the user can log again.
    var alwaysAllowLogging = false
    @State private var numberText = ""

    /// "Answered" means: this specific slot is logged today (slot mode), or any log today (ad-hoc).
    private var answeredToday: Bool {
        guard let e = experiments.get(experimentID) else { return false }
        if let slot { return e.isSlotLogged(item.id, slot: slot) }
        return !e.logs(for: item.id, on: Date()).isEmpty
    }

    /// Whether to show the input control.
    private var showControl: Bool { alwaysAllowLogging || !answeredToday }

    private func record(_ value: Double) {
        experiments.logSelfReport(experimentID, itemId: item.id, value: value, slot: slot)
        numberText = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if answeredToday {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.footnote).foregroundStyle(N1Design.signal)
                }
                Text(item.question)
                    .font(.callout).foregroundStyle(N1Design.ink)
                if let slotLabel {
                    Spacer(minLength: 6)
                    Text(slotLabel).font(.n1Mono(10)).foregroundStyle(N1Design.faint)
                }
            }
            if showControl {
                control
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder private var control: some View {
        switch item.type {
        case .scale:
            HStack(spacing: 6) {
                ForEach(1...(item.scaleMax ?? 5), id: \.self) { n in
                    chip("\(n)") { record(Double(n)) }
                }
            }
        case .yesNo:
            HStack(spacing: 6) {
                chip("Yes") { record(1) }
                chip("No") { record(0) }
            }
        case .number:
            HStack(spacing: 8) {
                TextField("value", text: $numberText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(N1Design.ink)
                    .frame(maxWidth: 120)
                Button {
                    if let v = Double(numberText) { record(v); numberText = "" }
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 26)).foregroundStyle(N1Design.signal)
                }
                .disabled(Double(numberText) == nil)
            }
        case .choice:
            Menu {
                ForEach(Array((item.options ?? []).enumerated()), id: \.offset) { idx, opt in
                    Button(opt) { record(Double(idx)) }
                }
            } label: {
                HStack {
                    Text("Choose…").font(.callout).foregroundStyle(N1Design.signal)
                    Image(systemName: "chevron.down").font(.caption).foregroundStyle(N1Design.faint)
                }
                .padding(.vertical, 8).padding(.horizontal, 12)
                .background(N1Design.signal.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func chip(_ text: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.n1Mono(14, weight: .medium))
                .frame(minWidth: 34).padding(.vertical, 8)
                .background(N1Design.signal.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                .foregroundStyle(N1Design.signal)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Logging schedule row (detail view)

/// One self-report item in the detail "Logging schedule" card: question, rule string,
/// next-due hint, and an inline control to log it right now (ad-hoc, no fixed slot).
private struct SelfReportScheduleRow: View {
    @EnvironmentObject var experiments: ExperimentsStore
    let experimentID: UUID
    let item: SelfReportItem

    private var experiment: Experiment? { experiments.get(experimentID) }

    private var statusLine: String {
        guard let e = experiment else { return item.ruleString }
        if e.allLoggedToday(for: item) { return "All logged for today" }
        return e.nextDueLabel(for: item) ?? item.ruleString
    }

    private var allLogged: Bool { experiment?.allLoggedToday(for: item) ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.question).font(.callout).foregroundStyle(N1Design.ink)
            HStack(spacing: 8) {
                Text(item.ruleString).font(.n1Mono(11)).foregroundStyle(N1Design.muted)
                Spacer(minLength: 6)
                HStack(spacing: 4) {
                    Image(systemName: allLogged ? "checkmark.circle.fill" : "clock")
                        .font(.caption2)
                        .foregroundStyle(allLogged ? N1Design.signal : N1Design.faint)
                    Text(statusLine).font(.n1Mono(11))
                        .foregroundStyle(allLogged ? N1Design.signal : N1Design.faint)
                }
            }
            // Always allow an ad-hoc log here (log any item at any time).
            QuickAnswerRow(experimentID: experimentID, item: item, slot: nil,
                           slotLabel: "log now", alwaysAllowLogging: true)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

struct ExperimentDetailView: View {
    @EnvironmentObject var experiments: ExperimentsStore
    let experimentID: UUID

    var body: some View {
        if let e = experiments.get(experimentID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(e)
                    designCard(e)
                    progressCard(e)
                    if !e.selfReports.isEmpty { selfReportsCard(e) }
                    actions(e)
                    if let a = e.analysis { resultCard(a) }
                    dropButton(e)
                }
                .padding(20)
            }
            .background(N1Design.bg)
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // —— header ——
    private func header(_ e: Experiment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(e.title).font(.n1Serif(24)).foregroundStyle(N1Design.ink)
                Spacer(minLength: 8)
                StatusChip(status: e.status)
            }
            Text(e.hypothesis).font(.callout).foregroundStyle(N1Design.muted)
        }
    }

    // —— design ——
    private func designCard(_ e: Experiment) -> some View {
        InstrumentCard {
            SectionLabel(text: "Design")
            Text("\(e.pairs) paired blocks × \(e.daysPerBlock) days, \(e.washoutDays)-day washout")
                .font(.callout).foregroundStyle(N1Design.ink)
            Text("Pre-registered \(e.lockedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.n1Mono(11)).foregroundStyle(N1Design.faint)
            Text("SHA-256 \(e.specHash.prefix(12))…")
                .font(.n1Mono(11)).foregroundStyle(N1Design.faint)
            blockStrip(e)
        }
    }

    private func blockStrip(_ e: Experiment) -> some View {
        HStack(spacing: 3) {
            ForEach(e.days) { d in
                RoundedRectangle(cornerRadius: 3)
                    .fill(color(for: d.kind))
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
            }
        }
        .padding(.top, 4)
    }

    private func color(for kind: DayKind) -> Color {
        switch kind {
        case .intervention: N1Design.signal.opacity(0.85)
        case .control:      Color.white.opacity(0.22)
        case .washout:      Color.clear
        }
    }

    // —— progress ——
    private func progressCard(_ e: Experiment) -> some View {
        InstrumentCard {
            SectionLabel(text: "Progress")
            ProgressView(value: Double(e.recordedCount),
                         total: Double(max(e.measurableDays.count, 1)))
                .tint(N1Design.signal)
            Text("\(e.recordedCount) of \(e.measurableDays.count) days recorded")
                .font(.n1Mono(12)).foregroundStyle(N1Design.muted)
        }
    }

    // —— self-reports / logging schedule ——
    private func selfReportsCard(_ e: Experiment) -> some View {
        InstrumentCard {
            SectionLabel(text: "Logging schedule")
            ForEach(Array(e.selfReports.enumerated()), id: \.element.id) { idx, item in
                SelfReportScheduleRow(experimentID: e.id, item: item)
                if idx < e.selfReports.count - 1 {
                    Divider().overlay(N1Design.faint.opacity(0.4)).padding(.vertical, 4)
                }
            }
        }
    }

    // —— actions ——
    @ViewBuilder private func actions(_ e: Experiment) -> some View {
        VStack(spacing: 10) {
            // "Fill demo data" only makes sense without real HealthKit data (i.e. the simulator).
            // On a real device we rely on ExperimentsStore.ingestRealData from the live snapshot.
            if e.recordedCount == 0 && !HealthKitSource.isAvailable {
                Button {
                    experiments.fillDemo(e.id)
                } label: {
                    Label("Fill demo data", systemImage: "wand.and.stars")
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(N1Design.muted)
            }

            Button {
                experiments.analyze(e.id)
            } label: {
                HStack {
                    if experiments.analyzingID == e.id {
                        ProgressView().tint(N1Design.signal)
                    } else {
                        Text("Analyze").font(.body.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 13)
            }
            .background(N1Design.signal.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(N1Design.signal)
            .disabled(experiments.analyzingID == e.id || e.recordedCount == 0)
        }
    }

    // —— result ——
    private func resultCard(_ a: AnalysisSummary) -> some View {
        InstrumentCard {
            TierBadge(tier: a.evidence == "strong" ? .confirmed : .tested)
            Text(a.headline).font(.n1Serif(21)).foregroundStyle(N1Design.ink).lineSpacing(5)
            Text(a.confidence).font(.callout).foregroundStyle(N1Design.signal).lineSpacing(4)
            HStack(spacing: 14) {
                readout("mean \(String(format: "%+.2f", a.deltaMean))")
                readout("90% CI [\(String(format: "%.1f", a.ciLow)), \(String(format: "%.1f", a.ciHigh))]")
            }
            HStack(spacing: 14) {
                readout("P(dir) \(String(format: "%.2f", a.pDirection))")
                readout("R̂ \(String(format: "%.3f", a.rHat))")
            }
            Text("Numbers from the open-source N1Stats engine; not medical advice.")
                .font(.footnote).foregroundStyle(N1Design.faint)
        }
    }

    private func readout(_ text: String) -> some View {
        Text(text).font(.n1Mono(12)).foregroundStyle(N1Design.ink)
    }

    // —— drop ——
    @ViewBuilder private func dropButton(_ e: Experiment) -> some View {
        if e.status == .running {
            Button {
                experiments.drop(e.id)
            } label: {
                Text("Drop this experiment")
                    .font(.callout)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .foregroundStyle(N1Design.faint)
        }
    }
}
