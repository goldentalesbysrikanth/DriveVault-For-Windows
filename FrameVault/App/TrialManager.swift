import Foundation
import Combine
/// Manages the 10-day trial period.
/// First launch date is stored in UserDefaults and never reset.
final class TrialManager {
    static let shared = TrialManager()

    private let firstLaunchKey = "fv.firstLaunchDate"
    private let trialDays = 14

    var isTrialExpired: Bool {
        let daysSince = daysSinceFirstLaunch
        return daysSince >= trialDays
    }

    var daysRemaining: Int {
        max(0, trialDays - daysSinceFirstLaunch)
    }

    var firstLaunchDate: Date? {
        UserDefaults.standard.object(forKey: firstLaunchKey) as? Date
    }

    var trialEndDate: Date? {
        guard let first = firstLaunchDate else { return nil }
        return Calendar.current.date(byAdding: .day, value: trialDays, to: first)
    }

    private var daysSinceFirstLaunch: Int {
        guard let first = firstLaunchDate else { return 0 }
        return Calendar.current.dateComponents([.day], from: first, to: Date()).day ?? 0
    }

    private init() {
        // Record first launch date if not already set
        if UserDefaults.standard.object(forKey: firstLaunchKey) == nil {
            UserDefaults.standard.set(Date(), forKey: firstLaunchKey)
        }
    }

    func refresh() {
        // No-op — trial state is computed on demand
    }
}
