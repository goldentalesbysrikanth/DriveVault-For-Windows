import SwiftUI

struct ClientsView: View {
    @EnvironmentObject var store: AppStore
    @State private var searchText = ""
    @State private var sortOrder = ClientSort.nameAsc
    @State private var selectedGroup: ClientGroup? = nil
    @State private var activeTab = "Clients"

    enum ClientSort: String, CaseIterable {
        case nameAsc  = "A–Z"
        case nameDesc = "Z–A"
        case drive    = "By Drive"
    }

    // MARK: - Computed

    private var totalSize: Int64 {
        store.clientGroups.reduce(0) { $0 + $1.totalBytes }
    }

    private var drivesUsed: Int {
        Set(store.shoots.map { $0.driveID }).count
    }

    private var sortedGroups: [ClientGroup] {
        switch sortOrder {
        case .nameAsc:  return store.clientGroups.sorted { $0.displayName < $1.displayName }
        case .nameDesc: return store.clientGroups.sorted { $0.displayName > $1.displayName }
        case .drive:    return store.clientGroups.sorted { ($0.uniqueDriveIDs.first ?? "") < ($1.uniqueDriveIDs.first ?? "") }
        }
    }

    private var filteredGroups: [ClientGroup] {
        guard !searchText.isEmpty else { return sortedGroups }
        let q = searchText.lowercased()
        return sortedGroups.compactMap { group in
            let matchesGroup = group.displayName.lowercased().contains(q)
            let matchedShoots = group.shoots.filter { $0.displayName.lowercased().contains(q) }
            if matchesGroup { return group }
            if !matchedShoots.isEmpty { return ClientGroup(key: group.key, shoots: matchedShoots) }
            return nil
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // ── Tab switcher ──────────────────────────────────────────
            // ── Tab switcher — refined underline style ────────────────
            HStack(spacing: 0) {
                ForEach(["Clients", "Workflow"], id: \.self) { tab in
                    let isActive = activeTab == tab
                    Button { activeTab = tab } label: {
                        VStack(spacing: 0) {
                            Text(tab)
                                .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                                .foregroundStyle(isActive ? Color(red: 0.32, green: 0.22, blue: 0.62) : .secondary)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                            Rectangle()
                                .fill(isActive ? Color(red: 0.32, green: 0.22, blue: 0.62) : Color.clear)
                                .frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .background(.background)

            if activeTab == "Workflow" {
                WorkflowView()
            } else {

            // ── Search + Sort (Clients tab only) ──────────────────────
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField("Search clients…", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color(.systemGray).opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Picker("Sort", selection: $sortOrder) {
                    ForEach(ClientSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 110)
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)
            .background(.background)

            // ── Header cards ─────────────────────────────────────────
            HStack(spacing: 12) {
                clientStatCard("Total Clients",
                               value: "\(store.clientGroups.count)",
                               icon: "person.2.fill", color: .purple)
                clientStatCard("Total Size",
                               value: ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file),
                               icon: "internaldrive.fill", color: .blue)
                clientStatCard("Drives Used",
                               value: "\(drivesUsed)",
                               icon: "externaldrive.fill", color: .orange)
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)

            // ── Client list ───────────────────────────────────────────
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredGroups) { group in
                        ClientGroupRow(
                            group: group,
                            drives: store.drives,
                            onTap: { selectedGroup = group }
                        )
                        Divider()
                    }
                }
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
                .padding(16)
            }
        }
            } // end Clients tab
        .navigationTitle("Clients")
        .onReceive(store.$searchNavigationClientKey) { key in
            guard let key else { return }
            if let group = store.clientGroups.first(where: { $0.key == key }) {
                selectedGroup = group
                store.searchNavigationClientKey = nil
            }
        }
        .overlay {
            if filteredGroups.isEmpty {
                ContentUnavailableView(
                    "No clients yet",
                    systemImage: "person.2",
                    description: Text(store.drives.isEmpty
                        ? "Connect a drive to auto-discover shoots"
                        : "No shoots found for connected drives")
                )
            }
        }
        // ── Client detail popup ───────────────────────────────────────
        .sheet(item: $selectedGroup) { group in
            ClientDetailSheet(group: group, drives: store.drives)
                .environmentObject(store)
        }
    }

    // MARK: - Stat card

    private func clientStatCard(_ label: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.12)).frame(width: 36, height: 36)
                Image(systemName: icon).foregroundStyle(color).font(.system(size: 16))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 18, weight: .semibold))
            }
            Spacer()
        }
        .padding(12)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
    }
}

// MARK: - Client group row (flat, click opens popup)

struct ClientGroupRow: View {
    @EnvironmentObject var store: AppStore
    let group: ClientGroup
    let drives: [Drive]
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(.purple.opacity(0.12)).frame(width: 36, height: 36)
                    Text(group.initials)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.purple)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.displayName)
                        .font(.system(size: 13, weight: .medium))
                    Text("\(group.shoots.count) shoot\(group.shoots.count != 1 ? "s" : "") · \(group.formattedTotalSize)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                LazyHStack(spacing: 6) {
                    ForEach(group.uniqueDriveIDs, id: \.self) { driveID in
                        if let drive = drives.first(where: { $0.id == driveID }) {
                            Label(drive.name, systemImage: "externaldrive")
                                .font(.system(size: 11))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(.secondary.opacity(0.1))
                                .clipShape(Capsule())
                        }
                    }
                }

                // Workflow badge
                let wf = store.workflow(for: group)
                Text(wf != nil ? wf!.progressDisplay : "+ Workflow")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(wf != nil ? Color.purple.opacity(0.1) : Color.red.opacity(0.08))
                    .foregroundStyle(wf != nil ? .purple : .red)
                    .clipShape(Capsule())

                Image(systemName: "chevron.right")
                    .font(.system(size: 13)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 11).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Client detail sheet (popup)

struct ClientDetailSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let group: ClientGroup
    let drives: [Drive]

    @State private var expandedShootID: Int64? = nil

    private var totalFileCount: Int64 {
        group.shoots.flatMap { store.folders(for: $0).filter { $0.depth == 0 } }
            .reduce(0) { $0 + $1.fileCount }
    }

    // Aggregate file types across all shoots
    private var allFileTypes: String {
        var counts: [String: Int] = [:]
        for shoot in group.shoots {
            for folder in store.folders(for: shoot).filter({ $0.depth == 0 }) {
                guard let types = folder.fileTypes else { continue }
                for part in types.split(separator: "·").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                    let pieces = part.split(separator: " ")
                    if pieces.count == 2, let n = Int(pieces[0]) {
                        let ext = String(pieces[1])
                        counts[ext, default: 0] += n
                    }
                }
            }
        }
        return counts.sorted { $0.value > $1.value }.prefix(6)
            .map { "\($0.value) \($0.key)" }.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(.purple.opacity(0.12)).frame(width: 48, height: 48)
                    Text(group.initials)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.purple)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.displayName)
                        .font(.system(size: 18, weight: .semibold))
                    Text("\(group.shoots.count) shoot\(group.shoots.count != 1 ? "s" : "")")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding(20)

            Divider()

            // Stat cards
            HStack(spacing: 10) {
                sheetStatCard("Total Size", value: group.formattedTotalSize)
                sheetStatCard("Total Files", value: totalFileCount > 0 ? "\(totalFileCount)" : "—")
                sheetStatCard("Drives", value: "\(group.uniqueDriveIDs.count)")
            }
            .padding(16)

            // File type breakdown
            if !allFileTypes.isEmpty {
                HStack {
                    Text("File Types")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.4)
                    Spacer()
                    Text(allFileTypes)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.bottom, 12)
            }

            Divider()

            // Shoots list
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(group.shoots) { shoot in
                        let shootFolders = store.folders(for: shoot)
                        let drive = drives.first { $0.id == shoot.driveID }
                        ClientShootRow(
                            shoot: shoot,
                            drive: drive,
                            folders: shootFolders,
                            isExpanded: expandedShootID == shoot.id,
                            onToggle: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    expandedShootID = expandedShootID == shoot.id ? nil : shoot.id
                                }
                            }
                        )
                        if shoot.id != group.shoots.last?.id {
                            Divider().padding(.leading, 62)
                        }
                    }
                }
            }
            Divider().padding(.horizontal, 16)
            WorkflowSummarySection(group: group)
                .environmentObject(store)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .frame(width: 600, height: 640)
    }

    private func sheetStatCard(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 16, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
    }
}

// MARK: - Client shoot row

struct ClientShootRow: View {
    let shoot: Shoot
    let drive: Drive?
    let folders: [DriveFolder]
    let isExpanded: Bool
    let onToggle: () -> Void

    private var rootFolders: [DriveFolder] {
        folders.filter { $0.depth == 0 }.sorted { $0.sizeBytes > $1.sizeBytes }
    }
    private var totalFileCount: Int64 { rootFolders.reduce(0) { $0 + $1.fileCount } }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 12) {
                    Color.clear.frame(width: 46)
                    Image(systemName: "camera").font(.system(size: 14)).foregroundStyle(.secondary)
                    Text(shoot.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer()
                    if let drive {
                        Label(drive.name, systemImage: "externaldrive")
                            .font(.system(size: 11))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(.secondary.opacity(0.1)).clipShape(Capsule())
                    }
                    if totalFileCount > 0 {
                        Text("\(totalFileCount) files").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    Text(shoot.formattedSize)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(minWidth: 60, alignment: .trailing)
                    Text(shoot.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .frame(minWidth: 88, alignment: .trailing)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isExpanded)
                }
                .padding(.horizontal, 16).padding(.vertical, 9).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(isExpanded ? Color(.systemGray).opacity(0.05) : .clear)

            if isExpanded {
                VStack(spacing: 0) {
                    Divider()
                    ForEach(rootFolders) { folder in
                        ClientFolderRow(folder: folder, shootTotalBytes: shoot.totalBytes)
                        if folder.id != rootFolders.last?.id { Divider().padding(.leading, 80) }
                    }
                    if rootFolders.isEmpty {
                        Text("No subfolders found").font(.callout).foregroundStyle(.tertiary).padding()
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.icloud").font(.system(size: 12)).foregroundStyle(.tertiary)
                        Text("Auto-scanned · available offline").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 80).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGray).opacity(0.03))
                }
                .transition(.opacity.combined(with: .slide))
            }
        }
    }
}

// MARK: - Client folder row

struct ClientFolderRow: View {
    let folder: DriveFolder
    let shootTotalBytes: Int64

    private var fraction: Double {
        shootTotalBytes > 0 ? Double(folder.sizeBytes) / Double(shootTotalBytes) : 0
    }

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 80)
            Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name).font(.system(size: 13)).lineLimit(1)
                if let types = folder.fileTypes, !types.isEmpty {
                    Text(types).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if folder.fileCount > 0 {
                Text(folder.formattedFileCount)
                    .font(.system(size: 10))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .foregroundStyle(.secondary).clipShape(Capsule())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.12)).frame(height: 3)
                    Capsule().fill(.purple.opacity(0.5))
                        .frame(width: geo.size.width * fraction, height: 3)
                }
            }
            .frame(width: 60, height: 3)
            Text(folder.formattedSize)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
    }
}
