#!/usr/bin/env bash
# ritual.sh — die drei Führungsrituale auf echten Daten (buzz#10, buzz#63)
#
#   morgenbrief    08:45 Europe/Berlin — 6 Blöcke: Top-3 · Termine (buzz#62) · Inbox ·
#                  Lage (inkl. Werkzeugbestand aus nest-doctor.sh, buzz#59) ·
#                  Entscheidungen · Lücken
#   gate-batch     20:45 Europe/Berlin — alle offenen blocked-munir als Ein-Zeilen-Entscheidungen
#                  + CRM-Löschzeile aus Espos Aktionshistorie (buzz#79)
#   wochen-review  So 18:00 Europe/Berlin — 5 Blöcke: Bewegung · Geld · Entscheidungs-
#                  Bewegung (gegen Snapshot der Vorwoche) · Vorschlag · Lücken (buzz#63)
#
# Aufruf:
#   bash .empire/tools/ritual.sh morgenbrief                      # nur rendern (stdout)
#   bash .empire/tools/ritual.sh morgenbrief --post --telegram --vault
#   bash .empire/tools/ritual.sh gate-batch  --post --telegram --vault
#   bash .empire/tools/ritual.sh gate-batch  --redact              # ohne Kundendaten (Issue-Beweise)
#   bash .empire/tools/ritual.sh wochen-review --post --telegram --vault
#   bash .empire/tools/ritual.sh wochen-review --since 2026-07-20 --no-snapshot   # Probe
#
# Exit-Codes (beantworten NUR die Erhebung, nie die Lage):
#   0 = alle Quellen geliefert · 1 = Brief steht, aber mit benannten Lücken
#   2 = kein Brief erzeugbar   · 3 = Brief erzeugt, aber ein Transport ist gescheitert
#
# ----------------------------------------------------------------------------
# GRUNDGESETZ: KEINE STILLEN NULLEN.
# Jede Zahl im Brief stammt aus einer gemessenen Quelle. Antwortet eine Quelle
# nicht, steht sie als benannte LÜCKE im Brief — nie als "0" und nie als grün.
# Der Brief MUSS falsch aussehen können, wenn die Daten fehlen.
#
# WARUM DIESES SCRIPT UND NICHT NUR EIN WORKFLOW-PROMPT:
# Ein Workflow kann nur `send_message`. Ein @mention-Prompt ("erstelle das
# Briefing") liefert das, woran sich das Modell erinnert — nicht das, was das
# System gerade tut. Hier wird gemessen; der Agent ist nur noch Transport.
# ----------------------------------------------------------------------------

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
MODE="${1:-}"; shift || true

POST=0; TG=0; VAULT=0; REDACT=0; DRY=0
BUZZ_CHANNEL=""
BRIEF_LIMIT="${RITUAL_GATE_LINES:-12}"
SECRETS_FILE="${SECRETS_FILE:-$HOME/.secrets/master.env}"
PRIORITIES="${LAGEBILD_PRIORITIES:-C:/Users/rescue/projects/adas-empire/priorities.json}"
EXTRA_REPOS="${RITUAL_EXTRA_REPOS:-munirad7s/buzz}"
VAULT_LOG="${RITUAL_VAULT_LOG:-$HOME/.buzz/vault-log.sh}"
MCP_CONFIG="${RITUAL_MCP_CONFIG:-$HOME/.buzz/.mcp.json}"
NOW_MD="${RITUAL_NOW_MD:-$HOME/Documents/Ai_Brain/99 System/Now.md}"
# Wochen-Gedächtnis (buzz#63). Bewusst AUSSERHALB des öffentlichen Repos:
# die Snapshots enthalten Issue-Titel aus Kunden-Repos.
SNAPDIR="${RITUAL_SNAPSHOT_DIR:-$HOME/.buzz/ritual-snapshots}"
SINCE=""; SNAPSHOT=1
# Kanäle: Morgenbrief in #general, Gate-Batch in #gates (Prefix-Router buzz#..)
CH_GENERAL="${RITUAL_CH_GENERAL:-96067fa5-a135-595f-9869-4fce8786f389}"
CH_GATES="${RITUAL_CH_GATES:-ac129605-42b4-4ef7-ad70-584cc24a4f58}"
POST_KEY="${RITUAL_POST_KEY:-agent:ef012af0d6db0f7c488cbf81f7ea5124de51348f4991bdb2eb0c1418b4ac6171}"

while [ $# -gt 0 ]; do
  case "$1" in
    --post) POST=1; shift ;;
    --telegram) TG=1; shift ;;
    --vault) VAULT=1; shift ;;
    --redact) REDACT=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --channel) BUZZ_CHANNEL="$2"; shift 2 ;;
    --lines) BRIEF_LIMIT="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --no-snapshot) SNAPSHOT=0; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unbekannte Option: $1" >&2; exit 64 ;;
  esac
done

case "$MODE" in
  morgenbrief|gate-batch|wochen-review) ;;
  *) echo "usage: ritual.sh <morgenbrief|gate-batch|wochen-review> [--post --telegram --vault --redact --dry-run --since YYYY-MM-DD --no-snapshot]" >&2; exit 64 ;;
esac

for t in jq curl gh; do command -v "$t" >/dev/null || { echo "$t fehlt" >&2; exit 2; }; done

CR=$'\r'
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
DATE_DE="$(date '+%a %d.%m.%Y')"
CLOCK="$(date '+%H:%M')"
GAPFILE="$TMP/gaps"; : > "$GAPFILE"
gap() { printf '%s\n' "$1" >> "$GAPFILE"; }
gapcount() { wc -l < "$GAPFILE" | tr -d ' '; }

# Woche = ISO-Woche (Mo–So). Der Sonntag 18:00-Lauf schaut auf die Woche, in der
# er selbst steht — deshalb wird der Montag aus dem ISO-Wochentag zurückgerechnet
# und nicht per `last monday` geraten (das liefert am Montag die Vorwoche).
WEEK_ID="$(date '+%G-W%V')"
WEEK_START="${SINCE:-$(date -d "-$(( $(date '+%u') - 1 )) days" '+%Y-%m-%d')}"
WEEK_LABEL="KW $(date '+%V') ($(date -d "$WEEK_START" '+%d.%m.') – $(date '+%d.%m.%Y'))"

# ------------------------------------------------------------------ Quellen

# (a) Lagebild — buzz#7. Nicht nachbauen, benutzen.
collect_lagebild() {
  local blocks="$1"
  bash "$HERE/lagebild.sh" --format json --blocks "$blocks" > "$TMP/lage.json" 2>"$TMP/lage.err"
  local rc=$?
  if [ ! -s "$TMP/lage.json" ] || ! jq -e . "$TMP/lage.json" >/dev/null 2>&1; then
    gap "Lagebild (#7) lieferte kein verwertbares JSON (exit $rc): $(head -c 120 "$TMP/lage.err" | tr -d '\n')"
    rm -f "$TMP/lage.json"; return 1
  fi
  # Ein Block, der sich selbst als tot meldet, ist eine Lücke — keine 0.
  # WICHTIG: `warn` heißt bei lagebild.sh nicht überall dasselbe. Nur bei
  # `backlog` bedeutet es "Erhebung unvollständig" (Truncation / Repo nicht
  # lesbar). Bei n8n/server/pay ist warn eine INHALTLICHE Auffälligkeit
  # (Fehler-Executions, roter Monitor, gescheiterte Zahlung) — die gehört in
  # den Lage-Block, nicht in die Lücken-Liste. Sonst sieht jede rote Lage wie
  # ein Messfehler aus und umgekehrt.
  local b
  for b in backlog n8n server pay; do
    case ",$blocks," in *",$b,"*) ;; *) continue ;; esac
    local st reason
    st="$(jq -r --arg b "$b" '.[$b].state // "fehlt"' "$TMP/lage.json" | tr -d "$CR")"
    reason="$(jq -r --arg b "$b" '.[$b].reason // "ohne Begründung"' "$TMP/lage.json" | tr -d "$CR")"
    case "$st" in
      ok) ;;
      warn) [ "$b" = "backlog" ] && gap "Lagebild/backlog unvollständig: $reason" ;;
      *)    gap "Lagebild/$b NICHT erhoben ($st): $reason" ;;
    esac
  done
  return 0
}

# Die Repo-Menge darf NICHT allein aus priorities.json kommen: sie ist eine
# gepflegte Liste und hinkt neuen Repos hinterher. Gemessen am 01.08.: 82 aus
# der Liste vs. 83 laut owner-weiter Suche — ein Repo fehlte still.
# Deshalb: Liste ∪ (Repos, in denen die Suche blocked-munir sieht).
repo_list() {
  [ -f "$TMP/repolist.txt" ] && { cat "$TMP/repolist.txt"; return 0; }
  local lim=300 found
  found="$(gh search issues --owner munirad7s --state open --label blocked-munir \
             --json repository -L "$lim" 2>/dev/null \
           | jq -r '.[].repository.nameWithOwner' 2>/dev/null | tr -d "$CR")"
  if [ -z "$found" ]; then
    gap "Repo-Suche (gh search) lieferte nichts — Repo-Menge nur aus priorities.json, evtl. unvollständig"
  elif [ "$(printf '%s\n' "$found" | wc -l | tr -d ' ')" -ge "$lim" ]; then
    gap "Repo-Suche am Limit ($lim) — es können weitere Repos mit blocked-munir existieren"
  fi
  { jq -r '.repo_order[].repo' "$PRIORITIES" 2>/dev/null; printf '%s\n' $EXTRA_REPOS; printf '%s\n' "$found"; } \
    | tr -d "$CR" | awk 'NF' | sort -u > "$TMP/repolist.txt"
  cat "$TMP/repolist.txt"
}

# (b) blocked-munir — je Repo einzeln abfragen. `gh search issues` schneidet bei
# erreichtem -L still ab; eine Abfrage je Repo macht Truncation sichtbar.
collect_blocked() {
  local limit=100 unreadable="" repo
  mkdir -p "$TMP/bl"
  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    (
      slug="$(printf '%s' "$repo" | tr '/' '~')"
      if out="$(gh issue list -R "$repo" --state open --label blocked-munir -L "$limit" \
                 --json number,title,labels,createdAt,url 2>/dev/null </dev/null)"; then
        printf '%s' "$out" | jq --arg repo "$repo" 'map(. + {repo:$repo})' > "$TMP/bl/$slug.json" 2>/dev/null
      fi
    ) &
    while [ "$(jobs -rp | wc -l)" -ge 8 ]; do sleep 0.2; done
  done < <(repo_list)
  wait

  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    [ -f "$TMP/bl/$(printf '%s' "$repo" | tr '/' '~').json" ] || unreadable="$unreadable $repo"
  done < <(repo_list)
  [ -n "$unreadable" ] && gap "blocked-munir nicht lesbar für:$unreadable (fehlen in der Summe, zählen NICHT als 0)"

  if ! ls "$TMP/bl"/*.json >/dev/null 2>&1; then
    gap "blocked-munir: kein einziges Repo lesbar — Gate-Batch hat keine Datenbasis"
    # KEINE leere Liste erzeugen. Eine leere Liste wäre eine stille Null und
    # der Batch würde "Heute kein Munir-Gate" melden — die gefährlichste
    # denkbare Falschaussage dieses Rituals (gemessen als Bug, dann behoben).
    return 1
  fi
  jq -s 'add | map({repo, number, url, title,
                    labels: (.labels|map(.name)),
                    createdAt})
        | sort_by( (if (.labels|index("P1-money")) then 0
                    elif (.labels|index("P1")) then 1
                    elif (.labels|index("P2")) then 2 else 3 end), .createdAt )' \
    "$TMP/bl"/*.json > "$TMP/blocked.json" 2>/dev/null \
    || { gap "blocked-munir: Aggregation fehlgeschlagen"; rm -f "$TMP/blocked.json"; return 1; }
  jq -e 'type == "array"' "$TMP/blocked.json" >/dev/null 2>&1 \
    || { gap "blocked-munir: Aggregat ist kein Array"; rm -f "$TMP/blocked.json"; return 1; }
  return 0
}

# (c) Inbox — google-mcp über den MCP-Adapter. Kein Send-Pfad, nur lesen.
collect_inbox() {
  local out
  if ! out="$(node "$HERE/mcp-call.mjs" --server google-mcp --tool gmail_search \
              --config "$MCP_CONFIG" --timeout 90000 \
              --args '{"query":"newer_than:1d -in:sent -in:chats -in:drafts","maxResults":50}' 2>"$TMP/inbox.err")"; then
    gap "Inbox (Gmail via google-mcp) nicht erhoben: $(head -c 140 "$TMP/inbox.err" | tr -d '\n')"
    return 1
  fi
  printf '%s' "$out" | jq -e '.messages' >/dev/null 2>&1 || {
    gap "Inbox lieferte kein verwertbares Ergebnis (Antwort ohne .messages)"; return 1; }
  printf '%s' "$out" > "$TMP/inbox.json"
  # Gmail deckelt bei maxResults. "50 neue" wäre sonst eine stille Untergrenze,
  # die wie eine gemessene Zahl aussieht.
  if [ "$(jq -r '.messages|length' "$TMP/inbox.json")" -ge 50 ]; then
    gap "Inbox-Abfrage am Limit (50) — die Zahl ist eine Untergrenze, kein Gesamtstand"
    echo 1 > "$TMP/inbox.capped"
  fi
  return 0
}

# (c2) Termine — google-mcp/calendar_events über denselben Adapter (buzz#62).
# Bis dahin stand hier eine harte Lücken-Zeile: der Kalender lief nur über den
# claude.ai-Connector und war für ein Script nicht erreichbar. Nur lesend —
# es existiert kein Tool, das einen Termin anlegt oder verschiebt.
collect_calendar() {
  local out from to
  # Fenster = jetzt bis morgen früh 06:00 Ortszeit: der Brief kommt 08:45 und
  # soll den ganzen Tag zeigen, nicht nur die nächsten 24 h ab Sendezeit.
  from="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  to="$(date -u -d 'tomorrow 06:00' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v+1d '+%Y-%m-%dT06:00:00Z')"
  if ! out="$(node "$HERE/mcp-call.mjs" --server google-mcp --tool calendar_events \
              --config "$MCP_CONFIG" --timeout 90000 \
              --args "{\"calendarId\":\"ALL\",\"timeMin\":\"$from\",\"timeMax\":\"$to\",\"maxResults\":40}" \
              2>"$TMP/cal.err")"; then
    gap "Termine (Kalender via google-mcp) nicht erhoben: $(head -c 140 "$TMP/cal.err" | tr -d '\n')"
    return 1
  fi
  printf '%s' "$out" | jq -e '.events' >/dev/null 2>&1 || {
    gap "Kalender lieferte kein verwertbares Ergebnis (Antwort ohne .events)"; return 1; }
  printf '%s' "$out" > "$TMP/cal.json"
  # Ein einzelner unlesbarer Kalender darf nicht wie ein leerer Tag aussehen.
  local bad; bad="$(jq -r '.unreadable|length' "$TMP/cal.json")"
  [ "$bad" -gt 0 ] && gap "Kalender unvollständig — $bad Kalender nicht lesbar (die Terminliste ist eine Untermenge)"
  return 0
}

# (d2) Werkzeugbestand — buzz#59. Ein Führungs-Agent, der glaubt ein Werkzeug zu
# haben, das er nicht hat, improvisiert — und improvisierte Führung ist falsche
# Führung. Genau das war in buzz#3 wochenlang unsichtbar: drei "verdrahtete"
# MCP-Server waren für die Agenten lautlos nicht vorhanden. Deshalb steht der
# Werkzeugbestand ab jetzt jeden Morgen im Brief.
#
# WICHTIG: nest-doctor.sh Exit 1 heißt "Drift gefunden" — das ist ein INHALTLICHER
# Befund und gehört in den Lage-Block, nicht in die Lücken-Liste (gleiche
# Unterscheidung wie bei lagebild.sh warn). Nur Exit 2 / unbrauchbares JSON ist
# eine Erhebungslücke.
collect_nest() {
  bash "$HERE/nest-doctor.sh" --format json > "$TMP/nest.json" 2>"$TMP/nest.err"
  local rc=$?
  if [ ! -s "$TMP/nest.json" ] || ! jq -e '.servers' "$TMP/nest.json" >/dev/null 2>&1; then
    # nest-doctor.sh meldet seine Abbruch-Gründe auf stdout, nicht auf stderr
    # (gemessen: `NEST_DIR=/weg` → stderr leer, Grund steht in der JSON-Datei).
    # Ohne diesen Fallback stünde im Brief eine Lücke OHNE Grund — eine stille
    # Null in Prosa-Form.
    local why; why="$(head -c 140 "$TMP/nest.err" | tr -d '\n')"
    [ -n "$why" ] || why="$(head -c 140 "$TMP/nest.json" | tr -d '\n')"
    [ -n "$why" ] || why="keine Ausgabe"
    gap "Nest-Doctor (#59) lieferte kein verwertbares JSON (exit $rc): $why"
    rm -f "$TMP/nest.json"; return 1
  fi
  return 0
}

# (d3) CRM-Löschungen — buzz#79. Nach #29/#52/#53 kann kein API-User mehr fremde
# Datensätze löschen — aber „kann nicht" ist eine Annahme, solange niemand
# hinsieht. Espo löscht SOFT: ein gelöschter Lead ist für jeden Lesepfad 404,
# der Grabstein bleibt liegen. Eine stille Löschwelle senkt KPI-Zahlen und
# Brief-Vorrat, ohne dass irgendwo etwas rot wird.
#
# QUELLENWAHL (drei Kandidaten gemessen, nicht geraten):
#   • Access-Log des Containers — vollständig, aber ohne Record-Identität
#     (DELETE /api/v1/Lead/<id> nennt keinen Entity-Namen und keinen User).
#   • Grabstein `deleted: true` — identitätsgenau, aber ohne Urheber und ohne
#     verlässlichen Löschzeitpunkt (Espo fasst modified_at beim Remove nicht an).
#   • `action_history_record` — hat ALLES: user_id, action, target_type,
#     target_id, created_at. Über die Espo-API wäre das `read: own` und damit
#     für einen Wächter wertlos; über die DB gelesen braucht es KEINEN neuen
#     Espo-User und KEINE Rechteerweiterung — genau die Bedingung aus #52/#53.
#   → gewählt: action_history_record, read-only über den bestehenden ssh-Pfad.
#
# Zeitrahmen: Espo schreibt created_at in UTC, der MariaDB-Container läuft in
# UTC (gemessen: NOW() == UTC_TIMESTAMP()). NOW() - INTERVAL 24 HOUR ist damit
# derselbe Rahmen wie die Daten — keine Zeitzonen-Verschiebung nötig.
collect_crm_deletions() {
  command -v ssh >/dev/null || { gap "CRM-Löschspur nicht erhoben: ssh nicht im PATH"; return 1; }
  { printf 'CRM_DB_CONTAINER=%s\n' "${RITUAL_CRM_CONTAINER:-agency-crm-mariadb}"
    printf 'CRM_WINDOW_H=%s\n' "${RITUAL_CRM_WINDOW_H:-24}"
    # Fenster-Ende = NOW - OFFSET. Default 0 = bis jetzt. Mit Offset lässt sich
    # jeder vergangene Tag nachschlagen ("was wurde letzten Dienstag gelöscht")
    # — und die Erwartungs-Zeile gegen einen ruhigen Tag gegenprüfen.
    printf 'CRM_OFFSET_H=%s\n' "${RITUAL_CRM_OFFSET_H:-0}"
    cat <<'REMOTE'
set -u
if ! command -v docker >/dev/null 2>&1; then
  echo "crm_err=docker auf dem Server nicht verfuegbar"; echo "REMOTE_DONE=1"; exit 0
fi
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CRM_DB_CONTAINER"; then
  echo "crm_err=DB-Container $CRM_DB_CONTAINER laeuft nicht"; echo "REMOTE_DONE=1"; exit 0
fi
SQL="SELECT CONCAT('crm_row=', IFNULL(u.user_name,'?'), '|', a.target_type, '|', COUNT(*))
     FROM action_history_record a LEFT JOIN user u ON u.id = a.user_id
     WHERE a.action = 'delete'
       AND a.created_at >= NOW() - INTERVAL $((CRM_OFFSET_H + CRM_WINDOW_H)) HOUR
       AND a.created_at <  NOW() - INTERVAL $CRM_OFFSET_H HOUR
     GROUP BY u.user_name, a.target_type
     ORDER BY COUNT(*) DESC;
     SELECT CONCAT('crm_last=', IFNULL(MAX(a.created_at),'-'))
     FROM action_history_record a WHERE a.action = 'delete';"
if OUT=$(printf '%s' "$SQL" | docker exec -i "$CRM_DB_CONTAINER" \
           sh -c 'exec mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" "$MARIADB_DATABASE" -N -B' 2>&1); then
  printf '%s\n' "$OUT"
  echo "crm_ok=1"
else
  echo "crm_err=SQL fehlgeschlagen: $(printf '%s' "$OUT" | head -c 120 | tr '\n' ' ')"
fi
echo "REMOTE_DONE=1"
REMOTE
  } | timeout 60 ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
      "${LAGEBILD_SSH_HOST:-hetzner}" 'bash -s' > "$TMP/crm.raw" 2>"$TMP/crm.err"

  # Sentinel wie beim Server-Block: ein halb durchgelaufener ssh-Block ist ein
  # Fehler, kein "0 Löschungen".
  if ! grep -q '^REMOTE_DONE=1$' "$TMP/crm.raw" 2>/dev/null; then
    gap "CRM-Löschspur nicht erhoben: ssh unvollständig ($(head -c 120 "$TMP/crm.err" 2>/dev/null | tr '\n' ' '))"
    rm -f "$TMP/crm.raw"; return 1
  fi
  if ! grep -q '^crm_ok=1$' "$TMP/crm.raw"; then
    gap "CRM-Löschspur nicht erhoben: $(grep -m1 '^crm_err=' "$TMP/crm.raw" | cut -d= -f2- || echo 'ohne Begründung')"
    rm -f "$TMP/crm.raw"; return 1
  fi
  return 0
}

# (e) Geschlossene Issues der Woche — buzz#63. Je Repo einzeln, NIE owner-weit:
# `gh search issues` schneidet bei erreichtem -L still ab, und eine abgeschnittene
# Bewegungszahl sieht aus wie eine gemessene. Eine Abfrage je Repo macht das
# Limit sichtbar (Repo am Limit → Lücke, nicht "genau 100").
CLOSED_LIMIT=200
collect_closed() {
  local repo capped="" unreadable=""
  mkdir -p "$TMP/cl"
  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    (
      slug="$(printf '%s' "$repo" | tr '/' '~')"
      if out="$(gh issue list -R "$repo" --state closed --search "closed:>=$WEEK_START" \
                 -L "$CLOSED_LIMIT" --json number,title,labels,closedAt,url 2>/dev/null </dev/null)"; then
        printf '%s' "$out" | jq --arg repo "$repo" 'map({repo:$repo, number, title, url, closedAt,
                                                         labels:(.labels|map(.name))})' \
          > "$TMP/cl/$slug.json" 2>/dev/null
      fi
    ) &
    while [ "$(jobs -rp | wc -l)" -ge 8 ]; do sleep 0.2; done
  done < <(repo_list)
  wait

  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    local f="$TMP/cl/$(printf '%s' "$repo" | tr '/' '~').json"
    if [ ! -f "$f" ]; then unreadable="$unreadable $repo"; continue; fi
    [ "$(jq -r 'length' "$f" 2>/dev/null || echo 0)" -ge "$CLOSED_LIMIT" ] && capped="$capped $repo"
  done < <(repo_list)
  [ -n "$unreadable" ] && gap "geschlossene Issues nicht lesbar für:$unreadable (fehlen in der Summe, zählen NICHT als 0)"
  [ -n "$capped" ] && gap "geschlossene Issues am Limit ($CLOSED_LIMIT) in:$capped — die Summe ist eine Untergrenze"

  if ! ls "$TMP/cl"/*.json >/dev/null 2>&1; then
    gap "geschlossene Issues: kein einziges Repo lesbar — Bewegungs-Block hat keine Datenbasis"
    return 1
  fi
  jq -s 'add | sort_by(.closedAt) | reverse' "$TMP/cl"/*.json > "$TMP/closed.json" 2>/dev/null \
    || { gap "geschlossene Issues: Aggregation fehlgeschlagen"; rm -f "$TMP/closed.json"; return 1; }
  return 0
}

# (e2) Auffüller für den Vorschlag — buzz#63. `lagebild.sh` liefert höchstens die
# drei ältesten ready-P1-money. Gemessen am 01.08.: es gibt owner-weit genau EINEN.
# Ein Vorschlagsblock, der dann still einzeilig bleibt, sieht aus wie ein Fehler —
# also wird sichtbar mit den ältesten ready-P1 aufgefüllt und die Herkunft je
# Zeile benannt. Aufgefüllt wird NUR, nie ersetzt: P1-money bleibt vorn.
collect_fillers() {
  local out
  if ! out="$(gh search issues --owner munirad7s --state open --label ready --label P1 \
               --sort created --order asc --json repository,number,title,labels -L 30 2>/dev/null)"; then
    gap "Vorschlag: P1-Auffüller nicht erhoben (gh search fehlgeschlagen) — Block 4 kann kürzer als 3 sein"
    return 1
  fi
  printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1 || {
    gap "Vorschlag: P1-Auffüller lieferte kein Array — Block 4 kann kürzer als 3 sein"; return 1; }
  printf '%s' "$out" | jq '[.[] | {repo: .repository.nameWithOwner, number, title,
                                   labels: (.labels|map(.name))}
                            | select((.labels|index("blocked-munir"))|not)
                            | select((.labels|index("in-progress"))|not)
                            | select((.labels|index("P1-money"))|not)]' > "$TMP/fillers.json" 2>/dev/null
  return 0
}

# (f) Wochen-Gedächtnis — buzz#63. Der Vergleich braucht eine Vorwoche; fehlt
# sie, ist das eine LÜCKE und keine "0 Bewegung". Genau diese Verwechslung wäre
# im ersten Lauf die gefährlichste Falschaussage des Rituals.
load_prev_snapshot() {
  [ -d "$SNAPDIR" ] || { gap "Vergleichsbasis fehlt — noch kein Snapshot-Verzeichnis ($SNAPDIR). Die Bewegungszahlen unter 3) sind NICHT 0, sondern unbekannt."; return 1; }
  local prev
  prev="$(ls -1 "$SNAPDIR"/*.json 2>/dev/null | sort | awk -v cur="$SNAPDIR/$WEEK_ID.json" '$0 < cur' | tail -1)"
  if [ -z "$prev" ] || [ ! -s "$prev" ] || ! jq -e '.blocked' "$prev" >/dev/null 2>&1; then
    gap "Vergleichsbasis fehlt — kein verwertbarer Snapshot vor $WEEK_ID. Die Bewegungszahlen unter 3) sind NICHT 0, sondern unbekannt."
    return 1
  fi
  cp "$prev" "$TMP/prev.json"
  PREV_WEEK="$(jq -r '.week // "unbekannt"' "$TMP/prev.json")"
  # Ein Snapshot, dem Repos fehlten, erzeugt Phantom-"neu" und Phantom-"gelöst".
  local pu; pu="$(jq -r '.repos_unreadable // [] | join(" ")' "$TMP/prev.json")"
  [ -n "$pu" ] && gap "Vergleichs-Snapshot $PREV_WEEK war unvollständig (nicht gelesen: $pu) — neu/gelöst können Messartefakte enthalten"
  return 0
}

write_snapshot() {
  [ "$SNAPSHOT" = "1" ] || { echo "snapshot: --no-snapshot gesetzt, nichts geschrieben" >&2; return 0; }
  mkdir -p "$SNAPDIR" || { gap "Snapshot-Verzeichnis $SNAPDIR nicht anlegbar — nächste Woche fehlt die Vergleichsbasis"; return 1; }
  local unread="[]"
  grep -q 'blocked-munir nicht lesbar' "$GAPFILE" 2>/dev/null && \
    unread="$(grep -m1 'blocked-munir nicht lesbar' "$GAPFILE" | sed 's/.*für://; s/ (fehlen.*//' | tr ' ' '\n' | awk 'NF' | jq -R . | jq -s .)"
  jq -n \
    --arg week "$WEEK_ID" --arg start "$WEEK_START" --arg at "$(date -Is)" \
    --argjson blocked "$( [ -f "$TMP/blocked.json" ] && jq '[.[] | "\(.repo)#\(.number)"]' "$TMP/blocked.json" || echo null )" \
    --argjson closed  "$( [ -f "$TMP/closed.json" ]  && jq 'length' "$TMP/closed.json" || echo null )" \
    --argjson pay "$( [ -f "$TMP/lage.json" ] && jq '.pay // null' "$TMP/lage.json" || echo null )" \
    --argjson unread "$unread" \
    '{week:$week, week_start:$start, generated_at:$at,
      blocked:$blocked, blocked_count:($blocked|if .==null then null else length end),
      closed_count:$closed, pay:$pay, repos_unreadable:$unread}' \
    > "$SNAPDIR/$WEEK_ID.json" 2>/dev/null \
    || { gap "Snapshot $WEEK_ID.json konnte nicht geschrieben werden"; return 1; }
  echo "snapshot: $SNAPDIR/$WEEK_ID.json geschrieben" >&2
  return 0
}

# (d) Foki — die drei #-Überschriften aus Now.md. Vault ist Kanon.
collect_foki() {
  if [ ! -f "$NOW_MD" ]; then
    gap "Now.md nicht lesbar ($NOW_MD) — Top-3 fehlen"; return 1
  fi
  grep -E '^## #[123] ' "$NOW_MD" | sed -E 's/^## #[123] //' | head -3 > "$TMP/foki.txt"
  [ -s "$TMP/foki.txt" ] || { gap "Now.md enthält keine '## #1..#3'-Foki — Top-3 fehlen"; return 1; }
  return 0
}

# ------------------------------------------------------------------- Render

trunc() { local s="$1" n="$2"; if [ "${#s}" -gt "$n" ]; then printf '%s…' "${s:0:$n}"; else printf '%s' "$s"; fi; }

prio_of() { # erstes echtes Prio-Label
  jq -r 'if (.labels|index("P1-money")) then "P1-money"
         elif (.labels|index("P1")) then "P1"
         elif (.labels|index("P2")) then "P2"
         elif (.labels|index("P3")) then "P3" else "-" end'
}

render_gate_lines() { # $1 = Anzahl
  local n="$1"
  jq -r --argjson n "$n" --argjson redact "$REDACT" '
    def prio: if (.labels|index("P1-money")) then "💶P1-money"
              elif (.labels|index("P1")) then "P1"
              elif (.labels|index("P2")) then "P2"
              elif (.labels|index("P3")) then "P3" else "—" end;
    .[0:$n] | to_entries[] |
    "\(.key+1). \(.value.repo|sub("^munirad7s/";""))#\(.value.number) [\(.value|prio)] — " +
    (if $redact == 1 then "‹Titel geschwärzt›" else (.value.title|.[0:95]) end)
  ' "$TMP/blocked.json"
}

render_morgenbrief() {
  local out="$TMP/brief.md"
  {
    printf '🌅 **MORGENBRIEF** — %s, %s (Europe/Berlin)\n' "$DATE_DE" "$CLOCK"
    printf '\n**1) Top-3 heute** (Quelle: Vault `99 System/Now.md`)\n'
    if [ -s "$TMP/foki.txt" ]; then
      local i=1
      while IFS= read -r l; do printf '   #%d %s\n' "$i" "$(trunc "$l" 110)"; i=$((i+1)); done < "$TMP/foki.txt"
    else
      printf '   ⚠️ LÜCKE — keine Foki gelesen\n'
    fi
    if [ -f "$TMP/lage.json" ]; then
      local tm
      tm="$(jq -r '.backlog.top_money // [] | .[] | "   💶 " + (.repo|sub("^munirad7s/";"")) + "#" + (.number|tostring) + " — " + (.title|.[0:80])' "$TMP/lage.json" | tr -d "$CR")"
      [ -n "$tm" ] && { printf '   ältestes offenes P1-money (Backlog):\n'; printf '%s\n' "$tm"; }
    fi

    printf '\n**2) Termine heute** (alle lesbaren Kalender, bis morgen 06:00)\n'
    if [ -f "$TMP/cal.json" ]; then
      local nev; nev="$(jq -r '.events|length' "$TMP/cal.json")"
      if [ "$nev" -eq 0 ]; then
        if [ "$(jq -r '.unreadable|length' "$TMP/cal.json")" -gt 0 ]; then
          printf '   ⚠️ 0 in den LESBAREN Kalendern — nicht alle waren lesbar (siehe Block 6)\n'
        else
          printf '   keine Termine im Fenster\n'
        fi
      else
        printf '   %s Termine:\n' "$nev"
        # Ganztägige zuerst: Klausuren, Fristen und Urlaube stehen dort, und ein
        # "ganztägig" ohne Uhrzeit sähe sonst wie 00:00 aus.
        jq -r '
          [.events[]|select(.allDay)] as $a |
          [.events[]|select(.allDay|not)] as $t |
          ([$a[]| "   ▪ ganztägig — " + (.summary|.[0:70]) + " (" + (.calendar|.[0:22]) + ")"]
           + [$t[]| "   ▪ " + (.start|.[11:16]) + " — " + (.summary|.[0:70])
                    + (if .location then " @" + (.location|.[0:28]) else "" end)])[0:12] | .[]
        ' "$TMP/cal.json" | tr -d "$CR"
        [ "$nev" -gt 12 ] && printf '   … und %s weitere\n' "$((nev-12))"
      fi
    else
      printf '   ⚠️ LÜCKE — Kalender nicht erhoben (siehe Block 6)\n'
    fi

    printf '\n**3) Inbox** (m.muniradas@gmail.com, letzte 24 h)\n'
    if [ -f "$TMP/inbox.json" ]; then
      local total unread mark=""
      total="$(jq -r '.messages|length' "$TMP/inbox.json")"
      unread="$(jq -r '[.messages[]|select(.labelIds|index("UNREAD"))]|length' "$TMP/inbox.json")"
      [ -f "$TMP/inbox.capped" ] && mark="≥"
      printf '   %s%s neue Nachrichten, davon %s%s ungelesen%s\n' "$mark" "$total" "$mark" "$unread" \
        "$([ -n "$mark" ] && printf ' (Abfrage-Limit erreicht — Untergrenze)')"
      if [ "$REDACT" = "1" ]; then
        printf '   (Absender/Betreffe geschwärzt — öffentlicher Kontext)\n'
      else
        jq -r '[.messages[]|select(.labelIds|index("UNREAD"))] | .[0:6][] |
               "   • " + ((.from|sub(" *<.*>$";""))|.[0:32]) + " — " + (.subject//"(ohne Betreff)"|.[0:70])' \
          "$TMP/inbox.json" | tr -d "$CR"
        [ "$unread" -gt 6 ] && printf '   …und %s weitere ungelesene\n' "$((unread-6))"
      fi
    else
      printf '   ⚠️ LÜCKE — Inbox nicht erhoben (siehe Block 6)\n'
    fi

    printf '\n**4) Lage** (Quelle: `.empire/tools/lagebild.sh`)\n'
    if [ -f "$TMP/lage.json" ]; then
      jq -r '
        def st(x): if x == "ok" then "" elif x == "warn" then " ⚠️" else " ❌" end;
        [ (if .backlog then "   Backlog:" + st(.backlog.state) + " " + (.backlog.ready_total|tostring) + " ready ("
             + ((.backlog.by_prio."P1-money")|tostring) + "× P1-money, ohne blockierte) · "
             + (.backlog.in_progress|tostring) + " in-progress"
           else "   Backlog: ❌ nicht erhoben" end),
          (if (.n8n.state? // "") != "" then "   n8n:" + st(.n8n.state) + " "
             + ((.n8n.errors_total // "?")|tostring) + " Fehler / "
             + ((.n8n.executions_in_window // "?")|tostring) + " Executions (24 h)"
             + (if (.n8n.by_workflow // []) | length > 0
                then " — häufigster: " + (.n8n.by_workflow[0].workflow) else "" end) else empty end),
          (if (.server.state? // "") != "" then "   Server:" + st(.server.state) + " "
             + ((.server.disk_used_pct // "?")|tostring) + "% Disk · "
             + ((.server.containers_running // "?")|tostring) + " Container up · "
             + ((.server.containers_unhealthy // "?")|tostring) + " unhealthy"
             + (if ((.server.kuma_down // []) | length) > 0
                then " · Kuma rot: " + ((.server.kuma_down)|join(", ")) else "" end)
             # agency-infra#134: ein Monitor ohne Benachrichtigung wird nie rot
             # gemeldet — er muss deshalb HIER auffallen, sonst fällt er nie auf.
             + (if ((.server.kuma_silent // []) | length) > 0
                then " · Kuma STUMM (alarmiert niemanden): " + ((.server.kuma_silent)|join(", ")) else "" end) else empty end),
          (if (.pay.state? // "") != "" then "   Zahlungen:" + st(.pay.state) + " "
             + ((.pay.subscriptions_active // "?")|tostring) + " aktive Abos · 30 T: "
             + ((.pay.last30_by_status.paid // 0)|tostring) + " bezahlt / "
             + ((.pay.last30_total // "?")|tostring) + " Versuche ("
             + ((.pay.last30_failed_after_method // 0)|tostring) + " nach Methodenwahl gescheitert)" else empty end)
        ] | .[]' "$TMP/lage.json" | tr -d "$CR"
    else
      printf '   ⚠️ LÜCKE — Lagebild nicht erhoben (siehe Block 6)\n'
    fi
    if [ -f "$TMP/nest.json" ]; then
      jq -r '
        (.servers|length) as $n |
        ([.servers[]|select(.status=="ok")]|length) as $ok |
        ([.servers[]|select(.status!="ok")|.name + " (" + .status + ")"]) as $bad |
        "   Werkzeuge:" + (if .exit == 0 then "" else " ❌" end)
        + " " + ($ok|tostring) + "/" + ($n|tostring) + " MCP-Server einsatzbereit"
        + (if ($bad|length) > 0 then " — rot: " + ($bad|join(", ")) else "" end)
        + (if .trust_accepted != "true" then " · Nest NICHT getraut — .mcp.json wird ignoriert" else "" end)
        + (if .process_drift == "ja" then " · Agenten laufen mit ALTEM Werkzeugkasten (Neustart im Desktop nötig)" else "" end)
      ' "$TMP/nest.json" | tr -d "$CR"
    else
      printf '   Werkzeuge: ⚠️ LÜCKE — Nest-Doctor nicht erhoben (siehe Block 6)\n'
    fi

    printf '\n**5) Deine Entscheidungen** (offene `blocked-munir`)\n'
    if [ -f "$TMP/blocked.json" ]; then
      local nb; nb="$(jq -r 'length' "$TMP/blocked.json")"
      if [ "$nb" -eq 0 ]; then
        if grep -q 'nicht lesbar\|am Limit\|lieferte nichts' "$GAPFILE" 2>/dev/null; then
          printf '   ⚠️ 0 in den lesbaren Repos — nicht alle waren lesbar (siehe Block 6)\n'
        else
          printf '   keine offenen Blocker\n'
        fi
      else
        printf '   %s offen — Top 3:\n' "$nb"
        render_gate_lines 3 | sed 's/^/   /'
        printf '   voller Batch heute 20:45\n'
      fi
    else
      printf '   ⚠️ LÜCKE — blocked-munir nicht erhoben (siehe Block 6)\n'
    fi

    printf '\n**6) Lücken** (bewusst benannt, nie als 0 verbucht)\n'
    if [ -s "$GAPFILE" ]; then
      sed 's/^/   • /' "$GAPFILE"
    else
      printf '   • sonst keine — alle Quellen haben geliefert\n'
    fi
  } > "$out"
  printf '%s' "$out"
}

# CRM-Löschzeile — buzz#79. Schwelle NICHT geraten, sondern aus 8 Tagen
# Aktionshistorie gemessen: 26.07.–31.07. löschte täglich genau `n8n-agent`
# 1× Lead + 1× CTouchpoint (der Funnel-Probe aus buzz#53) — sonst nichts.
# Alles darüber und jeder andere User ist erklärungsbedürftig.
# 0 Löschungen ist KEIN Ruhezustand: dann hat der Probe nicht gelöscht.
plural_del() { [ "$1" -eq 1 ] && printf 'Löschung' || printf 'Löschungen'; }

render_crm_deletions() {
  local win="${RITUAL_CRM_WINDOW_H:-24}" off="${RITUAL_CRM_OFFSET_H:-0}"
  if [ "$off" -gt 0 ]; then
    printf '\n**CRM-Löschungen** (%s h, endend vor %s h · Quelle: Espo-Aktionshistorie, read-only über die DB)\n' "$win" "$off"
  else
    printf '\n**CRM-Löschungen** (letzte %s h · Quelle: Espo-Aktionshistorie, read-only über die DB)\n' "$win"
  fi
  if [ ! -f "$TMP/crm.raw" ]; then
    printf '   ⚠️ LÜCKE — die Löschspur wurde NICHT erhoben. Das ist kein "0 Löschungen". Siehe Lücken.\n'
    return
  fi
  local total probe rest last
  total="$(awk -F'|' '/^crm_row=/{s+=$3} END{print s+0}' "$TMP/crm.raw")"
  probe="$(awk -F'|' '/^crm_row=/{u=$1; sub(/^crm_row=/,"",u);
             if (u=="n8n-agent" && ($2=="Lead" || $2=="CTouchpoint")) s += ($3>1 ? 1 : $3)}
           END{print s+0}' "$TMP/crm.raw")"
  rest=$((total - probe))
  last="$(grep -m1 '^crm_last=' "$TMP/crm.raw" | cut -d= -f2-)"

  if [ "$total" -eq 0 ]; then
    printf '   ⚠️ 0 Löschungen — auch der Funnel-Probe hat nichts gelöscht.\n'
    printf '      Erwartet wären 1× Lead + 1× CTouchpoint (n8n-agent). Prüfen, ob `[BUZZ-53] funnel-probe` noch läuft.\n'
    printf '      Letzte Löschung überhaupt: %s (UTC)\n' "${last:--}"
  elif [ "$rest" -eq 0 ]; then
    # Die Zusammensetzung wird GEMESSEN, nicht behauptet. Eine feste Formel
    # ("1× Lead + 1× CTouchpoint") wäre bei 1 gelöschtem Lead eine erfundene
    # Zahl im Führungsbrief — gemessen am 01.08. genau so passiert.
    local comp
    comp="$(awk -F'|' '/^crm_row=/{ c = c (c=="" ? "" : ", ") $3 "× " $2 } END{print c}' "$TMP/crm.raw")"
    printf '   ✅ %s %s — ausschließlich der Funnel-Probe (n8n-agent): %s. Erwartet.\n' \
      "$total" "$(plural_del "$total")" "$comp"
  else
    printf '   ⚠️ %s %s, davon **%s außerhalb des Funnel-Probes** — erklärungsbedürftig:\n' \
      "$total" "$(plural_del "$total")" "$rest"
    awk -F'|' '/^crm_row=/{
          u=$1; sub(/^crm_row=/,"",u);
          a[u] = a[u] (a[u]=="" ? "" : ", ") $3 "× " $2;
          t[u] += $3 }
        END{ for (u in t) printf "%d\t      – %s: %s\n", t[u], u, a[u] }' "$TMP/crm.raw" \
      | sort -rn | cut -f2-
    [ "$probe" -eq 0 ] && printf '      – Funnel-Probe (n8n-agent): NICHT gelaufen — zusätzlich prüfen.\n'
    printf '      Erwartungswert ist 1× Lead + 1× CTouchpoint durch n8n-agent; alles andere braucht eine Erklärung.\n'
  fi
}

render_gate_batch() {
  local out="$TMP/brief.md"
  local nb=0; [ -f "$TMP/blocked.json" ] && nb="$(jq -r 'length' "$TMP/blocked.json")"
  {
    printf '🔐 **GATE-BATCH** — %s, %s (Europe/Berlin)\n' "$DATE_DE" "$CLOCK"
    if [ ! -f "$TMP/blocked.json" ]; then
      printf '\n❌ KEINE DATENBASIS — die blocked-munir-Liste konnte nicht erhoben werden.\n'
      printf 'Das ist KEIN "heute nichts zu tun". Siehe Lücken.\n'
    elif [ "$nb" -eq 0 ]; then
      if grep -q 'nicht lesbar\|am Limit\|lieferte nichts' "$GAPFILE" 2>/dev/null; then
        printf '\n⚠️ 0 Blocker in den LESBAREN Repos — aber nicht alle Repos waren lesbar.\n'
        printf 'Das ist KEIN "heute kein Munir-Gate". Siehe Lücken.\n'
      else
        printf '\nHeute kein Munir-Gate — 0 offene `blocked-munir` über %s Repos.\n' "$(repo_list | wc -l | tr -d ' ')"
      fi
    else
      printf '\n**%s Entscheidungen offen.** Reihenfolge: P1-money → P1 → P2 → P3, je Gruppe ältestes zuerst.\n\n' "$nb"
      render_gate_lines "$BRIEF_LIMIT"
      if [ "$nb" -gt "$BRIEF_LIMIT" ]; then
        printf '\n…und %s weitere: https://github.com/issues?q=is%%3Aopen+label%%3Ablocked-munir+user%%3Amunirad7s\n' "$((nb-BRIEF_LIMIT))"
      fi
      printf '\nJede Zeile ist eine Entscheidung, die nur du treffen kannst. Erledigt = Label `blocked-munir` entfernen.\n'
    fi
    render_crm_deletions
    printf '\n**Lücken**\n'
    if [ -s "$GAPFILE" ]; then sed 's/^/   • /' "$GAPFILE"; else printf '   • keine — alle Repos gelesen\n'; fi
  } > "$out"
  printf '%s' "$out"
}

# Wochen-Review — buzz#63. Bewegung, Geld, Entscheidungen, Vorschlag, Lücken.
# Keine Bewertung, keine Motivation, keine Wunschliste: das Ritual beantwortet
# „was hat sich bewegt" und „woran arbeiten wir nächste Woche" — sonst nichts.
render_wochen_review() {
  local out="$TMP/brief.md"
  local nrepos; nrepos="$(repo_list | wc -l | tr -d ' ')"
  {
    printf '📊 **WOCHEN-REVIEW** — %s, Stand %s (Europe/Berlin)\n' "$WEEK_LABEL" "$CLOCK"

    printf '\n**1) Bewegung** (geschlossene Issues seit %s, je Repo einzeln gemessen)\n' "$WEEK_START"
    if [ -f "$TMP/closed.json" ]; then
      local ct money
      ct="$(jq -r 'length' "$TMP/closed.json")"
      money="$(jq -r '[.[]|select(.labels|index("P1-money"))]|length' "$TMP/closed.json")"
      if [ "$ct" -eq 0 ]; then
        printf '   0 geschlossene Issues in %s gescannten Repos — diese Woche stand der Backlog still.\n' "$nrepos"
      else
        local nactive; nactive="$(jq -r '[.[].repo]|unique|length' "$TMP/closed.json")"
        printf '   **%s geschlossen** in %s Repos (von %s gescannt), davon %s 💶P1-money\n' "$ct" "$nactive" "$nrepos" "$money"
        jq -r 'group_by(.repo)
               | map({repo:.[0].repo, n:length,
                      money:([.[]|select(.labels|index("P1-money"))]|length)})
               | sort_by(-.n) | .[0:8][]
               | "   • \(.repo|sub("^munirad7s/";"")): \(.n)\(if .money>0 then " (\(.money) 💶)" else "" end)"' \
          "$TMP/closed.json"
        [ "$nactive" -gt 8 ] && printf '   … und %s weitere Repos mit Bewegung\n' "$((nactive-8))"
      fi
    else
      printf '   ⚠️ LÜCKE — keine Datenbasis. Das ist KEIN "nichts bewegt". Siehe 5).\n'
    fi

    printf '\n**2) Geld** (Quelle: Mollie über `lagebild.sh`)\n'
    local pst; pst="$( [ -f "$TMP/lage.json" ] && jq -r '.pay.state // "fehlt"' "$TMP/lage.json" | tr -d "$CR" || echo fehlt )"
    if [ "$pst" = "ok" ] || [ "$pst" = "warn" ]; then
      jq -r '.pay |
        "   • aktive Abos: \(.subscriptions_active // "?")   ·   MRR: " +
          (if .mrr_eur == null then "LÜCKE (nicht erhoben)" else "\(.mrr_eur) €" end),
        "   • letzte 30 Tage: \(.last30_total // 0) Zahlungsvorgänge — " +
          ((.last30_by_status // {}) | to_entries | map("\(.value) \(.key)") | join(", ")),
        "     davon \(.last30_failed_after_method // 0) NACH der Methodenwahl gescheitert (echter Fehler), \(.last30_never_started // 0) nie gestartet",
        (if (.last_payments // []) | length > 0
         then "   • letzte Zahlung: \(.last_payments[0].status) / \(.last_payments[0].method) / \(.last_payments[0].at)"
         else "   • letzte Zahlung: LÜCKE — keine Zahlung im Fenster" end)' "$TMP/lage.json" | tr -d "$CR"
      if [ -f "$TMP/prev.json" ] && jq -e '.pay.last30_total' "$TMP/prev.json" >/dev/null 2>&1; then
        local pt ct2 pp cp
        pt="$(jq -r '.pay.last30_total' "$TMP/prev.json")";      ct2="$(jq -r '.pay.last30_total // 0' "$TMP/lage.json")"
        pp="$(jq -r '.pay.last30_by_status.paid // 0' "$TMP/prev.json")"; cp="$(jq -r '.pay.last30_by_status.paid // 0' "$TMP/lage.json")"
        printf '   • ggü. %s: Vorgänge %+d, bezahlt %+d\n' "$PREV_WEEK" "$((ct2-pt))" "$((cp-pp))"
      else
        printf '   • Wochen-Delta: LÜCKE — keine Geld-Vergleichsbasis (siehe 5)\n'
      fi
    else
      printf '   ⚠️ LÜCKE — Zahlungs-Block nicht erhoben (%s). Keine Zahl ist hier besser als eine erfundene.\n' "$pst"
    fi

    printf '\n**3) Entscheidungen** (offene `blocked-munir` über %s Repos)\n' "$nrepos"
    if [ ! -f "$TMP/blocked.json" ]; then
      printf '   ⚠️ LÜCKE — blocked-munir nicht erhoben. Das ist KEIN "keine offenen Gates". Siehe 5).\n'
    else
      local nb; nb="$(jq -r 'length' "$TMP/blocked.json")"
      printf '   Stand jetzt: **%s offen**\n' "$nb"
      if [ ! -f "$TMP/prev.json" ]; then
        printf '   ⚠️ Vergleichsbasis fehlt — neu/gelöst/liegengeblieben sind UNBEKANNT, nicht 0.\n'
        printf '   Ab nächstem Sonntag steht hier die echte Bewegung (Snapshot %s ist jetzt geschrieben).\n' "$WEEK_ID"
      else
        jq -r --slurpfile prev "$TMP/prev.json" '
          ($prev[0].blocked // []) as $p |
          ([.[] | "\(.repo)#\(.number)"]) as $c |
          ($c - $p) as $new | ($p - $c) as $gone | ($c - $new) as $stay |
          "   • neu diese Woche: \($new|length)",
          "   • gelöst: \($gone|length)",
          "   • liegengeblieben: \($stay|length)"' "$TMP/blocked.json"
        printf '   (Vergleich gegen Snapshot %s)\n' "$PREV_WEEK"
        jq -r --slurpfile prev "$TMP/prev.json" '
          ($prev[0].blocked // []) as $p |
          [.[] | select(("\(.repo)#\(.number)") as $k | $p | index($k))]
          | sort_by(.createdAt) | .[0:1][]
          | "   • ältester Liegengebliebener: \(.repo|sub("^munirad7s/";""))#\(.number) — \(.title|.[0:70])"' \
          "$TMP/blocked.json" 2>/dev/null
      fi
    fi

    printf '\n**4) Vorschlag kommende Woche** (ältestes offenes `ready` zuerst — P1-money vor P1)\n'
    local tm=""
    if [ -f "$TMP/lage.json" ]; then
      tm="$(jq -r --slurpfile f "${TMP}/fillers.json" '
        ([$f[0] // []] | flatten) as $fill |
        ((.backlog.top_money // []) | map(. + {src:"💶P1-money"})) as $money |
        (($money + ($fill | map({repo, number, title, src:"P1"}))) | .[0:3]) | to_entries[] |
        "   \(.key+1). [\(.value.src)] \(.value.repo|sub("^munirad7s/";""))#\(.value.number) — \(.value.title|.[0:80])"' \
        "$TMP/lage.json" 2>/dev/null | tr -d "$CR")"
    fi
    if [ -n "$tm" ]; then
      printf '%s\n' "$tm"
      local nmoney=0
      [ -f "$TMP/lage.json" ] && nmoney="$(jq -r '.backlog.top_money // [] | length' "$TMP/lage.json" | tr -d "$CR")"
      [ "$nmoney" -lt 3 ] && printf '   (nur %s offene ready-P1-money owner-weit — Rest ist mit ready-P1 aufgefüllt)\n' "$nmoney"
      printf '   Vorschlag aus gemessener Prio, keine Zuweisung.\n'
    else
      printf '   ⚠️ LÜCKE — kein Vorschlag ableitbar (Backlog-Block nicht erhoben oder leer).\n'
    fi

    printf '\n**5) Lücken**\n'
    if [ -s "$GAPFILE" ]; then sed 's/^/   • /' "$GAPFILE"; else printf '   • keine — alle Quellen haben geliefert\n'; fi
  } > "$out"
  printf '%s' "$out"
}

# ---------------------------------------------------------------- Transport

TRANSPORT_FAIL=0
BUZZ_OK=0
TG_OK=0

post_buzz() {
  local file="$1" ch="$2"
  local body; body="$(cat "$file")"
  local resp
  resp="$(BUZZ_KEY="$POST_KEY" bash "$HERE/buzzx.sh" messages send --channel "$ch" --content "$body" 2>&1)"
  if printf '%s' "$resp" | grep -q '"accepted":true'; then
    BUZZ_OK=1
    printf 'buzz: gepostet in %s (event %s)\n' "$ch" "$(printf '%s' "$resp" | jq -r '.event_id' 2>/dev/null | cut -c1-16)" >&2
  else
    printf 'buzz: POST FEHLGESCHLAGEN: %s\n' "$(printf '%s' "$resp" | head -c 200)" >&2
    TRANSPORT_FAIL=1
  fi
}

# Gleiche Mechanik wie in .empire/gate.sh — ein Format, eine Quelle.
read_secret() {
  local name="$1" val="${!1:-}"
  if [ -z "$val" ] && [ -f "$SECRETS_FILE" ]; then
    val="$(grep -m1 "^${name}=" "$SECRETS_FILE" | cut -d= -f2- | tr -d "$CR")"
  fi
  printf '%s' "$val"
}

post_telegram() {
  local file="$1"
  local token chat
  token="$(read_secret TELEGRAM_BOT_TOKEN)"; chat="$(read_secret TELEGRAM_CHAT_ID)"
  if [ -z "$token" ] || [ -z "$chat" ]; then
    echo "telegram: Token/Chat-ID nicht lesbar — NICHT gespiegelt" >&2; TRANSPORT_FAIL=1; return
  fi
  # Telegram deckelt bei 4096 Zeichen; sichtbar kürzen statt still abschneiden.
  # Markup wird entfernt statt geparst: Telegrams Legacy-Markdown scheitert an
  # `_` in Repo-Namen und an `**` (dort ist Fett `*x*`) — gemessen. Reiner Text
  # kommt immer an; die formatierte Fassung steht im Buzz-Kanal.
  local body; body="$(sed -e 's/\*\*//g' -e 's/`//g' "$file")"
  if [ "${#body}" -gt 3900 ]; then body="${body:0:3900}"$'\n\n…gekürzt für Telegram — Volltext im Buzz-Kanal.'; fi
  # UTF-8 stirbt in curls argv (MSYS) — Body IMMER über stdin.
  # Kein parse_mode: das Markup ist oben schon entfernt, und Telegrams
  # Legacy-Markdown stolpert zusaetzlich ueber "[repo#nr]" (Link-Syntax ohne
  # Ziel) — gemessen. Ein Pfad statt Versuch-und-Fallback.
  local resp
  resp="$(jq -n --arg c "$chat" --arg t "$body" '{chat_id:$c, text:$t, disable_web_page_preview:true}' \
          | curl -sS --max-time 30 -X POST -H 'Content-Type: application/json' \
                 --data-binary @- "https://api.telegram.org/bot$token/sendMessage" 2>&1)"
  if [ "$(printf '%s' "$resp" | jq -r '.ok' 2>/dev/null)" = "true" ]; then
    TG_OK=1
    printf 'telegram: zugestellt (message_id %s)\n' "$(printf '%s' "$resp" | jq -r '.result.message_id')" >&2
  else
    printf 'telegram: ZUSTELLUNG FEHLGESCHLAGEN: %s\n' "$(printf '%s' "$resp" | head -c 200)" >&2
    TRANSPORT_FAIL=1
  fi
}

append_vault() {
  local file="$1" label="$2"
  [ -f "$VAULT_LOG" ] || { echo "vault: $VAULT_LOG fehlt — nicht protokolliert" >&2; TRANSPORT_FAIL=1; return; }
  local kern gaps
  gaps="$(gapcount)"
  if [ "$MODE" = "gate-batch" ]; then
    local nb=0; [ -f "$TMP/blocked.json" ] && nb="$(jq -r 'length' "$TMP/blocked.json")"
    kern="$nb offene blocked-munir, Top-3 vorgekaut"
  elif [ "$MODE" = "wochen-review" ]; then
    local nc="?" nb="?"
    [ -f "$TMP/closed.json" ]  && nc="$(jq -r 'length' "$TMP/closed.json")"
    [ -f "$TMP/blocked.json" ] && nb="$(jq -r 'length' "$TMP/blocked.json")"
    kern="$WEEK_LABEL — $nc Issues geschlossen, $nb blocked-munir offen"
  else
    local nb="?" ready="?"
    [ -f "$TMP/blocked.json" ] && nb="$(jq -r 'length' "$TMP/blocked.json")"
    [ -f "$TMP/lage.json" ] && ready="$(jq -r '.backlog.ready_total // "?"' "$TMP/lage.json" | tr -d "$CR")"
    kern="$ready ready im Backlog, $nb blocked-munir"
  fi
  # Die Zeile behauptet nur Kanäle, die tatsächlich zugestellt haben.
  local where=""
  [ "$POST" = "1" ] && [ "$BUZZ_OK" = "1" ] && where="${where}Buzz-Kanal"
  [ "$TG" = "1" ] && [ "$TG_OK" = "1" ] && where="${where:+$where + }Telegram"
  [ -z "$where" ] && where="nur Vault (kein Transport erfolgreich)"
  bash "$VAULT_LOG" ritual "$label $(date '+%H:%M') — $kern; $gaps benannte Lücke(n); zugestellt: $where" >&2 \
    || { echo "vault: Append fehlgeschlagen" >&2; TRANSPORT_FAIL=1; }
}

# ----------------------------------------------------------------- Ausführung

case "$MODE" in
  morgenbrief)
    collect_foki
    collect_lagebild "backlog,n8n,server,pay"
    collect_nest
    collect_calendar
    collect_inbox
    collect_blocked
    BRIEF="$(render_morgenbrief)"
    CH="${BUZZ_CHANNEL:-$CH_GENERAL}"; LABEL="🌅 Morgenbrief"
    ;;
  gate-batch)
    collect_blocked
    collect_crm_deletions || true
    BRIEF="$(render_gate_batch)"
    CH="${BUZZ_CHANNEL:-$CH_GATES}"; LABEL="🔐 Gate-Batch"
    ;;
  wochen-review)
    PREV_WEEK=""
    collect_lagebild "backlog,pay"
    collect_blocked
    collect_closed
    collect_fillers
    # Ein fehlendes fillers.json würde `jq --slurpfile` hart abbrechen und den
    # ganzen Vorschlagsblock mitreißen — inklusive der P1-money-Zeilen, die
    # schon da sind. Die Lücke ist oben benannt; hier zählt nur, dass der
    # Ausfall lokal bleibt.
    [ -f "$TMP/fillers.json" ] || echo '[]' > "$TMP/fillers.json"
    # Reihenfolge ist bindend: erst die Vorwoche LESEN, dann diese Woche
    # SCHREIBEN — sonst überschreibt der Lauf seine eigene Vergleichsbasis,
    # sobald zweimal in derselben ISO-Woche gelaufen wird.
    load_prev_snapshot || true
    write_snapshot || true
    BRIEF="$(render_wochen_review)"
    CH="${BUZZ_CHANNEL:-$CH_GENERAL}"; LABEL="📊 Wochen-Review"
    ;;
esac

[ -s "$BRIEF" ] || { echo "ritual: kein Brief erzeugt" >&2; exit 2; }
cat "$BRIEF"

if [ "$DRY" = "1" ]; then
  echo "--- dry-run: nichts gepostet ---" >&2
else
  [ "$POST" = "1" ] && post_buzz "$BRIEF" "$CH"
  [ "$TG" = "1" ] && post_telegram "$BRIEF"
  [ "$VAULT" = "1" ] && append_vault "$BRIEF" "$LABEL"
fi

# --------------------------------------------------------- Lauf-Quittung (#15)
# Eine Zeile je Lauf, append-only, ausserhalb des oeffentlichen Repos. Sie ist
# der EINZIGE Beleg dafuer, DASS ein Ritual lief — Kanal-Posts beweisen nur die
# erfolgreichen Transporte, ein Lauf ohne Transport hinterlaesst dort nichts.
# Verbraucher: Cockpit-Kachel "Rituale" (#15). Kein Inhalt, nur Metadaten:
# der Brief selbst kann Kundendaten tragen, diese Zeile nie.
ritual_receipt() {
  local rc="$1" file="${RITUAL_RUNS_FILE:-$HOME/.buzz/ritual-runs.jsonl}"
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 0
  # Naives >> klebt an eine Datei ohne abschliessendes Newline (gemessen bei
  # vault-log.sh) — deshalb erst pruefen, dann anhaengen.
  if [ -s "$file" ] && [ "$(tail -c 1 "$file" 2>/dev/null | od -An -c | tr -d ' ')" != '\n' ]; then
    printf '\n' >> "$file" 2>/dev/null || return 0
  fi
  jq -cn --arg ritual "$MODE" --arg label "${LABEL:-}" \
        --arg at "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
        --argjson exit_code "$rc" --argjson gaps "$(gapcount)" \
        --argjson dry_run "$DRY" \
        --arg transports "$( { [ "$POST" = "1" ] && [ "${BUZZ_OK:-0}" = "1" ] && printf 'buzz '; \
                               [ "$TG" = "1" ]   && [ "${TG_OK:-0}" = "1" ]   && printf 'telegram '; \
                               [ "$VAULT" = "1" ] && printf 'vault'; } | tr -s ' ' | sed 's/ $//' )" \
    '{ritual:$ritual, label:$label, at:$at, exit_code:$exit_code, gaps:$gaps,
      dry_run:($dry_run==1), transports:($transports|split(" ")|map(select(length>0)))}' \
    >> "$file" 2>/dev/null || true
}

if [ "$TRANSPORT_FAIL" = "1" ]; then ritual_receipt 3; exit 3; fi
if [ -s "$GAPFILE" ]; then ritual_receipt 1; exit 1; fi
ritual_receipt 0
exit 0
