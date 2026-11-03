import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            SchedulerSettings().tabItem { Label("Scheduler", systemImage: "clock") }
            BrowserSettings().tabItem { Label("Browser", systemImage: "globe") }
        }
        .frame(width: 520, height: 360)
    }
}

private struct GeneralSettings: View {
    @AppStorage("saveDir") private var saveDir = Prefs.defaultSaveDir
    @AppStorage("connections") private var connections = 8
    @AppStorage("maxSimultaneous") private var maxSimultaneous = 3
    @AppStorage("speedLimitKB") private var speedLimitKB = 0
    @AppStorage("watchClipboard") private var watchClipboard = true

    var body: some View {
        Form {
            LabeledContent("Default folder") {
                HStack {
                    Text(saveDir).lineLimit(1).truncationMode(.head)
                    Button("Choose…") {
                        let p = NSOpenPanel()
                        p.canChooseDirectories = true
                        p.canChooseFiles = false
                        p.canCreateDirectories = true
                        if p.runModal() == .OK, let u = p.url { saveDir = u.path }
                    }
                }
            }
            Stepper("Connections per download: \(connections)", value: $connections, in: 1...32)
            Stepper("Simultaneous downloads: \(maxSimultaneous)", value: $maxSimultaneous, in: 1...16)
            TextField("Speed limit (KB/s, 0 = unlimited)", value: $speedLimitKB, format: .number)
            Toggle("Offer to download links copied to the clipboard", isOn: $watchClipboard)
        }
        .formStyle(.grouped)
    }
}

private struct SchedulerSettings: View {
    @AppStorage("schedEnabled") private var enabled = false
    @AppStorage("schedStartMinutes") private var startMinutes = 120
    @AppStorage("schedStopEnabled") private var stopEnabled = false
    @AppStorage("schedStopMinutes") private var stopMinutes = 360

    var body: some View {
        Form {
            Toggle("Start unfinished downloads on a schedule", isOn: $enabled)
            TimePicker(label: "Start at", minutes: $startMinutes).disabled(!enabled)
            Toggle("Stop downloads at a set time", isOn: $stopEnabled).disabled(!enabled)
            TimePicker(label: "Stop at", minutes: $stopMinutes).disabled(!enabled || !stopEnabled)
            Text("Fetchly must be running (it stays in the menu bar when the window is closed).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct TimePicker: View {
    let label: String
    @Binding var minutes: Int

    var body: some View {
        LabeledContent(label) {
            HStack {
                Picker("Hour", selection: Binding(get: { minutes / 60 }, set: { minutes = $0 * 60 + minutes % 60 })) {
                    ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
                .labelsHidden().frame(width: 70)
                Text(":")
                Picker("Minute", selection: Binding(get: { minutes % 60 }, set: { minutes = (minutes / 60) * 60 + $0 })) {
                    ForEach(0..<60, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
                .labelsHidden().frame(width: 70)
            }
        }
    }
}

private struct BrowserSettings: View {
    var body: some View {
        Form {
            LabeledContent("Local port") { Text("127.0.0.1:\(String(Prefs.capturePort))") }
            LabeledContent("Access token") {
                HStack {
                    Text(Prefs.token).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Prefs.token, forType: .string)
                    }
                }
            }
            Text("Load the Extension folder in chrome://extensions (Developer mode → Load unpacked), open its options, and paste this token. Browser downloads are then sent to Fetchly.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
