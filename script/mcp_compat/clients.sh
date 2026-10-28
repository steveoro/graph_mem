#!/usr/bin/env bash
# SDK client matrix (mcp-update-plan §3.1 step 4): TS client 2.3.1 and Ruby SDK 1.8.1 and 1.8.2, each
# in `auto` and `legacy` mode, against graph_mem over stdio and Streamable HTTP. All twelve must
# connect and list tools; the stdio `auto` timing shows the cost of the server/discover probe process.
#
# Usage (from the graph_mem checkout, with a server already listening for the HTTP rows):
#   script/mcp_compat/clients.sh http://127.0.0.1:3999/mcp
#
# Env:
#   STDIO_CMD  stdio server command (default: graph_mem's runner through its RVM gemset wrapper)
#   RSDK_RUBY      Ruby with gems mcp + faraday (default: the ruby-3.4.12@mcp_compat RVM wrapper)
#   RSDK_VERSIONS  Ruby SDK versions to run (default: "1.8.1 1.8.2")
#   MCP_TOKEN  bearer token for the HTTP rows, if the server requires one
# The stdio rows inherit RAILS_ENV/OLLAMA_URL; the defaults below keep them off real services.
set -uo pipefail

URL="${1:?usage: clients.sh <mcp-url>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
export RAILS_ENV="${RAILS_ENV:-test}" OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:9}"
STDIO_CMD="${STDIO_CMD:-$HOME/.rvm/wrappers/ruby-3.4.12@graph_mem/bundle exec ruby bin/mcp_stdio_runner.rb}"
RSDK_RUBY="${RSDK_RUBY:-$HOME/.rvm/wrappers/ruby-3.4.12@mcp_compat/ruby}"
RSDK_VERSIONS="${RSDK_VERSIONS:-1.8.1 1.8.2}"
FAILS=0
ROWS=0

[[ -d "$HERE/tsclient/node_modules" ]] || (cd "$HERE/tsclient" && npm ci --no-audit --no-fund >/dev/null)

run() { ROWS=$((ROWS + 1)); timeout 120 "$@" || FAILS=$((FAILS + 1)); }

for mode in auto legacy; do
  # shellcheck disable=SC2086 # STDIO_CMD is a command line on purpose
  run node "$HERE/tsclient/tsclient.mjs" stdio "$mode" -- $STDIO_CMD
  run node "$HERE/tsclient/tsclient.mjs" http "$mode" "$URL"
  for version in $RSDK_VERSIONS; do
    # shellcheck disable=SC2086
    RSDK_VERSION="$version" run "$RSDK_RUBY" "$HERE/rsdk_client.rb" stdio "$mode" -- $STDIO_CMD
    RSDK_VERSION="$version" run "$RSDK_RUBY" "$HERE/rsdk_client.rb" http "$mode" "$URL"
  done
done

echo "== $FAILS failed of $ROWS"
[[ $FAILS -eq 0 ]]
