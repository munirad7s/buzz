#!/usr/bin/env bash
# lagebild.sh — Ops-Lagebild auf Zuruf (buzz#7)
#
# Vier Blöcke, alle NUR LESEND:
#   (a) backlog  — ready-Bestand je Priorität über alle munirad7s-Repos + Top-3 P1-money
#   (b) n8n      — Fehler-Executions der letzten 24 h mit Workflow-Namen
#   (c) server   — adas-hetzner: uptime, Disk, Container, Uptime-Kuma-Monitore
#   (d) pay      — Mollie: aktive Subscriptions + letzte Payment-Status
#
# Aufruf:
#   bash .empire/tools/lagebild.sh                      # Markdown für den Kanal
#   bash .empire/tools/lagebild.sh --format json        # Maschinenformat (Morgenbrief #11, Cockpit #17)
#   bash .empire/tools/lagebild.sh --blocks server,n8n  # nur einzelne Blöcke
#   bash .empire/tools/lagebild.sh --amounts            # Beträge mit ausgeben (nur privater Kanal!)
#
# Exit-Codes (beantworten NUR "war die Erhebung vollständig?", nicht "ist die Lage gut?"):
#   0 = alle angeforderten Blöcke vollständig erhoben (Inhalt darf WARN sein)
#   1 = Bericht unvollständig — eine Teil-Quelle nicht lesbar (Kuma, einzelnes Repo)
#   2 = mindestens ein Block komplett tot (Quelle antwortet nicht)
#   3 = Zusammenbau fehlgeschlagen — es werden gar keine Zahlen ausgegeben
#
# ----------------------------------------------------------------------------
# GRUNDGESETZ DIESES SCRIPTS: KEINE STILLEN NULLEN.
# Eine Quelle, die nicht antwortet, wird als FEHLER ausgewiesen — niemals als 0
# und niemals als grün. Jede Zahl stammt aus der Quelle, keine aus einem Modell.
#
# FALLEN, DIE HIER BEWUSST UMGANGEN WERDEN (alle real getreten):
#   1. gh-Truncation: "gh search issues -L n" schneidet bei erreichtem Limit STILL ab.
#      -> eine Abfrage je Repo; wird das Limit erreicht, meldet der Block TRUNCATED.
#   2. jq unter Windows schreibt CRLF. Ohne "tr -d '\r'" hängt an jedem Feld ein CR
#      und "gh -R repo<CR>" antwortet "Could not resolve to a Repository".
#   3. HTTP 200 beweist nichts: jede HTTP-Quelle wird zusätzlich auf verwertbaren
#      Payload geprüft (Mollie: _embedded, n8n: .data als Array).
#   4. SSH kann teilweise durchlaufen: der Remote-Block endet mit einer Sentinel-Zeile.
#      Fehlt sie, ist der Block FEHLER — auch wenn schon Zeilen angekommen sind.
#   5. n8n prunt Executions: 0 Fehler ist erst dann grün, wenn im selben Fenster
#      überhaupt Executions gelaufen sind. Sonst WARN "Datenlage prüfen".
#   6. priorities.json ist eine gepflegte Liste und veraltet still: drei Repos mit
#      ready-/P1-money-/blocked-munir-Tickets standen in keiner Zeile, ihre
#      Blocker fehlten in JEDER Zahl (buzz#61). -> Der Backlog-Block bildet die
#      Vereinigung aus Liste und owner-weiter Label-Suche und meldet die
#      Nachzügler als `repos_untracked` namentlich, statt sie still zu schlucken.
# ----------------------------------------------------------------------------

set -uo pipefail

FORMAT="md"
BLOCKS="backlog,n8n,server,pay"
SHOW_AMOUNTS=0
WINDOW_HOURS="${LAGEBILD_WINDOW_HOURS:-24}"
SSH_HOST="${LAGEBILD_SSH_HOST:-hetzner}"
MAX_JOBS="${LAGEBILD_MAX_JOBS:-8}"
REPO_LIMIT="${LAGEBILD_REPO_LIMIT:-200}"
PRIORITIES="${LAGEBILD_PRIORITIES:-C:/Users/rescue/projects/adas-empire/priorities.json}"
SECRETS_DIR="${LAGEBILD_SECRETS_DIR:-$HOME/.secrets}"

while [ $# -gt 0 ]; do
  case "$1" in
    --format) FORMAT="${2:-md}"; shift 2 ;;
    --blocks) BLOCKS="${2:-}"; shift 2 ;;
    --amounts) SHOW_AMOUNTS=1; shift ;;
    --window) WINDOW_HOURS="${2:-24}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unbekannte Option: $1" >&2; exit 64 ;;
  esac
done

case "$FORMAT" in md|json) ;; *) echo "--format muss md oder json sein" >&2; exit 64 ;; esac

for tool in jq curl; do
  command -v "$tool" >/dev/null || { echo "$tool fehlt" >&2; exit 1; }
done

CR=$'\r'
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STAMP="$(date '+%Y-%m-%d %H:%M')"
CUTOFF="$(date -u -d "-${WINDOW_HOURS} hours" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
          || date -u -v-"${WINDOW_HOURS}"H '+%Y-%m-%dT%H:%M:%SZ')"

want() { case ",$BLOCKS," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
jqr()  { jq "$@" | tr -d "$CR"; }

# Ein Block ohne verwertbare Quelle schreibt IMMER dieses Ergebnis — nie Nullen.
block_error() {
  jq -n --arg state error --arg reason "$2" '{state:$state, reason:$reason}' > "$TMP/$1.json"
}

# Lädt KEY=VALUE aus einer Secrets-Datei, ohne bereits gesetzte Env zu überschreiben.
# Genau das macht die Rot-Probe möglich: MOLLIE_LIVE_API_KEY=falsch bash lagebild.sh
load_secret_file() {
  local file="$1"; shift
  [ -f "$file" ] || return 1
  local key val line
  for key in "$@"; do
    eval "val=\${$key:-}"
    [ -n "$val" ] && continue
    line="$(grep -E "^[[:space:]]*${key}=" "$file" | tail -1 | tr -d "$CR")"
    [ -z "$line" ] && continue
    val="${line#*=}"
    val="${val%\"}"; val="${val#\"}"
    export "$key=$val"
  done
  return 0
}

# ---------------------------------------------------------------- (a) Backlog
block_backlog() {
  command -v gh >/dev/null || { block_error backlog "gh CLI nicht im PATH"; return; }
  if ! gh auth status >/dev/null 2>&1; then
    block_error backlog "gh nicht authentifiziert (gh auth status)"; return
  fi

  local repos="" discovered="" untracked=""
  if [ -n "${LAGEBILD_REPOS:-}" ]; then
    # Explizite Vorgabe bleibt explizit — sonst wäre die Rot-Probe
    # "Repo unlesbar" nicht mehr durchführbar.
    repos="$(printf '%s' "$LAGEBILD_REPOS" | tr ',' '\n')"
  elif [ -f "$PRIORITIES" ]; then
    repos="$(jqr -r '.repo_order[].repo' "$PRIORITIES" 2>/dev/null)"
    # Der Fork selbst steht nicht in priorities.json, führt aber die Zentrale.
    printf '%s\n' "$repos" | grep -qx 'munirad7s/buzz' || repos="$repos"$'\n'"munirad7s/buzz"

    # priorities.json ist eine gepflegte Liste und hinkt neuen Repos hinterher.
    # Gemessen 2026-08-01 (buzz#61): drei Repos mit ready-/P1-money-/
    # blocked-munir-Tickets standen in keiner Zeile — ihre Blocker tauchten in
    # keiner Zahl auf. Deshalb: Vereinigung aus Liste und den Repos, in denen
    # eine owner-weite Suche Empire-Labels sieht. Der Fund wird zusätzlich
    # namentlich gemeldet, damit die Liste nachgepflegt wird statt still zu
    # veralten.
    local lbl found
    for lbl in ready blocked-munir in-progress; do
      found="$(gh search issues --owner munirad7s --state open --label "$lbl" \
                 --json repository -L 500 2>/dev/null \
               | jqr -r '.[].repository.nameWithOwner' 2>/dev/null)"
      [ -n "$found" ] && discovered="$discovered$found"$'\n'
    done
    if [ -n "$discovered" ]; then
      printf '%s' "$discovered" | tr -d "$CR" | awk 'NF' | sort -u > "$TMP/disc.txt"
      printf '%s' "$repos"      | tr -d "$CR" | awk 'NF' | sort -u > "$TMP/known.txt"
      untracked="$(comm -23 "$TMP/disc.txt" "$TMP/known.txt" | tr '\n' ' ' | sed 's/ *$//')"
      repos="$(cat "$TMP/disc.txt" "$TMP/known.txt" | sort -u)"
    fi
  else
    block_error backlog "keine Repo-Quelle: $PRIORITIES fehlt und LAGEBILD_REPOS ist leer"; return
  fi
  [ -z "$(printf '%s' "$repos" | tr -d '[:space:]')" ] && { block_error backlog "Repo-Liste leer"; return; }

  mkdir -p "$TMP/repos"
  local repo idx=0
  while IFS= read -r repo; do
    repo="$(printf '%s' "$repo" | tr -d "$CR" | tr -d '[:space:]')"
    [ -z "$repo" ] && continue
    idx=$((idx + 1))
    while [ "$(jobs -rp | wc -l)" -ge "$MAX_JOBS" ]; do sleep 0.2; done
    (
      slug="$(printf '%s' "$repo" | tr '/' '~')"
      if out="$(gh issue list -R "$repo" --state open -L "$REPO_LIMIT" \
                  --json number,title,labels,createdAt,url 2>"$TMP/repos/$slug.err" </dev/null)" \
         && [ -n "$out" ]; then
        printf '%s' "$out" | jq --arg repo "$repo" '{repo:$repo, issues:.}' > "$TMP/repos/$slug.json" 2>/dev/null \
          || rm -f "$TMP/repos/$slug.json"
      fi
    ) &
  done < <(printf '%s\n' "$repos")
  wait

  local files
  files="$(ls "$TMP/repos"/*.json 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$files" -eq 0 ]; then
    block_error backlog "kein einziges Repo lesbar (gh-Abfragen alle fehlgeschlagen)"; return
  fi

  # Unlesbare Repos werden namentlich gemeldet, nicht als 0 verbucht.
  local unreadable="[]" u_list=""
  while IFS= read -r repo; do
    repo="$(printf '%s' "$repo" | tr -d "$CR" | tr -d '[:space:]')"
    [ -z "$repo" ] && continue
    [ -f "$TMP/repos/$(printf '%s' "$repo" | tr '/' '~').json" ] || u_list="$u_list$repo"$'\n'
  done < <(printf '%s\n' "$repos")
  [ -n "$u_list" ] && unreadable="$(printf '%s' "$u_list" | jq -R -s 'split("\n")|map(select(length>0))')"

  jq -s \
    --argjson unreadable "$unreadable" \
    --argjson untracked "$(printf '%s' "$untracked" | tr ' ' '\n' | jq -R -s 'split("\n")|map(select(length>0))')" \
    --argjson expected "$idx" \
    --argjson limit "$REPO_LIMIT" '
    . as $repos
    | ($repos | map(select((.issues|length) >= $limit) | .repo)) as $truncated
    | ($repos | map(.issues[] as $i | {repo:.repo, number:$i.number, title:$i.title,
                                       createdAt:$i.createdAt, url:$i.url,
                                       labels:($i.labels|map(.name))})) as $issues
    | ($issues | map(select(.labels|index("ready")))) as $ready_all
    | ($ready_all | map(select((.labels|index("blocked-munir"))|not))) as $ready
    | {
        state: (if ($truncated|length) > 0 or ($unreadable|length) > 0 or ($untracked|length) > 0 then "warn" else "ok" end),
        repos_expected: $expected,
        repos_read: ($repos|length),
        repos_unreadable: $unreadable,
        # Repos, die Empire-Tickets tragen, aber in keiner priorities.json-Zeile
        # stehen. Sie sind mitgezaehlt - aber die Liste gehoert nachgepflegt.
        repos_untracked: $untracked,
        repos_truncated: $truncated,
        ready_total: ($ready|length),
        by_prio: {
          "P1-money": ($ready|map(select(.labels|index("P1-money")))|length),
          "P1":       ($ready|map(select((.labels|index("P1-money"))|not) | select(.labels|index("P1")))|length),
          "P2":       ($ready|map(select((.labels|index("P1-money"))|not) | select((.labels|index("P1"))|not) | select(.labels|index("P2")))|length),
          "P3":       ($ready|map(select((.labels|index("P1-money"))|not) | select((.labels|index("P1"))|not) | select((.labels|index("P2"))|not) | select(.labels|index("P3")))|length),
          "ohne":     ($ready|map(select([.labels[]|select(.=="P1-money" or .=="P1" or .=="P2" or .=="P3")]|length==0))|length)
        },
        in_progress: ($issues|map(select(.labels|index("in-progress")))|length),
        blocked: ($issues|map(select(.labels|index("blocked-munir")))|length),
        # je Repo — macht die Stichprobe gegen "gh issue list -R <repo> --label ready" exakt
        by_repo: ($repos | map({
            repo: .repo,
            open: (.issues|length),
            ready: (.issues|map(select([.labels[].name]|index("ready")))|length),
            ready_unblocked: (.issues|map(select([.labels[].name]|index("ready")) | select(([.labels[].name]|index("blocked-munir"))|not))|length),
            p1money: (.issues|map(select([.labels[].name]|index("ready")) | select([.labels[].name]|index("P1-money")))|length),
            blocked: (.issues|map(select([.labels[].name]|index("blocked-munir")))|length)
          }) | sort_by(-.ready)),
        ready_incl_blocked: ($ready_all|length),
        top_money: ($ready | map(select(.labels|index("P1-money")))
                    | sort_by(.createdAt) | .[0:3]
                    | map({repo, number, title})),
        # Die aeltesten offenen Munir-Gates, nach Prio dann Alter — dieselbe
        # Sortierung wie ritual.sh gate-batch, aber aus den Issues, die dieser
        # Block ohnehin schon geholt hat (kein zusaetzlicher API-Aufruf, kein
        # Doppelbau der Sammel-Logik). Verbraucher: Cockpit-Kachel "Gates" (#15).
        top_blocked: ($issues | map(select(.labels|index("blocked-munir")))
                    | sort_by( (if (.labels|index("P1-money")) then 0
                                elif (.labels|index("P1")) then 1
                                elif (.labels|index("P2")) then 2 else 3 end), .createdAt )
                    | .[0:3]
                    | map({repo, number, title, url, createdAt,
                           prio: (if (.labels|index("P1-money")) then "P1-money"
                                  elif (.labels|index("P1")) then "P1"
                                  elif (.labels|index("P2")) then "P2"
                                  elif (.labels|index("P3")) then "P3" else "ohne" end)})),
        reason: (if ($unreadable|length) > 0 then "nicht lesbar: " + ($unreadable|join(", "))
                 elif ($untracked|length) > 0 then "nicht in priorities.json (mitgezaehlt, Liste nachpflegen): " + ($untracked|join(", "))
                 elif ($truncated|length) > 0 then "Limit erreicht (mögliche Truncation): " + ($truncated|join(", "))
                 else null end)
      }' "$TMP/repos"/*.json > "$TMP/backlog.json" 2>"$TMP/backlog.err" \
    || block_error backlog "Aggregation fehlgeschlagen: $(head -c 200 "$TMP/backlog.err" 2>/dev/null)"
}

# -------------------------------------------------------------------- (b) n8n
block_n8n() {
  load_secret_file "$SECRETS_DIR/master.env" N8N_API_URL N8N_API_KEY
  if [ -z "${N8N_API_URL:-}" ] || [ -z "${N8N_API_KEY:-}" ]; then
    block_error n8n "N8N_API_URL/N8N_API_KEY weder in Env noch in $SECRETS_DIR/master.env"; return
  fi

  local code
  code="$(curl -s -m 30 -o "$TMP/n8n_err.json" -w '%{http_code}' \
          -H "X-N8N-API-KEY: $N8N_API_KEY" "$N8N_API_URL/executions?status=error&limit=250")"
  if [ "$code" != "200" ]; then
    block_error n8n "n8n-API HTTP $code auf /executions?status=error"; return
  fi
  if ! jq -e '.data|type=="array"' "$TMP/n8n_err.json" >/dev/null 2>&1; then
    block_error n8n "n8n-API antwortete 200, aber ohne verwertbares .data-Array"; return
  fi

  code="$(curl -s -m 30 -o "$TMP/n8n_all.json" -w '%{http_code}' \
          -H "X-N8N-API-KEY: $N8N_API_KEY" "$N8N_API_URL/executions?limit=250")"
  if [ "$code" != "200" ] || ! jq -e '.data|type=="array"' "$TMP/n8n_all.json" >/dev/null 2>&1; then
    # Ohne Nenner ist "0 Fehler" nicht beweisbar -> Block bleibt rot statt falsch-grün.
    block_error n8n "Nenner nicht ermittelbar (Gesamt-Executions HTTP $code)"; return
  fi

  # Workflow-IDs -> Namen (nur die tatsächlich betroffenen, ein Call je ID)
  : > "$TMP/wfnames.tsv"
  local wid wname wcode
  while IFS= read -r wid; do
    [ -z "$wid" ] && continue
    wcode="$(curl -s -m 20 -o "$TMP/wf.json" -w '%{http_code}' \
             -H "X-N8N-API-KEY: $N8N_API_KEY" "$N8N_API_URL/workflows/$wid")"
    if [ "$wcode" = "200" ]; then
      wname="$(jqr -r '.name // empty' "$TMP/wf.json")"
    else
      wname=""
    fi
    [ -z "$wname" ] && wname="(Name nicht auflösbar: $wid)"
    printf '%s\t%s\n' "$wid" "$wname" >> "$TMP/wfnames.tsv"
  done < <(jqr -r --arg c "$CUTOFF" '[.data[]|select(.startedAt >= $c)|.workflowId]|unique|.[]' "$TMP/n8n_err.json")

  jq -n \
    --arg cutoff "$CUTOFF" \
    --argjson window "$WINDOW_HOURS" \
    --slurpfile err "$TMP/n8n_err.json" \
    --slurpfile all "$TMP/n8n_all.json" \
    --rawfile names "$TMP/wfnames.tsv" '
    ($names | split("\n") | map(select(length>0) | split("\t") | {key:.[0], value:.[1]}) | from_entries) as $wf
    | ($err[0].data | map(select(.startedAt >= $cutoff))) as $e
    | ($all[0].data | map(select(.startedAt >= $cutoff))) as $a
    | {
        state: (if ($e|length) > 0 then "warn" elif ($a|length) == 0 then "warn" else "ok" end),
        window_hours: $window,
        errors_total: ($e|length),
        executions_in_window: ($a|length),
        executions_window_is_floor: (($all[0].data|length) >= 250),
        by_workflow: ($e | group_by(.workflowId) | map({
            workflow: ($wf[.[0].workflowId] // .[0].workflowId),
            count: length,
            last_execution: (max_by(.startedAt) | .id),
            last_at: (max_by(.startedAt) | .startedAt)
          }) | sort_by(-.count)),
        reason: (if ($a|length) == 0 then "keine einzige Execution im Fenster — Datenlage prüfen (Pruning oder n8n steht)" else null end)
      }' > "$TMP/n8n.json" 2>/dev/null \
    || block_error n8n "Aggregation der n8n-Antwort fehlgeschlagen"
}

# ----------------------------------------------------------------- (c) Server
block_server() {
  command -v ssh >/dev/null || { block_error server "ssh nicht im PATH"; return; }

  # Die erste stdin-Zeile setzt die Variablen — so bleibt der Remote-Block unquoted-frei
  # und der Kuma-Pfad ist per Env rot-probierbar, ohne den Server anzufassen.
  { printf 'KUMA_CONTAINER=%s\n' "${LAGEBILD_KUMA_CONTAINER:-agency-kuma}"
    cat <<'REMOTE'
set -u
echo "uptime_days=$(awk '{printf "%d", $1/86400}' /proc/uptime 2>/dev/null)"
echo "load1=$(awk '{print $1}' /proc/loadavg 2>/dev/null)"
df -Ph / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print "disk_used_pct="$5; print "disk_avail="$4}'
if command -v docker >/dev/null 2>&1; then
  echo "docker_ok=1"
  echo "containers_running=$(docker ps -q 2>/dev/null | wc -l)"
  echo "containers_exited=$(docker ps -aq -f status=exited 2>/dev/null | wc -l)"
  echo "containers_unhealthy=$(docker ps -q -f health=unhealthy 2>/dev/null | wc -l)"
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$KUMA_CONTAINER"; then
    if docker exec "$KUMA_CONTAINER" sqlite3 "file:/app/data/kuma.db?mode=ro" \
         "SELECT 'kuma_row=' || h.status || '|' || m.name FROM monitor m JOIN heartbeat h ON h.id=(SELECT id FROM heartbeat WHERE monitor_id=m.id ORDER BY time DESC LIMIT 1) WHERE m.active=1;" 2>/dev/null
    then
      # agency-infra#134: aktive Monitore OHNE jede Benachrichtigung. Ein
      # stummer Waechter ist teurer als keiner, weil man sich auf ihn
      # verlaesst — gobd-export (steuerliche Aufbewahrungspflicht) hing so da.
      # Bewusst eine eigene Abfrage OHNE heartbeat-JOIN: ein Push-Monitor, der
      # noch nie gepusht hat, faellt aus der Zeile oben komplett heraus.
      docker exec "$KUMA_CONTAINER" sqlite3 "file:/app/data/kuma.db?mode=ro" \
        "SELECT 'kuma_silent=' || m.name FROM monitor m WHERE m.active=1 AND NOT EXISTS (SELECT 1 FROM monitor_notification mn WHERE mn.monitor_id=m.id);" 2>/dev/null
      echo "kuma_ok=1"
    else echo "kuma_ok=0"; fi
  else
    echo "kuma_ok=0"
  fi
else
  echo "docker_ok=0"
fi
echo "REMOTE_DONE=1"
REMOTE
  } | timeout 60 ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
      "$SSH_HOST" 'bash -s' > "$TMP/server.raw" 2>"$TMP/server.err"

  # Sentinel: ein halb durchgelaufener SSH-Block ist FEHLER, kein Teilerfolg.
  if ! grep -q '^REMOTE_DONE=1$' "$TMP/server.raw" 2>/dev/null; then
    block_error server "ssh $SSH_HOST unvollständig/fehlgeschlagen: $(head -c 160 "$TMP/server.err" 2>/dev/null | tr '\n' ' ')"
    return
  fi

  local uptime_days load1 disk_pct disk_avail docker_ok running exited unhealthy kuma_ok
  uptime_days="$(grep -m1 '^uptime_days=' "$TMP/server.raw" | cut -d= -f2)"
  load1="$(grep -m1 '^load1=' "$TMP/server.raw" | cut -d= -f2)"
  disk_pct="$(grep -m1 '^disk_used_pct=' "$TMP/server.raw" | cut -d= -f2)"
  disk_avail="$(grep -m1 '^disk_avail=' "$TMP/server.raw" | cut -d= -f2)"
  docker_ok="$(grep -m1 '^docker_ok=' "$TMP/server.raw" | cut -d= -f2)"
  running="$(grep -m1 '^containers_running=' "$TMP/server.raw" | cut -d= -f2)"
  exited="$(grep -m1 '^containers_exited=' "$TMP/server.raw" | cut -d= -f2)"
  unhealthy="$(grep -m1 '^containers_unhealthy=' "$TMP/server.raw" | cut -d= -f2)"
  kuma_ok="$(grep -m1 '^kuma_ok=' "$TMP/server.raw" | cut -d= -f2)"

  grep '^kuma_row=' "$TMP/server.raw" | sed 's/^kuma_row=//' > "$TMP/kuma.txt" || true
  grep '^kuma_silent=' "$TMP/server.raw" | sed 's/^kuma_silent=//' > "$TMP/kuma_silent.txt" || true

  jq -n \
    --arg uptime_days "${uptime_days:-}" --arg load1 "${load1:-}" \
    --arg disk_pct "${disk_pct:-}" --arg disk_avail "${disk_avail:-}" \
    --arg docker_ok "${docker_ok:-0}" --arg running "${running:-}" \
    --arg exited "${exited:-}" --arg unhealthy "${unhealthy:-}" \
    --arg kuma_ok "${kuma_ok:-0}" --rawfile kuma "$TMP/kuma.txt" \
    --rawfile kuma_silent "$TMP/kuma_silent.txt" '
    ($kuma | split("\n") | map(select(length>0) | split("|") | {status:(.[0]|tonumber), name:(.[1:]|join("|"))})) as $mon
    | ($mon|map(select(.status==0))) as $down
    | ($mon|map(select(.status==2))) as $pending
    | ($kuma_silent | split("\n") | map(select(length>0))) as $silent
    | {
        state: (if ($docker_ok != "1") or ($kuma_ok != "1") then "warn"
                elif ($down|length) > 0 then "warn"
                elif ($silent|length) > 0 then "warn"
                elif (($disk_pct|tonumber?) // 0) >= 90 then "warn"
                elif (($unhealthy|tonumber?) // 0) > 0 then "warn"
                else "ok" end),
        host: "adas-hetzner",
        uptime_days: ($uptime_days|tonumber? // null),
        load1: ($load1|tonumber? // null),
        disk_used_pct: ($disk_pct|tonumber? // null),
        disk_avail: $disk_avail,
        containers_running: ($running|tonumber? // null),
        containers_exited: ($exited|tonumber? // null),
        containers_unhealthy: ($unhealthy|tonumber? // null),
        kuma_readable: ($kuma_ok == "1"),
        kuma_active: ($mon|length),
        kuma_down: ($down|map(.name)),
        kuma_pending: ($pending|map(.name)),
        kuma_silent: $silent,
        reason: (if ($docker_ok != "1") then "docker auf dem Host nicht abfragbar"
                 elif ($kuma_ok != "1") then "Uptime-Kuma nicht lesbar — Monitor-Status UNBEKANNT, nicht grün"
                 elif ($down|length) > 0 then (($down|length)|tostring) + " Monitor(e) rot"
                 elif ($silent|length) > 0 then (($silent|length)|tostring) + " Monitor(e) STUMM (keine Benachrichtigung): " + ($silent|join(", "))
                 elif (($disk_pct|tonumber? // 0) >= 90) then "Disk >= 90 %"
                 elif (($unhealthy|tonumber? // 0) > 0) then "unhealthy Container"
                 else null end)
      }' > "$TMP/server.json" 2>/dev/null \
    || block_error server "Aggregation der Server-Antwort fehlgeschlagen"
}

# --------------------------------------------------------------- (d) Zahlungen
block_pay() {
  load_secret_file "$SECRETS_DIR/mollie-api.env" MOLLIE_LIVE_API_KEY
  if [ -z "${MOLLIE_LIVE_API_KEY:-}" ]; then
    block_error pay "MOLLIE_LIVE_API_KEY weder in Env noch in $SECRETS_DIR/mollie-api.env"; return
  fi

  local ua='buzz-lagebild/1.0'
  local code
  code="$(curl -s -m 30 -o "$TMP/subs.json" -w '%{http_code}' -A "$ua" \
          -H "Authorization: Bearer $MOLLIE_LIVE_API_KEY" \
          'https://api.mollie.com/v2/subscriptions?limit=250')"
  if [ "$code" != "200" ]; then
    block_error pay "Mollie /subscriptions HTTP $code — $(jqr -r '.title // .detail // empty' "$TMP/subs.json" 2>/dev/null | head -c 120)"
    return
  fi
  if ! jq -e '._embedded.subscriptions|type=="array"' "$TMP/subs.json" >/dev/null 2>&1; then
    block_error pay "Mollie /subscriptions: 200 ohne verwertbares _embedded.subscriptions"; return
  fi

  code="$(curl -s -m 30 -o "$TMP/pays.json" -w '%{http_code}' -A "$ua" \
          -H "Authorization: Bearer $MOLLIE_LIVE_API_KEY" \
          'https://api.mollie.com/v2/payments?limit=50')"
  if [ "$code" != "200" ] || ! jq -e '._embedded.payments|type=="array"' "$TMP/pays.json" >/dev/null 2>&1; then
    block_error pay "Mollie /payments HTTP $code ohne verwertbare Liste"; return
  fi

  local since30
  since30="$(date -u -d '-30 days' '+%Y-%m-%d' 2>/dev/null || date -u -v-30d '+%Y-%m-%d')"

  jq -n \
    --argjson amounts "$SHOW_AMOUNTS" \
    --arg since30 "$since30" \
    --slurpfile subs "$TMP/subs.json" \
    --slurpfile pays "$TMP/pays.json" '
    ($subs[0]._embedded.subscriptions) as $s
    | ($pays[0]._embedded.payments) as $p
    | ($p | map(select(.createdAt >= $since30))) as $p30
    | ($s | map(select(.status=="active"))) as $act
    # Ein "expired" ohne gewählte Methode ist KEIN Zahlungsfehler: der Checkout-Link
    # wurde nie geöffnet. Beides in einen Topf zu werfen erzeugt Dauer-Fehlalarm —
    # gemessen an social-poster-wizard#83, wo 13 "fehlgeschlagene" Zahlungen nach
    # Prüfung ausnahmslos nie begonnene Checkouts waren.
    | ($p30 | map(select((.status=="failed" or .status=="expired") and (.method != null)))) as $real_fail
    | ($p30 | map(select((.status=="failed" or .status=="expired") and (.method == null)))) as $never_started
    | {
        state: (if ($act|length) == 0 then "warn"
                elif ($real_fail|length) > 0 then "warn"
                else "ok" end),
        subscriptions_active: ($act|length),
        subscriptions_by_status: ($s | group_by(.status) | map({key:.[0].status, value:length}) | from_entries),
        subscriptions_more_pages: (($subs[0]._links.next // null) != null),
        last_payments: ($p[0:3] | map({status, method, at:(.createdAt[0:16])}
                                      + (if $amounts == 1 then {amount:(.amount.value + " " + .amount.currency)} else {} end))),
        last30_by_status: ($p30 | group_by(.status) | map({key:.[0].status, value:length}) | from_entries),
        last30_total: ($p30|length),
        last30_failed_after_method: ($real_fail|length),
        last30_never_started: ($never_started|length),
        mrr_eur: (if $amounts == 1 then ($act|map(.amount.value|tonumber)|add // 0) else null end),
        reason: (if ($act|length) == 0 then "keine aktive Subscription"
                 elif ($real_fail|length) > 0
                   then (($real_fail|length)|tostring) + " Zahlung(en) NACH der Methodenwahl fehlgeschlagen — echter Zahlungsfehler"
                 else null end)
      }' > "$TMP/pay.json" 2>/dev/null \
    || block_error pay "Aggregation der Mollie-Antwort fehlgeschlagen"
}

# ------------------------------------------------------------------ Ausführung
want backlog && block_backlog
want n8n     && block_n8n
want server  && block_server
want pay     && block_pay

ASSEMBLED="$TMP/lagebild.json"
# Nicht angeforderte Blöcke werden explizit null — Prozess-Substitution ist unter
# MSYS/Windows für --slurpfile nicht zuverlässig (/proc/<pid>/fd verschwindet).
for b in backlog n8n server pay; do
  if [ ! -s "$TMP/$b.json" ] || ! jq -e . "$TMP/$b.json" >/dev/null 2>&1; then
    if want "$b"; then
      jq -n '{state:"error", reason:"Block lieferte kein verwertbares Ergebnis (interner Fehler)"}' > "$TMP/$b.json"
    else
      echo 'null' > "$TMP/$b.json"
    fi
  fi
done

jq -n \
  --arg stamp "$STAMP" --arg cutoff "$CUTOFF" --arg blocks "$BLOCKS" \
  --slurpfile backlog "$TMP/backlog.json" \
  --slurpfile n8n     "$TMP/n8n.json" \
  --slurpfile server  "$TMP/server.json" \
  --slurpfile pay     "$TMP/pay.json" '
  {generated_at:$stamp, window_cutoff_utc:$cutoff, blocks_requested:($blocks|split(",")),
   backlog:$backlog[0], n8n:$n8n[0], server:$server[0], pay:$pay[0]}' > "$ASSEMBLED" \
  || { echo "lagebild: Zusammenbau fehlgeschlagen — keine Zahlen ausgeben." >&2; exit 3; }

if [ "$FORMAT" = "json" ]; then
  cat "$ASSEMBLED"
else
  jq -r '
    def icon: if . == "ok" then "OK" elif . == "warn" then "WARN" else "FEHLER" end;
    [
    "## Lagebild — " + .generated_at + " (Europe/Berlin)",

    (if .backlog == null then null
     elif .backlog.state == "error" then "**Backlog** FEHLER — " + .backlog.reason + " · keine Zahlen (NICHT als 0 zu lesen)."
     else "**Backlog** " + (.backlog.state|icon) + " — " + (.backlog.repos_read|tostring) + "/" + (.backlog.repos_expected|tostring)
          + " Repos · " + (.backlog.ready_total|tostring) + " ready ("
          + "P1-money " + (.backlog.by_prio."P1-money"|tostring)
          + " · P1 " + (.backlog.by_prio.P1|tostring)
          + " · P2 " + (.backlog.by_prio.P2|tostring)
          + " · P3 " + (.backlog.by_prio.P3|tostring)
          + (if .backlog.by_prio.ohne > 0 then " · ohne Prio " + (.backlog.by_prio.ohne|tostring) else "" end)
          + ") · " + (.backlog.in_progress|tostring) + " in-progress · " + (.backlog.blocked|tostring) + " blocked-munir"
          + (if .backlog.reason then "\n  ! " + .backlog.reason else "" end)
          + (if (.backlog.top_money|length) > 0 then
               "\n" + (.backlog.top_money | to_entries | map("  " + ((.key+1)|tostring) + ". " + .value.repo + "#" + (.value.number|tostring) + " — " + (.value.title[0:70])) | join("\n"))
             else "\n  (kein P1-money ready)" end)
     end),

    (if .n8n == null then null
     elif .n8n.state == "error" then "**n8n** FEHLER — " + .n8n.reason + " · keine Zahlen (NICHT als 0 zu lesen)."
     else "**n8n** " + (.n8n.state|icon) + " — " + (.n8n.errors_total|tostring) + " Fehler-Executions in "
          + (.n8n.window_hours|tostring) + " h · " + (.n8n.executions_in_window|tostring)
          + (if .n8n.executions_window_is_floor then "+" else "" end) + " Executions gesamt"
          + (if .n8n.reason then "\n  ! " + .n8n.reason else "" end)
          + (if (.n8n.by_workflow|length) > 0 then
               "\n" + (.n8n.by_workflow | map("  - " + .workflow + " — " + (.count|tostring) + "x, zuletzt " + (.last_at[11:16]) + " UTC (exec " + .last_execution + ")") | join("\n"))
             else "" end)
     end),

    (if .server == null then null
     elif .server.state == "error" then "**Server** FEHLER — " + .server.reason + " · keine Zahlen (NICHT als 0 zu lesen)."
     else "**Server** " + (.server.state|icon) + " — " + .server.host + " · up " + (.server.uptime_days|tostring) + " d · load "
          + (.server.load1|tostring) + " · / " + (.server.disk_used_pct|tostring) + " % (" + .server.disk_avail + " frei) · "
          + (.server.containers_running|tostring) + " Container laufen, " + (.server.containers_exited|tostring) + " exited, "
          + (.server.containers_unhealthy|tostring) + " unhealthy"
          + "\n  Kuma: " + (if .server.kuma_readable then (.server.kuma_active|tostring) + " aktiv · " + (.server.kuma_down|length|tostring) + " rot"
                            + (if (.server.kuma_down|length) > 0 then " (" + (.server.kuma_down|join(", ")) + ")" else "" end)
                            + (if (.server.kuma_pending|length) > 0 then " · " + (.server.kuma_pending|length|tostring) + " pending (" + (.server.kuma_pending|join(", ")) + ")" else "" end)
                            + (if ((.server.kuma_silent // [])|length) > 0
                               then " · " + ((.server.kuma_silent|length)|tostring) + " STUMM (" + (.server.kuma_silent|join(", ")) + ")"
                               else "" end)
                          else "NICHT LESBAR — Status unbekannt" end)
          + (if .server.reason then "\n  ! " + .server.reason else "" end)
     end),

    (if .pay == null then null
     elif .pay.state == "error" then "**Zahlungen** FEHLER — " + .pay.reason + " · keine Zahlen (NICHT als 0 zu lesen)."
     else "**Zahlungen** " + (.pay.state|icon) + " — Mollie · " + (.pay.subscriptions_active|tostring) + " aktive Subscription(s)"
          + (if (.pay.subscriptions_by_status|to_entries|map(select(.key != "active"))|length) > 0
             then " (" + (.pay.subscriptions_by_status|to_entries|map(select(.key != "active"))|map(.key + " " + (.value|tostring))|join(", ")) + ")" else "" end)
          + (if .pay.mrr_eur then " · MRR " + (.pay.mrr_eur|tostring) + " EUR" else "" end)
          + "\n  Letzte 3 Zahlungen: " + (.pay.last_payments | map(.status + " (" + (.method // "?") + ", " + .at + ")") | join(" · "))
          + "\n  30 Tage: " + (.pay.last30_total|tostring) + " Zahlungen — " + (.pay.last30_by_status|to_entries|map(.key + " " + (.value|tostring))|join(", "))
          + "\n  davon " + (.pay.last30_failed_after_method|tostring) + " Fehlschlag NACH Methodenwahl (echter Zahlungsfehler) · "
          + (.pay.last30_never_started|tostring) + " nie begonnen (Link nicht geöffnet — kein Zahlungsfehler)"
          + (if .pay.reason then "\n  ! " + .pay.reason else "" end)
     end)
    ] | map(select(. != null)) | join("

")
  ' "$ASSEMBLED"
fi

# Exit-Code beantwortet NUR: "konnte ich das Lagebild vollständig erheben?"
# Er sagt NICHTS darüber, ob die Lage gut ist — das steht im Bericht.
if jq -e '[.backlog,.n8n,.server,.pay]|map(select(. != null and .state=="error"))|length > 0' "$ASSEMBLED" >/dev/null 2>&1; then
  exit 2   # mindestens eine Quelle komplett tot
fi
if jq -e '
    ((.backlog != null) and (((.backlog.repos_unreadable|length) > 0) or ((.backlog.repos_truncated|length) > 0)))
    or ((.server != null) and ((.server.kuma_readable|not) or (.server.containers_running == null)))
  ' "$ASSEMBLED" >/dev/null 2>&1; then
  exit 1   # Bericht unvollständig: eine Teil-Quelle war nicht lesbar (namentlich im Bericht)
fi
exit 0
