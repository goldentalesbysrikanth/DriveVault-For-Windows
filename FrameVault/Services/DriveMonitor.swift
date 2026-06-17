import Foundation
import DiskArbitration
import Combine
import os.log

final class DriveMonitor {

    private let driveConnectedSubject    = PassthroughSubject<URL, Never>()
    private let driveDisconnectedSubject = PassthroughSubject<String, Never>()

    var driveConnected: AnyPublisher<URL, Never>       { driveConnectedSubject.eraseToAnyPublisher() }
    var driveDisconnected: AnyPublisher<String, Never> { driveDisconnectedSubject.eraseToAnyPublisher() }

    private var session: DASession?
    private var autoScanTimer: DispatchSourceTimer?
    private var lastKnownVolumes = Set<String>()
    private let log = Logger(subsystem: "com.drivevault", category: "DriveMonitor")

    private let systemVolumeNames: Set<String> = [
        "Macintosh HD","Data","Preboot","Recovery","VM","Update","com.apple.os.update",
        "Hardware","iSCPreboot","mnt1","xarts","home"
    ]

    // MARK: - Lifecycle

    func start(scanInterval: TimeInterval = 5.0) {
        log.info("DriveMonitor.start() called")

        // Initial scan
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.scanMountedVolumes()
        }

        // Auto-scan timer
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .background))
        timer.schedule(deadline: .now() + scanInterval, repeating: scanInterval)
        timer.setEventHandler { [weak self] in self?.scanMountedVolumes() }
        timer.resume()
        autoScanTimer = timer

        // DiskArbitration session
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            log.error("Failed to create DiskArbitration session")
            return
        }
        self.session = session
        DASessionSetDispatchQueue(session, DispatchQueue.main)

        DARegisterDiskAppearedCallback(session, nil, { disk, ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<DriveMonitor>.fromOpaque(ctx).takeUnretainedValue()
            monitor.handleAppear(disk: disk)
        }, Unmanaged.passUnretained(self).toOpaque())

        DARegisterDiskDisappearedCallback(session, nil, { disk, ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<DriveMonitor>.fromOpaque(ctx).takeUnretainedValue()
            monitor.handleDisappear(disk: disk)
        }, Unmanaged.passUnretained(self).toOpaque())

        log.info("DriveMonitor ready — DA + auto-scan active")
    }

    func stop() {
        autoScanTimer?.cancel()
        autoScanTimer = nil
        if let session {
            DASessionSetDispatchQueue(session, nil)
        }
        session = nil
        log.info("DriveMonitor stopped")
    }

    // MARK: - Auto scan

    private func scanMountedVolumes() {
        guard let mounts = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                                 options: .skipHiddenVolumes) else {
            log.error("Failed to fetch mounted volumes")
            return
        }

        let currentVolumes = Set(mounts.map { $0.lastPathComponent })

        for url in mounts {
            let name = url.lastPathComponent
            guard shouldIndex(url: url), !lastKnownVolumes.contains(name) else { continue }
            log.info("Auto-scan detected: \(name)")
            driveConnectedSubject.send(url)
        }

        for name in lastKnownVolumes where !currentVolumes.contains(name) {
            log.info("Auto-scan lost: \(name)")
            driveDisconnectedSubject.send(name)
        }

        lastKnownVolumes = Set(mounts.compactMap { shouldIndex(url: $0) ? $0.lastPathComponent : nil })
    }

    // MARK: - DA Callbacks

    private func handleAppear(disk: DADisk) {
        guard let desc = DADiskCopyDescription(disk) as? [String: Any] else { return }

        if let volumeURL = desc[kDADiskDescriptionVolumePathKey as String] as? URL {
            let name = volumeURL.lastPathComponent
            guard shouldIndex(url: volumeURL) else { return }
            log.info("DA detected: \(name)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.driveConnectedSubject.send(volumeURL)
            }
            return
        }

        guard let volumeName = desc[kDADiskDescriptionVolumeNameKey as String] as? String,
              !volumeName.isEmpty,
              shouldIndexByName(volumeName) else { return }

        log.info("DA detected (mounting): \(volumeName) — waiting 2.5s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard let url = DriveMonitor.mountedURL(for: volumeName), self.shouldIndex(url: url) else {
                self.log.warning("\(volumeName) not found after delay — auto-scan will catch it")
                return
            }
            self.log.info("DA delayed: \(volumeName)")
            self.driveConnectedSubject.send(url)
        }
    }

    private func handleDisappear(disk: DADisk) {
        guard let desc = DADiskCopyDescription(disk) as? [String: Any] else { return }
        let name = (desc[kDADiskDescriptionVolumeNameKey as String] as? String)
            ?? (desc[kDADiskDescriptionMediaBSDNameKey as String] as? String)
            ?? "unknown"
        guard shouldIndexByName(name) else { return }
        log.info("DA lost: \(name)")
        driveDisconnectedSubject.send(name)
    }

    // MARK: - Filtering

    private func shouldIndex(url: URL) -> Bool {
        shouldIndexByName(url.lastPathComponent)
    }

    private func shouldIndexByName(_ name: String) -> Bool {
        guard !systemVolumeNames.contains(name),
              !name.hasPrefix("com.apple"),
              !name.hasPrefix("."),
              name != "/" && !name.isEmpty else { return false }
        return true
    }

    // MARK: - Static helpers

    static func mountedURL(for volumeName: String) -> URL? {
        FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                              options: .skipHiddenVolumes)?
            .first { $0.lastPathComponent == volumeName }
    }

    static func driveInfo(for volumeURL: URL) -> (connectionType: String?, driveType: String?) {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volumeURL as CFURL),
              let desc = DADiskCopyDescription(disk) as? [String: Any] else {
            return ("USB", "HDD")
        }
        let bus = desc[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? "USB"
        let isRemovable = desc[kDADiskDescriptionMediaRemovableKey as String] as? Bool ?? false
        return (bus, isRemovable ? "Flash" : "HDD")
    }
}

