#!/usr/bin/env python3
"""Stand in for a SAML IdP's final response: serve the headers gp-saml-gui
looks for. No corporate account, no ADFS, no network beyond loopback."""
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
KIND = sys.argv[2]          # prelogin-cookie | portal-userauthcookie
REDIR_TO = sys.argv[3] if len(sys.argv) > 3 else None

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if REDIR_TO and self.path == "/":
            self.send_response(302)
            self.send_header("Location", REDIR_TO)
            self.end_headers()
            return
        body = b"<html><body>synthetic SAML landing</body></html>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("saml-username", "test.user@example.com")
        self.send_header(KIND, "SYNTHETIC-%s-0123456789abcdef" % KIND.upper())
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", PORT), H).serve_forever()
