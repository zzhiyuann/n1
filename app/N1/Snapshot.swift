import Foundation

/// Grouping rule: split historical days into two groups, A/B (exposed vs. not exposed).
enum GroupingRule: String, CaseIterable, Codable {
    case lateNight, exerciseDay, weekend, highSteps

    var labelA: String {
        switch self {
        case .lateNight: "Late nights (after 00:30)"
        case .exerciseDay: "Workout days"
        case .weekend: "Weekends"
        case .highSteps: "High-step days"
        }
    }
    var labelB: String {
        switch self {
        case .lateNight: "Early nights"
        case .exerciseDay: "Rest days"
        case .weekend: "Weekdays"
        case .highSteps: "Low-step days"
        }
    }

    /// Does this day belong to group A? nil = not enough data, excluded from the comparison.
    func isGroupA(_ day: DailyMetric, median: Double?) -> Bool? {
        switch self {
        case .lateNight:
            guard let b = day.bedtimeHour else { return nil }
            return b >= 24.5
        case .exerciseDay:
            return (day.exerciseMinutes ?? 0) > 10
        case .weekend:
            return day.isWeekend
        case .highSteps:
            guard let s = day.steps, let m = median else { return nil }
            return s > m
        }
    }
}

/// Three-tier evidence vocabulary (enforced across the whole app, see product memo §6).
enum EvidenceTier: String, Codable {
    case snapshot   // Snapshot: what your history says (correlation)
    case tested     // Tested: a preliminary mini-experiment
    case confirmed  // Confirmed: a pre-registered experiment

    var badge: String {
        switch self {
        case .snapshot: "Snapshot"
        case .tested: "Tested"
        case .confirmed: "Confirmed"
        }
    }
}

/// A single "finding" — the display unit on the Archive screen.
struct Finding: Identifiable, Codable {
    let id: UUID
    let question: String
    let tier: EvidenceTier
    let headline: String
    let caveat: String
    let confounders: [String]
    let createdAt: Date
    /// Only present on the preset-engine path; nil for findings the agent analyzed on its own
    var metric: MetricKind?
    var grouping: GroupingRule?
}

/// Snapshot comparison result (entirely produced by deterministic code).
struct SnapshotResult {
    let metric: MetricKind
    let grouping: GroupingRule
    let nA: Int, nB: Int
    let meanA: Double, meanB: Double
    /// Welch 95% interval (meanA − meanB)
    let diff: Double
    let diffCI: ClosedRange<Double>
    let confounders: [String]
    let pointsA: [Double], pointsB: [Double]

    /// Is the difference "clear" (interval excludes 0, and each group has ≥10 days)?
    var isClear: Bool { nA >= 10 && nB >= 10 && !diffCI.contains(0) }
}

/// Retrospective snapshot engine: group → mean difference → Welch interval → confounder flags. Honesty is hard-coded.
enum SnapshotEngine {

    static func compare(
        days: [DailyMetric], metric: MetricKind, grouping: GroupingRule
    ) -> SnapshotResult? {
        let stepsMedian = median(days.compactMap(\.steps))
        var a: [Double] = [], b: [Double] = []
        var aDays: [DailyMetric] = [], bDays: [DailyMetric] = []
        for day in days {
            guard let v = metric.value(of: day),
                  let inA = grouping.isGroupA(day, median: stepsMedian) else { continue }
            if inA { a.append(v); aDays.append(day) } else { b.append(v); bDays.append(day) }
        }
        guard a.count >= 5, b.count >= 5 else { return nil }

        let mA = mean(a), mB = mean(b)
        let vA = variance(a, mA), vB = variance(b, mB)
        let se = sqrt(vA / Double(a.count) + vB / Double(b.count))
        let d = mA - mB

        return SnapshotResult(
            metric: metric, grouping: grouping,
            nA: a.count, nB: b.count, meanA: mA, meanB: mB,
            diff: d, diffCI: (d - 1.96 * se)...(d + 1.96 * se),
            confounders: confounders(grouping: grouping, aDays: aDays, bDays: bDays),
            pointsA: a, pointsB: b
        )
    }

    /// Plain-language wording for a snapshot answer (the snapshot layer bans "causes/proves" — a vocabulary red line).
    static func wording(_ r: SnapshotResult, question: String) -> Finding {
        let unit = r.metric.unit.isEmpty ? "points" : r.metric.unit
        let diffAbs = abs(r.diff)
        let moreOrLess = r.diff > 0 ? "higher" : "lower"
        let headline: String
        if r.isClear {
            headline = String(format: "On %@ (%d days), your %@ was on average %.0f %@ %@.",
                              r.grouping.labelA, r.nA, r.metric.label, diffAbs, unit, moreOrLess)
        } else if r.nA < 10 || r.nB < 10 {
            headline = "There are too few of these days in your history to tell yet."
        } else {
            headline = "Between \(r.grouping.labelA) and \(r.grouping.labelB), your \(r.metric.label) is about the same."
        }
        return Finding(
            id: UUID(), question: question, tier: .snapshot,
            headline: headline,
            caveat: "This is a correlation from your last \(r.nA + r.nB) days — not yet a cause.",
            confounders: r.confounders, createdAt: Date(),
            metric: r.metric, grouping: r.grouping
        )
    }

    /// Confounder flags: whether group A also differs in some other obvious way (honest, and a hook for upgrading to an experiment).
    private static func confounders(
        grouping: GroupingRule, aDays: [DailyMetric], bDays: [DailyMetric]
    ) -> [String] {
        var list: [String] = []
        let weekendA = ratio(aDays) { $0.isWeekend }
        let weekendB = ratio(bDays) { $0.isWeekend }
        if grouping != .weekend, abs(weekendA - weekendB) > 0.2 {
            list.append("Weekends (the two groups have very different shares of weekend days)")
        }
        let exA = ratio(aDays) { ($0.exerciseMinutes ?? 0) > 10 }
        let exB = ratio(bDays) { ($0.exerciseMinutes ?? 0) > 10 }
        if grouping != .exerciseDay, abs(exA - exB) > 0.2 {
            list.append("Exercise (the two groups work out at different rates)")
        }
        list.append("Things nobody logged (alcohol, stress, travel, ...)")
        return list
    }

    private static func mean(_ xs: [Double]) -> Double { xs.reduce(0, +) / Double(xs.count) }
    private static func variance(_ xs: [Double], _ m: Double) -> Double {
        xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(max(xs.count - 1, 1))
    }
    private static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s[s.count / 2]
    }
    private static func ratio(_ days: [DailyMetric], _ pred: (DailyMetric) -> Bool) -> Double {
        days.isEmpty ? 0 : Double(days.filter(pred).count) / Double(days.count)
    }
}

// MARK: - Question translator (v1 rule-based; to be replaced once the LLM version implements the same protocol)

enum ParsedQuestion {
    case query(metric: MetricKind, grouping: GroupingRule)
    /// HealthKit can't see this exposure (coffee/alcohol/diet, ...) → guide the user toward a mini-experiment
    case needsExperiment(exposure: String)
    case unknown
}

protocol QuestionTranslating {
    func parse(_ text: String) -> ParsedQuestion
}

/// Rule-based translator: keywords → metric/grouping. On failure it returns unknown and the UI falls back to a guided picker.
struct RuleBasedTranslator: QuestionTranslating {
    func parse(_ text: String) -> ParsedQuestion {
        let t = text.lowercased()

        // The exposure doesn't exist in HealthKit → tell the user honestly + offer an experiment hook
        for (kw, name) in [("coffee", "coffee"), ("alcohol", "alcohol"), ("melatonin", "melatonin"),
                           ("late-night snack", "late-night snacks"), ("boba", "caffeinated drinks")] {
            if t.contains(kw) { return .needsExperiment(exposure: name) }
        }

        var grouping: GroupingRule?
        if ["late night", "stay up", "scrolling", "sleep late", "up late"].contains(where: t.contains) {
            grouping = .lateNight
        } else if ["exercise", "workout", "gym", "running"].contains(where: t.contains) {
            grouping = .exerciseDay
        } else if t.contains("weekend") {
            grouping = .weekend
        } else if ["walk", "steps", "walk more"].contains(where: t.contains) {
            grouping = .highSteps
        }

        var metric: MetricKind?
        if ["sleep", "slept", "how long i sleep", "insomnia"].contains(where: t.contains) { metric = .sleep }
        else if ["recovery", "hrv", "energy", "how i feel"].contains(where: t.contains) { metric = .hrv }
        else if ["heart rate", "heartbeat"].contains(where: t.contains) { metric = .restingHR }
        else if ["step", "activity"].contains(where: t.contains) { metric = .steps }

        // Sensible default: asked about an exposure but not an outcome → default to recovery.
        // "late nights × sleep" is allowed: that late nights are short nights is itself a valid answer.
        if let g = grouping {
            return .query(metric: metric ?? .hrv, grouping: g)
        }
        return .unknown
    }
}
