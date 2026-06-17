import SwiftUI
import ServiceManagement

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        WindowManager.shared.showMainWindow(openWindow: nil)
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Re-lock if app comes back to foreground after being backgrounded
        // (handled by PasscodeManager.lock() called from scene phase changes)
    }
}

// MARK: - DriveVaultApp

@main
struct DriveVaultApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = AppStore()
    @StateObject private var pm = PasscodeManager.shared
    @State private var trial = TrialManager.shared
    @State private var showMainWindow = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        registerLoginItem()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu(store: store, showMainWindow: $showMainWindow)
        } label: {
            Label("Drive Vault", systemImage: "externaldrive.fill")
        }

        WindowGroup("Drive Vault", id: "main") {
            Group {
                if trial.isTrialExpired {
                    TrialExpiredView()
                } else if pm.isLocked {
                    // Full app lock screen
                    PasscodeLockView(mode: .appLock)
                        .frame(minWidth: 900, minHeight: 600)
                } else {
                    ContentView()
                        .environmentObject(store)
                        .environmentObject(pm)
                }
            }
            .frame(minWidth: 900, minHeight: 600)
            .onAppear { trial.refresh() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
        .commands {
            DriveVaultCommands()
        }
        .onChange(of: scenePhase) { _, phase in
            // Lock when app goes to background
            if phase == .background {
                pm.lock()
            }
        }
    }

    private func registerLoginItem() {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            if service.status == .notRegistered {
                do {
                    try service.register()
                } catch {
                    print("⚠️ Login item registration failed: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - WindowManager

final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()
    private var storedOpenWindow: OpenWindowAction?

    private override init() {
        super.init()
        NSApp.setActivationPolicy(.accessory)
    }

    func showMainWindow(openWindow: OpenWindowAction?) {
        if let action = openWindow { storedOpenWindow = action }

        if let window = existingMainWindow() {
            // Window exists — just bring it to front, don't open a new one
            attachDelegate(to: window)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else if let action = storedOpenWindow {
            // Only open if no window exists
            action(id: "main")
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                if let window = self.existingMainWindow() {
                    self.attachDelegate(to: window)
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let stillVisible = NSApp.windows.filter { $0.isVisible && $0.canBecomeKey }
            if stillVisible.isEmpty {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    private func existingMainWindow() -> NSWindow? {
        // Find any visible app window that can become key
        NSApp.windows.first {
            $0.canBecomeKey && !$0.isMiniaturized && $0.isVisible
        }
    }

    private func attachDelegate(to window: NSWindow) {
        if window.delegate == nil { window.delegate = self }
    }
}

// MARK: - MenuBarMenu

struct MenuBarMenu: View {
    @ObservedObject var store: AppStore
    @Binding var showMainWindow: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if store.drives.filter({ $0.isOnline }).isEmpty {
            Text("No drives connected").foregroundStyle(.secondary)
        } else {
            ForEach(store.drives.filter({ $0.isOnline })) { drive in
                if let total = drive.totalBytes, let used = drive.usedBytes {
                    let pct = Double(used) / Double(total)
                    Label("\(drive.name) — \(Int(pct * 100))%",
                          systemImage: "externaldrive.fill")
                } else {
                    Label(drive.name, systemImage: "externaldrive.fill")
                }
            }
        }

        Divider()

        if !store.alerts.isEmpty {
            Button {
                WindowManager.shared.showMainWindow(openWindow: openWindow)
            } label: {
                Label("\(store.alerts.count) alert\(store.alerts.count == 1 ? "" : "s")",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }

        Button("Open Drive Vault…") {
            WindowManager.shared.showMainWindow(openWindow: openWindow)
        }

        Divider()

        Button("Quit Drive Vault") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
