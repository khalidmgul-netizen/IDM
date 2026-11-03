import Foundation
import FetcherCore

// Usage: fetchcli <url> [output-dir] [connections]
// Handy for testing the engine without the GUI:  swift run fetchcli http://127.0.0.1:8000/big.bin /tmp 8

let args = CommandLine.arguments
guard args.count >= 2, let url = URL(string: args[1]) else {
    print("usage: fetchcli <url> [output-dir] [connections]")
    exit(2)
}
let dir = args.count > 2 ? args[2] : FileManager.default.currentDirectoryPath
let conns = args.count > 3 ? Int(args[3]) ?? 8 : 8

let record = DownloadRecord(url: url, fileName: FileNaming.fromURL(url), saveDir: dir, connections: conns)
let task = DownloadTask(record: record)
let done = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0

task.onUpdate = { rec, speed in
    let pct = String(format: "%5.1f%%", rec.progress * 100)
    print("\r\(rec.status.label) \(pct)  \(Format.bytes(rec.downloaded)) / \(Format.bytes(rec.totalSize))  \(Format.speed(speed))   ", terminator: "")
    fflush(stdout)
    if rec.status == .complete {
        print("\nSaved: \(rec.finalURL.path)")
        done.signal()
    } else if rec.status == .error {
        print("\nError: \(rec.errorMessage ?? "unknown")")
        exitCode = 1
        done.signal()
    }
}
task.start()
done.wait()
exit(exitCode)
