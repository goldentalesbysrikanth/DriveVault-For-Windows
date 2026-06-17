import Foundation
import Combine

/// Manages the trial period for Drive Vault.
/// First launch date is stored in UserDefaults and never reset.
final class TrialManager: ObservableObject {
    static let shared = TrialManager()

    private let firstLaunchKey = "fv.firstLaunchDate"
    private let trialDays = 14

    @Published private(set) var isTrialExpired: Bool = false
    @Published private(set) var daysRemaining: Int = 0
    @Published private(set) var trialEndDate: Date?

    var firstLaunchDate: Date? {
        UserDefaults.standard.object(forKey: firstLaunchKey) as? Date
    }

    private init() {
        if UserDefaults.standard.object(forKey: firstLaunchKey) == nil {
            UserDefaults.standard.set(Date(), forKey: firstLaunchKey)
        }
        refresh()
    }

    func refresh() {
        let daysSince = daysSinceFirstLaunch
        isTrialExpired = daysSince >= trialDays
        daysRemaining  = max(0, trialDays - daysSince)
        if let first = firstLaunchDate {
            trialEndDate = Calendar.current.date(byAdding: .day, value: trialDays, to: first)
        }
    }

    private var daysSinceFirstLaunch: Int {
        guard let first = firstLaunchDate else { return 0 }
        return Calendar.current.dateComponents([.day], from: first, to: Date()).day ?? 0
    }
}
