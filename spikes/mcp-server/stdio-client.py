#!/usr/bin/env python3
"""Minimal stdio MCP client: newline-delimited JSON-RPC over pipes."""
import json, subprocess, sys
p = subprocess.Popen([".build/release/TimelineMCP", "--stdio"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open("server-stdio.log", "a"), text=True)
def send(msg):
    p.stdin.write(json.dumps(msg) + "\n"); p.stdin.flush()
    print(">>", json.dumps(msg)[:160])
    if "id" in msg:
        line = p.stdout.readline(); print("<<", line.strip()[:400]); return json.loads(line)
send({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"py","version":"0"}}})
send({"jsonrpc":"2.0","method":"notifications/initialized"})
r = send({"jsonrpc":"2.0","id":2,"method":"tools/list"}); print("   tools:", [t["name"] for t in r["result"]["tools"]])
r = send({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"project_describe","arguments":{}}}); v = r["result"]["structuredContent"]["version"]
r = send({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"timeline_apply","arguments":{"baseVersion":v,"commandId":"py-1","ops":[{"op":"trimClip","clipId":"a1","duration":100}]}}})
print("   apply ->", r["result"].get("structuredContent"), "isError=", r["result"].get("isError"))
r = send({"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"look_at","arguments":{}}})
img = [c for c in r["result"]["content"] if c["type"]=="image"][0]; print("   image:", img["mimeType"], len(img["data"]), "b64 chars, PNG magic ok =", img["data"].startswith("iVBORw0KGgo"))
p.stdin.close(); p.wait(timeout=5); print("server exit code", p.returncode)
