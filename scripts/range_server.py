#!/usr/bin/env python3
"""Static file server WITH HTTP Range support (python -m http.server has none).
Usage: range_server.py [port] [dir]   (use --slow to throttle for testing pause/resume)"""
import http.server, os, re, sys, time

SLOW = "--slow" in sys.argv
args = [a for a in sys.argv[1:] if not a.startswith("--")]
PORT = int(args[0]) if args else 8000
ROOT = args[1] if len(args) > 1 else "."

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = os.path.join(ROOT, self.path.lstrip("/").split("?")[0])
        if not os.path.isfile(path):
            self.send_error(404); return
        size = os.path.getsize(path)
        start, end, code = 0, size - 1, 200
        m = re.match(r"bytes=(\d+)-(\d*)$", self.headers.get("Range", ""))
        if m:
            start = int(m.group(1)); end = min(int(m.group(2)) if m.group(2) else size - 1, size - 1)
            if start >= size:
                self.send_response(416); self.send_header("Content-Range", f"bytes */{size}"); self.end_headers(); return
            code = 206
        self.send_response(code)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if code == 206: self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        with open(path, "rb") as f:
            f.seek(start); left = end - start + 1
            while left > 0:
                chunk = f.read(min(65536, left))
                if not chunk: break
                try: self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError): return
                left -= len(chunk)
                if SLOW: time.sleep(0.02)
    def log_message(self, *a): pass

http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
