#!/usr/bin/env python3
"""Agent-CLI profiles and the wrapper (graph_mem ``script/llm_bridge/``, agent-CLI train PR3).

A profile (``profiles/<name>.json``) describes one agent CLI as data: how to call it non-interactively with
every tool, MCP server, config file and network action off, how to hand it the prompt, and how to read and
classify its answer. ``run_cli`` runs it once in an empty 0700 directory with an environment built from
scratch. Python 3.9+ standard library only; the Rails app never loads this file.

    python3 agent_cli.py check --profile claude
    python3 agent_cli.py run --profile claude prompt.txt <model> 120
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import pwd
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from typing import Dict, List, Optional, Tuple

from profile_schema import BUILT_ENV, CLASSES, HOOK, Profile, ProfileError, load_profile, shipped_profiles  # noqa: F401 (re-exported)

HERE = os.path.dirname(os.path.realpath(__file__))
STDOUT_CAP = 256 * 1024
STDERR_CAP = 64 * 1024
TERM_GRACE_S = 5.0
VERSION_TIMEOUT_S = 10
BASE_PATH = "/usr/local/bin:/usr/bin:/bin"
ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]")
CONTROL_RE = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")
TOOL_KEYS = ("tool_calls", "tool_call", "tool_use", "function_call")


def override_variable(name: str) -> str:
    """Return the environment variable that overrides a profile's ``cli_path`` (``AGENT_CLI_<NAME>_PATH``)."""
    return "AGENT_CLI_%s_PATH" % name.upper().replace("-", "_")


def resolve_cli(profile: Profile) -> Optional[Tuple[str, str]]:
    """Return ``(path found, realpath)`` of the profile's CLI, or None when it isn't installed."""
    found = shutil.which(os.environ.get(override_variable(profile.name)) or profile["cli_path"])
    if not found:
        return None
    real = os.path.realpath(found)
    return (found, real) if os.path.isfile(real) and os.access(real, os.X_OK) else None


def clean(text: str) -> str:
    """Strip ANSI sequences and control characters other than newline and tab."""
    return CONTROL_RE.sub("", ANSI_RE.sub("", text))


def _search_path(found):
    dirs = []
    for path in found:
        directory = os.path.dirname(path)
        if directory not in dirs:
            dirs.append(directory)
    return ":".join(dirs + [BASE_PATH])


_VERSIONS: Dict[tuple, str] = {}
_VERSIONS_LOCK = threading.Lock()


def cli_version(profile: Profile, found: Tuple[str, str]) -> Optional[str]:
    """Return the CLI's version line, cached per (realpath, inode, size) only, never by time."""
    real = found[1]
    try:
        info = os.stat(real)
    except OSError:
        return None
    key = (real, info.st_ino, info.st_size, tuple(profile["version_args"]))
    with _VERSIONS_LOCK:
        if key in _VERSIONS:
            return _VERSIONS[key]
    with tempfile.TemporaryDirectory(prefix="agent-cli-version-") as scratch:
        env = {"PATH": _search_path(found), "HOME": scratch, "LANG": "C.UTF-8", "TERM": "dumb", "NO_COLOR": "1"}
        try:
            done = subprocess.run([real, *profile["version_args"]], cwd=scratch, env=env, stdin=subprocess.DEVNULL,
                                  capture_output=True, timeout=VERSION_TIMEOUT_S, start_new_session=True)
        except (OSError, subprocess.TimeoutExpired):
            return None
    lines = clean(done.stdout.decode("utf-8", "replace")).strip().splitlines()
    if done.returncode != 0 or not lines:
        return None
    with _VERSIONS_LOCK:
        _VERSIONS[key] = lines[0].strip()[:200]
    return _VERSIONS[key]


def wrapper_digest(profile: Profile) -> str:
    """SHA-256 over ``agent_cli.py``, ``profile_schema.py``, ``deny-hook.sh`` and the profile file, in that order."""
    digest = hashlib.sha256()
    for path in (os.path.realpath(__file__), os.path.join(HERE, "profile_schema.py"), HOOK, profile.path):
        with open(path, "rb") as handle:
            digest.update(handle.read())
    return digest.hexdigest()


def state_dir() -> str:
    """Return ``$AGENT_CLI_STATE`` (default ``~/.local/state/agent-cli``), created 0700."""
    path = os.environ.get("AGENT_CLI_STATE") or os.path.join(real_home(), ".local", "state", "agent-cli")
    os.makedirs(path, mode=0o700, exist_ok=True)
    return os.path.realpath(path)


def runs_dir(state: str) -> str:
    """Where run dirs go (created 0700): ``$XDG_RUNTIME_DIR/agent-cli`` when that is the user's own 0700 dir (its
    parents are root's), else ``<state>/runs``. Never the shared /tmp: CLIs search a run dir's parents for config."""
    runtime = os.environ.get("XDG_RUNTIME_DIR") or ""
    info = os.stat(runtime) if runtime and os.path.isdir(runtime) else None
    private = info is not None and info.st_uid == os.getuid() and not info.st_mode & 0o077
    path = os.path.join(runtime, "agent-cli") if private else os.path.join(state, "runs")
    os.makedirs(path, mode=0o700, exist_ok=True)
    return path


def real_home() -> str:
    """Return the running user's home directory from the password database (not ``$HOME``)."""
    return pwd.getpwuid(os.getuid()).pw_dir


def read_private_file(path: str) -> Optional[str]:
    """Return a file's stripped text only if it is a regular file the user owns with mode 0600 (or stricter)."""
    try:
        handle = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError:
        return None
    try:
        info = os.fstat(handle)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            return None
        data = os.read(handle, 65536)
    finally:
        os.close(handle)
    value = data.decode("utf-8", "replace").strip()
    return value or None


def subst(value, ctx: Dict[str, str]):
    """Replace ``{run}``, ``{home}``, ``{hook}`` and ``{state}`` in strings, lists and objects; nothing else."""
    if isinstance(value, str):
        for key in ("run", "home", "hook", "state"):
            value = value.replace("{%s}" % key, ctx[key])
        return value
    if isinstance(value, list):
        return [subst(item, ctx) for item in value]
    if isinstance(value, dict):
        return {key: subst(item, ctx) for key, item in value.items()}
    return value


def choose_mode(profile: Profile, size: int) -> Optional[dict]:
    """Return the first prompt mode whose ``max_bytes`` fits ``size`` bytes, or None (prompt_too_long)."""
    for mode in profile["prompt"]:
        if mode.get("max_bytes") is None or size <= mode["max_bytes"]:
            return mode
    return None


def build_argv(profile: Profile, real: str, model: str, mode: dict, ctx: Dict[str, str], omit_trust=False) -> List[str]:
    """Return argv as a list: CLI, base, trust, max-turns and lockdown args, the model, the prompt args."""
    argv = [real, *subst(profile["base_args"], ctx)]
    if not omit_trust:
        argv += subst(profile["trust_args"], ctx)
    argv += subst(profile["max_turns_args"], ctx) + subst(profile["lockdown_args"], ctx)
    argv += [profile["model_flag"], model]
    if mode["mode"] == "file":
        argv += [mode["flag"], os.path.join(ctx["run"], "prompt.txt")]
    elif mode["mode"] == "arg":
        argv += ["--", ctx["prompt"]]
    return argv


def build_env(profile: Profile, found: Tuple[str, str], ctx: Dict[str, str], run_id: str) -> Optional[Dict[str, str]]:
    """Return the run's environment, built from scratch, or None when a ``secret_env`` file isn't the user's 0600 file."""
    spec = profile["env"]
    data_home = (os.environ.get("XDG_DATA_HOME") or os.path.join(real_home(), ".local", "share")) \
        if spec["xdg_data_home"] == "owner" else os.path.join(ctx["run"], "data")
    env = {
        "PATH": _search_path(found), "HOME": ctx["home"] if spec["home"] == "synthetic" else real_home(),
        "XDG_CONFIG_HOME": os.path.join(ctx["run"], "config"), "XDG_CACHE_HOME": os.path.join(ctx["run"], "cache"),
        "XDG_DATA_HOME": data_home, "NO_COLOR": "1", "TERM": "dumb", "LANG": "C.UTF-8",
        "GM_LLM_RUN_ID": run_id, "AGENT_CLI_STATE": ctx["state"],
    }
    env.update(spec["set"])  # fixed values from the profile (e.g. switches that stop memory files loading)
    for name in spec["pass"]:
        if name in os.environ:
            env[name] = os.environ[name]
    for name, template in spec["secret_env"].items():
        value = read_private_file(subst(template, ctx))
        if value is None:
            return None
        env[name] = value
    return env


def _write_private(path, data: bytes):
    handle = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(handle, "wb") as out:
        out.write(data)


def prepare_run_dir(profile: Profile, run: str, prompt: bytes, state: str, test_seed=None) -> Dict[str, str]:
    """Fill the 0700 run dir: ``prompt.txt``, the synthetic ``home/``, ``config/``, ``cache/``, ``data/``, config files."""
    ctx = {"run": run, "home": os.path.join(run, "home"), "hook": HOOK, "state": state,
           "prompt": prompt.decode("utf-8")}
    for sub in ("home", "config", "cache", "data"):
        os.mkdir(os.path.join(run, sub), 0o700)
    _write_private(os.path.join(run, "prompt.txt"), prompt)
    for entry in profile["config_files"]:
        path = os.path.realpath(subst(entry["path"], ctx))
        if not path.startswith(run + os.sep):
            raise ProfileError("config_files: path escapes the run dir")
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        content = entry["content"]
        text = subst(content, ctx) if isinstance(content, str) else json.dumps(subst(content, ctx), indent=2)
        _write_private(path, text.encode("utf-8"))
    if test_seed:  # lockdown decoys only; bridge.py never passes it
        for part, target in (("run", run), ("home", ctx["home"])):
            source = os.path.join(test_seed, part)
            if os.path.isdir(source):
                shutil.copytree(source, target, dirs_exist_ok=True)
    return ctx


def _drain(handle, cap, sink: bytearray, on_over=None):
    while True:
        try:
            chunk = os.read(handle, 65536)
        except OSError:
            return
        if not chunk:
            return
        room = cap + 1 - len(sink)
        if room > 0:
            sink.extend(chunk[:room])
        if on_over and len(sink) > cap:
            on_over()
            on_over = None


def _feed(pipe, data):
    with contextlib.suppress(OSError):
        pipe.write(data)
        pipe.close()


def kill_group(proc, sig):
    """Send ``sig`` to the run's process group (it was started in its own session)."""
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.killpg(proc.pid, sig)


def execute(argv: List[str], env: dict, cwd: str, stdin_data: Optional[bytes], timeout: float) -> Optional[dict]:
    """Run argv with a timeout (SIGTERM to the group, then SIGKILL) and output caps; None if it can't start."""
    try:
        proc = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.PIPE if stdin_data is not None else subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True, close_fds=True)
    except OSError:
        return None
    out, err, over = bytearray(), bytearray(), threading.Event()

    def cap_hit():
        over.set()
        kill_group(proc, signal.SIGKILL)

    threads = [threading.Thread(target=_drain, args=(proc.stdout.fileno(), STDOUT_CAP, out, cap_hit), daemon=True),
               threading.Thread(target=_drain, args=(proc.stderr.fileno(), STDERR_CAP, err), daemon=True)]
    if stdin_data is not None:
        threads.append(threading.Thread(target=_feed, args=(proc.stdin, stdin_data), daemon=True))
    for thread in threads:
        thread.start()
    timed_out = False
    try:
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        kill_group(proc, signal.SIGTERM)
        try:
            proc.wait(timeout=TERM_GRACE_S)
        except subprocess.TimeoutExpired:
            kill_group(proc, signal.SIGKILL)
            proc.wait()
    kill_group(proc, signal.SIGKILL)  # nothing a run started outlives it
    for thread in threads:
        thread.join(timeout=5)
    for pipe in (proc.stdout, proc.stderr):
        pipe.close()
    return {"exit": proc.returncode, "stdout": bytes(out[:STDOUT_CAP]), "stderr": bytes(err[:STDERR_CAP]),
            "timed_out": timed_out, "over_cap": over.is_set()}


def _dig(doc, path):
    for key in path.split("."):
        if not isinstance(doc, dict) or key not in doc:
            return None
        doc = doc[key]
    return doc


def unwrap(profile: Profile, stdout: str) -> dict:
    """Read the answer: the whole stdout for ``text``, the ``text_path`` field of a JSON envelope for ``json``."""
    out = profile["output"]
    if out["format"] == "text":
        return {"valid": True, "text": stdout, "error": False, "subtype": "", "turns": None}
    try:
        doc = json.loads(stdout)
    except (ValueError, RecursionError):
        return {"valid": False, "text": None, "error": False, "subtype": "", "turns": None}
    pick = lambda key: _dig(doc, out[key]) if out.get(key) else None  # noqa: E731
    text, subtype = pick("text_path"), pick("subtype_path")
    return {"valid": isinstance(text, str), "text": text, "error": bool(pick("error_path")),
            "subtype": subtype if isinstance(subtype, str) else "", "turns": pick("turns_path")}


def _tool_steps(node) -> int:
    """Tool calls in a transcript node; a doubtful node may count twice (more steps than hook calls fails closed)."""
    if isinstance(node, dict):
        own = int(node.get("type") in TOOL_KEYS)
        own += sum(len(node[key]) if isinstance(node[key], list) else 1 for key in TOOL_KEYS if node.get(key))
        return own + sum(_tool_steps(value) for value in node.values())
    return sum(_tool_steps(item) for item in node) if isinstance(node, list) else 0


def transcript_tool_steps(text: Optional[str], exit_code) -> Optional[int]:
    """The tool calls in an exported transcript (JSON or JSON lines); None when it is unreadable (fail closed),
    or missing although the run succeeded (a failed run may have stopped before writing one: 0)."""
    if text is None:
        return None if exit_code == 0 else 0
    try:
        try:
            docs = [json.loads(text)]
        except ValueError:
            docs = [json.loads(line) for line in text.splitlines() if line.strip()]
        return _tool_steps(docs)
    except (ValueError, RecursionError):  # unreadable or too deep to walk
        return None


def _hook_lines(state, offset, run_id):
    path = os.path.join(state, "hook.log")
    try:
        with open(path, "rb") as handle:
            handle.seek(offset)
            tail = handle.read().decode("utf-8", "replace")
    except OSError:
        return []
    return [line for line in tail.splitlines() if ("\t%s\t" % run_id) in line]


def _size(path):
    return os.path.getsize(path) if os.path.isfile(path) else 0


def tool_use(profile: Profile, proc: dict, envelope: dict, hook_lines: list, transcript: Optional[str], stdout: str):
    """``"used"`` (cli_tool_use), ``"denied"`` or None. Too many turns, the stdout pattern or an unreadable
    transcript is use. Otherwise any hook.log line or transcript tool call is use, except on a profile whose
    tools are denied rather than removed (``tools_fully_disabled: false``, with the hook wired): there, when
    the deny hook saw at least as many calls as the transcript shows, each was refused (cli_tool_denied)."""
    trace, turns = profile["tool_trace"], envelope["turns"]
    if (trace["max_turns"] is not None and isinstance(turns, int) and turns > trace["max_turns"]) or \
            (profile.stdout_re and profile.stdout_re.search(stdout)):
        return "used"
    steps = transcript_tool_steps(transcript, proc["exit"]) if trace["export_path"] else 0
    if steps is None:
        return "used"
    if not steps and not hook_lines:
        return None
    hooked = not profile["tools_fully_disabled"] and trace["hook_log"] and len(hook_lines) >= steps
    return "denied" if hooked else "used"


def classify(profile: Profile, proc: dict, envelope: dict, stdout: str, stderr: str) -> str:
    """The failure class of a finished run that used no tool (first match wins), or ``ok``."""
    if proc["timed_out"]:
        return "cli_timeout"
    if proc["over_cap"]:
        return "cli_bad_output"
    if proc["exit"] == 0 and not envelope["error"]:
        return "ok" if envelope["valid"] and envelope["text"].strip() else "cli_bad_output"
    text = envelope["text"] if isinstance(envelope["text"], str) else ("" if envelope["valid"] else stdout)
    haystack = "\n".join([text, envelope["subtype"], stderr])
    for cls, pattern in profile.patterns:
        if pattern.search(haystack):
            return cls
    return profile["exit_codes"].get(str(proc["exit"]), "cli_error")


def _outcome(model, cls, started, text=None, raw=None):
    result = {"ok": cls == "ok", "text": text if cls == "ok" else None, "failure_class": None if cls == "ok" else cls,
              "model_used": model, "latency_ms": round((time.monotonic() - started) * 1000, 1)}
    return result, raw or {"stdout": "", "stderr": "", "transcript": None, "hook_lines": []}


def run_cli(profile: Profile, prompt: str, model: str, timeout_s: float, run_id: str, test_seed=None, omit_trust=False):
    """Run the profile's CLI once on ``prompt`` and return ``(result, raw)``.

    ``result`` is ``{ok, text, failure_class, model_used, latency_ms}`` (``text`` cleaned, only when ok);
    ``raw`` (stdout, stderr, transcript, hook lines) is for the lockdown test only and never leaves the host.
    """
    started = time.monotonic()
    if not isinstance(model, str) or model.startswith("-") or not profile.model_re.fullmatch(model):
        raise ValueError("model does not match the profile's model_pattern")
    if "\x00" in prompt:
        raise ValueError("the prompt holds a NUL")
    found = resolve_cli(profile)
    if not found:
        return _outcome(model, "cli_missing", started)
    data = prompt.encode("utf-8")
    mode = choose_mode(profile, len(data))
    if mode is None:
        return _outcome(model, "prompt_too_long", started)
    state = state_dir()
    run = os.path.realpath(tempfile.mkdtemp(prefix="agent-cli-run-", dir=runs_dir(state)))
    cls = "cli_error"
    try:
        ctx = prepare_run_dir(profile, run, data, state, test_seed)
        env = build_env(profile, found, ctx, run_id)
        if env is None:
            cls = "cli_auth"
            return _outcome(model, cls, started)
        offset = _size(os.path.join(state, "hook.log"))
        proc = execute(build_argv(profile, found[1], model, mode, ctx, omit_trust), env, run,
                       data if mode["mode"] == "stdin" else None, timeout_s)
        if proc is None:
            cls = "cli_missing"
            return _outcome(model, cls, started)
        stdout, stderr = proc["stdout"].decode("utf-8", "replace"), proc["stderr"].decode("utf-8", "replace")
        export = profile["tool_trace"]["export_path"]
        transcript = _read_text(subst(export, ctx)) if export else None
        raw = {"stdout": stdout, "stderr": stderr, "transcript": transcript, "hook_lines": _hook_lines(state, offset, run_id)}
        envelope = unwrap(profile, stdout)
        used = tool_use(profile, proc, envelope, raw["hook_lines"], transcript, stdout)
        cls = {"used": "cli_tool_use", "denied": "cli_tool_denied"}.get(used) or classify(profile, proc, envelope, stdout, stderr)
        text = envelope["text"] if isinstance(envelope["text"], str) else ""
        return _outcome(model, cls, started, clean(text), raw)
    finally:
        if cls == "ok" or os.environ.get("AGENT_CLI_KEEP_FAILED") != "1":
            shutil.rmtree(run, ignore_errors=True)


def _read_text(path):
    try:
        with open(path, "rb") as handle:
            return handle.read(4 * STDOUT_CAP).decode("utf-8", "replace")
    except OSError:
        return None


def check(profile: Profile) -> dict:
    """What the bridge and the gate compare: the CLI found now, its version, and the wrapper digest."""
    found = resolve_cli(profile)
    return {"profile": profile.name, "cli_ok": bool(found), "cli_path": found[0] if found else None,
            "cli_realpath": found[1] if found else None, "cli_version": cli_version(profile, found) if found else None,
            "wrapper_digest": wrapper_digest(profile)}


def main(argv=None) -> int:
    """Command line: ``check --profile <name>`` and ``run --profile <name> <prompt-file> <model> <timeout>``."""
    parser = argparse.ArgumentParser(prog="agent_cli.py", description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    check_cmd = commands.add_parser("check", help="validate a profile and report the CLI it finds")
    run_cmd = commands.add_parser("run", help="run a profile's CLI once and print the result as JSON")
    for command in (check_cmd, run_cmd):
        command.add_argument("--profile", required=True)
    for name in ("prompt_file", "model"):
        run_cmd.add_argument(name)
    run_cmd.add_argument("timeout", type=int)
    run_cmd.add_argument("--run-id", default=None)
    run_cmd.add_argument("--test-seed", default=None, help="lockdown test only: decoys copied into the run dir")
    run_cmd.add_argument("--omit-trust", action="store_true", help="lockdown test only: leave out trust_args")
    args = parser.parse_args(argv)
    try:
        profile = load_profile(args.profile)
    except ProfileError as error:
        print(f"agent_cli: {error}", file=sys.stderr)
        return 2
    if args.command == "check":
        report = check(profile)
        print(json.dumps(report, indent=2))
        return 0 if report["cli_ok"] else 1
    with open(args.prompt_file, encoding="utf-8") as handle:
        prompt = handle.read()
    result, _raw = run_cli(profile, prompt, args.model, args.timeout, args.run_id or str(uuid.uuid4()),
                           test_seed=args.test_seed, omit_trust=args.omit_trust)
    print(json.dumps(result))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
