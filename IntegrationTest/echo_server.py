#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body=b'MACXTERM_FORWARD_OK\n'
        self.send_response(200); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self,*args): pass
ThreadingHTTPServer(('127.0.0.1',int(os.environ.get('MACXTERM_HTTP_PORT','22338'))),Handler).serve_forever()
