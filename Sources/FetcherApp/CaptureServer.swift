import Foundation
import Network

struct CaptureRequest: Decodable {
    var url: String
    var referer: String?
    var cookie: String?
    var userAgent: String?
    var filename: String?
}

/// Tiny HTTP server on 127.0.0.1 so the browser extension can hand downloads to the app.
/// POST /add  (header X-Fetchly-Token, JSON body)   GET /ping
final class CaptureServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "fetchly.capture")
    var token: String = ""
    var onAdd: ((CaptureRequest) -> Void)?

    func start(port: UInt16) {
        guard listener == nil, let p = NWEndpoint.Port(rawValue: port) else { return }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        guard let l = try? NWListener(using: params, on: p) else {
            NSLog("Fetchly: could not listen on 127.0.0.1:\(port) (already in use?)")
            return
        }
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: self?.queue ?? .global())
            self?.receive(conn, Data())
        }
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private struct HTTPRequest {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    private func receive(_ conn: NWConnection, _ buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { conn.cancel(); return }
            var buf = buffer
            if let d = data { buf.append(d) }
            if let req = Self.parse(buf) {
                self.respond(conn, req)
                return
            }
            if error != nil || isComplete || buf.count > 1_000_000 {
                conn.cancel()
                return
            }
            self.receive(conn, buf)
        }
    }

    /// Returns nil until a full request (headers + Content-Length body) has arrived.
    private static func parse(_ buf: Data) -> HTTPRequest? {
        guard let sep = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buf[buf.startIndex..<sep.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            if let idx = l.firstIndex(of: ":") {
                let k = l[l.startIndex..<idx].lowercased()
                let v = l[l.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }
        let want = Int(headers["content-length"] ?? "0") ?? 0
        let body = buf[sep.upperBound...]
        if body.count < want { return nil }
        return HTTPRequest(method: String(first[0]), path: String(first[1]),
                           headers: headers, body: Data(body.prefix(want)))
    }

    private func respond(_ conn: NWConnection, _ req: HTTPRequest) {
        var status = "200 OK"
        var body = #"{"ok":true}"#

        switch (req.method, req.path) {
        case ("OPTIONS", _):
            status = "204 No Content"
            body = ""
        case ("GET", "/ping"):
            body = #"{"app":"fetchly"}"#
        case ("POST", "/add"):
            if req.headers["x-fetchly-token"] != token || token.isEmpty {
                status = "401 Unauthorized"
                body = #"{"ok":false,"error":"bad token"}"#
            } else if let cap = try? JSONDecoder().decode(CaptureRequest.self, from: req.body) {
                onAdd?(cap)
            } else {
                status = "400 Bad Request"
                body = #"{"ok":false,"error":"bad json"}"#
            }
        default:
            status = "404 Not Found"
            body = #"{"ok":false}"#
        }

        let head = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "Access-Control-Allow-Headers: Content-Type, X-Fetchly-Token\r\n"
            + "Access-Control-Allow-Methods: POST, GET, OPTIONS\r\n"
            + "Connection: close\r\n\r\n"
        conn.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in conn.cancel() })
    }
}
