import Foundation

// MARK: - Persistent investigation history (threads of turns)
//
// History is a first-class, persisted thing. A new question starts a fresh thread;
// digging deeper appends a turn to the SAME thread (prior reasoning collapses but is
// never wiped). The Archive lists past threads so you can revisit or deep-dive later.

struct StepRec: Codable, Identifiable, Equatable {
    var id = UUID()
    var icon: String
    var title: String
    var detail: String
}

struct PlotRec: Codable, Equatable {
    let labelA: String; let valuesA: [Double]
    let labelB: String; let valuesB: [Double]
}

struct ExperimentRec: Codable, Equatable {
    let hypothesis: String; let intervention: String; let control: String
    var selfReports: [SelfReportItem] = []
}

struct FindingRec: Codable, Identifiable, Equatable {
    var id = UUID()
    let headline: String
    let caveat: String?
    let plot: PlotRec?
    let experiment: ExperimentRec?
}

struct UnmeasuredRec: Codable, Equatable { let factor: String; let suggestion: String }

/// One turn in a thread: a question (or an answer to a clarification / a deeper dig)
/// plus the reasoning and results it produced.
struct Turn: Codable, Identifiable, Equatable {
    var id = UUID()
    enum Kind: String, Codable { case question, clarify, dig }
    var kind: Kind
    var prompt: String              // what the user said this turn
    var steps: [StepRec] = []
    var findings: [FindingRec] = []
    var narration: String?
    var unmeasured: [UnmeasuredRec] = []
    var followups: [String] = []
    var pendingAsk: String?
    var pendingOptions: [String] = []
    var pendingAllowCustom = true
    var plan: CollectionPlan?
    var isRunning = false
}

struct Investigation: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var sessionId: String?          // Claude session for resume-based deep dives
    var turns: [Turn] = []

    var lastFinding: String? { turns.reversed().flatMap { $0.findings }.first?.headline }
}

@MainActor
final class InvestigationStore: ObservableObject {
    @Published private(set) var threads: [Investigation] = []
    @Published var activeID: UUID?
    private let key = "n1.investigations"

    init() { load() }

    var active: Investigation? {
        get { threads.first { $0.id == activeID } }
        set {
            guard let nv = newValue, let i = threads.firstIndex(where: { $0.id == nv.id }) else { return }
            threads[i] = nv; threads[i].updatedAt = Date()
            save()
        }
    }
    var activeTurn: Turn? { active?.turns.last }

    // New top-level question → fresh thread.
    func startThread(prompt: String) {
        var inv = Investigation(title: prompt, createdAt: Date(), updatedAt: Date())
        inv.turns = [Turn(kind: .question, prompt: prompt, isRunning: true)]
        threads.insert(inv, at: 0)
        activeID = inv.id
        save()
    }

    // Deeper dig / answer to clarification → append a turn to the SAME thread.
    func appendTurn(kind: Turn.Kind, prompt: String) {
        guard var inv = active else { return }
        inv.turns.append(Turn(kind: kind, prompt: prompt, isRunning: true))
        active = inv
    }

    func open(_ id: UUID) { activeID = id }

    func delete(_ id: UUID) {
        threads.removeAll { $0.id == id }
        if activeID == id { activeID = nil }
        save()
    }

    // —— mutations on the current (last) turn of the active thread ——

    private func mutateLastTurn(_ change: (inout Turn) -> Void) {
        guard var inv = active, !inv.turns.isEmpty else { return }
        var t = inv.turns[inv.turns.count - 1]
        change(&t)
        inv.turns[inv.turns.count - 1] = t
        active = inv
    }

    func pushStep(icon: String, title: String, detail: String) {
        mutateLastTurn { $0.steps.append(StepRec(icon: icon, title: title, detail: detail)) }
    }

    func setSession(_ id: String?) {
        guard let id, var inv = active else { return }
        inv.sessionId = id; active = inv
    }

    func finishTurn(findings: [FindingRec], narration: String?, unmeasured: [UnmeasuredRec],
                    followups: [String], ask: (q: String, opts: [String], custom: Bool)?,
                    plan: CollectionPlan?) {
        mutateLastTurn {
            $0.findings = findings
            $0.narration = narration
            $0.unmeasured = unmeasured
            $0.followups = followups
            $0.pendingAsk = ask?.q
            $0.pendingOptions = ask?.opts ?? []
            $0.pendingAllowCustom = ask?.custom ?? true
            $0.plan = plan
            $0.isRunning = false
        }
    }

    func failTurn(message: String) {
        mutateLastTurn {
            $0.steps.append(StepRec(icon: "exclamationmark.triangle", title: "Couldn't finish", detail: message))
            $0.isRunning = false
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let t = try? JSONDecoder().decode([Investigation].self, from: data) else { return }
        threads = t
    }
    private func save() {
        if let data = try? JSONEncoder().encode(threads) { UserDefaults.standard.set(data, forKey: key) }
    }
}
