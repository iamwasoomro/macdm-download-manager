from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
DATA = bytes(range(256)) * 1024
class Handler(BaseHTTPRequestHandler):
    failures = 0
    def log_message(self, *args): pass
    def do_HEAD(self):
        if self.path == '/no-head':
            self.send_response(405); self.end_headers(); return
        self.send_response(200)
        if self.path != '/unknown': self.send_header('Content-Length', str(3 if self.path == '/tiny' else len(DATA)))
        if self.path in ('/tiny', '/ranges', '/ignored'): self.send_header('Accept-Ranges', 'bytes')
        self.send_header('ETag', '"fixture-v1"')
        self.send_header('Content-Disposition', 'attachment; filename="fixture.bin"')
        self.end_headers()
    def do_GET(self):
        if self.path == '/retry' and Handler.failures == 0:
            Handler.failures += 1
            self.send_response(503); self.end_headers(); return
        body = b'abc' if self.path == '/tiny' else DATA
        r = self.headers.get('Range')
        if r and self.path != '/ignored':
            start, end = r.removeprefix('bytes=').split('-')
            start = int(start); end = int(end) if end else len(body) - 1
            full = len(body); body = body[start:end+1]
            self.send_response(206)
            self.send_header('Content-Range', f'bytes {start}-{end}/{full}')
        else: self.send_response(200)
        if self.path != '/unknown': self.send_header('Content-Length', str(len(body)))
        self.send_header('Content-Disposition', 'attachment; filename="fixture.bin"')
        self.end_headers()
        try: self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass
ThreadingHTTPServer(('127.0.0.1', 17211), Handler).serve_forever()
