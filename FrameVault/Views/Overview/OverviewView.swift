import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var store: AppStore
    @Binding var selection: SidebarItem
    @State private var searchText = ""
    @State private var debouncedText = ""
    @State private var searchFolders: [DriveFolder] = []
    @State private var foldersLoaded = false
    @State private var showActivitySheet = false

    var body: some View {
        Group {
            if !debouncedText.isEmpty {
                searchResults
            } else {
                dashboard
            }
        }
        .navigationTitle("Overview")
        .searchable(text: $searchText, prompt: "Search shoots, drives, clients…")
        .onChange(of: searchText) { _, newVal in
            // Debounce: wait 300ms after last keystroke before searching
            let debounced = newVal
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard searchText == debounced else { return }
                debouncedText = debounced
            }
            // Load folders once in background
            if !newVal.isEmpty && !foldersLoaded {
                DispatchQueue.global(qos: .userInitiated).async {
                    let folders = store.db.fetchAllFolders()
                    DispatchQueue.main.async {
                        searchFolders = folders
                        foldersLoaded = true
                    }
                }
            }
        }
    }

    // ── Dashboard ──────────────────────────────────────────────────────

    private var dashboard: some View {
        ScrollView {
            VStack(spacing: 16) {
                statsRow
                // Connected drives pending index — only shown when relevant
                if !unindexedConnectedDrives.isEmpty {
                    connectedDrivesCard
                }
                HStack(alignment: .top, spacing: 16) {
                    driveStatusCard
                    VStack(spacing: 12) {
                        alertsCard
                        activityCard
                    }
                }
            }
            .padding(20)
        }
    }

    // ── Stat cards ─────────────────────────────────────────────────────

    private var statsRow: some View {
        HStack(spacing: 10) {
            StatCard(label: "Total drives",
                     value: "\(store.drives.count)",
                     sub: "\(store.drives.filter(\.isOnline).count) connected") {
                selection = .drives
            }
            StatCard(label: "Total indexed",
                     value: formattedTotalStorage,
                     sub: "\(formattedUsedStorage) used") {
                selection = .drives
            }
            StatCard(label: "Shoots tracked",
                     value: "\(store.shoots.count)",
                     sub: "\(recentShootCount) this month") {
                selection = .library
            }
            StatCard(label: "Clients",
                     value: "\(store.clientGroups.count)",
                     sub: "") {
                selection = .clients
            }
        }
    }

    // ── Connected drives card (unindexed only) ─────────────────────────

    // Drives that are online but have never been indexed (zero shoots in DB)
    private var unindexedConnectedDrives: [Drive] {
        store.drives.filter { drive in
            drive.isOnline && store.shoots(for: drive).isEmpty
        }
    }

    private var connectedDrivesCard: some View {
        CardView(title: "Connected drives — not yet indexed", icon: "externaldrive.badge.exclamationmark") {
            ForEach(unindexedConnectedDrives) { drive in
                HStack(spacing: 12) {
                    // Drive icon
                    ZStack {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.orange.opacity(0.12))
                            .frame(width: 32, height: 32)
                        Image(systemName: "externaldrive")
                            .foregroundStyle(.orange)
                            .font(.system(size: 14))
                    }

                    // Drive info
                    VStack(alignment: .leading, spacing: 2) {
                        Text(drive.name)
                            .font(.system(size: 13, weight: .medium))
                        Text(driveSubtitle(drive))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    // Indexing indicator or Index button
                    if store.indexingState.driveID == drive.id {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.65)
                            Text(store.indexingState.progressText.isEmpty
                                 ? "Indexing…"
                                 : store.indexingState.progressText)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button {
                            store.forceReindex(drive: drive)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11, weight: .medium))
                                Text("Index now")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Color.purple.opacity(0.12))
                            .foregroundStyle(.purple)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.purple.opacity(0.25), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 3)

                if drive.id != unindexedConnectedDrives.last?.id {
                    Divider()
                }
            }
        }
    }

    private func driveSubtitle(_ drive: Drive) -> String {
        var parts: [String] = []
        if let type = drive.driveType { parts.append(type) }
        if let conn = drive.connectionType { parts.append(conn) }
        if let total = drive.totalBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    // ── Drive status card ──────────────────────────────────────────────

    private var sortedDrivesForOverview: [Drive] {
        store.drives.sorted { a, b in
            if a.isOnline != b.isOnline { return a.isOnline }
            let aDate = a.lastSeenAt ?? .distantPast
            let bDate = b.lastSeenAt ?? .distantPast
            return aDate > bDate
        }
    }

    private var driveStatusCard: some View {
        let visible = Array(sortedDrivesForOverview.prefix(7))
        return CardView(title: "Drive status", icon: "externaldrive") {
            ForEach(visible) { drive in
                DriveStatusRow(drive: drive) { selection = .drives }
                if drive.id != visible.last?.id { Divider() }
            }
            if store.drives.count > 7 {
                Button { selection = .drives } label: {
                    Text("View all \(store.drives.count) drives →")
                        .font(.system(size: 12))
                        .foregroundStyle(.purple)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
    }

    // ── Alerts card ────────────────────────────────────────────────────

    @State private var alertsExpanded = false

    private var alertsCard: some View {
        CardView(title: "Alerts", icon: "exclamationmark.triangle") {
            if store.alerts.isEmpty {
                Label("All drives healthy", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let visibleAlerts = alertsExpanded ? store.alerts : Array(store.alerts.prefix(7))
                ForEach(visibleAlerts) { alert in
                    AlertRow(alert: alert)
                    if alert.id != visibleAlerts.last?.id { Divider() }
                }
                if store.alerts.count > 7 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            alertsExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(alertsExpanded
                                 ? "Show fewer"
                                 : "Show \(store.alerts.count - 7) more…")
                                .font(.system(size: 12))
                                .foregroundStyle(.purple)
                            Image(systemName: alertsExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10))
                                .foregroundStyle(.purple)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
        }
    }

    // ── Activity card ──────────────────────────────────────────────────

    // Last 7 days, max 7 entries for the overview card
    private var recentActivityForCard: [ActivityEvent] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        return Array(store.recentActivity.filter { $0.occurredAt >= cutoff }.prefix(7))
    }

    private var activityCard: some View {
        CardView(title: "Recent activity", icon: "clock") {
            if recentActivityForCard.isEmpty {
                Text("No activity yet — connect a drive to start")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(recentActivityForCard) { event in
                    activityRow(event)
                }
                if store.recentActivity.count > 7 {
                    Button {
                        showActivitySheet = true
                    } label: {
                        Text("View all \(store.recentActivity.count) events →")
                            .font(.system(size: 12))
                            .foregroundStyle(.purple)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
        }
        .onTapGesture {
            if !store.recentActivity.isEmpty {
                showActivitySheet = true
            }
        }
        .sheet(isPresented: $showActivitySheet) {
            ActivityLogSheet()
                .environmentObject(store)
        }
    }

    private func activityRow(_ event: ActivityEvent) -> some View {
        HStack(spacing: 8) {
            Image(systemName: event.kind.icon)
                .font(.system(size: 13))
                .foregroundStyle(activityColor(event.kind))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.callout)
                    .lineLimit(1)
                Text(event.subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(event.occurredAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func activityColor(_ kind: ActivityEvent.ActivityKind) -> Color {
        kind.color
    }

    // ── Search results ─────────────────────────────────────────────────

    @State private var selectedSearchShoot: Shoot? = nil
    @State private var showShootDetail = false

    private var searchResults: some View {
        let q = debouncedText.lowercased()
        let driveMap = Dictionary(uniqueKeysWithValues: store.drives.map { ($0.id, $0) })

        // Search shoots by name or drive name
        var seen = Set<Int64>()
        var shootResults: [Shoot] = []
        for s in store.shoots {
            let matchesName  = s.name.lowercased().contains(q)
            let matchesDrive = s.driveID.lowercased().contains(q) ||
                               (driveMap[s.driveID]?.name.lowercased().contains(q) ?? false)
            if (matchesName || matchesDrive) && seen.insert(s.id).inserted {
                shootResults.append(s)
            }
        }

        // Search drives by name
        let driveResults = store.drives.filter { $0.name.lowercased().contains(q) }

        // Search folders — cached only, never hits DB on main thread
        let shootMap = Dictionary(uniqueKeysWithValues: store.shoots.map { ($0.id, $0) })
        let folderResults: [DriveFolder] = foldersLoaded ? searchFolders.filter { $0.name.lowercased().contains(q) } : []

        let totalResults = shootResults.count + driveResults.count + folderResults.count

        return Group {
            if totalResults == 0 {
                ContentUnavailableView.search(text: debouncedText)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Drives section
                        if !driveResults.isEmpty {
                            Text("DRIVES")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .tracking(0.5)
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                            ForEach(driveResults) { drive in
                                Button { selection = .drives } label: {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(.purple.opacity(0.1))
                                                .frame(width: 28, height: 28)
                                            Image(systemName: "externaldrive")
                                                .foregroundStyle(.purple)
                                                .font(.system(size: 12))
                                        }
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(drive.name).font(.system(size: 13, weight: .medium))
                                            Text(drive.isOnline ? "Online" : "Offline")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if let total = drive.totalBytes {
                                            Text(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                                                .font(.caption).foregroundStyle(.tertiary)
                                        }
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 16).padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }

                        // Folders section
                        if !shootResults.isEmpty {
                            Text("FOLDERS")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .tracking(0.5)
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                            ForEach(shootResults) { shoot in
                                SearchResultRow(
                                    shoot: shoot,
                                    drive: driveMap[shoot.driveID],
                                    onTap: {
                                        store.searchNavigationShootID = shoot.id
                                        selection = .library
                                    }
                                )
                                Divider()
                            }
                        }

                        // Folder records section
                        if !folderResults.isEmpty {
                            Text("FOLDERS")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .tracking(0.5)
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                            ForEach(folderResults) { folder in
                                let shoot = shootMap[folder.shootID]
                                let drive = shoot.flatMap { driveMap[$0.driveID] }
                                Button {
                                    if let shoot {
                                        store.searchNavigationShootID = shoot.id
                                        selection = .library
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(Color.purple.opacity(0.1))
                                                .frame(width: 28, height: 28)
                                            Image(systemName: "folder")
                                                .foregroundStyle(.purple)
                                                .font(.system(size: 12))
                                        }
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(folder.name)
                                                .font(.system(size: 13, weight: .medium))
                                            HStack(spacing: 6) {
                                                if let drive {
                                                    Label(drive.name, systemImage: "externaldrive")
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                                if let shoot {
                                                    Text("· \(shoot.displayName)")
                                                        .font(.caption)
                                                        .foregroundStyle(.tertiary)
                                                }
                                            }
                                        }
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 2) {
                                            Text(folder.formattedSize)
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                            Text(folder.formattedFileCount)
                                                .font(.system(size: 10))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }

                        // Clients section
                        let clientResults = store.clientGroups.filter {
                            $0.displayName.lowercased().contains(q)
                        }
                        if !clientResults.isEmpty {
                            Text("CLIENTS")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .tracking(0.5)
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                            ForEach(clientResults) { group in
                                Button {
                                    store.searchNavigationClientKey = group.key
                                    selection = .clients
                                } label: {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            Circle().fill(.purple.opacity(0.1)).frame(width: 28, height: 28)
                                            Text(group.initials).font(.system(size: 11, weight: .medium)).foregroundStyle(.purple)
                                        }
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(group.displayName).font(.system(size: 13, weight: .medium))
                                            Text("Client · \(group.shoots.count) shoots · \(group.formattedTotalSize)")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 16).padding(.vertical, 10).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }
                    }
                }

            }
        }
    }

    // ── Computed helpers ───────────────────────────────────────────────

    private var formattedTotalStorage: String {
        ByteCountFormatter.string(fromByteCount: store.drives.compactMap(\.totalBytes).reduce(0, +), countStyle: .file)
    }

    private var formattedUsedStorage: String {
        ByteCountFormatter.string(fromByteCount: store.drives.compactMap(\.usedBytes).reduce(0, +), countStyle: .file)
    }

    private var recentShootCount: Int {
        store.shoots.filter { Calendar.current.isDate($0.createdAt, equalTo: Date(), toGranularity: .month) }.count
    }
}

// ── Activity log sheet ─────────────────────────────────────────────────

struct ActivityLogSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity Log")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding(16)
            .background(.background)

            Divider()

            if store.recentActivity.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("No activity recorded yet")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groupedActivity, id: \.date) { group in
                            Section {
                                ForEach(group.events) { event in
                                    HStack(spacing: 12) {
                                        Image(systemName: event.kind.icon)
                                            .font(.system(size: 15))
                                            .foregroundStyle(colorFor(event.kind))
                                            .frame(width: 24)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(event.title)
                                                .font(.system(size: 13, weight: .medium))
                                            Text(event.subtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.system(size: 12))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    Divider().padding(.leading, 52)
                                }
                            } header: {
                                Text(group.date)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                    .tracking(0.5)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.background.secondary)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 520, height: 520)
    }

    private var groupedActivity: [(date: String, events: [ActivityEvent])] {
        let grouped = Dictionary(grouping: store.recentActivity) { event -> String in
            if Calendar.current.isDateInToday(event.occurredAt)     { return "Today" }
            if Calendar.current.isDateInYesterday(event.occurredAt) { return "Yesterday" }
            return event.occurredAt.formatted(date: .long, time: .omitted)
        }
        let order = ["Today", "Yesterday"]
        let sorted = grouped.keys.sorted { a, b in
            let ai = order.firstIndex(of: a) ?? 999
            let bi = order.firstIndex(of: b) ?? 999
            if ai != bi { return ai < bi }
            let af = grouped[a]!.first!.occurredAt
            let bf = grouped[b]!.first!.occurredAt
            return af > bf
        }
        return sorted.map { (date: $0, events: grouped[$0]!.sorted { $0.occurredAt > $1.occurredAt }) }
    }

    private func colorFor(_ kind: ActivityEvent.ActivityKind) -> Color {
        kind.color
    }
}

// ── Supporting views ───────────────────────────────────────────────────

struct StatCard: View {
    let label: String
    let value: String
    let sub: String
    let action: () -> Void  // kept for API compatibility but not used

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.tertiary).textCase(.uppercase).tracking(0.5)
            Text(value).font(.system(size: 22, weight: .medium)).foregroundStyle(.primary)
            if !sub.isEmpty { Text(sub).font(.system(size: 11)).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct CardView<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
    }
}

struct DriveStatusRow: View {
    let drive: Drive
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(drive.name).font(.callout).fontWeight(.medium).lineLimit(1)
                    if let used = drive.usedBytes, let total = drive.totalBytes, total > 0 {
                        ProgressView(value: Double(used), total: Double(total))
                            .tint(drive.statusColor == .warning ? .orange : .purple)
                            .scaleEffect(y: 0.6)
                    }
                    Text(driveMetaText).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    StatusBadge(label: drive.isOnline ? "Online" : "Offline",
                                color: drive.isOnline ? .green : .secondary)
                    if drive.isOnline,
                       let used = drive.usedBytes, let total = drive.totalBytes, total > 0,
                       Double(used) / Double(total) >= 0.90 {
                        StatusBadge(label: "Nearly full", color: .orange)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private var statusColor: Color {
        switch drive.statusColor {
        case .online:  return .green
        case .warning: return .orange
        case .offline: return .secondary
        }
    }

    private var driveMetaText: String {
        guard let total = drive.totalBytes, let used = drive.usedBytes else { return drive.connectionType ?? "" }
        return "\(ByteCountFormatter.string(fromByteCount: used, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
    }
}

struct AlertRow: View {
    let alert: AppAlert
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName).foregroundStyle(iconColor).font(.system(size: 15))
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title).font(.callout)
                Text(alert.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()

            Menu {
                Button("Snooze 1 day")  { store.snoozeAlert(alert, days: 1) }
                Button("Snooze 3 days") { store.snoozeAlert(alert, days: 3) }
                Button("Snooze 1 week") { store.snoozeAlert(alert, days: 7) }
            } label: {
                Image(systemName: "clock.badge.exclamationmark")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Snooze this alert")

            Button {
                store.ignoreAlert(alert)
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .help("Ignore this alert permanently")
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        switch alert.kind {
        case .warning: return "exclamationmark.triangle.fill"
        case .info:    return "clock"
        case .success: return "checkmark.circle.fill"
        case .error:   return "xmark.octagon.fill"
        }
    }

    private var iconColor: Color {
        switch alert.kind {
        case .warning: return .orange
        case .info:    return .blue
        case .success: return .green
        case .error:   return .red
        }
    }
}

struct StatusBadge: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// ── Search shoot detail sheet ──────────────────────────────────────────

struct SearchShootDetailSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let shoot: Shoot
    let drive: Drive?

    // Load folders from DB inside the sheet — avoids empty array at sheet creation time
    private var folders: [DriveFolder] { store.folders(for: shoot) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.purple.opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: "camera")
                        .foregroundStyle(.purple)
                        .font(.system(size: 18))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(shoot.displayName)
                        .font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 8) {
                        if let drive {
                            Label(drive.name, systemImage: "externaldrive")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(shoot.formattedSize)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text("Created \(shoot.createdAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(16)
            .background(.background)

            Divider()

            if folders.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No subfolders found")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(folders) { folder in
                            FolderRow(folder: folder, totalBytes: shoot.totalBytes)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 580, height: 520)
    }
}

struct SearchResultRow: View {
    let shoot: Shoot
    let drive: Drive?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.purple.opacity(0.1))
                        .frame(width: 28, height: 28)
                    Image(systemName: "camera")
                        .foregroundStyle(.purple)
                        .font(.system(size: 12))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(shoot.displayName)
                        .font(.system(size: 13, weight: .medium))
                    if let drive {
                        Label(drive.name, systemImage: "externaldrive")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(shoot.formattedSize)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(shoot.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
