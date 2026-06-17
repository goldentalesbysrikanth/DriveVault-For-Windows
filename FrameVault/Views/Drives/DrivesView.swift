import SwiftUI

struct DrivesView: View {
    @EnvironmentObject var store: AppStore
    @State private var filter: DriveFilter = .all
    @State private var sortOrder: DriveSort = .name
    @State private var viewMode: ViewMode = .grid
    @State private var searchText = ""
    @State private var selectedDrive: Drive? = nil

    enum DriveFilter: String, CaseIterable {
        case all = "All"; case online = "Online"; case offline = "Offline"; case warning = "Nearly full"
    }
    enum DriveSort: String, CaseIterable {
        case name = "Name"; case freeSpace = "Most free space"; case usedSpace = "Most used"; case shoots = "Most folders"
    }
    enum ViewMode { case grid, list }

    var body: some View {
        Group {
            if let drive = selectedDrive {
                DriveDetailView(drive: drive) { selectedDrive = nil }
            } else {
                driveList
            }
        }
        .navigationTitle(selectedDrive?.name ?? "Drives")
        .searchable(text: $searchText, prompt: "Search drives…")
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button { viewMode = .grid } label: { Image(systemName: "square.grid.2x2") }.help("Grid view")
                Button { viewMode = .list } label: { Image(systemName: "list.bullet") }.help("List view")
            }
        }
        .toolbarRole(.editor)
        .overlay {
            if store.drives.isEmpty {
                ContentUnavailableView("No drives found", systemImage: "externaldrive",
                    description: Text("Connect a drive to begin indexing"))
            }
        }
    }

    // MARK: - Drive list

    private var driveList: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if viewMode == .grid { driveGrid } else { driveTableList }
        }
    }

    // Summary bar showing counts per filter
    private var filterBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(DriveFilter.allCases, id: \.self) { f in
                    FilterPill(label: f.rawValue, isActive: filter == f) { filter = f }
                }
                Spacer()
                Button {
                store.drives.filter(\.isOnline).forEach { store.forceReindex(drive: $0) }
            } label: {
                Text("Re-Index All")
                    .font(.system(size: 12))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.purple.opacity(0.12))
                    .foregroundStyle(.purple)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            Picker("Sort", selection: $sortOrder) {
                    ForEach(DriveSort.allCases, id: \.self) { s in Text(s.rawValue).tag(s) }
                }
                .labelsHidden().pickerStyle(.menu).font(.system(size: 12))
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            // Drive count summary
            HStack(spacing: 16) {
                driveCountBadge("Total", count: store.drives.count, color: .secondary)
                driveCountBadge("Online", count: store.drives.filter(\.isOnline).count, color: .green)
                driveCountBadge("Offline", count: store.drives.filter { !$0.isOnline }.count, color: .secondary)
                driveCountBadge("Nearly full", count: store.drives.filter { $0.statusColor == .warning }.count, color: .orange)
                Spacer()
                Text("\(filteredDrives.count) shown")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
        .background(.background)
    }

    private func driveCountBadge(_ label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(count) \(label)").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var driveGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(filteredDrives) { drive in
                    DriveCard(
                        drive: drive,
                        shootCount: store.shoots(for: drive).count,
                        onTap: { selectedDrive = drive },
                        onDelete: { store.removeDrive(drive) },
                        onReindex: { store.forceReindex(drive: drive) }
                    )
                }
            }
            .padding(16)
        }
    }

    private var driveTableList: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section(header: driveListHeader) {
                    ForEach(filteredDrives) { drive in
                        DriveListRow(
                            drive: drive,
                            shootCount: store.shoots(for: drive).count,
                            isIndexing: store.indexingState.driveID == drive.id,
                            onTap: { selectedDrive = drive },
                            onReindex: { store.forceReindex(drive: drive) },
                            onDelete: { store.removeDrive(drive) }
                        )
                        Divider()
                    }
                }
            }
        }
    }

    private var driveListHeader: some View {
        HStack {
            Text("Drive").frame(maxWidth: .infinity, alignment: .leading)
            Text("Free").frame(width: 80, alignment: .trailing)
            Text("Used").frame(width: 80, alignment: .trailing)
            Text("Folders").frame(width: 60, alignment: .trailing)
            Text("Status").frame(width: 100, alignment: .trailing)
            Color.clear.frame(width: 60)
        }
        .font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
        .textCase(.uppercase).tracking(0.4)
        .padding(.horizontal, 16).padding(.vertical, 8).background(.background.secondary)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button { viewMode = .grid } label: { Image(systemName: "square.grid.2x2") }.help("Grid view")
            Button { viewMode = .list } label: { Image(systemName: "list.bullet") }.help("List view")
        }
    }

    private var filteredDrives: [Drive] {
        let filtered = store.drives
            .filter {
                switch filter {
                case .all: return true; case .online: return $0.isOnline
                case .offline: return !$0.isOnline; case .warning: return $0.statusColor == .warning
                }
            }
            .filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }
        switch sortOrder {
        case .name:      return filtered.sorted { $0.name < $1.name }
        case .freeSpace: return filtered.sorted { (freeBytes($0) ?? -1) > (freeBytes($1) ?? -1) }
        case .usedSpace: return filtered.sorted { ($0.usedBytes ?? 0) > ($1.usedBytes ?? 0) }
        case .shoots:    return filtered.sorted { store.shoots(for: $0).count > store.shoots(for: $1).count }
        }
    }

    private func freeBytes(_ drive: Drive) -> Int64? {
        guard let t = drive.totalBytes, let u = drive.usedBytes else { return nil }
        return t - u
    }
}

// MARK: - Drive list row

struct DriveListRow: View {
    @EnvironmentObject var store: AppStore
    let drive: Drive; let shootCount: Int; let isIndexing: Bool
    let onTap: () -> Void; let onReindex: () -> Void; let onDelete: () -> Void

    private var freeBytes: Int64? {
        guard let t = drive.totalBytes, let u = drive.usedBytes else { return nil }
        return t - u
    }

    var body: some View {
        Button(action: onTap) {
            HStack {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6).fill(.purple.opacity(0.1)).frame(width: 26, height: 26)
                        Image(systemName: "externaldrive").foregroundStyle(.purple).font(.system(size: 12))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(drive.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(drive.driveType ?? "External").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(freeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                    .font(.system(size: 12)).foregroundStyle(freeSpaceColor).frame(width: 80, alignment: .trailing)
                Text(drive.usedBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                    .font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                Text("\(shootCount)").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)

                HStack(spacing: 4) {
                    StatusBadge(label: drive.isOnline ? "Online" : "Offline", color: drive.isOnline ? .green : .secondary)
                    if isIndexing { ProgressView().scaleEffect(0.55) }
                }
                .frame(width: 100, alignment: .trailing)

                HStack(spacing: 6) {
                    Button { onReindex() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).disabled(!drive.isOnline).help("Re-index")
                    Button(role: .destructive) { onDelete() } label: {
                        Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).help("Remove drive")
                }
                .frame(width: 60, alignment: .trailing)
            }
            .padding(.horizontal, 16).padding(.vertical, 10).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { onReindex() } label: { Label("Re-index now", systemImage: "arrow.clockwise") }.disabled(!drive.isOnline)
            Divider()
            Button(role: .destructive) { onDelete() } label: { Label("Remove this drive", systemImage: "trash") }
        }
    }

    private var freeSpaceColor: Color {
        guard let t = drive.totalBytes, let u = drive.usedBytes, t > 0 else { return .secondary }
        let pct = Double(u) / Double(t)
        return pct >= 0.90 ? .orange : pct >= 0.75 ? .yellow : .secondary
    }
}

// MARK: - Drive card

struct DriveCard: View {
    @EnvironmentObject var store: AppStore
    let drive: Drive; let shootCount: Int
    let onTap: () -> Void; let onDelete: () -> Void; let onReindex: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(.purple.opacity(0.12)).frame(width: 34, height: 34)
                        Image(systemName: "externaldrive").foregroundStyle(.purple)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(drive.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                        Text("\(drive.driveType ?? "External") · \(drive.connectionType ?? "")")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 6) {
                            if drive.isOnline {
                                Button { onReindex() } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.clockwise")
                                            .font(.system(size: 10, weight: .medium))
                                        Text("Re-index")
                                            .font(.system(size: 11))
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.purple.opacity(0.12))
                                    .foregroundStyle(.purple)
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                            StatusBadge(label: drive.isOnline ? "Online" : "Offline", color: drive.isOnline ? .green : .secondary)
                        }
                        if drive.isOnline, let u = drive.usedBytes, let t = drive.totalBytes,
                           t > 0, Double(u) / Double(t) >= 0.90 {
                            StatusBadge(label: "Nearly full", color: .orange)
                        }
                    }
                }

                if let t = drive.totalBytes, let u = drive.usedBytes, t > 0 {
                    ProgressView(value: Double(u), total: Double(t))
                        .tint(drive.statusColor == .warning ? .orange : .purple).scaleEffect(y: 0.7)
                    HStack {
                        Text("\(ByteCountFormatter.string(fromByteCount: u, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: t, countStyle: .file))")
                        Spacer()
                        Text("\(ByteCountFormatter.string(fromByteCount: t - u, countStyle: .file)) free")
                    }
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                }

                HStack {
                    Label("\(shootCount) folder\(shootCount != 1 ? "s" : "")", systemImage: "folder")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    if let lastSeen = drive.lastSeenAt {
                        Text(lastSeen, style: .relative).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(14).background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(drive.statusColor == .warning ? Color.orange.opacity(0.5) : Color(.separatorColor), lineWidth: 0.5))
            .overlay(alignment: .topTrailing) {
                if store.indexingState.driveID == drive.id {
                    HStack(spacing: 4) {
                        ProgressView().scaleEffect(0.6)
                        Text("Indexing…").font(.system(size: 11))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.ultraThinMaterial).clipShape(Capsule()).padding(8)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { onReindex() } label: { Label("Re-index now", systemImage: "arrow.clockwise") }.disabled(!drive.isOnline)
            Divider()
            Button(role: .destructive) { onDelete() } label: { Label("Remove this drive", systemImage: "trash") }
        }
    }
}

// MARK: - Drive detail view

struct DriveDetailView: View {
    @EnvironmentObject var store: AppStore
    let drive: Drive
    let onBack: () -> Void

    @State private var expandedShootID: Int64? = nil
    private var shoots: [Shoot] { store.shoots(for: drive) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                driveHeader
                shootsList
            }
            .padding(16)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { onBack() } label: { Label("Drives", systemImage: "chevron.left") }
            }
            // Single re-index button on drive detail — no duplicate icons
            ToolbarItem(placement: .automatic) {
                Button { store.forceReindex(drive: drive) } label: {
                    Label("Re-index", systemImage: "arrow.clockwise")
                }
                .disabled(!drive.isOnline)
                .help(drive.isOnline ? "Re-index this drive" : "Drive is offline")
            }
        }
    }

    private var driveHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(.purple.opacity(0.12)).frame(width: 44, height: 44)
                    Image(systemName: "externaldrive").foregroundStyle(.purple).font(.system(size: 22))
                }
                VStack(alignment: .leading) {
                    Text(drive.name).font(.system(size: 16, weight: .medium))
                    Text("\(drive.driveType ?? "External") · \(drive.connectionType ?? "") · Last seen \(drive.lastSeenAt.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    StatusBadge(label: drive.isOnline ? "Online" : "Offline", color: drive.isOnline ? .green : .secondary)
                    if drive.isOnline, let u = drive.usedBytes, let t = drive.totalBytes,
                       t > 0, Double(u) / Double(t) >= 0.90 {
                        StatusBadge(label: "Nearly full", color: .orange)
                    }
                }
            }

            if let t = drive.totalBytes, let u = drive.usedBytes {
                ProgressView(value: Double(u), total: Double(t)).tint(drive.statusColor == .warning ? .orange : .purple)
            }

            // Renamed labels as requested
            HStack(spacing: 10) {
                statsCell("Total Size",      value: drive.totalBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                statsCell("Used Size",       value: drive.usedBytes.map  { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                statsCell("Available Space", value: drive.freeBytes.map  { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                statsCell("Folders",         value: "\(shoots.count)")
            }
        }
        .padding(14).background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
    }

    private var shootsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(shoots.count) folder\(shoots.count != 1 ? "s" : "") on this drive")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10).background(.background)
            Divider()
            ForEach(shoots) { shoot in
                // Simple non-expandable folder list — no clickable detail
                SimpleFolderRow(shoot: shoot)
                Divider()
            }
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
    }

    private func statsCell(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(.tertiary).textCase(.uppercase).tracking(0.4)
            Text(value).font(.system(size: 14, weight: .medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10).background(.background.secondary).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Simple folder row (non-expandable, for drive detail)

struct SimpleFolderRow: View {
    let shoot: Shoot

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder").font(.system(size: 15)).foregroundStyle(.orange)
            Text(shoot.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Spacer()
            Text(shoot.formattedSize).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(shoot.formattedDate).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

// MARK: - Filter pill

struct FilterPill: View {
    let label: String; let isActive: Bool; let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).font(.system(size: 12))
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(isActive ? Color.purple.opacity(0.15) : Color(.systemGray).opacity(0.1))
                .foregroundStyle(isActive ? .purple : .secondary)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(isActive ? Color.purple.opacity(0.3) : Color.clear, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}
