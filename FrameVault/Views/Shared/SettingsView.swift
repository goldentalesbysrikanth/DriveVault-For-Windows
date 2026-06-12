import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    private var trial = TrialManager.shared

    @AppStorage("fv.autoIndexOnConnect") var autoIndexOnConnect = true
    @AppStorage("fv.promptBeforeIndex")  var promptBeforeIndex  = false
    @State private var launchAtLogin = LaunchAtLoginManager.shared.isEnabled
    @AppStorage("fv.alertThresholdPct") var alertThresholdPct: Double = 90
    @AppStorage("fv.alertDaysUnseen")   var alertDaysUnseen: Double   = 3
    @AppStorage("fv.excludedDrives") var excludedDrivesRaw = ""
    @State private var newExcludedDrive  = ""
    @State private var showAddExcluded   = false

    // Passcode
    @StateObject private var pm = PasscodeManager.shared
    @State private var showPasscodeSetup     = false
    @State private var showPasscodeChange    = false
    @State private var showPasscodeDisable   = false
    @State private var showPasscodeAuth      = false
    @State private var pendingProtectedAction: (() -> Void)? = nil

    // Snapshots
    @State private var snapshots: [DatabaseSnapshot] = []
    @State private var showRestoreConfirm: DatabaseSnapshot? = nil

    // Reset confirmations
    @State private var showDBResetConfirm    = false
    @State private var showDBResetFinal      = false
    @State private var showAppResetConfirm   = false
    @State private var showAppResetFinal     = false
    @State private var resetConfirmText      = ""

    var excludedDrives: [String] {
        excludedDrivesRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                settingsGroup("License") {
                    settingsRow {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                if trial.isTrialExpired {
                                    Label("Trial expired", systemImage: "lock.fill")
                                        .foregroundStyle(.red)
                                        .font(.system(size: 13, weight: .medium))
                                } else {
                                    Label("\(trial.daysRemaining) day\(trial.daysRemaining != 1 ? "s" : "") remaining in trial", systemImage: "clock")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(trial.daysRemaining <= 3 ? .orange : .green)
                                }
                                if let end = trial.trialEndDate {
                                    Text("Trial \(trial.isTrialExpired ? "ended" : "ends") \(end.formatted(date: .long, time: .omitted))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Purchase license") {
                                NSWorkspace.shared.open(URL(string: "https://drivevault.app/buy")!)
                            }
                            .buttonStyle(.borderedProminent).tint(.purple).controlSize(.small)
                        }
                    }
                }

                settingsGroup("Startup") {
                    settingsRow {
                        Toggle("Launch Drive Vault when Mac starts", isOn: $launchAtLogin)
                            .onChange(of: launchAtLogin) { _, val in LaunchAtLoginManager.shared.isEnabled = val; store.logAppEvent(.settingsChanged, detail: "Launch at login: \(val ? "enabled" : "disabled")") }
                        Text("Drive Vault will start automatically in the background when you log in.")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                    }
                }

                settingsGroup("Indexing") {
                    settingsRow {
                        Toggle("Auto-index when a drive connects", isOn: $autoIndexOnConnect)
                            .onChange(of: autoIndexOnConnect) { _, val in
                                store.autoIndexEnabled = val
                                store.logAppEvent(.settingsChanged, detail: "Auto-index \(val ? "enabled" : "disabled")")
                            }
                        Text("Automatically scans folders whenever an external drive is mounted.")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                    }
                    settingsRow {
                        Toggle("Ask before indexing a new drive", isOn: $promptBeforeIndex)
                            .onChange(of: promptBeforeIndex) { _, val in
                                store.logAppEvent(.settingsChanged, detail: "Prompt before index \(val ? "enabled" : "disabled")")
                            }
                        Text("Shows a confirmation dialog before scanning any newly connected drive.")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                    }
                }

                settingsGroup("Alerts") {
                    settingsRow {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Warn when drive is full")
                                Spacer()
                                Text("\(Int(alertThresholdPct))%").foregroundStyle(.secondary).monospacedDigit()
                            }
                            Slider(value: $alertThresholdPct, in: 70...99, step: 5).tint(.purple)
                                .onChange(of: alertThresholdPct) { _, val in store.reload(); store.logAppEvent(.settingsChanged, detail: "Alert threshold: \(Int(val))%") }
                        }
                    }
                    settingsRow {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Warn if drive not seen for")
                                Spacer()
                                Text("\(Int(alertDaysUnseen)) day\(alertDaysUnseen != 1 ? "s" : "")").foregroundStyle(.secondary).monospacedDigit()
                            }
                            Slider(value: $alertDaysUnseen, in: 1...30, step: 1).tint(.purple)
                                .onChange(of: alertDaysUnseen) { _, val in store.reload(); store.logAppEvent(.settingsChanged, detail: "Alert days unseen: \(Int(val)) days") }
                        }
                    }
                }

                settingsGroup("Excluded Drives") {
                    settingsRow {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Drives in this list will never be indexed.")
                                .font(.caption).foregroundStyle(.secondary)
                            if excludedDrives.isEmpty {
                                Text("All drives are currently eligible for indexing")
                                    .font(.callout).foregroundStyle(.tertiary).padding(.vertical, 4)
                            } else {
                                ForEach(excludedDrives, id: \.self) { name in
                                    HStack {
                                        Label(name, systemImage: "externaldrive").font(.callout)
                                        Spacer()
                                        Button { removeExcluded(name) } label: {
                                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                            if showAddExcluded {
                                HStack {
                                    TextField("Drive name e.g. Backup", text: $newExcludedDrive)
                                        .textFieldStyle(.roundedBorder)
                                    Button("Add") { addExcluded() }.disabled(newExcludedDrive.isEmpty)
                                    Button("Cancel") { showAddExcluded = false; newExcludedDrive = "" }
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Button { showAddExcluded = true } label: {
                                    Label("Add excluded drive", systemImage: "plus.circle").font(.callout)
                                }
                                .buttonStyle(.plain).foregroundStyle(.purple)
                            }
                        }
                    }
                }

                settingsGroup("Security") {
                    settingsRow {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("App Passcode")
                                    .font(.callout)
                                Text(pm.isPasscodeEnabled ? "Passcode is enabled · \(pm.passcodeLength)-digit" : "Protect sensitive areas with a passcode")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if pm.isPasscodeEnabled {
                                Button("Change") { showPasscodeChange = true }
                                    .buttonStyle(.bordered).controlSize(.small)
                                Button("Disable") { showPasscodeDisable = true }
                                    .buttonStyle(.bordered).controlSize(.small)
                                    .foregroundStyle(.red)
                            } else {
                                Button("Set up passcode") { showPasscodeSetup = true }
                                    .buttonStyle(.borderedProminent).tint(.purple).controlSize(.small)
                            }
                        }
                    }
                    if pm.isPasscodeEnabled && pm.biometricsAvailable {
                        settingsRow {
                            Toggle("Use \(pm.biometricType) to unlock", isOn: Binding(
                                get: { pm.isBiometricsEnabled },
                                set: { pm.enableBiometrics($0) }
                            ))
                            Text("Use \(pm.biometricType) as an alternative to your passcode.")
                                .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                        }
                    }
                }

                settingsGroup("Database") {
                    settingsRow {
                        LabeledContent("Location") {
                            Text(dbPath).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    // Snapshots
                    if !snapshots.isEmpty {
                        settingsRow {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Available backups")
                                    .font(.caption).foregroundStyle(.secondary)
                                ForEach(snapshots) { snap in
                                    HStack {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .foregroundStyle(.purple)
                                        Text(snap.displayName)
                                            .font(.callout)
                                        Spacer()
                                        Button("Restore") { showRestoreConfirm = snap }
                                            .buttonStyle(.bordered).controlSize(.small)
                                    }
                                }
                            }
                        }
                    }
                    settingsRow {
                        HStack {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dbPath)])
                            }
                            .buttonStyle(.link)
                            Spacer()
                            Button("Reset Database…") { showDBResetConfirm = true }
                                .foregroundStyle(.orange).buttonStyle(.link)
                            Button("Reset App…") { showAppResetConfirm = true }
                                .foregroundStyle(.red).buttonStyle(.link)
                        }
                    }
                    settingsRow {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Reset Database").font(.callout.bold())
                            Text("Deletes all indexed drive, shoot, and folder data. Activity log and settings are preserved.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    settingsRow {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Reset App").font(.callout.bold())
                            Text("Deletes everything including activity log and all settings. Returns app to a clean install state.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                settingsGroup("About") {
                    settingsRow { LabeledContent("Version", value: appVersion) }
                    settingsRow { LabeledContent("Build",   value: appBuild) }
                    settingsRow {
                        HStack {
                            Link("drivevault.app", destination: URL(string: "https://drivevault.app")!)
                            Spacer()
                            Link("Send feedback", destination: URL(string: "mailto:support@drivevault.app")!)
                        }
                        .font(.callout)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Settings")

        // MARK: Passcode Sheets
        .sheet(isPresented: $showPasscodeSetup) {
            PasscodeSetupView(mode: .create) { showPasscodeSetup = false }
        }
        .sheet(isPresented: $showPasscodeChange) {
            PasscodeSetupView(mode: .change) { showPasscodeChange = false }
        }
        .sheet(isPresented: $showPasscodeDisable) {
            PasscodeSetupView(mode: .disable) { showPasscodeDisable = false }
        }
        .confirmationDialog(
            "Restore from backup?",
            isPresented: Binding(get: { showRestoreConfirm != nil }, set: { if !$0 { showRestoreConfirm = nil } }),
            titleVisibility: .visible
        ) {
            if let snap = showRestoreConfirm {
                Button("Restore \(snap.displayName)", role: .destructive) {
                    store.db.restoreSnapshot(snap)
                    store.reload()
                    showRestoreConfirm = nil
                }
            }
            Button("Cancel", role: .cancel) { showRestoreConfirm = nil }
        } message: {
            Text("This will replace your current database with the selected backup. Current data will be lost.")
        }
        .onAppear { snapshots = store.db.fetchSnapshots() }

        // MARK: Database Reset
        .confirmationDialog("Reset Database?", isPresented: $showDBResetConfirm, titleVisibility: .visible) {
            Button("Yes, Continue", role: .destructive) { showDBResetFinal = true; resetConfirmText = "" }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all drives, shoots, and folders. Activity log and settings are preserved.")
        }
        .sheet(isPresented: $showDBResetFinal) {
            resetSheet(
                title: "Reset Database",
                message: "Type **RESET** to permanently delete all indexed data. Activity log and settings will be kept.",
                confirmText: $resetConfirmText,
                onCancel: { showDBResetFinal = false; resetConfirmText = "" },
                onConfirm: {
                    showDBResetFinal = false
                    resetConfirmText = ""
                    resetDatabase()
                }
            )
        }

        // MARK: App Reset
        .confirmationDialog("Reset Entire App?", isPresented: $showAppResetConfirm, titleVisibility: .visible) {
            Button("Yes, Continue", role: .destructive) { showAppResetFinal = true; resetConfirmText = "" }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete ALL data including activity log and settings. This cannot be undone.")
        }
        .sheet(isPresented: $showAppResetFinal) {
            resetSheet(
                title: "Reset Entire App",
                message: "Type **RESET** to permanently delete everything. This cannot be undone.",
                confirmText: $resetConfirmText,
                onCancel: { showAppResetFinal = false; resetConfirmText = "" },
                onConfirm: {
                    showAppResetFinal = false
                    resetConfirmText = ""
                    resetApp()
                }
            )
        }
    }

    // MARK: Reset Sheet

    private func resetSheet(
        title: String,
        message: String,
        confirmText: Binding<String>,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40)).foregroundStyle(.red)
            Text(title).font(.title2.bold())
            Text(.init(message))
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 300)
            TextField("Type RESET to confirm", text: confirmText)
                .textFieldStyle(.roundedBorder).frame(width: 200)
            HStack(spacing: 12) {
                Button("Cancel", action: onCancel).buttonStyle(.bordered)
                Button("Confirm") { onConfirm() }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(confirmText.wrappedValue != "RESET")
            }
        }
        .padding(32).frame(width: 400)
    }

    // MARK: Actions

    private func addExcluded() {
        let name = newExcludedDrive.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var list = excludedDrives
        if !list.contains(name) { list.append(name) }
        excludedDrivesRaw = list.joined(separator: ",")
        newExcludedDrive = ""; showAddExcluded = false
    }

    private func removeExcluded(_ name: String) {
        excludedDrivesRaw = excludedDrives.filter { $0 != name }.joined(separator: ",")
    }

    private func resetDatabase() {
        store.logAppEvent(.databaseReset, detail: "All index data deleted. Activity log preserved.")
        try? FileManager.default.removeItem(atPath: dbPath)
        UserDefaults.standard.removeObject(forKey: "fv.snoozed")
        store.reload()
    }

    private func resetApp() {
        store.logAppEvent(.appReset, detail: "Full app reset. All data and settings deleted.")
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("Drive Vault")
        try? FileManager.default.removeItem(at: appSupport)
        // Clear all UserDefaults
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        store.reload()
    }

    private var dbPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Drive Vault/drivevault.sqlite").path
    }

    private var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
    private var appBuild: String    { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1" }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .textCase(.uppercase).tracking(0.5)
                .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 6)
            VStack(spacing: 0) { content() }
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
        }
    }

    private func settingsRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading) { content() }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Divider().padding(.leading, 16) }
    }
}
