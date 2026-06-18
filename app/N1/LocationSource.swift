import Foundation
import CoreLocation
import Combine

/// On-device location collector for the open-source N1.
///
/// N1's richer analyses (home vs. work, commute, "where did this behavior happen")
/// need a coarse sense of *places and routine*, not a GPS breadcrumb trail. iOS gives
/// us a low-power, privacy-respecting, background-capable primitive for exactly that:
/// **visit monitoring** (`CLLocationManager.startMonitoringVisits`). The OS decides
/// when you've arrived at / departed from a meaningful place and hands back a coarse
/// coordinate plus arrival/departure timestamps — no continuous tracking, no battery
/// drain.
///
/// Everything here is OPTIONAL and ADDITIVE. N1's HealthKit core works fully with
/// location disabled; when enabled, captured visits are turned into a CSV that is
/// included in the agent's `phoneSources` (so the agent learns place/routine context
/// without any external data store).
///
/// Honesty: iOS exposes **no** historical location to apps — there is nothing to
/// backfill. Collection starts the moment the user enables it and accrues from then on.
/// All visits are persisted locally (a JSON file in the app's Documents directory) and
/// never leave the device except as the aggregated CSV the user's own analysis backend
/// receives.
@MainActor
final class LocationSource: NSObject, ObservableObject {
    /// Shared singleton — Agent and Settings both talk to the same collector.
    static let shared = LocationSource()

    /// One captured place visit (the OS's `CLVisit` mapped to a Codable record).
    struct Visit: Codable, Identifiable {
        var id = UUID()
        var arrival: Date
        var departure: Date?
        var latitude: Double
        var longitude: Double
        var horizontalAccuracy: Double
    }

    /// Published so the Settings UI updates live as visits accrue / auth changes.
    @Published private(set) var visits: [Visit] = []
    @Published private(set) var authorizationStatus: CLAuthorizationStatus

    private let manager = CLLocationManager()

    /// File in Documents holding the persisted visits as JSON.
    private static var storeURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("n1_location_visits.json")
    }

    private override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        visits = Self.load()
        // If the user previously authorized, resume monitoring on launch so background
        // visits keep flowing without re-prompting.
        if Self.isAuthorized { startMonitoring() }
    }

    // MARK: Authorization

    /// Whether N1 is currently allowed to collect visits (When-In-Use or Always).
    static var isAuthorized: Bool {
        switch CLLocationManager().authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return true
        default: return false
        }
    }

    /// Instance mirror of `isAuthorized`, derived from published status (drives the UI).
    var isAuthorizedNow: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    /// Ask the user for permission and begin collecting.
    ///
    /// When-In-Use is enough to *start*; we then opportunistically request Always so
    /// the OS can deliver visit arrivals/departures while the app is backgrounded
    /// (which is where most of the routine signal lives). If the user keeps it at
    /// When-In-Use that's fine — visits still arrive while the app is foreground/recent.
    func authorize() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            // Upgrade to Always for background visit capture (user can decline).
            manager.requestAlwaysAuthorization()
            startMonitoring()
        case .authorizedAlways:
            startMonitoring()
        default:
            // Denied / restricted: nothing we can do but stay a no-op.
            break
        }
    }

    private func startMonitoring() {
        manager.startMonitoringVisits()
        // Significant-location-change is a cheap complement that keeps the app alive
        // enough to receive visits across larger moves; also background-capable.
        manager.startMonitoringSignificantLocationChanges()
    }

    // MARK: Export for the agent / UI

    /// CSV of all captured visits, one row per visit.
    /// Columns: `arrival,departure,latitude,longitude,duration_min`.
    /// Returns an empty string when there is nothing to share (the caller should then
    /// omit the source entirely). Never crashes on zero data.
    func visitsCSV() -> String {
        guard !visits.isEmpty else { return "" }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var out = "arrival,departure,latitude,longitude,duration_min\n"
        for v in visits.sorted(by: { $0.arrival < $1.arrival }) {
            let arr = iso.string(from: v.arrival)
            let dep = v.departure.map { iso.string(from: $0) } ?? ""
            let durMin: String = {
                guard let d = v.departure else { return "" }
                return String(format: "%.0f", d.timeIntervalSince(v.arrival) / 60.0)
            }()
            out += String(format: "%@,%@,%.5f,%.5f,%@\n",
                          arr, dep, v.latitude, v.longitude, durMin)
        }
        return out
    }

    /// Small summary for the Settings UI: how many places, and since when.
    struct Summary {
        var count: Int
        var since: Date?
    }

    var summary: Summary {
        Summary(count: visits.count, since: visits.map(\.arrival).min())
    }

    // MARK: Persistence

    private static func load() -> [Visit] {
        guard let data = try? Data(contentsOf: storeURL) else { return [] }
        return (try? JSONDecoder().decode([Visit].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(visits) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }

    /// Record a freshly delivered visit. A visit with a non-nil departure that matches a
    /// previously-stored open visit (same arrival/coordinate) is treated as the closing
    /// update for that same visit rather than a new row.
    fileprivate func record(_ clVisit: CLVisit) {
        // The OS sends a "null" coordinate sentinel in some edge cases; ignore those.
        let coord = clVisit.coordinate
        guard CLLocationCoordinate2DIsValid(coord),
              !(coord.latitude == 0 && coord.longitude == 0) else { return }

        let arrival = clVisit.arrivalDate == .distantPast ? Date() : clVisit.arrivalDate
        let departure = clVisit.departureDate == .distantFuture ? nil : clVisit.departureDate

        // Update an existing open visit at the same place/arrival if this is its closing
        // departure event; otherwise append a new one.
        if let idx = visits.firstIndex(where: {
            abs($0.arrival.timeIntervalSince(arrival)) < 60 &&
            abs($0.latitude - coord.latitude) < 0.0005 &&
            abs($0.longitude - coord.longitude) < 0.0005
        }) {
            if let departure { visits[idx].departure = departure }
        } else {
            visits.append(Visit(arrival: arrival,
                                departure: departure,
                                latitude: coord.latitude,
                                longitude: coord.longitude,
                                horizontalAccuracy: clVisit.horizontalAccuracy))
        }
        save()
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationSource: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        Task { @MainActor in self.record(visit) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            if Self.isAuthorized { self.startMonitoring() }
        }
    }
}
