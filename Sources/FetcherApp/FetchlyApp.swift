import SwiftUI
import AppKit
import FetcherCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DownloadStore.shared.startServices()
    }

    // Keep running in the menu bar so scheduled and browser-captured downloads still work.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        DownloadStore.shared.shutdown()
    }
}

@main
struct FetchlyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = DownloadStore.shared

    var body: some Scene {
        Window("Fetchly", id: "main") {
            MainView()
                .environmentObject(store)
                .frame(minWidth: 860, minHeight: 480)
        }
        .defaultSize(width: 1100, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add URL…") { store.requestAdd() }
                    .keyboardShortcut("n")
            }
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(store)
        } label: {
            Image(systemName: store.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
        }

        Settings {
            SettingsView().environmentObject(store)
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(store.activeCount > 0
             ? "\(store.activeCount) downloading · \(Format.speed(store.totalSpeed))"
             : "No active downloads")
        Divider()
        Button("Show Fetchly") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Add URL…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            store.requestAdd()
        }
        Button("Resume All") { store.resumeAllUnfinished() }
        Button("Stop All") { store.stopAll() }
        Divider()
        Button("Quit Fetchly") { NSApp.terminate(nil) }
    }
}
