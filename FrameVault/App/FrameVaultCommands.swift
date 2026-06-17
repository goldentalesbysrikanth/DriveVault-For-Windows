import SwiftUI

struct DriveVaultCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Re-index All Connected Drives") {
                NotificationCenter.default.post(name: .reindexAll, object: nil)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .help("Force re-indexing of all currently connected drives")
        }
        CommandGroup(replacing: .newItem) {
            Button("Open Drive Vault") {
                NotificationCenter.default.post(name: .openMainWindow, object: nil)
            }
            .keyboardShortcut("o", modifiers: [.command])
            .help("Open the main Drive Vault window")
        }
    }
}

extension Notification.Name {
    static let reindexAll    = Notification.Name("fv.reindexAll")
    static let openMainWindow = Notification.Name("fv.openMainWindow")
}
