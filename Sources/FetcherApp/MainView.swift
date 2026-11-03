import SwiftUI
import AppKit
import FetcherCore

enum SidebarSelection: Hashable {
    case all, unfinished, finished
    case category(FileCategory)

    func matches(_ r: DownloadRecord) -> Bool {
        switch self {
        case .all: return true
        case .unfinished: return r.status != .complete
        case .finished: return r.status == .complete
        case .category(let c): return r.category == c
        }
    }

    var title: String {
        switch self {
        case .all: return "All Downloads"
        case .unfinished: return "Unfinished"
        case .finished: return "Finished"
        case .category(let c): return c.rawValue
        }
    }
}

struct DetailsTarget: Identifiable { let id: UUID }

struct MainView: View {
    @EnvironmentObject var store: DownloadStore
    @State private var selection: SidebarSelection? = .all
    @State private var rowSelection = Set<UUID>()
    @State private var sortOrder = [KeyPathComparator(\DownloadRecord.addedAt, order: .reverse)]
    @State private var query = ""
    @State private var details: DetailsTarget?
    @State private var lastPasteboardCount = NSPasteboard.general.changeCount

    private var rows: [DownloadRecord] {
        let sel = selection ?? .all
        return store.items
            .filter { sel.matches($0) }
            .filter { query.isEmpty || $0.fileName.localizedCaseInsensitiveContains(query)
                        || $0.url.absoluteString.localizedCaseInsensitiveContains(query) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
        } detail: {
            DownloadTable(rows: rows, selection: $rowSelection, sortOrder: $sortOrder) { id in
                details = DetailsTarget(id: id)
            }
            .navigationTitle((selection ?? .all).title)
            .searchable(text: $query, prompt: "Search downloads")
            .safeAreaInset(edge: .bottom) { StatusBar() }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { store.requestAdd() } label: {
                    Label("Add URL", systemImage: "plus.circle")
                }
                .help("Add a new download")

                Button { store.resume(rowSelection) } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .disabled(rowSelection.isEmpty)
                .help("Resume selected")

                Button { store.stop(rowSelection) } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(rowSelection.isEmpty)
                .help("Stop selected")

                Button { store.stopAll() } label: {
                    Label("Stop All", systemImage: "stop.circle")
                }
                .help("Stop all downloads")

                Button(role: .destructive) {
                    store.remove(rowSelection, deleteFile: false)
                    rowSelection = []
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(rowSelection.isEmpty)
                .help("Remove selected from the list")

                SettingsLink {
                    Label("Options", systemImage: "gearshape")
                }
                .help("Options and scheduler")
            }
        }
        .sheet(isPresented: $store.showAddSheet) {
            AddURLSheet(prefill: store.addPrefill)
        }
        .sheet(item: $details) { target in
            DetailsView(id: target.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkClipboard()
        }
    }

    /// When the app is activated and the clipboard holds a link to a known file type, offer to download it.
    private func checkClipboard() {
        guard Prefs.watchClipboard else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastPasteboardCount else { return }
        lastPasteboardCount = pb.changeCount
        guard let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let u = URL(string: s),
              ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
              FileCategory.forFileName(u.lastPathComponent) != .other else { return }
        store.requestAdd(prefill: s)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Binding var selection: SidebarSelection?
    @EnvironmentObject var store: DownloadStore

    var body: some View {
        List(selection: $selection) {
            Label("All Downloads", systemImage: "tray.full")
                .badge(store.count(in: .all))
                .tag(SidebarSelection.all)

            Section("Categories") {
                ForEach(FileCategory.allCases) { c in
                    Label(c.rawValue, systemImage: c.symbol)
                        .badge(store.count(in: .category(c)))
                        .tag(SidebarSelection.category(c))
                }
            }

            Section("Status") {
                Label("Unfinished", systemImage: "arrow.down.circle")
                    .badge(store.count(in: .unfinished))
                    .tag(SidebarSelection.unfinished)
                Label("Finished", systemImage: "checkmark.circle")
                    .badge(store.count(in: .finished))
                    .tag(SidebarSelection.finished)
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Table

struct DownloadTable: View {
    let rows: [DownloadRecord]
    @Binding var selection: Set<UUID>
    @Binding var sortOrder: [KeyPathComparator<DownloadRecord>]
    var onDetails: (UUID) -> Void
    @EnvironmentObject var store: DownloadStore

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("File Name", value: \.fileName) { r in
                HStack(spacing: 6) {
                    Image(systemName: r.category.symbol).foregroundStyle(.secondary)
                    Text(r.fileName).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 180, ideal: 300)

            TableColumn("Size", value: \.totalSize) { r in
                Text(Format.bytes(r.totalSize)).monospacedDigit()
            }
            .width(min: 70, ideal: 90)

            TableColumn("Status") { r in
                StatusCell(record: r)
            }
            .width(min: 110, ideal: 150)

            TableColumn("Time Left") { r in
                Text(Format.eta(remaining: r.totalSize - r.downloaded, speed: store.speeds[r.id] ?? 0))
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 90)

            TableColumn("Transfer Rate") { r in
                Text(Format.speed(store.speeds[r.id] ?? 0)).monospacedDigit()
            }
            .width(min: 90, ideal: 110)

            TableColumn("Last Try", value: \.lastTrySort) { r in
                Text(r.lastTry?.formatted(date: .abbreviated, time: .shortened) ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 150)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if !ids.isEmpty {
                Button("Resume") { store.resume(ids) }
                Button("Stop") { store.stop(ids) }
                Divider()
                Button("Open") { ids.forEach { store.open($0) } }
                Button("Show in Finder") { store.reveal(ids) }
                Button("Copy Address") {
                    let text = store.items.filter { ids.contains($0.id) }.map { $0.url.absoluteString }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Properties…") { if let id = ids.first { onDetails(id) } }
                Divider()
                Button("Redownload") { ids.forEach { store.redownload($0) } }
                Button("Delete") { store.remove(ids, deleteFile: false) }
                Button("Delete and Move File to Trash") { store.remove(ids, deleteFile: true) }
            }
        } primaryAction: { ids in
            guard let id = ids.first, let r = store.items.first(where: { $0.id == id }) else { return }
            if r.status == .complete { store.open(id) } else { onDetails(id) }
        }
    }
}

struct StatusCell: View {
    let record: DownloadRecord

    var body: some View {
        switch record.status {
        case .downloading:
            if record.totalSize > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.1f%%", record.progress * 100)).font(.caption).monospacedDigit()
                    ProgressView(value: record.progress)
                }
            } else {
                Text("Downloading…")
            }
        case .error:
            Text(record.errorMessage ?? "Error").foregroundStyle(.red).lineLimit(1)
        case .complete:
            Label("Complete", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .paused:
            Text(record.downloaded > 0 ? String(format: "Stopped %.0f%%", record.progress * 100) : "Stopped")
                .foregroundStyle(.secondary)
        case .queued:
            Text("Queued").foregroundStyle(.secondary)
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject var store: DownloadStore

    var body: some View {
        HStack {
            Text("\(store.activeCount) active · \(store.items.count) total")
            Spacer()
            if store.totalSpeed > 0 {
                Label(Format.speed(store.totalSpeed), systemImage: "arrow.down")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
