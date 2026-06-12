import Foundation
import SQLite

final class DatabaseManager {

    private let db: Connection
    private let activityDB: Connection
    private let queue = DispatchQueue(label: "DriveVault.DatabaseQueue")

    // MARK: - Tables & Columns

    private let drivesTable      = Table("drives")
    private let colDriveID       = Expression<String>("id")
    private let colDriveName     = Expression<String>("name")
    private let colDriveTotal    = Expression<Int64?>("total_bytes")
    private let colDriveUsed     = Expression<Int64?>("used_bytes")
    private let colDriveOnline   = Expression<Bool>("is_online")
    private let colDriveConn     = Expression<String?>("connection_type")
    private let colDriveType     = Expression<String?>("drive_type")
    private let colDriveLastSeen = Expression<Date?>("last_seen_at")

    private let shootsTable        = Table("shoots")
    private let colShootID         = Expression<Int64>("id")
    private let colShootDriveID    = Expression<String>("drive_id")
    private let colShootName       = Expression<String>("name")
    private let colShootScanned    = Expression<Date>("scanned_at")
    private let colShootCreated    = Expression<Date?>("created_at")
    private let colShootTotal      = Expression<Int64>("total_bytes")

    private let foldersTable       = Table("folders")
    private let colFolderID        = Expression<Int64>("id")
    private let colFolderShootID   = Expression<Int64>("shoot_id")
    private let colFolderParentID  = Expression<Int64?>("parent_id")
    private let colFolderName      = Expression<String>("name")
    private let colFolderSize      = Expression<Int64>("size_bytes")
    private let colFolderScanned   = Expression<Date>("scanned_at")
    private let colFolderFileCount = Expression<Int64>("file_count")
    private let colFolderDepth     = Expression<Int64>("depth")
    private let colFolderFileTypes = Expression<String?>("file_types")

    private let activityTable    = Table("activity_log")
    private let colActivityID    = Expression<Int64>("id")
    private let colActivityKind  = Expression<String>("kind")
    private let colActivityTitle = Expression<String>("title")
    private let colActivitySub   = Expression<String>("subtitle")
    private let colActivityAt    = Expression<Date>("occurred_at")

    private let appEventsTable     = Table("app_events")
    private let colAppEventID      = Expression<Int64>("id")
    private let colAppEventKind    = Expression<String>("kind")
    private let colAppEventDetail  = Expression<String>("detail")
    private let colAppEventAt      = Expression<Date>("occurred_at")

    // MARK: - Init

    init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Drive Vault", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let dbPath       = appSupport.appendingPathComponent("drivevault.sqlite").path
        let activityPath = appSupport.appendingPathComponent("activity.sqlite").path

        do {
            db         = try Connection(dbPath)
            activityDB = try Connection(activityPath)
            db.busyTimeout         = 5
            activityDB.busyTimeout = 5
            try createSchema()
            try createActivitySchema()
        } catch {
            fatalError("Drive Vault: Failed to open database: \(error)")
        }
    }

    // MARK: - Schema

    private func createSchema() throws {
        try db.run(drivesTable.create(ifNotExists: true) { t in
            t.column(colDriveID, primaryKey: true)
            t.column(colDriveName)
            t.column(colDriveTotal)
            t.column(colDriveUsed)
            t.column(colDriveOnline, defaultValue: false)
            t.column(colDriveConn)
            t.column(colDriveType)
            t.column(colDriveLastSeen)
        })

        try db.run(shootsTable.create(ifNotExists: true) { t in
            t.column(colShootID, primaryKey: .autoincrement)
            t.column(colShootDriveID)
            t.column(colShootName)
            t.column(colShootScanned)
            t.column(colShootCreated)
            t.column(colShootTotal, defaultValue: 0)
        })

        let shootColumns = (try? db.prepare("PRAGMA table_info(shoots)").map { $0[1] as? String ?? "" }) ?? []
        if !shootColumns.contains("created_at") {
            try? db.run("ALTER TABLE shoots ADD COLUMN created_at REAL")
        }

        try db.run(foldersTable.create(ifNotExists: true) { t in
            t.column(colFolderID, primaryKey: .autoincrement)
            t.column(colFolderShootID)
            t.column(colFolderParentID)
            t.column(colFolderName)
            t.column(colFolderSize, defaultValue: 0)
            t.column(colFolderScanned)
            t.column(colFolderFileCount, defaultValue: 0)
            t.column(colFolderDepth, defaultValue: 0)
        })

        let folderColumns = (try? db.prepare("PRAGMA table_info(folders)").map { $0[1] as? String ?? "" }) ?? []
        if !folderColumns.contains("file_count") {
            try? db.run("ALTER TABLE folders ADD COLUMN file_count INTEGER DEFAULT 0")
        }
        if !folderColumns.contains("parent_id") {
            try? db.run("ALTER TABLE folders ADD COLUMN parent_id INTEGER")
        }
        if !folderColumns.contains("depth") {
            try? db.run("ALTER TABLE folders ADD COLUMN depth INTEGER DEFAULT 0")
        }
        if !folderColumns.contains("file_types") {
            try? db.run("ALTER TABLE folders ADD COLUMN file_types TEXT")
        }

        try db.run(shootsTable.createIndex(colShootDriveID, ifNotExists: true))
        try db.run(foldersTable.createIndex(colFolderShootID, ifNotExists: true))

        // One-time migration: force rescan of shoots missing file counts
        try? db.run(
            "UPDATE shoots SET scanned_at = '2000-01-01T00:00:00.000' " +
            "WHERE id IN (SELECT DISTINCT shoot_id FROM folders WHERE file_count = 0)"
        )
    }

    private func createActivitySchema() throws {
        try activityDB.run(activityTable.create(ifNotExists: true) { t in
            t.column(colActivityID, primaryKey: .autoincrement)
            t.column(colActivityKind)
            t.column(colActivityTitle)
            t.column(colActivitySub)
            t.column(colActivityAt)
        })
        try activityDB.run(activityTable.createIndex(colActivityAt, ifNotExists: true))

        // App-level events table — persists across DB resets
        try activityDB.run(appEventsTable.create(ifNotExists: true) { t in
            t.column(colAppEventID, primaryKey: .autoincrement)
            t.column(colAppEventKind)
            t.column(colAppEventDetail)
            t.column(colAppEventAt)
        })
        try activityDB.run(appEventsTable.createIndex(colAppEventAt, ifNotExists: true))
    }

    // MARK: - DB Health Check

    func runHealthCheck() {
        queue.async {
            let systemIDs: Set<String> = [
                "home", "iSCPreboot", "xarts", "Hardware", "mnt1",
                "Preboot", "Recovery", "VM", "Update", "Data",
                "com.apple.TimeMachineBackupMountPoint",
                "Drive Vault", "DriveVault", "Claude"
            ]
            for id in systemIDs {
                self.deleteAllDataForDrive(id)
            }

            let allDriveIDs = (try? self.db.prepare(self.drivesTable)
                .map { $0[self.colDriveID] }) ?? []
            for id in allDriveIDs where id.hasPrefix("com.apple") || id.hasPrefix(".") || id == "/" {
                self.deleteAllDataForDrive(id)
            }

            let driveIDs = Set((try? self.db.prepare(self.drivesTable)
                .map { $0[self.colDriveID] }) ?? [])
            let allShoots = (try? self.db.prepare(self.shootsTable)
                .map { (id: $0[self.colShootID], driveID: $0[self.colShootDriveID]) }) ?? []
            for shoot in allShoots where !driveIDs.contains(shoot.driveID) {
                try? self.db.run(self.foldersTable.filter(self.colFolderShootID == shoot.id).delete())
                try? self.db.run(self.shootsTable.filter(self.colShootID == shoot.id).delete())
            }

            let shootIDs = Set((try? self.db.prepare(self.shootsTable)
                .map { $0[self.colShootID] }) ?? [])
            let allFolderShootIDs = (try? self.db.prepare(self.foldersTable)
                .map { $0[self.colFolderShootID] }) ?? []
            for shootID in Set(allFolderShootIDs) where !shootIDs.contains(shootID) {
                try? self.db.run(self.foldersTable.filter(self.colFolderShootID == shootID).delete())
            }

            try? self.db.run(
                "UPDATE shoots SET scanned_at = '2000-01-01T00:00:00.000' " +
                "WHERE id IN (SELECT DISTINCT shoot_id FROM folders WHERE file_count = 0)"
            )
        }
    }

    private func deleteAllDataForDrive(_ driveID: String) {
        let shootIDs = (try? db.prepare(
            shootsTable.filter(colShootDriveID == driveID)
        ).map { $0[colShootID] }) ?? []
        for shootID in shootIDs {
            try? db.run(foldersTable.filter(colFolderShootID == shootID).delete())
        }
        try? db.run(shootsTable.filter(colShootDriveID == driveID).delete())
        try? db.run(drivesTable.filter(colDriveID == driveID).delete())
    }

    // MARK: - Drives

    func fetchAllDrives() -> [Drive] {
        queue.sync {
            (try? db.prepare(drivesTable).map(rowToDrive)) ?? []
        }
    }

    private func isSystemVolume(_ id: String) -> Bool {
        let systemIDs: Set<String> = [
            "home", "iSCPreboot", "xarts", "Hardware", "mnt1",
            "Preboot", "Recovery", "VM", "Update", "Data",
            "com.apple.TimeMachineBackupMountPoint",
            "Drive Vault", "DriveVault", "Claude"
        ]
        return systemIDs.contains(id) ||
               id.hasPrefix("com.apple") ||
               id.hasPrefix(".") ||
               id == "/" ||
               id.isEmpty
    }

    func upsertDrive(_ drive: Drive) {
        guard !isSystemVolume(drive.id) else { return }
        queue.async {
            try? self.db.run(self.drivesTable.insert(or: .replace,
                self.colDriveID       <- drive.id,
                self.colDriveName     <- drive.name,
                self.colDriveTotal    <- drive.totalBytes,
                self.colDriveUsed     <- drive.usedBytes,
                self.colDriveOnline   <- drive.isOnline,
                self.colDriveConn     <- drive.connectionType,
                self.colDriveType     <- drive.driveType,
                self.colDriveLastSeen <- drive.lastSeenAt
            ))
        }
    }

    func markDriveOnline(serial: String) {
        guard !isSystemVolume(serial) else { return }
        queue.async {
            let row = self.drivesTable.filter(self.colDriveID == serial)
            try? self.db.run(row.update(self.colDriveOnline <- true, self.colDriveLastSeen <- Date()))
        }
    }

    func markDriveOffline(serial: String) {
        queue.async {
            let row = self.drivesTable.filter(self.colDriveID == serial)
            try? self.db.run(row.update(self.colDriveOnline <- false))
        }
    }

    func markAllDrivesOffline() {
        queue.async {
            try? self.db.run(self.drivesTable.update(self.colDriveOnline <- false))
        }
    }

    func deleteDrive(id: String) {
        queue.async {
            let shootIDs = (try? self.db.prepare(
                self.shootsTable.filter(self.colShootDriveID == id)
            ).map { $0[self.colShootID] }) ?? []
            for shootID in shootIDs {
                try? self.db.run(self.foldersTable.filter(self.colFolderShootID == shootID).delete())
            }
            try? self.db.run(self.shootsTable.filter(self.colShootDriveID == id).delete())
            try? self.db.run(self.drivesTable.filter(self.colDriveID == id).delete())
        }
    }

    func isDriveFirstIndex(id: String) -> Bool {
        queue.sync {
            let count = (try? db.scalar(shootsTable.filter(colShootDriveID == id).count)) ?? 0
            return count == 0
        }
    }

    // FIX: Resets scanned_at to epoch zero for all shoots on a drive so the
    // mod-date incremental check in IndexEngine always fails and every shoot
    // gets a full re-scan. Called by forceReindex in AppStore.
    func clearShootScanDates(for driveID: String) {
        queue.async {
            let epoch = Date(timeIntervalSince1970: 0)
            let rows = self.shootsTable.filter(self.colShootDriveID == driveID)
            try? self.db.run(rows.update(self.colShootScanned <- epoch))
        }
    }

    private func rowToDrive(_ row: Row) -> Drive {
        Drive(
            id: row[colDriveID],
            name: row[colDriveName],
            totalBytes: row[colDriveTotal],
            usedBytes: row[colDriveUsed],
            isOnline: row[colDriveOnline],
            connectionType: row[colDriveConn],
            driveType: row[colDriveType],
            lastSeenAt: row[colDriveLastSeen]
        )
    }

    // MARK: - Shoots

    func fetchAllShoots() -> [Shoot] {
        queue.sync {
            (try? db.prepare(shootsTable).map(rowToShoot)) ?? []
        }
    }

    func fetchShoots(for driveID: String) -> [Shoot] {
        queue.sync {
            let q = shootsTable.filter(colShootDriveID == driveID)
            return (try? db.prepare(q).map(rowToShoot)) ?? []
        }
    }

    func existingShootNames(for driveID: String) -> [String: (id: Int64, totalBytes: Int64, scannedAt: Date)] {
        queue.sync {
            let q = shootsTable.filter(colShootDriveID == driveID)
            var result: [String: (id: Int64, totalBytes: Int64, scannedAt: Date)] = [:]
            if let rows = try? db.prepare(q) {
                for row in rows {
                    result[row[colShootName]] = (
                        id: row[colShootID],
                        totalBytes: row[colShootTotal],
                        scannedAt: row[colShootScanned]
                    )
                }
            }
            return result
        }
    }

    @discardableResult
    func insertShoot(driveID: String, name: String, scannedAt: Date, totalBytes: Int64, createdAt: Date? = nil) -> Int64 {
        guard !isSystemVolume(driveID) else { return -1 }
        return queue.sync {
            let existing = shootsTable.filter(colShootDriveID == driveID && colShootName == name)
            if let row = try? db.pluck(existing) {
                let keepCreated = row[colShootCreated] ?? createdAt
                try? db.run(existing.update(
                    colShootTotal   <- totalBytes,
                    colShootScanned <- scannedAt,
                    colShootCreated <- keepCreated
                ))
                return row[colShootID]
            }
            return (try? db.run(shootsTable.insert(
                colShootDriveID <- driveID,
                colShootName    <- name,
                colShootScanned <- scannedAt,
                colShootCreated <- createdAt,
                colShootTotal   <- totalBytes
            ))) ?? -1
        }
    }

    func updateShootScanDate(id: Int64, scannedAt: Date) {
        queue.async {
            let row = self.shootsTable.filter(self.colShootID == id)
            try? self.db.run(row.update(self.colShootScanned <- scannedAt))
        }
    }

    func updateShootCreatedAt(id: Int64, createdAt: Date) {
        queue.async {
            let row = self.shootsTable.filter(self.colShootID == id && self.colShootCreated == Date?.none)
            try? self.db.run(row.update(self.colShootCreated <- createdAt))
        }
    }

    nonisolated func deleteShoot(id: Int64) {
        queue.async {
            try? self.db.run(self.foldersTable.filter(self.colFolderShootID == id).delete())
            try? self.db.run(self.shootsTable.filter(self.colShootID == id).delete())
        }
    }

    private func rowToShoot(_ row: Row) -> Shoot {
        Shoot(
            id: row[colShootID],
            driveID: row[colShootDriveID],
            name: row[colShootName],
            scannedAt: row[colShootScanned],
            createdAt: row[colShootCreated] ?? row[colShootScanned],
            totalBytes: row[colShootTotal]
        )
    }

    // MARK: - Folders

    func fetchAllFolders() -> [DriveFolder] {
        queue.sync {
            (try? db.prepare(foldersTable).map(rowToFolder)) ?? []
        }
    }

    func fetchFolders(for shootID: Int64) -> [DriveFolder] {
        queue.sync {
            let q = foldersTable.filter(colFolderShootID == shootID).order(colFolderSize.desc)
            return (try? db.prepare(q).map(rowToFolder)) ?? []
        }
    }

    func replaceAllFolders(for shootID: Int64, folders: [(name: String, sizeBytes: Int64, scannedAt: Date, fileCount: Int64, parentID: Int64?, depth: Int64, fileTypes: String?)]) {
        queue.async {
            try? self.db.run(self.foldersTable.filter(self.colFolderShootID == shootID).delete())

            let sorted = folders.enumerated()
                .map { (originalIndex: $0.offset, folder: $0.element) }
                .sorted { $0.folder.depth < $1.folder.depth }

            var indexToRowID: [Int: Int64] = [:]

            for item in sorted {
                let realParentID: Int64? = item.folder.parentID.flatMap { indexToRowID[Int($0)] }
                if let rowid = try? self.db.run(self.foldersTable.insert(
                    self.colFolderShootID   <- shootID,
                    self.colFolderParentID  <- realParentID,
                    self.colFolderName      <- item.folder.name,
                    self.colFolderSize      <- item.folder.sizeBytes,
                    self.colFolderScanned   <- item.folder.scannedAt,
                    self.colFolderFileCount <- item.folder.fileCount,
                    self.colFolderDepth     <- item.folder.depth,
                    self.colFolderFileTypes <- item.folder.fileTypes
                )) {
                    indexToRowID[item.originalIndex] = rowid
                }
            }
        }
    }

    private func rowToFolder(_ row: Row) -> DriveFolder {
        DriveFolder(
            id: row[colFolderID],
            shootID: row[colFolderShootID],
            parentID: row[colFolderParentID],
            name: row[colFolderName],
            sizeBytes: row[colFolderSize],
            scannedAt: row[colFolderScanned],
            fileCount: row[colFolderFileCount],
            depth: Int(row[colFolderDepth]),
            fileTypes: row[colFolderFileTypes]
        )
    }

    // MARK: - Activity Log

    nonisolated func logActivity(kind: ActivityEvent.ActivityKind, title: String, subtitle: String) {
        queue.async {
            try? self.activityDB.run(self.activityTable.insert(
                self.colActivityKind  <- kind.rawValue,
                self.colActivityTitle <- title,
                self.colActivitySub   <- subtitle,
                self.colActivityAt    <- Date()
            ))
            // Keep full history — no pruning
        }
    }

    func logActivityWithDate(kind: ActivityEvent.ActivityKind, title: String, subtitle: String, date: Date) {
        queue.async {
            try? self.activityDB.run(self.activityTable.insert(
                self.colActivityKind  <- kind.rawValue,
                self.colActivityTitle <- title,
                self.colActivitySub   <- subtitle,
                self.colActivityAt    <- date
            ))
            // Keep full history — no pruning
        }
    }

    func fetchRecentActivity(limit: Int = 10000) -> [ActivityEvent] {
        queue.sync {
            let q = activityTable.order(colActivityAt.desc).limit(limit)
            return (try? activityDB.prepare(q).map { row in
                ActivityEvent(
                    id: row[colActivityID],
                    kind: ActivityEvent.ActivityKind(rawValue: row[colActivityKind]) ?? .folderAdded,
                    title: row[colActivityTitle],
                    subtitle: row[colActivitySub],
                    occurredAt: row[colActivityAt]
                )
            }) ?? []
        }
    }

    // MARK: - App Events

    /// Logs a one-time "app installed" event on very first launch.
    func logAppEventIfFirstLaunch() {
        queue.async {
            let count = (try? self.activityDB.scalar(self.appEventsTable.count)) ?? 0
            if count == 0 {
                try? self.activityDB.run(self.appEventsTable.insert(
                    self.colAppEventKind   <- AppEventKind.appInstalled.rawValue,
                    self.colAppEventDetail <- "Drive Vault installed",
                    self.colAppEventAt     <- Date()
                ))
            }
        }
    }

    func logAppEvent(kind: AppEventKind, detail: String) {
        queue.async {
            try? self.activityDB.run(self.appEventsTable.insert(
                self.colAppEventKind   <- kind.rawValue,
                self.colAppEventDetail <- detail,
                self.colAppEventAt     <- Date()
            ))
            // Also write to activity_log so it appears in ActivityLogView
            try? self.activityDB.run(self.activityTable.insert(
                self.colActivityKind  <- kind.rawValue,
                self.colActivityTitle <- kind.label,
                self.colActivitySub   <- detail,
                self.colActivityAt    <- Date()
            ))
        }
    }

    func fetchAppEvents() -> [AppEvent] {
        queue.sync {
            let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
            let q = appEventsTable
                .filter(colAppEventAt >= cutoff)
                .order(colAppEventAt.desc)
            return (try? activityDB.prepare(q).map { row in
                AppEvent(
                    id: row[colAppEventID],
                    kind: AppEventKind(rawValue: row[colAppEventKind]) ?? .settingsChanged,
                    detail: row[colAppEventDetail],
                    occurredAt: row[colAppEventAt]
                )
            }) ?? []
        }
    }

    func resetAppEvents() {
        queue.async {
            try? self.activityDB.run(self.appEventsTable.delete())
        }
    }

    func appInstallDate() -> Date? {
        queue.sync {
            let q = appEventsTable
                .filter(colAppEventKind == AppEventKind.appInstalled.rawValue)
                .order(colAppEventAt.asc)
                .limit(1)
            return (try? activityDB.pluck(q)).flatMap { $0[colAppEventAt] }
        }
    }

    // MARK: - Snapshots

    func createSnapshot() {
        guard let src = try? URL(fileURLWithPath: dbPath()) else { return }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("Drive Vault/Snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "snapshot_\(formatter.string(from: Date())).sqlite"
        let dst = appSupport.appendingPathComponent(name)

        try? FileManager.default.copyItem(at: src, to: dst)

        // Keep only last 3 snapshots
        let snapshots = fetchSnapshots()
        if snapshots.count > 3 {
            for old in snapshots.dropFirst(3) {
                try? FileManager.default.removeItem(at: old.url)
            }
        }
        print("📸 Snapshot created: \(name)")
    }

    func fetchSnapshots() -> [DatabaseSnapshot] {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("Drive Vault/Snapshots")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "sqlite" }
            .compactMap { url -> DatabaseSnapshot? in
                let attrs = try? url.resourceValues(forKeys: [.creationDateKey])
                let date = attrs?.creationDate ?? Date()
                return DatabaseSnapshot(url: url, createdAt: date)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func restoreSnapshot(_ snapshot: DatabaseSnapshot) {
        guard let dst = try? URL(fileURLWithPath: dbPath()) else { return }
        try? FileManager.default.removeItem(at: dst)
        try? FileManager.default.copyItem(at: snapshot.url, to: dst)
        print("♻️ Snapshot restored: \(snapshot.url.lastPathComponent)")
    }

    private func dbPath() -> String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Drive Vault/drivevault.sqlite").path
    }

    // MARK: - Search

    func searchShoots(query: String) -> [Shoot] {
        queue.sync {
            let pattern = "%\(query)%"
            let q = shootsTable.filter(colShootName.like(pattern))
            return (try? db.prepare(q).map(rowToShoot)) ?? []
        }
    }

    func searchShootsByDriveID(driveID: String) -> [Shoot] {
        queue.sync {
            let q = shootsTable.filter(colShootDriveID == driveID)
            return (try? db.prepare(q).map(rowToShoot)) ?? []
        }
    }
}
