#!/usr/bin/env bash
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/buzz-codex-dispatcher.XXXXXX")"
MAIN_HOME="$TEST_ROOT/main"
AGENT_HOME="$TEST_ROOT/agent"
TEST_APPDATA="$TEST_ROOT/appdata"

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$MAIN_HOME" "$AGENT_HOME" "$TEST_APPDATA"
printf '{"test_only":true}\n' > "$MAIN_HOME/auth.json"
printf '%s\n' \
  'model = "test-model"' \
  'unrelated_setting = "preserve-me"' \
  > "$AGENT_HOME/config.toml"

run_setup() {
  CODEX_MAIN_HOME="$MAIN_HOME" \
  CODEX_AGENT_HOME="$AGENT_HOME" \
  APPDATA="$TEST_APPDATA" \
    bash "$TOOLS_DIR/codex-agent-home.sh" setup >/dev/null
}

run_setup
first_hash="$(sha256sum "$AGENT_HOME/config.toml" | awk '{print $1}')"
run_setup
second_hash="$(sha256sum "$AGENT_HOME/config.toml" | awk '{print $1}')"

test "$first_hash" = "$second_hash"
grep -Fqx 'unrelated_setting = "preserve-me"' "$AGENT_HOME/config.toml"
test "$(grep -c '^\[mcp_servers\.' "$AGENT_HOME/config.toml")" -eq 2
test "$(grep -Fc 'C:/Users/rescue/.buzz/mcp-env-shim.js' "$AGENT_HOME/config.toml")" -eq 2
grep -Fq '[mcp_servers.obsidian-mcp-tools]' "$AGENT_HOME/config.toml"
grep -Fq '[mcp_servers.n8n-api]' "$AGENT_HOME/config.toml"
grep -Fq '"--keys", "OBSIDIAN_API_KEY", "--"' "$AGENT_HOME/config.toml"
grep -Fq '"--keys", "N8N_API_URL,N8N_API_KEY", "--"' "$AGENT_HOME/config.toml"
! grep -Eq '^[[:space:]]*env[[:space:]]*=' "$AGENT_HOME/config.toml"

denied_tools=(
  n8n_create_workflow
  n8n_update_full_workflow
  n8n_update_partial_workflow
  n8n_delete_workflow
  n8n_autofix_workflow
  n8n_deploy_template
  n8n_generate_workflow
  n8n_test_workflow
  n8n_manage_credentials
  n8n_manage_datatable
  create_vault_file
  update_active_file
  patch_vault_file
  patch_active_file
  delete_vault_file
  delete_active_file
  execute_template
)

for tool in "${denied_tools[@]}"; do
  test "$(grep -Foc "\"$tool\"" "$AGENT_HOME/config.toml")" -eq 1
done

CODEX_MAIN_HOME="$MAIN_HOME" \
CODEX_AGENT_HOME="$AGENT_HOME" \
APPDATA="$TEST_APPDATA" \
  bash "$TOOLS_DIR/codex-agent-home.sh" verify >/dev/null

printf 'codex dispatcher MCP config: OK\n'
