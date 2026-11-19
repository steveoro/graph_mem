#!/usr/bin/env bash
# Runs the auto-adoption tests of docs/plans/auto-adoption-tests.md end to end and writes a report.
#
#   script/adoption_eval/run_eval.sh                 # menu: pick a suite, N and the model
#   script/adoption_eval/run_eval.sh --suite screen --yes
#   script/adoption_eval/run_eval.sh --suite custom --arms I,ALL --tasks T1 --n 1
#   script/adoption_eval/run_eval.sh --resume 20261119T104500Z
#   script/adoption_eval/run_eval.sh --help
#
# What it does by itself: builds the eval MCP configs from your user-scope graph_mem entry (the
# token never leaves a private temp dir), pins and resets the scratch clones next to this repo, flips
# the user-level levers (rule, skill, hook, alwaysLoad) per arm and restores them afterwards, runs
# headless Claude Code (and the Cursor CLI) sessions, stops on a usage limit with a resume hint, and
# writes a counts-only report under ~/adoption-eval/reports/. It pauses only where a person must act:
# the Cursor User Rules UI, the IDE calibration chats, and the timed install test.
#
# --setting KEY=VALUE changes a graph_mem setting in the production container for the run, restarts
# the app container (closing every open MCP session) and puts the old value back at the end.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PROJECTS_DIR=${ADOPTION_PROJECTS_DIR:-$(dirname "$REPO")}
EVAL_DIR=${ADOPTION_EVAL_DIR:-$HOME/adoption-eval}
SUMMARIZE=$REPO/script/adoption_eval/summarize.rb
READ_TOOLS=(get_context set_context search get_entities traverse_graph)

note() { printf '%s\n' "$@" >&2; }
die() {
  note "run_eval: $*"
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: script/adoption_eval/run_eval.sh [options]

Suites (docs/plans/auto-adoption-tests.md):
  screen      I ALL ALL-R ALL-S ALL-H ALL+A on T1, N=5 (30 sessions, the default)
  full        the same arms on T1 T2 T3, N=5 (90)
  q1          ALL ALL+A on T1 T2 T3, N=10 (60)
  q2          RO-full RO-lite on T4, N=5 (10)
  cursor      K0 K1 K2 on T1 T3, N=5, headless Cursor CLI (30; K1 needs one paste in Cursor)
  cursor-ide  K0 K2 on T1, N=5, as manual Cursor IDE chats to calibrate the CLI numbers (10)
  q3          the timed install test, one per host (manual)
  custom      --arms / --tasks / --n

Options:
  --suite NAME           a suite above (no options at all opens a menu)
  --arms A,B --tasks T1,T3 --n N
                         Claude Code arms: I R S H A ALL ALL-R ALL-S ALL-H ALL+A RO-full RO-lite;
                         Cursor arms: K0 K1 K2 (B0 and ALL-I need a 1.89.0 server)
  --model ALIAS          Claude Code model (default: the "model" in ~/.claude/settings.json)
  --cursor-model NAME    Cursor CLI model (default: the CLI's own)
  --max-turns N          per session (default 25)
  --setting KEY=VALUE    change a graph_mem setting in the production container for this run
                         (repeatable; restarts the app container, restored at the end)
  --resume RUN_ID        finish an interrupted run (sessions with a result are kept)
  --restore RUN_ID       only put back what a killed run changed, then exit
  --refresh-clones       move the scratch clones' pinned commit to origin's default branch
  --guard-skip A,B       repos under the projects folder the edit guard ignores
  --dry-run              print the plan and exit, changing nothing
  --yes                  don't ask before starting
  -h, --help             this help

Environment: ADOPTION_PROJECTS_DIR (default: this repo's parent folder),
ADOPTION_EVAL_DIR (default: ~/adoption-eval).
USAGE
}

# --- Options ---------------------------------------------------------------------------------

SUITE="" ARMS="" TASKS="" N="" MODEL="" CURSOR_MODEL="" MAX_TURNS=25 RESUME="" RESTORE_ONLY=""
REFRESH_CLONES=false DRY_RUN=false ASSUME_YES=false GUARD_SKIP=""
SETTING_KEYS=() SETTING_VALUES=()
[[ $# -eq 0 ]] && INTERACTIVE=true || INTERACTIVE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --suite) SUITE=${2:?--suite needs a name}; shift ;;
    --arms) ARMS=${2//,/ }; shift ;;
    --tasks) TASKS=${2//,/ }; shift ;;
    --n) N=${2:?}; shift ;;
    --model) MODEL=${2:?}; shift ;;
    --cursor-model) CURSOR_MODEL=${2:?}; shift ;;
    --max-turns) MAX_TURNS=${2:?}; shift ;;
    --setting)
      [[ ${2:-} == *=* ]] || die "--setting takes KEY=VALUE"
      SETTING_KEYS+=("${2%%=*}") SETTING_VALUES+=("${2#*=}")
      shift
      ;;
    --resume) RESUME=${2:?}; shift ;;
    --restore) RESTORE_ONLY=${2:?}; shift ;;
    --refresh-clones) REFRESH_CLONES=true ;;
    --guard-skip) GUARD_SKIP=${2//,/ }; shift ;;
    --dry-run) DRY_RUN=true ;;
    --yes) ASSUME_YES=true ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
[[ $N =~ ^[0-9]*$ && $MAX_TURNS =~ ^[0-9]+$ ]] || die "--n and --max-turns take numbers"

tty_read() { # tty_read VAR PROMPT [DEFAULT]
  local answer
  [[ -r /dev/tty ]] || die "this step needs a terminal"
  read -r -p "$2${3:+ [$3]} " answer </dev/tty
  printf -v "$1" '%s' "${answer:-${3:-}}"
}
pause() {
  local _
  tty_read _ "$1 Press Enter to continue."
}

# --- Tasks, arms and suites -----------------------------------------------------------------

task_prompt() {
  case "$1" in
    T1) echo "In goggles_admin2-eval (a clone of goggles_admin2), add a CHANGELOG entry and bump the version for a small fix to the Data-Fix grid toolbar." ;;
    T2) echo "In goggles_admin2-eval (a clone of goggles_admin2), add a spec for the error handling in app/strategies/api_proxy.rb." ;;
    T3) echo "In fast-mcp-eval (a clone of fast-mcp), prepare a patch release: bump the version and add the CHANGELOG entry for a fix in initialize handling." ;;
    T4) echo "In goggles_admin2-eval (a clone of goggles_admin2), I prefer commit subjects under 50 characters; keep that in mind. Then fix any typo you find in README.md." ;;
    *) return 1 ;;
  esac
}
task_clone() { [[ $1 == T3 ]] && echo fast-mcp-eval || echo goggles_admin2-eval; }

# "rule skill hook mcp" for a Claude Code arm; "cursor" for a Cursor arm.
arm_spec() {
  case "$1" in
    I) echo "off old off default" ;;
    R) echo "on old off default" ;;
    S) echo "off new off default" ;;
    H) echo "off old on default" ;;
    A) echo "off old off alwaysload" ;;
    ALL) echo "on new on default" ;;
    ALL-R) echo "off new on default" ;;
    ALL-S) echo "on old on default" ;;
    ALL-H) echo "on new off default" ;;
    ALL+A) echo "on new on alwaysload" ;;
    RO-full) echo "off new off readonly" ;;
    RO-lite) echo "off lite off readonly" ;;
    K0 | K1 | K2) echo "cursor" ;;
    B0 | ALL-I) die "$1 needs the 1.89.0 instructions, which this server no longer serves: compare with your 1.89.0 logs" ;;
    *) die "unknown arm: $1" ;;
  esac
}

suite_plan() { # sets ARMS TASKS N (keeping any given on the command line)
  local arms tasks n
  case "$1" in
    screen) arms="I ALL ALL-R ALL-S ALL-H ALL+A" tasks="T1" n=5 ;;
    full) arms="I ALL ALL-R ALL-S ALL-H ALL+A" tasks="T1 T2 T3" n=5 ;;
    q1) arms="ALL ALL+A" tasks="T1 T2 T3" n=10 ;;
    q2) arms="RO-full RO-lite" tasks="T4" n=5 ;;
    cursor) arms="K0 K1 K2" tasks="T1 T3" n=5 ;;
    cursor-ide) arms="K0 K2" tasks="T1" n=5 ;;
    q3) arms="" tasks="" n=0 ;;
    custom) arms="" tasks="" n=1 ;;
    *) die "unknown suite: $1" ;;
  esac
  ARMS=${ARMS:-$arms} TASKS=${TASKS:-$tasks} N=${N:-$n}
}

menu() {
  local choice
  note "Suites: 1) screen (30)  2) full (90)  3) q1 (60)  4) q2 (10)  5) cursor (30, headless)"
  note "        6) cursor-ide (10, manual)  7) q3 (install test)  8) custom"
  tty_read choice "Suite?" 1
  case "$choice" in
    1 | screen) SUITE=screen ;; 2 | full) SUITE=full ;; 3 | q1) SUITE=q1 ;; 4 | q2) SUITE=q2 ;;
    5 | cursor) SUITE=cursor ;; 6 | cursor-ide) SUITE=cursor-ide ;; 7 | q3) SUITE=q3 ;; 8 | custom) SUITE=custom ;;
    *) die "no such suite: $choice" ;;
  esac
  if [[ $SUITE == custom ]]; then
    tty_read ARMS "Arms (space-separated)?" "I ALL"
    tty_read TASKS "Tasks?" "T1"
  fi
  suite_plan "$SUITE"
  [[ $SUITE == q3 ]] || tty_read N "Sessions per arm and task?" "$N"
}

# --- State shared with the cleanup trap ------------------------------------------------------

RUN_ID="" RUN_DIR="" SECRETS="" WORK="" BACKUP="" SETTINGS_CHANGED=false CLEANED=false
ORIGINAL_SETTINGS=()

USER_PATHS=("$HOME/.claude/rules/graph-mem.md" "$HOME/.claude/skills/graph-mem-mcp-toolset"
  "$HOME/.claude/hooks/graph_mem_session_start.sh")
CURSOR_PATHS=("$HOME/.cursor/mcp.json" "$HOME/.cursor/cli-config.json" "$HOME/.cursor/hooks.json"
  "$HOME/.cursor/hooks/graph_mem_session_start_cursor.sh")

# Copies each path (or an "absent" marker, and whether its folder existed) into $BACKUP.
backup_paths() {
  local path key
  mkdir -p "$BACKUP" && chmod 700 "$BACKUP"
  for path in "$@"; do
    key=$(printf '%s' "${path#"$HOME"/}" | tr '/' '%')
    [[ -e $BACKUP/$key || -e $BACKUP/$key.absent ]] && continue
    if [[ -e $path ]]; then cp -a "$path" "$BACKUP/$key"; else printf '%s\n' "$path" >"$BACKUP/$key.absent"; fi
    [[ -d $(dirname "$path") ]] || printf '%s\n' "$(dirname "$path")" >"$BACKUP/$key.newdir"
    printf '%s\n' "$path" >"$BACKUP/$key.path"
  done
  echo taken >"$BACKUP/state"
}

# Puts every backed-up path back exactly as it was, and removes folders the run created.
restore_paths() {
  local marker key path
  [[ -d $BACKUP && $(cat "$BACKUP/state" 2>/dev/null) == taken ]] || return 0
  for marker in "$BACKUP"/*.path; do
    [[ -e $marker ]] || continue
    key=$(basename "$marker" .path)
    path=$(cat "$marker")
    rm -rf "$path"
    [[ -e $BACKUP/$key ]] && cp -a "$BACKUP/$key" "$path"
    [[ -e $BACKUP/$key.newdir ]] && rmdir -p "$(cat "$BACKUP/$key.newdir")" 2>/dev/null || true
  done
  echo restored >"$BACKUP/state"
  note "Restored the user-level files."
}

cleanup() {
  $CLEANED && return 0
  CLEANED=true
  set +e
  restore_paths
  $SETTINGS_CHANGED && restore_settings
  [[ -n $SECRETS ]] && rm -rf "$SECRETS"
  [[ -n $WORK ]] && rm -rf "$WORK"
  return 0
}

if [[ -n $RESTORE_ONLY ]]; then
  BACKUP=$EVAL_DIR/runs/$RESTORE_ONLY/.backup
  [[ -d $BACKUP ]] || die "no backup for run $RESTORE_ONLY"
  restore_paths
  exit 0
fi

# --- Preflight -------------------------------------------------------------------------------

need() { command -v "$1" >/dev/null || die "$1 is not installed"; }

# The eval MCP configs from the user-scope graph_mem entry (or the repo's .env), in a private temp dir.
build_mcp_configs() {
  local entry token
  SECRETS=$(mktemp -d "${TMPDIR:-/tmp}/adoption-eval.XXXXXX")
  chmod 700 "$SECRETS"
  entry=$(jq -c '.mcpServers.graph_mem // empty' "$HOME/.claude.json" 2>/dev/null || true)
  if [[ -z $entry ]]; then
    token=$(sed -n 's/^GRAPH_MEM_MCP_TOKEN=//p' "$REPO/.env" 2>/dev/null | tr -d '"' | head -1)
    entry=$(jq -cn --arg token "$token" '{type: "http", url: "http://localhost:3030/mcp", headers: (if $token == "" then {} else {Authorization: "Bearer \($token)"} end)}')
  fi
  local mask
  mask=$(umask)
  umask 077
  jq -c '.headers = ((.headers // {}) + {"X-MCP-Client": "adoption-eval"})' <<<"$entry" >"$SECRETS/entry.json"
  jq '{mcpServers: {graph_mem: .}}' "$SECRETS/entry.json" >"$SECRETS/mcp.json"
  jq '{mcpServers: {graph_mem: (. + {alwaysLoad: true})}}' "$SECRETS/entry.json" >"$SECRETS/mcp-alwaysload.json"
  jq '{mcpServers: {graph_mem: (.url |= sub("/mcp(/.*)?$"; "/mcp/readonly"))}}' "$SECRETS/entry.json" >"$SECRETS/mcp-readonly.json"
  # curl reads the headers from a config file, so the token never shows in a process list.
  jq -r '.headers | to_entries[] | "header = \"\(.key): \(.value)\""' "$SECRETS/entry.json" >"$SECRETS/curl.conf"
  umask "$mask"
  MCP_URL=$(jq -r .url "$SECRETS/entry.json")
  BASE_URL=${MCP_URL%%/mcp*}
}

server_version() {
  curl -fsS --noproxy '*' -m 10 -K "$SECRETS/curl.conf" -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' "$MCP_URL" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"adoption-eval","version":"1"}}}' 2>/dev/null |
    sed -n 's/^data: //p; /^{/p' | jq -r '.result.serverInfo.version // empty' 2>/dev/null | head -1
}

server_up() { curl -fsS --noproxy '*' -m 5 "$BASE_URL/up" >/dev/null 2>&1; }

# Which user-level texts exist before the run, and whether they mention graph_mem (counts only).
baseline_json() {
  local label path exists mentions rows=()
  local -a checks=("~/.claude/CLAUDE.md|$HOME/.claude/CLAUDE.md" "~/.claude/rules/*|$HOME/.claude/rules"
    "<projects-dir>/CLAUDE.md|$PROJECTS_DIR/CLAUDE.md" "~/.claude/skills/graph-mem-mcp-toolset|$HOME/.claude/skills/graph-mem-mcp-toolset"
    "<projects-dir>/.claude/skills/graph-mem-mcp-toolset|$PROJECTS_DIR/.claude/skills/graph-mem-mcp-toolset")
  for label in "${checks[@]}"; do
    path=${label#*|}
    exists=false mentions=false
    if [[ -e $path ]]; then
      exists=true
      grep -rqi 'graph_mem' "$path" 2>/dev/null && mentions=true
    fi
    rows+=("$(jq -cn --arg path "${label%%|*}" --argjson e "$exists" --argjson m "$mentions" '{path: $path, exists: $e, mentions_graph_mem: $m}')")
  done
  printf '%s\n' "${rows[@]}" | jq -cs .
}

# --- Clones ----------------------------------------------------------------------------------

CLONES=(goggles_admin2-eval fast-mcp-eval)
declare -A CLONE_SOURCE=([goggles_admin2-eval]=goggles_admin2 [fast-mcp-eval]=fast-mcp)
declare -A CLONE_URL=([goggles_admin2-eval]=https://github.com/steveoro/goggles_admin2.git
  [fast-mcp-eval]=https://github.com/steveoro/fast-mcp.git)
declare -A CLONE_SHA=()

# Clones a missing scratch clone from the local source repo (no network), else from GitHub, and
# pins it: the commit in $EVAL_DIR/clones.lock, recorded on the first run.
prepare_clone() {
  local name=$1 dest=$PROJECTS_DIR/$1 src=$PROJECTS_DIR/${CLONE_SOURCE[$1]} branch sha lock=$EVAL_DIR/clones.lock
  if [[ ! -d $dest/.git ]]; then
    if [[ -d $src/.git ]]; then
      branch=$(git -C "$src" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
      git clone -q ${branch:+--branch "$branch"} "$src" "$dest"
      git -C "$dest" remote set-url origin "$(git -C "$src" remote get-url origin 2>/dev/null || echo "${CLONE_URL[$name]}")"
    else
      git clone -q "${CLONE_URL[$name]}" "$dest"
    fi
    note "Cloned $name."
  fi
  sha=$(awk -v n="$name" '$1 == n { print $2 }' "$lock" 2>/dev/null || true)
  if $REFRESH_CLONES; then
    git -C "$dest" fetch -q origin
    sha=$(git -C "$dest" rev-parse "origin/HEAD" 2>/dev/null || git -C "$dest" rev-parse origin/main)
  fi
  [[ -n $sha ]] || sha=$(git -C "$dest" rev-parse HEAD)
  touch "$lock"
  { grep -v "^$name " "$lock" || true; echo "$name $sha"; } >"$lock.tmp" && mv "$lock.tmp" "$lock"
  CLONE_SHA[$name]=$sha
  reset_clone "$name"
}

reset_clone() {
  git -C "$PROJECTS_DIR/$1" checkout -q --force --detach "${CLONE_SHA[$1]}"
  git -C "$PROJECTS_DIR/$1" clean -fdq
}

# --- Edit guard ------------------------------------------------------------------------------

# The projects folder's top-level entries (files by content) and each repo's git status, except the
# clones and anything named in --guard-skip.
guard_state() {
  local entry name
  for entry in "$PROJECTS_DIR"/* "$PROJECTS_DIR"/.[!.]*; do
    [[ -e $entry ]] || continue
    name=$(basename "$entry")
    [[ " ${CLONES[*]} $GUARD_SKIP " == *" $name "* ]] && continue
    if [[ -d $entry/.git ]]; then
      echo "repo $name $(git -C "$entry" status --porcelain 2>/dev/null | md5sum)"
    elif [[ -f $entry ]]; then
      echo "file $name $(md5sum <"$entry")"
    else
      echo "dir $name"
    fi
  done
}

check_guard() {
  local now changed
  now=$(guard_state)
  [[ $now == "$GUARD_BEFORE" ]] && return 0
  changed=$(diff <(echo "$GUARD_BEFORE") <(echo "$now") | sed -n 's/^> \(repo\|file\|dir\) \([^ ]*\).*/\2/p' | sort -u | tr '\n' ' ')
  note "Stopped: something changed outside the scratch clones: ${changed:-<projects-dir>}."
  note "Nothing was reverted there. Check it, then rerun with --resume $RUN_ID (or --guard-skip if it's your own work)."
  exit 3
}

# --- Levers ----------------------------------------------------------------------------------

build_variants() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/adoption-eval-work.XXXXXX")
  mkdir -p "$WORK/skill-old" "$WORK/skill-new" "$WORK/skill-lite"
  git -C "$REPO" archive v1.89.0 skills/graph-mem-mcp-toolset | tar -x -C "$WORK/skill-old" --strip-components=1
  cp -r "$REPO/skills/graph-mem-mcp-toolset" "$WORK/skill-new/"
  cp -r "$REPO/skills/graph-mem-mcp-toolset" "$WORK/skill-lite/"
  # The readonly variant: no Persist section, no line that names a write tool or the persist prompt.
  ruby -e '
    text = File.read(ARGV[0])
    text = text.gsub(/^## Persist.*?(?=^## )/m, "")
    File.write(ARGV[0], text.lines.reject { |line| line.match?(/graph_write|graph_edit|graph_delete|`persist`/) }.join)
  ' "$WORK/skill-lite/graph-mem-mcp-toolset/SKILL.md"
  echo '{"hooks": {}}' >"$WORK/settings-nohook.json"
  printf '%s\n' '{"hooks":{"SessionStart":[{"matcher":"startup|resume|clear|compact","hooks":[{"type":"command","command":"~/.claude/hooks/graph_mem_session_start.sh","timeout":5}]}]}}' \
    >"$WORK/settings-hook.json"
}

CURRENT_ARM=""
apply_arm() {
  local rule skill hook mcp
  read -r rule skill hook mcp <<<"$(arm_spec "$1")"
  [[ $1 == "$CURRENT_ARM" ]] && return 0
  CURRENT_ARM=$1
  mkdir -p "$HOME/.claude/skills"
  if [[ $rule == on ]]; then
    mkdir -p "$HOME/.claude/rules" && cp "$REPO/docs/rules/graph_mem_user_rule.md" "$HOME/.claude/rules/graph-mem.md"
  else rm -f "$HOME/.claude/rules/graph-mem.md"; fi
  rm -rf "$HOME/.claude/skills/graph-mem-mcp-toolset"
  [[ $skill != none ]] && cp -r "$WORK/skill-$skill/graph-mem-mcp-toolset" "$HOME/.claude/skills/"
  if [[ $hook == on ]]; then
    mkdir -p "$HOME/.claude/hooks"
    install -m 755 "$REPO/script/agent_hooks/graph_mem_session_start.sh" "$HOME/.claude/hooks/graph_mem_session_start.sh"
    SETTINGS_FILE=$WORK/settings-hook.json
  else
    SETTINGS_FILE=$WORK/settings-nohook.json
  fi
  case "$mcp" in
    default) MCP_FILE=$SECRETS/mcp.json ;;
    alwaysload) MCP_FILE=$SECRETS/mcp-alwaysload.json ;;
    readonly) MCP_FILE=$SECRETS/mcp-readonly.json ;;
  esac
  note "Arm $1: rule $rule, skill $skill, hook $hook, MCP $mcp."
}

# --- Sessions --------------------------------------------------------------------------------

# "adopted turns tokens complete limited" for one log, from summarize.rb (counts only).
log_facts() {
  ruby -r "$SUMMARIZE" -e '
    m = AdoptionEval::Session.from_file(ARGV[0]).metrics
    puts [m[:adopted] ? "Y" : "N", m[:turns] || "-", m[:tokens] || "-", m[:complete], m[:limited]].join(" ")
  ' "$1"
}

run_claude_session() { # run_claude_session ARM TASK RUN LOG
  local prompt allowed=()
  prompt=$(task_prompt "$2")
  for tool in "${READ_TOOLS[@]}"; do allowed+=("mcp__graph_mem__$tool"); done
  (cd "$PROJECTS_DIR" && env -u ANTHROPIC_API_KEY timeout "${ADOPTION_SESSION_TIMEOUT:-30m}" claude -p "$prompt" \
    --model "$MODEL" --output-format stream-json --verbose \
    --mcp-config "$MCP_FILE" --strict-mcp-config --settings "$SETTINGS_FILE" \
    --permission-mode acceptEdits --allowedTools "${allowed[@]}" \
    --max-turns "$MAX_TURNS" --no-session-persistence) >"$4" 2>/dev/null </dev/null || true
}

run_cursor_session() { # run_cursor_session ARM TASK RUN LOG
  local prompt
  prompt=$(task_prompt "$2")
  rm -f "$WORK/cursor-hook-marker"
  (cd "$PROJECTS_DIR" && env -u CURSOR_API_KEY timeout "${ADOPTION_SESSION_TIMEOUT:-30m}" agent -p "$prompt" \
    --output-format stream-json --approve-mcps --trust --workspace "$PROJECTS_DIR" --sandbox enabled \
    ${CURSOR_MODEL:+--model "$CURSOR_MODEL"}) >"$4" 2>/dev/null </dev/null || true
  [[ -e $WORK/cursor-hook-marker ]] && fired=1 || fired=0
  echo "$1,$2,$3,$fired" >>"$RUN_DIR/cursor-hooks.csv"
}

TOTAL=0 DONE=0
run_sessions() {
  local arm task i log facts adopted turns tokens complete limited kind
  for arm in $ARMS; do
    kind=$(arm_spec "$arm")
    for task in $TASKS; do
      for ((i = 1; i <= N; i++)); do
        DONE=$((DONE + 1))
        log=$RUN_DIR/logs/$arm-$task-$i.jsonl
        if [[ -s $log ]] && [[ $(log_facts "$log" | cut -d' ' -f4) == true ]]; then continue; fi
        [[ -e $log ]] && mv "$log" "$log.incomplete-$(date -u +%H%M%S)"
        if [[ $kind == cursor ]]; then cursor_arm "$arm"; else apply_arm "$arm"; fi
        reset_clone "$(task_clone "$task")"
        if [[ $kind == cursor ]]; then run_cursor_session "$arm" "$task" "$i" "$log"; else run_claude_session "$arm" "$task" "$i" "$log"; fi
        read -r adopted turns tokens complete limited <<<"$(log_facts "$log")"
        if [[ $limited == true ]]; then
          mv "$log" "$log.limited"
          note "Stopped on a usage limit at [$DONE/$TOTAL]. Resume later with: script/adoption_eval/run_eval.sh --resume $RUN_ID"
          exit 75
        fi
        printf '[%d/%d] %s %s #%d adopted=%s turns=%s tokens=%s%s\n' "$DONE" "$TOTAL" "$arm" "$task" "$i" \
          "$adopted" "$turns" "$tokens" "$([[ $complete == true ]] || echo ' (no result: counted as n/a)')"
        check_guard
      done
    done
  done
}

# --- Production settings (opt-in) ------------------------------------------------------------

# Validates the keys in the app container and prints their values as JSON; refuses a field with its
# own validator, or one in a group with a cross-field check (access, review policies).
SETTINGS_READ='
  out = ARGV.to_h do |key|
    field = SettingsSchema.field(key)
    group = field && SettingsSchema.all.find { |g| g.fields.include?(field) }
    abort("ADOPTION_EVAL_ERROR=unknown setting #{key}") unless field && !field.readonly
    abort("ADOPTION_EVAL_ERROR=#{key} is in the #{group.key} group, which the eval never changes") if group.check || group.key == :access
    abort("ADOPTION_EVAL_ERROR=#{key} has its own validator; change it in Settings instead") if field.validator
    [ key, AppSettings.public_send(key) ]
  end
  puts "ADOPTION_EVAL_JSON=#{JSON.generate(out)}"'
SETTINGS_WRITE='
  ARGV.each_slice(2) do |key, raw|
    field = SettingsSchema.field(key)
    abort("ADOPTION_EVAL_ERROR=unknown setting #{key}") unless field && !field.readonly
    AppSettings.public_send("#{key}=", SettingsSchema.cast(field, raw))
  end
  AppSettings.clear_cache
  puts "ADOPTION_EVAL_OK"'

app_runner() { (cd "$REPO" && docker compose exec -T app bin/rails runner "$@") 2>&1; }

restart_app() {
  local i
  note "Restarting the app container..."
  (cd "$REPO" && docker compose restart app >/dev/null)
  for ((i = 0; i < 90; i++)); do
    server_up && [[ -n $(server_version) ]] && return 0
    sleep 2
  done
  die "graph_mem didn't come back within 3 minutes"
}

apply_settings() {
  local out json args=() i
  [[ ${#SETTING_KEYS[@]} -gt 0 ]] || return 0
  need docker
  out=$(app_runner "$SETTINGS_READ" "${SETTING_KEYS[@]}") || die "$(sed -n 's/^ADOPTION_EVAL_ERROR=//p' <<<"$out" | head -1)"
  json=$(sed -n 's/^ADOPTION_EVAL_JSON=//p' <<<"$out")
  [[ -n $json ]] || die "couldn't read the settings from the app container"
  for i in "${!SETTING_KEYS[@]}"; do
    ORIGINAL_SETTINGS+=("${SETTING_KEYS[$i]}" "$(jq -r --arg k "${SETTING_KEYS[$i]}" '.[$k] | tostring' <<<"$json")")
    args+=("${SETTING_KEYS[$i]}" "${SETTING_VALUES[$i]}")
    note "Setting ${SETTING_KEYS[$i]}: ${ORIGINAL_SETTINGS[-1]} -> ${SETTING_VALUES[$i]}"
  done
  SETTINGS_JSON=$(for i in "${!SETTING_KEYS[@]}"; do
    jq -cn --arg k "${SETTING_KEYS[$i]}" --arg b "${ORIGINAL_SETTINGS[$((i * 2 + 1))]}" --arg a "${SETTING_VALUES[$i]}" '{key: $k, before: $b, after: $a}'
  done | jq -cs .)
  note "The app container restarts now and again at the end: open MCP sessions (this one's included) close, running jobs stop."
  $ASSUME_YES || { tty_read ok "Change the settings? [y/N]" n; [[ $ok == [yY]* ]] || die "settings left unchanged"; }
  SETTINGS_CHANGED=true
  out=$(app_runner "$SETTINGS_WRITE" "${args[@]}") && grep -q ADOPTION_EVAL_OK <<<"$out" || die "writing the settings failed"
  restart_app
}

restore_settings() {
  note "Restoring the graph_mem settings..."
  app_runner "$SETTINGS_WRITE" "${ORIGINAL_SETTINGS[@]}" | grep -q ADOPTION_EVAL_OK || note "Restoring the settings failed: set them back in Settings."
  restart_app
  SETTINGS_CHANGED=false
}

# --- Cursor ----------------------------------------------------------------------------------

CURSOR_READY=false CURSOR_ARM=""
prepare_cursor() {
  $CURSOR_READY && return 0
  local allow=() tool rule_text
  if [[ $SUITE != cursor-ide ]]; then
    need agent
    until env -u CURSOR_API_KEY agent status 2>/dev/null | grep -q 'Logged in'; do
      pause "The Cursor CLI isn't logged in: run 'agent login' in another terminal."
    done
    CURSOR_VERSION=$(agent --version 2>/dev/null | head -1)
  fi
  backup_paths "${CURSOR_PATHS[@]}"
  mkdir -p "$HOME/.cursor"
  [[ -s $HOME/.cursor/mcp.json ]] || echo '{"mcpServers": {}}' >"$HOME/.cursor/mcp.json"
  # Your graph_mem entry (or the eval one) on /mcp/readonly with its own client id; the read tools
  # allowed, shell and the write tools denied.
  jq --slurpfile e "$SECRETS/entry.json" '.mcpServers.graph_mem = ((.mcpServers.graph_mem // ($e[0] | del(.type)))
    | .url |= sub("/mcp(/.*)?$"; "/mcp/readonly") | .headers["X-MCP-Client"] = "adoption-eval-cursor")' \
    "$HOME/.cursor/mcp.json" >"$WORK/cursor-mcp.json"
  cat "$WORK/cursor-mcp.json" >"$HOME/.cursor/mcp.json"
  for tool in "${READ_TOOLS[@]}"; do allow+=("Mcp(graph_mem:$tool)"); done
  [[ -s $HOME/.cursor/cli-config.json ]] || echo '{}' >"$HOME/.cursor/cli-config.json"
  jq --args '.permissions.allow = ((.permissions.allow // []) + $ARGS.positional)
    | .permissions.deny = ((.permissions.deny // []) + ["Shell(*)", "Mcp(graph_mem:graph_write)", "Mcp(graph_mem:graph_edit)", "Mcp(graph_mem:graph_delete)"])' \
    "${allow[@]}" <"$HOME/.cursor/cli-config.json" >"$WORK/cursor-cli.json"
  cat "$WORK/cursor-cli.json" >"$HOME/.cursor/cli-config.json"
  CURSOR_READY=true
  [[ $SUITE == cursor-ide ]] && pause "In the Cursor IDE, reload the MCP servers (Settings > MCP), so graph_mem uses the eval profile."
  return 0
}

# K0: nothing; K1: the User Rule (pasted by hand); K2: the sessionStart hook with a marker.
cursor_arm() {
  prepare_cursor
  [[ $1 == "$CURSOR_ARM" ]] && return 0
  if [[ $CURSOR_ARM == K1 ]]; then pause "Remove the graph_mem User Rule from Cursor (Settings > Customize > Rules)."; fi
  rm -f "$HOME/.cursor/hooks/graph_mem_session_start_cursor.sh"
  [[ -e $BACKUP/.cursor%hooks.json ]] && cp -a "$BACKUP/.cursor%hooks.json" "$HOME/.cursor/hooks.json" || rm -f "$HOME/.cursor/hooks.json"
  case "$1" in
    K1)
      note "" "Paste this into Cursor: Settings > Customize > Rules > User Rules:" ""
      sed 's/^/    /' "$REPO/docs/rules/graph_mem_user_rule.md" >&2
      pause "Paste the rule above."
      ;;
    K2)
      mkdir -p "$HOME/.cursor/hooks"
      awk -v m="GRAPH_MEM_HOOK_MARKER=\"$WORK/cursor-hook-marker\"" 'done == 0 && !/^#/ { print m; done = 1 } { print }' \
        "$REPO/script/agent_hooks/graph_mem_session_start_cursor.sh" >"$HOME/.cursor/hooks/graph_mem_session_start_cursor.sh"
      chmod 755 "$HOME/.cursor/hooks/graph_mem_session_start_cursor.sh"
      [[ -s $HOME/.cursor/hooks.json ]] || echo '{"version": 1, "hooks": {}}' >"$HOME/.cursor/hooks.json"
      jq '.version //= 1 | .hooks.sessionStart = ((.hooks.sessionStart // []) + [{"command": "./hooks/graph_mem_session_start_cursor.sh"}])' \
        "$HOME/.cursor/hooks.json" >"$WORK/cursor-hooks.json"
      cat "$WORK/cursor-hooks.json" >"$HOME/.cursor/hooks.json"
      ;;
  esac
  CURSOR_ARM=$1
  note "Arm $1 (Cursor)."
}

# The IDE calibration: the person runs each chat; the hook marker is read, three answers are asked.
run_cursor_ide() {
  local arm task i first before calls fired
  [[ -s $RUN_DIR/cursor-ide.csv ]] || echo "arm,task,run,first_gm,gm_before_edit,gm_calls,hook_fired" >"$RUN_DIR/cursor-ide.csv"
  for arm in $ARMS; do
    for task in $TASKS; do
      for ((i = 1; i <= N; i++)); do
        grep -q "^$arm,$task,$i," "$RUN_DIR/cursor-ide.csv" && continue
        cursor_arm "$arm"
        reset_clone "$(task_clone "$task")"
        rm -f "$WORK/cursor-hook-marker"
        note "" "[$arm $task #$i] In the Cursor IDE, start a NEW Agent chat (workspace: $PROJECTS_DIR) and paste:" ""
        note "    $(task_prompt "$task")" ""
        pause "When the agent has finished,"
        [[ -e $WORK/cursor-hook-marker ]] && fired=y || fired=n
        tty_read first "Was the first tool call to graph_mem? [y/n]" n
        tty_read before "Any graph_mem call before the first edit? [y/n]" n
        tty_read calls "How many graph_mem calls?" 0
        echo "$arm,$task,$i,${first:0:1},${before:0:1},$calls,$fired" >>"$RUN_DIR/cursor-ide.csv"
        check_guard
      done
    done
  done
  pause "In the Cursor IDE, remove the User Rule if it's still there."
}

# --- Q3: the timed install test --------------------------------------------------------------

run_q3() {
  local host home rc start minutes failed
  [[ -s $RUN_DIR/q3.csv ]] || echo "host,minutes,mistakes,failed" >"$RUN_DIR/q3.csv"
  for host in claude cursor; do
    grep -q "^$host," "$RUN_DIR/q3.csv" && continue
    home=$(mktemp -d "${TMPDIR:-/tmp}/adoption-q3.XXXXXX")
    mkdir -p "$home/.claude" "$home/.cursor"
    echo '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo synth-unrelated-hook"}]}]}}' >"$home/.claude/settings.json"
    echo '{"version":1,"hooks":{"sessionStart":[{"command":"echo synth-unrelated-hook"}]}}' >"$home/.cursor/hooks.json"
    rc=$WORK/q3-rc
    printf 'PS1="[q3 %s install: type exit when done] \\w\\$ "\ncd %q\nbin/agent-install --%s\n' "$host" "$REPO" "$host" >"$rc"
    pause "Install test for $host: a shell with a throwaway HOME opens. Follow the printed steps (Cursor's User Rules paste doesn't count), then type exit."
    start=$(date +%s)
    env HOME="$home" bash --rcfile "$rc" -i </dev/tty || true
    minutes=$(awk -v s="$(($(date +%s) - start))" 'BEGIN { printf "%.1f", s / 60 }')
    failed=$(q3_check "$host" "$home")
    echo "$host,$minutes,$(wc -w <<<"$failed" | tr -d ' '),${failed// /;}" >>"$RUN_DIR/q3.csv"
    note "$host: $minutes min, failed checks: ${failed:-none}"
    rm -rf "$home"
  done
}

q3_check() { # prints the failed checks
  local host=$1 home=$2 failed=() json
  if [[ $host == claude ]]; then
    [[ -f $home/.claude/skills/graph-mem-mcp-toolset/SKILL.md ]] || failed+=(skill)
    [[ -f $home/.claude/rules/graph-mem.md ]] || failed+=(rule)
    [[ -x $home/.claude/hooks/graph_mem_session_start.sh ]] || failed+=(hook-script)
    json=$home/.claude/settings.json
    jq -e . "$json" >/dev/null 2>&1 || failed+=(settings-json)
    jq -e '[.. | .command? // empty] | any(endswith("graph_mem_session_start.sh"))' "$json" >/dev/null 2>&1 || failed+=(hook-entry)
    jq -e '[.. | .command? // empty] | any(. == "echo synth-unrelated-hook")' "$json" >/dev/null 2>&1 || failed+=(unrelated-hook-lost)
    [[ -n $(HOME=$home sh "$home/.claude/hooks/graph_mem_session_start.sh" 2>/dev/null) ]] || failed+=(hook-silent)
  else
    [[ -f $home/.claude/skills/graph-mem-mcp-toolset/SKILL.md || -f $home/.cursor/skills/graph-mem-mcp-toolset/SKILL.md ]] || failed+=(skill)
    [[ -x $home/.cursor/hooks/graph_mem_session_start_cursor.sh ]] || failed+=(hook-script)
    json=$home/.cursor/hooks.json
    jq -e . "$json" >/dev/null 2>&1 || failed+=(hooks-json)
    jq -e '[.. | .command? // empty] | any(endswith("graph_mem_session_start_cursor.sh"))' "$json" >/dev/null 2>&1 || failed+=(hook-entry)
    jq -e '[.. | .command? // empty] | any(. == "echo synth-unrelated-hook")' "$json" >/dev/null 2>&1 || failed+=(unrelated-hook-lost)
  fi
  echo "${failed[*]:-}"
}

# --- Main ------------------------------------------------------------------------------------

$INTERACTIVE && [[ -r /dev/tty ]] && menu
if [[ -n $RESUME ]]; then
  RUN_DIR=$EVAL_DIR/runs/$RESUME
  [[ -f $RUN_DIR/run.json ]] || die "no run $RESUME under $EVAL_DIR/runs"
  SUITE=$(jq -r .suite "$RUN_DIR/run.json") ARMS=${ARMS:-$(jq -r '.arms | join(" ")' "$RUN_DIR/run.json")}
  TASKS=${TASKS:-$(jq -r '.tasks | join(" ")' "$RUN_DIR/run.json")} N=${N:-$(jq -r .n "$RUN_DIR/run.json")}
  MODEL=${MODEL:-$(jq -r '.model // empty' "$RUN_DIR/run.json")}
fi
suite_plan "${SUITE:=screen}"
for arm in $ARMS; do arm_spec "$arm" >/dev/null; done
for task in $TASKS; do task_prompt "$task" >/dev/null || die "unknown task: $task"; done

need git
need jq
need ruby
need curl
CLAUDE_ARMS=false
for arm in $ARMS; do [[ $(arm_spec "$arm") != cursor ]] && CLAUDE_ARMS=true; done
$CLAUDE_ARMS && need claude
[[ $SUITE == q3 ]] && ARMS="" TASKS=""
build_mcp_configs
server_up || die "graph_mem doesn't answer on $BASE_URL/up"
GM_VERSION=$(server_version)
[[ -n $GM_VERSION ]] || die "graph_mem's MCP initialize failed (check the token in your graph_mem entry)"
if $CLAUDE_ARMS; then
  [[ -n $MODEL ]] || MODEL=$(jq -r '.model // empty' "$HOME/.claude/settings.json" 2>/dev/null || true)
  [[ -n $MODEL ]] || { $ASSUME_YES && MODEL=opus || tty_read MODEL "Claude Code model alias?" opus; }
  CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1)
  [[ -n ${ANTHROPIC_API_KEY:-} ]] && note "ANTHROPIC_API_KEY is set: the runs unset it, so they use your Claude login."
fi
SESSIONS=0
for arm in $ARMS; do for task in $TASKS; do SESSIONS=$((SESSIONS + N)); done; done
TOTAL=$SESSIONS

note "" "graph_mem $GM_VERSION at $BASE_URL; suite $SUITE: ${ARMS:-install test} on ${TASKS:--}, N=$N ($SESSIONS sessions)."
for arm in $ARMS; do
  spec=$(arm_spec "$arm")
  if [[ $spec == cursor ]]; then
    note "  $arm: Cursor CLI ($([[ $arm == K0 ]] && echo nothing added || { [[ $arm == K1 ]] && echo 'the User Rule, pasted by you' || echo 'the sessionStart hook'; }))"
  else
    read -r rule skill hook mcp <<<"$spec"
    note "  $arm: rule $rule, skill $skill, hook $hook, MCP $mcp"
  fi
done
for clone in "${CLONES[@]}"; do [[ -d $PROJECTS_DIR/$clone/.git ]] || note "  $clone will be cloned."; done
[[ ${#SETTING_KEYS[@]} -gt 0 ]] && note "  settings: ${SETTING_KEYS[*]} (the app container restarts twice)"
if $DRY_RUN; then
  for arm in $ARMS; do for task in $TASKS; do for ((i = 1; i <= N; i++)); do echo "$arm $task $i"; done; done; done
  rm -rf "$SECRETS"
  exit 0
fi
if ! $ASSUME_YES; then
  tty_read ok "Start? [y/N]" n
  [[ $ok == [yY]* ]] || exit 0
fi

RUN_ID=${RESUME:-$(date -u +%Y%m%dT%H%M%SZ)}
RUN_DIR=$EVAL_DIR/runs/$RUN_ID
BACKUP=$RUN_DIR/.backup
mkdir -p "$RUN_DIR/logs" "$EVAL_DIR/reports"
chmod 700 "$EVAL_DIR" "$RUN_DIR"
trap cleanup EXIT
trap 'exit 130' INT TERM
restore_paths # a killed earlier attempt of this run left its changes: undo them first
[[ -n $RESUME ]] && rm -rf "$BACKUP"
BASELINE=$(baseline_json)
backup_paths "${USER_PATHS[@]}"
build_variants
[[ $SUITE == q3 ]] || for clone in "${CLONES[@]}"; do prepare_clone "$clone"; done
GUARD_BEFORE=$(guard_state)
SETTINGS_JSON=[]
apply_settings

clones_json=$(for clone in "${!CLONE_SHA[@]}"; do jq -cn --arg k "$clone" --arg v "${CLONE_SHA[$clone]}" '{($k): $v}'; done | jq -cs add)
jq -n --arg id "$RUN_ID" --arg suite "$SUITE" --arg arms "$ARMS" --arg tasks "$TASKS" --argjson n "$N" \
  --arg model "${MODEL:-}" --arg claude "${CLAUDE_VERSION:-}" --arg gm "$GM_VERSION" --argjson clones "$clones_json" \
  --argjson baseline "$BASELINE" --argjson settings "${SETTINGS_JSON:-[]}" --arg started "$(date -u +%FT%TZ)" \
  '{id: $id, suite: $suite, arms: ($arms | split(" ") | map(select(. != ""))), tasks: ($tasks | split(" ") | map(select(. != ""))),
    n: $n, model: $model, claude_version: $claude, graph_mem_version: $gm, clones: $clones, baseline: $baseline,
    settings: $settings, started_at: $started}' >"$RUN_DIR/run.json"

case "$SUITE" in
  q3) run_q3 ;;
  cursor-ide) run_cursor_ide ;;
  *)
    [[ -s $RUN_DIR/cursor-hooks.csv ]] || echo "arm,task,run,fired" >"$RUN_DIR/cursor-hooks.csv"
    run_sessions
    [[ $CURSOR_ARM == K1 ]] && pause "Remove the graph_mem User Rule from Cursor (Settings > Customize > Rules)."
    ;;
esac

auth=$(cat "$RUN_DIR"/logs/*.jsonl 2>/dev/null | jq -r 'select(.type == "system" and .subtype == "init") | .apiKeySource // empty' 2>/dev/null | sort -u | paste -sd, -)
jq --arg finished "$(date -u +%FT%TZ)" --arg auth "$auth" --arg cursor "${CURSOR_VERSION:-}" --arg cmodel "$CURSOR_MODEL" \
  '.finished_at = $finished | .auth = $auth | .cursor_version = $cursor | .cursor_model = $cmodel' \
  "$RUN_DIR/run.json" >"$RUN_DIR/run.json.tmp" && mv "$RUN_DIR/run.json.tmp" "$RUN_DIR/run.json"
cleanup
report=$(ruby "$REPO/script/adoption_eval/report.rb" "$RUN_DIR")
cp "$report" "$EVAL_DIR/reports/$RUN_ID-report.md"
note "" "Report: $EVAL_DIR/reports/$RUN_ID-report.md (counts only; the logs stay in $RUN_DIR)"
