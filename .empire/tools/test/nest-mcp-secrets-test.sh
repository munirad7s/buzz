#!/usr/bin/env bash
# Regression test for agent-scoped secret injection in the canonical Nest MCP config.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$TOOLS_DIR/nest-mcp.json"
HANDSHAKE="$TOOLS_DIR/mcp-handshake.js"
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

PASS=0
FAIL=0

ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
ko() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_jq() {
  local label="$1"
  local expression="$2"
  if jq -e "$expression" "$CONFIG" >/dev/null; then
    ok "$label"
  else
    ko "$label"
  fi
}

cat > "$TEST_TMP/fake-obsidian-mcp.js" <<'FAKE_MCP'
#!/usr/bin/env node
const readline = require("node:readline");

if (!process.env.OBSIDIAN_API_KEY) {
  console.error("fake-obsidian-mcp: OBSIDIAN_API_KEY is required");
  process.exitCode = 42;
  return;
}

const input = readline.createInterface({ input: process.stdin });
input.on("line", (line) => {
  const message = JSON.parse(line);
  if (message.method === "initialize") {
    process.stdout.write(`${JSON.stringify({
      jsonrpc: "2.0",
      id: message.id,
      result: {
        protocolVersion: "2025-06-18",
        capabilities: { tools: {} },
        serverInfo: { name: "fake-obsidian-mcp", version: "1" },
      },
    })}\n`);
  }
  if (message.method === "tools/list") {
    process.stdout.write(`${JSON.stringify({
      jsonrpc: "2.0",
      id: message.id,
      result: {
        tools: [{
          name: "vault_read_fixture",
          description: "Read-only fixture",
          inputSchema: { type: "object", properties: {} },
        }],
      },
    })}\n`);
  }
});
FAKE_MCP

echo "=== Static public-config contract ==="
assert_jq "Vault MCP uses the shared shim" \
  '.mcpServers["obsidian-mcp-tools"].command == "node" and
   .mcpServers["obsidian-mcp-tools"].args[0] == "C:/Users/rescue/.buzz/mcp-env-shim.js"'
assert_jq "Vault MCP allowlists only OBSIDIAN_API_KEY" \
  '.mcpServers["obsidian-mcp-tools"].args[1:4] == ["--keys", "OBSIDIAN_API_KEY", "--"]'
assert_jq "n8n MCP keeps its exact allowlist" \
  '.mcpServers["n8n-api"].args[1:4] == ["--keys", "N8N_API_URL,N8N_API_KEY", "--"]'
assert_jq "Public MCP config has no inline environment values" \
  '[.mcpServers[] | (.env // {}) | length] | all(. == 0)'

echo ""
echo "=== Real shim behavior with a controlled stdio MCP ==="
if jq -e \
  --arg fake "$TEST_TMP/fake-obsidian-mcp.js" \
  '.mcpServers["obsidian-mcp-tools"] as $server
   | select($server.command == "node")
   | select($server.args[1:4] == ["--keys", "OBSIDIAN_API_KEY", "--"])
   | {mcpServers: {"obsidian-mcp-tools": ($server | .args = (.args[0:4] + ["node", $fake]))}}' \
  "$CONFIG" > "$TEST_TMP/test-mcp.json"; then
  : > "$TEST_TMP/empty.env"
  RED_OUTPUT=$(env -u OBSIDIAN_API_KEY MCP_ENV_SHIM_FILE="$TEST_TMP/empty.env" \
    node "$HANDSHAKE" "$TEST_TMP/test-mcp.json" obsidian-mcp-tools 10)
  if [[ "$RED_OUTPUT" == FEHLER:exit-65-* ]]; then
    ok "Missing credential fails closed through the real shim"
  else
    ko "Missing credential returned unexpected status: $RED_OUTPUT"
  fi

  printf 'OBSIDIAN_API_KEY=test-only-value\n' > "$TEST_TMP/credential.env"
  GREEN_OUTPUT=$(env -u OBSIDIAN_API_KEY MCP_ENV_SHIM_FILE="$TEST_TMP/credential.env" \
    node "$HANDSHAKE" "$TEST_TMP/test-mcp.json" obsidian-mcp-tools 10)
  if [[ "$GREEN_OUTPUT" == "1" ]]; then
    ok "Allowlisted credential reaches the child without entering the config"
  else
    ko "Credential-injected handshake returned: $GREEN_OUTPUT"
  fi
else
  ko "Vault MCP entry is not shaped for secret-shim behavior"
fi

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
