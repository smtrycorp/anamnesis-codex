"""The Codex MCP proxy against a stand-in server (tests/mock_server.py)."""

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROXY = os.path.join(ROOT, "plugins", "anamnesis", "bin", "anamnesis-mcp-proxy")
TOOLS = {"jsonrpc": "2.0", "id": 1, "result": {"tools": [{"name": "retrieve_memories"}]}}


class ProxyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.srv = os.path.join(self.tmp.name, "srv")
        self.home = os.path.join(self.tmp.name, "home")
        os.makedirs(self.srv)
        os.makedirs(self.home)
        self.server = subprocess.Popen([sys.executable, os.path.join(ROOT, "tests", "mock_server.py"), self.srv])
        for _ in range(50):
            if os.path.exists(os.path.join(self.srv, "port")):
                break
            time.sleep(0.1)
        with open(os.path.join(self.srv, "port")) as f:
            self.url = f"http://127.0.0.1:{f.read()}"
        self._write(os.path.join(self.srv, "routes.json"), {"/mcp": {"auth": "current", "body": TOOLS}})
        self._write(os.path.join(self.srv, "oauth.json"), {"access_token": "at0", "refresh_token": "rt0"})
        self.write_config(access_token="at0", refresh_token="rt0", expires_at=time.time() + 3600)

    def tearDown(self):
        self.server.kill()
        self.server.wait()
        self.tmp.cleanup()

    @staticmethod
    def _write(path, data):
        with open(path, "w") as f:
            json.dump(data, f)

    def write_config(self, **fields):
        self._write(os.path.join(self.home, "config.json"),
                    {"server_url": self.url, "client_id": "c", **fields})

    def config(self):
        with open(os.path.join(self.home, "config.json")) as f:
            return json.load(f)

    def requests(self, needle=""):
        try:
            with open(os.path.join(self.srv, "requests")) as f:
                return [line for line in f if needle in line]
        except FileNotFoundError:
            return []

    def start(self, **env):
        return subprocess.Popen(
            [sys.executable, PROXY], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env={**os.environ, "ANAMNESIS_HOME": self.home, "ANAMNESIS_CAPTURE": "on", **env})

    @staticmethod
    def call(proxy, message):
        proxy.stdin.write(json.dumps(message) + "\n")
        proxy.stdin.flush()
        return json.loads(proxy.stdout.readline())

    def finish(self, proxy):
        proxy.stdin.close()
        stderr = proxy.stderr.read()
        proxy.wait(timeout=10)
        proxy.stdout.close()
        proxy.stderr.close()
        return stderr

    def test_capture_off_never_connects(self):
        for value in ("off", "OFF", "0", "false", "No", "bogus"):
            with self.subTest(value=value):
                proxy = self.start(ANAMNESIS_CAPTURE=value)
                init = self.call(proxy, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
                tools = self.call(proxy, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
                call = self.call(proxy, {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {}})
                self.finish(proxy)
                self.assertIn("off for this session", init["result"]["serverInfo"]["name"])
                self.assertEqual(tools["result"]["tools"], [])
                self.assertIn("error", call)
                self.assertEqual(self.requests(), [])

    def test_pause_takes_effect_mid_session(self):
        proxy = self.start()
        first = self.call(proxy, {"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        open(os.path.join(self.home, "paused"), "w").close()
        second = self.call(proxy, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        self.finish(proxy)
        self.assertEqual(first["result"]["tools"][0]["name"], "retrieve_memories")
        self.assertEqual(second["result"]["tools"], [])
        self.assertEqual(len(self.requests("/mcp")), 1)

    def test_picks_up_tokens_a_hook_rotated(self):
        proxy = self.start()
        self.call(proxy, {"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        # A hook refreshes behind the proxy's back: rt0 is now revoked.
        form = b"grant_type=refresh_token&refresh_token=rt0&client_id=c"
        with urllib.request.urlopen(f"{self.url}/oauth/token", data=form) as resp:
            tok = json.load(resp)
        self.write_config(access_token=tok["access_token"], refresh_token=tok["refresh_token"],
                          expires_at=time.time() + 3600)
        reply = self.call(proxy, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        self.finish(proxy)
        self.assertIn("result", reply)
        self.assertEqual(len(self.requests("/oauth/token")), 1)

    def test_refreshes_an_expired_token_and_saves_it_0600(self):
        self.write_config(access_token="at0", refresh_token="rt0", expires_at=0)
        proxy = self.start()
        reply = self.call(proxy, {"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        self.finish(proxy)
        self.assertIn("result", reply)
        cfg = self.config()
        self.assertEqual((cfg["access_token"], cfg["refresh_token"]), ("at1", "rt1"))
        self.assertEqual(os.stat(os.path.join(self.home, "config.json")).st_mode & 0o777, 0o600)

    def test_failed_refresh_is_a_tool_error_and_logged(self):
        self._write(os.path.join(self.srv, "oauth.json"), {"access_token": "at9", "refresh_token": "rt9"})
        self.write_config(access_token="at0", refresh_token="rt0", expires_at=0)
        proxy = self.start()
        reply = self.call(proxy, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {}})
        stderr = self.finish(proxy)
        self.assertIn("token refresh failed", reply["error"]["message"])
        self.assertIn("invalid_grant", stderr)

    def test_waits_for_the_hooks_refresh_lock_and_rereads(self):
        self.write_config(access_token="at0", refresh_token="rt0", expires_at=0)
        holder = subprocess.Popen(["sleep", "30"])
        lock = os.path.join(self.home, "refresh.lck")
        os.symlink(str(holder.pid), lock)
        proxy = self.start()
        proxy.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}) + "\n")
        proxy.stdin.flush()
        time.sleep(1)
        # The "hook" finishes its refresh and releases the lock.
        self._write(os.path.join(self.srv, "oauth.json"), {"access_token": "at5", "refresh_token": "rt5"})
        self.write_config(access_token="at5", refresh_token="rt5", expires_at=time.time() + 3600)
        os.unlink(lock)
        reply = json.loads(proxy.stdout.readline())
        self.finish(proxy)
        holder.kill()
        holder.wait()
        self.assertIn("result", reply)
        self.assertEqual(self.requests("/oauth/token"), [])

    def test_stale_lock_from_a_dead_process_is_stolen(self):
        dead = subprocess.Popen(["true"])
        dead.wait()
        os.symlink(str(dead.pid), os.path.join(self.home, "refresh.lck"))
        self.write_config(access_token="at0", refresh_token="rt0", expires_at=0)
        proxy = self.start()
        reply = self.call(proxy, {"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        self.finish(proxy)
        self.assertIn("result", reply)
        self.assertFalse(os.path.lexists(os.path.join(self.home, "refresh.lck")))

    def test_non_object_line_is_rejected_and_proxy_keeps_going(self):
        proxy = self.start()
        proxy.stdin.write("[1, 2]\n")
        proxy.stdin.flush()
        bad = json.loads(proxy.stdout.readline())
        good = self.call(proxy, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        self.finish(proxy)
        self.assertEqual(bad["error"]["code"], -32600)
        self.assertIn("result", good)


if __name__ == "__main__":
    unittest.main()
