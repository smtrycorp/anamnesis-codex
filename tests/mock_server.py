"""Stand-in Anamnesis server for the hook tests.

Usage: mock_server.py <dir>. Listens on a free loopback port, writes it to
<dir>/port and appends every request as one JSON line to <dir>/requests.
Responses come from <dir>/routes.json, re-read per request:
{"/path": {"status": 200, "body": {...}, "delay": 0}}; unknown paths get
200 {"status": "ok"}; a route with "auth": "current" answers 401 unless the
request carries the current access token. /oauth/token rotates: it accepts
only the current refresh token (state in <dir>/oauth.json) and issues a new
pair.
"""

import http.server
import json
import os
import sys
import time
import urllib.parse

DIR = sys.argv[1]


def _routes():
    try:
        with open(os.path.join(DIR, "routes.json")) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _handle(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode() if length else ""
        path = urllib.parse.urlparse(self.path).path
        with open(os.path.join(DIR, "requests"), "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path,
                                "auth": self.headers.get("Authorization") or self.headers.get("X-Anamnesis-Key"),
                                "body": raw}) + "\n")
        if path == "/oauth/token":
            return self._token(raw)
        route = _routes().get(path, {})
        time.sleep(route.get("delay", 0))
        if route.get("auth") == "current" and self.headers.get("Authorization") != "Bearer " + self._state()["access_token"]:
            return self._send(401, {"error": "invalid_token"})
        self._send(route.get("status", 200), route.get("body", {"status": "ok"}))

    def _state(self):
        with open(os.path.join(DIR, "oauth.json")) as f:
            return json.load(f)

    def _token(self, raw):
        state_path = os.path.join(DIR, "oauth.json")
        state = self._state()
        form = urllib.parse.parse_qs(raw)
        if form.get("refresh_token", [""])[0] != state["refresh_token"]:
            return self._send(400, {"error": "invalid_grant", "error_description": "refresh token revoked"})
        n = state.get("issued", 0) + 1
        state.update(issued=n, refresh_token=f"rt{n}", access_token=f"at{n}")
        with open(state_path, "w") as f:
            json.dump(state, f)
        time.sleep(state.get("delay", 0))
        self._send(200, {"access_token": f"at{n}", "refresh_token": f"rt{n}", "expires_in": 3600})

    def _send(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = do_POST = _handle


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(DIR, "port.tmp"), "w") as f:
    f.write(str(server.server_address[1]))
os.replace(os.path.join(DIR, "port.tmp"), os.path.join(DIR, "port"))
server.serve_forever()
