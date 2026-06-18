import Foundation

// MARK: - User ground truth (established at onboarding, confirmed by the user, reused everywhere)
//
// Replaces hardcoded heuristics (e.g. "weekday low-movement = work"). After data permission,
// the agent proposes candidate facts from the actual data; the user confirms/edits/skips; the
// confirmed set persists and is injected into every future investigation's context.

struct ConfirmedFact: Codable, Identifiable, Equatable {
    var id: String              // stable key, e.g. "work_schedule", "office_location"
    var statement: String       // the confirmed fact in plain language
    var confirmedAt: Date = Date()
}

@MainActor
final class GroundTruthStore: ObservableObject {
    @Published private(set) var facts: [ConfirmedFact] = []
    @Published var onboarded: Bool = false
    /// Personalized starter questions the agent surfaced from this user's data at onboarding.
    @Published var suggestedQuestions: [String] = []
    private let factsKey = "n1.groundTruth"
    private let onboardedKey = "n1.onboarded"
    private let suggestionsKey = "n1.suggestedQuestions"

    init() {
        if let d = UserDefaults.standard.data(forKey: factsKey),
           let f = try? JSONDecoder().decode([ConfirmedFact].self, from: d) { facts = f }
        onboarded = UserDefaults.standard.bool(forKey: onboardedKey)
        suggestedQuestions = UserDefaults.standard.stringArray(forKey: suggestionsKey) ?? []
    }

    func setSuggestions(_ qs: [String]) {
        suggestedQuestions = qs
        UserDefaults.standard.set(qs, forKey: suggestionsKey)
    }

    /// Confirm (or update) a fact.
    func confirm(id: String, statement: String) {
        if let i = facts.firstIndex(where: { $0.id == id }) {
            facts[i].statement = statement; facts[i].confirmedAt = Date()
        } else {
            facts.append(ConfirmedFact(id: id, statement: statement))
        }
        save()
    }

    func remove(id: String) { facts.removeAll { $0.id == id }; save() }

    func finishOnboarding() { onboarded = true; UserDefaults.standard.set(true, forKey: onboardedKey) }
    func resetOnboarding() { onboarded = false; UserDefaults.standard.set(false, forKey: onboardedKey) }

    /// Confirmed facts as plain statements — injected into every agent investigation.
    var statements: [String] { facts.map { $0.statement } }

    private func save() {
        if let d = try? JSONEncoder().encode(facts) { UserDefaults.standard.set(d, forKey: factsKey) }
    }
}
