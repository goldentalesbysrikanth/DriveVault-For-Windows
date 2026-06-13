import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var store: AppStore
    @State private var searchText = ""
    @State private var expandedShootID: Int64? = nil
    @State private var sortOrder = SortOrder.dateDesc
    @State private var driveFilter: String? = nil
    @State private var selectedShoot: Shoot? = nil

    enum SortOrder: String, CaseIterable {
        case dateDesc  = "Newest first"
        case dateAsc   = "Oldest first"
        case nameAsc   = "Name A–Z"
        case sizeDesc  = "Largest first"
        case filesDesc = "Most files"
    }

    var body: some View {
        Group {
            if let shoot = selectedShoot {
                ShootDetailView(
                    shoot: shoot,
                    drive: driveMap[shoot.driveID],
                    onBack: { selectedShoot = nil }
                )
            } else {
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    libraryTable
                }
                .searchable(text: $searchText, prompt: "Search folders or drives…")
            }
        }
        .navigationTitle(selectedShoot?.displayName ?? "Library")
        .onReceive(store.$searchNavigationShootID) { id in
            guard let id else { return }
            if let shoot = store.shoots.first(where: { $0.id == id }) {
                selectedShoot = shoot
                store.searchNavigationShootID = nil
            }
        }
    }

    // MARK: Toolbar — Windows style: bold count left, drive filter + sort right

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("\(filteredShoots.count) folder\(filteredShoots.count != 1 ? "s" : "")")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.primary)
            Spacer()
            Picker("", selection: $driveFilter) {
                Text("All Drives").tag(String?.none)
                ForEach(store.drives, id: \.id) { drive in
                    Text(drive.name).tag(Optional(drive.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 140)

            Picker("Sort", selection: $sortOrder) {
                ForEach(SortOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 130)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.background)
    }

    // MARK: Table

    private var libraryTable: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section(header: tableHeader) {
                    ForEach(filteredShoots) { shoot in
                        LibraryTableRow(
                            shoot: shoot,
                            drive: driveMap[shoot.driveID],
                            folders: store.folders(for: shoot),
                            isExpanded: expandedShootID == shoot.id,
                            onTap: { selectedShoot = shoot },
                            onExpand: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    expandedShootID = expandedShootID == shoot.id ? nil : shoot.id
                                }
                            }
                        )
                        Divider()
                    }
                }
            }
        }
        .background(.background)
        .overlay {
            if filteredShoots.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private var tableHeader: some View {
        HStack {
            Text("Folder").frame(maxWidth: .infinity, alignment: .leading)
            Text("Drive").frame(width: 130, alignment: .leading)
            Text("Files").frame(width: 65, alignment: .trailing)
            Text("Size").frame(width: 80, alignment: .trailing)
            Text("Created").frame(width: 100, alignment: .trailing)
            Color.clear.frame(width: 20)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.tertiary)
        .textCase(.uppercase)
        .tracking(0.4)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.background.secondary)
    }

    private var filteredShoots: [Shoot] {
        var pool = driveFilter == nil ? store.shoots : store.shoots.filter { $0.driveID == driveFilter }
        let base: [Shoot]
        if searchText.isEmpty {
            base = pool
        } else {
            let q = searchText.lowercased()
            base = pool.filter {
                $0.name.lowercased().contains(q) ||
                $0.driveID.lowercased().contains(q) ||
                (driveMap[$0.driveID]?.name.lowercased().contains(q) ?? false)
            }
        }
        switch sortOrder {
        case .dateDesc:  return base.sorted { $0.createdAt > $1.createdAt }
        case .dateAsc:   return base.sorted { $0.createdAt < $1.createdAt }
        case .nameAsc:   return base.sorted { $0.name < $1.name }
        case .sizeDesc:  return base.sorted { $0.totalBytes > $1.totalBytes }
        case .filesDesc: return base.sorted { totalFiles($0) > totalFiles($1) }
        }
    }

    private func totalFiles(_ shoot: Shoot) -> Int64 {
        store.folders(for: shoot).filter { $0.depth == 0 }.reduce(0) { $0 + $1.fileCount }
    }

    private var driveMap: [String: Drive] {
        Dictionary(uniqueKeysWithValues: store.drives.map { ($0.id, $0) })
    }
}

// MARK: - Library table row

struct LibraryTableRow: View {
    let shoot: Shoot
    let drive: Drive?
    let folders: [DriveFolder]
    let isExpanded: Bool
    let onTap: () -> Void
    let onExpand: () -> Void

    private var totalFileCount: Int64 {
        folders.filter { $0.depth == 0 }.reduce(0) { $0 + $1.fileCount }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onTap) {
                HStack {
                    HStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.purple.opacity(0.1))
                                .frame(width: 28, height: 28)
                            Image(systemName: "folder")
                                .foregroundStyle(.purple)
                                .font(.system(size: 13))
                        }
                        Text(shoot.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let drive {
                        Label(drive.name, systemImage: "externaldrive")
                            .font(.system(size: 11))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.secondary.opacity(0.1))
                            .clipShape(Capsule())
                            .frame(width: 130, alignment: .leading)
                            .lineLimit(1)
                    } else {
                        Text("—").frame(width: 130, alignment: .leading).foregroundStyle(.tertiary)
                    }

                    Text(totalFileCount == 0 ? "—" : "\(totalFileCount)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 65, alignment: .trailing)

                    Text(shoot.formattedSize)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)

                    Text(shoot.formattedDate)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(width: 100, alignment: .trailing)

                    // Chevron — only this triggers expand/collapse
                    Button(action: onExpand) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isExpanded)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(isExpanded ? Color(.systemGray).opacity(0.04) : .clear)

            if isExpanded {
                VStack(spacing: 0) {
                    Divider()
                    let rootFolders = folders.filter { $0.depth == 0 }
                    ForEach(rootFolders) { folder in
                        ExpandableFolderRow(
                            folder: folder,
                            allFolders: folders,
                            shootTotalBytes: shoot.totalBytes
                        )
                        if folder.id != rootFolders.last?.id {
                            Divider().padding(.leading, 44)
                        }
                    }
                    if rootFolders.isEmpty {
                        Text("No subfolders found")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding()
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.icloud")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                        Text("Auto-scanned · available offline")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 44)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGray).opacity(0.03))
                }
                .transition(.opacity.combined(with: .slide))
            }
        }
    }
}

// MARK: - Expandable folder row (max depth 4, shared with ClientsView)

struct ExpandableFolderRow: View {
    let folder: DriveFolder
    let allFolders: [DriveFolder]
    let shootTotalBytes: Int64

    @State private var isExpanded = false

    private let indentPerLevel: CGFloat = 20
    private let maxDisplayDepth = 4

    private var indent: CGFloat {
        CGFloat(folder.depth) * indentPerLevel + 16
    }

    private var fraction: Double {
        shootTotalBytes > 0 ? Double(folder.sizeBytes) / Double(shootTotalBytes) : 0
    }

    private var children: [DriveFolder] {
        allFolders.filter { $0.parentID == folder.id }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private var hasChildren: Bool {
        !children.isEmpty && folder.depth < maxDisplayDepth
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Color.clear.frame(width: indent)

                if hasChildren {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isExpanded)
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                } else {
                    Circle()
                        .fill(.tertiary.opacity(0.4))
                        .frame(width: 4, height: 4)
                        .frame(width: 14)
                }

                Image(systemName: "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(folderColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .font(.system(size: 13 - CGFloat(min(folder.depth, 1))))
                        .lineLimit(1)
                        .foregroundStyle(folder.depth == 0 ? .primary : .secondary)
                    if let types = folder.fileTypes, !types.isEmpty, folder.depth == 0 {
                        Text(types)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if folder.fileCount > 0 {
                    Text(folder.formattedFileCount)
                        .font(.system(size: 10))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())
                }

                if folder.depth <= 1 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.secondary.opacity(0.12)).frame(height: 3)
                            Capsule().fill(.purple.opacity(0.5))
                                .frame(width: geo.size.width * fraction, height: 3)
                        }
                        .frame(height: 3)
                    }
                    .frame(width: 60, height: 3)
                }

                Text(folder.formattedSize)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 52, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)

            if isExpanded && hasChildren {
                VStack(spacing: 0) {
                    ForEach(children) { child in
                        Divider().padding(.leading, indent + indentPerLevel)
                        ExpandableFolderRow(
                            folder: child,
                            allFolders: allFolders,
                            shootTotalBytes: shootTotalBytes
                        )
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var folderColor: Color {
        switch folder.depth {
        case 0: return .orange
        case 1: return .purple
        case 2: return .blue
        default: return .gray.opacity(0.6)
        }
    }
}

// MARK: - Shoot Detail View

struct ShootDetailView: View {
    @EnvironmentObject var store: AppStore
    let shoot: Shoot
    let drive: Drive?
    let onBack: () -> Void

    private var folders: [DriveFolder] { store.folders(for: shoot) }
    private var rootFolders: [DriveFolder] { folders.filter { $0.depth == 0 }.sorted { $0.sizeBytes > $1.sizeBytes } }
    private var totalFileCount: Int64 { rootFolders.reduce(0) { $0 + $1.fileCount } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button { onBack() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .medium))
                        Text("Back").font(.system(size: 13))
                    }
                    .foregroundStyle(.purple)
                }
                .buttonStyle(.plain)

                Text(shoot.displayName).font(.system(size: 22, weight: .semibold))

                HStack(spacing: 12) {
                    detailStatCard("Total Size",  value: shoot.formattedSize)
                    detailStatCard("Total Files", value: totalFileCount > 0 ? "\(totalFileCount) files" : "—")
                    detailStatCard("Drive",       value: drive?.name ?? "—")
                    detailStatCard("Created",     value: shoot.createdAt.formatted(date: .long, time: .omitted))
                }

                VStack(spacing: 0) {
                    ForEach(rootFolders) { folder in
                        ExpandableFolderRow(folder: folder, allFolders: folders, shootTotalBytes: shoot.totalBytes)
                        if folder.id != rootFolders.last?.id { Divider().padding(.leading, 16) }
                    }
                    if rootFolders.isEmpty {
                        Text("No subfolders found").font(.callout).foregroundStyle(.tertiary).padding(20).frame(maxWidth: .infinity)
                    }
                }
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))

                HStack(spacing: 6) {
                    Image(systemName: "checkmark.icloud").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Text("Auto-scanned · available offline").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .padding(20)
        }
        .background(Color(.windowBackgroundColor))
    }

    private func detailStatCard(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 16, weight: .semibold)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14).background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
    }
}
