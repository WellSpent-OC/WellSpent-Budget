"""A server on this computer that passes every request on to staging, and
can hold them: while held, a request waits until it's let go. A test points
the app at it to keep a sync running for as long as it needs, which staging
alone answers too quickly to catch."""

import http.server
import threading
import urllib.error
import urllib.request

# Hop-by-hop headers, and the ones urllib sets again itself.
_DROPPED = {"connection", "keep-alive", "transfer-encoding", "content-length", "host", "accept-encoding"}


class HoldingServer:
    def __init__(self, upstream):
        self.upstream = upstream.rstrip("/")
        self._open = threading.Event()
        self._open.set()
        # Requests that reached the server while it held them.
        self.waiting = 0
        server = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *arguments):
                pass

            def forward(self):
                length = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(length) if length else None
                if not server._open.is_set():
                    server.waiting += 1
                    server._open.wait()
                headers = {k: v for k, v in self.headers.items() if k.lower() not in _DROPPED}
                request = urllib.request.Request(server.upstream + self.path, data=body, headers=headers,
                                                 method=self.command)
                try:
                    with urllib.request.urlopen(request, timeout=60) as answer:
                        status, answer_headers, data = answer.status, answer.headers.items(), answer.read()
                except urllib.error.HTTPError as error:
                    status, answer_headers, data = error.code, error.headers.items(), error.read()
                self.send_response(status)
                for key, value in answer_headers:
                    if key.lower() not in _DROPPED:
                        self.send_header(key, value)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = forward

        self._server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._server.daemon_threads = True
        self.url = f"http://127.0.0.1:{self._server.server_address[1]}"
        threading.Thread(target=self._server.serve_forever, daemon=True).start()

    def hold(self):
        self.waiting = 0
        self._open.clear()

    def let_go(self):
        self._open.set()

    def close(self):
        self.let_go()
        self._server.shutdown()
        self._server.server_close()
