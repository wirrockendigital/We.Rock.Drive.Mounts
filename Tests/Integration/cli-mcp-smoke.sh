#!/usr/bin/env bash
# Verify CLI exit policy and MCP schema rejection against the built executables.
set -euo pipefail

BIN_PATH="${1:?Pass the Swift build binary directory}"
WRDM="$BIN_PATH/wrdm"
MCP="$BIN_PATH/wrdm-mcp"
OUTPUT="$(mktemp "${TMPDIR:-/tmp}/wrdm-mcp-smoke.XXXXXX")"
trap 'rm -f "$OUTPUT"' EXIT

# Read-only CLI status must use the canonical successful JSON envelope.
"$WRDM" --json status | /usr/bin/python3 -c 'import json,sys; value=json.load(sys.stdin); assert value["ok"] is True and value["code"] == "OK"'
"$WRDM" --json app login status | /usr/bin/python3 -c 'import json,sys; value=json.load(sys.stdin); data=json.loads(value["data"]["json"]); assert value["ok"] is True and data["label"] == "com.we-rock.drive-mounts.app-login"'

# Human-readable output and invalid-command exit codes stay stable for scripts and users.
"$WRDM" status | /usr/bin/python3 -c 'import sys; value=sys.stdin.read(); assert value.startswith("OK [OK] Status loaded.")'
if "$WRDM" unknown-command >"$OUTPUT" 2>&1; then
  printf 'Unknown CLI command unexpectedly succeeded.\n' >&2
  exit 1
else
  UNKNOWN_STATUS="$?"
fi
test "$UNKNOWN_STATUS" -eq 2
/usr/bin/python3 -c 'import sys; assert open(sys.argv[1]).read().startswith("Usage: wrdm")' "$OUTPUT"

# A connectivity mutation without confirmation must be rejected before its adapter runs.
if "$WRDM" --json network wifi off >"$OUTPUT"; then
  printf 'Unconfirmed network mutation unexpectedly succeeded.\n' >&2
  exit 1
fi
/usr/bin/python3 -c 'import json,sys; value=json.load(open(sys.argv[1])); assert value["code"] == "CONFIRMATION_REQUIRED"' "$OUTPUT"

# Force recovery must always require explicit confirmation before mount adapters are reached.
if "$WRDM" --json mounts force-recover >"$OUTPUT"; then
  printf 'Unconfirmed force recovery unexpectedly succeeded.\n' >&2
  exit 1
fi
/usr/bin/python3 -c 'import json,sys; value=json.load(open(sys.argv[1])); assert value["code"] == "CONFIRMATION_REQUIRED"' "$OUTPUT"

# MCP enforces JSON-RPC structure, lifecycle negotiation, and tool input schemas.
printf '%s\n' \
  '{"jsonrpc":"2.0","id":0,"method":"tools/list","params":{}}' \
  '{' \
  '{"jsonrpc":"1.0","id":9,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":null,"method":"ping","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"status","arguments":{"unexpected":true}}}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"status","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"transfer.monitoring.status","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"mounts.force-recover","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":4,"method":"tools/list","params":{}}' \
  | "$MCP" >"$OUTPUT"

# CLI and MCP must expose equivalent canonical status envelopes and complete automation tools.
CLI_STATUS="$("$WRDM" --json status)" CLI_TRANSFER="$("$WRDM" --json transfer monitoring)" /usr/bin/python3 -c 'import json,os,sys; rows=[json.loads(line) for line in open(sys.argv[1])]; cli=json.loads(os.environ["CLI_STATUS"]); cli_transfer=json.loads(os.environ["CLI_TRANSFER"]); assert rows[0]["error"]["code"] == -32002; assert rows[1]["error"]["code"] == -32700; assert rows[2]["error"]["code"] == -32600; assert rows[3]["result"]["protocolVersion"] == "2025-11-25"; assert rows[4]["id"] is None and rows[4]["result"] == {}; assert rows[5]["result"]["isError"] is True; mcp=json.loads(rows[6]["result"]["content"][0]["text"]); assert rows[6]["result"]["isError"] is False; assert (cli["ok"],cli["code"],cli["message"],sorted(cli["data"])) == (mcp["ok"],mcp["code"],mcp["message"],sorted(mcp["data"])); mcp_transfer=json.loads(rows[7]["result"]["content"][0]["text"]); assert rows[7]["result"]["isError"] is False; assert cli_transfer["data"]["retryMode"] == mcp_transfer["data"]["retryMode"]; assert cli_transfer["data"]["maximumAutoRetries"] == mcp_transfer["data"]["maximumAutoRetries"]; force=json.loads(rows[8]["result"]["content"][0]["text"]); assert rows[8]["result"]["isError"] is True and force["code"] == "CONFIRMATION_REQUIRED"; names={tool["name"] for tool in rows[9]["result"]["tools"]}; required={"config.export","config.import","config.set","app.login.status","mounts.add","mounts.update","mounts.remove","mounts.enable","mounts.recover","mounts.force-recover","mounts.incidents","transfer.monitoring.status"}; assert required <= names' "$OUTPUT"

# Closing stdin is the local MCP client's normal abort path and must stop the server cleanly.
"$MCP" </dev/null
