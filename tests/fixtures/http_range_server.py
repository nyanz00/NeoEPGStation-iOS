"""Loopback-only synthetic Range/history API for native simulator checks."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread


def start_server(directory):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.path == '/api/videos/1/duration':
                body = b'{"duration":20}'
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(body)
                return
            if self.path.endswith('/subtitles'):
                body = b'{"items":[]}'
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(body)
                return
            if self.path != '/api/videos/1':
                self.send_error(404)
                return
            data = (Path(directory) / 'player-tap.ts').read_bytes()
            value = self.headers.get('Range', 'bytes=0-').removeprefix('bytes=')
            begin, end = value.split('-')
            begin = int(begin)
            end = min(int(end) if end else len(data)-1, len(data)-1)
            if begin >= len(data) or end < begin:
                self.send_error(416)
                return
            body = data[begin:end+1]
            self.send_response(206)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Content-Range', f'bytes {begin}-{end}/{len(data)}')
            self.send_header('ETag', '"synthetic-range-v1"')
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def do_PUT(self):
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            assert self.path == '/api/recorded/1/playback'
            assert self.headers['X-EPGStation-User-Id'] == '7'
            assert body['duration'] > 0 and 0 <= body['position'] <= body['duration']
            assert body['sessionWatchedSeconds'] >= 0 and len(body['sessionId']) == 36
            self.server.progress.append(body)
            reply = json.dumps({'position': body['position'], 'duration': body['duration'],
                                'watchedSeconds': body['sessionWatchedSeconds'], 'updatedAt': 1}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(reply)))
            self.end_headers()
            self.wfile.write(reply)

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.progress = []
    Thread(target=server.serve_forever, daemon=True).start()
    return server
