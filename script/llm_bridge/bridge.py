#!/usr/bin/env python3
"""The host bridge (graph_mem ``script/llm_bridge/``, agent-CLI train PR3): a small HTTP server on
127.0.0.1 that takes a masked prompt from graph_mem, runs one agent CLI through ``agent_cli.run_cli``
and returns the raw answer with a failure class.

    python3 bridge.py init-token            # writes $AGENT_CLI_STATE/bridge.token (0600), prints its path
    python3 bridge.py serve [--port 8765]   # 127.0.0.1 only

Every route needs ``X-GM-Bridge-Token``. A profile is served only while its lockdown gate says PASS
for the CLI binary, version and wrapper found now, and not after a run used a tool (tripped). The
bridge never takes a path, flag or URL from a request, never returns stderr, never retries, and
logs one line per request without the prompt, the answer, stderr, the token or any env value.
Python 3.9+ standard library only; the Rails app never loads this file.
"""

from __future__ import annotations

import argparse
import hmac
import json
import os
import secrets
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Dict, Optional, Tuple

import agent_cli

BRIDGE_VERSION = "1.0.0"
LISTEN = "127.0.0.1"
DEFAULT_PORT = 8765
MAX_BODY = 1024 * 1024
TOKEN_MIN_BYTES = 32
KEYS = {"profile", "model", "prompt", "timeout_s", "task", "run_id"}
TASKS = ("summary", "scan", "judge")
STATUS = {"ok": 200, "bridge_bad_request": 400, "bridge_unauthorized": 401, "bridge_not_found": 404,
          "bridge_method_not_allowed": 405, "prompt_too_long": 413, "bridge_busy": 429, "cli_missing": 503,
          "gate_missing": 503, "gate_failed": 503, "gate_stale": 503, "tripped": 503, "bridge_error": 500}
ROUTES = {"/v1/health": "GET", "/v1/complete": "POST"}


class StartError(RuntimeError):
    """The bridge refuses to start (bad listen address, token file or profile); the message is safe to print."""


def token_path(state: str) -> str:
    """Return ``<state>/bridge.token``."""
    return os.path.join(state, "bridge.token")


def init_token(state: str, force: bool = False) -> str:
    """Write a new random token (0600) and return its path; refuse to overwrite one unless ``force``."""
    path = token_path(state)
    if os.path.lexists(path) and not force:
        raise StartError("%s exists (pass --force to replace it)" % path)
    fresh = path + ".new"
    if os.path.lexists(fresh):
        os.remove(fresh)
    handle = os.open(fresh, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(handle, "w", encoding="utf-8") as out:
        out.write(secrets.token_urlsafe(32) + "\n")
    os.replace(fresh, path)
    return path


def load_token(state: str) -> str:
    """Return the token, or raise StartError unless the file is the user's own regular 0600 file of 32+ bytes."""
    token = agent_cli.read_private_file(token_path(state))
    if token is None or len(token.encode("utf-8")) < TOKEN_MIN_BYTES:
        raise StartError("%s must exist, be a regular file you own, mode 0600, with at least %d bytes (bridge.py init-token)"
                         % (token_path(state), TOKEN_MIN_BYTES))
    return token


def _private_json(path: str) -> Optional[dict]:
    text = agent_cli.read_private_file(path)
    try:
        doc = json.loads(text) if text else None
    except ValueError:
        return None
    return doc if isinstance(doc, dict) else None


class Bridge:
    """The bridge's state: the token, the validated profiles, a non-blocking lock per profile."""

    def __init__(self, token: str, state: str, profiles: Dict[str, agent_cli.Profile], log=None):
        self.token, self.state, self.profiles = token, state, profiles
        self.locks = {name: threading.Lock() for name in profiles}
        self.log_stream = log or sys.stderr

    def authorized(self, header: Optional[str]) -> bool:
        """Compare the request's token in constant time."""
        return bool(header) and hmac.compare_digest(header.encode("utf-8"), self.token.encode("utf-8"))

    def gate_record(self, name: str) -> Optional[dict]:
        """The profile's ``gates/<name>.json`` (only if it is the user's 0600 file)."""
        return _private_json(os.path.join(self.state, "gates", name + ".json"))

    def tripped(self, name: str) -> bool:
        """Whether ``tripped/<name>.json`` exists (a run used a tool; cleared by a lockdown PASS)."""
        return os.path.lexists(os.path.join(self.state, "tripped", name + ".json"))

    def trip(self, name: str, run_id: str):
        """Record a tool-use run (run id and class only, no content)."""
        folder = os.path.join(self.state, "tripped")
        os.makedirs(folder, mode=0o700, exist_ok=True)
        path = os.path.join(folder, name + ".json")
        handle = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0), 0o600)
        with os.fdopen(handle, "w", encoding="utf-8") as out:
            json.dump({"profile": name, "run_id": run_id, "failure_class": "cli_tool_use"}, out)

    def gate_check(self, name: str, model: Optional[str] = None) -> Tuple[Optional[str], dict]:
        """``(failure class or None, what was found)``: the CLI now versus the gate record, by realpath,
        version and wrapper digest; ``passed_on`` is never compared to anything."""
        profile = self.profiles[name]
        found = agent_cli.resolve_cli(profile)
        info = {"cli_ok": bool(found), "cli_realpath": found[1] if found else None, "cli_version": None}
        if not found:
            return "cli_missing", info
        info["cli_version"] = agent_cli.cli_version(profile, found)
        record = self.gate_record(name)
        if record is None:
            return "gate_missing", info
        if record.get("result") != "PASS":
            return "gate_failed", info
        current = (found[1], info["cli_version"], agent_cli.wrapper_digest(profile))
        if current != (record.get("cli_realpath"), record.get("cli_version"), record.get("wrapper_digest")):
            return "gate_stale", info
        if model is not None and model not in (record.get("models") or []):
            return "gate_missing", info
        return None, info

    def health(self) -> dict:
        """``GET /v1/health``: per profile, the CLI found, its gate record and whether it can serve."""
        profiles = {}
        for name in self.profiles:
            problem, info = self.gate_check(name)
            record = self.gate_record(name)
            gate = {key: record.get(key) for key in ("result", "cli_version", "wrapper_digest", "models", "passed_on")} if record else None
            tripped = self.tripped(name)
            profiles[name] = dict(info, gate=gate, gate_ok=problem is None, tripped=tripped)
        return {"bridge_version": BRIDGE_VERSION, "profiles": profiles}

    def validate(self, body: bytes) -> Optional[dict]:
        """The request as a dict if it has exactly the allowed keys with allowed values, else None."""
        try:
            request = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, ValueError, RecursionError):  # RecursionError: very deep nesting
            return None
        if not isinstance(request, dict) or set(request) != KEYS:
            return None
        profile = self.profiles.get(request["profile"]) if isinstance(request["profile"], str) else None
        model, timeout = request["model"], request["timeout_s"]
        checks = [
            profile is not None,
            isinstance(model, str) and not model.startswith("-") and bool(profile and profile.model_re.fullmatch(model)),
            isinstance(request["prompt"], str) and request["prompt"] != "" and _plain_text(request["prompt"]),
            isinstance(timeout, int) and not isinstance(timeout, bool) and 1 <= timeout <= 600,
            request["task"] in TASKS,
            isinstance(request["run_id"], str) and _is_uuid(request["run_id"]),
        ]
        return request if all(checks) else None

    def complete(self, request: dict) -> Tuple[str, dict]:
        """Run one validated request under its profile's lock: ``(class, response body)``."""
        name = request["profile"]
        lock = self.locks[name]
        if not lock.acquire(blocking=False):
            return "bridge_busy", {}
        try:
            if self.tripped(name):
                return "tripped", {}
            problem, info = self.gate_check(name, request["model"])
            if problem:
                return problem, {"cli_version": info["cli_version"]}
            result, _raw = agent_cli.run_cli(self.profiles[name], request["prompt"], request["model"],
                                             request["timeout_s"], request["run_id"])
            if result["failure_class"] == "cli_tool_use":
                self.trip(name, request["run_id"])
            return result["failure_class"] or "ok", dict(result, cli_version=info["cli_version"])
        finally:
            lock.release()

    def log(self, fields: dict):
        """One line per request (validated fields only; never the prompt, answer, stderr, token or env)."""
        self.log_stream.write("[llm_bridge] %s\n" % json.dumps(fields, sort_keys=False))
        self.log_stream.flush()


def _plain_text(value: str) -> bool:
    """Encodable as UTF-8 (no lone surrogate) and without NUL (which can't go into argv)."""
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return "\x00" not in value


def _is_uuid(value: str) -> bool:
    try:
        return str(uuid.UUID(value)) == value.lower()
    except ValueError:
        return False


def response_body(cls: str, extra: dict) -> dict:
    """The response shape for every request: ``ok, text, failure_class, model_used, cli_version, latency_ms``."""
    body = {"ok": cls == "ok", "text": None, "failure_class": None if cls == "ok" else cls, "model_used": None,
            "cli_version": None, "latency_ms": None}
    body.update({key: value for key, value in extra.items() if key in body})
    return body


class Handler(BaseHTTPRequestHandler):
    """Routes, the token check, the body limit and the log line; the work is in Bridge."""

    server_version = "graph_mem-llm-bridge"
    sys_version = ""
    protocol_version = "HTTP/1.1"
    timeout = 30

    def log_message(self, format, *args):  # noqa: A002 (the base class's name); the default access log is off
        pass

    def _send(self, status: int, payload: dict):
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _route(self, method: str):
        started = time.monotonic()
        bridge = self.server.bridge
        fields = {"run_id": None, "profile": None, "model": None, "task": None, "prompt_bytes": None}
        if not bridge.authorized(self.headers.get("X-GM-Bridge-Token")):
            cls, payload = "bridge_unauthorized", response_body("bridge_unauthorized", {})
        elif self.path not in ROUTES:
            cls, payload = "bridge_not_found", response_body("bridge_not_found", {})
        elif ROUTES[self.path] != method:
            cls, payload = "bridge_method_not_allowed", response_body("bridge_method_not_allowed", {})
        elif self.path == "/v1/health":
            cls, payload = "ok", bridge.health()
        else:
            cls, payload = self._complete(bridge, fields)
        status = STATUS.get(cls, 200)
        if payload.get("latency_ms", 0) is None:
            payload["latency_ms"] = round((time.monotonic() - started) * 1000, 1)
        if status >= 400 and status != 413:
            self.close_connection = True
        # Logged before the answer goes out, so the line exists once the client has it (or hangs up).
        bridge.log(dict(fields, status=status, failure_class=None if cls == "ok" else cls,
                        latency_ms=round((time.monotonic() - started) * 1000, 1)))
        self._send(status, payload)

    def _complete(self, bridge: Bridge, fields: dict):
        content_type = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        length = self.headers.get("Content-Length")
        if content_type != "application/json" or length is None or not length.isdigit():
            return "bridge_bad_request", response_body("bridge_bad_request", {})
        if int(length) > MAX_BODY:  # not read past the limit
            self.close_connection = True
            return "prompt_too_long", response_body("prompt_too_long", {})
        request = bridge.validate(self.rfile.read(int(length)))
        if request is None:
            return "bridge_bad_request", response_body("bridge_bad_request", {})
        fields.update({key: request[key] for key in ("run_id", "profile", "model", "task")},
                      prompt_bytes=len(request["prompt"].encode("utf-8")))
        try:
            cls, extra = bridge.complete(request)
        except Exception:  # noqa: BLE001: never a traceback, an exception text or a path in the answer or the log
            cls, extra = "bridge_error", {}
        return cls, response_body(cls, dict(extra, model_used=extra.get("model_used", request["model"])))

    def do_GET(self):  # noqa: N802 (http.server's naming)
        """Serve GET."""
        self._route("GET")

    def do_POST(self):  # noqa: N802
        """Serve POST."""
        self._route("POST")

    def do_PUT(self):  # noqa: N802
        """Refuse PUT (after the token check)."""
        self._route("PUT")

    def do_DELETE(self):  # noqa: N802
        """Refuse DELETE (after the token check)."""
        self._route("DELETE")

    def do_PATCH(self):  # noqa: N802
        """Refuse PATCH (after the token check)."""
        self._route("PATCH")

    def do_OPTIONS(self):  # noqa: N802
        """Refuse OPTIONS: no CORS headers, so a browser page can't send the token header."""
        self._route("OPTIONS")


class BridgeServer(ThreadingHTTPServer):
    """ThreadingHTTPServer whose error report is one fixed line (the default prints a traceback)."""

    daemon_threads = True

    def handle_error(self, request, client_address):
        """Log that a connection failed, nothing about it."""
        self.bridge.log({"status": None, "failure_class": "bridge_error"})


def make_server(listen: str = LISTEN, port: int = DEFAULT_PORT, log=None) -> BridgeServer:
    """Build the server after every start check (listen address, token file, profiles); raise StartError."""
    if listen != LISTEN:
        raise StartError("the bridge listens on %s only" % LISTEN)
    if not isinstance(port, int) or not 0 <= port <= 65535:
        raise StartError("bad port")
    state = agent_cli.state_dir()
    token = load_token(state)
    try:
        profiles = {name: agent_cli.load_profile(name) for name in agent_cli.shipped_profiles()}
    except agent_cli.ProfileError as error:
        raise StartError("profile: %s" % error) from None
    server = BridgeServer((LISTEN, port), Handler)
    server.bridge = Bridge(token, state, profiles, log)
    return server


def main(argv=None) -> int:
    """Command line: ``serve [--listen 127.0.0.1] [--port 8765]`` and ``init-token [--force]``."""
    parser = argparse.ArgumentParser(prog="bridge.py", description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    serve = commands.add_parser("serve", help="serve /v1/health and /v1/complete on 127.0.0.1")
    serve.add_argument("--listen", default=LISTEN)
    serve.add_argument("--port", type=int, default=DEFAULT_PORT)
    init = commands.add_parser("init-token", help="write a new bridge token (0600) and print its path")
    init.add_argument("--force", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.command == "init-token":
            print(init_token(agent_cli.state_dir(), args.force))
            return 0
        server = make_server(args.listen, args.port)
    except StartError as error:
        print("bridge: %s" % error, file=sys.stderr)
        return 2
    print("bridge: listening on %s:%d" % server.server_address[:2], file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
