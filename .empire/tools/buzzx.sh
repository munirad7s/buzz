#!/usr/bin/env bash
# .empire/tools/buzzx.sh — Buzz-CLI headless, mit Schluessel aus dem Windows-Credential-Store.
#
# Warum: `buzz.exe` braucht BUZZ_PRIVATE_KEY. Der Desktop hat die Identitaet
# 2026 in den Credential Manager migriert (`identity.migrated`), es liegt kein
# Key mehr als Datei herum. Ohne diesen Umweg ist der Relay fuer Agenten tot.
#
# Aufruf:
#   .empire/tools/buzzx.sh [--key identity|agent:<hex>] -- <buzz-cli args...>
#   BUZZ_KEY=agent:ef01... .empire/tools/buzzx.sh channels list
#
# Der Schluessel wird NIE ausgegeben, nie in eine Datei geschrieben und nie
# als Argument uebergeben — nur als Prozess-Env innerhalb von buzzx.ps1.
# Argumente gehen zeilenweise ueber eine UTF-8-Datei an PowerShell, weil
# PowerShell 5.1 sonst Multibyte-Argumente verstuemmelt (gemessene Falle).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PS1_FILE="$HERE/buzzx.ps1"
KEY="${BUZZ_KEY:-identity}"
RELAY="${BUZZ_RELAY_URL:-https://adaswin.communities.buzz.xyz}"

while [ $# -gt 0 ]; do
  case "$1" in
    --key) KEY="$2"; shift 2 ;;
    --relay) RELAY="$2"; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

if [ $# -eq 0 ]; then
  echo "usage: buzzx.sh [--key identity|agent:<hex>] [--relay URL] -- <buzz args...>" >&2
  exit 1
fi

# Jedes Argument geht base64-kodiert (UTF-8) durch: mehrzeilige YAML-Bodies und
# Umlaute ueberleben so sowohl die MSYS-Argumentkonvertierung als auch
# PowerShell 5.1. Dieselbe Falle wie bei curl (-d "$(...)" vs --data-binary @-).
ARGFILE="$(mktemp)"
trap 'rm -f "$ARGFILE"' EXIT
for a in "$@"; do printf '%s' "$a" | base64 -w0; printf '\n'; done > "$ARGFILE"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$PS1_FILE")" \
  -Key "$KEY" -ArgFile "$(cygpath -w "$ARGFILE")" -Relay "$RELAY"
