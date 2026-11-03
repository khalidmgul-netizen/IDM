import Foundation

public enum DownloadStatus: String, Codable, CaseIterable {
    case queued, downloading, paused, complete, error

    public var label: String {
        switch self {
        case .queued: return "Queued"
        case .downloading: return "Downloading"
        case .paused: return "Stopped"
        case .complete: return "Complete"
        case .error: return "Error"
        }
    }
}

/// One connection's byte range. `end` is inclusive; -1 means unknown length.
public struct SegmentState: Codable, Equatable {
    public var start: Int64
    public var end: Int64
    public var done: Int64
    public var sealed: Bool

    public init(start: Int64, end: Int64, done: Int64 = 0, sealed: Bool = false) {
        self.start = start
        self.end = end
        self.done = done
        self.sealed = sealed
    }

    public var length: Int64 { end >= 0 ? end - start + 1 : -1 }
    public var isFinished: Bool { sealed || (end >= 0 && done >= length) }
}

public enum FileCategory: String, CaseIterable, Identifiable, Codable, Hashable {
    case compressed = "Compressed"
    case documents = "Documents"
    case music = "Music"
    case programs = "Programs"
    case video = "Video"
    case images = "Images"
    case other = "Other"

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .compressed: return "doc.zipper"
        case .documents: return "doc.text"
        case .music: return "music.note"
        case .programs: return "app.badge"
        case .video: return "film"
        case .images: return "photo"
        case .other: return "doc"
        }
    }

    public static func forFileName(_ name: String) -> FileCategory {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz", "zst", "cab", "lz":
            return .compressed
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "epub", "pages", "numbers", "key", "csv", "odt":
            return .documents
        case "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "wma", "aiff":
            return .music
        case "dmg", "pkg", "exe", "msi", "iso", "deb", "rpm", "appimage", "apk":
            return .programs
        case "mp4", "mkv", "mov", "avi", "webm", "flv", "wmv", "m4v", "mpg", "mpeg", "ts", "m3u8":
            return .video
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "tiff", "bmp", "svg":
            return .images
        default:
            return .other
        }
    }
}

public struct DownloadRecord: Codable, Identifiable, Equatable {
    public var id: UUID
    public var url: URL
    public var fileName: String
    /// True when the name was derived automatically (so the server's Content-Disposition may refine it).
    public var autoName: Bool
    public var saveDir: String
    /// 0 = not probed yet, -1 = unknown length, >0 = bytes
    public var totalSize: Int64
    public var acceptsRanges: Bool
    public var segments: [SegmentState]
    public var status: DownloadStatus
    public var addedAt: Date
    public var lastTry: Date?
    public var completedAt: Date?
    public var connections: Int
    public var errorMessage: String?
    public var referer: String?
    public var cookie: String?
    public var userAgent: String?

    public init(url: URL, fileName: String, saveDir: String, connections: Int = 8,
                autoName: Bool = true, referer: String? = nil, cookie: String? = nil,
                userAgent: String? = nil) {
        self.id = UUID()
        self.url = url
        self.fileName = fileName
        self.autoName = autoName
        self.saveDir = saveDir
        self.totalSize = 0
        self.acceptsRanges = false
        self.segments = []
        self.status = .paused
        self.addedAt = Date()
        self.connections = connections
        self.referer = referer
        self.cookie = cookie
        self.userAgent = userAgent
    }

    public var downloaded: Int64 { segments.reduce(0) { $0 + $1.done } }
    public var progress: Double {
        if status == .complete { return 1 }
        return totalSize > 0 ? min(1, Double(downloaded) / Double(totalSize)) : 0
    }
    public var category: FileCategory { FileCategory.forFileName(fileName) }
    public var saveDirURL: URL { URL(fileURLWithPath: saveDir, isDirectory: true) }
    public var finalURL: URL { saveDirURL.appendingPathComponent(fileName) }
    public var partURL: URL { saveDirURL.appendingPathComponent(fileName + ".part") }
    public var lastTrySort: Date { lastTry ?? .distantPast }
}

public enum Format {
    public static func bytes(_ n: Int64) -> String {
        n <= 0 ? "—" : ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    public static func speed(_ bytesPerSecond: Double) -> String {
        bytesPerSecond < 1 ? "" : ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    public static func eta(remaining: Int64, speed: Double) -> String {
        guard speed > 1, remaining > 0 else { return "" }
        let s = Int(Double(remaining) / speed)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, sec) }
        return "\(sec) sec"
    }
}
