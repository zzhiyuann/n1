import Foundation
import SwiftUI
import UserNotifications

/// Collection plan: when the data isn't enough to draw a (especially long-term) conclusion, the "start tracking today" plan the agent proposes.
/// A generic structure — the agent decides what to track, for how long, and how to remind; the app just executes and monitors adherence.
struct CollectionPlan: Codable, Identifiable, Equatable {
    var id = UUID()
    let goal: String            // the question this is meant to answer
    let signals: [String]       // signals to keep collecting (matching MetricKind.rawValue)
    let durationDays: Int       // how long to collect before it's worth looking back
    let reminderHour: Int       // daily reminder time (hour)
    let reminderMinute: Int
    let reminderText: String    // reminder copy
    let rationale: String       // why we can't conclude right now
    var startedAt: Date = Date()

    var endDate: Date { Calendar.current.date(byAdding: .day, value: durationDays, to: startedAt)! }
    var daysElapsed: Int {
        max(0, Calendar.current.dateComponents([.day], from: startedAt, to: Date()).day ?? 0)
    }
    var isComplete: Bool { Date() >= endDate }

    /// Signal → readable name
    var signalLabels: [String] {
        signals.map { MetricKind(rawValue: $0)?.label ?? $0 }
    }
}

@MainActor
final class CollectionStore: ObservableObject {
    @Published private(set) var plans: [CollectionPlan] = []
    private let key = "n1.collectionPlans"

    init() { load() }

    func activate(_ plan: CollectionPlan) async {
        guard !plans.contains(where: { $0.goal == plan.goal }) else { return }
        plans.insert(plan, at: 0)
        save()
        await NotificationManager.shared.scheduleDaily(for: plan)
    }

    func cancel(_ plan: CollectionPlan) {
        plans.removeAll { $0.id == plan.id }
        save()
        NotificationManager.shared.cancel(for: plan)
    }

    /// Adherence monitoring: how many recent days are missing the target signal → decide whether a follow-up reminder is needed.
    struct Adherence { let recorded: Int; let expected: Int; let missedYesterday: Bool }

    func adherence(_ plan: CollectionPlan, days: [DailyMetric]) -> Adherence {
        let cal = Calendar.current
        let metrics = plan.signals.compactMap { MetricKind(rawValue: $0) }
        let window = days.filter { $0.date >= cal.startOfDay(for: plan.startedAt) }
        let recorded = window.filter { day in metrics.allSatisfy { $0.value(of: day) != nil } }.count
        let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!
        let yDay = days.first { cal.isDate($0.date, inSameDayAs: yesterday) }
        let missed = yDay == nil || metrics.contains { $0.value(of: yDay!) == nil }
        return Adherence(recorded: recorded, expected: max(plan.daysElapsed, 1), missedYesterday: missed)
    }

    /// On every app launch: if last night was missed, make sure tonight's reminder is set (adaptive follow-up reminders).
    func reconcile(days: [DailyMetric]) async {
        for plan in plans where !plan.isComplete {
            if adherence(plan, days: days).missedYesterday {
                await NotificationManager.shared.scheduleDaily(for: plan, escalate: true)
            }
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let p = try? JSONDecoder().decode([CollectionPlan].self, from: data) else { return }
        plans = p
    }
    private func save() {
        if let data = try? JSONEncoder().encode(plans) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// Local notifications: bedtime reminders + follow-up reminders for missed logs. No special entitlement needed — just request permission at runtime.
final class NotificationManager {
    static let shared = NotificationManager()
    private let center = UNUserNotificationCenter.current()

    func requestAuth() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func scheduleDaily(for plan: CollectionPlan, escalate: Bool = false) async {
        _ = await requestAuth()
        let id = "n1.plan.\(plan.id.uuidString)"
        center.removePendingNotificationRequests(withIdentifiers: [id])

        let content = UNMutableNotificationContent()
        content.title = escalate ? "Looks like last night wasn't logged" : "N1 · Tonight's tracking"
        content.body = plan.reminderText
        content.sound = .default

        var when = DateComponents()
        when.hour = plan.reminderHour
        when.minute = plan.reminderMinute
        let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: true)
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    func cancel(for plan: CollectionPlan) {
        center.removePendingNotificationRequests(withIdentifiers: ["n1.plan.\(plan.id.uuidString)"])
    }

    // MARK: - Self-report reminders (per experiment × item × time-slot)

    /// Identifier for one item/slot reminder, e.g. "n1.exp.<expId>.<itemId>.09:00".
    private func selfReportID(expId: UUID, itemId: String, slot: String) -> String {
        "n1.exp.\(expId.uuidString).\(itemId).\(slot)"
    }

    /// Schedule a repeating DAILY notification for each self-report item × each time-slot.
    /// iOS can't natively express "every N days", so we fire daily and let the app's
    /// heads-up / due logic decide whether it's actually due today (everyNDays).
    func scheduleSelfReportReminders(experiment e: Experiment) {
        guard e.status == .running, !e.selfReports.isEmpty else { return }
        Task {
            _ = await requestAuth()
            for item in e.selfReports {
                for slot in item.slots {
                    guard let (h, m) = SelfReportItem.parse(slot) else { continue }
                    let id = selfReportID(expId: e.id, itemId: item.id, slot: slot)
                    center.removePendingNotificationRequests(withIdentifiers: [id])

                    let content = UNMutableNotificationContent()
                    content.title = "N1 · \(e.title)"
                    content.body = item.question
                    content.sound = .default

                    var when = DateComponents()
                    when.hour = h; when.minute = m
                    let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: true)
                    try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
                }
            }
        }
    }

    /// Cancel every self-report reminder belonging to an experiment (all items × slots).
    func cancelSelfReportReminders(experiment e: Experiment) {
        let ids = e.selfReports.flatMap { item in
            item.slots.map { selfReportID(expId: e.id, itemId: item.id, slot: $0) }
        }
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}
