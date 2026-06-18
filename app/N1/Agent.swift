import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Where N1 reaches the analysis backend (the `n1d` server running on your own Mac).
///
/// The URL is user-configurable in Settings and persisted to `UserDefaults` under
/// `n1_server_url`. With no override it defaults to localhost, which works in the
/// iOS Simulator. On a physical phone, point it at your Mac (e.g. its Tailscale
/// `100.x.x.x` address) from the in-app Settings screen.
enum ServerConfig {
    /// UserDefaults key holding the user's chosen server URL.
    static let defaultsKey = "n1_server_url"

    /// Default backend URL: localhost, reachable from the iOS Simulator.
    static let fallback = "http://127.0.0.1:8787"

    /// Current backend base URL: the user's override if set, otherwise `fallback`.
    static var baseURL: String {
        let stored = UserDefaults.standard.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty { return stored }
        return fallback
    }

    /// Persist a new base URL (trimmed). Passing an empty string clears the override
    /// and reverts to `fallback`.
    static func set(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: defaultsKey)
        }
    }
}

/// One step in the analysis process — shown to the user (making "what the AI is doing for you" transparent).
struct AgentStep: Identifiable {
    let id = UUID()
    var icon: String
    var title: String
    var detail: String
    var done = false
}

/// Ask agent: an on-device LLM (FoundationModels) handles understanding, decomposition, orchestration, and narration;
/// all numbers still come from the deterministic SnapshotEngine tools. When no model is available, it falls back to rule-based translation.
@MainActor
final class AskAgent: ObservableObject {
    /// Whether a turn is currently running (for disabling input). All display state
    /// (steps/findings/narration/...) lives in the InvestigationStore's active thread.
    @Published var isRunning = false
    @Published var usedFallback = false

    /// History store — the single source of truth for threads/turns. Injected by the app.
    weak var store: InvestigationStore?
    /// Confirmed user ground truth, injected into every investigation. Set by the app.
    weak var profile: GroundTruthStore?

    // Onboarding (separate from threads): the agent proposes ground-truth facts to confirm.
    @Published var onboardingSteps: [StepRec] = []
    @Published var onboardingCandidates: [GroundTruthSpec] = []
    @Published var onboardingRunning = false

    /// Run the onboarding ground-truth pass: agent explores data and proposes facts to confirm.
    func runOnboarding(days: [DailyMetric]) async {
        guard await claudeReachable() else { onboardingCandidates = []; return }
        onboardingRunning = true; onboardingSteps = []; onboardingCandidates = []
        defer { onboardingRunning = false }
        let body: [String: Any] = [
            "question": "Establish my ground truth from my data.",
            "mode": "onboarding",
            "phoneSources": Self.phoneSources(days: days),
        ]
        // Same background-resilient poll model as investigations: survives the app being
        // backgrounded / the status bar being pulled during the multi-minute pass.
        let result: AgentResult? = await withBackgroundGrace {
            try? await self.runViaPoll(body: body) { icon, title, detail in
                self.onboardingSteps.append(StepRec(icon: icon, title: title, detail: detail))
            }.result
        }
        if let result {
            onboardingCandidates = result.groundTruth ?? []
            if let qs = result.suggestedQuestions, !qs.isEmpty { profile?.setSuggestions(qs) }
        } else {
            onboardingCandidates = []
        }
    }

    private let fallback = RuleBasedTranslator()

    /// New top-level question → start a FRESH thread.
    func run(question: String, days: [DailyMetric]) async {
        store?.startThread(prompt: question)
        isRunning = true; usedFallback = false
        defer { isRunning = false }
        push("ear", "Understanding your question", "\"\(question)\"")
        await route(question: question, days: days, resumeSession: nil)
    }

    /// User answers the clarifying question → append a turn and RESUME the same session.
    func clarify(answer: String, days: [DailyMetric]) async {
        await continueThread(prompt: answer, kind: .clarify, days: days)
    }

    /// Dig deeper / follow-up on the SAME thread → append a turn and RESUME.
    func dig(question: String, days: [DailyMetric]) async {
        await continueThread(prompt: question, kind: .dig, days: days)
    }

    private func continueThread(prompt: String, kind: Turn.Kind, days: [DailyMetric]) async {
        let sid = store?.active?.sessionId
        guard let sid, await claudeReachable() else {
            // No live session to resume (offline/fallback) → best-effort fresh pass on a new thread.
            await run(question: prompt, days: days)
            return
        }
        store?.appendTurn(kind: kind, prompt: prompt)
        isRunning = true
        defer { isRunning = false }
        push("arrowshape.turn.up.right", kind == .clarify ? "You answered" : "Digging deeper",
             "\"\(prompt)\"")
        await runWithClaude(question: prompt, days: days, resume: true, resumeSession: sid)
    }

    private func route(question: String, days: [DailyMetric], resumeSession: String?) async {
        if await claudeReachable() {
            await runWithClaude(question: question, days: days, resume: false)
            return
        }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.availability == .available {
            await runWithModel(question: question, days: days)
            return
        }
        #endif
        runFallback(question: question, days: days)
    }

    // MARK: Claude Code backend (the autonomous analysis agent on your Mac, via n1d)
    // Philosophy: don't hand the agent a menu. Given the dataset, it writes its own code to run any analysis; the app only renders the generic structure.

    /// n1d backend base URL. Reads from `ServerConfig`, which is in-app configurable
    /// (Settings) and falls back to localhost so the simulator works out of the box.
    static var claudeBase: String { ServerConfig.baseURL }

    struct AgentPlot: Decodable {
        let labelA: String; let valuesA: [Double]
        let labelB: String; let valuesB: [Double]
    }
    struct SelfReportSpec: Decodable {
        let id: String; let question: String; let type: String
        let scaleMax: Int?; let options: [String]?; let when: String?
        func toItem() -> SelfReportItem {
            SelfReportItem(id: id, question: question,
                           type: SelfReportItem.Kind(rawValue: type) ?? .scale,
                           scaleMax: scaleMax, options: options,
                           when: SelfReportItem.When(rawValue: when ?? "preSleep") ?? .preSleep)
        }
    }
    struct AgentExperiment: Decodable {
        let hypothesis: String; let intervention: String; let control: String
        let selfReport: [SelfReportSpec]?
    }
    struct AgentFinding: Decodable, Identifiable {
        var id: String { headline }
        let headline: String
        let caveat: String?
        let plot: AgentPlot?
        let experiment: AgentExperiment?
    }
    private struct StepSpec: Decodable { let title: String; let detail: String? }
    private struct UnmeasuredSpec: Decodable { let factor: String; let suggestion: String }
    /// Structured clarification: compatible with the legacy plain-string askUser, and also supports {question, options, allowCustom}
    struct AskSpec: Decodable {
        let question: String
        let options: [String]
        let allowCustom: Bool
        init(from decoder: Decoder) throws {
            if let s = try? decoder.singleValueContainer().decode(String.self) {
                question = s; options = []; allowCustom = true; return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            question = try c.decode(String.self, forKey: .question)
            options = (try? c.decode([String].self, forKey: .options)) ?? []
            allowCustom = (try? c.decode(Bool.self, forKey: .allowCustom)) ?? true
        }
        enum CodingKeys: String, CodingKey { case question, options, allowCustom }
    }
    struct CollectionPlanSpec: Decodable {
        let goal: String
        let signals: [String]
        let durationDays: Int
        let reminderTime: String?   // "21:30"
        let reminderText: String
        let rationale: String
        func toPlan() -> CollectionPlan {
            let parts = (reminderTime ?? "21:30").split(separator: ":")
            let h = parts.first.flatMap { Int($0) } ?? 21
            let m = parts.count > 1 ? (Int(parts[1]) ?? 30) : 30
            return CollectionPlan(goal: goal, signals: signals, durationDays: durationDays,
                                  reminderHour: h, reminderMinute: m,
                                  reminderText: reminderText, rationale: rationale)
        }
    }
    /// A ground-truth candidate the agent proposes at onboarding for the user to confirm.
    struct GroundTruthSpec: Decodable, Identifiable {
        let id: String
        let statement: String
        let question: String
        let options: [String]?
        let allowCustom: Bool?
    }
    private struct AgentResult: Decodable {
        let steps: [StepSpec]?
        let findings: [AgentFinding]?
        let askUser: AskSpec?
        let unmeasured: [UnmeasuredSpec]?
        let followups: [String]?
        let collectionPlan: CollectionPlanSpec?
        let groundTruth: [GroundTruthSpec]?
        let suggestedQuestions: [String]?
    }

    private func claudeReachable() async -> Bool {
        guard let url = URL(string: Self.claudeBase + "/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// GET /job/:id response — used to recover a run after the live stream dies
    /// (e.g. the app was backgrounded mid-analysis and the socket was killed).
    private struct JobSnapshot: Decodable {
        let id: String
        let status: String          // "running" | "done" | "error"
        let steps: [StepSpec]
        let result: AgentResult?
        let error: String?
        let sessionId: String?
    }

    // Matches the step titles streamed by the n1d backend (backend contract).
    private static func icon(for title: String) -> String {
        switch title {
        case "Thinking": "brain"
        case "Running code": "terminal"
        case "Pulling a data source": "arrow.down.circle"
        case "Writing analysis script": "square.and.pencil"
        case "Reading": "doc.text.magnifyingglass"
        case "Searching data": "magnifyingglass"
        default: "circle.dotted"
        }
    }

    private func runWithClaude(question: String, days: [DailyMetric],
                               resume: Bool, resumeSession: String? = nil) async {
        if !resume {
            push("desktopcomputer", "Claude on your Mac is analyzing on its own",
                 "Its chain of thought will appear below in real time")
        }
        do {
            var body: [String: Any] = ["question": question]
            if resume, let sid = resumeSession {
                body["sessionId"] = sid    // resume: agent keeps prior work, no re-send of data
            } else {
                body["phoneSources"] = Self.phoneSources(days: days)
                if let p = profile?.statements, !p.isEmpty { body["profile"] = p }
            }

            let (result, session) = try await withBackgroundGrace {
                try await self.runViaPoll(body: body) { icon, title, detail in
                    self.push(icon, title, detail)
                }
            }
            store?.setSession(session)
            applyResult(result)
        } catch {
            // Surface the failure as a VISIBLE turn, never a blank one. Try the
            // on-device/rule-based brains as a courtesy, but if they produce nothing
            // the user still sees a clear "couldn't reach the backend" message.
            push("exclamationmark.triangle", "Couldn't reach the analysis backend",
                 error.localizedDescription)
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *), SystemLanguageModel.default.availability == .available {
                await runWithModel(question: question, days: days)
                return
            }
            #endif
            // No on-device model: if the turn would otherwise be blank, leave an
            // honest, visible error instead of an empty result.
            if (store?.activeTurn?.findings.isEmpty ?? true) {
                store?.failTurn(message:
                    "The analysis backend on your Mac couldn't be reached (\(error.localizedDescription)). Your data and earlier results are kept — try again in a moment.")
            }
            runFallback(question: question, days: days)
        }
    }

    /// Turn a backend result into a finished turn, GUARANTEEING the user sees
    /// something: a finding, the clarifying question, the collection plan, an
    /// unmeasured note, or — if all of those are empty — an honest "not enough"
    /// finding. A valid response must never render as a blank turn.
    private func applyResult(_ result: AgentResult) {
        let findings = (result.findings ?? []).map(Self.toRec)
        let unmeasured = (result.unmeasured ?? []).map { UnmeasuredRec(factor: $0.factor, suggestion: $0.suggestion) }
        let ask: (q: String, opts: [String], custom: Bool)? =
            result.askUser.flatMap { $0.question.isEmpty ? nil : (q: $0.question, opts: $0.options, custom: $0.allowCustom) }
        let plan = result.collectionPlan?.toPlan()
        let hasContent = !findings.isEmpty || ask != nil || plan != nil || !unmeasured.isEmpty

        if let ask {
            push("questionmark.bubble", "The agent wants to check with you", ask.q)
        } else if hasContent {
            push("checkmark.seal", "Done", "The analysis code actually ran on your Mac; the numbers are computed, not generated")
        } else {
            push("info.circle", "Not enough to conclude yet",
                 "The analysis ran but didn't find a supportable answer this time")
        }

        // Floor: if the backend returned a structurally-empty result, show an
        // honest finding rather than nothing.
        let safeFindings = hasContent ? findings : [
            FindingRec(headline: "Not enough data to answer this confidently yet.",
                       caveat: "The analysis ran on your Mac but didn't find a supportable pattern. Try a more specific question, or give it more days of data.",
                       plot: nil, experiment: nil)
        ]
        store?.finishTurn(
            findings: safeFindings,
            narration: nil,
            unmeasured: unmeasured,
            followups: result.followups ?? [],
            ask: ask,
            plan: plan)
    }

    private struct JobStart: Decodable { let jobId: String }

    /// Start a backend job and POLL it to completion. Background-resilient by design:
    /// only short requests are made (no multi-minute held socket that iOS kills when the
    /// app resigns active / the status bar is pulled). The job keeps running on the Mac
    /// regardless; polling simply pauses while suspended and resumes on return.
    /// Applies new steps via `onStep`. Returns the final result + session id, or throws.
    private func runViaPoll(body: [String: Any],
                            onStep: @escaping (_ icon: String, _ title: String, _ detail: String) -> Void)
        async throws -> (result: AgentResult, sessionId: String?) {
        guard let base = URL(string: Self.claudeBase) else {
            throw NSError(domain: "n1d", code: 9, userInfo: [NSLocalizedDescriptionKey: "bad server url"])
        }
        // 1. Start the job (short request → jobId).
        var startReq = URLRequest(url: base)
        startReq.httpMethod = "POST"
        startReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        startReq.httpBody = try JSONSerialization.data(withJSONObject: body)
        startReq.timeoutInterval = 20
        let (startData, _) = try await URLSession.shared.data(for: startReq)
        guard let start = try? JSONDecoder().decode(JobStart.self, from: startData) else {
            throw NSError(domain: "n1d", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "the backend didn't start a job"])
        }

        // 2. Poll until done/error. ~10 min ceiling at 2s.
        let jobURL = base.appendingPathComponent("job").appendingPathComponent(start.jobId)
        var shown = 0
        var consecutiveFailures = 0
        for _ in 0..<300 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            var req = URLRequest(url: jobURL)
            req.timeoutInterval = 12
            req.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let snap = try? JSONDecoder().decode(JobSnapshot.self, from: data) else {
                consecutiveFailures += 1
                if consecutiveFailures > 30 {   // ~1 min of unreachable backend
                    throw NSError(domain: "n1d", code: 13,
                                  userInfo: [NSLocalizedDescriptionKey: "lost contact with the analysis backend"])
                }
                continue
            }
            consecutiveFailures = 0
            if snap.steps.count > shown {
                for s in snap.steps[shown...] { onStep(Self.icon(for: s.title), s.title, s.detail ?? "") }
                shown = snap.steps.count
            }
            if snap.status == "done", let r = snap.result { return (r, snap.sessionId) }
            if snap.status == "error" {
                throw NSError(domain: "n1d", code: 11,
                              userInfo: [NSLocalizedDescriptionKey: snap.error ?? "the analysis failed"])
            }
        }
        throw NSError(domain: "n1d", code: 12,
                      userInfo: [NSLocalizedDescriptionKey: "the analysis took too long"])
    }

    /// Ask iOS for a little extra runtime so a brief backgrounding doesn't suspend us
    /// mid-poll. (The job survives regardless; this just keeps polling smooth.)
    private func withBackgroundGrace<T>(_ work: () async throws -> T) async rethrows -> T {
        #if canImport(UIKit)
        let id = UIApplication.shared.beginBackgroundTask(withName: "n1-investigation")
        defer { if id != .invalid { UIApplication.shared.endBackgroundTask(id) } }
        return try await work()
        #else
        return try await work()
        #endif
    }

    // MARK: Data packaging (aggregate-layer CSV; raw samples never leave the phone)

    /// Build the `phoneSources` map sent to n1d. Always includes the HealthKit CSVs;
    /// additionally includes `location_visits` IF the optional on-device location
    /// collector has captured any visits. Location is purely additive — when disabled or
    /// empty, the key is omitted and the rest is unaffected.
    @MainActor
    static func phoneSources(days: [DailyMetric]) -> [String: String] {
        var sources: [String: String] = [
            "healthkit_daily": dailyCSV(days),
            "healthkit_hourly": hourlyCSV(days),
        ]
        let locationCSV = LocationSource.shared.visitsCSV()
        if !locationCSV.isEmpty { sources["location_visits"] = locationCSV }
        return sources
    }

    private static func dailyCSV(_ days: [DailyMetric]) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let cal = Calendar.current
        func f(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "" }
        var out = "date,weekday,is_weekend,sleep_minutes,bedtime_hour,hrv,resting_hr,steps,exercise_minutes,respiratory_rate,blood_oxygen,active_energy_kcal,distance_km,flights,walking_hr\n"
        for d in days {
            let wd = cal.component(.weekday, from: d.date)
            out += "\(df.string(from: d.date)),\(wd),\(d.isWeekend ? 1 : 0),\(f(d.sleepMinutes)),\(f(d.bedtimeHour)),\(f(d.hrv)),\(f(d.restingHR)),\(f(d.steps)),\(f(d.exerciseMinutes)),\(f(d.respiratoryRate)),\(f(d.bloodOxygen)),\(f(d.activeEnergy)),\(f(d.distanceKm)),\(f(d.flightsClimbed)),\(f(d.walkingHR))\n"
        }
        return out
    }

    private static func hourlyCSV(_ days: [DailyMetric]) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        var out = "date,hour,steps\n"
        for d in days {
            guard let hs = d.hourlySteps else { continue }
            let ds = df.string(from: d.date)
            for (h, s) in hs.enumerated() { out += "\(ds),\(h),\(Int(s))\n" }
        }
        return out
    }

    // MARK: On-device model path

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func runWithModel(question: String, days: [DailyMetric]) async {
        push("brain", "On-device AI is breaking it down", "Your data never leaves this device")

        let scratch = AgentScratch(days: days) { [weak self] step in
            Task { @MainActor in self?.push(step.icon, step.title, step.detail) }
        }
        let catalog = Self.dataCatalog(days: days)
        let session = LanguageModelSession(
            tools: [CompareDaysTool(scratch: scratch), UnmeasurableTool(scratch: scratch)],
            instructions: """
            You are N1's analysis assistant, helping the user find answers in their own health data.
            Available data: \(catalog).
            Rules:
            1. Break the user's question into measurable parts; whatever compare_days can check, check it (you may call it multiple times).
            2. For factors the phone can't see (mood, overtime, coffee, stress, etc.), declare them honestly with note_unmeasurable — don't make things up.
            3. You only handle understanding and narration; all numbers come from the tools' returns, and you must never compute or invent numbers yourself.
            4. Finish with a summary, in the language the user asked in, of no more than 100 words: what you found and what can't be seen.
            5. These are all historical correlations, not causation — don't say "causes" or "proves" in the summary.
            """
        )
        do {
            let response = try await session.respond(to: question)
            push("checkmark.seal", "Done", "Numbers come from the on-device stats engine; the AI only handles understanding and narration")
            store?.finishTurn(
                findings: scratch.collected.map { Self.toRec($0.finding, $0.result) },
                narration: response.content,
                unmeasured: scratch.limitations.map { UnmeasuredRec(factor: $0.factor, suggestion: $0.suggestion) },
                followups: [], ask: nil, plan: nil)
        } catch {
            push("exclamationmark.triangle", "On-device AI failed, falling back to simple parsing", "\(error.localizedDescription)")
            runFallback(question: question, days: days)
        }
    }
    #endif

    // MARK: Fallback path (when no on-device model is available)

    private func runFallback(question: String, days: [DailyMetric]) {
        usedFallback = true
        push("text.magnifyingglass", "Parsing keywords (on-device AI is off)", "Turn on Apple Intelligence on a real device and any phrasing will be understood")
        switch fallback.parse(question) {
        case let .query(metric, grouping):
            push("function", "Comparing \(grouping.labelA) × \(metric.label)", "Deterministic stats engine")
            if let r = SnapshotEngine.compare(days: days, metric: metric, grouping: grouping) {
                push("checkmark.seal", "Done", "")
                store?.finishTurn(findings: [Self.toRec(SnapshotEngine.wording(r, question: question), r)],
                                  narration: nil, unmeasured: [], followups: [], ask: nil, plan: nil)
            } else {
                store?.finishTurn(findings: [], narration: nil, unmeasured: [], followups: [], ask: nil, plan: nil)
            }
        case let .needsExperiment(exposure):
            push("eye.slash", "Can't see \"\(exposure)\"", "Being honest: your history can't answer this")
            store?.finishTurn(findings: [], narration: nil,
                              unmeasured: [UnmeasuredRec(factor: exposure, suggestion: "There's no record of this on your phone — run a mini-experiment to compare directly")],
                              followups: [], ask: nil, plan: nil)
        case .unknown:
            push("questionmark", "Didn't catch that", "Try rephrasing, or use the picker below")
            store?.finishTurn(findings: [], narration: nil, unmeasured: [], followups: [], ask: nil, plan: nil)
        }
    }

    private func push(_ icon: String, _ title: String, _ detail: String) {
        store?.pushStep(icon: icon, title: title, detail: detail)
    }

    // MARK: Converters → persistable records

    static func toRec(_ f: AgentFinding) -> FindingRec {
        FindingRec(headline: f.headline, caveat: f.caveat,
                   plot: f.plot.map { PlotRec(labelA: $0.labelA, valuesA: $0.valuesA, labelB: $0.labelB, valuesB: $0.valuesB) },
                   experiment: f.experiment.map { ExperimentRec(hypothesis: $0.hypothesis, intervention: $0.intervention,
                                                                control: $0.control,
                                                                selfReports: ($0.selfReport ?? []).map { $0.toItem() }) })
    }

    static func toRec(_ finding: Finding, _ r: SnapshotResult) -> FindingRec {
        let exp = r.grouping.experimentPlan.map { ExperimentRec(hypothesis: $0.hypothesis, intervention: $0.intervention, control: $0.control) }
        return FindingRec(headline: finding.headline, caveat: finding.caveat,
                          plot: PlotRec(labelA: r.grouping.labelA, valuesA: r.pointsA,
                                        labelB: r.grouping.labelB, valuesB: r.pointsB),
                          experiment: exp)
    }

    private static func dataCatalog(days: [DailyMetric]) -> String {
        let n = days.count
        return "the past \(n) days of: sleep duration, bedtime, nightly recovery (HRV), resting heart rate, steps, exercise minutes"
    }
}

// MARK: - Tools (callable by the model; the single source of numbers)

/// Shared scratchpad between tools: collect results + push steps to the UI.
final class AgentScratch: @unchecked Sendable {
    let days: [DailyMetric]
    private(set) var collected: [(finding: Finding, result: SnapshotResult)] = []
    private(set) var limitations: [(factor: String, suggestion: String)] = []
    let log: (AgentStep) -> Void
    private let lock = NSLock()

    init(days: [DailyMetric], log: @escaping (AgentStep) -> Void) {
        self.days = days
        self.log = log
    }

    func add(_ entry: (Finding, SnapshotResult)) {
        lock.lock(); collected.append(entry); lock.unlock()
    }
    func addLimitation(_ l: (String, String)) {
        lock.lock(); limitations.append(l); lock.unlock()
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
struct CompareDaysTool: Tool {
    let scratch: AgentScratch

    let name = "compare_days"
    let description = """
    Use deterministic statistics to compare a health metric across two kinds of days. Returns the mean difference and a confidence interval.
    metric values: sleep (sleep duration) | hrv (nightly recovery) | restingHR (resting heart rate) | steps (step count).
    grouping values: lateNight (late vs. early nights) | exerciseDay (workout vs. rest) | weekend (weekend vs. weekday) | highSteps (high vs. low steps).
    """

    @Generable
    struct Arguments {
        @Guide(description: "sleep | hrv | restingHR | steps")
        var metric: String
        @Guide(description: "lateNight | exerciseDay | weekend | highSteps")
        var grouping: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let m = MetricKind(rawValue: arguments.metric),
              let g = GroupingRule(rawValue: arguments.grouping) else {
            return ("Invalid arguments. metric/grouping must be one of the values listed in the description.")
        }
        scratch.log(AgentStep(icon: "function",
                              title: "Comparing: \(g.labelA) × \(m.label)",
                              detail: "The deterministic stats engine is computing"))
        guard let r = SnapshotEngine.compare(days: scratch.days, metric: m, grouping: g) else {
            return ("Not enough data to compare (each group needs at least 5 days).")
        }
        let f = SnapshotEngine.wording(r, question: "\(g.labelA) × \(m.label)")
        scratch.add((f, r))
        let unit = m.unit.isEmpty ? "points" : m.unit
        return (String(
            format: "%@: n=%d days, mean %.1f; %@: n=%d days, mean %.1f; difference %+.1f %@ (95%%CI %.1f to %.1f). This is a correlation, not causation.",
            g.labelA, r.nA, r.meanA, g.labelB, r.nB, r.meanB,
            r.diff, unit, r.diffCI.lowerBound, r.diffCI.upperBound))
    }
}

@available(iOS 26.0, *)
struct UnmeasurableTool: Tool {
    let scratch: AgentScratch

    let name = "note_unmeasurable"
    let description = "Call this when a question involves a factor that doesn't exist in the phone's data (mood, overtime, coffee, stress, diet, etc.) to honestly record the limitation."

    @Generable
    struct Arguments {
        @Guide(description: "The factor that can't be seen, e.g. overtime, mood")
        var factor: String
        @Guide(description: "A one-line suggestion for the user, e.g. run a two-week mini-experiment to compare directly")
        var suggestion: String
    }

    func call(arguments: Arguments) async throws -> String {
        scratch.log(AgentStep(icon: "eye.slash",
                              title: "The phone can't see \"\(arguments.factor)\"",
                              detail: "Stated honestly, not invented"))
        scratch.addLimitation((arguments.factor, arguments.suggestion))
        return ("Recorded: \(arguments.factor) is not measurable.")
    }
}
#endif
