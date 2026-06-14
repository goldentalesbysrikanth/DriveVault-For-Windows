import Foundation
import SwiftUI

// MARK: - Drive
struct Drive: Identifiable, Hashable, Codable {
    let id: String
    var name: String
    var totalBytes: Int64?
    var usedBytes: Int64?
    var isOnline: Bool
    var connectionType: String?
    var driveType: String?
    var lastSeenAt: Date?

    var freeBytes: Int64? {
        guard let total = totalBytes, let used = usedBytes else { return nil }
        return total - used
    }

    var usedFraction: Double {
        guard let total = totalBytes, let used = usedBytes, total > 0 else { return 0 }
        return Double(used) / Double(total)
    }

    var statusLabel: String {
        guard isOnline else { return "Offline" }
        return usedFraction >= 0.90 ? "Nearly full" : "Online"
    }

    var connectionLabel: String { isOnline ? "Online" : "Offline" }

    var statusColor: DriveStatusColor {
        if !isOnline { return .offline }
        return usedFraction >= 0.90 ? .warning : .online
    }
}

enum DriveStatusColor: Codable {
    case online, offline, warning
}

// MARK: - Shoot
struct Shoot: Identifiable, Hashable, Codable {
    let id: Int64
    let driveID: String
    var name: String
    var scannedAt: Date
    var createdAt: Date
    var totalBytes: Int64

    var displayName: String {
        name.replacingOccurrences(of: "_", with: " ")
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    var formattedDate: String {
        createdAt.formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: - DriveFolder
struct DriveFolder: Identifiable, Hashable, Codable {
    let id: Int64
    let shootID: Int64
    let parentID: Int64?
    var name: String
    var sizeBytes: Int64
    var scannedAt: Date
    var fileCount: Int64
    var depth: Int
    var fileTypes: String?  // e.g. "100 .jpg · 50 .mp4"

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var formattedFileCount: String {
        fileCount == 1 ? "1 file" : "\(fileCount) files"
    }
}

// MARK: - ActivityEvent
struct ActivityEvent: Identifiable, Hashable, Codable {
    let id: Int64
    let kind: ActivityKind
    let title: String
    let subtitle: String
    let occurredAt: Date

    var formattedDate: String {
        occurredAt.formatted(date: .abbreviated, time: .shortened)
    }

    enum ActivityKind: String, Codable {
        case folderAdded       = "folder_added"
        case folderRemoved     = "folder_removed"
        case driveConnected    = "drive_connected"
        case driveDisconnected = "drive_disconnected"
        case reindexed         = "reindexed"

        var icon: String {
            switch self {
            case .folderAdded:       return "folder.badge.plus"
            case .folderRemoved:     return "folder.badge.minus"
            case .driveConnected:    return "externaldrive.badge.checkmark"
            case .driveDisconnected: return "externaldrive.badge.xmark"
            case .reindexed:         return "arrow.clockwise"
            }
        }

        var color: Color {
            switch self {
            case .folderAdded:       return .green
            case .folderRemoved:     return .red
            case .driveConnected:    return .blue
            case .driveDisconnected: return .gray
            case .reindexed:         return .purple
            }
        }
    }
}

// MARK: - ClientGroup
struct ClientGroup: Identifiable, Codable {
    let key: String
    var shoots: [Shoot]

    var id: String { key }

    var displayName: String {
        key.replacingOccurrences(of: "_", with: " ")
    }

    var initials: String {
        displayName.split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
    }

    var totalBytes: Int64 {
        shoots.reduce(0) { $0 + $1.totalBytes }
    }

    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    var uniqueDriveIDs: [String] {
        Array(Set(shoots.map { $0.driveID }))
    }

    static func rootKey(from name: String) -> String {
        let parts = name.split(separator: "_").map(String.init)
        guard parts.count > 1 else { return name }
        let suffixWords: Set<String> = ["BTS","RAW","Edited","Finals","Backup","Exports","Delivered",
                                        "Day1","Day2","Day3","Part1","Part2"]
        var kept: [String] = []
        for part in parts {
            if suffixWords.contains(part) { break }
            kept.append(part)
        }
        return kept.isEmpty ? name : kept.joined(separator: "_")
    }
}

// MARK: - AppAlert
struct AppAlert: Identifiable, Codable {
    let id: String
    let kind: AlertKind
    let title: String
    let subtitle: String

    enum AlertKind: String, Codable {
        case warning, info, success, error
    }
}

// MARK: - ClientWorkflow
struct ClientWorkflow: Identifiable, Codable {
    var clientName: String
    var selectionLinkStatus: String = "Not Shared"
    var clientHDDCopyStatus: String = "Not Shared"
    var editedPhotosStatus: String = "NA"
    var cinematicVideoStatus: String = "NA"
    var traditionalVideoStatus: String = "NA"
    var albumDesigningStatus: String = "NA"
    var completeProjectStatus: String = "NA"
    var notes: String = ""
    var projectStartDate: Date = Date()
    var lastUpdatedAt: Date = Date()

    var id: String { clientName }

    var progressPercent: Double {
        let groupA = [selectionLinkStatus, clientHDDCopyStatus]
        let groupB = [editedPhotosStatus, cinematicVideoStatus,
                      traditionalVideoStatus, albumDesigningStatus,
                      completeProjectStatus]

        var total = 0.0
        var count = 0.0

        for s in groupA {
            count += 1
            switch s {
            case "Shared":    total += 100
            case "Pending":   total += 50
            case "On Hold":   total += 25
            default:          total += 0
            }
        }

        for s in groupB where s != "NA" {
            count += 1
            switch s {
            case "Delivered":  total += 100
            case "In Progress": total += 60
            case "Started":    total += 30
            case "On Hold":    total += 15
            default:           total += 0
            }
        }

        return count > 0 ? total / count : 0
    }

    var progressDisplay: String { String(format: "%.0f%%", progressPercent) }

    var daysRunning: Int {
        Calendar.current.dateComponents([.day], from: projectStartDate, to: Date()).day ?? 0
    }
}
