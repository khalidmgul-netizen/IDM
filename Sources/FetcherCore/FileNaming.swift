import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum FileNaming {
    public static func sanitize(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if out.hasPrefix(".") { out = "_" + String(out.dropFirst()) }
        return out.isEmpty ? "download" : out
    }

    public static func fromURL(_ url: URL) -> String {
        let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let name = (last.isEmpty || last == "/") ? (url.host ?? "download") : last
        return sanitize(name)
    }

    public static func fromResponse(_ http: HTTPURLResponse?, url: URL) -> String {
        if let cd = http?.value(forHTTPHeaderField: "Content-Disposition"),
           let n = parseDisposition(cd) {
            return sanitize(n)
        }
        return fromURL(url)
    }

    /// Returns the filename from a Content-Disposition header if present.
    public static func parseDisposition(_ header: String) -> String? {
        if let m = firstMatch(#"filename\*\s*=\s*[^']*'[^']*'([^;]+)"#, in: header) {
            return m.removingPercentEncoding ?? m
        }
        if let m = firstMatch(#"filename\s*=\s*"([^"]+)""#, in: header)
            ?? firstMatch(#"filename\s*=\s*([^;\s]+)"#, in: header) {
            return m
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// "name.ext" -> "name (1).ext" until it doesn't exist in `dir` or in `taken`.
    public static func uniqueName(_ name: String, in dir: URL, avoiding taken: Set<String> = []) -> String {
        let fm = FileManager.default
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        var candidate = name
        var i = 1
        while fm.fileExists(atPath: dir.appendingPathComponent(candidate).path) || taken.contains(candidate) {
            candidate = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            i += 1
        }
        return candidate
    }
}

public enum Persistence {
    public static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Fetchly", isDirectory: true)
    }

    private static var file: URL { supportDir.appendingPathComponent("downloads.json") }

    public static func load() -> [DownloadRecord] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([DownloadRecord].self, from: data)) ?? []
    }

    public static func save(_ items: [DownloadRecord]) {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(items) {
            try? data.write(to: file, options: .atomic)
        }
    }
}
