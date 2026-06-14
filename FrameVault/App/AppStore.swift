import SwiftUI
import Combine

// MARK: - IndexingState

struct IndexingState {
    var driveID: String? = nil
    var progress: Double = 0
    var progressText: String = ""
    var isIndexing: Bool = false
}

// MARK: - AlertPreferences

struct AlertPreferences {
    static func ignoredIDs() -> Set<String> {
        let raw = UserDefaults.standard.string(forKey: "fv.ignoredAlerts") ?? ""
        return Set(raw.split(separator: ",").map(String.init))
    }

    static func snoozed() -> [String: Double] {
        let raw = UserDefaults.standard.string(forKey: "fv.snoozed") ?? ""
        return raw.split(separator: "|").reduce(into: [:]) { dict, pair in
            let parts = pair.split(separator: "=")
            if parts.count == 2, let val = Double(parts[1]) {
                dict[String(parts[0])] = val
            }
        }
    }

    static func saveSnoozed(_ dict: [String: Double]) {
        let raw = dict.map { "\($0.key)=\($0.value)" }.joined(separator: "|")
        UserDefaults.standard.set(raw, forKey: "fv.snoozed")
    }

    static func ignore(_ id: String) {
        var ignored = ignoredIDs()
        ignored.insert(id)
        UserDefaults.standard.set(ignored.joined(separator: ","), forKey: "fv.ignoredAlerts")
    }
}

// MARK: - AppStore

@MainActor
final class AppStore: ObservableObject {

    // MARK: Published State

    @Published var drives: [Drive] = []
    @Published var shoots: [Shoot] = []
    @Published var alerts: [AppAlert] = []
    @Published var workflows: [ClientWorkflow] = []
    @Published var recentActivity: [ActivityEvent] = []
    @Published var indexingState = IndexingState()
    @Published var appEvents: [AppEvent] = []
    var appInstallDate: Date? { db.appInstallDate() }
    @Published var showIndexPrompt: Bool = false
    @Published var pendingIndexURL: URL? = nil
    @Published var searchNavigationShootID: Int64? = nil
    @Published var searchNavigationClientKey: String? = nil
    @Published var workflowPromptGroup: ClientGroup? = nil

    @AppStorage("fv.autoIndexOnConnect") var autoIndexEnabled = true

    // MARK: Managers

    let db: DatabaseManager
    let accessManager = DriveAccessManager()
    private var driveMonitor: DriveMonitor?
    private var cancellables = Set<AnyCancellable>()
    private let indexEngine: IndexEngine

    // MARK: Internal State

    private var indexQueue: [URL] = []
    private var seenThisSession = Set<String>()
    private var pendingPromptQueue: [URL] = []

    // Tracks drives where user declined the index prompt this session.
    // These are removed from the app when disconnected and re-prompted when reconnected.
    private var declinedDrives = Set<String>()
    private var loggedConnectThisSession = Set<String>()

    // Debounce reload — prevents rapid-fire DB hits
    private var reloadTask: Task<Void, Never>? = nil

    private let skipNames: Set<String> = [
        "Macintosh HD", "Data", "Preboot", "Recovery", "VM", "Update",
        "com.apple.TimeMachineBackupMountPoint", "Hardware", "iSCPreboot",
        "mnt1", "xarts", "home", "Drive Vault", "DriveVault", "Claude"
    ]

    private var userExcludedDrives: [String] {
        (UserDefaults.standard.string(forKey: "fv.excludedDrives") ?? "")
            .split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: Init

    init() {
        self.db = DatabaseManager()
        self.indexEngine = IndexEngine(db: db)

        let monitor = DriveMonitor()
        self.driveMonitor = monitor

        monitor.driveConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] volumeURL in self?.handleDriveConnected(volumeURL) }
            .store(in: &cancellables)

        monitor.driveDisconnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] serial in self?.handleDriveDisconnected(serial) }
            .store(in: &cancellables)

        db.markAllDrivesOffline()
        db.logAppEventIfFirstLaunch()
        monitor.start()
        reloadImmediate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.forceScanAllVolumes()
            self.startWatchersForConnectedDrives()
        }

        setupDrivePolling()
    }

    // MARK: Helpers

    private func isValidDriveName(_ name: String) -> Bool {
        guard !skipNames.contains(name),
              !userExcludedDrives.contains(name),
              !name.hasPrefix("com.apple"),
              name != "/" else { return false }
        return true
    }

    private func startWatchersForConnectedDrives() {
        guard let mounts = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: .skipHiddenVolumes
        ) else { return }
        for url in mounts {
            let name = url.lastPathComponent
            guard isValidDriveName(name) else { continue }
            guard !db.isDriveFirstIndex(id: name) else { continue }
            let volumeURL = url
            Task {
                await indexEngine.startWatching(volumeURL: volumeURL) {
                    Task { @MainActor in
                        guard !self.indexingState.isIndexing else { return }
                        print("📂 FSEvents: change on \(name) — queuing re-scan")
                        self.indexDrive(volumeURL, force: true)
                    }
                }
            }
        }
    }

    private func setupDrivePolling() {
        Timer.publish(every: 10.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in Task { @MainActor in self?.checkDriveChanges() } }
            .store(in: &cancellables)
    }

    // MARK: Reload — debounced to prevent rapid-fire DB access

    func reload() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms debounce
            guard !Task.isCancelled else { return }
            reloadImmediate()
        }
    }

    private func reloadImmediate() {
        drives         = db.fetchAllDrives()
        shoots         = db.fetchAllShoots()
        recentActivity = db.fetchRecentActivity(limit: 100)
        appEvents      = db.fetchAppEvents()
        workflows      = db.fetchAllWorkflows()
        refreshAlerts()
    }

    // MARK: Drive Monitoring

    private func forceScanAllVolumes() {
        guard let mounts = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: .skipHiddenVolumes
        ) else { return }
        for url in mounts {
            let name = url.lastPathComponent
            guard isValidDriveName(name) else { continue }
            db.markDriveOnline(serial: name)
            handleDriveConnected(url)
        }
        reloadImmediate()
    }

    private func checkDriveChanges() {
        let mountedNames = FileManager.default
            .mountedVolumeURLs(includingResourceValuesForKeys: nil, options: .skipHiddenVolumes)?
            .map { $0.lastPathComponent } ?? []

        var didChange = false
        for drive in drives where !mountedNames.contains(drive.name) && drive.isOnline {
            db.markDriveOffline(serial: drive.id)
            seenThisSession.remove(drive.id)
            // If user declined index for this drive, remove it from app on disconnect
            if declinedDrives.contains(drive.id) {
                db.deleteDrive(id: drive.id)
                declinedDrives.remove(drive.id)
                print("🗑 Removed declined drive on disconnect: \(drive.id)")
            }
            didChange = true
        }
        if didChange { reload() }

        for name in mountedNames where isValidDriveName(name) {
            if let existing = drives.first(where: { $0.name == name }) {
                if !existing.isOnline {
                    db.markDriveOnline(serial: name)
                    reload()
                    handleDriveConnected(URL(fileURLWithPath: "/Volumes/\(name)"))
                }
            } else {
                handleDriveConnected(URL(fileURLWithPath: "/Volumes/\(name)"))
            }
        }
    }

    // MARK: Drive Connected

    func handleDriveConnected(_ volumeURL: URL) {
        let volumeName = volumeURL.lastPathComponent
        guard isValidDriveName(volumeName) else { return }

        print("🔌 connected: \(volumeName) | seen: \(seenThisSession.contains(volumeName))")

        let info = DriveMonitor.driveInfo(for: volumeURL)
        let (totalBytes, usedBytes): (Int64?, Int64?) = {
            guard let vals = try? volumeURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]) else { return (nil, nil) }
            let total = vals.volumeTotalCapacity.map(Int64.init)
            let free  = vals.volumeAvailableCapacity.map(Int64.init)
            return (total, total.flatMap { t in free.map { t - $0 } })
        }()
        db.upsertDrive(Drive(
            id: volumeName, name: volumeName,
            totalBytes: totalBytes, usedBytes: usedBytes,
            isOnline: true, connectionType: info.connectionType,
            driveType: info.driveType, lastSeenAt: Date()
        ))
        reload()

        guard !seenThisSession.contains(volumeName) else {
            print("⛔ already handled this session: \(volumeName)")
            return
        }

        let promptEnabled = UserDefaults.standard.bool(forKey: "fv.promptBeforeIndex")
        guard autoIndexEnabled || promptEnabled else {
            print("⚠️ both settings off — will retry when enabled")
            return
        }

        seenThisSession.insert(volumeName)
        print("✅ proceeding for: \(volumeName)")
        // Only log drive connected once per session per drive
        if !loggedConnectThisSession.contains(volumeName) {
            loggedConnectThisSession.insert(volumeName)
            logAppEvent(.driveConnected, detail: volumeName)
        }

        // Only prompt/index if drive has never been indexed
        let isFirstIndex = db.isDriveFirstIndex(id: volumeName)
        if !isFirstIndex && !declinedDrives.contains(volumeName) {
            print("✅ already indexed, starting watcher + incremental index for: \(volumeName)")
            indexDrive(volumeURL, force: true)
            return
        }

        if promptEnabled {
            if showIndexPrompt {
                pendingPromptQueue.append(volumeURL)
            } else {
                pendingIndexURL = volumeURL
                showIndexPrompt = true
            }
        } else {
            indexDrive(volumeURL)
        }
    }

    func declineIndexPrompt() {
        // Mark drive as declined — it will be removed from app when disconnected
        // and re-prompted as a new drive when reconnected
        if let url = pendingIndexURL {
            let name = url.lastPathComponent
            declinedDrives.insert(name)
            print("⏭ Index declined for: \(name) — will vanish on disconnect")
            logAppEvent(.indexSkipped, detail: "Index skipped for \(name)")
        }
        pendingIndexURL = nil
        showIndexPrompt = false
        processNextPrompt()
    }

    func confirmIndexPrompt() {
        guard let url = pendingIndexURL else { return }
        pendingIndexURL = nil
        showIndexPrompt = false
        indexDrive(url, force: true)
        processNextPrompt()
    }

    private func processNextPrompt() {
        guard !pendingPromptQueue.isEmpty else { return }
        let next = pendingPromptQueue.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.pendingIndexURL = next
            self.showIndexPrompt = true
        }
    }

    private func handleDriveDisconnected(_ serial: String) {
        let mountedNames = FileManager.default
            .mountedVolumeURLs(includingResourceValuesForKeys: nil, options: .skipHiddenVolumes)?
            .map { $0.lastPathComponent } ?? []

        for drive in db.fetchAllDrives() where !mountedNames.contains(drive.name) {
            db.markDriveOffline(serial: drive.id)
            seenThisSession.remove(drive.id)
            // Remove declined drives so they re-prompt next connection
            if declinedDrives.contains(drive.id) {
                db.deleteDrive(id: drive.id)
                declinedDrives.remove(drive.id)
                print("🗑 Removed declined drive: \(drive.id)")
            }
        }
        Task { await indexEngine.stopWatching(volumeURL: URL(fileURLWithPath: "/Volumes/\(serial)")) }
        seenThisSession.remove(serial)
        loggedConnectThisSession.remove(serial)
        logAppEvent(.driveDisconnected, detail: serial)
        reload()
    }

    // MARK: Indexing

    func indexDrive(_ volumeURL: URL, force: Bool = false) {
        let serial = volumeURL.lastPathComponent
        db.markDriveOnline(serial: serial)
        reload()

        guard autoIndexEnabled || force else { return }
        guard !indexQueue.contains(volumeURL) else { return }

        indexQueue.append(volumeURL)
        processIndexQueue()
    }

    private func processIndexQueue() {
        guard !indexingState.isIndexing, let volumeURL = indexQueue.first else { return }
        indexQueue.removeFirst()

        let serial = volumeURL.lastPathComponent
        indexingState = IndexingState(driveID: serial, progress: 0, progressText: "", isIndexing: true)

        indexEngine.onProgress = { completed, total in
            Task { @MainActor in
                let pct = total > 0 ? Double(completed) / Double(total) : 0
                self.indexingState.progress = pct
                self.indexingState.progressText = "\(completed) / \(total) shoots"
            }
        }

        Task {
            await indexEngine.index(volumeURL: volumeURL)
            await MainActor.run {
                self.indexingState = IndexingState()
                self.db.markDriveOnline(serial: serial)
                // Delay reload to let background DB writes commit
                self.logAppEvent(.indexComplete, detail: self.db.isDriveFirstIndex(id: serial) ? "\(serial) — Full index complete" : "\(serial) — Incremental index complete")
                // Check for 500GB+ clients needing workflow
                self.checkWorkflowPrompts()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.reloadImmediate()
                }
                // Start FSEvents watcher — but only re-index if NOT currently indexing
                // and debounce to avoid re-indexing during large file copies
                Task {
                    await self.indexEngine.startWatching(volumeURL: volumeURL) {
                        Task { @MainActor in
                            guard !self.indexingState.isIndexing else {
                                print("📂 FSEvents: change on \(serial) — skipped, already indexing")
                                return
                            }
                            print("📂 FSEvents: change on \(serial) — queuing re-scan")
                            self.indexDrive(volumeURL, force: true)
                        }
                    }
                }
                self.processIndexQueue()
            }
        }
    }

    func removeDrive(_ drive: Drive) {
        seenThisSession.remove(drive.id)
        declinedDrives.remove(drive.id)
        logAppEvent(.driveRemoved, detail: drive.name)
        db.deleteDrive(id: drive.id)
        reload()
    }

    func forceReindex(drive: Drive) {
        db.clearShootScanDates(for: drive.id)
        seenThisSession.remove(drive.id)
        db.logActivity(kind: .reindexed, title: "\(drive.name) re-indexed", subtitle: "Manual re-index triggered")
        if let url = DriveMonitor.mountedURL(for: drive.name) {
            indexDrive(url, force: true)
        }
    }

    // MARK: App Events

    // MARK: - Workflow

    func checkWorkflowPrompts() {
        let existingNames = Set(workflows.map { $0.clientName })
        let skipped = Set(
            clientGroups.map { "wf_skip_\($0.displayName)" }
                .filter { UserDefaults.standard.bool(forKey: $0) }
        )
        for group in clientGroups {
            let skipKey = "wf_skip_\(group.displayName)"
            guard group.totalBytes >= 500 * 1024 * 1024 * 1024 else { continue }
            guard !existingNames.contains(group.displayName) else { continue }
            guard !UserDefaults.standard.bool(forKey: skipKey) else { continue }
            DispatchQueue.main.async {
                self.workflowPromptGroup = group
            }
            break // one prompt at a time
        }
    }

    func workflow(for group: ClientGroup) -> ClientWorkflow? {
        workflows.first { $0.clientName == group.displayName }
    }

    func saveWorkflow(_ wf: ClientWorkflow) {
        db.saveWorkflow(wf)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.workflows = self.db.fetchAllWorkflows()
        }
    }

    func deleteWorkflow(for group: ClientGroup) {
        db.deleteWorkflow(for: group.displayName)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.workflows = self.db.fetchAllWorkflows()
        }
    }

    func logAppEvent(_ kind: AppEventKind, detail: String = "") {
        db.logAppEvent(kind: kind, detail: detail)
        appEvents = db.fetchAppEvents()
    }

    func resetAppEvents() {
        db.resetAppEvents()
        appEvents = []
    }

    // MARK: Alerts

    func ignoreAlert(_ alert: AppAlert) {
        AlertPreferences.ignore(alert.id)
        reload()
    }

    func snoozeAlert(_ alert: AppAlert, days: Int) {
        let until = Date().addingTimeInterval(Double(days) * 86400)
        var snoozed = AlertPreferences.snoozed()
        snoozed[alert.id] = until.timeIntervalSince1970
        AlertPreferences.saveSnoozed(snoozed)
        reload()
    }

    private func refreshAlerts() {
        var newAlerts: [AppAlert] = []
        let thresholdPct   = UserDefaults.standard.double(forKey: "fv.alertThresholdPct")
        let alertThreshold = thresholdPct > 0 ? thresholdPct / 100.0 : 0.90
        let daysUnseen     = UserDefaults.standard.double(forKey: "fv.alertDaysUnseen")
        let alertDays      = daysUnseen > 0 ? Int(daysUnseen) : 3

        for drive in drives {
            if let total = drive.totalBytes, let used = drive.usedBytes, total > 0 {
                let pct = Double(used) / Double(total)
                if pct >= alertThreshold {
                    newAlerts.append(AppAlert(
                        id: "full-\(drive.id)", kind: .warning,
                        title: "\(drive.name) is \(Int(pct * 100))% full",
                        subtitle: "\(ByteCountFormatter.string(fromByteCount: total - used, countStyle: .file)) remaining"
                    ))
                }
            }
            if !drive.isOnline, let lastSeen = drive.lastSeenAt {
                let days = Calendar.current.dateComponents([.day], from: lastSeen, to: Date()).day ?? 0
                if days >= alertDays {
                    newAlerts.append(AppAlert(
                        id: "unseen-\(drive.id)", kind: .info,
                        title: "\(drive.name) not seen for \(days) days",
                        subtitle: "Last connected \(lastSeen.formatted(date: .abbreviated, time: .omitted))"
                    ))
                }
            }
        }

        let snoozed = AlertPreferences.snoozed()
        let ignored = AlertPreferences.ignoredIDs()
        let now     = Date().timeIntervalSince1970
        alerts = newAlerts.filter { alert in
            guard !ignored.contains(alert.id) else { return false }
            guard let until = snoozed[alert.id] else { return true }
            return now > until
        }
    }

    // MARK: Queries

    func shoots(for drive: Drive) -> [Shoot] {
        shoots.filter { $0.driveID == drive.id }
    }

    func folders(for shoot: Shoot) -> [DriveFolder] {
        db.fetchFolders(for: shoot.id)
    }

    var clientGroups: [ClientGroup] {
        let grouped = Dictionary(grouping: shoots) { ClientGroup.rootKey(from: $0.name) }
        return grouped.map { ClientGroup(key: $0.key, shoots: $0.value) }.sorted { $0.key < $1.key }
    }
}
