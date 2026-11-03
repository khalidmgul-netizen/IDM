import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Multi-connection downloader for a single file.
///
/// Flow: probe (GET Range 0-0) -> plan segments -> one URLSession task per segment, each
/// writing at its own offset of a sparse `.part` file -> rename when every segment is done.
/// Progress lives in `record.segments`, so a persisted record can resume after a quit.
/// All mutable state is touched only on the private serial `queue` (also the delegate queue).
public final class DownloadTask: NSObject, URLSessionDataDelegate {
    public private(set) var record: DownloadRecord
    /// Called on an arbitrary thread with the latest record and smoothed speed (bytes/s).
    public var onUpdate: ((DownloadRecord, Double) -> Void)?
    /// Bytes per second for this task; 0 = unlimited.
    public var speedLimit: Int64 = 0

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        return q
    }()

    private var session: URLSession?
    private var segmentOf: [ObjectIdentifier: Int] = [:]
    private var liveTasks: [Int: URLSessionDataTask] = [:]
    private var handle: FileHandle?
    private var timer: DispatchSourceTimer?
    private var cancelled = false
    private var probeDone = false
    private var generation = 0
    private var retries: [Int: Int] = [:]

    private var bytesSinceTick: Int64 = 0
    private var speed: Double = 0

    private var windowStart = Date()
    private var windowBytes: Int64 = 0
    private var throttled = false

    public init(record: DownloadRecord) {
        self.record = record
        super.init()
    }

    // MARK: - Public control

    public func start() {
        queue.addOperation { [weak self] in self?.doStart() }
    }

    public func pause() {
        queue.addOperation { [weak self] in self?.doPause() }
    }

    /// Blocking variant used when the app quits, so the final progress can be persisted.
    public func pauseSync() -> DownloadRecord {
        let op = BlockOperation { [weak self] in self?.doPause() }
        queue.addOperations([op], waitUntilFinished: true)
        return record
    }

    /// Pure helper (unit-tested): split a file into byte ranges, one per connection.
    public static func plan(total: Int64, ranges: Bool, connections: Int) -> [SegmentState] {
        guard total > 0, ranges else {
            return [SegmentState(start: 0, end: total > 0 ? total - 1 : -1)]
        }
        let minChunk: Int64 = 512 * 1024
        let n = Int(max(1, min(Int64(max(1, connections)), total / minChunk)))
        let chunk = total / Int64(n)
        return (0..<n).map { i in
            let s = Int64(i) * chunk
            let e = (i == n - 1) ? total - 1 : (Int64(i) + 1) * chunk - 1
            return SegmentState(start: s, end: e)
        }
    }

    // MARK: - Lifecycle (serial queue only)

    private func doStart() {
        guard record.status != .complete else { return }
        teardown()
        cancelled = false
        generation += 1
        probeDone = false
        retries = [:]
        throttled = false
        record.status = .downloading
        record.errorMessage = nil
        record.lastTry = Date()

        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = max(4, record.connections)
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 60
        cfg.httpShouldSetCookies = false   // we send the browser's Cookie header ourselves
        cfg.urlCache = nil
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: queue)

        startTimer()
        emit()
        if record.totalSize == 0 { probe() } else { begin() }
    }

    private func doPause() {
        cancelled = true
        generation += 1
        stopTimer()
        teardown()
        if record.status == .downloading || record.status == .queued { record.status = .paused }
        speed = 0
        emit()
    }

    private func teardown() {
        liveTasks.values.forEach { $0.cancel() }
        liveTasks.removeAll()
        segmentOf.removeAll()
        session?.invalidateAndCancel()
        session = nil
        try? handle?.close()
        handle = nil
    }

    private func fail(_ message: String) {
        guard !cancelled else { return }
        cancelled = true
        generation += 1
        stopTimer()
        teardown()
        record.status = .error
        record.errorMessage = message
        speed = 0
        emit()
    }

    private func finish() {
        stopTimer()
        teardown()
        cancelled = true
        if record.totalSize <= 0 { record.totalSize = record.downloaded }
        let dest = FileNaming.uniqueName(record.fileName, in: record.saveDirURL)
        do {
            try FileManager.default.moveItem(at: record.partURL,
                                             to: record.saveDirURL.appendingPathComponent(dest))
            record.fileName = dest
            record.status = .complete
            record.completedAt = Date()
            record.errorMessage = nil
        } catch {
            record.status = .error
            record.errorMessage = "Could not save file: \(error.localizedDescription)"
        }
        speed = 0
        emit()
    }

    // MARK: - Probe & planning

    private func applyHeaders(_ req: inout URLRequest) {
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")  // keep byte offsets honest
        req.setValue(record.userAgent ?? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Fetchly/0.1",
                     forHTTPHeaderField: "User-Agent")
        if let r = record.referer, !r.isEmpty { req.setValue(r, forHTTPHeaderField: "Referer") }
        if let c = record.cookie, !c.isEmpty { req.setValue(c, forHTTPHeaderField: "Cookie") }
    }

    private func probe() {
        guard let session = session else { return }
        var req = URLRequest(url: record.url)
        applyHeaders(&req)
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let t = session.dataTask(with: req)
        t.taskDescription = "probe"
        t.resume()
    }

    private func handleProbe(_ http: HTTPURLResponse) {
        probeDone = true
        if http.statusCode >= 400 {
            fail("HTTP \(http.statusCode)")
            return
        }
        if http.statusCode == 206,
           let cr = http.value(forHTTPHeaderField: "Content-Range"),
           let totalStr = cr.split(separator: "/").last,
           let total = Int64(totalStr), total > 0 {
            record.totalSize = total
            record.acceptsRanges = true
        } else {
            record.totalSize = http.expectedContentLength > 0 ? http.expectedContentLength : -1
            record.acceptsRanges = false
        }
        if record.autoName {
            let n = FileNaming.fromResponse(http, url: record.url)
            record.fileName = FileNaming.uniqueName(n, in: record.saveDirURL)
        }
        begin()
    }

    private func begin() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: record.saveDirURL, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: record.partURL.path) {
                fm.createFile(atPath: record.partURL.path, contents: nil)
                record.segments = []
            }
            let h = try FileHandle(forWritingTo: record.partURL)
            handle = h
            if !record.acceptsRanges {
                // Can't resume a stream that doesn't support ranges: start over.
                record.segments = []
                try h.truncate(atOffset: 0)
            } else if record.totalSize > 0 {
                try h.truncate(atOffset: UInt64(record.totalSize))  // sparse pre-allocation
            }
        } catch {
            fail("Cannot create file: \(error.localizedDescription)")
            return
        }

        if record.segments.isEmpty {
            record.segments = Self.plan(total: record.totalSize,
                                        ranges: record.acceptsRanges,
                                        connections: record.connections)
        }
        if record.segments.allSatisfy({ $0.isFinished }) {
            finish()
            return
        }
        for i in record.segments.indices where !record.segments[i].isFinished {
            startSegment(i)
        }
        emit()
    }

    private func startSegment(_ i: Int) {
        guard let session = session, !cancelled, i < record.segments.count else { return }
        let seg = record.segments[i]
        if seg.isFinished { return }
        var req = URLRequest(url: record.url)
        applyHeaders(&req)
        if record.acceptsRanges {
            let from = seg.start + seg.done
            req.setValue(seg.end >= 0 ? "bytes=\(from)-\(seg.end)" : "bytes=\(from)-",
                         forHTTPHeaderField: "Range")
        }
        let t = session.dataTask(with: req)
        segmentOf[ObjectIdentifier(t)] = i
        liveTasks[i] = t
        t.resume()
    }

    // MARK: - URLSession delegate (runs on `queue`)

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                           didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard session === self.session, !cancelled else { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            fail("Invalid server response")
            return
        }
        if dataTask.taskDescription == "probe" {
            handleProbe(http)
            completionHandler(.cancel)   // we only wanted the headers
            return
        }
        guard segmentOf[ObjectIdentifier(dataTask)] != nil else { completionHandler(.cancel); return }
        if http.statusCode >= 400 {
            completionHandler(.cancel)
            fail("HTTP \(http.statusCode)")
            return
        }
        if record.acceptsRanges && http.statusCode != 206 {
            completionHandler(.cancel)
            fail("Server stopped honoring range requests")
            return
        }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard session === self.session, !cancelled,
              let idx = segmentOf[ObjectIdentifier(dataTask)],
              idx < record.segments.count else { return }
        let seg = record.segments[idx]
        let offset = seg.start + seg.done
        var chunk = data
        if seg.end >= 0 {
            let remaining = seg.end - offset + 1
            if remaining <= 0 { return }
            if Int64(chunk.count) > remaining { chunk = Data(chunk.prefix(Int(remaining))) }
        }
        do {
            try handle?.seek(toOffset: UInt64(offset))
            try handle?.write(contentsOf: chunk)
        } catch {
            fail("Disk write failed: \(error.localizedDescription)")
            return
        }
        record.segments[idx].done += Int64(chunk.count)
        bytesSinceTick += Int64(chunk.count)
        throttleIfNeeded(added: Int64(chunk.count))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard session === self.session else { return }

        if task.taskDescription == "probe" {
            if !probeDone, let e = error as NSError?, e.code != NSURLErrorCancelled {
                fail(e.localizedDescription)
            }
            return
        }

        guard !cancelled, let idx = segmentOf.removeValue(forKey: ObjectIdentifier(task)) else { return }
        liveTasks[idx] = nil

        if let e = error as NSError? {
            if e.code == NSURLErrorCancelled { return }
            retry(idx, reason: e.localizedDescription)
            return
        }

        let seg = record.segments[idx]
        if seg.end < 0 {
            // Stream of unknown length finished.
            record.segments[idx].sealed = true
            record.totalSize = record.segments[idx].done
        } else if seg.done < seg.length {
            retry(idx, reason: "Connection closed early")
            return
        }
        retries[idx] = 0
        if record.segments.allSatisfy({ $0.isFinished }) { finish() }
    }

    private func retry(_ idx: Int, reason: String) {
        guard record.acceptsRanges else { fail(reason); return }   // can't resume a plain stream
        let n = (retries[idx] ?? 0) + 1
        retries[idx] = n
        if n > 5 { fail(reason); return }
        let delay = min(pow(2.0, Double(n)), 15)
        let gen = generation
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.queue.addOperation {
                guard let self = self, self.generation == gen, !self.cancelled else { return }
                self.startSegment(idx)
            }
        }
    }

    // MARK: - Speed, limiting, reporting

    private func throttleIfNeeded(added: Int64) {
        guard speedLimit > 0, !throttled else { return }
        let now = Date()
        if now.timeIntervalSince(windowStart) >= 1 {
            windowStart = now
            windowBytes = 0
        }
        windowBytes += added
        if windowBytes >= speedLimit {
            let wait = max(0.05, 1 - now.timeIntervalSince(windowStart))
            throttled = true
            let gen = generation
            liveTasks.values.forEach { $0.suspend() }
            DispatchQueue.global().asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.queue.addOperation {
                    guard let self = self, self.generation == gen else { return }
                    self.throttled = false
                    self.windowStart = Date()
                    self.windowBytes = 0
                    self.liveTasks.values.forEach { $0.resume() }
                }
            }
        }
    }

    private func startTimer() {
        stopTimer()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in
            self?.queue.addOperation { self?.tick() }
        }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard record.status == .downloading else { return }
        let instant = Double(bytesSinceTick) / 0.5
        speed = speed == 0 ? instant : 0.6 * speed + 0.4 * instant
        bytesSinceTick = 0
        emit()
    }

    private func emit() {
        onUpdate?(record, speed)
    }
}
