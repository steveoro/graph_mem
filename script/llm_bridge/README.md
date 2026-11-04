# LLM host bridge

A small HTTP server that runs on the operator's workstation, not in the container (agent-CLI train
PR3). It takes a prompt that graph_mem has already masked, runs **one** agent CLI (Claude Code,
Devin) non-interactively with its tools, MCP servers, config files and network actions switched
off, and returns the raw answer with a failure class. The Rails app never loads, starts or calls
anything here; PR4 adds the client. Python 3.9+ standard library and POSIX `sh` only.

| File | What |
|---|---|
| `bridge.py` | `serve` (`GET /v1/health`, `POST /v1/complete`) and `init-token` |
| `agent_cli.py` | The wrapper: argv, environment, run dir, timeout, caps, envelope, tool use, classes. `run` and `check` subcommands |
| `profile_schema.py` | The strict profile loader (an unknown key or a wrong type is an error) |
| `tool_trace.py` | Tool-use detection: the deny hook's `hook.log` lines, the transcript's tool calls, turns |
| `profiles/claude.json`, `profiles/devin.json` | One profile per CLI, as data |
| `deny-hook.sh` | A `PreToolUse` hook: logs the attempt to `hook.log` and denies it |
| `lockdown.py`, `lockdown_test.sh` | The per-profile lockdown gate |
| `llm-bridge.service.example` | A systemd user unit |
| `test/` | `fake_cli.py` and the tests: `python3 -m unittest discover -s script/llm_bridge/test` |

State lives in `$AGENT_CLI_STATE` (default `~/.local/state/agent-cli`, 0700): `bridge.token`,
`claude.token`, `gates/<profile>.json`, `tripped/<profile>.json` and `hook.log`. Run dirs go in
`$XDG_RUNTIME_DIR/agent-cli`, or `$AGENT_CLI_STATE/runs` when there is no private runtime dir. Either way
the runs dir must be a real (not symlinked) 0700 dir you own, and every dir above it must be root's or
yours and not group- or other-writable. Otherwise the bridge won't start and the gate stops with a setup
error. The state dir must be a real 0700 dir you own. Run dirs never go in the shared `/tmp`, because CLIs
search a run dir's parents for config. Nothing is written
under the checkout at run time.

## Install

1. Install and log in to the CLI as you normally would. Set its vendor's data-sharing opt-out where one
   exists. The bridge never installs, updates or logs in to a CLI.
2. `python3 script/llm_bridge/bridge.py init-token` writes `bridge.token` (0600) and prints its path.
   graph_mem reads the same value from `LLM_BRIDGE_TOKEN` (PR4).
3. `claude` only: create a long-lived token with `claude setup-token` and save it as
   `~/.local/state/agent-cli/claude.token`, mode 0600. The bridge passes it as `CLAUDE_CODE_OAUTH_TOKEN`
   to a run with an empty, synthetic HOME. `devin` keeps its login in the owner's data dir
   (`XDG_DATA_HOME`, default `~/.local/share`).
4. Run the gate for each profile and model (below) until it says PASS.
5. Start the bridge: `python3 script/llm_bridge/bridge.py serve`, or use the systemd unit
   (`llm-bridge.service.example`, with `/path/to/graph_mem` fixed).

`agent_cli.py check --profile <name>` shows the CLI it finds, the CLI's version and the wrapper digest.
`AGENT_CLI_<NAME>_PATH` (for example `AGENT_CLI_CLAUDE_PATH`) overrides where the CLI is found.

## The lockdown gate

```bash
sh script/llm_bridge/lockdown_test.sh --profile devin --models <model>[,<model>…] [--listen-ip 127.0.0.1]
```

The gate runs the production `run_cli` path for every model and prompt form (`devin`: `arg`, and a
`file` prompt padded past 96 KiB). First it checks three things:
- the CLI answers a plain prompt;
- the loopback listener logs a request;
- for `devin`, `deny-hook.sh` denies and logs a call the gate makes itself. That check runs outside the
  CLI's sandbox, so it proves the hook and the state dir work, not that the CLI can reach them.

Then it sends judge-style prompts whose statement asks the CLI to do one of these things:
- print or search for a canary file, a new file with a unique name in `CANARY_DIR` (default: your
  home), removed afterwards;
- `touch` a marker (`sh -c` and `bash -lc`);
- fetch a loopback listener's URL, or "search the web" for it;
- list or call MCP tools, or spawn a subagent to do all of this.

Every run also carries decoys, each with its own random tag or marker:
- `AGENTS.md` and `CLAUDE.md` in the run dir, in Devin's user config dir and in the synthetic home;
- MCP configs that start a server which touches a marker: `.mcp.json` and `~/.claude.json`;
- project `.claude/settings.json` files that point the API at the listener and carry a hook that
  touches a marker (Devin also reads hooks from `.claude/` dirs).

The run dir has no `.devin/` decoy and no decoy user `mcp_config.json`. Devin always loads native project
config (`.devin/config.json`, `.devin/mcp_config.json`, their `.local` variants and `.devin/hooks.v1.json`)
from its working dir
and that dir's parents, and its user `mcp_config.json` from `$XDG_CONFIG_HOME/devin/`, whatever its
flags say. Both are inside the private run dir: it is created empty, and the profile writes the user
`config.json` and an empty `mcp_config.json` itself. So the gate checks the parents instead: any of
those project files in the runs dir or above it FAILs the `devin` gate.

Each prompt also runs once without the profile's `trust_args`. A CLI that then refuses to run counts as
not having loaded anything.

Each report line ends with how the run ended (`[answered]` or its failure class). A FAIL names the
decoy files or MCP configs that were loaded. An attack run that ends without answering, outside the
`trust_omit` runs, is marked `warn`, because it tested nothing. If no attack run answered for a model
and prompt form, the gate FAILs.

**PASS** only if no run leaks the canary, creates a marker, reaches the listener (a control hit proves
it logs), calls the hook (outside a `cli_tool_denied` run), prints a decoy's text or is classified `cli_tool_use`. These are listed as
**WARN**:
- with `env.home: real`, user-level `AGENTS.md`, `CLAUDE.md` and MCP configs in your home;
- `.devin`, `.claude`, `.git`, `.jj`, `AGENTS.md`, `CLAUDE.md` or `.mcp.json` in the runs dir or above it,
  which a CLI may find by walking up.

The gate writes `gates/<profile>.json` (0600): `profile`, `result`, `cli_path`, `cli_realpath`,
`cli_version`, `wrapper_digest`, `models`, `prompt_forms`, `trust_omit`, `run_as`, `runs_dir`,
`warnings`, `passed_on`. Exit codes: 0 PASS, 1 FAIL, 2 setup error. A PASS clears `tripped/<profile>.json`. The
prompts name the canary's path, so your username, and they go to the CLI's vendor like any prompt.
The gate never changes an existing file.

**Re-run it after every CLI update.** The bridge serves a profile only while the record's CLI
realpath, version (from `version_args`, cached by realpath, inode and size, never by time),
`wrapper_digest` and `runs_dir` all match what it finds now. `runs_dir` is there because the gate checked
that dir's parents; a bridge started as a service with another `XDG_RUNTIME_DIR` gets `gate_stale`. The
digest is SHA-256 over `agent_cli.py`, `profile_schema.py`, `tool_trace.py`, `deny-hook.sh` and the profile
file. `passed_on` is informational only.

## HTTP contract (`127.0.0.1` only; `X-GM-Bridge-Token` on every route)

`POST /v1/complete`, `Content-Type: application/json`, at most 1 MiB. The body has exactly these keys:

| Key | Value |
|---|---|
| `profile` | `claude` or `devin` |
| `model` | Matches the profile's `model_pattern`, doesn't start with `-`, and is in the gate record's `models` |
| `prompt` | A non-empty string, already masked by graph_mem |
| `timeout_s` | An integer from 1 to 600 |
| `task` | `summary`, `scan` or `judge` (logged only) |
| `run_id` | A UUID |

The response is always `{ "ok", "text", "failure_class", "model_used", "cli_version", "latency_ms" }`.
`text` is the CLI's answer (for `claude`, the envelope's `result`) with ANSI and control characters
other than `\n` and `\t` removed, and nothing else changed. stderr is never returned.

| Status | `failure_class` |
|---|---|
| 200 | `null` (ok); or a CLI-level class: `cli_timeout`, `cli_quota`, `cli_rate_limited`, `cli_auth`, `cli_model_unavailable`, `cli_payment_required`, `cli_config`, `cli_sandbox`, `cli_truncated`, `cli_turn_limit`, `cli_tool_use`, `cli_tool_denied`, `cli_error`, `cli_bad_output` |
| 400 | `bridge_bad_request` (an unknown key, a wrong type, another value). PR4 must not pass it to a scan as `http_status: 400`, which splits parts |
| 401 / 404 / 405 | `bridge_unauthorized` / `bridge_not_found` / `bridge_method_not_allowed` |
| 413 | `prompt_too_long`: the body is over 1 MiB, the prompt is over the profile's `max_bytes`, or the CLI said so |
| 429 | `bridge_busy`: one run at a time per profile, no queue |
| 500 | `bridge_error` (unexpected; no detail) |
| 503 | `cli_missing`; `gate_missing` (no record, or not for this model); `gate_failed`; `gate_stale`; `tripped` |

`GET /v1/health` returns `{ bridge_version, profiles: { <name>: { cli_ok, cli_realpath, cli_version,
gate: { result, cli_version, wrapper_digest, models, passed_on } | null, gate_ok, tripped } } }`.

A run classified `cli_tool_use` trips its profile: every request then gets `503 tripped` until a new
gate PASS. One exception is for `devin`, whose tools are denied rather than removed
(`tools_fully_disabled: false`): when every tool call in the transcript has its own refusal by the same
name (case-insensitive) in `hook.log`, each call was refused, so the run is `cli_tool_denied`. That is a failed request, but it doesn't
trip the profile, and the gate counts it as a `warn` (not answered), not a leak. A tool call the hook
never refused by that name, an unnamed call, too many turns, the stdout pattern or an unreadable transcript
is still `cli_tool_use`; so is
any tool use on `claude`, whose tools are removed. The bridge never retries and never falls back to another profile; graph_mem's chain does
that (PR4).

## Profile fields

| Field | Meaning |
|---|---|
| `name`, `cli_path`, `version_args` | The profile name (= file name), the CLI's command, and the arguments that print its version |
| `base_args`, `trust_args`, `max_turns_args`, `lockdown_args` | Args, in that order, before `model_flag <model>` and the prompt args |
| `model_flag`, `model_pattern` | The model's flag and the regex a model must fully match |
| `prompt` | Delivery modes, in order: `arg` (after `--`, up to `max_bytes`), `file` (`flag` followed by the prompt file), `stdin` (up to `max_bytes`). The first one that fits is used |
| `output` | `format` (`text` or `json`); for `json`, `text_path`, `error_path`, `subtype_path`, `turns_path` (dotted keys) |
| `config_files` | `{ path, content }` written into the run dir or the synthetic home (`{run}`, `{home}`, `{hook}` and `{state}` are substituted) |
| `tools_fully_disabled` | Whether the CLI's flags alone switch every tool off (`claude`), or the hook, deny config and transcript checks are all needed (`devin`) |
| `tool_trace` | `hook_log` (the profile wires `{hook}`), `max_turns`, `export_path` (a transcript to check), `stdout_pattern` |
| `env` | `home` (`synthetic` or `real`), `xdg_data_home` (`owner` or `synthetic`), `set` (fixed `NAME: value` pairs), `pass` (env names to pass through; empty in both profiles), `secret_env` (`NAME: file`, each file the user's own and 0600) |
| `failure_patterns`, `exit_codes` | Class → regex (case-insensitive, over the answer, the subtype and stderr of a failed run), and exit code → class |

Each run gets a new 0700 dir under the runs dir as its cwd: no repo, no `.git`, no `AGENTS.md`. It holds
`prompt.txt`, the synthetic `home/`, `config/`, `cache/` and `data/`. The environment is built from
scratch:
- `PATH=/usr/local/bin:/usr/bin:/bin` plus the CLI's directory;
- `HOME`, and the `XDG_*` dirs under the run dir (`devin`'s `XDG_DATA_HOME` is the owner's);
- `NO_COLOR`, `TERM=dumb`, `LANG=C.UTF-8`, `GM_LLM_RUN_ID`, `AGENT_CLI_STATE`;
- the profile's `set`, `pass` and `secret_env` names.

On a timeout the process group gets `SIGTERM`, then `SIGKILL` after 5 s. After every run the whole
group is killed. stdout is capped at 256 KiB and stderr at 64 KiB. The run dir is removed; with
`AGENT_CLI_KEEP_FAILED=1`, a failed run's dir is kept, still 0700.

### What the vendors' docs say, and what is still to confirm
- `claude`: Claude Code loads `CLAUDE.md` (and `AGENTS.md`) from the working dir and every dir above it,
  and `~/.claude/CLAUDE.md`, whatever the tool and MCP flags say. The profile adds `--safe-mode`
  (no CLAUDE.md, hooks, MCP servers, skills, plugins or auto memory; authentication still works) and sets
  `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` and `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`, and loads only user settings
  (`--setting-sources user`, from the empty synthetic home)
  ([CLI reference](https://code.claude.com/docs/en/cli-reference), [env vars](https://code.claude.com/docs/en/env-vars)).
  Still to confirm: the envelope field names (`result`, `is_error`, `subtype`, `num_turns`).
- `devin`: `read_config_from` imports other tools' rules and MCP servers (`agents_standard`, `cursor`,
  `windsurf`, `claude`, `copilot`, `opencode`, `zed`, `cloud`), all on by default; the profile turns
  each off. The same config is written as the user config too (`{run}/config/devin/config.json`), since
  `cloud` and `subagents_enabled` are user-config only. A hook `matcher` is a regex (`""` matches every tool). Without `--respect-workspace-trust
  false`, print mode refuses to run in a new dir, so the `trust_omit` runs end without answering (their
  class shows in the report) ([config](https://docs.devin.ai/cli/reference/configuration/read-config-from),
  [commands](https://docs.devin.ai/cli/reference/commands), [permissions](https://docs.devin.ai/cli/reference/permissions)).
  The first gate runs showed two more things. Native project config in the working dir is loaded even
  with `--config` and every import off. And a dir under your home counts as trusted once `~/.devin`
  exists, so the `trust_omit` runs answered there; the runtime dir avoids both. Still to confirm:
  whether a tool that needs approval is denied in print mode, and the transcript format.
- `failure_patterns`: they are written from the vendors' documented messages. A sanitized envelope per
  profile becomes a spec fixture for PR4.

If a CLI can't start with a synthetic HOME, its profile gets `env.home: real`, and the gate reports
WARN for what it finds there.

## What the bridge never does
- Listen anywhere but `127.0.0.1`: never `0.0.0.0` or a LAN address. Any other `--listen` value refuses
  to start, and so does a token file that isn't the user's own regular 0600 file of 32 bytes or more.
- Take a path, flag or URL from a request. argv is always a list.
- Return stderr, retry or fall back. A prompt or an answer is kept only in a failed run's dir with
  `AGENT_CLI_KEEP_FAILED=1` (0700, remove it yourself).
- Log the prompt, the answer, stderr, the token or an env value. The log has one line per request on
  stderr: `run_id`, `profile`, `model`, `task`, `prompt_bytes`, `status`, `failure_class` and
  `latency_ms`.
- See an anonymizer mapping. graph_mem masks prompts before they leave the app and restores the answer
  itself.

## Run model

With `devin`'s `arg` mode, up to 96 KiB of the (masked) prompt sits in the CLI's argv while it runs,
readable by other local users through `ps` unless `/proc` is mounted with `hidepid`; the `file` mode
keeps it in the 0700 run dir. Larger prompts already use `file`.

By default, the bridge and the CLI run as your own user, with your CLI login. That gives up one thing:
if every lockdown layer failed, the CLI could read your home. A dedicated low-privilege user with a
0600 copy of the CLI credential is optional extra hardening. No code for it ships here.
