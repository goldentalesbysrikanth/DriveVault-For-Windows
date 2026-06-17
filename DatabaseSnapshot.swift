import Foundation

/// Represents a point-in-time backup of drivevault.sqlite
struct DatabaseSnapshot: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let url: URL
    let createdAt: Date

    // MARK: - Initializer
    init(url: URL, createdAt: Date = Date()) {
        self.id = UUID()
        self.url = url
        self.createdAt = createdAt
    }

    // MARK: - Display Helpers
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var displayName: String {
        Self.formatter.string(from: createdAt)
    }
}
