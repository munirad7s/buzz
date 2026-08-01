#!/usr/bin/env bash
# nest-doctor.sh — beweist, welche MCP-Werkzeuge die Buzz-Nest-Agenten WIRKLICH haben (buzz#59).
#
# Warum es das gibt: in buzz#3 kam heraus, dass die in #4/#5/#6 "verdrahteten" MCP-Server
# fuer die Agenten lautlos nicht vorhanden waren — `.mcp.json` war gepflegt, die Freigabe in
# `~/.claude.json` fehlte, `claude mcp list` sagte "Pending approval", und in der Session
# existierte kein einziges `mcp__<server>__*`-Tool. Kein Fehler, kein Log. Drei Tickets galten
# als erledigt, das Werkzeug fehlte trotzdem.
#
# Vier Schichten, jede kann rot werden:
#   SOLL      .empire/tools/nest-mcp.json                  (Repo-Kanon)
#   IST-CFG   ~/.buzz/.mcp.json                            (was der Nest anbietet)
#   FREIGABE  ~/.claude.json projects[<nest>].hasTrustDialogAccepted + enableAllProjectMcpServers
#   LAUFZEIT  echter stdio-Handshake je Server (initialize + tools/list)
#   PROZESS   mtime .mcp.json vs. Startzeit der buzz-acp-Prozesse
#
# Exit-Codes beantworten nur die ERHEBUNG, nicht die Lage:
#   0 = alle Schichten deckungsgleich · 1 = Drift gefunden · 2 = Erhebung tot (Quelle unlesbar)
set -uo pipefail

NEST_DIR="${NEST_DIR:-$HOME/.buzz}"
NEST_KEY="${NEST_KEY:-C:/Users/rescue/.buzz}"
CLAUDE_JSON="${CLAUDE_JSON:-$HOME/.claude.json}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOLL_FILE="${SOLL_FILE:-$SCRIPT_DIR/nest-mcp.json}"
FORMAT="md"
MIN_TOOLS="${NEST_DOCTOR_MIN_TOOLS:-1}"
HANDSHAKE_TIMEOUT="${NEST_DOCTOR_TIMEOUT:-60}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --format) FORMAT="${2:-md}"; shift 2 ;;
    --format=*) FORMAT="${1#*=}"; shift ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "nest-doctor: unbekanntes Argument $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { echo "nest-doctor: jq fehlt"; exit 2; }
command -v node >/dev/null || { echo "nest-doctor: node fehlt"; exit 2; }

MCP_JSON="$NEST_DIR/.mcp.json"
[[ -r "$MCP_JSON" ]]     || { echo "nest-doctor: FEHLER — $MCP_JSON nicht lesbar"; exit 2; }
[[ -r "$CLAUDE_JSON" ]]  || { echo "nest-doctor: FEHLER — $CLAUDE_JSON nicht lesbar"; exit 2; }

sorted_keys() { jq -r '.mcpServers // {} | keys[]' "$1" 2>/dev/null | tr -d '\r' | sort; }

IST_CFG="$(sorted_keys "$MCP_JSON")"
[[ -n "$IST_CFG" ]] || { echo "nest-doctor: FEHLER — $MCP_JSON enthaelt keine mcpServers"; exit 2; }

if [[ -r "$SOLL_FILE" ]]; then
  SOLL="$(sorted_keys "$SOLL_FILE")"
  SOLL_STATUS="gelesen"
else
  SOLL=""
  SOLL_STATUS="NICHT LESBAR"
fi

ENABLED="$(jq -r --arg k "$NEST_KEY" '.projects[$k].enabledMcpjsonServers // [] | .[]' "$CLAUDE_JSON" 2>/dev/null | tr -d '\r' | sort)"
DISABLED="$(jq -r --arg k "$NEST_KEY" '.projects[$k].disabledMcpjsonServers // [] | .[]' "$CLAUDE_JSON" 2>/dev/null | tr -d '\r' | sort)"
TRUSTED="$(jq -r --arg k "$NEST_KEY" '.projects[$k].hasTrustDialogAccepted // false' "$CLAUDE_JSON" 2>/dev/null | tr -d '\r')"
HAS_PROJECT="$(jq -r --arg k "$NEST_KEY" 'if (.projects | has($k)) then "ja" else "nein" end' "$CLAUDE_JSON" 2>/dev/null | tr -d '\r')"

# `enableAllProjectMcpServers` wirkt NUR, wenn das Projekt getraut ist (in buzz#59 als Rot-Probe gemessen:
# `hasTrustDialogAccepted: false` -> alle Nest-Server sofort wieder "Pending approval").
ENABLE_ALL="false"
for f in "$NEST_DIR/.claude/settings.json" "$NEST_DIR/.claude/settings.local.json"; do
  [[ -r "$f" ]] || continue
  [[ "$(jq -r '.enableAllProjectMcpServers // false' "$f" 2>/dev/null | tr -d '\r')" == "true" ]] && ENABLE_ALL="true"
done

# --- Laufzeit: echter stdio-Handshake je Server ------------------------------
handshake() { # $1 = servername -> "<toolcount>" oder "FEHLER:<grund>"
  node "$SCRIPT_DIR/mcp-handshake.js" "$MCP_JSON" "$1" "$HANDSHAKE_TIMEOUT" 2>/dev/null || echo "FEHLER:node"
}

# --- Prozess-Drift ----------------------------------------------------------
CFG_MTIME="$(date -r "$MCP_JSON" +%s 2>/dev/null || echo 0)"
OLDEST_ACP=""
DRIFT_PROC="unbekannt"
if command -v powershell.exe >/dev/null 2>&1; then
  OLDEST_ACP="$(powershell.exe -NoProfile -Command \
    "\$p = Get-Process buzz-acp -ErrorAction SilentlyContinue; if (\$p) { (\$p | Sort-Object StartTime | Select-Object -First 1).StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }" \
    2>/dev/null | tr -d '\r' | head -1)"
fi
if [[ -n "$OLDEST_ACP" ]]; then
  PROC_EPOCH="$(date -d "$OLDEST_ACP" +%s 2>/dev/null || echo 0)"
  if [[ "$PROC_EPOCH" -gt 0 && "$CFG_MTIME" -gt "$PROC_EPOCH" ]]; then
    DRIFT_PROC="ja"
  elif [[ "$PROC_EPOCH" -gt 0 ]]; then
    DRIFT_PROC="nein"
  fi
elif [[ -n "${OLDEST_ACP+x}" ]]; then
  DRIFT_PROC="keine-agenten"
fi

# --- Auswertung -------------------------------------------------------------
EXIT=0
ROWS=""
JSON_SERVERS="[]"
ALL="$(printf '%s\n%s\n%s\n' "$SOLL" "$IST_CFG" "$ENABLED" | grep -v '^$' | sort -u)"

for name in $ALL; do
  in_soll=nein; in_cfg=nein; in_enabled=nein
  grep -qx "$name" <<<"$SOLL"    && in_soll=ja
  grep -qx "$name" <<<"$IST_CFG" && in_cfg=ja
  if grep -qx "$name" <<<"$DISABLED"; then
    in_enabled=nein
  elif [[ "$TRUSTED" == "true" && ( "$ENABLE_ALL" == "true" || -n "$(grep -x "$name" <<<"$ENABLED")" ) ]]; then
    in_enabled=ja
  fi

  if [[ "$in_cfg" == ja ]]; then
    hs="$(handshake "$name")"
  else
    hs="-"
  fi

  status="ok"
  if [[ "$in_cfg" == ja && "$in_enabled" == nein ]]; then
    status="NICHT FREIGEGEBEN (Pending approval — der Agent hat das Werkzeug nicht)"
  elif [[ "$in_cfg" == nein ]]; then
    status="fehlt in .mcp.json"
  elif [[ "$hs" == FEHLER:* ]]; then
    status="HANDSHAKE $hs"
  elif [[ "$hs" =~ ^[0-9]+$ && "$hs" -lt "$MIN_TOOLS" ]]; then
    status="0 Tools — Server antwortet, liefert aber nichts"
  elif [[ "$in_soll" == nein && "$SOLL_STATUS" == gelesen ]]; then
    status="nicht im Repo-Kanon (nest-mcp.json nachziehen)"
  fi
  [[ "$status" == ok ]] || EXIT=1

  ROWS+="| \`$name\` | $in_soll | $in_cfg | $in_enabled | $hs | $status |"$'\n'
  JSON_SERVERS="$(jq -c --arg n "$name" --arg s "$in_soll" --arg c "$in_cfg" --arg e "$in_enabled" \
    --arg h "$hs" --arg st "$status" '. + [{name:$n, soll:$s, in_mcp_json:$c, enabled:$e, handshake:$h, status:$st}]' <<<"$JSON_SERVERS")"
done

[[ "$HAS_PROJECT" == "ja" ]] || EXIT=1
[[ "$TRUSTED" == "true" ]]   || EXIT=1
[[ "$DRIFT_PROC" == "ja" ]]  && EXIT=1
[[ "$SOLL_STATUS" == "gelesen" ]] || EXIT=1

if [[ "$FORMAT" == "json" ]]; then
  jq -n --argjson servers "$JSON_SERVERS" \
        --arg project "$HAS_PROJECT" --arg trusted "$TRUSTED" \
        --arg soll "$SOLL_STATUS" --arg drift "$DRIFT_PROC" \
        --arg oldest "$OLDEST_ACP" --argjson exit "$EXIT" \
    '{generated_at: (now|todate), nest_project_entry:$project, trust_accepted:$trusted,
      repo_kanon:$soll, process_drift:$drift, oldest_buzz_acp_start:$oldest,
      servers:$servers, exit:$exit}'
else
  echo "## Nest-Doctor — Werkzeugbestand der Buzz-Agenten"
  echo
  echo "Nest: \`$NEST_DIR\` · Projekt-Key: \`$NEST_KEY\` · Repo-Kanon: $SOLL_STATUS"
  echo
  echo "| Server | im Kanon | in .mcp.json | freigegeben | Tools (Handshake) | Status |"
  echo "|---|---|---|---|---|---|"
  printf '%s' "$ROWS"
  echo
  echo "- Projekt-Eintrag in \`~/.claude.json\`: **$HAS_PROJECT** · \`hasTrustDialogAccepted\`: **$TRUSTED** · \`enableAllProjectMcpServers\`: **$ENABLE_ALL**"
  echo "- Aeltester \`buzz-acp\`-Prozessstart: ${OLDEST_ACP:-unbekannt} · Config neuer als Prozess: **$DRIFT_PROC**"
  [[ "$DRIFT_PROC" == "ja" ]] && echo "  - ⚠️ Die Agenten laufen mit dem ALTEN Werkzeugkasten — MCP-Config wird beim Prozessstart gelesen. Agent im Desktop stoppen/starten."
  echo
  echo "Exit $EXIT (0 = deckungsgleich · 1 = Drift · 2 = Erhebung tot). **Exit 0 heisst nicht \"alles gut\", sondern \"alle vier Schichten sagen dasselbe\".**"
fi

exit "$EXIT"
