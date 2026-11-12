"""Run the disk-download/API checks against a disposable loopback server."""
import json
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

requests = []
counts = {}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def respond(self, code, data=b'', mime='application/octet-stream', extra=None):
        self.send_response(code)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(data)))
        for name, value in (extra or {}).items():
            self.send_header(name, value)
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        if self.path == '/checks':
            mutations = [(r['method'], r['path']) for r in requests if r['method'] != 'GET']
            expected = [('PUT', '/prefix/api/recorded/10/protect'), ('PUT', '/prefix/api/recorded/10/unprotect'), ('PUT', '/prefix/api/recorded/10/user'), ('POST', '/prefix/api/thumbnails/videos/101/replace'), ('DELETE', '/prefix/api/videos/101'), ('DELETE', '/prefix/api/recorded/10')]
            result = {'mutation paths and methods': mutations == expected,
                      'download endpoint includes isDownload': any(r['path'] == '/prefix/api/videos/1?isDownload=true' for r in requests),
                      'playlist endpoint': any(r['path'] == '/prefix/api/videos/1/playlist' for r in requests),
                      'captured account headers on every request': all(r['user'] == '7' and r['profile'] == '21' and r['session'] == 'fixture' for r in requests),
                      'assignment body': any(r['body'] == {'userId': 9} for r in requests),
                      'redirect not followed': not any(r['path'] == '/must-not-follow' for r in requests)}
            return self.respond(200, json.dumps(result).encode(), 'application/json')
        self.remember()
        if '/recorded/' in self.path:
            ident = int(self.path.split('/recorded/')[1].split('?')[0])
            counts[ident] = counts.get(ident, 0) + 1
            if ident == 21:
                time.sleep(.25)
            value = {'id': ident, 'name': 'revision'+str(counts[ident]), 'startAt': 0, 'endAt': 1000, 'isRecording': False, 'userId': 9}
            return self.respond(200, json.dumps(value).encode(), 'application/json')
        if '/videos/2?' in self.path:
            return self.respond(200, b'<html>login</html>', 'text/html')
        if '/videos/3?' in self.path:
            return self.respond(500, b'{"message":"fixture failure"}', 'application/json')
        if '/videos/4?' in self.path:
            return self.respond(302, extra={'Location': '/must-not-follow'})
        if '/videos/5?' in self.path:
            time.sleep(.5)
        if self.path.endswith('/playlist'):
            return self.respond(200, b'#EXTM3U\nfixture\n', 'application/x-mpegURL', {'Content-Disposition': 'attachment; filename="fixture.m3u8"'})
        self.respond(200, b'Z' * 2097152, extra={'Content-Disposition': 'attachment; filename="fixture.mkv"'})

    def remember(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        requests.append({'method': self.command, 'path': self.path, 'body': json.loads(body) if body else None,
                         'user': self.headers.get('X-EPGStation-User-Id'), 'profile': self.headers.get('X-Viewer-Profile-Id'), 'session': self.headers.get('X-Viewer-Session')})

    def do_PUT(self):
        self.remember()
        self.respond(204)

    do_POST = do_PUT
    do_DELETE = do_PUT


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    result = subprocess.run([sys.argv[1], f'http://127.0.0.1:{server.server_port}'], timeout=45)
finally:
    server.shutdown()
sys.exit(result.returncode)
