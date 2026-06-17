import Foundation

/// IndexEngine — reliable single-pass indexing
actor IndexEngine {

    private let db: DatabaseManager

    nonisolated(unsafe) var onProgress: ((Int, Int) -> Void)? = nil

    func setProgressHandler(_ handler: @escaping (Int, Int) -> Void) {
        onProgress = handler
    }

    private let systemFolders: Set<String> = [
        ".Spotlight-V100", ".Trashes", ".fseventsd",
        ".DocumentRevisions-V100", ".TemporaryItems",
        "System Volume Information"
    ]

    private let maxDepth: Int
    private let batchSize: Int
    private var fsWatchers: [String: DriveWatcher] = [:]

    init(db: DatabaseManager, maxDepth: Int = 3, batchSize: Int = 32) {
        self.db = db
        self.maxDepth = maxDepth
        self.batchSize = batchSize
    }

    // MARK: - FSEvents

    func startWatching(volumeURL: URL, onChange: @escaping () -> Void) {
        let key = volumeURL.path
        guard fsWatchers[key] == nil else { return }
        let watcher = DriveWatcher(url: volumeURL, onChange: onChange)
        watcher.start()
        fsWatchers[key] = watcher
        print("👁 FSEvents watching: \(volumeURL.lastPathComponent)")
    }

    func stopWatching(volumeURL: URL) {
        let key = volumeURL.path
        fsWatchers[key]?.stop()
        fsWatchers.removeValue(forKey: key)
        print("👁 FSEvents stopped: \(volumeURL.lastPathComponent)")
    }

    func stopAllWatchers() {
        fsWatchers.values.forEach { $0.stop() }
        fsWatchers.removeAll()
    }

    // MARK: - Result types

    private struct ShootResult {
        let name: String
        let itemURL: URL
        let action: ShootAction
    }

    private enum ShootAction {
        case skip
        case update(existing: (id: Int64, totalBytes: Int64, scannedAt: Date),
                    subfolders: [DriveFolder],
                    totalBytes: Int64,
                    createdDate: Date)
        case insert(subfolders: [DriveFolder],
                    totalBytes: Int64,
                    createdDate: Date)
    }

    // MARK: - Public API

    func index(volumeURL: URL) async {
        guard !Task.isCancelled else { return }

        let fm     = FileManager.default
        let now    = Date()
        let serial = volumeURL.lastPathComponent

        let (totalBytes, usedBytes) = diskUsage(for: volumeURL)
        let info = DriveMonitor.driveInfo(for: volumeURL)
        db.upsertDrive(Drive(
            id: serial, name: serial,
            totalBytes: totalBytes, usedBytes: usedBytes,
            isOnline: true, connectionType: info.connectionType,
            driveType: info.driveType, lastSeenAt: now
        ))

        let existingShootMap = db.existingShootNames(for: serial)
        var scannedNames = Set<String>()

        guard let topLevel = try? fm.contentsOfDirectory(
            at: volumeURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey,
                                         .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let shootDirs = topLevel.filter {
            let name = $0.lastPathComponent
            return !systemFolders.contains(name) && !name.hasPrefix(".") && isDirectory($0)
        }

        let total = shootDirs.count
        var completed = 0

        await withTaskGroup(of: ShootResult?.self) { group in
            for itemURL in shootDirs {
                let existingCopy = existingShootMap
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    return await self.processShoot(
                        itemURL: itemURL, serial: serial,
                        now: now, existingShootMap: existingCopy
                    )
                }
            }

            for await result in group {
                guard let r = result else { continue }
                scannedNames.insert(r.name)
                completed += 1
                onProgress?(completed, total)

                switch r.action {
                case .skip:
                    break

                case .update(let existing, let subfolders, let newTotal, let createdDate):
                    db.insertShoot(driveID: serial, name: r.name, scannedAt: now,
                                   totalBytes: newTotal, createdAt: createdDate)
                    db.replaceAllFolders(for: existing.id, folders: subfolders.map {
                        (name: $0.name, sizeBytes: $0.sizeBytes, scannedAt: $0.scannedAt,
                         fileCount: $0.fileCount, parentID: $0.parentID,
                         depth: Int64($0.depth), fileTypes: $0.fileTypes)
                    })
                    // Log the update if size or folder count changed
                    let newRootCount = subfolders.filter { $0.depth == 0 }.count
                    let oldRootCount = self.db.fetchFolders(for: existing.id).filter { $0.depth == 0 }.count
                    let updateRootFolders = subfolders.filter { $0.depth == 0 }
                    let updateFileCount = updateRootFolders.reduce(0) { $0 + $1.fileCount }
                    if (newTotal != existing.totalBytes || newRootCount != oldRootCount) && updateFileCount > 0 {
                        // Build type string from fileTypes stored on root folders
                        let typeStr = updateRootFolders
                            .compactMap { $0.fileTypes }
                            .first ?? ""
                        let subtitle = typeStr.isEmpty
                            ? "\(updateFileCount) files · \(serial)"
                            : "\(typeStr) · \(serial)"
                        db.logActivityWithDate(
                            kind: .folderAdded,
                            title: "\(r.name.replacingOccurrences(of: "_", with: " ")) updated",
                            subtitle: subtitle,
                            date: now
                        )
                    }

                case .insert(let subfolders, let newTotal, let createdDate):
                    let alreadyExists = db.existingShootNames(for: serial)[r.name] != nil
                    let shootID = db.insertShoot(driveID: serial, name: r.name, scannedAt: now,
                                                  totalBytes: newTotal, createdAt: createdDate)
                    db.replaceAllFolders(for: shootID, folders: subfolders.map {
                        (name: $0.name, sizeBytes: $0.sizeBytes, scannedAt: $0.scannedAt,
                         fileCount: $0.fileCount, parentID: $0.parentID,
                         depth: Int64($0.depth), fileTypes: $0.fileTypes)
                    })
                    let rootFolders = subfolders.filter { $0.depth == 0 }
                    let totalFiles = rootFolders.reduce(0) { $0 + $1.fileCount }
                    if !alreadyExists && totalFiles > 0 {
                        let totalFiles  = rootFolders.reduce(0) { $0 + $1.fileCount }
                        // Build type summary from stored fileTypes on root folders
                        var typeCounts: [String: Int] = [:]
                        for folder in rootFolders {
                            guard let types = folder.fileTypes else { continue }
                            for part in types.split(separator: "·").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                                let pieces = part.split(separator: " ")
                                if pieces.count == 2, let n = Int(pieces[0]) {
                                    typeCounts[String(pieces[1]), default: 0] += n
                                }
                            }
                        }
                        let typeStr = typeCounts.sorted { $0.value > $1.value }.prefix(4)
                            .map { "\($0.value) \($0.key)" }.joined(separator: " · ")
                        let subtitle = typeStr.isEmpty
                            ? "\(totalFiles) files added to \(serial)"
                            : "\(typeStr) · \(serial)"
                        db.logActivityWithDate(
                            kind: .folderAdded,
                            title: "\(r.name.replacingOccurrences(of: "_", with: " ")) added",
                            subtitle: subtitle,
                            date: createdDate
                        )
                    }
                }
            }
        }

        // Detect deletions and renames
        let removedNames = Set(existingShootMap.keys).subtracting(scannedNames)
        let addedNames   = scannedNames.subtracting(Set(existingShootMap.keys))

        for name in removedNames {
            guard let existing = existingShootMap[name] else { continue }
            if removedNames.count == 1 && addedNames.count == 1,
               let newName = addedNames.first {
                db.deleteShoot(id: existing.id)
                db.logActivityWithDate(
                    kind: .folderAdded,
                    title: "\(name.replacingOccurrences(of: "_", with: " ")) renamed to \(newName.replacingOccurrences(of: "_", with: " "))",
                    subtitle: "Renamed on \(serial)",
                    date: now
                )
            } else {
                db.deleteShoot(id: existing.id)
                db.logActivityWithDate(
                    kind: .folderRemoved,
                    title: "\(name.replacingOccurrences(of: "_", with: " ")) removed",
                    subtitle: "Removed from \(serial)",
                    date: existing.scannedAt
                )
            }
        }
    }

    // MARK: - Per-shoot processing

    private func processShoot(
        itemURL: URL, serial: String, now: Date,
        existingShootMap: [String: (id: Int64, totalBytes: Int64, scannedAt: Date)]
    ) async -> ShootResult? {
        guard !Task.isCancelled else { return nil }

        let name        = itemURL.lastPathComponent
        let createdDate = folderCreationDate(itemURL) ?? now

        if let existing = existingShootMap[name] {
            // Only skip if mod date hasn't changed — catches file additions/deletions
            if let mod = folderModDate(itemURL), mod <= existing.scannedAt {
                db.updateShootScanDate(id: existing.id, scannedAt: now)
                db.updateShootCreatedAt(id: existing.id, createdAt: createdDate)
                return ShootResult(name: name, itemURL: itemURL, action: .skip)
            }
            // Mod date changed — re-scan this shoot
        }

        let subfolders = await scanSubfolders(of: itemURL, scannedAt: now)
        let totalBytes = subfolders.filter { $0.depth == 0 }.reduce(0) { $0 + $1.sizeBytes }

        if let existing = existingShootMap[name] {
            return ShootResult(name: name, itemURL: itemURL,
                               action: .update(existing: existing, subfolders: subfolders,
                                               totalBytes: totalBytes, createdDate: createdDate))
        } else {
            return ShootResult(name: name, itemURL: itemURL,
                               action: .insert(subfolders: subfolders,
                                               totalBytes: totalBytes, createdDate: createdDate))
        }
    }

    // MARK: - Subfolder scan

    private func scanSubfolders(of shootURL: URL, scannedAt: Date) async -> [DriveFolder] {
        var allFolders: [DriveFolder] = []
        await scanLevel(url: shootURL, shootID: 0, parentArrayIndex: nil,
                        depth: 0, maxDepth: maxDepth, scannedAt: scannedAt, results: &allFolders)
        return allFolders
    }

    private func scanLevel(
        url: URL, shootID: Int64, parentArrayIndex: Int?,
        depth: Int, maxDepth: Int, scannedAt: Date,
        results: inout [DriveFolder]
    ) async {
        guard !Task.isCancelled else { return }

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let items = contents.filter { !$0.lastPathComponent.hasPrefix(".") }
        var levelFolders: [(url: URL, folder: DriveFolder)] = []

        for batchStart in stride(from: 0, to: items.count, by: batchSize) {
            let batch = Array(items[batchStart ..< min(batchStart + batchSize, items.count)])
            let batchResults: [(URL, DriveFolder)] = await withTaskGroup(of: (URL, DriveFolder).self) { group in
                for itemURL in batch {
                    group.addTask {
                        guard !Task.isCancelled else {
                            return (itemURL, DriveFolder(
                                id: 0, shootID: shootID,
                                parentID: parentArrayIndex.map(Int64.init),
                                name: itemURL.lastPathComponent,
                                sizeBytes: 0, scannedAt: scannedAt,
                                fileCount: 0, depth: depth, fileTypes: nil
                            ))
                        }
                        let isDir = self.isDirectory(itemURL)
                        let size: Int64
                        let count: Int64
                        let fileTypes: String?
                        if isDir {
                            // Recursive enumeration — accurate size + file count + types
                            let (s, c, types) = self.fastFolderSizeCountAndTypes(itemURL)
                            size = s
                            count = c
                            if depth == 0 {
                                // Only store type breakdown for top-level folders
                                let top = types.sorted { $0.value > $1.value }.prefix(4)
                                    .map { "\($0.value) .\($0.key)" }.joined(separator: " · ")
                                fileTypes = top.isEmpty ? nil : top
                            } else {
                                fileTypes = nil
                            }
                        } else {
                            size = self.fileSize(itemURL)
                            count = 1
                            fileTypes = nil
                        }
                        return (itemURL, DriveFolder(
                            id: 0, shootID: shootID,
                            parentID: parentArrayIndex.map(Int64.init),
                            name: itemURL.lastPathComponent,
                            sizeBytes: size, scannedAt: scannedAt,
                            fileCount: count, depth: depth, fileTypes: fileTypes
                        ))
                    }
                }
                var r: [(URL, DriveFolder)] = []
                for await pair in group { r.append(pair) }
                return r
            }
            levelFolders.append(contentsOf: batchResults)
        }

        levelFolders.sort { $0.folder.sizeBytes > $1.folder.sizeBytes }

        for (itemURL, folder) in levelFolders {
            let myIndex = results.count
            results.append(folder)
            if isDirectory(itemURL) && depth < maxDepth && !Task.isCancelled {
                await scanLevel(url: itemURL, shootID: shootID, parentArrayIndex: myIndex,
                                depth: depth + 1, maxDepth: maxDepth,
                                scannedAt: scannedAt, results: &results)
            }
        }
    }

    // MARK: - Helpers

    /// Single pass: size + file count + extension breakdown
    nonisolated private func fastFolderSizeCountAndTypes(_ url: URL) -> (Int64, Int64, [String: Int]) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return (0, 0, [:]) }

        var totalSize: Int64 = 0
        var fileCount: Int64 = 0
        var typeCounts: [String: Int] = [:]
        for case let fileURL as URL in enumerator {
            guard let vals = try? fileURL.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
            ), vals.isRegularFile == true,
            let size = vals.totalFileAllocatedSize else { continue }
            totalSize += Int64(size)
            fileCount += 1
            let ext = fileURL.pathExtension.lowercased()
            if !ext.isEmpty { typeCounts[ext, default: 0] += 1 }
        }
        return (totalSize, fileCount, typeCounts)
    }

    nonisolated private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    nonisolated private func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    nonisolated private func folderModDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    nonisolated private func folderCreationDate(_ url: URL) -> Date? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        let birthTime = st.st_birthtimespec
        if birthTime.tv_sec > 0 {
            return Date(timeIntervalSince1970: Double(birthTime.tv_sec) + Double(birthTime.tv_nsec) / 1_000_000_000)
        }
        let changeTime = st.st_ctimespec
        if changeTime.tv_sec > 0 {
            return Date(timeIntervalSince1970: Double(changeTime.tv_sec) + Double(changeTime.tv_nsec) / 1_000_000_000)
        }
        return nil
    }

    nonisolated private func quickItemCount(_ url: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ).count) ?? 0
    }

    nonisolated private func diskUsage(for url: URL) -> (total: Int64?, used: Int64?) {
        guard let vals = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey
        ]) else { return (nil, nil) }
        let total = vals.volumeTotalCapacity.map(Int64.init)
        let free  = vals.volumeAvailableCapacity.map(Int64.init)
        if let total, let free { return (total, total - free) }
        return (total, nil)
    }

    func serialNumber(for volumeURL: URL) -> String? {
        let name = volumeURL.lastPathComponent
        return name.isEmpty ? nil : name
    }
}

// MARK: - DriveWatcher (FSEvents)

final class DriveWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private var debounceTimer: Timer?
    private var maxTimer: Timer?
    private let debounceInterval: TimeInterval = 10.0

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func start() {
        let path = url.path as CFString
        let paths = [path] as CFArray
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DriveWatcher>.fromOpaque(info).takeUnretainedValue().scheduleDebounced()
        }
        stream = FSEventStreamCreate(
            nil, callback, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents)
        )
        if let stream {
            FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        debounceTimer?.invalidate(); debounceTimer = nil
        maxTimer?.invalidate(); maxTimer = nil
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream); self.stream = nil
        }
    }

    private func scheduleDebounced() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Reset debounce — fires 10s after last change
            self.debounceTimer?.invalidate()
            self.debounceTimer = Timer.scheduledTimer(
                withTimeInterval: self.debounceInterval, repeats: false
            ) { [weak self] _ in
                self?.maxTimer?.invalidate()
                self?.maxTimer = nil
                self?.onChange()
            }
            // Max timer — fires after 30s regardless of ongoing file copies
            if self.maxTimer == nil {
                self.maxTimer = Timer.scheduledTimer(
                    withTimeInterval: 30.0, repeats: false
                ) { [weak self] _ in
                    self?.debounceTimer?.invalidate()
                    self?.debounceTimer = nil
                    self?.maxTimer = nil
                    self?.onChange()
                }
            }
        }
    }
}