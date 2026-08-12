#!/usr/bin/env bash
# buzz#40 — legt/repariert/prueft den eigenen CODEX_HOME des Buzz-`codex`-Agenten.
#
# Warum es das Script gibt: der schlanke Agenten-Kontext liegt ausserhalb des
# (oeffentlichen) Repos unter ~/.codex-buzz. Ohne Wiederherstellungsquelle waere
# er nach einem Maschinenwechsel weg und der Agent fiele still auf Munirs
# ~/.codex zurueck — genau der Zustand, den dieses Ticket abgeschafft hat.
#
# Munirs interaktives ~/.codex wird NIE angefasst. Einzige Verbindung: auth.json
# ist ein Hardlink, damit beide dasselbe Token benutzen und ein Refresh nicht
# auseinanderlaeuft.
#
#   codex-agent-home.sh verify   (Default) — prueft, meldet, aendert nichts
#   codex-agent-home.sh setup             — legt an bzw. repariert
set -uo pipefail

MAIN_HOME="${CODEX_MAIN_HOME:-$HOME/.codex}"
AGENT_HOME="${CODEX_AGENT_HOME:-$HOME/.codex-buzz}"
SKILLS="review fix-issue deploy-check explain brain markdown-converter"
MODE="${1:-verify}"
rc=0
MCP_BLOCK_BEGIN="# >>> buzz#3 dispatcher MCP >>>"
MCP_BLOCK_END="# <<< buzz#3 dispatcher MCP <<<"

# MSYS-Pfad -> echter Windows-Pfad. Ein blosses s|/|\\|g macht aus
# /c/Users/... ein \c\Users\... — fsutil meldet dann "Datei nicht gefunden"
# und der Hardlink-Zaehler faellt still auf 1. Genau so ein stiller Fehlbefund
# waere hier der schlimmste Fall, also cygpath.
win() { cygpath -w "$1"; }

note() { printf '%s\n' "$*"; }
fail() { printf 'FEHLER: %s\n' "$*"; rc=1; }

link_count() {
  # Anzahl der Namen, die auf dieselbe Datei zeigen. 2 = Hardlink intakt.
  powershell.exe -NoProfile -Command \
    "(fsutil hardlink list '$(win "$1")' | Measure-Object -Line).Lines" 2>/dev/null | tr -d '\r'
}

install_dispatcher_mcp() {
  local config="$AGENT_HOME/config.toml"
  local begin_count end_count candidate
  begin_count="$(grep -Fxc "$MCP_BLOCK_BEGIN" "$config" 2>/dev/null || true)"
  end_count="$(grep -Fxc "$MCP_BLOCK_END" "$config" 2>/dev/null || true)"
  if [ "$begin_count" != "$end_count" ] || [ "$begin_count" -gt 1 ]; then
    fail "dispatcher-MCP-Markierungen in config.toml sind inkonsistent"
    return 1
  fi

  candidate="$(mktemp "$AGENT_HOME/config.toml.tmp.XXXXXX")"
  awk -v begin="$MCP_BLOCK_BEGIN" -v end="$MCP_BLOCK_END" '
    $0 == begin { in_block = 1; next }
    $0 == end { in_block = 0; next }
    !in_block { print }
    END { if (in_block) exit 2 }
  ' "$config" > "$candidate" || {
    rm -f -- "$candidate"
    fail "vorhandener dispatcher-MCP-Block ist unvollstaendig"
    return 1
  }

  cat >> "$candidate" <<'TOML'
# >>> buzz#3 dispatcher MCP >>>
# Agent-lokal; Credentials kommen ausschliesslich zur Laufzeit aus dem Secret-Shim.
[mcp_servers.obsidian-mcp-tools]
command = "node"
args = ["C:/Users/rescue/.buzz/mcp-env-shim.js", "--keys", "OBSIDIAN_API_KEY", "--", "C:/Users/rescue/Documents/Ai_Brain/.obsidian/plugins/mcp-tools/bin/mcp-server.exe"]
disabled_tools = ["create_vault_file", "update_active_file", "patch_vault_file", "patch_active_file", "delete_vault_file", "delete_active_file", "execute_template"]
required = true
startup_timeout_sec = 30
tool_timeout_sec = 60

[mcp_servers.n8n-api]
command = "node"
args = ["C:/Users/rescue/.buzz/mcp-env-shim.js", "--keys", "N8N_API_URL,N8N_API_KEY", "--", "C:/Users/rescue/AppData/Local/Volta/bin/n8n-mcp.cmd"]
disabled_tools = ["n8n_create_workflow", "n8n_update_full_workflow", "n8n_update_partial_workflow", "n8n_delete_workflow", "n8n_autofix_workflow", "n8n_deploy_template", "n8n_generate_workflow", "n8n_test_workflow", "n8n_manage_credentials", "n8n_manage_datatable"]
required = true
startup_timeout_sec = 60
tool_timeout_sec = 60
# <<< buzz#3 dispatcher MCP <<<
TOML

  if cmp -s "$config" "$candidate"; then
    rm -f -- "$candidate"
    return 0
  fi

  cp -- "$config" "$config.bak-buzz3-$(date +%s)" || {
    rm -f -- "$candidate"
    fail "Sicherung von config.toml fehlgeschlagen"
    return 1
  }
  mv -- "$candidate" "$config" || {
    rm -f -- "$candidate"
    fail "atomarer Austausch von config.toml fehlgeschlagen"
    return 1
  }
  note "dispatcher-MCP-Konfiguration aktualisiert"
}

verify_dispatcher_mcp() {
  local config="$AGENT_HOME/config.toml"
  local tool mcp_count shim_count
  [ -f "$config" ] || return

  mcp_count="$(grep -c '^\[mcp_servers\.' "$config" || true)"
  shim_count="$(grep -Fc 'C:/Users/rescue/.buzz/mcp-env-shim.js' "$config" || true)"
  [ "$mcp_count" = "2" ] || fail "config.toml muss genau zwei dispatcher-MCP-Server enthalten"
  [ "$shim_count" = "2" ] || fail "beide dispatcher-MCP-Server muessen den Secret-Shim nutzen"
  grep -Fq '[mcp_servers.obsidian-mcp-tools]' "$config" || fail "Vault-MCP fehlt"
  grep -Fq '[mcp_servers.n8n-api]' "$config" || fail "n8n-MCP fehlt"
  grep -Fq '"--keys", "OBSIDIAN_API_KEY", "--"' "$config" || fail "Vault-Key-Allowlist fehlt"
  grep -Fq '"--keys", "N8N_API_URL,N8N_API_KEY", "--"' "$config" || fail "n8n-Key-Allowlist fehlt"
  if grep -Eq '^[[:space:]]*env[[:space:]]*=' "$config"; then
    fail "Inline-env ist im Agenten-Home verboten; Secret-Shim verwenden"
  fi

  for tool in \
    n8n_create_workflow n8n_update_full_workflow n8n_update_partial_workflow \
    n8n_delete_workflow n8n_autofix_workflow n8n_deploy_template \
    n8n_generate_workflow n8n_test_workflow n8n_manage_credentials \
    n8n_manage_datatable create_vault_file update_active_file patch_vault_file \
    patch_active_file delete_vault_file delete_active_file execute_template; do
    [ "$(grep -Foc "\"$tool\"" "$config" || true)" = "1" ] \
      || fail "Deny-Regel fehlt oder ist doppelt: $tool"
  done
}

if [ "$MODE" = "setup" ]; then
  mkdir -p "$AGENT_HOME/skills"
  if [ ! -f "$AGENT_HOME/config.toml" ]; then
    cat > "$AGENT_HOME/config.toml" <<'TOML'
# CODEX_HOME des Buzz-`codex`-Agenten (buzz#40).
# Bewusst schlank: nur die zwei lokalen Dispatcher-MCPs, keine OAuth-Server.
# Munirs interaktiver Codex nutzt weiter ~/.codex und bleibt unberuehrt.
# auth.json ist ein Hardlink auf ~/.codex/auth.json -> ein Token, ein Refresh.

model = "gpt-5.6-sol"
model_reasoning_effort = "high"
personality = "pragmatic"
approval_policy = "never"
sandbox_mode = "danger-full-access"
service_tier = "default"
TOML
    note "config.toml angelegt"
  fi

  install_dispatcher_mcp

  # auth.json: Hardlink, kein Kopie — eine Kopie refresht nicht mit.
  if [ ! -e "$AGENT_HOME/auth.json" ] || [ "$(link_count "$AGENT_HOME/auth.json")" != "2" ]; then
    [ -e "$AGENT_HOME/auth.json" ] && mv "$AGENT_HOME/auth.json" "$AGENT_HOME/auth.json.stale-$(date +%s)"
    cmd //c "mklink /H $(win "$AGENT_HOME/auth.json") $(win "$MAIN_HOME/auth.json")" >/dev/null \
      && note "auth.json neu verlinkt" || fail "Hardlink auf auth.json fehlgeschlagen"
  fi

  for s in $SKILLS; do
    [ -e "$AGENT_HOME/skills/$s" ] && continue
    for src in "$MAIN_HOME/skills/$s" "$HOME/.agents/skills/$s"; do
      [ -e "$src" ] || continue
      powershell.exe -NoProfile -Command \
        "New-Item -ItemType Junction -Path '$(win "$AGENT_HOME/skills/$s")' -Target '$(win "$src")' | Out-Null" \
        >/dev/null 2>&1 && note "Skill verlinkt: $s"
      break
    done
  done
fi

# ── Pruefung (laeuft in beiden Modi) ─────────────────────────────────────────
[ -f "$AGENT_HOME/config.toml" ] || fail "config.toml fehlt in $AGENT_HOME"
[ -e "$AGENT_HOME/auth.json" ]   || fail "auth.json fehlt in $AGENT_HOME"

if [ -e "$AGENT_HOME/auth.json" ]; then
  n="$(link_count "$AGENT_HOME/auth.json")"
  if [ "$n" = "2" ]; then
    note "auth.json: Hardlink intakt (ein Token fuer Munir und Agent)"
  else
    fail "auth.json ist KEIN Hardlink mehr (Namen: ${n:-?}) — Token laeuft auseinander. Reparatur: $0 setup"
  fi
fi

if [ -f "$AGENT_HOME/config.toml" ]; then
  m=$(grep -c '^\[mcp_servers\.' "$AGENT_HOME/config.toml")
  p=$(grep -c '^\[plugins\.' "$AGENT_HOME/config.toml")
  note "config.toml: $m mcp_servers, $p plugins (Soll: zwei lokale MCPs, keine OAuth-Server)"
  verify_dispatcher_mcp
fi

k=$(ls -1 "$AGENT_HOME/skills" 2>/dev/null | wc -l | tr -d ' ')
[ "${k:-0}" -gt 0 ] && note "skills: $k Eintraege" || fail "skills/ ist leer — Agent saehe keine Skills"

# Der Agent liest CODEX_HOME aus seinem Buzz-Agent-Record.
REC="$APPDATA/xyz.block.buzz.app/agents/managed-agents.json"
if [ -f "$REC" ]; then
  if grep -q 'CODEX_HOME' "$REC"; then
    note "Agent-Record: CODEX_HOME gesetzt"
  else
    fail "Agent-Record hat kein CODEX_HOME — der Agent faellt auf Munirs ~/.codex zurueck"
  fi
fi

[ $rc -eq 0 ] && note "OK" || note "NICHT OK"
exit $rc
