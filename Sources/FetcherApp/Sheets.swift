import SwiftUI
import AppKit
import FetcherCore

// MARK: - Add URL

struct AddURLSheet: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var saveDir = Prefs.saveDir
    @State private var fileName = ""

    init(prefill: String = "") {
        _text = State(initialValue: prefill)
    }

    private var urls: [URL] {
        text.split(whereSeparator: \.isNewline)
            .compactMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
            .filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enter a new address to download").font(.headline)

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            Text("One address per line.").font(.caption).foregroundStyle(.secondary)

            LabeledContent("Save to") {
                HStack {
                    Text(saveDir).lineLimit(1).truncationMode(.head)
                    Button("Choose…") { chooseFolder() }
                }
            }
            if urls.count == 1 {
                TextField("File name (optional)", text: $fileName)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Download Later") { submit(start: false) }
                    .disabled(urls.isEmpty)
                Button("Start Download") { submit(start: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(urls.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func submit(start: Bool) {
        store.add(urls: urls, saveDir: saveDir, start: start,
                  fileName: urls.count == 1 ? fileName : nil)
        dismiss()
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        if p.runModal() == .OK, let u = p.url { saveDir = u.path }
    }
}

// MARK: - Details

struct DetailsView: View {
    let id: UUID
    @EnvironmentObject var store: DownloadStore
    @Environment(\.dismiss) private var dismiss

    private var record: DownloadRecord? { store.items.first { $0.id == id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let r = record {
                Text(r.fileName).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(r.url.absoluteString).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled)

                ProgressView(value: r.progress)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow { Text("Status").foregroundStyle(.secondary); Text(r.status.label) }
                    GridRow { Text("File size").foregroundStyle(.secondary); Text(Format.bytes(r.totalSize)) }
                    GridRow { Text("Downloaded").foregroundStyle(.secondary)
                        Text("\(Format.bytes(r.downloaded)) (\(String(format: "%.1f", r.progress * 100))%)") }
                    GridRow { Text("Transfer rate").foregroundStyle(.secondary)
                        Text(Format.speed(store.speeds[r.id] ?? 0)) }
                    GridRow { Text("Time left").foregroundStyle(.secondary)
                        Text(Format.eta(remaining: r.totalSize - r.downloaded, speed: store.speeds[r.id] ?? 0)) }
                    GridRow { Text("Resume support").foregroundStyle(.secondary)
                        Text(r.totalSize == 0 ? "Unknown" : (r.acceptsRanges ? "Yes" : "No")) }
                    GridRow { Text("Save to").foregroundStyle(.secondary)
                        Text(r.saveDir).lineLimit(1).truncationMode(.head) }
                }

                if !r.segments.isEmpty && r.totalSize > 0 {
                    Text("Connections").font(.subheadline)
                    SegmentBar(record: r).frame(height: 16)
                }
                if let e = r.errorMessage, r.status == .error {
                    Text(e).foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    if r.status == .downloading || r.status == .queued {
                        Button("Pause") { store.stop([id]) }
                    } else if r.status != .complete {
                        Button("Resume") { store.resume([id]) }
                    }
                    Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                Text("This download was removed.")
                Button("Close") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// Draws each connection's finished byte range along the file, like a segmented progress bar.
struct SegmentBar: View {
    let record: DownloadRecord

    var body: some View {
        GeometryReader { geo in
            let total = CGFloat(max(1, record.totalSize))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                ForEach(record.segments.indices, id: \.self) { i in
                    let s = record.segments[i]
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * CGFloat(s.done) / total)
                        .offset(x: geo.size.width * CGFloat(s.start) / total)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}
