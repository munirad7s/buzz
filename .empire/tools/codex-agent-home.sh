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

if [ "$MODE" = "setup" ]; then
  mkdir -p "$AGENT_HOME/skills"
  if [ ! -f "$AGENT_HOME/config.toml" ]; then
    cat > "$AGENT_HOME/config.toml" <<'TOML'
# CODEX_HOME des Buzz-`codex`-Agenten (buzz#40).
# Bewusst schlank: keine OAuth-MCP-Server, keine Plugin-Marketplaces.
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
  note "config.toml: $m mcp_servers, $p plugins (Soll: bewusst wenige, keine OAuth-Server)"
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
