#!/usr/bin/env bash
# MCP Streamable HTTP probe (mcp-update-plan §3.0 "Streamable HTTP" table + §3.1 Oct 22 additions).
#
# Usage: http_probe.sh http://127.0.0.1:<port>/mcp [--reference]
#
# Sends synthetic, read-only JSON-RPC traffic (initialize, ping, tools/list, get_current_time) and
# checks each answer against the "graph_mem after PR-2" column. --reference only prints the
# answers (for the v2.0.0 Everything server, whose expectations differ). Needs curl and jq.
# Run it against a local dev/test instance, never production. Exit 1 when a check fails.
#
# Env: MCP_TOKEN (sends Authorization: Bearer), MCP_CLIENT (X-MCP-Client, default mcp-compat-probe).
set -uo pipefail

URL="${1:?usage: http_probe.sh <mcp-url> [--reference]}"
MODE="${2:-check}"
CLIENT="${MCP_CLIENT:-mcp-compat-probe}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILS=0

BASE_HEADERS=(-H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" -H "X-MCP-Client: $CLIENT")
[[ -n "${MCP_TOKEN:-}" ]] && BASE_HEADERS+=(-H "Authorization: Bearer $MCP_TOKEN")

MODERN_META='"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"io.modelcontextprotocol/clientInfo":{"name":"mcp-compat-probe","version":"0"}}'

# post BODY [extra curl args...] -> sets STATUS, BODY_OUT (first JSON object of a JSON or SSE reply), HDRS
post() {
  local body="$1"; shift
  STATUS=$(curl -s -o "$TMP/body" -D "$TMP/hdrs" -w '%{http_code}' -X POST "${BASE_HEADERS[@]}" "$@" \
    --data-binary "$body" "$URL")
  HDRS="$(tr -d '\r' < "$TMP/hdrs")"
  if grep -q '^data: ' "$TMP/body"; then
    BODY_OUT="$(grep -m1 '^data: ' "$TMP/body" | sed 's/^data: //')"
  else
    BODY_OUT="$(cat "$TMP/body")"
  fi
}

session_header() { grep -i '^mcp-session-id:' <<<"$HDRS" | head -1 | cut -d' ' -f2; }

# check NAME EXPECTED_STATUS JQ_FILTER — the filter must print "true" on BODY_OUT.
check() {
  local name="$1" want="$2" filter="$3" got
  # An empty body (e.g. a 202) is checked as null.
  got=$(jq -c "$filter" <<<"${BODY_OUT:-null}" 2>/dev/null || echo "jq-error")
  local line
  line=$(printf '%-58s %s %s' "$name" "$STATUS" "$(head -c 160 <<<"$BODY_OUT")")
  if [[ "$MODE" == "--reference" ]]; then echo "  $line"; return; fi
  if [[ "$STATUS" == "$want" && "$got" == "true" ]]; then
    echo "PASS $line"
  else
    echo "FAIL $line   (want $want, $filter)"
    FAILS=$((FAILS + 1))
  fi
}

init_body() {
  printf '{"jsonrpc":"2.0","id":%s,"method":"initialize","params":{"protocolVersion":"%s","capabilities":{},"clientInfo":{"name":"mcp-compat-probe","version":"0"}}}' "$1" "$2"
}

new_session() {
  post "$(init_body 1 2025-11-25)"
  SID="$(session_header)"
  post '{"jsonrpc":"2.0","method":"notifications/initialized"}' -H "Mcp-Session-Id: $SID" -H "MCP-Protocol-Version: 2025-11-25"
}

end_session() { curl -s -o /dev/null -X DELETE "${BASE_HEADERS[@]}" -H "Mcp-Session-Id: $1" "$URL"; }

echo "== $URL"

# --- 2026-07-28 traffic (falls back; MG-5 changes these rows) ---
post "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"server/discover\",\"params\":{$MODERN_META}}" -H "MCP-Protocol-Version: 2026-07-28"
check "discover + envelope + 2026-07-28 header -> 4xx with id" 400 '.id == 11 and (.error.code | type) == "number"'
[[ "$MODE" != "--reference" && -n "$(session_header)" ]] && { echo "FAIL   ...and it opened a session"; FAILS=$((FAILS + 1)); }

post '{"jsonrpc":"2.0","id":12,"method":"tools/list","params":{}}' -H "MCP-Protocol-Version: 2026-07-28"
check "modern header, no envelope -> 400 + id" 400 '.id == 12 and .error.code == -32600'
post "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"tools/list\",\"params\":{$MODERN_META}}" -H "MCP-Protocol-Version: 2025-11-25"
check "header != envelope -> 400 + id" 400 '.id == 13 and .error.code == -32600'
post "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2027-01-01\"}}}" -H "MCP-Protocol-Version: 2027-01-01"
check "future revision -> 400 + id" 400 '.id == 14 and .error.code == -32600'

# --- initialize ---
post "$(init_body 20 2025-11-25)" -H "MCP-Protocol-Version: 2026-07-28"
check "initialize + modern header -> 200, 2025-11-25 (lenient)" 200 '.result.protocolVersion == "2025-11-25"'
end_session "$(session_header)"
for pair in 2026-07-28:2025-11-25 2025-11-25:2025-11-25 2025-06-18:2025-06-18 2025-03-26:2025-03-26 2024-11-05:2024-11-05 9:2025-11-25; do
  asked="${pair%%:*}"; answered="${pair##*:}"
  post "$(init_body 21 "$asked")"
  check "initialize $asked -> $answered" 200 ".result.protocolVersion == \"$answered\""
  end_session "$(session_header)"
done
post "$(init_body 22 2025-11-25)"
check "initialize capabilities: subscribe/listChanged false" 200 \
  '.result.capabilities.resources.subscribe == false and .result.capabilities.resources.listChanged == false and .result.capabilities.tools.listChanged == false'
end_session "$(session_header)"

# --- in session ---
new_session
post '{"jsonrpc":"2.0","id":30,"method":"ping"}' -H "Mcp-Session-Id: $SID"
check "in session, no MCP-Protocol-Version -> 200" 200 '.id == 30 and .result == {}'
post '{"jsonrpc":"2.0","id":31,"method":"ping"}' -H "Mcp-Session-Id: $SID" -H "MCP-Protocol-Version: 1999-01-01"
check "in session, header 1999-01-01 -> 400 -32000" 400 '.id == 31 and .error.code == -32000'
post '{"jsonrpc":"2.0","id":32,"method":"ping"}' -H "Mcp-Session-Id: $SID" -H "MCP-Protocol-Version: 2026-07-28"
check "in session, header 2026-07-28 -> 400 -32000" 400 '.id == 32 and .error.code == -32000'
post '{"jsonrpc":"2.0","id":33,"method":"tools/list"}' -H "Mcp-Session-Id: $SID" -H "MCP-Protocol-Version: 2025-11-25"
check "in session, tools/list -> tools" 200 '.id == 33 and (.result.tools | length) > 0'
post '{"jsonrpc":"2.0","id":34,"method":"resources/subscribe","params":{"uri":"memory_graph"}}' -H "Mcp-Session-Id: $SID"
check "resources/subscribe -> -32601" 200 '.id == 34 and .error.code == -32601'
post '{"jsonrpc":"2.0","id":null,"method":"tools/call","params":{"name":"get_current_time","arguments":{}}}' -H "Mcp-Session-Id: $SID"
check "\"id\": null tools/call -> 400 -32600" 400 '.error.code == -32600'
post '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"get_current_time","arguments":{}}}' -H "Mcp-Session-Id: $SID"
check "id-less tools/call -> 202, no body" 202 '. == null'
post $'{"jsonrpc":"2.0","id":35,"method":"ping","params":{"\xff":1}}' -H "Mcp-Session-Id: $SID"
check "invalid UTF-8 object key -> 400 -32700" 400 '.error.code == -32700'
post '[{"jsonrpc":"2.0","id":36,"method":"ping"}]' -H "Mcp-Session-Id: $SID"
check "JSON array body -> 400 -32600" 400 '.error.code == -32600'
post '{"id":37,"method":"ping"}' -H "Mcp-Session-Id: $SID"
check "missing jsonrpc -> 400 -32600, id echoed" 400 '.id == 37 and .error.code == -32600'
post '{"jsonrpc":"2.0","id":38,"method":' -H "Mcp-Session-Id: $SID"
check "parse error -> 400 -32700" 400 '.error.code == -32700'
head -c $((5 * 1024 * 1024)) /dev/zero | tr '\0' a | sed 's/^/{"jsonrpc":"2.0","id":39,"method":"ping","params":{"x":"/;s/$/"}}/' > "$TMP/big.json"
post "@$TMP/big.json" -H "Mcp-Session-Id: $SID"
check "5 MiB body -> 413" 413 '.error.code == -32600'

# One GET stream per session: hold the first open, the second gets 409.
curl -s -N -o /dev/null -m 4 "${BASE_HEADERS[@]}" -H "Accept: text/event-stream" -H "Mcp-Session-Id: $SID" "$URL" &
first_get=$!
sleep 1
STATUS=$(curl -s -o "$TMP/body" -m 3 -w '%{http_code}' "${BASE_HEADERS[@]}" -H "Accept: text/event-stream" -H "Mcp-Session-Id: $SID" "$URL")
BODY_OUT="$(cat "$TMP/body")"
check "second GET stream on one session -> 409" 409 '.error.code == -32000'
kill "$first_get" 2>/dev/null; wait "$first_get" 2>/dev/null
end_session "$SID"

# --- no / unknown session ---
post '{"jsonrpc":"2.0","id":40,"method":"ping"}' -H "Mcp-Session-Id: mcp-compat-no-such-session"
check "unknown session -> 404, id echoed" 404 '.id == 40 and .error.code == -32001'
post '{"jsonrpc":"2.0","id":41,"method":"tools/list"}'
check "session-less non-initialize -> 400 + id" 400 '.id == 41'

if [[ "$MODE" != "--reference" ]]; then
  echo "== $FAILS failed"
  [[ $FAILS -eq 0 ]]
fi
