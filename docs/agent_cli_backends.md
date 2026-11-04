# Agent-CLI backends (opt-in cloud models through your workstation's CLI)

graph_mem normally sends every summary, scan part and fact-supersede judgement to a local Ollama (or an
OpenAI-compatible server). Since 1.71.0 an operator can also route a task to an **agent CLI** (Claude Code
as `claude`, Devin as `devin`) running on their own workstation, behind a small loopback HTTP bridge, with
the data anonymized first and only for projects that allow it. Nothing changes until you configure it: every
chain is `ollama` by default.

How it works in one line: the app masks the prompt (`Llm::CloudCall`), POSTs it to the bridge on
`127.0.0.1`, the bridge runs the CLI with its tools, MCP servers and config files switched off, and the app
restores the answer. Details: [`docs/summarization.md`](summarization.md) ("LLM providers", "Anonymization
and cloud access") and [`script/llm_bridge/README.md`](../script/llm_bridge/README.md).

## 1. What must already exist

**A supported CLI is already installed and logged in on the workstation, under the user that runs the
bridge.** graph_mem never installs a CLI, never logs in, and never stores the CLI's credential. If the CLI
can't answer `claude -p "hi"` (or `devin -p "hi"`) for that user in an empty folder, nothing below will work.

## 2. Setup per profile (`claude`, `devin`)

1. **Install** the CLI as its vendor documents, as the user who will run the bridge (`<user>`). Turn on the
   vendor's data-sharing opt-out where one exists.
2. **Headless login:**
   - `claude`: create a long-lived token with `claude setup-token` and save it as
     `~/.local/state/agent-cli/claude.token`, mode 0600. The bridge passes it to each run, in an empty,
     synthetic home.
   - `devin`: log in once as usual; the bridge uses the login in your data dir (`~/.local/share`).
3. **Verify** in an empty dir: `cd "$(mktemp -d)" && claude -p "Reply with ok"` (or `devin -p …`).
4. **The bridge:** `python3 /path/to/graph_mem/script/llm_bridge/bridge.py init-token` (writes
   `~/.local/state/agent-cli/bridge.token`, 0600), then `python3 /path/to/graph_mem/script/llm_bridge/bridge.py serve`,
   or as a systemd **user** unit from `script/llm_bridge/llm-bridge.service.example` (edit `/path/to/graph_mem`;
   `systemctl --user enable --now llm-bridge`).
5. **`AGENT_CLI_<NAME>_PATH`** (`AGENT_CLI_CLAUDE_PATH`, `AGENT_CLI_DEVIN_PATH`) only when the CLI isn't on
   the bridge's `PATH`. (The old `DEVIN_CLI_PATH` is replaced by `AGENT_CLI_DEVIN_PATH`.)
6. **The lockdown gate, per profile:** `sh /path/to/graph_mem/script/llm_bridge/lockdown_test.sh --profile claude --models <model>[,<model>…]`
   (and again for `devin`). The bridge serves a profile only while its gate says PASS for the CLI binary,
   version and wrapper it finds now, and only for the models the gate tested. **Re-run it after every CLI
   update** and after upgrading graph_mem; until then that profile answers "gate stale" and its calls fall
   back.

## 3. The app side

- `LLM_BRIDGE_URL=http://127.0.0.1:<port>` (default port 8765). Only the literal `127.0.0.1` is accepted.
  The shipped `docker-compose.yml` uses host networking, so the container reaches the host's loopback.
- `LLM_BRIDGE_TOKEN_FILE`: the bridge's token, in a file owned by the app's own user, mode 0600. In the
  container (uid 1000), mount a read-only **copy owned by uid 1000** (or the bridge's own file when `<user>`
  is uid 1000). There is no token environment variable.
- Check it: **System › Settings › Summaries › Host bridge › Check now**, or `bin/rails llm:bridge_probe`. It
  shows whether the bridge answers, each profile's gate and tripped state, and each chain's configured
  models, flagging any the gate didn't test. It never shows a path or the token.

## 4. Enabling one task for one project

1. **Projects page → Cloud → Allow** for that project. The confirm names the folder its cloud scans must
   come from (the realpath of its last completed scan). Projects you don't allow never leave the machine.
2. **Settings › Summaries:**
   - each profile's **model** (one its gate tested) and up to three **backup models** (tried when a model is
     unavailable, over quota, rate limited, needs payment, or untested);
   - the task's **chain**, for example scan = `claude,ollama` (Ollama stays the last fallback) or
     `claude,devin,ollama`;
   - **a budget** for that task: cloud calls per day and estimated tokens per day. `0` means no limit, so set
     one. Over it, the task goes to the next chain entry (Ollama if listed) until the next calendar day.
3. Summaries run inside requests (the `summarize` tool and `POST /api/v1/summaries`), so they use the bridge
   only if you also set **Requests that may use the host bridge** to `summary`. Then each request makes one
   attempt, primary model only, and waits at most the configured seconds (20 by default, 5 to 60).
   `detect_contradictions` never waits on the bridge.
4. Watch **LLM usage** on the same page: calls, errors, fallbacks, refusals and estimated tokens per task and
   provider, today and the previous day, and each budget's remainder.

Only one cloud-using job (a scan or a fact-supersede run whose chain is cloud) runs at a time; the others
wait their turn. A chain change applies to jobs enqueued after it.

## 5. What leaves the machine, and what is logged

- **Sent to the CLI's vendor:** the masked prompt. Names of projects and their members, people, paths,
  hosts, URLs, e-mails and IPs become tokens like `⟦PRJ_3f9a⟧`, and secrets become `⟦SECRET⟧`. What the
  anonymizer can't hide (code structure, domain vocabulary, numbers, a name fused with other letters, …) is
  listed in [`docs/summarization.md`](summarization.md) under "What still leaks". This is pseudonymization,
  not anonymity: allow Cloud only for projects whose remaining text you are willing to share.
- **Logged:** one `[llm]` line per attempt with sizes, estimated tokens, latency, outcome, profile, model and
  fallback step, and the usage counters. Never the prompt, the answer, a name, a path or the token.

## 6. Turning it off

- **Instantly:** set the chains back to `ollama` (Settings › Summaries). The next call uses Ollama.
- **Everything at once:** stop the bridge (`systemctl --user stop llm-bridge`). Every cloud attempt then fails
  as unreachable and falls back to Ollama where the chain lists it.
- Per project: turn **Cloud** off on the Projects page.

## 7. Not supported

- Running a CLI inside the graph_mem container, or bind-mounting the host's CLI into it (the credential would
  be in the image, the uid wouldn't match, and an auto-update would swap the binary under the gate). The host
  bridge is the supported deployment.
- Embeddings: they stay on Ollama (fixed vector dimensions, called on every write).
- Per-model prices or costs in money: the usage card shows estimated tokens only (a lower bound; the CLI's
  own overhead is invisible).
