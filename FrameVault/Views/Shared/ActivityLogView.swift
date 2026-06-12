import SwiftUI
import UniformTypeIdentifiers

// MARK: - AppEvent Kind

enum AppEventKind: String, CaseIterable {
    case appInstalled      = "app_installed"
    case appReset          = "app_reset"
    case databaseReset     = "database_reset"
    case licenseActivated  = "license_activated"
    case driveConnected    = "drive_connected"
    case driveDisconnected = "drive_disconnected"
    case driveRemoved      = "drive_removed"
    case reindexTriggered  = "reindex_triggered"
    case exportDone        = "export_done"
    case settingsChanged   = "settings_changed"
    case cloudSync         = "cloud_sync"
    case tokenSync         = "token_sync"
    case appOpened         = "app_opened"
    case appClosed         = "app_closed"
    case indexComplete     = "index_complete"
    case indexSkipped      = "index_skipped"
    case activityLogReset  = "activity_log_reset"
    case databaseRestored  = "database_restored"
    case passcodeChanged   = "passcode_changed"

    var label: String {
        switch self {
        case .appInstalled:     return "App installed"
        case .appReset:         return "App reset"
        case .databaseReset:    return "Database reset"
        case .licenseActivated: return "License activated"
        case .driveConnected:   return "Drive connected"
        case .driveDisconnected:return "Drive disconnected"
        case .driveRemoved:     return "Drive removed"
        case .reindexTriggered: return "Re-index triggered"
        case .exportDone:       return "Export done"
        case .settingsChanged:  return "Settings changed"
        case .cloudSync:        return "Cloud sync"
        case .tokenSync:        return "Token sync"
        case .appOpened:        return "App opened"
        case .appClosed:        return "App closed"
        case .indexComplete:    return "Index complete"
        case .indexSkipped:     return "Index skipped"
        case .activityLogReset: return "Activity log reset"
        case .databaseRestored: return "Database restored"
        case .passcodeChanged:  return "Passcode changed"
        }
    }

    var icon: String {
        switch self {
        case .appInstalled:     return "app.badge.checkmark"
        case .appReset:         return "arrow.counterclockwise.circle"
        case .databaseReset:    return "cylinder.split.1x2"
        case .licenseActivated: return "checkmark.seal.fill"
        case .driveConnected:   return "externaldrive.fill.badge.plus"
        case .driveDisconnected:return "externaldrive.badge.minus"
        case .driveRemoved:     return "trash"
        case .reindexTriggered: return "arrow.clockwise"
        case .exportDone:       return "square.and.arrow.up"
        case .settingsChanged:  return "gearshape"
        case .cloudSync:        return "icloud.and.arrow.up"
        case .tokenSync:        return "key.horizontal"
        case .appOpened:        return "power"
        case .appClosed:        return "power.dotted"
        case .indexComplete:    return "checkmark.circle.fill"
        case .indexSkipped:     return "forward.fill"
        case .activityLogReset: return "clock.badge.xmark"
        case .databaseRestored: return "arrow.counterclockwise.circle"
        case .passcodeChanged:  return "lock.rotation"
        }
    }

    var color: Color {
        switch self {
        case .appInstalled:     return .purple
        case .appReset:         return .red
        case .databaseReset:    return .orange
        case .licenseActivated: return .green
        case .driveConnected:   return .green
        case .driveDisconnected:return .gray
        case .driveRemoved:     return .red
        case .reindexTriggered: return .blue
        case .exportDone:       return .teal
        case .settingsChanged:  return .gray
        case .cloudSync:        return .cyan
        case .tokenSync:        return .indigo
        case .appOpened:        return .green
        case .appClosed:        return .secondary
        case .indexComplete:    return .green
        case .indexSkipped:     return .orange
        case .activityLogReset: return .red
        case .databaseRestored: return .purple
        case .passcodeChanged:  return .indigo
        }
    }
}

// MARK: - AppEvent Model

struct AppEvent: Identifiable {
    let id: Int64
    let kind: AppEventKind
    let detail: String
    let occurredAt: Date
}

// MARK: - Time Filter

enum ActivityTimeFilter: String, CaseIterable {
    case last7   = "Last 7 days"
    case last30  = "Last 30 days"
    case last90  = "Last 90 days"
    case allTime = "All time"

    var days: Int? {
        switch self {
        case .last7:   return 7
        case .last30:  return 30
        case .last90:  return 90
        case .allTime: return nil
        }
    }
}

// MARK: - ActivityLogView

struct ActivityLogView: View {
    @EnvironmentObject var store: AppStore
    @State private var timeFilter: ActivityTimeFilter = .last30
    @State private var exportCSV: ExportFile? = nil
    @State private var exportPDF: ExportFile? = nil
    @State private var showCSVExporter = false
    @State private var showPDFExporter = false

    // Pull from store — app-level events only
    private var allEvents: [ActivityEvent] { store.recentActivity }

    private var filtered: [ActivityEvent] {
        guard let days = timeFilter.days else { return allEvents }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
        return allEvents.filter { $0.occurredAt >= cutoff }
    }

    // MARK: Stats
    private var totalEvents: Int    { filtered.count }
    private var reindexCount: Int   { filtered.filter { $0.kind == .reindexed }.count }
    private var connectedCount: Int { filtered.filter { $0.kind == .driveConnected }.count }
    private var removedCount: Int   { filtered.filter { $0.kind == .folderRemoved }.count }

    var body: some View {
        VStack(spacing: 0) {

            // ── Top bar ──────────────────────────────────────────────
            HStack(spacing: 10) {
                // Install date
                if let date = store.appInstallDate {
                    Text("Installed \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()

                // Time filter picker
                Picker("", selection: $timeFilter) {
                    ForEach(ActivityTimeFilter.allCases, id: \.self) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 130)
                .font(.system(size: 12))

                // Export
                Menu {
                    Button {
                        exportCSV = makeCSVExport()
                        showCSVExporter = true
                        store.logAppEvent(.exportDone, detail: "Activity log exported as CSV")
                    } label: { Label("Export as CSV", systemImage: "tablecells") }
                    Button {
                        exportPDF = makePDFExport()
                        showPDFExporter = true
                        store.logAppEvent(.exportDone, detail: "Activity log exported as PDF")
                    } label: { Label("Export as PDF", systemImage: "doc.richtext") }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Export")
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.background.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator, lineWidth: 0.5))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()


            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.background)

            Divider()

            // ── Stat cards ───────────────────────────────────────────
            HStack(spacing: 12) {
                statCard("Total Events",     value: "\(totalEvents)")
                statCard("Re-indexed",       value: "\(reindexCount)")
                statCard("Drives Connected", value: "\(connectedCount)")
                statCard("Drives Removed",   value: "\(removedCount)")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.background)

            Divider()

            // ── Event list ───────────────────────────────────────────
            if filtered.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.badge.xmark")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("No activity in this period")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { event in
                            eventRow(event)
                            Divider().padding(.leading, 44)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle("Activity Log")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    store.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh activity log")
            }
        }
        .fileExporter(
            isPresented: $showCSVExporter,
            document: exportCSV,
            contentType: .commaSeparatedText,
            defaultFilename: "DriveVault_Activity_\(dateStamp()).csv"
        ) { _ in }
        .fileExporter(
            isPresented: $showPDFExporter,
            document: exportPDF,
            contentType: .pdf,
            defaultFilename: "DriveVault_Activity_\(dateStamp()).pdf"
        ) { _ in }

    }

    // MARK: Stat Card

    private func statCard(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
    }

    // MARK: Event Row

    private func eventRow(_ event: ActivityEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Colored dot
            Circle()
                .fill(event.kind.color)
                .frame(width: 10, height: 10)
                .padding(.top, 4)

            // Icon
            Image(systemName: event.kind.icon)
                .font(.system(size: 13))
                .foregroundStyle(event.kind.color)
                .frame(width: 16)
                .padding(.top, 1)

            // Text
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if !event.subtitle.isEmpty {
                    Text(event.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            // Timestamp
            Text(event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: Export

    private func makeCSVExport() -> ExportFile {
        var lines = ["Date,Time,Event,Detail"]
        for event in filtered {
            let date   = event.occurredAt.formatted(date: .abbreviated, time: .omitted)
            let time   = event.occurredAt.formatted(date: .omitted, time: .shortened)
            let detail = event.subtitle.replacingOccurrences(of: ",", with: ";")
            lines.append("\(date),\(time),\(event.title),\(detail)")
        }
        return ExportFile(csvContent: lines.joined(separator: "\n"))
    }

    private func makePDFExport() -> ExportFile {
        var html = """
        <html><head><style>
        body { font-family: -apple-system, sans-serif; margin: 40px; color: #1a1a1a; }
        h1 { font-size: 22px; margin-bottom: 4px; }
        .sub { color: #888; font-size: 13px; margin-bottom: 24px; }
        table { width: 100%; border-collapse: collapse; font-size: 13px; }
        th { text-align: left; padding: 8px 12px; background: #f5f5f7; border-bottom: 1px solid #e0e0e0; }
        td { padding: 8px 12px; border-bottom: 1px solid #f0f0f0; vertical-align: top; }
        .kind { font-weight: 600; }
        .detail { color: #555; }
        </style></head><body>
        <h1>Drive Vault — Activity Log</h1>
        <div class="sub">Exported \(Date().formatted(date: .long, time: .shortened)) · \(filtered.count) events</div>
        <table><tr><th>Date</th><th>Time</th><th>Event</th><th>Detail</th></tr>
        """
        for event in filtered {
            let date   = event.occurredAt.formatted(date: .abbreviated, time: .omitted)
            let time   = event.occurredAt.formatted(date: .omitted, time: .shortened)
            html += "<tr><td>\(date)</td><td>\(time)</td><td class='kind'>\(event.title)</td><td class='detail'>\(event.subtitle)</td></tr>"
        }
        html += "</table></body></html>"
        return ExportFile(htmlContent: html)
    }

    private func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

// MARK: - ExportFile (FileDocument)

struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .pdf, .plainText] }
    let data: Data
    let type: UTType

    // CSV init
    init(csvContent: String) {
        self.data = csvContent.data(using: .utf8) ?? Data()
        self.type = .commaSeparatedText
    }

    // PDF init — renders HTML to real PDF using WebKit
    init(htmlContent: String) {
        self.data = ExportFile.renderHTMLtoPDF(htmlContent)
        self.type = .pdf
    }

    init(configuration: ReadConfiguration) throws {
        data = Data()
        type = .plainText
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }

    // MARK: HTML → PDF via NSPrintOperation + WKWebView

    static func renderHTMLtoPDF(_ html: String) -> Data {
        // Use NSAttributedString HTML rendering for a lightweight real PDF
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard
            let htmlData = html.data(using: .utf8),
            let attrStr = try? NSAttributedString(data: htmlData, options: options, documentAttributes: nil)
        else {
            return html.data(using: .utf8) ?? Data()
        }

        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        printInfo.paperSize = NSSize(width: 595, height: 842) // A4
        printInfo.leftMargin   = 40
        printInfo.rightMargin  = 40
        printInfo.topMargin    = 40
        printInfo.bottomMargin = 40
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination   = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered   = false

        let container = NSTextContainer(size: CGSize(
            width: printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin,
            height: .greatestFiniteMagnitude
        ))
        let layoutMgr = NSLayoutManager()
        let textStorage = NSTextStorage(attributedString: attrStr)
        textStorage.addLayoutManager(layoutMgr)
        layoutMgr.addTextContainer(container)

        // Paginate
        var pageRanges: [NSRange] = []
        let pageHeight = printInfo.paperSize.height - printInfo.topMargin - printInfo.bottomMargin
        var glyphIdx = 0
        let totalGlyphs = layoutMgr.numberOfGlyphs
        while glyphIdx < totalGlyphs {
            var lineRange = NSRange()
            layoutMgr.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: &lineRange)
            var rangeEnd = lineRange.upperBound
            var usedHeight: CGFloat = 0
            var scanIdx = glyphIdx
            while scanIdx < totalGlyphs {
                var fragRange = NSRange()
                let rect = layoutMgr.lineFragmentRect(forGlyphAt: scanIdx, effectiveRange: &fragRange)
                if usedHeight + rect.height > pageHeight { break }
                usedHeight += rect.height
                scanIdx = fragRange.upperBound
                rangeEnd = scanIdx
            }
            pageRanges.append(NSRange(location: glyphIdx, length: rangeEnd - glyphIdx))
            glyphIdx = rangeEnd
        }
        if pageRanges.isEmpty {
            pageRanges = [NSRange(location: 0, length: totalGlyphs)]
        }

        let pdfData = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: printInfo.paperSize)
        guard let ctx = CGContext(consumer: CGDataConsumer(data: pdfData)!, mediaBox: &mediaBox, nil) else {
            return html.data(using: .utf8) ?? Data()
        }

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)

        for range in pageRanges {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsCtx
            let origin = CGPoint(x: printInfo.leftMargin, y: printInfo.bottomMargin)
            layoutMgr.drawGlyphs(forGlyphRange: range, at: origin)
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return pdfData as Data
    }
}
