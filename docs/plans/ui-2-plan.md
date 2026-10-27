# UI-2 → graph_mem 1.58.3 + 1.59.0: editable MCP allowlists, `bin/up` LAN detection (UI-2a, 1.58.3), Home (UI-2b, 1.59.0)

**Written 2026-10-27 (Europe/Rome)** for Claude, from `main` at `2cf8dad` (1.58.2 tagged, #131 and #132 merged).
**Updated 2026-10-27 evening** with Steve's answers: Decision 3 (public ranges allowed with a token) and Decision 8
(UI-2a ships as **1.58.3**) changed; Decisions 4 and 6 kept.
Every file:line in "What the code looks like today" was checked against `2cf8dad`. If a line has moved, find the code
by the quoted text; if the code no longer matches the description, **stop and ask Steve** instead of improvising.
Only code was read while writing this plan. **No spec was run**: the PRs are checked by running the suite locally and
by CI (CircleCI: rspec, rubocop, brakeman; Actions: lint, scan_ruby, scan_js).

Context: this file expands `docs/plans/ui-dashboard-plan.md` §6 **"UI-2 [Claude]: Home → 1.59.0"** (and §2.2 Home)
and wins where the two differ. The Home scope there is unchanged and is carried as **UI-2b** below. Steve added two
items to UI-2 on Oct 27, and they are carried as **UI-2a**:

1. the MCP allowlists (`GRAPH_MEM_MCP_ALLOWED_IPS`, `GRAPH_MEM_MCP_ALLOWED_HOSTS`, `GRAPH_MEM_MCP_ALLOWED_ORIGINS`)
   become **runtime-editable, additive only**, on the operator settings page ("we'll show the ENV value as a disabled
   text prefix beside the editable part");
2. a host-side **`bin/up`** that detects the host's LAN address, subnet and host names and passes them as the
   allowlist defaults to `docker compose up -d` (Steve: "Fold the bin/up LAN auto-detect into the UI-2 plan").

It also records the **PR-B follow-up** from `docs/plans/mcp-sdk-1.8.2-plan.md`: a runtime source for the allowed
origins must call `Transports.reset!` (the transport reads the list once, when it is built; CORS reads it per
request). A1–A4 below do that.

## Brief

| | |
|---|---|
| **Branches / PRs** | **Two PRs**, UI-2b off `main` after UI-2a merges. **UI-2a** `claude/ui-2a-mcp-access`, title `MCP access: editable allowlists and bin/up LAN detection (1.58.3)`: steps A1–A6 + release **RA** (**1.58.3**, Decision 8). **UI-2b** `claude/ui-2-1.59.0`, title `Home (1.59.0)`: steps H1–H3 + release R. Steve merges and tags; never merge, tag, push tags or run `rake release`. |
| **Commits** | UI-2a: **A1** merged sources + refresh, **A2** validation, **A3** settings panel, **A4** specs, **A5** `bin/up`, **A6** docs, **RA** release 1.58.3. UI-2b: **H1** `HomeSnapshot`, **H2** page + partials, **H3** specs, **R** release. Review fixes go in new commits; no force-push after review starts. |
| **Scope** | UI-2a: no change to the ENV semantics of the three variables, to `McpAccessPolicy`'s invariant (never unauthenticated *and* public), to the gem's DNS-rebinding protection (stays on) or to `/api/*` CORS. No secret goes into the settings table (`GRAPH_MEM_MCP_TOKEN` stays ENV-only). UI-2b: exactly `ui-dashboard-plan.md` §2.2 and §6 UI-2. |
| **Data** | Synthetic fixtures only (documentation ranges `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`; `*.test`/`*.localhost` names; temp dirs and fake `ip`/`ifconfig`/`route`/`hostname` binaries on a temp `PATH` for `bin/up`). Never real data, real credentials, real host names or a production dump. |
| **Read first** | `CLAUDE.md`, `AGENTS.md`, `.devin/rules/*`, `ui-dashboard-plan.md` §0.1 (spec hygiene, test-DB truncate, done criteria), §2.2, §5.4; `docs/mcp_access_control.md`. |

## What the code looks like today (verified at `2cf8dad`)

- **Access policy.** `lib/graph_mem/mcp_access_policy.rb`: `UNRESTRICTED = %w[any all *]` (24), `LOOPBACK_RANGES`
  `127.0.0.0/8 ::1` (26), `PRIVATE_RANGES` `10/8 172.16/12 192.168/16 fc00::/7 fe80::/10` (27), `DEFAULT_RANGES` (28).
  `from_env(env:, logger:)` (36-39). `resolve_allowed_ips` (96-115): empty → defaults; a sentinel → `[]`
  (= unrestricted) with a token, else a warning and the defaults; otherwise `parse_ranges` (150-157, unparseable →
  warn + skip) then `narrow_to_defaults` (120-130) without a token; an empty result → defaults. **A custom list
  replaces `DEFAULT_RANGES`** (`docs/mcp_access_control.md:50-51`), so `192.168.0.0/24` alone drops loopback.
- **Policy memo.** `lib/graph_mem/official_mcp.rb:25-27` `access_policy` memoizes `McpAccessPolicy.from_env`;
  `reset!` (30-33) clears it **and** calls `Transports.reset!`. Used by `AccessGate`
  (`official_mcp/access_gate.rb:17`, `network_allowed?` at 18; it only runs for `Router.mcp_path?`, 14 and
  `router.rb:17-19`).
- **Second policy reader.** `app/controllers/concerns/api_authentication.rb:85` builds
  `GraphMem::McpAccessPolicy.from_env(logger: Rails.logger)` **per request** for the `/api/v1` bearer path. It doesn't
  go through `OfficialMcp.access_policy`, so a settings-backed list would not reach it unless it is switched over (A1).
- **Transport.** `lib/graph_mem/official_mcp/transports.rb`: `for(profile)` memoizes per profile (13-15); `reset!`
  (19-22) closes every transport, **sessions included**; `options` (28-36) passes
  `allowed_hosts: list(ENV["GRAPH_MEM_MCP_ALLOWED_HOSTS"])` (33) and `allowed_origins: allowed_origins` (34), read
  once per build; `allowed_origins` (44-46, the PR-B single source; its comment at 38-41 already says a runtime
  source must call `reset!`); `allowed_origin?` (52-56, `casecmp?`); `list` (64-66).
- **The gem** (`mcp` 1.8.2, `streamable_http_transport.rb`): `@allowed_hosts = (DEFAULT_LOOPBACK_HOSTS +
  Array(allowed_hosts)).map(&:downcase)` (248), loopback hosts `127.0.0.1 ::1 localhost` always accepted (370); an
  entry matches the bare host name (any port) or `host:port` (2432-2436); `@allowed_origins` downcased (249), compared
  exactly to the downcased `Origin` (2447). It exposes **no public session count**; `close` (479) tears every
  session down.
- **CORS.** `config/initializers/cors.rb:46-55`: `/mcp/*` origins Proc → `Transports.allowed_origin?(source)`, per
  request. `/api/*` blocks (8-44) are separate and stay untouched.
- **Boot.** `config/initializers/mcp.rb`: middleware `AccessGate`, `RequestContext`, `Router` (26-28);
  `after_initialize` calls `Transports.options` (32) and logs `access_policy.describe` (33); dev reloader
  `Transports.reset!` (37). Boot can run without a database (e.g. `assets:precompile` in the Dockerfile), so a DB read
  at boot must not raise.
- **Settings.** `app/models/app_settings.rb` (rails-settings-cached); uncached readers by raw SQL, e.g.
  `project_scan_subfolders_raw` (123-132, rescues to the default). `app/controllers/operator/settings_controller.rb`:
  `bulk_update` (15-86, per-tab validation blocks 19-53, generic write loop 60-72); `restore_backup` (112-119);
  `group_settings_by_category` (136-177). `app/views/operator/settings/index.html.haml:20-29` renders a bespoke
  partial per tab (`_project_scans_panel`, `_review_policies_panel`, …). Audit pattern for settings:
  `app/controllers/concerns/review_policy_settings.rb:35-44` (one `AuditLog` row per changed key, actor
  `Current.actor`). Puma runs **one process** (`config/puma.rb`: threads only, no `workers`; `config/deploy.yml:47`
  has `WEB_CONCURRENCY` commented out), so an in-process refresh reaches every `/mcp` request.
- **Compose.** `docker-compose.yml:21` `network_mode: host`; MCP env at 40-44 (`${GRAPH_MEM_MCP_ALLOWED_IPS:-}` etc.).
  `README.md:174` and `:186` start the stack with `docker compose up -d`. There is no `bin/up`.
- **`.env.example`.** `:35` is an **uncommented** `GRAPH_MEM_MCP_ALLOWED_IPS=127.0.0.0/8,::1,192.168.0.0/24` (anyone
  who copied the file has an override that drops the Docker bridge range and other private ranges); `:40`
  `# GRAPH_MEM_MCP_ALLOWED_HOSTS=192.168.0.10,graphmem.lan`; `:44` `# GRAPH_MEM_MCP_ALLOWED_ORIGINS=…`.
- **Docs.** `docs/mcp_access_control.md:40-51` (variables table, "explicit allowlist replaces these defaults");
  `docs/troubleshooting.md:27-38` ("`403` on Every Request (Host or Origin Check)"; the literal
  `Forbidden: Invalid Host header` text isn't there yet).
- **Specs.** `spec/lib/graph_mem/mcp_access_policy_spec.rb` (allowlist parsing, 76-118); `spec/requests/mcp_official_spec.rb`
  `with_env` (24-32, calls `OfficialMcp.reset!`), Host/Origin (185-204), "CORS preflight (rack-cors)" (308-359);
  `spec/requests/operator/settings_spec.rb`, `review_policy_settings_spec.rb`.
- **Home (UI-2b).** `PagesController#home` (`pages_controller.rb:6-21`, guest → `/search` at 7) reads
  `MaintenanceDashboardSnapshot`; `app/views/pages/home.html.haml` (44 lines) + 8 partials in
  `app/views/pages/dashboard/`. `EmbeddingStatusSnapshot`, `AgentContextsSnapshot`, `ReviewDigest` (UI-5),
  `OperationProgress`, `ScanRootPolicy.status` (`scan_root_policy.rb:107`) and change sets (UI-4a) all exist;
  `/review` exists (`routes.rb:113`). No `HomeSnapshot` and no `spec/services/home_snapshot_spec.rb` yet.

## UI-2a → 1.58.3: editable MCP allowlists and `bin/up`

### A1. One merged source per list, and the refresh
- New `lib/graph_mem/mcp_access_lists.rb` (`GraphMem::McpAccessLists`), the **only** place that knows both sources:
  - `KINDS = { ips: "GRAPH_MEM_MCP_ALLOWED_IPS", hosts: "GRAPH_MEM_MCP_ALLOWED_HOSTS", origins: "GRAPH_MEM_MCP_ALLOWED_ORIGINS" }`
    and the matching `AppSettings` keys `mcp_extra_allowed_ips`, `mcp_extra_allowed_hosts`, `mcp_extra_allowed_origins`.
  - `env_entries(kind)` (split as `Transports.list` does today), `extra_entries(kind)` (an **uncached** read of the
    stored value, like `project_scan_subfolders_raw`; rescue `StandardError` → `[]` and log once at warn, so boot
    without a DB and a missing table don't raise), `entries(kind)` = ENV entries + extras, de-duplicated
    case-insensitively, ENV first.
- `app/models/app_settings.rb`: the three `field … type: :string, default: ""` next to the other MCP-free fields, with
  a comment "Additive MCP allowlists (UI-2a); not secrets. ENV entries can't be removed here."
- `Transports.allowed_origins` (44-46) → `McpAccessLists.entries(:origins)`; new public `Transports.allowed_hosts` →
  `McpAccessLists.entries(:hosts)`, used by `options` (33). These two stay the single source for the transport and
  for CORS (`cors.rb:48` unchanged). Update the comment at 38-41 to name the settings source and A1's refresh.
- **IPs: additive on the effective ENV list.** `McpAccessPolicy` gets `extra_ips:` (`from_env(env:, logger:,
  extra_ips: [])`, `initialize(…, extra_ips: nil)`). The ENV part resolves exactly as today (defaults when unset);
  then each extra is parsed and appended, de-duplicated. Rules: if the ENV part resolved to **unrestricted** (`[]`),
  extras are ignored (appending would *narrow* it); extras never contain a sentinel; a public extra (outside
  `DEFAULT_RANGES`) is kept **only while a token is configured**, exactly like an ENV entry: without a token it goes
  through the same `narrow_to_defaults` filter (warn + skip), so removing the token later deactivates it on the next
  build instead of leaving it silently active (Decision 3). All these rules are re-checked here, not only at save
  time (a value written from the console or restored from a backup goes through the same filter). `describe` (81-85) adds
  "(+N from settings)" when extras are in use.
- `OfficialMcp.access_policy` (25-27) passes `extra_ips: McpAccessLists.extra_entries(:ips)`. New
  `OfficialMcp.refresh_access!(transports:)`: clears `@access_policy`; calls `Transports.reset!` only when
  `transports: true` (Decision 4). `reset!` (30-33) stays as is.
- `api_authentication.rb:85`: use `GraphMem::OfficialMcp.access_policy` instead of building one from ENV, so
  `/api/v1` bearer requests and `/mcp` see the same merged IP list. (`McpAccessPolicy` is already loaded by
  `config/initializers/mcp.rb`.)

### A2. Validation (same rules as ENV, stricter where the UI can refuse)
New `GraphMem::McpAccessLists.validate(kind, raw)` → `{ entries:, errors:, warnings:, duplicates: }`. Input is
comma- or newline-separated; whitespace stripped; blanks dropped; an entry already in ENV is dropped and reported
under `duplicates` ("already set in ENV").
- **IPs:** each entry must parse as `IPAddr` (address or CIDR). **Refused (422):** `any`, `all`, `*` (lifting the
  restriction stays an ENV + token decision); anything unparseable (named in the message; ENV only warns, the UI can
  refuse); a range not inside `DEFAULT_RANGES` (public addresses) **when no token is configured** (same rule as
  ENV; the message says a token is required). **With a token, a public range is accepted** and saved, with a
  warning in the flash and beside the entry: "Public range: reachable from outside your network, protected only by
  the bearer token. If the token is removed, this entry stops applying." (Decision 3).
  Normalize to `IPAddr#to_range`-safe text (`addr/prefix`, e.g. `192.168.0.18/24` → `192.168.0.0/24`) and warn when
  the host bits were masked. Warning, not an error: "already covered by the ENV/default ranges" when the ENV part
  contains the range (e.g. any private range with the ENV unset); the entry is kept but has no effect.
- **Hosts:** a host name (RFC 1123 labels, `a-z0-9-` and dots, ≤ 253 chars), an IPv4 address, or a bracketed IPv6
  (`[fd00::1]`), each with an optional `:port` (1-65535). Lowercased. **Refused:** `*`, wildcards (`*.lan`), `any`,
  `all`, a scheme (`http://…`), a path, userinfo, spaces inside an entry. The loopback names
  (`localhost 127.0.0.1 ::1`) are dropped with a note ("always accepted").
- **Origins:** `scheme://host[:port]` with scheme `http` or `https`, a host as above, and **nothing else**. Lowercased;
  a single trailing `/` is stripped (warning shown); the default port is stripped (`:80` for http, `:443` for https),
  because browsers never send it and the gem compares exact strings. **Refused:** `*`, `null`, any other scheme, a
  path beyond `/`, a query, a fragment, userinfo.
- ENV values keep their current behaviour (no new errors at boot). The panel only **flags** an ENV entry that can
  never match (an origin with a path or trailing `/`, a host with a scheme) as a warning beside the prefix.

### A3. Settings panel (operator only)
- `settings_controller.rb`: a new group `mcp_access:` in `group_settings_by_category` (136-177) with the three keys;
  a validation block in `bulk_update` like the `project_scans` one (46-53): any error → re-render with `422`,
  **nothing saved**; on success write the normalized values, then one `AuditLog` row per changed key (same shape as
  `review_policy_settings.rb:35-44`), then `OfficialMcp.refresh_access!(transports: hosts_or_origins_changed)` and log
  `[McpAccessPolicy] /mcp access changed by <actor>: <describe>` at info. Put this in a small concern
  (`app/controllers/concerns/mcp_access_settings.rb`) so the controller doesn't grow.
- `restore_backup` (112-119): after a successful restore call `OfficialMcp.refresh_access!(transports: true)`, so the
  restored lists take effect at once instead of after a restart.
- `app/views/operator/settings/_mcp_access_panel.html.haml` (+ the `elsif` in `index.html.haml:20-29`), per list:
  - the **ENV value as a disabled, read-only text prefix** (`readonly`, not a form field, so it is never submitted),
    or "unset (default: loopback + private ranges)" / "unset (loopback names only)" / "unset"; for IPs with an
    unrestricted ENV: "ENV allows any IP (token set); additions have no effect", with the input disabled;
  - beside it, the **editable additive part** (text input, comma-separated);
  - the effective merged list below (read from `McpAccessLists.entries` / `access_policy`), and the A2 warnings;
    a stored public extra is marked "public (token required)" and, when no token is configured now, "inactive: no
    token" (it is listed but not in the effective list).
  - Help text: "Adds to the ENV value; it can't remove ENV entries. Not a secret. Operator pages and the operator
    login aren't behind these lists, so a mistake here can't lock you out."
  - A notice on the form: "**Saving a change to allowed hosts or origins closes every open MCP session.** Clients
    get `404 Session not found` on their next call and must start a new session (most reconnect on their own).
    Changing only the allowed IPs keeps sessions open." Don't reach into the gem for a session count (it has no
    public API for one).
- Locale strings in `config/locales/operator_settings.en.yml`; the tab title "MCP access". UI-7 later moves the panel
  under System › Access (§2.7 already lists "allowed IP ranges" there).
- **No lockout, by construction:** `AccessGate` only guards `Router.mcp_path?` paths (`access_gate.rb:14`), the
  operator pages and `/operator/login` aren't behind any of the three lists, an operator session on `/api/v1`
  isn't IP-checked, and the additive part can't remove an ENV entry. Say so in the docs (A6).

### A4. Specs (UI-2a)
- `spec/lib/graph_mem/mcp_access_lists_spec.rb`: validation table per kind (each refused form above, each
  normalization, duplicates of ENV entries, loopback names dropped, newline input); `entries` = ENV first, extras
  appended, case-insensitive de-dupe; `extra_entries` returns `[]` when the settings read raises.
- `spec/lib/graph_mem/mcp_access_policy_spec.rb` additions: extras extend the defaults when the ENV is unset; extras
  extend a custom ENV list (`127.0.0.0/8,::1,192.168.0.0/24` + `10.8.0.0/24` → both allowed); extras are ignored
  when ENV is unrestricted (`any` + token stays unrestricted); a stored sentinel in extras is skipped with a warning
  (with and without a token); a public extra (`198.51.100.0/24`) is allowed with a token and skipped with a warning
  without one; **token removed later:** the same stored public extra, policy rebuilt with no token → the range is
  refused and a warning is logged (it doesn't stay active); `describe` shows the extras count.
- `spec/requests/operator/mcp_access_settings_spec.rb`: operator saves each list (200/redirect, stored normalized
  value, one `AuditLog` row per changed key); each refused input → 422 and nothing stored; a public range →
  422 without a token, saved with the public-range warning shown with a token; `any`/`all`/`*` → 422 with a token
  too; guest → 403, signed out →
  login redirect (role matrix stays green); the ENV prefix renders as read-only text and is not a submitted param;
  saving IPs only calls `refresh_access!(transports: false)`, saving hosts or origins calls it with `true` (spy).
- `spec/requests/mcp_official_spec.rb` additions (under `with_env`, and reset the settings rows after each example):
  1. **refresh on change:** a `Host: synth-lan.test` initialize gets 403; the operator adds `synth-lan.test`; the
     next initialize gets a session, with no restart;
  2. **CORS and transport agree after a change:** with ENV `GRAPH_MEM_MCP_ALLOWED_ORIGINS=http://localhost:3001`,
     add `http://synth-ui.localhost:3002` in settings, then for that origin: the preflight has
     `access-control-allow-origin` **and** the POST initialize gets 200; for an origin removed from settings: no
     ACAO on the preflight **and** 403 on the POST (never one without the other);
  3. **sessions are dropped by a hosts/origins change:** a session opened before the change answers 404 after it;
     a session survives an IPs-only change;
  4. **IP extras reach `/mcp` and `/api/v1`:** with ENV `GRAPH_MEM_MCP_ALLOWED_IPS=127.0.0.1` and a token, a request
     from `10.8.0.5` (`REMOTE_ADDR`) is 403 on `/mcp` and on a bearer `/api/v1` GET, then allowed on both after
     `10.8.0.0/24` is added.
- `spec/requests/operator/settings_spec.rb`: a restore re-reads the lists (spy on `refresh_access!`).

### A5. `bin/up`: host-side LAN detection for `docker compose up -d`
The container can't reliably learn the host's LAN address (Docker Desktop on macOS runs it in a VM; and the
detected values must exist before compose substitutes `${…}`), so detection runs on the host, in a POSIX-ish bash
script next to `bin/docker-mcp`.
- `bin/up [--print] [compose args…]`: `set -euo pipefail`; detects, then `exec docker compose up -d "$@"` with the
  computed variables exported. `--print` prints the values it would pass (and where each came from: ENV, `.env`,
  detected, default) and exits 0 without running compose. `--help` documents both.
- **Override order (per variable):** a non-empty value in the caller's environment, then a non-comment
  `KEY=value` line in `.env` (parse it with a simple `grep`/`sed`; don't `source` it), then the detected value. A set
  value is passed through **unchanged** (it is not merged with the detection). Compose gives the shell environment
  priority over `.env`, which is why the script must not export a detected value when `.env` sets one.
- **Detection, Linux first:** `ip -4 route get 1.1.1.1` (no traffic is sent) → `src` address and `dev`;
  `ip -o -4 addr show dev <dev>` → the `addr/prefix` holding that address; compute the network address in bash
  arithmetic (e.g. `192.168.0.18/24` → `192.168.0.0/24`). **macOS (best effort):** `route -n get default` →
  `interface:`; `ipconfig getifaddr <if>`; netmask from `ifconfig <if>` (`netmask 0xffffff00` → `/24`). Host
  names: `hostname -s` (or `scutil --get LocalHostName` on macOS) and `<name>.local`.
- **Defaults it produces:**
  - `GRAPH_MEM_MCP_ALLOWED_HOSTS` = `<name>,<name>.local,<lan-ip>` (lowercased, de-duplicated). This is the main
    gain: it fixes `Forbidden: Invalid Host header` for LAN clients out of the box.
  - `GRAPH_MEM_MCP_ALLOWED_IPS` = `127.0.0.0/8,::1,172.16.0.0/12,<lan-subnet>`. **Loopback and the Docker bridge
    range are always in the list**, because a custom list replaces `DEFAULT_RANGES` (Steve hit exactly this:
    `192.168.0.0/24` alone stopped localhost from working) and local clients can arrive from a bridge address
    (containers on the default bridge, or a setup without `network_mode: host`). Only narrow to the subnet when the
    detected address is private (inside `10/8`, `172.16/12` or `192.168/16`) and the prefix is between `/16` and
    `/30`; otherwise leave the variable unset so the policy's defaults apply, and print why.
  - `GRAPH_MEM_MCP_ALLOWED_ORIGINS`: **not set** by `bin/up` (Decision 6): an origin is the browser client's own
    `scheme://host:port`, which the server host can't guess, and same-origin pages need no entry.
- **Fallback:** if any detection step fails (no `ip`/`route`, no default route, unparseable output, a CIDR that
  doesn't parse), print one line to stderr ("LAN detection failed: …; using the built-in defaults") and leave the
  variable unset, i.e. exactly today's behaviour. Never abort the start-up because detection failed.
- **Specs:** `spec/bin/up_spec.rb` runs `bin/up --print` with a temp `PATH` of fake `ip`, `ifconfig`, `route`,
  `ipconfig`, `hostname`, `scutil`, `uname` scripts printing canned synthetic output (`192.0.2.18/24` is public, so
  use `10.9.8.18/24` and `172.20.1.5/16` for the private cases): Linux → hosts and IPs as above (loopback and
  bridge present); macOS → the same from `route`/`ifconfig`; ENV override wins; a `.env` line wins over detection
  and a commented `.env` line doesn't; a public address → IPs left unset, hosts still set; every tool missing →
  both unset, a stderr line, exit 0. Run it from a temp dir copy of `.env` fixtures; never read the real `.env`.
  Also `bash -n bin/up` in the spec, and `shellcheck bin/up` if `shellcheck` is on `PATH` (skip otherwise).

### A6. Docs and config
- `docs/troubleshooting.md` (after the item at 27-38): a new entry **"`-32600 Forbidden: Invalid Host header` from
  another machine on the LAN"**: cause (the `Host` the client uses isn't loopback or listed), fixes in order: start
  with `bin/up`, or add the name/IP in Settings › MCP access, or set `GRAPH_MEM_MCP_ALLOWED_HOSTS`. Plus the
  follow-up symptom: "after setting `GRAPH_MEM_MCP_ALLOWED_IPS` to a subnet, `localhost` stops working": include
  `127.0.0.0/8,::1` (and `172.16.0.0/12` in Docker), or let `bin/up` build the list.
- `docs/mcp_access_control.md`: in "Configuration" (40-51) a paragraph on the settings panel (additive, ENV entries
  can't be removed, same validation, public ranges only with a token (and inactive if the token is removed), no
  `any` from the UI, not secrets, no lockout because operator
  pages aren't behind the lists, hosts/origins changes close open MCP sessions); a "Starting with `bin/up`" recipe
  with an example `--print` output (synthetic values).
- `.env.example`: comment out `:35` (`# GRAPH_MEM_MCP_ALLOWED_IPS=127.0.0.0/8,::1,172.16.0.0/12,192.168.0.0/24`) and
  add above the block: "Leave these unset to let `bin/up` detect them; a value here overrides the detection. A custom
  IP list replaces the defaults: keep `127.0.0.0/8,::1` (and `172.16.0.0/12` in Docker)."
- `README.md:174` and `:186`: `bin/up` (`bin/up --build` for the update line), with one sentence that `docker compose
  up -d` still works and uses the built-in defaults.
- `docs/app_settings_reference.md`: the three new fields.
- CHANGELOG (these go under `## [1.58.3]` in RA):
  - **Added:** "Settings › MCP access: add allowed IPs, hosts and origins at runtime, on top of the ENV values (which
    can't be removed there). Changes apply without a restart; changing hosts or origins closes open MCP sessions."
  - **Added:** "`bin/up` starts the stack with the host's LAN subnet and host names as the MCP allowlist defaults
    (loopback and the Docker bridge range always kept); ENV and `.env` values override it."
  - **Changed:** "`/api/v1` bearer requests use the same merged IP allowlist as `/mcp`."

### RA. Release 1.58.3
- `lib/graph_mem/version.rb:4` → `VERSION = "1.58.3"`; `skills/graph-mem-mcp-toolset/SKILL.md:18` →
  `graph-mem-version: "1.58.3"`. Check with `rg -n '1\.58\.2' -g '!CHANGELOG.md' -g '!docs/plans/**' -g '!Gemfile.lock'`:
  the only other hits are the recorded runs in `docs/protocol_compat.md:27, 61, 63` and
  `script/mcp_compat/README.md:78` ("at 1.58.2 …"). They record when the compat suite was last run; leave them
  unless you re-run it (UI-2a changes no protocol behaviour).
- CHANGELOG: rename `## [Unreleased]` to `## [1.58.3] - <merge date>` with a one-line summary ("Editable MCP
  allowlists and `bin/up` LAN detection."). It **absorbs the existing Security line from PR-C** ("Project scans no
  longer follow a symlinked child to test whether it's a directory.") plus the A6 entries. Add a
  **Security** line: "Settings › MCP access can add public IP ranges only while `GRAPH_MEM_MCP_TOKEN` is set, as
  ENV can; without a token they are refused and stop applying."

## UI-2b → 1.59.0: Home

Unchanged scope from `ui-dashboard-plan.md` §2.2 and §6 UI-2 (status-only Home; its only form is quick search).
Since that section was written, UI-5 has shipped `/review` and `ReviewDigest`, so the digest links there; UI-6 hasn't,
so scan and import buttons still link to the old pages.

### H1. `HomeSnapshot`
- New `app/services/home_snapshot.rb` composing `MaintenanceDashboardSnapshot`, `EmbeddingStatusSnapshot`,
  `AgentContextsSnapshot`, the review digest (`ReviewDigest`), recent jobs from `OperationProgress`, recent change
  sets and `ScanRootPolicy.status`. The health strip's "MCP access mode" pill reads `OfficialMcp.access_policy.describe`
  (now including the UI-2a extras) and links to Settings › MCP access.

### H2. Page
- `app/controllers/pages_controller.rb` (`home`, 6-21), `app/views/pages/home.html.haml`, `app/views/home/_*.html.haml`
  (lazy Turbo Frames); remove the `app/views/pages/dashboard/*` partials as their content moves. Exactly §2.2: no
  forms except quick search.

### H3. Specs
- `spec/requests/pages_spec.rb` (health strip green/amber/red with a stubbed snapshot; digest rows link correctly; no
  `form` other than search; guest → redirect to `/search`); `spec/services/home_snapshot_spec.rb`; a system spec
  Home → digest → Review.

### R. Release 1.59.0
- `lib/graph_mem/version.rb`, `skills/graph-mem-mcp-toolset/SKILL.md` and the CHANGELOG to **1.59.0**
  (`## [1.59.0] - <merge date>`, with any `[Unreleased]` entries added after 1.58.3).

## Specs (summary)

| PR | New / changed |
|---|---|
| UI-2a (1.58.3) | `mcp_access_lists_spec.rb` (validation, merge); `mcp_access_policy_spec.rb` (extras, public extras with/without a token, token removed later → re-filtered); `operator/mcp_access_settings_spec.rb` (save, 422, public range 422 without a token / saved + warning with one, sentinel always 422, audit, roles, refresh vs reset); `mcp_official_spec.rb` (refresh on change, CORS ⇔ transport after a change, sessions dropped only by hosts/origins changes, IP extras on `/mcp` and `/api/v1`); `operator/settings_spec.rb` (restore refresh); `spec/bin/up_spec.rb` (detection, overrides, fallback). |
| UI-2b (1.59.0) | `pages_spec.rb`, `home_snapshot_spec.rb`, a Home → digest → Review system spec. |

## Size and split

| PR | Version | Estimate | Diff size (guess) |
|---|---|---|---|
| UI-2a | **1.58.3** | ~1 day | ~600 lines (half specs; `bin/up` ~150) |
| UI-2b | **1.59.0** | ~1–1.5 days | ~700 lines, mostly views/partials |

UI-2a goes first: it's independent of Home, fixes Steve's LAN set-up, and Home's MCP pill reads its result.

## Decisions (defaults; Steve may change any)

1. **Two PRs** (UI-2a allowlists + `bin/up`, UI-2b Home + release), like UI-1a/1b and UI-5a/5b.
2. **Storage:** three `AppSettings` string fields. These lists aren't secrets, so the settings table (which is in
   every backup and export) is fine; the token never goes there.
3. **Public ranges from the UI only with a token, as in ENV** (Steve, Oct 27). Without a token: 422. With one:
   saved, with a warning. Re-filtered on every policy build, so if the token is removed the public extras stop
   applying (logged, shown as inactive) instead of staying silently active. `any`/`all`/`*` stay **refused from the
   UI** even with a token: in ENV the sentinel lifts the whole restriction, which is a deployment decision, not an
   addition, and the additive model can't express it (appending to an unrestricted list would narrow it).
4. **Only hosts/origins changes call `Transports.reset!`.** The transport caches hosts and origins at build time,
   not IPs, so an IPs-only change just clears the memoized policy and keeps sessions open. (Alternative: always
   `OfficialMcp.reset!`, simpler, but every IP edit drops sessions.)
5. **Single-process refresh.** Puma runs one process today; the refresh is in-process. If more workers are ever
   configured, a change only reaches the worker that saved it until restart; noted in the code comment, not solved
   here.
6. **`bin/up` doesn't set `GRAPH_MEM_MCP_ALLOWED_ORIGINS`** (the server can't guess a browser client's origin).
7. **`bin/up` passes an ENV/`.env` value through unchanged** rather than merging it with the detection, so an explicit
   list always means exactly what it says. The Settings panel is where additions go.
8. **UI-2a ships as 1.58.3** (Steve, Oct 27), so `bin/up` and the panel reach the LAN set-up before Home; it also
   releases PR-C's `[Unreleased]` Security line. UI-2b stays **1.59.0**; the UI train numbers don't move.

## Acceptance criteria

- UI-2a (1.58.3): an operator can add a host, an origin and an IP range in Settings and a LAN client uses them on its next
  request with no restart; ENV entries are shown as a read-only prefix and can't be removed; every refused input is
  a 422 with nothing stored; a public range is refused without a token, accepted with a warning with one, and stops
  applying when the token is removed; `any`/`all`/`*` are always refused from the UI; CORS and the transport accept exactly the same origins after any change; a hosts/origins
  change closes sessions and says so beforehand, an IPs-only change doesn't; `/api/v1` bearer and `/mcp` agree on
  IPs; guests get 403 on the panel; `bin/up --print` on Linux gives hosts `<name>,<name>.local,<ip>` and IPs with
  loopback, `::1`, `172.16.0.0/12` and the detected subnet; an ENV or `.env` value wins; a failed detection leaves
  today's defaults; `docker compose up -d` without `bin/up` behaves as before; version text and CHANGELOG read
  1.58.3 (`## [1.58.3]` includes PR-C's Security line; no `## [Unreleased]` left).
- UI-2b (1.59.0): as in `ui-dashboard-plan.md` §6 UI-2 (Home fits in ~1.5 screens at 1440×900 with synthetic data and renders
  in < 300 ms with the embedding service unreachable, `OLLAMA_URL=http://127.0.0.1:9`; lazy frames).
- Both: full suite green locally and on CI (rspec, rubocop, brakeman, lint, scan_ruby, scan_js); 0 rows left in the
  test DB; `git diff db/structure.sql` empty (no migration is needed: `AppSettings` rows only); CHANGELOG entries;
  synthetic data only.

## Stop and ask Steve if

- Any code above no longer matches its description (in particular `transports.rb` options, the `cors.rb` Proc,
  `OfficialMcp.reset!`, or `api_authentication.rb:85`).
- Puma is configured with more than one worker anywhere in the repo's deploy configs.
- `Transports.reset!` blocks noticeably (the gem joins its reaper thread on `close`) or an in-flight request on a
  closed transport answers 500 in the specs.
- Supporting the additive IP list needs a change to `McpAccessPolicy`'s invariant or to how the ENV part resolves.
- Keeping `any`/`all`/`*` refused from the UI turns out inconsistent with how ENV and the extras combine (e.g. a
  case where the ENV rule would honour a sentinel the UI can't represent); keep it refused and ask.
- The gem's host matching doesn't accept a form A2 allows (e.g. bracketed IPv6 with a port), or accepts one it
  refuses.
- `bin/up` needs anything beyond bash and the standard `ip`/`route`/`ifconfig`/`hostname` tools, or detection would
  have to run inside the container.
- A documented setup relies on the uncommented `.env.example` IP line.
