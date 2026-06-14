import SwiftUI

// MARK: - Premium Color Constants

private extension Color {
    static let accent      = Color(red: 0.32, green: 0.22, blue: 0.62)
    static let accentLight = Color(red: 0.32, green: 0.22, blue: 0.62).opacity(0.10)
    static let accentMid   = Color(red: 0.32, green: 0.22, blue: 0.62).opacity(0.18)

    // Status colors — muted, professional
    static let statusGreen  = Color(red: 0.18, green: 0.58, blue: 0.42)
    static let statusAmber  = Color(red: 0.75, green: 0.52, blue: 0.18)
    static let statusBlue   = Color(red: 0.22, green: 0.42, blue: 0.72)
    static let statusGray   = Color(red: 0.52, green: 0.52, blue: 0.55)
}

// MARK: - Progress color helper (luxury gradient)

private func progressColor(_ percent: Double) -> Color {
    switch percent {
    case 0..<25:   return Color(red: 0.72, green: 0.12, blue: 0.12) // deep crimson
    case 25..<50:  return Color(red: 0.78, green: 0.38, blue: 0.08) // burnt orange
    case 50..<70:  return Color(red: 0.70, green: 0.58, blue: 0.08) // dark amber/gold
    case 70..<90:  return Color(red: 0.28, green: 0.62, blue: 0.30) // muted green
    default:       return Color(red: 0.12, green: 0.52, blue: 0.28) // deep emerald
    }
}

// MARK: - WorkflowView (tab inside ClientsView)

struct WorkflowView: View {
    @EnvironmentObject var store: AppStore
    @State private var filterStatus = "All"
    @State private var selectedGroup: ClientGroup? = nil

    private let filters = ["All", "Attached", "Pending", "In Progress", "Completed"]

    private var filteredGroups: [ClientGroup] {
        let groups = store.clientGroups
        switch filterStatus {
        case "Attached":    return groups.filter { store.workflow(for: $0) != nil }
        case "Pending":     return groups.filter { store.workflow(for: $0) == nil }
        case "In Progress":
            return groups.filter {
                if let wf = store.workflow(for: $0) {
                    return wf.progressPercent > 0 && wf.progressPercent < 100
                }
                return false
            }
        case "Completed":
            return groups.filter { store.workflow(for: $0)?.progressPercent ?? 0 >= 100 }
        default: return groups
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter pills only — no sort in Workflow
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(filters, id: \.self) { f in filterPill(f) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(.background)

            Divider()

            if filteredGroups.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checklist")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No workflows yet")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredGroups) { group in
                            WorkflowRowCard(group: group)
                                .onTapGesture { selectedGroup = group }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .sheet(item: $selectedGroup) { group in
            WorkflowEditorSheet(group: group)
                .environmentObject(store)
        }
    }

    private func filterPill(_ filter: String) -> some View {
        let isActive = filterStatus == filter
        return Button { filterStatus = filter } label: {
            Text(filter)
                .font(.system(size: 11, weight: isActive ? .medium : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isActive ? Color.accentLight : Color(.systemGray).opacity(0.08))
                .foregroundStyle(isActive ? Color.accent : .secondary)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(isActive ? Color.accent.opacity(0.4) : Color.clear, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - WorkflowRowCard

struct WorkflowRowCard: View {
    @EnvironmentObject var store: AppStore
    let group: ClientGroup

    var body: some View {
        let wf = store.workflow(for: group)
        let hasWF = wf != nil
        let progress = wf?.progressPercent ?? 0
        let pColor = progressColor(progress)

        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(avatarColor(for: group.displayName).opacity(0.12))
                    .frame(width: 38, height: 38)
                Text(group.initials)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(avatarColor(for: group.displayName))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(group.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)

                if let wf {
                    Text("\(wf.projectStartDate.formatted(date: .abbreviated, time: .omitted)) · \(wf.daysRunning) days running")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        statusChip("Photos", wf.editedPhotosStatus)
                        statusChip("Video",  wf.cinematicVideoStatus)
                        statusChip("Album",  wf.albumDesigningStatus)
                    }

                    // Progress bar — luxury gradient color
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color(.systemGray).opacity(0.12))
                                .frame(height: 3)
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(pColor)
                                .frame(width: geo.size.width * CGFloat(progress / 100), height: 3)
                        }
                    }
                    .frame(height: 3)
                    .padding(.top, 3)
                } else {
                    Text(group.formattedTotalSize + " · " + group.shoots.count.description + " shoots")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                if hasWF {
                    Text(wf!.progressDisplay)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(pColor.opacity(0.12))
                        .foregroundStyle(pColor)
                        .clipShape(Capsule())
                } else {
                    Text("+ Workflow")
                        .font(.system(size: 11, weight: .regular))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(.systemGray).opacity(0.10))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(14)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separatorColor), lineWidth: 0.5))
    }

    private func statusChip(_ label: String, _ status: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 5, height: 5)
            Text(status == "NA" ? label + ": N/A" : label + ": " + status)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "Delivered", "Shared":              return .statusGreen
        case "In Progress", "Pending":           return Color.accent
        case "Awaiting Client's Response":       return .statusAmber
        case "Started":                          return .statusBlue
        case "On Hold":                          return Color(red: 0.65, green: 0.25, blue: 0.18)
        case "Not Started", "Not Shared", "NA":  return .statusGray
        default:                                 return .statusGray.opacity(0.5)
        }
    }

    private func avatarColor(for name: String) -> Color {
        let colors: [Color] = [
            Color(red: 0.32, green: 0.22, blue: 0.62),
            Color(red: 0.18, green: 0.38, blue: 0.65),
            Color(red: 0.15, green: 0.50, blue: 0.45),
            Color(red: 0.45, green: 0.28, blue: 0.58),
            Color(red: 0.62, green: 0.38, blue: 0.18),
            Color(red: 0.22, green: 0.45, blue: 0.38),
            Color(red: 0.52, green: 0.28, blue: 0.42),
            Color(red: 0.28, green: 0.35, blue: 0.62),
        ]
        return colors[abs(name.hashValue) % colors.count]
    }
}

// MARK: - WorkflowSummarySection (embedded in client detail popup)

struct WorkflowSummarySection: View {
    @EnvironmentObject var store: AppStore
    let group: ClientGroup
    @State private var showEditor = false

    var body: some View {
        let wf = store.workflow(for: group)
        let progress = wf?.progressPercent ?? 0
        let pColor = progressColor(progress)

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Workflow")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accent)

                Spacer()

                if let wf {
                    Text("\(wf.progressDisplay) complete")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(pColor.opacity(0.12))
                        .foregroundStyle(pColor)
                        .clipShape(Capsule())
                }

                Button(wf != nil ? "Edit" : "+ Attach") {
                    showEditor = true
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.accent)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Color.accentLight)
                .clipShape(Capsule())
                .buttonStyle(.plain)
            }

            if let wf {
                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(.systemGray).opacity(0.12))
                            .frame(height: 4)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(pColor)
                            .frame(width: geo.size.width * CGFloat(progress / 100), height: 4)
                    }
                }
                .frame(height: 4)

                // Field rows
                VStack(spacing: 8) {
                    workflowRow("Selection Link",   wf.selectionLinkStatus)
                    workflowRow("Client HDD Copy",  wf.clientHDDCopyStatus)
                    workflowRow("Edited Photos",    wf.editedPhotosStatus)
                    workflowRow("Cinematic Video",  wf.cinematicVideoStatus)
                    workflowRow("Traditional Video",wf.traditionalVideoStatus)
                    workflowRow("Album Designing",  wf.albumDesigningStatus)
                    workflowRow("Project Status",   wf.completeProjectStatus)
                }
                .padding(.top, 2)

                if !wf.notes.isEmpty {
                    Text(wf.notes)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            } else {
                Text("No workflow attached. Tap + Attach to start tracking delivery.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            }
        }
        .padding(14)
        .background(Color(.systemGray).opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separatorColor), lineWidth: 0.5))
        .sheet(isPresented: $showEditor) {
            WorkflowEditorSheet(group: group)
                .environmentObject(store)
        }
    }

    private func workflowRow(_ label: String, _ status: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusDotColor(status))
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(status)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(statusTextColor(status))
            Spacer()
        }
    }

    private func statusDotColor(_ status: String) -> Color {
        switch status {
        case "Delivered", "Shared":              return .statusGreen
        case "In Progress", "Pending":           return Color.accent
        case "Awaiting Client's Response":       return .statusAmber
        case "Started":                          return .statusBlue
        case "On Hold":                          return Color(red: 0.65, green: 0.25, blue: 0.18)
        case "Not Started", "Not Shared", "NA":  return .statusGray
        default:                                 return .statusGray
        }
    }

    private func statusTextColor(_ status: String) -> Color {
        switch status {
        case "Delivered", "Shared":              return .statusGreen
        case "In Progress", "Pending":           return Color.accent
        case "Awaiting Client's Response":       return .statusAmber
        case "Started":                          return .statusBlue
        case "On Hold":                          return Color(red: 0.65, green: 0.25, blue: 0.18)
        case "NA":                               return .statusGray
        default:                                 return .secondary
        }
    }
}

// MARK: - WorkflowEditorSheet

struct WorkflowEditorSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let group: ClientGroup

    @State private var wf: ClientWorkflow
    @State private var showDeleteConfirm = false

    private let groupAOptions = ["Not Shared", "Pending", "On Hold", "Shared"]
    // Screenshot 3 shows: NA / Not Started / Started / In Progress / Awaiting Client's Response / On Hold / Delivered
    private let groupBOptions = ["NA", "Not Started", "Started", "In Progress",
                                 "Awaiting Client's Response", "On Hold", "Delivered"]
    private let projectStatusOptions = ["NA", "Not Started", "Started", "In Progress",
                                        "Awaiting Client's Response", "On Hold", "Delivered"]

    init(group: ClientGroup) {
        self.group = group
        _wf = State(initialValue: ClientWorkflow(clientName: group.displayName))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.displayName)
                        .font(.system(size: 15, weight: .semibold))
                    Text("\(wf.projectStartDate.formatted(date: .abbreviated, time: .omitted)) · \(wf.daysRunning) days running · \(wf.progressDisplay)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Progress ring — luxury gradient color
                let pColor = progressColor(wf.progressPercent)
                ZStack {
                    Circle()
                        .stroke(Color(.systemGray).opacity(0.15), lineWidth: 3)
                        .frame(width: 42, height: 42)
                    Circle()
                        .trim(from: 0, to: CGFloat(wf.progressPercent / 100))
                        .stroke(pColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 42, height: 42)
                        .rotationEffect(.degrees(-90))
                    Text(wf.progressDisplay)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(pColor)
                }

                Button("Done") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(.systemGray).opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.leading, 4)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.background)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {

                    sectionBlock("DELIVERY") {
                        segmentedField("Selection Link",  options: groupAOptions, binding: $wf.selectionLinkStatus)
                        segmentedField("Client HDD Copy", options: groupAOptions, binding: $wf.clientHDDCopyStatus)
                    }

                    Divider().padding(.vertical, 2)

                    sectionBlock("PRODUCTION") {
                        segmentedField("Edited Photos",     options: groupBOptions, binding: $wf.editedPhotosStatus)
                        segmentedField("Cinematic Video",   options: groupBOptions, binding: $wf.cinematicVideoStatus)
                        segmentedField("Traditional Video", options: groupBOptions, binding: $wf.traditionalVideoStatus)
                        segmentedField("Album Designing",   options: groupBOptions, binding: $wf.albumDesigningStatus)
                    }

                    Divider().padding(.vertical, 2)

                    sectionBlock("OVERALL") {
                        segmentedField("Complete Project Status",
                                       options: projectStatusOptions,
                                       binding: $wf.completeProjectStatus)
                    }

                    Divider().padding(.vertical, 2)

                    // Notes
                    VStack(alignment: .leading, spacing: 6) {
                        sectionLabel("NOTES")
                        TextEditor(text: $wf.notes)
                            .font(.system(size: 12))
                            .frame(minHeight: 60)
                            .padding(8)
                            .background(Color(.systemGray).opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(.separatorColor), lineWidth: 0.5))
                    }

                    // Action buttons
                    HStack {
                        if store.workflow(for: group) != nil {
                            Button(role: .destructive) {
                                showDeleteConfirm = true
                            } label: {
                                Text("Remove Workflow")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(red: 0.72, green: 0.18, blue: 0.18))
                            }
                            .buttonStyle(.plain)
                        }

                        Spacer()

                        Button("Save") {
                            store.saveWorkflow(wf)
                            store.logAppEvent(.settingsChanged,
                                detail: "Workflow saved for \(group.displayName)")
                            dismiss()
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(Color.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)
                }
                .padding(20)
            }
        }
        .frame(width: 560, height: 640)
        .onAppear {
            if let existing = store.workflow(for: group) {
                wf = existing
            } else {
                let latest = group.shoots.map { $0.createdAt }.max() ?? Date()
                wf.projectStartDate = latest
            }
        }
        .confirmationDialog("Remove workflow from \(group.displayName)?",
                           isPresented: $showDeleteConfirm,
                           titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                store.deleteWorkflow(for: group)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.8)
    }

    private func sectionBlock<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel(title)
            content()
        }
    }

    private func segmentedField(_ label: String, options: [String],
                                  binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)

            FlowLayout(spacing: 6) {
                ForEach(options, id: \.self) { option in
                    let isSelected = binding.wrappedValue == option
                    Button {
                        binding.wrappedValue = option
                    } label: {
                        Text(option)
                            .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(isSelected ? Color.accentLight : Color(.systemGray).opacity(0.08))
                            .foregroundStyle(isSelected ? Color.accent : Color(.labelColor).opacity(0.55))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(isSelected ? Color.accent.opacity(0.5) : Color(.separatorColor), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - FlowLayout (wrapping HStack)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let height = rows.map { $0.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0 }
                         .reduce(0) { $0 + $1 + spacing } - spacing
        return CGSize(width: proposal.width ?? 0, height: max(height, 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            for subview in row {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubview]] {
        var rows: [[LayoutSubview]] = [[]]
        var x: CGFloat = 0
        let maxWidth = proposal.width ?? .infinity
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && !rows[rows.count - 1].isEmpty {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(subview)
            x += size.width + spacing
        }
        return rows
    }
}

// MARK: - WorkflowPromptSheet

struct WorkflowPromptSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let group: ClientGroup
    let onAttach: () -> Void
    let onLater: () -> Void
    let onNever: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.accentLight)
                        .frame(width: 52, height: 52)
                    Image(systemName: "checklist")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.accent)
                }

                Text("Attach Workflow?")
                    .font(.system(size: 15, weight: .semibold))

                Text("\"\(group.displayName)\" has \(group.formattedTotalSize) of data.\nWould you like to track its delivery status?")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 28)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)

            Divider()

            VStack(spacing: 8) {
                Button {
                    dismiss()
                    onAttach()
                } label: {
                    Text("Attach Workflow")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .foregroundStyle(.white)
                        .background(Color.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                Button {
                    dismiss()
                    onLater()
                } label: {
                    Text("Do Later")
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .foregroundStyle(.primary)
                        .background(Color(.systemGray).opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                Button {
                    dismiss()
                    onNever()
                } label: {
                    Text("Never for this client")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .frame(width: 320)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
