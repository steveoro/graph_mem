<img src="../app/assets/images/logo.svg" alt="GraphMem logo" width="64" height="64" align="right">

# Quick setup: graph_mem on a new workstation

The shortest path from nothing to a running graph_mem container, plus the skill and the rule
for Claude Code, Cursor and Devin Desktop. Everything else in `docs/` is optional reading.

**You need:** Docker with Compose, git, and [Ollama](https://ollama.com). Linux is the tested
host: the app container uses host networking.

## 1. Clone and configure

```bash
git clone https://github.com/steveoro/graph_mem.git ~/Projects/graph_mem
cd ~/Projects/graph_mem
cp .env.example .env
ollama pull nomic-embed-text
```

Edit `.env` and set:

| Variable | Value |
|---|---|
| `DB_PASSWORD` | Any password for the MariaDB container. |
| `OPERATOR_PASSWORD` | Your password for the web UI. Add the line: the operator login stays disabled while the password is the default `changeme`. |
| `DB_BACKUP_HOST_PATH` | An existing folder for database backups, e.g. `/home/<you>/backups/graph_mem`. |
| `SECRET_KEY_BASE` | Optional: your own key, from `openssl rand -hex 64`. Without it, graph_mem generates one on first boot and keeps it in the `storage` volume. |

Leave everything else as it is. You need no master key: the app needs only a `secret_key_base`,
and the operator login comes from `.env`. You need no `config/database.yml` either: the image uses
`config/database.example.yml` when there is none. The container gets its main database URL from
`.env`, and the cache, queue and cable databases are SQLite files in the `storage` volume. To edit
the file, copy it first (`cp config/database.example.yml config/database.yml`, git-ignored).

## 2. Optional: your own Rails credentials

Skip this step unless you want settings in an encrypted `config/credentials.yml.enc` (for example
`operator.password` instead of `OPERATOR_PASSWORD`). Every developer makes their own key and file;
nobody shares one, and both are git-ignored. Build the image, then let Rails create them inside it
(no Ruby needed on the host):

```bash
docker compose build app
docker run --rm --user "$(id -u):$(id -g)" --entrypoint "" -e RAILS_ENV=production -e EDITOR=true \
  -v "$PWD/config:/rails/config" graph_mem-app bin/rails credentials:edit
echo "RAILS_MASTER_KEY=$(cat config/master.key)" >> .env
```

`sh: git: not found` in the output is harmless. The credentials' `secret_key_base` is used from
then on, unless `.env` sets `SECRET_KEY_BASE`. Back up `config/master.key`: without it, your
credentials file can't be decrypted.

## 3. Start the container

```bash
bin/up --build                                         # docker compose up -d, plus LAN allowlist detection
docker compose exec app bin/rails db:seed              # first run only: canonical entity types
docker compose exec app bin/rails embeddings:check     # confirms Ollama answers
```

Check: `curl -s localhost:3030/up` returns a green page, and `http://localhost:3030` opens the
graph view. The database is created and migrated on startup.

**After a `git pull`:** `docker compose down && bin/up --build`.

## 4. Connect your agents to the MCP server

Give every agent its own `X-MCP-Client` value: graph_mem keeps one project context per value.

**Claude Code** (once, for all projects):

```bash
claude mcp add --transport http graph_mem http://localhost:3030/mcp \
  --header "X-MCP-Client: claude-code" --scope user
```

**Cursor:** add this to `~/.cursor/mcp.json` (all projects) or `.cursor/mcp.json` (one project):

```json
{
  "mcpServers": {
    "graph_mem": {
      "url": "http://localhost:3030/mcp",
      "headers": { "X-MCP-Client": "cursor" }
    }
  }
}
```

**Devin Desktop:** open its MCP settings, edit the raw config and add the same `graph_mem` block,
with `"X-MCP-Client": "devin"`. Refresh the tool list afterwards.

## 5. Install the skill, rule and hook once per machine

From the graph_mem repo, run:

```bash
bin/agent-install            # Claude Code, then Cursor; or --claude / --cursor for one
```

It only prints: the commands to copy the skill, the user-level rule and the SessionStart reminder
hook into `~/.claude/` (and `~/.cursor/` for Cursor), and the JSON to merge by hand into
`~/.claude/settings.json` and `~/.cursor/hooks.json`. It writes nothing; follow its output. Once done,
agents use graph_mem in **every** repository, whichever folder the session starts in.

- **The rule** (`docs/rules/graph_mem_user_rule.md`) goes to `~/.claude/rules/graph-mem.md`; in Cursor,
  paste it in Settings > Customize > Rules > User Rules.
- **The hook** (`script/agent_hooks/`) prints a short static reminder when the server answers on
  `http://localhost:3030/up`, and nothing otherwise. It's on by default; skip its steps to leave it out.
  If graph_mem runs elsewhere, pass `--url http://host:port`.
- **Optional, Claude Code:** `"alwaysLoad": true` on the `graph_mem` server entry loads its tool definitions
  at session start instead of on demand. It costs roughly 11,000 tokens of context per session, so try
  the rule and the hook first.

What a session sees, by where it starts (`<projects-dir>` is the parent folder of your repos):

| Text | Started in `<projects-dir>` | Started in `<projects-dir>/<repo>` |
|---|---|---|
| `~/.claude/rules/*.md`, the SessionStart hook's reminder | at launch | at launch |
| `~/.claude/skills/*` | listed | listed |
| `<projects-dir>/.claude/skills/*` | listed | not listed |
| `<projects-dir>/<repo>/CLAUDE.md` | once Claude reads or edits a file in the repo | at launch |
| graph_mem server instructions and tool names | at launch | at launch |

So for a session started in `<projects-dir>`, a per-project install arrives late (the repo's `CLAUDE.md`,
once Claude opens a file there) or not at all (the repo's `.claude/skills/`); the user-level files are
there from the start.

## 6. Or install per project (fallback)

For a teammate who doesn't install at user level, or an agent that reads only project files
(Devin Desktop), copy the skill into each project, from the project root:

```bash
GM=~/Projects/graph_mem
mkdir -p .agents/skills .claude/skills
cp -r "$GM/skills/graph-mem-mcp-toolset" .agents/skills/   # Cursor, Devin Desktop
cp -r "$GM/skills/graph-mem-mcp-toolset" .claude/skills/   # Claude Code
```

Copy the whole folder, `references/` included.

Optional: also copy `$GM/skills/project-scan` the same way. It scans a project into the graph,
and runs only when you ask for it.

Then add the rule, ten lines telling the agent when to use the skill: append it to the project's
`AGENTS.md`, which Cursor and Devin Desktop read:

```bash
printf '\n' >> AGENTS.md && cat "$GM/docs/rules/graph_mem_mcp_rules.md" >> AGENTS.md
```

**Claude Code** reads `AGENTS.md` only when the project has no `CLAUDE.md`. If there is one,
make its first line `@AGENTS.md`:

```bash
[ -f CLAUDE.md ] && ! grep -qx '@AGENTS.md' CLAUDE.md && sed -i '1i @AGENTS.md\n' CLAUDE.md
```

Don't also put the rule in `.cursor/rules/` or `.devin/rules/`: an agent that reads both loads it twice.

## 7. Try it

Start a new agent session in the project and ask: *"call graph_mem get_context"*. A reply with
a context status means the agent is connected. The first time in a project, ask it to set the
context to that project (it creates the Project entity if needed).

## When something goes wrong

| Symptom | Fix |
|---|---|
| App container keeps restarting; `docker compose logs app` says ``The `cable` database is not configured`` (an image built from an older checkout) or `config/database.yml is missing` | `cp config/database.example.yml config/database.yml`, then `docker compose down && bin/up --build`. |
| App container keeps restarting; `docker compose logs app` says `RAILS_MASTER_KEY doesn't match config/credentials.yml.enc` | The key in `.env` didn't encrypt that file. Fix the key, or remove `RAILS_MASTER_KEY` from `.env` and delete `config/credentials.yml.enc` to boot without credentials. Then `docker compose down && bin/up --build`. |
| App container keeps restarting; `docker compose logs app` says `RAILS_MASTER_KEY is set but config/credentials.yml.enc is missing` | The file is no longer tracked, so a `git pull` removed it: copy your backup back into `config/`, or remove `RAILS_MASTER_KEY` from `.env`. Then `docker compose down && bin/up --build`. |
| Operator login returns 503 | Set `OPERATOR_PASSWORD` in `.env`, then `docker compose down && bin/up`. |
| `embeddings:check` fails | Ollama isn't running, or `nomic-embed-text` isn't pulled. |
| Agent gets 403 from `/mcp` | It connects from another machine or through a host name not on the allowlist: see [MCP access control](mcp_access_control.md). |
| Agent doesn't list graph_mem tools | Restart the agent or refresh its MCP tools; check the URL ends in `/mcp`. |

More: [troubleshooting](troubleshooting.md), [agent rules and skills](rules/README.md),
[MCP tools](mcp_tools.md), [README](../README.md) (full configuration).
