import Foundation

/// Thin wrapper over UserDefaults. Keys match the @AppStorage keys in SettingsView.
enum Prefs {
    private static let d = UserDefaults.standard

    static var defaultSaveDir: String {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
    }

    static var saveDir: String { d.string(forKey: "saveDir") ?? defaultSaveDir }
    static var connections: Int { min(32, max(1, d.object(forKey: "connections") as? Int ?? 8)) }
    static var maxSimultaneous: Int { min(16, max(1, d.object(forKey: "maxSimultaneous") as? Int ?? 3)) }
    /// KB/s across all downloads; 0 = unlimited
    static var speedLimitKB: Int { max(0, d.object(forKey: "speedLimitKB") as? Int ?? 0) }
    static var watchClipboard: Bool { d.object(forKey: "watchClipboard") as? Bool ?? true }

    static let capturePort: UInt16 = 6811

    /// Shared secret the browser extension must send, so random web pages can't queue downloads.
    static var token: String {
        if let t = d.string(forKey: "captureToken") { return t }
        let t = UUID().uuidString
        d.set(t, forKey: "captureToken")
        return t
    }
}
