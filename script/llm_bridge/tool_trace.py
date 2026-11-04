"""Tool-use detection for the agent-CLI wrapper (graph_mem ``script/llm_bridge/``, agent-CLI train PR3).

``tool_use`` decides whether a finished run used a tool, from evidence the model can't write: the deny
hook's lines in ``hook.log`` (written outside the run dir, filtered by run id), the exported transcript,
the turn count and the stdout pattern. Python 3.9+ standard library only; part of the gate's
``wrapper_digest``.
"""

from __future__ import annotations

import collections
import json
import os
from typing import List, Optional

TOOL_KEYS = ("tool_calls", "tool_call", "tool_use", "function_call")
NAME_KEYS = ("function_name", "name", "tool_name")


def _call_name(call) -> str:
    """A tool call's name, lower-cased; ``"?"`` when it has none (which fails closed)."""
    if isinstance(call, dict):
        for key in NAME_KEYS:
            if isinstance(call.get(key), str) and call[key]:
                return call[key].lower()
        function = call.get("function")
        if isinstance(function, dict) and isinstance(function.get("name"), str) and function["name"]:
            return function["name"].lower()
    return "?"


def tool_names(node) -> List[str]:
    """Every tool call in a transcript node, by name; a doubtful node may count twice (more calls fails closed)."""
    if isinstance(node, list):
        return [name for item in node for name in tool_names(item)]
    if not isinstance(node, dict):
        return []
    found = [_call_name(node)] if node.get("type") in TOOL_KEYS else []
    for key in TOOL_KEYS:
        value = node.get(key)
        if value:
            found += [_call_name(item) for item in (value if isinstance(value, list) else [value])]
    return found + [name for value in node.values() for name in tool_names(value)]


def transcript_tool_names(text: Optional[str], exit_code) -> Optional[List[str]]:
    """The tool calls in an exported transcript (JSON or JSON lines); None when it is unreadable (fail closed),
    or missing although the run succeeded (a failed run may have stopped before writing one: none)."""
    if text is None:
        return None if exit_code == 0 else []
    try:
        try:
            docs = [json.loads(text)]
        except ValueError:
            docs = [json.loads(line) for line in text.splitlines() if line.strip()]
        return tool_names(docs)
    except (ValueError, RecursionError):  # unreadable or too deep to walk
        return None


def hook_lines(state: str, offset: int, run_id: str) -> List[str]:
    """The ``hook.log`` lines written for ``run_id`` after byte ``offset``."""
    try:
        with open(os.path.join(state, "hook.log"), "rb") as handle:
            handle.seek(offset)
            tail = handle.read().decode("utf-8", "replace")
    except OSError:
        return []
    return [line for line in tail.splitlines() if ("\t%s\t" % run_id) in line]


def file_size(path: str) -> int:
    """A file's size, or 0 when it doesn't exist (the ``hook.log`` offset before a run)."""
    return os.path.getsize(path) if os.path.isfile(path) else 0


def _refused(lines: List[str]) -> collections.Counter:
    return collections.Counter((line.split("\t") + ["", "", "?"])[2].lower() or "?" for line in lines)


def tool_use(profile, proc: dict, envelope: dict, lines: List[str], transcript: Optional[str], stdout: str):
    """``"used"`` (cli_tool_use), ``"denied"`` (cli_tool_denied) or None.

    Too many turns, the stdout pattern or an unreadable transcript is use. Otherwise any hook line or
    transcript tool call is use, except on a profile whose tools are denied rather than removed
    (``tools_fully_disabled: false``, hook wired): there, when every named call in the transcript has its
    own refusal by the same name in ``hook.log``, each was refused. An unnamed call is use.
    """
    trace, turns = profile["tool_trace"], envelope["turns"]
    if (trace["max_turns"] is not None and isinstance(turns, int) and turns > trace["max_turns"]) or \
            (profile.stdout_re and profile.stdout_re.search(stdout)):
        return "used"
    names = transcript_tool_names(transcript, proc["exit"]) if trace["export_path"] else []
    if names is None:
        return "used"
    if not names and not lines:
        return None
    calls = collections.Counter(names)
    hooked = not profile["tools_fully_disabled"] and trace["hook_log"] and "?" not in calls and not (calls - _refused(lines))
    return "denied" if hooked else "used"
