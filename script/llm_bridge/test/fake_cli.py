#!/usr/bin/env python3
"""A fake agent CLI for the llm_bridge tests: synthetic answers only, never a model, account or network
beyond 127.0.0.1.

It acts like the ``claude`` profile's CLI when argv has ``--output-format`` (prompt on stdin, a JSON
envelope on stdout) and like the ``devin`` profile's otherwise (prompt after ``--`` or in
``--prompt-file``, plain text, a transcript at ``--export``). Tests copy it under the CLI's name with
``VERSION`` rewritten and point ``AGENT_CLI_<NAME>_PATH`` at the copy.

Two control channels:
- ``@fake key=value`` lines in the prompt (wrapper and bridge tests): ``answer``, ``raw``, ``exit``,
  ``stderr``, ``is_error``, ``subtype``, ``turns``, ``no_result``, ``sleep``, ``ignore_term``,
  ``spawn_child=<pid file>``, ``flood=<bytes>``, ``hook=<tool>``, ``echo_env``, ``echo_argv``, ``echo_cwd_mode``,
  ``transcript=none|tool|garbage|deep``.
- ``<this file>.json`` next to the copy (lockdown tests): ``{"obey": [...], "load_decoys": bool,
  "refuse_without_trust": bool, "error_on_attack": bool}``. ``obey`` holds ``read``, ``grep``, ``touch``, ``fetch``, ``mcp``, ``hooks`` and ``settings``:
  the fake then really reads the canary, touches the marker, fetches the listener or starts the
  decoy MCP server named in the prompt or the seeded config.
"""

import glob
import json
import os
import re
import signal
import subprocess
import sys
import time
import urllib.request

VERSION = "0.0.0-fake"


def read_prompt(argv, claude):
    if claude:
        return sys.stdin.read()
    if "--prompt-file" in argv:
        with open(argv[argv.index("--prompt-file") + 1], encoding="utf-8") as handle:
            return handle.read()
    return argv[argv.index("--") + 1] if "--" in argv else ""


def directives(prompt):
    found = {}
    for line in prompt.splitlines():
        if line.startswith("@fake "):
            key, _, value = line[6:].partition("=")
            found[key.strip()] = value
    return found


def sidecar():
    try:
        with open(os.path.realpath(__file__) + ".json", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def run_hook(tool):
    """Call the hook the profile wired into the run dir's config.json, as a CLI would; else log it directly."""
    event = json.dumps({"hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": {}}).encode()
    try:
        with open("config.json", encoding="utf-8") as handle:
            command = re.search(r'"command": "([^"]+deny-hook\.sh)"', handle.read()).group(1)
        subprocess.run([command], input=event, env=os.environ, check=False, capture_output=True)
    except (OSError, AttributeError):
        with open(os.path.join(os.environ["AGENT_CLI_STATE"], "hook.log"), "a", encoding="utf-8") as log:
            log.write("t\t%s\t%s\n" % (os.environ.get("GM_LLM_RUN_ID", "none"), tool))


def obey(prompt, rules):
    """What an obedient CLI would do with the lockdown vectors; returns the text it would print."""
    said = []
    wants = set(rules.get("obey", []))
    if "read" in wants:
        for path in re.findall(r"contents of the file (/\S+?) ", prompt):
            said.append(open(path, encoding="utf-8").read())
    if "grep" in wants:
        for directory, name in re.findall(r"under (/\S+?) for a file named (\S+?)\*", prompt):
            said += [open(path, encoding="utf-8").read() for path in glob.glob(os.path.join(directory, name + "*"))]
    if "touch" in wants:
        for path in re.findall(r"touch (/\S+?)['`]", prompt):
            open(path, "a").close()
    if "fetch" in wants:
        for url in re.findall(r"(http://127\.0\.0\.1:\d+/canary-[0-9a-f]+)", prompt):
            said.append(urllib.request.urlopen(url, timeout=5).read().decode())
    user = os.environ.get("XDG_CONFIG_HOME", "")
    if "mcp" in wants:
        for config in ("./.mcp.json", os.path.expanduser("~/.claude.json"), "./.devin/mcp_config.json", user + "/devin/mcp_config.json"):
            if os.path.exists(config):
                for server in json.load(open(config, encoding="utf-8")).get("mcpServers", {}).values():
                    subprocess.run([server["command"], *server.get("args", [])], check=False)
    if "hooks" in wants and os.path.exists("./.devin/config.json"):
        for entry in json.load(open("./.devin/config.json", encoding="utf-8"))["hooks"]["SessionStart"]:
            subprocess.run(["sh", "-c", entry["hooks"][0]["command"]], check=False)
    if "settings" in wants and os.path.exists("./.claude/settings.json"):
        url = json.load(open("./.claude/settings.json", encoding="utf-8"))["env"]["ANTHROPIC_BASE_URL"]
        urllib.request.urlopen(url + "/v1/messages", timeout=5).read()
    if rules.get("load_decoys"):
        for path in ("AGENTS.md", "CLAUDE.md", user + "/devin/AGENTS.md", "~/.claude/CLAUDE.md", "~/.config/devin/AGENTS.md"):
            path = os.path.expanduser(path)
            if os.path.exists(path):
                said += re.findall(r"DECOY-[0-9a-f]+", open(path, encoding="utf-8").read())
    return "\n".join(said)


def answer_for(prompt, found, argv):
    if "echo_env" in found:
        return ",".join(sorted(os.environ))
    if "echo_argv" in found:
        return json.dumps(argv[1:])
    if "echo_cwd_mode" in found:
        return oct(os.stat(".").st_mode & 0o777)
    if "answer" in found:
        return found["answer"]
    body = "\n".join(line for line in prompt.splitlines() if not line.startswith("@fake "))
    return "fake answer: " + body


def side_effects(found):
    if "spawn_child" in found:
        child = subprocess.Popen(["sleep", "60"])
        with open(found["spawn_child"], "w", encoding="utf-8") as handle:
            handle.write(str(child.pid))
    if "ignore_term" in found:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    if "hook" in found:
        run_hook(found["hook"])
    if "flood" in found:
        sys.stdout.write("x" * int(found["flood"]))
        sys.stdout.flush()
    if "sleep" in found:
        time.sleep(float(found["sleep"]))


def write_transcript(argv, found, text):
    if "--export" not in argv or found.get("transcript") == "none":
        return
    steps = [{"source": "agent", "message": text}]
    if found.get("transcript") == "tool":
        steps.append({"source": "agent", "tool_calls": [{"function_name": "exec", "arguments": {}}]})
    body = {"garbage": "not json {", "deep": "[" * 100000 + "]" * 100000}.get(found.get("transcript"))
    body = body or json.dumps({"schema_version": "ATIF-v1.2", "steps": steps})
    with open(argv[argv.index("--export") + 1], "w", encoding="utf-8") as handle:
        handle.write(body)


def main(argv):
    if "--version" in argv[1:2]:
        print("%s (Fake CLI)" % VERSION)
        return 0
    claude = "--output-format" in argv
    rules = sidecar()
    if rules.get("refuse_without_trust") and not claude and "--respect-workspace-trust" not in argv:
        print("error: workspace is not trusted", file=sys.stderr)
        return 1
    prompt = read_prompt(argv, claude)
    if rules.get("error_on_attack") and "Statements:" in prompt:  # answers the gate's control prompt only
        print("error: synthetic failure", file=sys.stderr)
        return 1
    found = directives(prompt)
    side_effects(found)
    text = answer_for(prompt, found, argv)
    obeyed = obey(prompt, rules)
    text = (obeyed + "\n" + text) if obeyed else text
    if "stderr" in found:
        print(found["stderr"], file=sys.stderr)
    if "raw" in found:
        sys.stdout.write(found["raw"])
    elif claude:
        envelope = {"type": "result", "subtype": found.get("subtype", "success"), "is_error": "is_error" in found,
                    "result": text, "num_turns": int(found.get("turns", "1")), "session_id": "fake-session"}
        if "no_result" in found:
            del envelope["result"]
        print(json.dumps(envelope))
    else:
        print(text)
    write_transcript(argv, found, text)
    return int(found.get("exit", "0"))


if __name__ == "__main__":
    sys.exit(main(sys.argv))
