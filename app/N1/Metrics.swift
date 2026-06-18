import Foundation
import HealthKit

/// One day of body data (all optional — real data always has gaps).
struct DailyMetric: Identifiable {
    let date: Date
    var sleepMinutes: Double?
    /// Bedtime in hours (24.5 = 00:30 after midnight)
    var bedtimeHour: Double?
    var hrv: Double?
    var restingHR: Double?
    var steps: Double?
    var exerciseMinutes: Double?
    // Richer signals (all optional)
    var respiratoryRate: Double?     // breaths/min, averaged over the night's main sleep window (see sleepByNight)
    var bloodOxygen: Double?         // SpO2 %, averaged over the night's main sleep window (see sleepByNight)
    var activeEnergy: Double?        // kcal, daily sum
    var distanceKm: Double?          // walking+running km, daily sum
    var flightsClimbed: Double?      // daily sum
    var walkingHR: Double?           // walking heart-rate avg, bpm
    /// Hourly step counts across the 24 hours of the day (raw input for behavioral-rhythm inference)
    var hourlySteps: [Double]?

    var id: Date { date }
    var isWeekend: Bool {
        let wd = Calendar.current.component(.weekday, from: date)
        return wd == 1 || wd == 7
    }
}

/// A metric you can ask about (the outcome variable).
enum MetricKind: String, CaseIterable, Codable {
    case sleep, hrv, restingHR, steps

    var label: String {
        switch self {
        case .sleep: "Sleep duration"
        case .hrv: "Nightly recovery"
        case .restingHR: "Resting heart rate"
        case .steps: "Activity"
        }
    }
    var unit: String {
        switch self {
        case .sleep: "minutes"
        case .hrv: "" // recovery is shown in "points"
        case .restingHR: "bpm"
        case .steps: "steps"
        }
    }
    /// Is higher better? (Heart rate is the opposite.)
    var higherIsBetter: Bool { self != .restingHR }

    func value(of day: DailyMetric) -> Double? {
        switch self {
        case .sleep: day.sleepMinutes
        case .hrv: day.hrv
        case .restingHR: day.restingHR
        case .steps: day.steps
        }
    }
}

// MARK: - Data sources

protocol DataSource {
    func fetchDailyMetrics(daysBack: Int) async -> [DailyMetric]
}

/// Demo data source: 180 days with three built-in real patterns, so snapshot answers have something to say.
/// Patterns: (1) late nights (>00:30) drop recovery by −6 and sleep by −45min; (2) exercise days raise next-day recovery by +3; (3) later bedtimes on weekends.
struct DemoSource: DataSource {
    func fetchDailyMetrics(daysBack: Int = 180) async -> [DailyMetric] {
        var rng = SplitMix64Local(seed: 88)
        var result: [DailyMetric] = []
        let cal = Calendar.current
        var exercisedYesterday = false
        for offset in stride(from: daysBack, through: 1, by: -1) {
            let date = cal.startOfDay(for: cal.date(byAdding: .day, value: -offset, to: Date())!)
            let wd = cal.component(.weekday, from: date)
            let weekend = wd == 1 || wd == 7
            // Pattern (4): about 1/3 of weekdays involve overtime (still in a working rhythm in the evening), with a later bedtime and worse recovery that night
            let isOvertime = !weekend && rng.uniform() < 0.35
            let lateProb = weekend ? 0.65 : (isOvertime ? 0.7 : 0.18)
            let isLate = rng.uniform() < lateProb
            let bedtime = isLate ? 24.6 + rng.normal(sd: 0.7).magnitude : 23.0 + rng.normal(sd: 0.5)
            let exercise = (!isOvertime && rng.uniform() < 0.35) ? 25 + rng.normal(sd: 10).magnitude : 0
            let hrv = 52 - (isLate ? 6.0 : 0) - (isOvertime ? 3.0 : 0)
                + (exercisedYesterday ? 3.0 : 0) + rng.normal(sd: 4)
            let sleep = 430 - (isLate ? 45.0 : 0) - (isOvertime ? 20.0 : 0) + rng.normal(sd: 35)
            let rhr = 58 + (isLate ? 2.0 : 0) + (isOvertime ? 1.0 : 0) + rng.normal(sd: 2.5)

            // Hourly steps: commute spikes + sitting at the desk + evening; on overtime days the sitting stretches to 8-9pm
            var hourly = [Double](repeating: 0, count: 24)
            for h in 0..<24 {
                if weekend {
                    hourly[h] = h >= 9 && h <= 21 ? max(0, 300 + rng.normal(sd: 220)) : 10
                } else {
                    switch h {
                    case 8: hourly[h] = 700 + rng.normal(sd: 150).magnitude          // commute in
                    case 9...16: hourly[h] = max(10, 70 + rng.normal(sd: 40))        // at the desk
                    case 17...20:
                        if isOvertime && h <= 20 { hourly[h] = max(10, 60 + rng.normal(sd: 35)) } // still at the desk
                        else if h == 17 { hourly[h] = 750 + rng.normal(sd: 150).magnitude }       // commute home on time
                        else { hourly[h] = max(0, 250 + rng.normal(sd: 150)) }                    // evening life
                    case 21: hourly[h] = isOvertime ? 700 + rng.normal(sd: 120).magnitude
                                                    : max(0, 150 + rng.normal(sd: 100))
                    case 7, 22: hourly[h] = max(0, 120 + rng.normal(sd: 80))
                    default: hourly[h] = 5
                    }
                }
            }
            if exercise > 5 { hourly[weekend ? 10 : 19] += 2500 }

            result.append(DailyMetric(
                date: date,
                sleepMinutes: max(sleep, 240),
                bedtimeHour: bedtime,
                hrv: max(hrv, 20),
                restingHR: max(rhr, 45),
                steps: max(hourly.reduce(0, +), 800),
                exerciseMinutes: exercise > 5 ? exercise : nil,
                hourlySteps: hourly
            ))
            exercisedYesterday = exercise > 5
        }
        return result
    }
}

/// Result of requesting HealthKit authorization — surfaced honestly to the UI and the diagnostic file.
struct HealthAuthResult {
    let available: Bool
    let requested: Bool
    let error: String?
}

/// Real HealthKit data source (used on a real, authorized device; the app automatically falls back to DemoSource only when HealthKit is unavailable, i.e. the simulator).
final class HealthKitSource: DataSource {
    private let store = HKHealthStore()

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// The set of types we want to read. Built defensively so one bad type can't nuke the whole request.
    private static var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        // Category types
        types.insert(HKCategoryType(.sleepAnalysis))
        types.insert(HKCategoryType(.mindfulSession))
        // Quantity types
        let quantityIDs: [HKQuantityTypeIdentifier] = [
            .heartRateVariabilitySDNN,
            .restingHeartRate,
            .heartRate,
            .walkingHeartRateAverage,
            .respiratoryRate,
            .oxygenSaturation,
            .stepCount,
            .appleExerciseTime,
            .activeEnergyBurned,
            .basalEnergyBurned,
            .distanceWalkingRunning,
            .flightsClimbed,
            .vo2Max,
            .appleStandTime,
        ]
        for id in quantityIDs { types.insert(HKQuantityType(id)) }
        types.insert(HKObjectType.workoutType())
        if #available(iOS 16.0, *) { types.insert(HKQuantityType(.timeInDaylight)) }
        return types
    }

    /// Request authorization without swallowing errors. Returns a struct describing what happened
    /// so the UI can show an honest outcome and the diagnostic file can record the localized error.
    @discardableResult
    func requestAuthorizationResult() async -> HealthAuthResult {
        guard Self.isAvailable else {
            return HealthAuthResult(available: false, requested: false, error: nil)
        }
        do {
            try await store.requestAuthorization(toShare: [], read: Self.readTypes)
            return HealthAuthResult(available: true, requested: true, error: nil)
        } catch {
            return HealthAuthResult(available: true, requested: false,
                                    error: error.localizedDescription)
        }
    }

    /// Back-compat Bool wrapper.
    func requestAuthorization() async -> Bool {
        await requestAuthorizationResult().requested
    }

    func fetchDailyMetrics(daysBack: Int = 180) async -> [DailyMetric] {
        guard Self.isAvailable else { return [] }
        let cal = Calendar.current
        let end = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -daysBack, to: end)!

        // Sleep is fetched first because the night's main-sleep window is the foundation for the
        // overnight-only signals (respiratory rate, SpO2). We widen the sleep query window by one day
        // on the leading edge so a night that begins before `start` still contributes its main block
        // for the first in-range wake date.
        let sleepStart = cal.date(byAdding: .day, value: -1, to: start) ?? start
        let sleepMap = await sleepByNight(sleepStart, end)

        async let hrv = dailyStat(.heartRateVariabilitySDNN, .discreteAverage, start, end,
                                  unit: HKUnit.secondUnit(with: .milli))
        async let rhr = dailyStat(.restingHeartRate, .discreteAverage, start, end,
                                  unit: HKUnit.count().unitDivided(by: .minute()))
        async let steps = dailyStat(.stepCount, .cumulativeSum, start, end, unit: .count())
        async let exercise = dailyStat(.appleExerciseTime, .cumulativeSum, start, end, unit: .minute())
        async let active = dailyStat(.activeEnergyBurned, .cumulativeSum, start, end, unit: .kilocalorie())
        async let dist = dailyStat(.distanceWalkingRunning, .cumulativeSum, start, end,
                                   unit: .meterUnit(with: .kilo))
        async let flights = dailyStat(.flightsClimbed, .cumulativeSum, start, end, unit: .count())
        async let walkHR = dailyStat(.walkingHeartRateAverage, .discreteAverage, start, end,
                                     unit: .count().unitDivided(by: .minute()))
        async let hourly = hourlyStepsByDay(start, end)   // real per-hour aggregation, computed on device

        // Respiratory rate and SpO2 are only physiologically meaningful while asleep, so they are
        // restricted to each night's main sleep window (keyed by wake date) rather than averaged
        // across the whole calendar day. Falls back to the 00:00–09:00 local window on nights with
        // no detected main sleep block.
        let sleepWindows: [Date: (start: Date, end: Date)] =
            sleepMap.mapValues { (start: $0.windowStart, end: $0.windowEnd) }
        async let resp = overnightStat(.respiratoryRate,
                                        unit: .count().unitDivided(by: .minute()),
                                        windows: sleepWindows, start: start, end: end)
        async let spo2 = overnightStat(.oxygenSaturation, unit: .percent(),
                                        windows: sleepWindows, start: start, end: end)

        let (hrvMap, rhrMap, stepMap, exMap) = await (hrv, rhr, steps, exercise)
        let (activeMap, distMap, flightsMap, walkHRMap) = await (active, dist, flights, walkHR)
        let (respMap, spo2Map, hourlyMap) = await (resp, spo2, hourly)

        var result: [DailyMetric] = []
        var cursor = start
        while cursor < end {
            let s = sleepMap[cursor]
            result.append(DailyMetric(
                date: cursor,
                sleepMinutes: s?.minutes,
                bedtimeHour: s?.bedtimeHour,
                hrv: clamp(hrvMap[cursor], 5, 250),
                restingHR: clamp(rhrMap[cursor], 30, 120),
                steps: stepMap[cursor],
                exerciseMinutes: exMap[cursor],
                respiratoryRate: clamp(respMap[cursor], 5, 40),
                bloodOxygen: clamp(spo2Map[cursor].map { $0 * 100 }, 70, 100),
                activeEnergy: activeMap[cursor],
                distanceKm: distMap[cursor],
                flightsClimbed: flightsMap[cursor],
                walkingHR: clamp(walkHRMap[cursor], 30, 200),
                hourlySteps: hourlyMap[cursor]
            ))
            cursor = cal.date(byAdding: .day, value: 1, to: cursor)!
        }
        return result
    }

    /// Drop values that fall outside a physiologically plausible range. Out-of-range or missing → nil,
    /// so downstream statistics never ingest sensor garbage. (We reject rather than clamp: a value of
    /// 300ms HRV or 4% SpO2 is a sensor artifact, not a saturated-but-real reading.)
    private func clamp(_ value: Double?, _ lo: Double, _ hi: Double) -> Double? {
        guard let v = value, v.isFinite, v >= lo, v <= hi else { return nil }
        return v
    }

    /// Real per-hour step aggregation, bucketed into a 24-slot array per day.
    /// (Demo data fabricated this; on a real device we must actually compute it from samples.)
    ///
    /// Real-data contract: the collection query emits an empty `HKStatistics` for every hour in the
    /// range, even hours with no samples — but `sumQuantity()` is nil for those, so an empty hour stays
    /// at zero (correct: zero steps were taken). A day appears in the map only if it has at least one
    /// hour carrying a step sample, and when present it is ALWAYS a full 24-slot array (empty hours = 0).
    /// Days with literally no step data are absent → caller sees `nil`, which is the honest signal.
    private func hourlyStepsByDay(_ start: Date, _ end: Date) async -> [Date: [Double]] {
        await withCheckedContinuation { cont in
            let q = HKStatisticsCollectionQuery(
                quantityType: HKQuantityType(.stepCount),
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end),
                options: .cumulativeSum,
                anchorDate: Calendar.current.startOfDay(for: start),
                intervalComponents: DateComponents(hour: 1))
            q.initialResultsHandler = { _, collection, _ in
                var map: [Date: [Double]] = [:]
                let cal = Calendar.current
                collection?.enumerateStatistics(from: start, to: end) { stat, _ in
                    // Bucket by the LOCAL hour of the interval start. DST transitions can make a civil
                    // day have 23 or 25 hours; we only ever index 0..<24 and tolerate the rare missing
                    // or duplicated hour rather than crashing.
                    let day = cal.startOfDay(for: stat.startDate)
                    let hour = cal.component(.hour, from: stat.startDate)
                    guard hour >= 0, hour < 24 else { return }
                    // Only materialize a day's array once it actually carries a step sample, so a day
                    // with no data stays absent (→ nil) instead of becoming a misleading all-zero row.
                    guard let s = stat.sumQuantity() else { return }
                    var arr = map[day] ?? [Double](repeating: 0, count: 24)
                    arr[hour] = s.doubleValue(for: .count())
                    map[day] = arr
                }
                cont.resume(returning: map)
            }
            store.execute(q)
        }
    }

    /// Average a discrete quantity (e.g. respiratory rate, SpO2) over each night's main sleep window,
    /// keyed by the wake date. For nights with no detected main sleep block we fall back to the
    /// 00:00–09:00 local window of that calendar day, which captures the bulk of typical overnight
    /// sleep without depending on the sleep-stage data being present.
    ///
    /// Returns a per-wake-date average. The query is run once over the whole range and partitioned in
    /// memory, so it is O(samples) rather than one query per night.
    private func overnightStat(
        _ id: HKQuantityTypeIdentifier, unit: HKUnit,
        windows: [Date: (start: Date, end: Date)],
        start: Date, end: Date
    ) async -> [Date: Double] {
        let cal = Calendar.current
        // The effective sample window: from the earliest sleep-window start (which may precede `start`)
        // to `end`. Guard against empty input.
        let earliest = windows.values.map(\.start).min() ?? start
        let queryStart = min(earliest, start)
        return await withCheckedContinuation { cont in
            let pred = HKQuery.predicateForSamples(withStart: queryStart, end: end)
            let query = HKSampleQuery(sampleType: HKQuantityType(id), predicate: pred,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                // Per wake-date running mean.
                var sum: [Date: Double] = [:]
                var count: [Date: Int] = [:]

                // Pre-resolve each wake date's window; build the 00:00–09:00 fallback lazily per day.
                func window(for wake: Date) -> (start: Date, end: Date)? {
                    if let w = windows[wake] { return w }
                    let dayStart = cal.startOfDay(for: wake)
                    guard let nine = cal.date(byAdding: .hour, value: 9, to: dayStart) else { return nil }
                    return (dayStart, nine)
                }

                for case let s as HKQuantitySample in samples ?? [] {
                    let v = s.quantity.doubleValue(for: unit)
                    guard v.isFinite else { continue }
                    // A sample's midpoint decides which night it belongs to. Try the wake date implied by
                    // the sample timestamp, plus the neighbours, and accept it into whichever night's
                    // main window actually contains the sample. This handles samples that fall just
                    // before or after midnight without a fragile hour-of-day heuristic.
                    let mid = s.startDate.addingTimeInterval(s.endDate.timeIntervalSince(s.startDate) / 2)
                    let base = cal.startOfDay(for: mid)
                    var assigned: Date?
                    for delta in [0, 1, -1] {
                        guard let wake = cal.date(byAdding: .day, value: delta, to: base),
                              let w = window(for: wake) else { continue }
                        if mid >= w.start && mid <= w.end { assigned = wake; break }
                    }
                    guard let wake = assigned else { continue }
                    sum[wake, default: 0] += v
                    count[wake, default: 0] += 1
                }

                var map: [Date: Double] = [:]
                for (wake, c) in count where c > 0 { map[wake] = sum[wake]! / Double(c) }
                cont.resume(returning: map)
            }
            store.execute(query)
        }
    }

    /// Write a diagnostic file to the app's Documents directory so the developer can pull it via
    /// devicectl and verify HealthKit behavior without involving the user.
    /// Filename: `healthkit-status.json`.
    static func writeDiagnostic(auth: HealthAuthResult, days: [DailyMetric]) {
        let usableCount = days.filter { $0.hrv != nil || $0.sleepMinutes != nil }.count
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"

        func nonNilFields(_ d: DailyMetric) -> [String] {
            var f: [String] = []
            if d.sleepMinutes != nil { f.append("sleep") }
            if d.bedtimeHour != nil { f.append("bedtime") }
            if d.hrv != nil { f.append("hrv") }
            if d.restingHR != nil { f.append("restingHR") }
            if d.steps != nil { f.append("steps") }
            if d.exerciseMinutes != nil { f.append("exercise") }
            if d.respiratoryRate != nil { f.append("respiratoryRate") }
            if d.bloodOxygen != nil { f.append("bloodOxygen") }
            if d.activeEnergy != nil { f.append("activeEnergy") }
            if d.distanceKm != nil { f.append("distanceKm") }
            if d.flightsClimbed != nil { f.append("flightsClimbed") }
            if d.walkingHR != nil { f.append("walkingHR") }
            if d.hourlySteps != nil { f.append("hourlySteps") }
            return f
        }

        // Up to 3 example day rows that actually carry data (most recent first).
        let sampleDays: [[String: Any]] = days.reversed()
            .filter { !nonNilFields($0).isEmpty }
            .prefix(3)
            .map { ["date": df.string(from: $0.date), "fields": nonNilFields($0)] }

        // Per-field coverage: how many days carry each signal. Lets the lead confirm at a glance that
        // real, multi-signal data is flowing (e.g. sleep present on N days, SpO2 on M, etc.).
        var coverage: [String: Int] = [:]
        for d in days {
            for field in nonNilFields(d) { coverage[field, default: 0] += 1 }
        }
        // A complete-hourly-steps count is a useful real-data health check on its own.
        let hourlyStepsDays = days.filter { ($0.hourlySteps?.count ?? 0) == 24 }.count

        var payload: [String: Any] = [
            "available": auth.available,
            "requested": auth.requested,
            "dayCount": days.count,
            "usableCount": usableCount,
            "coverage": coverage,
            "hourlyStepsDays": hourlyStepsDays,
            "sampleDays": sampleDays,
            "writtenAt": ISO8601DateFormatter().string(from: Date()),
        ]
        payload["error"] = auth.error as Any? ?? NSNull()

        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        else { return }
        let url = dir.appendingPathComponent("healthkit-status.json")
        try? data.write(to: url, options: .atomic)
    }

    private func dailyStat(
        _ id: HKQuantityTypeIdentifier, _ option: HKStatisticsOptions,
        _ start: Date, _ end: Date, unit: HKUnit
    ) async -> [Date: Double] {
        await withCheckedContinuation { cont in
            let query = HKStatisticsCollectionQuery(
                quantityType: HKQuantityType(id),
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end),
                options: option,
                anchorDate: Calendar.current.startOfDay(for: start),
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, collection, _ in
                var map: [Date: Double] = [:]
                collection?.enumerateStatistics(from: start, to: end) { stat, _ in
                    let q = option == .cumulativeSum ? stat.sumQuantity() : stat.averageQuantity()
                    if let q { map[stat.startDate] = q.doubleValue(for: unit) }
                }
                cont.resume(returning: map)
            }
            store.execute(query)
        }
    }

    /// The processed result for one night, keyed by the morning you woke up.
    /// - minutes: total true-asleep minutes summed across the night's main sleep block (naps excluded).
    /// - bedtimeHour: see `bedtimeHour(from:)` for the convention.
    /// - windowStart/windowEnd: the main block's boundaries, used to scope overnight-only signals.
    struct NightSleep {
        let minutes: Double
        let bedtimeHour: Double
        let windowStart: Date
        let windowEnd: Date
    }

    /// True-asleep predicate. We count ONLY genuine sleep stages and explicitly exclude `.inBed`
    /// (awake-in-bed) and `.awake`, which the old code's `allAsleepValues` happened to fold in on some
    /// SDKs and which inflate sleep duration by 10–30%. On iOS 16+ the fine-grained stages exist; on
    /// older OSes only the coarse `.asleep` value is available.
    private static func isAsleep(_ value: Int) -> Bool {
        guard let v = HKCategoryValueSleepAnalysis(rawValue: value) else { return false }
        if #available(iOS 16.0, *) {
            switch v {
            case .asleepCore, .asleepDeep, .asleepREM, .asleepUnspecified: return true
            default: return false   // .inBed, .awake, anything else → not asleep
            }
        } else {
            // Pre-16 SDKs only expose `.asleep` as the asleep marker.
            return v == .asleep
        }
    }

    /// Convert a main-block start instant into the app's bedtime-hour scale.
    ///
    /// Convention (kept stable for downstream code, e.g. Snapshot's `bedtimeHour >= 24.5` late-night
    /// test): the value is "local clock hours, measured continuously across midnight", anchored so that
    /// an evening bedtime reads as its civil hour and a post-midnight bedtime reads as 24 + its hour.
    ///   21:30 → 21.5,  23:00 → 23.0,  00:30 → 24.5,  02:00 → 26.0
    ///
    /// We derive it timezone/DST-robustly by measuring hours elapsed since the *prior local noon*
    /// (a fixed civil anchor that the bedtime always falls after, never on a DST seam the way midnight
    /// can), then shifting by +12 so noon=12 maps onto the 24h clock. Anything that lands before noon
    /// of the wake day is treated as the previous night's late bedtime.
    private func bedtimeHour(from blockStart: Date, cal: Calendar) -> Double {
        // Prior noon = noon of the civil day the block starts in.
        let dayStart = cal.startOfDay(for: blockStart)
        let noon = cal.date(byAdding: .hour, value: 12, to: dayStart) ?? dayStart
        // If the block started before noon (an after-midnight bedtime), anchor on the *previous* day's
        // noon so the elapsed-hours value continues past 24.
        let anchor: Date = blockStart >= noon
            ? noon
            : (cal.date(byAdding: .day, value: -1, to: noon) ?? noon)
        let hoursAfterPriorNoon = blockStart.timeIntervalSince(anchor) / 3600
        return hoursAfterPriorNoon + 12   // shift so the value reads on the familiar 24h(+) clock
    }

    /// Minimum total asleep minutes for a contiguous block to count as a "main sleep" rather than a nap.
    private static let mainSleepMinMinutes: Double = 90
    /// Gap between consecutive asleep samples that still counts as the same sleep block. Brief
    /// awakenings (and the small gaps HealthKit leaves between stage samples) shouldn't split a night.
    private static let blockMergeGapMinutes: Double = 60

    /// Aggregate sleep by night. For each morning you woke up we identify the night's MAIN sleep block —
    /// the contiguous asleep period (samples merged across short awakenings) holding the most asleep
    /// minutes and ending that morning — and report its total asleep minutes plus a nap-free bedtime.
    /// Short blocks (<90 min, i.e. naps) are ignored for bedtime purposes.
    private func sleepByNight(_ start: Date, _ end: Date) async -> [Date: NightSleep] {
        await withCheckedContinuation { cont in
            let pred = HKQuery.predicateForSamples(withStart: start, end: end)
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            let query = HKSampleQuery(sampleType: HKCategoryType(.sleepAnalysis),
                                      predicate: pred, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: sort) { _, samples, _ in
                let cal = Calendar.current

                // 1. Keep only true-asleep intervals, sorted by start.
                var intervals: [(start: Date, end: Date)] = []
                for case let s as HKCategorySample in samples ?? [] {
                    guard Self.isAsleep(s.value), s.endDate > s.startDate else { continue }
                    intervals.append((s.startDate, s.endDate))
                }
                intervals.sort { $0.start < $1.start }
                guard !intervals.isEmpty else { cont.resume(returning: [:]); return }

                // 2. Merge into contiguous blocks, bridging gaps up to `blockMergeGapMinutes`.
                //    Each block records its span plus the actual asleep minutes inside it (so overlapping
                //    multi-device samples don't double-count, and gaps aren't counted as sleep).
                struct Block { var start: Date; var end: Date; var asleepMinutes: Double; var coveredUntil: Date }
                var blocks: [Block] = []
                let mergeGap = Self.blockMergeGapMinutes * 60
                for iv in intervals {
                    if var last = blocks.last, iv.start <= last.end.addingTimeInterval(mergeGap) {
                        // Same block. Count only the portion of this interval not already covered by an
                        // earlier (possibly overlapping, multi-device) sample, so we never double-count.
                        let from = max(iv.start, last.coveredUntil)
                        if iv.end > from { last.asleepMinutes += iv.end.timeIntervalSince(from) / 60 }
                        last.coveredUntil = max(last.coveredUntil, iv.end)
                        if iv.end > last.end { last.end = iv.end }
                        blocks[blocks.count - 1] = last
                    } else {
                        blocks.append(Block(start: iv.start, end: iv.end,
                                            asleepMinutes: iv.end.timeIntervalSince(iv.start) / 60,
                                            coveredUntil: iv.end))
                    }
                }

                // 3. Assign each block to a wake date (the morning it ends), then pick, per wake date,
                //    the main block = the qualifying (>= mainSleepMinMinutes) block with the most asleep
                //    minutes. Naps fall below the threshold and never become the night's bedtime.
                var best: [Date: Block] = [:]
                for b in blocks {
                    guard b.asleepMinutes >= Self.mainSleepMinMinutes else { continue }
                    let wake = cal.startOfDay(for: b.end)
                    if let existing = best[wake], existing.asleepMinutes >= b.asleepMinutes { continue }
                    best[wake] = b
                }

                var map: [Date: NightSleep] = [:]
                for (wake, b) in best {
                    map[wake] = NightSleep(
                        minutes: b.asleepMinutes,
                        bedtimeHour: self.bedtimeHour(from: b.start, cal: cal),
                        windowStart: b.start,
                        windowEnd: b.end)
                }
                cont.resume(returning: map)
            }
            store.execute(query)
        }
    }
}

/// Small local RNG (decoupled from N1Stats, for demo data only).
struct SplitMix64Local {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) + .leastNonzeroMagnitude
    }
    mutating func normal(mean: Double = 0, sd: Double = 1) -> Double {
        mean + sd * sqrt(-2 * log(uniform())) * cos(2 * .pi * uniform())
    }
}
