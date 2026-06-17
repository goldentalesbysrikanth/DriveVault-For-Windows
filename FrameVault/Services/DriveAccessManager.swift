import Foundation
import AppKit

/// Manages security-scoped bookmarks for external drives.
/// Required under App Sandbox to read external volume contents.
final class DriveAccessManager {
    private let defaults = UserDefaults.standard
    private let bookmarkKeyPrefix = "fv.bookmark."

    // ── Request access ─────────────────────────────────────────────────
    @MainActor
    func requestAccess(for volumeURL: URL) async -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Drive Vault needs access to \"\(volumeURL.lastPathComponent)\" to index your shoots."
        panel.prompt = "Grant Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = volumeURL
        let result = await panel.beginSheetModal(for: NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow())
        guard result == .OK, let url = panel.url else { return nil }
        saveBookmark(for: url)
        return url
    }

    // ── Bookmark management ────────────────────────────────────────────
    func saveBookmark(for url: URL) {
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope,
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil)
            defaults.set(bookmark, forKey: bookmarkKeyPrefix + url.lastPathComponent)
            NSLog("Saved bookmark for \(url.lastPathComponent)")
        } catch {
            NSLog("Failed to save bookmark for \(url): \(error)")
        }
    }

    func resolveBookmark(for volumeName: String) -> URL? {
        guard let data = defaults.data(forKey: bookmarkKeyPrefix + volumeName) else { return nil }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data,
                              options: .withSecurityScope,
                              relativeTo: nil,
                              bookmarkDataIsStale: &isStale)
            if isStale { saveBookmark(for: url) }
            if url.startAccessingSecurityScopedResource() {
                return url
            } else {
                NSLog("Failed to start accessing resource for \(volumeName)")
                return nil
            }
        } catch {
            NSLog("Failed to resolve bookmark for \(volumeName): \(error)")
            return nil
        }
    }

    func hasBookmark(for volumeName: String) -> Bool {
        defaults.data(forKey: bookmarkKeyPrefix + volumeName) != nil
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
        NSLog("Stopped accessing \(url.lastPathComponent)")
    }

    // ── Batch helpers ──────────────────────────────────────────────────
    func allBookmarks() -> [String] {
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(bookmarkKeyPrefix) }
            .map { $0.replacingOccurrences(of: bookmarkKeyPrefix, with: "") }
    }

    @MainActor
    func stopAllAccess() {
        for volumeName in allBookmarks() {
            if let url = resolveBookmark(for: volumeName) {
                url.stopAccessingSecurityScopedResource()
            }
        }
        NSLog("Stopped all drive access")
    }
}
