#!/bin/zsh
# Streamable HTTP transcript against the spike server. Usage: ./curl-transcript.sh [port]
P=${1:-8765}; U="http://127.0.0.1:$P/mcp"
H=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H "Origin: http://127.0.0.1:$P")
post() { # $1 = label, $2 = json, rest = extra headers
  local label=$1 json=$2; shift 2
  echo "\n### $label\nPOST $U\n$json"
  curl -s --retry 15 --retry-connrefused --retry-delay 1 -D /tmp/tl-hdr.txt "${H[@]}" "$@" -d "$json" "$U" | cut -c1-600
  echo; grep -i -E '^(HTTP|mcp-session-id|content-type)' /tmp/tl-hdr.txt | tr -d '\r'
}
post "initialize" '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'
SID=$(grep -i '^mcp-session-id' /tmp/tl-hdr.txt | awk '{print $2}' | tr -d '\r'); echo "SESSION=$SID"
S=(-H "Mcp-Session-Id: $SID" -H 'MCP-Protocol-Version: 2025-06-18')
post "notifications/initialized" '{"jsonrpc":"2.0","method":"notifications/initialized"}' "${S[@]}"
post "tools/list" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' "${S[@]}"
post "tools/call project_describe" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"project_describe","arguments":{}}}' "${S[@]}"
post "tools/call timeline_apply (base 1, cmd A)" '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"timeline_apply","arguments":{"baseVersion":1,"commandId":"cmd-A","ops":[{"op":"moveClip","clipId":"c1","start":120}]}}}' "${S[@]}"
post "tools/call timeline_apply RETRY same cmd A (idempotent)" '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"timeline_apply","arguments":{"baseVersion":1,"commandId":"cmd-A","ops":[{"op":"moveClip","clipId":"c1","start":120}]}}}' "${S[@]}"
post "tools/call timeline_apply STALE base 1, cmd B" '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"timeline_apply","arguments":{"baseVersion":1,"commandId":"cmd-B","ops":[{"op":"trimClip","clipId":"c2","duration":30}]}}}' "${S[@]}"
post "tools/call look_at" '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"look_at","arguments":{}}}' "${S[@]}"
echo "\n### Origin check (evil origin)"; curl -s -o /dev/null -w 'HTTP %{http_code}\n' -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H 'Origin: http://evil.example' -d '{"jsonrpc":"2.0","id":9,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"x","version":"0"}}}' "$U"
echo "### DELETE session"; curl -s -o /dev/null -w 'HTTP %{http_code}\n' -X DELETE "${S[@]}" "$U"
