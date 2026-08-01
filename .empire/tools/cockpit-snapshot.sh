#!/usr/bin/env bash
# cockpit-snapshot.sh — Datenstand für die Empire-Cockpit-Kachelwand (buzz#15)
#
# Der Buzz-Desktop ist eine Webview: sie kann kein `gh`, kein `ssh`, kein jq.
# Dieses Script erhebt einmal, was das Cockpit anzeigt, und legt das Ergebnis
# als EINE Datei ab. Der Tauri-Command `read_empire_snapshot` liest nur noch
# diese Datei — das Öffnen des Tabs feuert nie gegen die GitHub-API.
#
# Aufruf:
#   bash .empire/tools/cockpit-snapshot.sh                 # -> ~/.buzz/cockpit.json
#   bash .empire/tools/cockpit-snapshot.sh --out FILE
#   bash .empire/tools/cockpit-snapshot.sh --stdout        # nichts schreiben, nur zeigen
#
# Exit-Codes (beantworten NUR die Erhebung, nie die Lage):
#   0 = alle Blöcke erhoben · 1 = Snapshot steht, aber ein Block ist eine Lücke
#   2 = gar kein verwertbarer Snapshot (die alte Datei bleibt dann unangetastet)
#
# ----------------------------------------------------------------------------
# GRUNDGESETZ: KEINE STILLEN NULLEN.
# Jeder Block trägt ein `state` (ok|warn|error) und im Fehlerfall ein `reason`.
# Eine Quelle, die nicht antwortet, wird NIE zu einer 0 verdichtet — das
# Cockpit muss "nicht erhoben" anzeigen können. Genau dieser Fehler ist am
# 01.08. real passiert: ein Report meldete "kein Gate offen", weil die
# Datenbasis fehlte. Ein Cockpit, das eine ungeprüfte Zahl zeigt, ist
# schlimmer als keines.
#
# WAS HIER BEWUSST NICHT NEU GEBAUT WIRD:
#   - Backlog/Gates kommen aus `lagebild.sh --format json --blocks backlog`
#     (buzz#7) — inklusive dessen Truncation-, Repo- und Fehlerbehandlung.
#   - Agenten-Status holt das Cockpit direkt aus der Desktop-Laufzeit
#     (`list_managed_agent_runtimes`), nicht von hier: das ist Live-Zustand
#     im selben Prozess und würde in einem Snapshot sofort veralten.
#   - Rituale kommen aus den Lauf-Quittungen, die `ritual.sh` selbst schreibt.
# ----------------------------------------------------------------------------

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${COCKPIT_SNAPSHOT_FILE:-$HOME/.buzz/cockpit.json}"
RUNS="${RITUAL_RUNS_FILE:-$HOME/.buzz/ritual-runs.jsonl}"
LAGEBILD="${COCKPIT_LAGEBILD:-$HERE/lagebild.sh}"
TO_STDOUT=0
SCHEMA_VERSION=1

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --stdout) TO_STDOUT=1; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unbekannte Option: $1" >&2; exit 64 ;;
  esac
done

command -v jq >/dev/null || { echo "cockpit-snapshot: jq fehlt" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
STAMP="$(date '+%Y-%m-%dT%H:%M:%S%z')"
INCOMPLETE=0

# ------------------------------------------------------------------ (a) Lagebild
# Nur der backlog-Block: er trägt Gates und Backlog und spricht ausschließlich
# mit GitHub. n8n/ssh/Mollie bleiben absichtlich draußen — das Cockpit soll
# keine geteilten Live-Systeme anfassen, nur weil jemand einen Tab öffnet.
collect_lagebild() {
  if [ ! -f "$LAGEBILD" ]; then
    jq -n --arg r "lagebild.sh nicht gefunden: $LAGEBILD" \
      '{state:"error", reason:$r}' > "$TMP/backlog.json"
    INCOMPLETE=1; return
  fi
  bash "$LAGEBILD" --format json --blocks backlog > "$TMP/lage.json" 2>"$TMP/lage.err"
  local rc=$?
  if [ ! -s "$TMP/lage.json" ] || ! jq -e '.backlog' "$TMP/lage.json" >/dev/null 2>&1; then
    jq -n --arg r "lagebild.sh lieferte kein verwertbares JSON (exit $rc): $(head -c 160 "$TMP/lage.err" 2>/dev/null | tr -d '\n\r')" \
      '{state:"error", reason:$r}' > "$TMP/backlog.json"
    INCOMPLETE=1; return
  fi
  jq '.backlog' "$TMP/lage.json" > "$TMP/backlog.json"
  local st
  st="$(jq -r '.state // "fehlt"' "$TMP/backlog.json" | tr -d '\r')"
  [ "$st" = "ok" ] || INCOMPLETE=1
}

# ------------------------------------------------------------------ (b) Rituale
# Quelle: die Lauf-Quittungen von ritual.sh. KEINE Quittungsdatei heißt
# "nicht erhoben" — nicht "0 Rituale gelaufen". Der Unterschied ist der
# ganze Sinn dieser Kachel.
collect_rituals() {
  if [ ! -f "$RUNS" ]; then
    jq -n --arg r "keine Lauf-Quittungen gefunden ($RUNS) — es ist UNBEKANNT, ob Rituale liefen" \
      '{state:"error", reason:$r, last_by_ritual:null}' > "$TMP/rituals.json"
    INCOMPLETE=1; return
  fi
  # Defekte Zeilen werden gezählt, nicht verschluckt: eine halb geschriebene
  # Zeile darf den Block nicht still um einen Lauf ärmer machen.
  local total bad
  total="$(grep -c '' "$RUNS" 2>/dev/null || echo 0)"
  bad="$(while IFS= read -r line; do
           [ -z "$line" ] && continue
           printf '%s' "$line" | jq -e . >/dev/null 2>&1 || echo x
         done < "$RUNS" | grep -c '' || true)"
  if ! jq -s --argjson bad "${bad:-0}" --argjson total "${total:-0}" '
        map(select(type=="object" and (.ritual|type=="string")))
        | (group_by(.ritual) | map({key:.[0].ritual, value:(max_by(.at))}) | from_entries) as $last
        | {state: (if ($last|length) == 0 then "error" elif $bad > 0 then "warn" else "ok" end),
           reason: (if ($last|length) == 0 then "Quittungsdatei vorhanden, aber keine lesbare Zeile — Ritual-Stand UNBEKANNT"
                    elif $bad > 0 then ($bad|tostring) + " unlesbare Zeile(n) in der Quittungsdatei — Stand evtl. unvollstaendig"
                    else null end),
           lines_total: $total, lines_unreadable: $bad,
           last_by_ritual: $last}' "$RUNS" > "$TMP/rituals.json" 2>/dev/null; then
    jq -n --arg r "Quittungsdatei nicht auswertbar ($RUNS)" \
      '{state:"error", reason:$r, last_by_ritual:null}' > "$TMP/rituals.json"
    INCOMPLETE=1; return
  fi
  local st
  st="$(jq -r '.state // "fehlt"' "$TMP/rituals.json" | tr -d '\r')"
  [ "$st" = "ok" ] || INCOMPLETE=1
}

collect_lagebild
collect_rituals

for b in backlog rituals; do
  if [ ! -s "$TMP/$b.json" ] || ! jq -e . "$TMP/$b.json" >/dev/null 2>&1; then
    jq -n '{state:"error", reason:"Block lieferte kein verwertbares Ergebnis (interner Fehler)"}' > "$TMP/$b.json"
    INCOMPLETE=1
  fi
done

jq -n \
  --argjson schema "$SCHEMA_VERSION" \
  --arg generated_at "$STAMP" \
  --arg host "$(hostname 2>/dev/null || echo unbekannt)" \
  --slurpfile backlog "$TMP/backlog.json" \
  --slurpfile rituals "$TMP/rituals.json" '
  {schema_version:$schema, generated_at:$generated_at, host:$host,
   backlog:$backlog[0], rituals:$rituals[0]}' > "$TMP/cockpit.json" \
  || { echo "cockpit-snapshot: Zusammenbau fehlgeschlagen — nichts geschrieben." >&2; exit 2; }

if [ "$TO_STDOUT" = "1" ]; then
  cat "$TMP/cockpit.json"
else
  mkdir -p "$(dirname "$OUT")" || { echo "cockpit-snapshot: $(dirname "$OUT") nicht anlegbar" >&2; exit 2; }
  # Atomar ersetzen: ein abgebrochener Lauf darf nie eine halbe Datei
  # hinterlassen, die das Cockpit als gueltigen Stand liest.
  cp "$TMP/cockpit.json" "$OUT.tmp" && mv -f "$OUT.tmp" "$OUT" \
    || { rm -f "$OUT.tmp"; echo "cockpit-snapshot: Schreiben nach $OUT fehlgeschlagen — alter Stand bleibt." >&2; exit 2; }
  echo "cockpit-snapshot: $OUT geschrieben ($STAMP)" >&2
fi

[ "$INCOMPLETE" = "1" ] && exit 1
exit 0
