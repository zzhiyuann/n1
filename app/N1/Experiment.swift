import Foundation
import CryptoKit
import N1Stats

// MARK: - Self-report (EMA / diary) items, designed by the agent per digital-health methods

struct SelfReportItem: Codable, Identifiable, Equatable {
    var id: String
    var question: String
    enum Kind: String, Codable { case scale, number, yesNo, choice }
    var type: Kind
    var scaleMax: Int?          // for .scale (e.g. 5)
    var options: [String]?      // for .choice
    enum When: String, Codable { case morning, preSleep, momentary
        var label: String {
            switch self { case .morning: "Morning"; case .preSleep: "Before sleep"; case .momentary: "During the day" }
        }
        /// Sensible default time-slots when the agent didn't specify any.
        var defaultTimes: [String] {
            switch self {
            case .morning:   ["09:00"]
            case .preSleep:  ["21:30"]
            case .momentary: ["10:00", "14:00", "18:00"]
            }
        }
    }
    var when: When

    // —— flexible schedule (new; optional/defaulted so old data & agent JSON still decode) ——
    /// HH:mm slots in the day, e.g. ["09:00"] or ["09:00","13:00","21:00"].
    /// Empty means "derive from `when`" (see `slots`).
    var times: [String] = []
    /// 1 = every day, 2 = every other day, etc. Counted from the experiment's startedAt.
    var everyNDays: Int = 1

    /// Effective time-slots: explicit `times` if present, else derived from `when`.
    /// Always sorted ascending and de-duplicated so "next slot" math is stable.
    var slots: [String] {
        let raw = times.isEmpty ? when.defaultTimes : times
        return Array(Set(raw)).sorted()
    }

    /// Cadence in days, floored at 1 (defensive against bad/zero decoded values).
    var cadenceDays: Int { max(1, everyNDays) }

    /// Human-readable rule, e.g. "3×/day · 9:00, 13:00, 21:00" or "every 2 days · 21:30".
    var ruleString: String {
        let slotList = slots.map(SelfReportItem.prettyTime).joined(separator: ", ")
        let cadence: String
        switch cadenceDays {
        case 1:  cadence = slots.count > 1 ? "\(slots.count)×/day" : "daily"
        case 2:  cadence = "every 2 days"
        default: cadence = "every \(cadenceDays) days"
        }
        return slotList.isEmpty ? cadence : "\(cadence) · \(slotList)"
    }

    /// Memberwise-compatible initializer so Agent.swift's call site
    /// `SelfReportItem(id:question:type:scaleMax:options:when:)` keeps compiling,
    /// while new call sites can pass `times`/`everyNDays`.
    init(id: String, question: String, type: Kind,
         scaleMax: Int? = nil, options: [String]? = nil, when: When,
         times: [String] = [], everyNDays: Int = 1) {
        self.id = id
        self.question = question
        self.type = type
        self.scaleMax = scaleMax
        self.options = options
        self.when = when
        self.times = times
        self.everyNDays = everyNDays
    }

    // Custom decoding so already-persisted experiments (without `times`/`everyNDays`)
    // and the agent's SelfReportSpec JSON decode cleanly with defaults.
    enum CodingKeys: String, CodingKey {
        case id, question, type, scaleMax, options, when, times, everyNDays
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        question = try c.decode(String.self, forKey: .question)
        type = try c.decode(Kind.self, forKey: .type)
        scaleMax = try c.decodeIfPresent(Int.self, forKey: .scaleMax)
        options = try c.decodeIfPresent([String].self, forKey: .options)
        when = try c.decodeIfPresent(When.self, forKey: .when) ?? .preSleep
        times = try c.decodeIfPresent([String].self, forKey: .times) ?? []
        everyNDays = try c.decodeIfPresent(Int.self, forKey: .everyNDays) ?? 1
    }

    /// "09:00" -> "9:00"; leaves already-trimmed strings alone. Display only.
    static func prettyTime(_ hhmm: String) -> String {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]) else { return hhmm }
        return "\(h):\(parts[1])"
    }

    /// Parse an "HH:mm" slot into (hour, minute); nil if malformed.
    static func parse(_ hhmm: String) -> (hour: Int, minute: Int)? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }
}

// MARK: - Self-report log entry (timestamped; multiple per day allowed)

struct SelfReportEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var itemId: String
    var timestamp: Date
    var slot: String?           // the HH:mm slot it answers, or nil for an ad-hoc log
    var value: Double
}

// MARK: - One experiment (multiple can run at once)

enum ExperimentStatus: String, Codable { case running, completed, dropped }

/// Cached analysis so we don't recompute the Bayesian model on every render.
struct AnalysisSummary: Codable, Equatable {
    var deltaMean: Double
    var ciLow: Double
    var ciHigh: Double
    var pDirection: Double
    var pROPE: Double
    var rHat: Double
    var evidence: String        // Evidence.rawValue
    var headline: String
    var confidence: String
}

struct Experiment: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var hypothesis: String
    var interventionLabel: String
    var controlLabel: String
    var outcomeLabel: String = "nightly recovery"
    var outcomeSignal: String = MetricKind.hrv.rawValue   // which sensor metric is the primary endpoint

    // design
    var pairs = 2
    var daysPerBlock = 3
    var washoutDays = 1
    var ropeHalfWidth = 2.0
    var hypothesizedPositive = false
    var baselineMean = 52.0
    var baselineSD = 3.0

    // self-report plan (agent-designed; may be empty)
    var selfReports: [SelfReportItem] = []

    // lifecycle / data
    var status: ExperimentStatus = .running
    var startedAt = Date()
    var lockedAt = Date()
    /// Pre-registration: once true, the analysis spec (design + priors + ROPE) is frozen.
    /// The spec hash is computed from the locked spec and must not change post-hoc.
    var isLocked = false
    var specHash = ""
    var days: [DayPlan] = []
    /// DERIVED daily aggregate (mean per item per day): date(yyyy-MM-dd) -> itemId -> value.
    /// Kept so the analysis pipeline keeps reading a single value per (day,item).
    var selfReportValues: [String: [String: Double]] = [:]
    /// Source of truth for self-logging: every timestamped log, possibly many per day/item.
    var selfReportLog: [SelfReportEntry] = []
    var analysis: AnalysisSummary?

    struct DayPlan: Codable, Identifiable, Equatable {
        var id: Int
        var kind: DayKind
        var value: Double?       // primary sensor endpoint for that day
        var adherent = true
    }

    // —— progress / scheduling ——
    var measurableDays: [DayPlan] { days.filter { $0.kind != .washout } }
    var recordedCount: Int { measurableDays.filter { $0.value != nil }.count }
    var scheduleComplete: Bool { !measurableDays.isEmpty && recordedCount == measurableDays.count }

    /// Index of today's day cell (first measurable cell without a value), if running.
    var todayIndex: Int? { days.firstIndex { $0.kind != .washout && $0.value == nil } }

    var todayKind: DayKind? { todayIndex.map { days[$0].kind } }

    /// What to do today for this experiment (one line).
    var todayInstruction: (title: String, detail: String)? {
        guard status == .running, let idx = todayIndex else { return nil }
        switch days[idx].kind {
        case .intervention: return (interventionLabel, "Do this today, then wear your watch tonight.")
        case .control:      return (controlLabel, "Today is a control day. Wear your watch tonight.")
        case .washout:      return ("Rest day", "Back to normal today — nothing to change.")
        }
    }

    // —— self-report scheduling ——

    /// Logs for one item on a given calendar day.
    func logs(for itemId: String, on day: Date) -> [SelfReportEntry] {
        let cal = Calendar.current
        return selfReportLog.filter { $0.itemId == itemId && cal.isDate($0.timestamp, inSameDayAs: day) }
    }

    /// Has a given slot been logged for this item today?
    func isSlotLogged(_ itemId: String, slot: String, on day: Date = Date()) -> Bool {
        logs(for: itemId, on: day).contains { $0.slot == slot }
    }

    /// Is `day` an eligible logging day for `item` given its cadence (counted from startedAt)?
    func isEligibleDay(_ item: SelfReportItem, on day: Date) -> Bool {
        let cal = Calendar.current
        let start = cal.startOfDay(for: startedAt)
        let d = cal.startOfDay(for: day)
        guard d >= start else { return false }
        let offset = cal.dateComponents([.day], from: start, to: d).day ?? 0
        return offset % item.cadenceDays == 0
    }

    /// Next due datetime for an item: the next un-logged slot today (if today is eligible),
    /// else the first slot on the next eligible day. nil only if the item has no parseable slots.
    func nextDue(for item: SelfReportItem, now: Date = Date()) -> Date? {
        let cal = Calendar.current
        let slots = item.slots
        guard !slots.isEmpty else { return nil }

        // Remaining un-logged slots today, if today is an eligible day.
        if isEligibleDay(item, on: now) {
            for slot in slots {
                guard let (h, m) = SelfReportItem.parse(slot) else { continue }
                guard let slotDate = cal.date(bySettingHour: h, minute: m, second: 0, of: now) else { continue }
                if isSlotLogged(item.id, slot: slot, on: now) { continue }
                // Due if the slot time hasn't passed, OR has passed but is still un-logged (overdue).
                return slotDate
            }
        }

        // Otherwise: first slot of the next eligible day.
        guard let (h, m) = SelfReportItem.parse(slots[0]) else { return nil }
        var probe = now
        for _ in 1...366 {
            guard let next = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: probe)) else { break }
            probe = next
            if isEligibleDay(item, on: probe) {
                return cal.date(bySettingHour: h, minute: m, second: 0, of: probe)
            }
        }
        return nil
    }

    /// Human "Next: …" string for an item, relative to `now`. nil if fully logged for today
    /// AND there is somehow no future slot (shouldn't happen for valid items).
    func nextDueLabel(for item: SelfReportItem, now: Date = Date()) -> String? {
        let cal = Calendar.current
        guard let due = nextDue(for: item, now: now) else { return nil }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let time = SelfReportItem.prettyTime(f.string(from: due))
        if cal.isDateInToday(due) {
            return "Next: today \(time)"
        } else if cal.isDateInTomorrow(due) {
            return "Next: tomorrow \(time)"
        } else {
            let d = DateFormatter(); d.dateFormat = "EEE"
            return "Next: \(d.string(from: due)) \(time)"
        }
    }

    /// True when every eligible slot for today has been logged for this item.
    func allLoggedToday(for item: SelfReportItem, now: Date = Date()) -> Bool {
        guard isEligibleDay(item, on: now), !item.slots.isEmpty else { return false }
        return item.slots.allSatisfy { isSlotLogged(item.id, slot: $0, on: now) }
    }

    /// Slots that are currently due (eligible day, time has arrived, not yet logged).
    func dueSlots(for item: SelfReportItem, now: Date = Date()) -> [String] {
        guard isEligibleDay(item, on: now) else { return [] }
        let cal = Calendar.current
        return item.slots.filter { slot in
            guard let (h, m) = SelfReportItem.parse(slot),
                  let slotDate = cal.date(bySettingHour: h, minute: m, second: 0, of: now) else { return false }
            return slotDate <= now && !isSlotLogged(item.id, slot: slot, on: now)
        }
    }
}

// MARK: - Store (hosts many experiments, persists, runs lifecycle)

@MainActor
final class ExperimentsStore: ObservableObject {
    @Published private(set) var experiments: [Experiment] = []
    @Published var analyzingID: UUID?
    private let key = "n1.experiments"

    init() { load() }

    var running: [Experiment] { experiments.filter { $0.status == .running } }
    func get(_ id: UUID) -> Experiment? { experiments.first { $0.id == id } }

    // Create a new experiment (from a finding suggestion, an unmeasured factor, or scratch).
    /// `baselineFrom`: the user's real DailyMetrics. If provided, the Bayesian priors
    /// (baselineMean/SD) and the ROPE are derived from the ~30 days BEFORE startedAt;
    /// otherwise sensible per-metric defaults are used. The spec is locked at creation.
    @discardableResult
    func create(title: String, hypothesis: String, intervention: String, control: String,
                outcomeLabel: String = "nightly recovery", outcomeSignal: MetricKind = .hrv,
                selfReports: [SelfReportItem] = [],
                baselineFrom days: [DailyMetric]? = nil) -> UUID {
        var e = Experiment(title: title, hypothesis: hypothesis,
                           interventionLabel: intervention, controlLabel: control,
                           outcomeLabel: outcomeLabel, outcomeSignal: outcomeSignal.rawValue,
                           selfReports: selfReports)
        e.days = Self.schedule(pairs: e.pairs, daysPerBlock: e.daysPerBlock, washout: e.washoutDays)

        // Bayesian priors from real history (≥7 days before startedAt), else per-metric defaults.
        let base = Self.baseline(metric: outcomeSignal, before: e.startedAt, from: days)
        e.baselineMean = base.mean
        e.baselineSD = base.sd
        // ROPE = fraction of baseline SD (practical-equivalence band scaled to the metric's units),
        // floored so it never collapses to zero on a very stable signal.
        e.ropeHalfWidth = max(0.4 * base.sd, Self.ropeFloor(for: outcomeSignal))

        // Pre-registration: freeze the spec and hash it.
        e.lockedAt = Date()
        e.isLocked = true
        e.specHash = Self.hash(e)
        experiments.insert(e, at: 0)
        save()
        // Schedule local reminders for each self-report item × time-slot.
        NotificationManager.shared.scheduleSelfReportReminders(experiment: e)
        return e.id
    }

    /// Compute baseline mean/SD of a metric over the ~30 days before `start`.
    /// Needs ≥7 usable days; otherwise falls back to per-metric defaults.
    static func baseline(metric: MetricKind, before start: Date,
                         from days: [DailyMetric]?) -> (mean: Double, sd: Double) {
        let cal = Calendar.current
        let windowStart = cal.date(byAdding: .day, value: -30, to: start) ?? start
        let values: [Double] = (days ?? []).compactMap { d in
            guard d.date < start, d.date >= windowStart else { return nil }
            return metric.value(of: d)
        }
        guard values.count >= 7 else { return defaultBaseline(for: metric) }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        let sd = variance.squareRoot()
        // Guard against a degenerate (near-constant) window producing a useless prior.
        guard sd.isFinite, sd > 0.5 else {
            return (mean.isFinite ? mean : defaultBaseline(for: metric).mean,
                    defaultBaseline(for: metric).sd)
        }
        return (mean, sd)
    }

    /// Sensible per-metric defaults when real history is insufficient.
    static func defaultBaseline(for metric: MetricKind) -> (mean: Double, sd: Double) {
        switch metric {
        case .hrv:       return (50, 15)
        case .restingHR: return (60, 6)
        case .sleep:     return (420, 45)
        case .steps:     return (8000, 3000)
        }
    }

    /// Smallest sensible ROPE half-width per metric (used as a floor on the SD-scaled band).
    static func ropeFloor(for metric: MetricKind) -> Double {
        switch metric {
        case .hrv:       return 2.0      // ms / recovery points
        case .restingHR: return 1.0      // bpm
        case .sleep:     return 10.0     // minutes
        case .steps:     return 250.0    // steps
        }
    }

    func drop(_ id: UUID) {
        if let e = get(id) { NotificationManager.shared.cancelSelfReportReminders(experiment: e) }
        mutate(id) { $0.status = .dropped }; save()
    }
    func remove(_ id: UUID) {
        if let e = get(id) { NotificationManager.shared.cancelSelfReportReminders(experiment: e) }
        experiments.removeAll { $0.id == id }; save()
    }

    /// Backwards-compatible: a "default slot" log (no explicit slot) for the given day.
    func recordSelfReport(_ id: UUID, itemId: String, value: Double, on date: Date = Date()) {
        logSelfReport(id, itemId: itemId, value: value, slot: nil, at: date)
    }

    /// Log a self-report value. Appends a timestamped entry AND refreshes the day's aggregate
    /// (mean of all of that item's logs on that calendar day) so the analysis pipeline still
    /// reads a single value per (day,item). The user may log ANY item at ANY time.
    func logSelfReport(_ id: UUID, itemId: String, value: Double, slot: String?, at date: Date = Date()) {
        mutate(id) { e in
            // If this slot was already logged today, replace it (lets the user correct a slot answer).
            if let slot {
                let cal = Calendar.current
                e.selfReportLog.removeAll {
                    $0.itemId == itemId && $0.slot == slot && cal.isDate($0.timestamp, inSameDayAs: date)
                }
            }
            e.selfReportLog.append(SelfReportEntry(itemId: itemId, timestamp: date, slot: slot, value: value))
            Self.refreshAggregate(&e, itemId: itemId, on: date)
        }
        save()
    }

    /// Recompute the daily aggregate (mean) for one item on one day from the log.
    private static func refreshAggregate(_ e: inout Experiment, itemId: String, on date: Date) {
        let key = dayKey(date)
        let cal = Calendar.current
        let vals = e.selfReportLog
            .filter { $0.itemId == itemId && cal.isDate($0.timestamp, inSameDayAs: date) }
            .map { $0.value }
        if vals.isEmpty {
            e.selfReportValues[key]?[itemId] = nil
            if e.selfReportValues[key]?.isEmpty == true { e.selfReportValues[key] = nil }
        } else {
            e.selfReportValues[key, default: [:]][itemId] = vals.reduce(0, +) / Double(vals.count)
        }
    }

    /// Ingest REAL sensor data into every running experiment's schedule.
    ///
    /// Each DayPlan occupies one real calendar day starting at `startedAt` (washout days
    /// consume a calendar day too). For each measurable day whose date has already passed
    /// and for which we have a DailyMetric carrying the experiment's `outcomeSignal`, we set
    /// DayPlan.value. Future days, and days with missing data, stay nil.
    ///
    /// Idempotent: re-running with the same/extended data just refreshes the same cells.
    /// Call this on every data refresh (after SnapshotStore loads `days`).
    func ingestRealData(days: [DailyMetric]) {
        guard !days.isEmpty else { return }
        let cal = Calendar.current
        // Index real metrics by day-key for O(1) lookup.
        var byDay: [String: DailyMetric] = [:]
        for d in days { byDay[Self.dayKey(d.date)] = d }
        let today = cal.startOfDay(for: Date())

        var changed = false
        for i in experiments.indices where experiments[i].status == .running {
            let metric = MetricKind(rawValue: experiments[i].outcomeSignal) ?? .hrv
            let start = cal.startOfDay(for: experiments[i].startedAt)
            var local = experiments[i]
            for j in local.days.indices {
                guard local.days[j].kind != .washout else { continue }
                // The day index in `days` is the cumulative calendar offset; DayPlan.id is that offset.
                let offset = local.days[j].id
                guard let date = cal.date(byAdding: .day, value: offset, to: start) else { continue }
                let day = cal.startOfDay(for: date)
                guard day <= today else { continue }   // don't fabricate future days
                let key = Self.dayKey(day)
                guard let metricDay = byDay[key], let v = metric.value(of: metricDay) else { continue }
                if local.days[j].value != v {
                    local.days[j].value = v
                    changed = true
                }
            }
            // Auto-complete a fully-recorded running experiment.
            if local.scheduleComplete && local.status == .running {
                local.status = .completed
                NotificationManager.shared.cancelSelfReportReminders(experiment: local)
                changed = true
            }
            experiments[i] = local
        }
        if changed { save() }
    }

    /// Demo: fill the schedule with simulated sensor + self-report values so the loop is testable.
    func fillDemo(_ id: UUID) {
        mutate(id) { e in
            var rng = SplitMix64(seed: 99)
            for i in e.days.indices where e.days[i].kind != .washout {
                let isIntervention = e.days[i].kind == .intervention
                let mean = e.baselineMean + (isIntervention ? -5.0 : 0)
                e.days[i].value = mean + gaussianN1(sd: e.baselineSD, &rng)
            }
            // Seed today's self-report log across the item's slots so the schedule UI is testable.
            let now = Date()
            for item in e.selfReports {
                for slot in item.slots {
                    let v: Double = item.type == .yesNo ? (gaussianN1(sd: 1, &rng) > 0 ? 1 : 0)
                        : Double(min(item.scaleMax ?? 5, max(1, Int(3 + gaussianN1(sd: 1, &rng)))))
                    e.selfReportLog.append(SelfReportEntry(itemId: item.id, timestamp: now, slot: slot, value: v))
                }
                Self.refreshAggregate(&e, itemId: item.id, on: now)
            }
        }
        save()
    }

    /// Run the Bayesian analysis (numbers from N1Stats only) and cache the summary.
    func analyze(_ id: UUID) {
        guard let e = get(id) else { return }
        let blocks = Self.blocks(from: e)
        guard blocks.count >= 2 else { return }
        analyzingID = id
        Task.detached(priority: .userInitiated) {
            let priors = Priors(baselineMean: e.baselineMean, baselineSD: e.baselineSD)
            let post = BlockModel.fit(blocks: blocks, priors: priors)
            var verdict = Evidence.decide(post, hypothesizedPositive: e.hypothesizedPositive,
                                          ropeHalfWidth: e.ropeHalfWidth)
            // Minimum-data gate: never surface a non-insufficient verdict on near-empty data.
            // Mirror the rigor of the snapshot engine — require a real minimum per arm:
            // each condition needs ≥3 recorded days AND there must be ≥2 blocks total.
            if !Self.meetsMinimumData(blocks) { verdict = .insufficient }
            let summary = Self.summarize(post, verdict: verdict, e: e)
            await MainActor.run {
                self.mutate(id) { $0.analysis = summary
                    if $0.scheduleComplete { $0.status = .completed } }
                if let done = self.get(id), done.status == .completed {
                    NotificationManager.shared.cancelSelfReportReminders(experiment: done)
                }
                self.analyzingID = nil
                self.save()
            }
        }
    }

    // —— today across all running experiments ——
    struct TodayTask: Identifiable { let id: UUID; let experiment: Experiment
        let instruction: (title: String, detail: String)
        /// Items with at least one currently-due slot today.
        let dueReports: [SelfReportItem]
        /// Items eligible today but not yet due (so the UI can hint "next at HH:mm").
        let upcomingReports: [SelfReportItem] }

    var todayTasks: [TodayTask] {
        let now = Date()
        return running.compactMap { e in
            guard let ins = e.todayInstruction else { return nil }
            let due = e.selfReports.filter { !e.dueSlots(for: $0, now: now).isEmpty }
            let upcoming = e.selfReports.filter {
                e.isEligibleDay($0, on: now) && e.dueSlots(for: $0, now: now).isEmpty
                    && !e.allLoggedToday(for: $0, now: now)
            }
            return TodayTask(id: e.id, experiment: e, instruction: ins,
                             dueReports: due, upcomingReports: upcoming)
        }
    }

    // —— helpers ——
    private func mutate(_ id: UUID, _ change: (inout Experiment) -> Void) {
        guard let i = experiments.firstIndex(where: { $0.id == id }) else { return }
        var e = experiments[i]; change(&e); experiments[i] = e
    }

    static func dayKey(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }

    /// ABAB block schedule: random A/B order within each pair, washout between blocks.
    static func schedule(pairs: Int, daysPerBlock: Int, washout: Int) -> [Experiment.DayPlan] {
        var rng = SplitMix64(seed: 20260616)
        var out: [Experiment.DayPlan] = []; var idx = 0
        for pair in 0..<pairs {
            let treatFirst = Double.random(in: 0..<1, using: &rng) < 0.5
            for slot in 0..<2 {
                let kind: DayKind = ((slot == 0) == treatFirst) ? .intervention : .control
                for _ in 0..<daysPerBlock { out.append(.init(id: idx, kind: kind)); idx += 1 }
                let last = pair == pairs - 1 && slot == 1
                if !last { for _ in 0..<washout { out.append(.init(id: idx, kind: .washout)); idx += 1 } }
            }
        }
        return out
    }

    static func blocks(from e: Experiment) -> [BlockData] {
        var out: [BlockData] = []; var cur: [Double] = []; var curKind: DayKind?
        func flush() {
            if let k = curKind, k != .washout, !cur.isEmpty {
                out.append(BlockData(condition: k == .intervention ? .intervention : .control, values: cur))
            }
            cur = []
        }
        for d in e.days {
            if d.kind == .washout { flush(); curKind = nil; continue }
            if d.kind != curKind { flush(); curKind = d.kind }
            if let v = d.value, d.adherent { cur.append(v) }
        }
        flush()
        return out.filter { !$0.values.isEmpty }
    }

    /// Minimum-data gate: require a real amount of data before any confident verdict.
    /// Each condition (intervention/control) must have ≥3 recorded days AND there must be
    /// ≥2 blocks total. Below this, the analysis is forced to `.insufficient`.
    nonisolated static func meetsMinimumData(_ blocks: [BlockData]) -> Bool {
        guard blocks.count >= 2 else { return false }
        let interventionDays = blocks.filter { $0.condition == .intervention }
            .reduce(0) { $0 + $1.values.count }
        let controlDays = blocks.filter { $0.condition == .control }
            .reduce(0) { $0 + $1.values.count }
        return interventionDays >= 3 && controlDays >= 3
    }

    nonisolated static func summarize(_ post: PosteriorResult, verdict: Evidence, e: Experiment) -> AnalysisSummary {
        let ci = post.credibleInterval90
        let p = post.probDirection(positive: e.hypothesizedPositive)
        // Direction word comes from the SIGN of the observed effect, not the hypothesis.
        let diff = abs(post.mean)
        let dir = post.mean < 0 ? "lower" : "higher"
        let headline: String
        switch verdict {
        case .strong, .preliminary:
            // Sub-unit effects read as "less than 1 <unit>" rather than rounding to "about 0".
            let unit = MetricKind(rawValue: e.outcomeSignal)?.unit ?? ""
            // "points" is the natural unit for the unitless recovery score.
            let plural = unit.isEmpty ? "points" : unit
            let magnitude = diff < 1
                ? "less than 1 \(unit.isEmpty ? "point" : unit) \(dir)"
                : String(format: "about %.1f %@ %@", diff, plural, dir)
            headline = "On \(e.interventionLabel.lowercased()) days, your \(e.outcomeLabel) was \(magnitude)."
        case .negligible: headline = "\(e.interventionLabel) made almost no difference to your \(e.outcomeLabel)."
        case .insufficient: headline = "Not enough days yet to call it — keep logging and check back."
        }
        let confidence: String
        switch verdict {
        case .strong: confidence = "The two kinds of days separate clearly — this is unlikely to be chance."
        case .preliminary: confidence = "It leans this way, but isn't rock-solid yet; one more round would confirm."
        case .negligible: confidence = "The two kinds of days overlap — any effect is small enough to ignore."
        case .insufficient: confidence = "The data can't separate them yet. Not knowing is an honest answer too."
        }
        return AnalysisSummary(deltaMean: post.mean, ciLow: ci.lowerBound, ciHigh: ci.upperBound,
                               pDirection: p, pROPE: post.probInROPE(halfWidth: e.ropeHalfWidth),
                               rHat: post.rHat, evidence: verdict.rawValue,
                               headline: headline, confidence: confidence)
    }

    /// Hash of the LOCKED analysis spec: design + priors + ROPE + endpoint. Any of these
    /// changing would change the registered analysis, so they're all folded in.
    static func hash(_ e: Experiment) -> String {
        let s = [
            e.hypothesis, e.interventionLabel, e.controlLabel, e.outcomeSignal,
            "\(e.pairs)", "\(e.daysPerBlock)", "\(e.washoutDays)",
            String(format: "%.4f", e.ropeHalfWidth),
            String(format: "%.4f", e.baselineMean),
            String(format: "%.4f", e.baselineSD),
            "\(e.hypothesizedPositive)"
        ].joined(separator: "|")
        return SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func load() {
        guard let d = UserDefaults.standard.data(forKey: key),
              let e = try? JSONDecoder().decode([Experiment].self, from: d) else { return }
        experiments = e
    }
    private func save() {
        if let d = try? JSONEncoder().encode(experiments) { UserDefaults.standard.set(d, forKey: key) }
    }
}

/// Box–Muller for demo data (kept local; inference randomness lives in N1Stats).
private func gaussianN1(sd: Double, _ rng: inout SplitMix64) -> Double {
    let u1 = Double.random(in: Double.leastNonzeroMagnitude..<1, using: &rng)
    let u2 = Double.random(in: 0..<1, using: &rng)
    return sd * (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * .pi * u2)
}
