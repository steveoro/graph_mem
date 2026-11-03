"""The bridge: a real server on an ephemeral 127.0.0.1 port, in a thread, in front of the fake CLI.

Start refusals, the token on every route, routes and methods, the body limit, each validation 400,
the gate (missing, failed, stale, untested model), tripped, busy, responses and the log line."""

import contextlib
import http.client
import io
import json
import os
import secrets
import threading
import time
import unittest
import uuid

from support import FakeCliCase, agent_cli, write_private

import bridge

CANARY = "Zq7Canary" + secrets.token_hex(6)


class Client:
    def __init__(self, port, token):
        self.port, self.token = port, token

    def call(self, method, path, body=None, token=True, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=60)
        sent = {"Content-Type": "application/json"}
        if token:
            sent["X-GM-Bridge-Token"] = self.token if token is True else token
        sent.update(headers or {})
        data = body if isinstance(body, (bytes, type(None))) else json.dumps(body).encode()
        conn.request(method, path, body=data, headers=sent)
        response = conn.getresponse()
        payload = json.loads(response.read() or b"null")
        conn.close()
        return response.status, payload


def request(**changes):
    body = {"profile": "devin", "model": "fake-model", "prompt": "Summarize SynthWidget.", "timeout_s": 30, "task": "summary",
            "run_id": str(uuid.uuid4())}
    body.update(changes)
    return body


class BridgeCase(FakeCliCase):
    def setUp(self):
        super().setUp()
        self.token = agent_cli.read_private_file(bridge.init_token(self.state))
        self.log = io.StringIO()
        self.server = bridge.make_server("127.0.0.1", 0, log=self.log)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.client = Client(self.server.server_address[1], self.token)
        for name in ("claude", "devin"):
            self.gate(name)

    def gate(self, name, result="PASS", models=("fake-model",), **changes):
        record = dict(agent_cli.check(agent_cli.load_profile(name)), result=result, models=list(models),
                      passed_on="2026-11-03", prompt_forms=[], trust_omit=False, run_as="user", warnings=[])
        record.update(changes)
        os.makedirs(os.path.join(self.state, "gates"), mode=0o700, exist_ok=True)
        write_private(os.path.join(self.state, "gates", name + ".json"), json.dumps(record))

    def complete(self, **changes):
        return self.client.call("POST", "/v1/complete", request(**changes))

    def outcome(self, **changes):
        status, body = self.complete(**changes)
        return status, body["failure_class"]

    def log_lines(self):
        return [json.loads(line.split(" ", 1)[1]) for line in self.log.getvalue().splitlines()]


class StartTest(FakeCliCase):
    def test_init_token_writes_a_0600_file_and_refuses_to_overwrite(self):
        path = bridge.init_token(self.state)
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        self.assertGreaterEqual(len(agent_cli.read_private_file(path)), 32)
        with self.assertRaises(bridge.StartError):
            bridge.init_token(self.state)
        before = agent_cli.read_private_file(path)
        bridge.init_token(self.state, force=True)
        self.assertNotEqual(agent_cli.read_private_file(path), before)

    def test_no_valid_token_file_no_start(self):
        path = bridge.token_path(self.state)
        with self.assertRaises(bridge.StartError):
            bridge.make_server("127.0.0.1", 0)
        for mode, text in ((0o644, secrets.token_urlsafe(32)), (0o640, secrets.token_urlsafe(32)), (0o600, "short")):
            write_private(path, text, mode)
            with self.subTest(mode=oct(mode), text=len(text)), self.assertRaises(bridge.StartError):
                bridge.make_server("127.0.0.1", 0)
        os.remove(path)
        target = os.path.join(self.tmp, "elsewhere.token")
        write_private(target, secrets.token_urlsafe(32))
        os.symlink(target, path)
        with self.assertRaises(bridge.StartError):
            bridge.make_server("127.0.0.1", 0)

    def test_only_loopback(self):
        bridge.init_token(self.state)
        for address in ("0.0.0.0", "::1", "localhost", ""):
            with self.subTest(address=address), self.assertRaises(bridge.StartError):
                bridge.make_server(address, 0)
        with contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertEqual(bridge.main(["serve", "--listen", "0.0.0.0", "--port", "0"]), 2)
        self.assertIn("127.0.0.1 only", err.getvalue())


class TokenAndRoutesTest(BridgeCase):
    def test_every_route_needs_the_token(self):
        for method, path in (("GET", "/v1/health"), ("POST", "/v1/complete"), ("GET", "/nope"), ("PUT", "/v1/complete"),
                             ("OPTIONS", "/v1/complete")):
            for token in (False, "wrong-" + secrets.token_urlsafe(30), self.token[:-1]):
                with self.subTest(method=method, path=path, token=bool(token)):
                    status, body = self.client.call(method, path, request() if method == "POST" else None, token=token)
                    self.assertEqual(status, 401)
                    self.assertEqual(body["failure_class"], "bridge_unauthorized")
        self.assertNotIn(self.token, self.log.getvalue())

    def test_routes_and_methods(self):
        self.assertEqual(self.client.call("GET", "/nope")[0], 404)
        self.assertEqual(self.client.call("GET", "/v1/complete")[0], 405)
        self.assertEqual(self.client.call("POST", "/v1/health", b"{}")[0], 405)
        self.assertEqual(self.client.call("PUT", "/v1/complete", b"{}")[0], 405)

    def test_health(self):
        status, body = self.client.call("GET", "/v1/health")
        self.assertEqual(status, 200)
        self.assertEqual(body["bridge_version"], bridge.BRIDGE_VERSION)
        devin = body["profiles"]["devin"]
        self.assertEqual(set(devin), {"cli_ok", "cli_realpath", "cli_version", "gate", "gate_ok", "tripped"})
        self.assertEqual(set(devin["gate"]), {"result", "cli_version", "wrapper_digest", "models", "passed_on"})
        self.assertEqual((devin["cli_ok"], devin["gate_ok"], devin["tripped"], devin["cli_version"]),
                         (True, True, False, "0.0.0-fake (Fake CLI)"))


class ValidationTest(BridgeCase):
    def test_a_body_over_1_mib_is_413_and_not_read(self):
        status, body = self.client.call("POST", "/v1/complete", b"{}", headers={"Content-Length": str(bridge.MAX_BODY + 1)})
        self.assertEqual((status, body["failure_class"]), (413, "prompt_too_long"))

    def test_each_bad_shape_is_400(self):
        bad = [request(extra=1), {k: v for k, v in request().items() if k != "task"}, request(profile="cursor"),
               request(profile=["devin"]), request(model="--dangerously-skip-permissions"), request(model="a b"),
               request(model=7), request(prompt=""), request(prompt=["x"]), request(timeout_s=0), request(timeout_s=601),
               request(timeout_s="30"), request(timeout_s=True), request(timeout_s=1.5), request(task="chat"),
               request(run_id="run-1"), request(run_id=str(uuid.uuid4()).replace("-", ""))]
        for body in bad:
            with self.subTest(body={k: v for k, v in body.items() if k != "prompt"}):
                status, answer = self.client.call("POST", "/v1/complete", body)
                self.assertEqual((status, answer["failure_class"]), (400, "bridge_bad_request"))
        for raw, headers in ((b"not json", {}), (b"[]", {}), (b'{"profile": "devin"', {}), (json.dumps(request()).encode(), {"Content-Type": "text/plain"})):
            with self.subTest(raw=raw[:20], headers=headers):
                self.assertEqual(self.client.call("POST", "/v1/complete", raw, headers=headers)[0], 400)
        self.assertNotIn("dangerously", self.log.getvalue())


class GateTest(BridgeCase):
    def test_a_missing_failed_or_stale_gate_and_an_untested_model_are_503(self):
        os.remove(os.path.join(self.state, "gates", "devin.json"))
        self.assertEqual(self.outcome(), (503, "gate_missing"))
        self.gate("devin", result="FAIL")
        self.assertEqual(self.outcome(), (503, "gate_failed"))
        self.gate("devin", models=("other-model",))
        self.assertEqual(self.outcome(), (503, "gate_missing"))
        self.gate("devin", wrapper_digest="0" * 64)
        self.assertEqual(self.outcome(), (503, "gate_stale"))
        self.gate("devin", cli_realpath=os.path.join(self.tmp, "old", "devin"))
        self.assertEqual(self.outcome(), (503, "gate_stale"))
        self.gate("devin")
        self.assertEqual(self.outcome(), (200, None))
        self.install("devin", version="0.0.2-fake")  # an auto-update swapped the binary
        status, body = self.complete()
        self.assertEqual((status, body["failure_class"], body["cli_version"]), (503, "gate_stale", "0.0.2-fake (Fake CLI)"))
        self.assertEqual(self.client.call("GET", "/v1/health")[1]["profiles"]["devin"]["gate_ok"], False)

    def test_a_gate_file_others_can_read_counts_as_missing(self):
        os.chmod(os.path.join(self.state, "gates", "devin.json"), 0o644)
        self.assertEqual(self.outcome(), (503, "gate_missing"))

    def test_a_missing_cli_is_503(self):
        os.environ[agent_cli.override_variable("devin")] = os.path.join(self.bin, "gone")
        self.assertEqual(self.outcome(), (503, "cli_missing"))


class RunTest(BridgeCase):
    def test_ok_and_the_response_shape(self):
        status, body = self.complete(prompt="@fake answer=SynthWidget renders gadget frames.\n")
        self.assertEqual(status, 200)
        self.assertEqual(set(body), {"ok", "text", "failure_class", "model_used", "cli_version", "latency_ms"})
        self.assertEqual((body["ok"], body["text"].strip(), body["failure_class"], body["model_used"], body["cli_version"]),
                         (True, "SynthWidget renders gadget frames.", None, "fake-model", "0.0.0-fake (Fake CLI)"))
        claude_status, claude = self.complete(profile="claude", prompt="@fake answer=Alpha Service.\n")
        self.assertEqual((claude_status, claude["text"]), (200, "Alpha Service."))

    def test_a_cli_failure_is_200_with_its_class_and_too_long_is_413(self):
        status, body = self.complete(prompt="@fake exit=1\n@fake stderr=Not logged in %s\n" % CANARY)
        self.assertEqual((status, body["ok"], body["failure_class"], body["text"]), (200, False, "cli_auth", None))
        self.assertNotIn(CANARY, json.dumps(body))
        self.assertEqual(self.complete(prompt="@fake exit=1\n@fake stderr=Prompt is too long\n")[0], 413)

    def test_tool_use_trips_the_profile_until_a_new_pass(self):
        status, body = self.complete(prompt="@fake hook=Bash\n")
        self.assertEqual((status, body["failure_class"]), (200, "cli_tool_use"))
        tripped = os.path.join(self.state, "tripped", "devin.json")
        with open(tripped, encoding="utf-8") as handle:
            self.assertEqual(set(json.load(handle)), {"profile", "run_id", "failure_class"})
        self.assertEqual(os.stat(tripped).st_mode & 0o777, 0o600)
        self.assertEqual(self.outcome(), (503, "tripped"))
        self.assertTrue(self.client.call("GET", "/v1/health")[1]["profiles"]["devin"]["tripped"])
        self.assertEqual(self.complete(profile="claude", prompt="@fake answer=ok\n")[0], 200)

    def test_one_run_at_a_time_per_profile(self):
        results = {}
        slow = threading.Thread(target=lambda: results.update(slow=self.complete(prompt="@fake sleep=2\n@fake answer=slow\n")))
        slow.start()
        deadline = time.monotonic() + 5
        while not self.server.bridge.locks["devin"].locked() and time.monotonic() < deadline:
            time.sleep(0.01)
        started = time.monotonic()
        busy = self.complete(prompt="@fake answer=second\n")
        self.assertLess(time.monotonic() - started, 1.5)
        side = self.complete(profile="claude", prompt="@fake answer=side by side\n")
        slow.join()
        self.assertEqual((busy[0], busy[1]["failure_class"]), (429, "bridge_busy"))
        self.assertEqual((side[0], results["slow"][0]), (200, 200))

    def test_the_log_line_has_no_prompt_answer_stderr_or_token(self):
        run_id = str(uuid.uuid4())
        self.complete(prompt="%s\n@fake stderr=%s-stderr\n" % (CANARY, CANARY), run_id=run_id, task="judge")
        self.client.call("GET", "/v1/health")
        lines = self.log_lines()
        self.assertEqual(len(lines), 2)
        self.assertEqual(lines[0], dict(lines[0], run_id=run_id, profile="devin", model="fake-model", task="judge",
                                        status=200, failure_class=None))
        self.assertEqual(set(lines[0]), {"run_id", "profile", "model", "task", "prompt_bytes", "status", "failure_class", "latency_ms"})
        self.assertNotIn(CANARY, self.log.getvalue())
        self.assertNotIn(self.token, self.log.getvalue())


if __name__ == "__main__":
    unittest.main()
