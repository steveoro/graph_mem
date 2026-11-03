"""Profile schema and loader for the agent-CLI wrapper (graph_mem ``script/llm_bridge/``, agent-CLI PR3).

``load_profile(name)`` reads ``profiles/<name>.json`` and validates it strictly: an unknown key or a
wrong type is an error, so a typo can't silently drop a lockdown flag, and every regex must compile.
Python 3.9+ standard library only; part of the gate's ``wrapper_digest``.
"""

from __future__ import annotations

import json
import os
import re
from typing import List

HERE = os.path.dirname(os.path.realpath(__file__))
PROFILE_DIR = os.path.join(HERE, "profiles")
HOOK = os.path.join(HERE, "deny-hook.sh")
NAME_RE = re.compile(r"[a-z][a-z0-9_-]{0,31}")
ENV_NAME_RE = re.compile(r"[A-Z_][A-Z0-9_]{0,63}")
PATTERN_CLASSES = ("prompt_too_long", "cli_quota", "cli_rate_limited", "cli_auth", "cli_model_unavailable",
                   "cli_payment_required", "cli_config", "cli_sandbox", "cli_truncated", "cli_turn_limit")
CLASSES = ("cli_tool_use", "cli_missing", "cli_timeout") + PATTERN_CLASSES + ("cli_error", "cli_bad_output", "ok")
BUILT_ENV = ("PATH", "HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "NO_COLOR", "TERM", "LANG",
             "GM_LLM_RUN_ID", "AGENT_CLI_STATE")

TYPES = {
    "str": lambda v: isinstance(v, str),
    "str?": lambda v: v is None or isinstance(v, str),
    "int?": lambda v: v is None or (isinstance(v, int) and not isinstance(v, bool)),
    "bool": lambda v: isinstance(v, bool),
    "strings": lambda v: isinstance(v, list) and all(isinstance(item, str) for item in v),
    "object": lambda v: isinstance(v, dict),
    "list": lambda v: isinstance(v, list),
    "content": lambda v: isinstance(v, (str, dict)),
}
TOP = {key: (kind, True) for key, kind in {
    "name": "str", "cli_path": "str", "version_args": "strings", "base_args": "strings", "model_flag": "str",
    "model_pattern": "str", "prompt": "list", "output": "object", "lockdown_args": "strings", "config_files": "list",
    "trust_args": "strings", "max_turns_args": "strings", "tools_fully_disabled": "bool", "tool_trace": "object",
    "env": "object", "failure_patterns": "object", "exit_codes": "object"}.items()}
PROMPT_MODE = {"mode": ("str", True), "max_bytes": ("int?", False), "flag": ("str?", False)}
OUTPUT = {"format": ("str", True), "text_path": ("str?", False), "error_path": ("str?", False),
          "subtype_path": ("str?", False), "turns_path": ("str?", False)}
CONFIG_FILE = {"path": ("str", True), "content": ("content", True)}
TOOL_TRACE = {"hook_log": ("bool", True), "max_turns": ("int?", True), "export_path": ("str?", True),
              "stdout_pattern": ("str?", True)}
ENV = {"home": ("str", True), "xdg_data_home": ("str", True), "pass": ("strings", True), "secret_env": ("object", True)}


class ProfileError(ValueError):
    """A profile file that is missing, malformed or unsafe (the message names the key, never a value)."""


def _fields(obj, spec, where):
    if not isinstance(obj, dict):
        raise ProfileError(f"{where}: expected an object")
    unknown = sorted(set(obj) - set(spec))
    if unknown:
        raise ProfileError(f"{where}: unknown key(s) {unknown}")
    for key, (kind, required) in spec.items():
        if key not in obj:
            if required:
                raise ProfileError(f"{where}.{key}: missing")
        elif not TYPES[kind](obj[key]):
            raise ProfileError(f"{where}.{key}: expected {kind}")


def _regex(source, where, flags=0):
    try:
        return re.compile(source, flags)
    except re.error as error:
        raise ProfileError(f"{where}: bad regex ({error.msg})") from None


def _check_prompt_and_files(data):
    if not data["prompt"]:
        raise ProfileError("prompt: needs at least one mode")
    for index, mode in enumerate(data["prompt"]):
        _fields(mode, PROMPT_MODE, f"prompt[{index}]")
        if mode["mode"] not in ("arg", "file", "stdin"):
            raise ProfileError(f"prompt[{index}].mode: arg, file or stdin")
        if mode["mode"] in ("arg", "stdin") and mode.get("max_bytes") is None:
            raise ProfileError(f"prompt[{index}].max_bytes: required for {mode['mode']}")
        if mode["mode"] == "file" and not mode.get("flag"):
            raise ProfileError(f"prompt[{index}].flag: required for file")
    for index, entry in enumerate(data["config_files"]):
        _fields(entry, CONFIG_FILE, f"config_files[{index}]")
        path = entry["path"]
        if not path.startswith(("{run}/", "{home}/")) or ".." in path.split("/"):
            raise ProfileError(f"config_files[{index}].path: must stay under {{run}}/ or {{home}}/")


def _check_sections(data):
    _fields(data["output"], OUTPUT, "output")
    if data["output"]["format"] not in ("text", "json"):
        raise ProfileError("output.format: text or json")
    if data["output"]["format"] == "json" and not data["output"].get("text_path"):
        raise ProfileError("output.text_path: required for json")
    _fields(data["tool_trace"], TOOL_TRACE, "tool_trace")
    _fields(data["env"], ENV, "env")
    env = data["env"]
    if env["home"] not in ("synthetic", "real") or env["xdg_data_home"] not in ("owner", "synthetic"):
        raise ProfileError("env.home: synthetic|real; env.xdg_data_home: owner|synthetic")
    names = list(env["pass"]) + list(env["secret_env"])
    if any(not ENV_NAME_RE.fullmatch(name) or name in BUILT_ENV for name in names):
        raise ProfileError("env: pass/secret_env names must be plain and not one the wrapper sets")
    if not all(isinstance(path, str) for path in env["secret_env"].values()):
        raise ProfileError("env.secret_env: values are file paths")
    if set(data["failure_patterns"]) - set(PATTERN_CLASSES):
        raise ProfileError("failure_patterns: unknown class")
    if any(not code.isdigit() or cls not in CLASSES for code, cls in data["exit_codes"].items()):
        raise ProfileError("exit_codes: '<code>': <class>")


class Profile:
    """A validated profile: ``profile["key"]`` reads its data; regexes are compiled once."""

    def __init__(self, data: dict, path: str):
        _fields(data, TOP, "profile")
        _check_prompt_and_files(data)
        _check_sections(data)
        if not data["model_flag"].startswith("-"):
            raise ProfileError("model_flag: must be a flag")
        self.data, self.path, self.name = data, path, data["name"]
        self.model_re = _regex(data["model_pattern"], "model_pattern")
        self.patterns = [(cls, _regex(data["failure_patterns"][cls], f"failure_patterns.{cls}", re.IGNORECASE))
                         for cls in PATTERN_CLASSES if cls in data["failure_patterns"]]
        pattern = data["tool_trace"]["stdout_pattern"]
        self.stdout_re = _regex(pattern, "tool_trace.stdout_pattern") if pattern else None
        if data["tool_trace"]["hook_log"]:
            if "{hook}" not in json.dumps(data["config_files"]):
                raise ProfileError("tool_trace.hook_log: no config file runs {hook}")
            if not os.access(HOOK, os.X_OK):
                raise ProfileError("deny-hook.sh: not executable")

    def __getitem__(self, key):
        return self.data[key]


def shipped_profiles() -> List[str]:
    """Return the names of the profiles under ``profiles/`` (sorted)."""
    names = [entry[:-5] for entry in os.listdir(PROFILE_DIR) if entry.endswith(".json")]
    return sorted(name for name in names if NAME_RE.fullmatch(name))


def load_profile(name: str) -> Profile:
    """Load and validate ``profiles/<name>.json``; raise ProfileError when it is unknown or invalid."""
    if not isinstance(name, str) or not NAME_RE.fullmatch(name) or name not in shipped_profiles():
        raise ProfileError("unknown profile")
    path = os.path.join(PROFILE_DIR, name + ".json")
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError) as error:
        raise ProfileError(f"{name}: unreadable ({type(error).__name__})") from None
    profile = Profile(data, path)
    if profile.name != name:
        raise ProfileError(f"{name}: name differs from the file name")
    return profile
