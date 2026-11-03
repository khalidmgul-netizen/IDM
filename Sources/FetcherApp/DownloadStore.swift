import AppKit
import Combine
import Foundation
import FetcherCore

/// App-wide state: the list, the queue, persistence, scheduler and browser capture.
/// Always used from the main thread; engine callbacks hop to main before touching it.
final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()

    @Published var items: [DownloadRecord] = []
    @Published var speeds: [UUID: Double] = [:]
    @Published var showAddSheet = false
    var addPrefill = ""

    private var tasks: [UUID: DownloadTask] = [:]
    private var saveScheduled = false
    private let server = CaptureServer()
    private var schedulerTimer: Timer?
    private var lastFiredMinute = -1

    var totalSpeed: Double { speeds.values.reduce(0, +) }
    var activeCount: Int { items.filter { $0.status == .downloading }.count }

    init() {
        items = Persistence.load().map { rec in
            var r = rec
            if r.status == .downloading || r.status == .queued { r.status = .paused }
            return r
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.applyLimits()
        }
    }

    // MARK: Services

    func startServices() {
        server.token = Prefs.token
        server.onAdd = { [weak self] cap in
            DispatchQueue.main.async { self?.addCaptured(cap) }
        }
        server.start(port: Prefs.capturePort)

        schedulerTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.schedulerTick()
        }
    }

    func shutdown() {
        for (id, task) in tasks {
            let rec = task.pauseSync()
            if let i = items.firstIndex(where: { $0.id == id }) { items[i] = rec }
        }
        for i in items.indices where items[i].status == .queued { items[i].status = .paused }
        Persistence.save(items)
    }

    // MARK: Adding

    func requestAdd(prefill: String = "") {
        addPrefill = prefill
        showAddSheet = true
    }

    func add(urls: [URL], saveDir: String, start: Bool, fileName: String? = nil,
             referer: String? = nil, cookie: String? = nil, userAgent: String? = nil) {
        for url in urls {
            let taken = Set(items.filter { $0.saveDir == saveDir }.map { $0.fileName })
            let given = fileName.flatMap { $0.isEmpty ? nil : FileNaming.sanitize($0) }
            let base = given ?? FileNaming.fromURL(url)
            let name = FileNaming.uniqueName(base, in: URL(fileURLWithPath: saveDir), avoiding: taken)
            var rec = DownloadRecord(url: url, fileName: name, saveDir: saveDir,
                                     connections: Prefs.connections, autoName: given == nil,
                                     referer: referer, cookie: cookie, userAgent: userAgent)
            rec.status = start ? .queued : .paused
            items.insert(rec, at: 0)
        }
        scheduleSave()
        pump()
    }

    private func addCaptured(_ cap: CaptureRequest) {
        guard let url = URL(string: cap.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        add(urls: [url], saveDir: Prefs.saveDir, start: true,
            fileName: cap.filename, referer: cap.referer, cookie: cap.cookie, userAgent: cap.userAgent)
    }

    // MARK: Control

    func resume(_ ids: Set<UUID>) {
        for i in items.indices where ids.contains(items[i].id) {
            if items[i].status == .paused || items[i].status == .error {
                items[i].status = .queued
                items[i].errorMessage = nil
            }
        }
        pump()
        scheduleSave()
    }

    func resumeAllUnfinished() {
        resume(Set(items.filter { $0.status != .complete }.map { $0.id }))
    }

    func stop(_ ids: Set<UUID>) {
        for i in items.indices where ids.contains(items[i].id) {
            switch items[i].status {
            case .queued:
                items[i].status = .paused
            case .downloading:
                if let t = tasks[items[i].id] { t.pause() } else { items[i].status = .paused }
            default:
                break
            }
        }
        scheduleSave()
    }

    func stopAll() { stop(Set(items.map { $0.id })) }

    func remove(_ ids: Set<UUID>, deleteFile: Bool) {
        let fm = FileManager.default
        for id in ids {
            tasks[id]?.pause()
            tasks[id] = nil
            speeds[id] = nil
            guard let it = items.first(where: { $0.id == id }) else { continue }
            if it.status != .complete {
                try? fm.removeItem(at: it.partURL)
            } else if deleteFile {
                try? fm.trashItem(at: it.finalURL, resultingItemURL: nil)
            }
        }
        items.removeAll { ids.contains($0.id) }
        scheduleSave()
        pump()
    }

    func redownload(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        tasks[id]?.pause()
        tasks[id] = nil
        try? FileManager.default.removeItem(at: items[i].partURL)
        var r = items[i]
        r.segments = []
        r.totalSize = 0
        r.acceptsRanges = false
        r.status = .queued
        r.errorMessage = nil
        r.completedAt = nil
        items[i] = r
        pump()
        scheduleSave()
    }

    func reveal(_ ids: Set<UUID>) {
        let urls: [URL] = items.filter { ids.contains($0.id) }.map { rec in
            if rec.status == .complete { return rec.finalURL }
            return FileManager.default.fileExists(atPath: rec.partURL.path) ? rec.partURL : rec.saveDirURL
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func open(_ id: UUID) {
        guard let rec = items.first(where: { $0.id == id }) else { return }
        if rec.status == .complete { NSWorkspace.shared.open(rec.finalURL) }
    }

    // MARK: Queue

    /// Start queued items (oldest first) until the simultaneous-download limit is reached.
    private func pump() {
        var active = items.filter { $0.status == .downloading }.count
        let limit = Prefs.maxSimultaneous
        for item in items.reversed() where item.status == .queued {
            if active >= limit { break }
            launch(item.id)
            active += 1
        }
        applyLimits()
    }

    private func launch(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].status = .downloading
        let task: DownloadTask
        if let existing = tasks[id] {
            task = existing
        } else {
            task = DownloadTask(record: items[idx])
            task.onUpdate = { [weak self] rec, speed in
                DispatchQueue.main.async { self?.apply(rec, speed) }
            }
            tasks[id] = task
        }
        task.start()
    }

    private func apply(_ rec: DownloadRecord, _ speed: Double) {
        guard let idx = items.firstIndex(where: { $0.id == rec.id }) else { return }
        let old = items[idx].status
        items[idx] = rec
        speeds[rec.id] = rec.status == .downloading ? speed : nil
        if rec.status != old, rec.status != .downloading {
            if rec.status == .complete { tasks[rec.id] = nil }
            pump()
        }
        scheduleSave()
    }

    private func applyLimits() {
        let total = Int64(Prefs.speedLimitKB) * 1024
        let active = max(1, tasks.count)
        for t in tasks.values { t.speedLimit = total > 0 ? max(1024, total / Int64(active)) : 0 }
    }

    // MARK: Scheduler (Settings > Scheduler)

    private func schedulerTick() {
        let d = UserDefaults.standard
        guard d.bool(forKey: "schedEnabled") else { return }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let now = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        guard now != lastFiredMinute else { return }
        let start = d.object(forKey: "schedStartMinutes") as? Int ?? 120
        let stop = d.object(forKey: "schedStopMinutes") as? Int ?? 360
        if now == start {
            lastFiredMinute = now
            resumeAllUnfinished()
        } else if d.bool(forKey: "schedStopEnabled"), now == stop {
            lastFiredMinute = now
            stopAll()
        }
    }

    // MARK: Filtering helpers

    func count(in sel: SidebarSelection) -> Int {
        items.filter { sel.matches($0) }.count
    }

    // MARK: Persistence

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            self.saveScheduled = false
            Persistence.save(self.items)
        }
    }
}
