"""The app the end-to-end test deploys: HTTP saying its version, and a WebSocket
sending it, until closed. `BROKEN` in its version file makes its health fail."""
import base64, hashlib, http.server, pathlib, signal, socketserver, sys, time

VERSION = pathlib.Path("/app/version.txt").read_text().strip()
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.headers.get("Upgrade", "").lower() == "websocket":
            return self.websocket()
        status = 500 if VERSION == "BROKEN" else 200
        body = VERSION.encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def websocket(self):
        key = self.headers["Sec-WebSocket-Key"] + GUID
        accept = base64.b64encode(hashlib.sha1(key.encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.wfile.flush()
        try:
            while True:
                text = VERSION.encode()
                self.wfile.write(bytes([0x81, len(text)]) + text)
                self.wfile.flush()
                time.sleep(0.2)
        except OSError:
            self.close_connection = True


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
Server(("0.0.0.0", 8000), Handler).serve_forever()
