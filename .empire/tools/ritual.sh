#!/usr/bin/env bash
# ritual.sh — die beiden Führungsrituale auf echten Daten (buzz#10)
#
#   morgenbrief  08:45 Europe/Berlin — 5 Blöcke: Top-3 · Inbox · Lage · Entscheidungen · Lücken
#   gate-batch   20:45 Europe/Berlin — alle offenen blocked-munir als Ein-Zeilen-Entscheidungen
#
# Aufruf:
#   bash .empire/tools/ritual.sh morgenbrief                      # nur rendern (stdout)
#   bash .empire/tools/ritual.sh morgenbrief --post --telegram --vault
#   bash .empire/tools/ritual.sh gate-batch  --post --telegram --vault
#   bash .empire/tools/ritual.sh gate-batch  --redact              # ohne Kundendaten (Issue-Beweise)
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
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unbekannte Option: $1" >&2; exit 64 ;;
  esac
done

case "$MODE" in
  morgenbrief|gate-batch) ;;
  *) echo "usage: ritual.sh <morgenbrief|gate-batch> [--post --telegram --vault --redact --dry-run]" >&2; exit 64 ;;
esac

for t in jq curl gh; do command -v "$t" >/dev/null || { echo "$t fehlt" >&2; exit 2; }; done

CR=$'\r'
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
DATE_DE="$(date '+%a %d.%m.%Y')"
CLOCK="$(date '+%H:%M')"
GAPFILE="$TMP/gaps"; : > "$GAPFILE"
gap() { printf '%s\n' "$1" >> "$GAPFILE"; }
gapcount() { wc -l < "$GAPFILE" | tr -d ' '; }

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

    printf '\n**2) Inbox** (m.muniradas@gmail.com, letzte 24 h)\n'
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
      printf '   ⚠️ LÜCKE — Inbox nicht erhoben (siehe Block 5)\n'
    fi

    printf '\n**3) Lage** (Quelle: `.empire/tools/lagebild.sh`)\n'
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
                then " · Kuma rot: " + ((.server.kuma_down)|join(", ")) else "" end) else empty end),
          (if (.pay.state? // "") != "" then "   Zahlungen:" + st(.pay.state) + " "
             + ((.pay.subscriptions_active // "?")|tostring) + " aktive Abos · 30 T: "
             + ((.pay.last30_by_status.paid // 0)|tostring) + " bezahlt / "
             + ((.pay.last30_total // "?")|tostring) + " Versuche ("
             + ((.pay.last30_failed_after_method // 0)|tostring) + " nach Methodenwahl gescheitert)" else empty end)
        ] | .[]' "$TMP/lage.json" | tr -d "$CR"
    else
      printf '   ⚠️ LÜCKE — Lagebild nicht erhoben (siehe Block 5)\n'
    fi

    printf '\n**4) Deine Entscheidungen** (offene `blocked-munir`)\n'
    if [ -f "$TMP/blocked.json" ]; then
      local nb; nb="$(jq -r 'length' "$TMP/blocked.json")"
      if [ "$nb" -eq 0 ]; then
        if grep -q 'nicht lesbar\|am Limit\|lieferte nichts' "$GAPFILE" 2>/dev/null; then
          printf '   ⚠️ 0 in den lesbaren Repos — nicht alle waren lesbar (siehe Block 5)\n'
        else
          printf '   keine offenen Blocker\n'
        fi
      else
        printf '   %s offen — Top 3:\n' "$nb"
        render_gate_lines 3 | sed 's/^/   /'
        printf '   voller Batch heute 20:45\n'
      fi
    else
      printf '   ⚠️ LÜCKE — blocked-munir nicht erhoben (siehe Block 5)\n'
    fi

    printf '\n**5) Lücken** (bewusst benannt, nie als 0 verbucht)\n'
    printf '   • Kalender: n/a — headless nicht angebunden (claude.ai-Connector); Folge-Ticket\n'
    if [ -s "$GAPFILE" ]; then
      sed 's/^/   • /' "$GAPFILE"
    else
      printf '   • sonst keine — alle Quellen haben geliefert\n'
    fi
  } > "$out"
  printf '%s' "$out"
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
    printf '\n**Lücken**\n'
    if [ -s "$GAPFILE" ]; then sed 's/^/   • /' "$GAPFILE"; else printf '   • keine — alle Repos gelesen\n'; fi
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
    collect_inbox
    collect_blocked
    BRIEF="$(render_morgenbrief)"
    CH="${BUZZ_CHANNEL:-$CH_GENERAL}"; LABEL="🌅 Morgenbrief"
    ;;
  gate-batch)
    collect_blocked
    BRIEF="$(render_gate_batch)"
    CH="${BUZZ_CHANNEL:-$CH_GATES}"; LABEL="🔐 Gate-Batch"
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

[ "$TRANSPORT_FAIL" = "1" ] && exit 3
[ -s "$GAPFILE" ] && exit 1
exit 0
