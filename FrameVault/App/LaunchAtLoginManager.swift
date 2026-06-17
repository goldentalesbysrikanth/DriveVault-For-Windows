import Foundation
import ServiceManagement

/// Manages launch at login using the modern ServiceManagement API (macOS 13+)
final class LaunchAtLoginManager {
    static let shared = LaunchAtLoginManager()
    private init() {}

    /// Whether the app is set to launch at login
    var isEnabled: Bool {
        get {
            if #available(macOS 13.0, *) {
                return SMAppService.mainApp.status == .enabled
            } else {
                return UserDefaults.standard.bool(forKey: "fv.launchAtLogin")
            }
        }
        set {
            if #available(macOS 13.0, *) {
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                        print("✅ Launch at login enabled")
                    } else {
                        try SMAppService.mainApp.unregister()
                        print("✅ Launch at login disabled")
                    }
                } catch {
                    print("⚠️ LaunchAtLogin error: \(error.localizedDescription)")
                }
            } else {
                UserDefaults.standard.set(newValue, forKey: "fv.launchAtLogin")
            }
        }
    }

    /// Toggle launch at login state
    func toggle() {
        isEnabled.toggle()
    }
}
