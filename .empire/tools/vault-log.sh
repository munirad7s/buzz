#!/usr/bin/env bash
# vault-log.sh — Buzz-Agenten schreiben ins geteilte Gedächtnis (buzz#11).
#
# Hängt EINEN Bullet an die heutige Ai_Brain-Tagesnotiz an. Append-only, UTF-8,
# kein git. Der Sync macht obsidian-git — nie selbst committen oder pushen.
#
#   bash ~/.buzz/vault-log.sh <AgentName> "<was> — <Ergebnis/Blocker>"
#
# Mehrere Bullets = mehrere Aufrufe (1–3 pro Session, keine Transkripte).
set -euo pipefail

VAULT="${AI_BRAIN_VAULT:-/c/Users/rescue/Documents/Ai_Brain}"

agent="${1:-}"
shift || true
text="$*"

if [ -z "$agent" ] || [ -z "$text" ]; then
  echo "usage: bash ~/.buzz/vault-log.sh <AgentName> \"<was> — <Ergebnis/Blocker>\"" >&2
  exit 1
fi
if [ ! -d "$VAULT" ]; then
  echo "vault not found: $VAULT" >&2
  exit 1
fi

day="$(date +%Y-%m-%d)"
note="$VAULT/01 Journal/$(date +%Y-%m)/$day.md"
mkdir -p "$(dirname "$note")"

if [ ! -f "$note" ]; then
  printf -- '---\ntype: journal\nstatus: active\ncreated: %s\ntags:\n  - journal\n  - daily\n---\n# %s\n\n' "$day" "$day" > "$note"
fi

# Nie an eine Zeile ohne Zeilenende ankleben.
[ -s "$note" ] && [ "$(tail -c 1 "$note" | od -An -c | tr -d ' ')" != '\n' ] && printf '\n' >> "$note"

line="- 🐝 $agent: $text"
printf '%s\n' "$line" >> "$note"

printf 'appended -> %s\n%s\n' "$note" "$line"
