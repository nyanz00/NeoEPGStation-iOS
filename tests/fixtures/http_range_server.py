"""Loopback-only synthetic Range/history API for native simulator checks."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread, Lock
import time
import socket


def start_server(directory):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.path.startswith('/fault/arm/'):
                with self.server.fault_lock:
                    self.server.fault_mode = self.path.rsplit('/', 1)[-1]
                    self.server.fault_remaining = 3 if self.server.fault_mode == 'slow' else 1
                self.send_response(200); self.send_header('Content-Length', '0'); self.end_headers()
                return
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
            if self.path not in ['/api/videos/1', '/api/videos/2', '/api/videos/3', '/api/videos/4']:
                self.send_error(404)
                return
            data = (Path(directory) / {'/api/videos/1': 'player-tap.ts', '/api/videos/2': 'pip-fixture.mp4', '/api/videos/3': 'player-seek.mkv', '/api/videos/4': 'network-fixture.mkv'}[self.path]).read_bytes()
            value = self.headers.get('Range', 'bytes=0-').removeprefix('bytes=')
            begin, end = value.split('-')
            begin = int(begin)
            end = min(int(end) if end else len(data)-1, len(data)-1)
            if begin >= len(data) or end < begin:
                self.send_error(416)
                return
            body = data[begin:end+1]
            mode = None
            if self.path == '/api/videos/4':
                with self.server.fault_lock:
                    if self.server.fault_remaining > 0:
                        mode = self.server.fault_mode; self.server.fault_remaining -= 1
                if mode:
                    self.server.fault_events.append({'mode': mode, 'offset': begin, 'time': time.monotonic()})
                    if mode == 'slow': time.sleep(9)
                    elif mode == 'disconnect':
                        self.connection.shutdown(socket.SHUT_RDWR); self.connection.close(); return
            self.send_response(206)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Content-Range', f'bytes {begin}-{end}/{len(data)}')
            self.send_header('ETag', '"synthetic-range-v1"')
            self.end_headers()
            try:
                if self.path == '/api/videos/4' and len(body) >= 256*1024:
                    # Keep normal throughput above the media bitrate but below
                    # loopback speed. Otherwise VLC's read-ahead downloads the
                    # entire small fixture before the mid-playback fault arms.
                    for at in range(0, len(body), 65536):
                        self.wfile.write(body[at:at+65536]); self.wfile.flush(); time.sleep(0.125)
                else:
                    self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def do_PUT(self):
            self.server.history_requests.append(self.headers.get('X-EPGStation-User-Id'))
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            assert self.path == '/api/recorded/1/playback'
            assert self.headers['X-EPGStation-User-Id'] == '7'
            assert body['duration'] > 0 and 0 <= body['position'] <= body['duration']
            assert body['sessionWatchedSeconds'] >= 0 and len(body['sessionId']) == 36
            # OpenAPI UnixtimeMS is integer, not a fractional millisecond timestamp.
            assert type(body['observedAt']) is int and body['observedAt'] > 0
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
    server.history_requests = []
    server.fault_lock = Lock(); server.fault_mode = None; server.fault_remaining = 0; server.fault_events = []
    Thread(target=server.serve_forever, daemon=True).start()
    return server
