#!/usr/bin/env bash
# .empire/tools/decision-drafts.sh — ⚖️-Marker werden Entscheidungs-Entwürfe (buzz#42)
#
# Agenten markieren tragweite Entscheidungen im Journal (buzz#11):
#   - 🐝 <Agent>: ⚖️ Decision-Kandidat: <Entscheidung>
# Dieses Script hebt sie nach `08 Decisions/` — als ENTWURF. Das „Warum" schreibt
# der Agent NICHT: es ist Munirs Urteil, der knappste Input im System (Vault-Regel
# „Capture the Why"). Die Note bleibt `draft`, bis er geantwortet hat.
#
# Modi:
#   collect [--days N]   Marker einsammeln, fehlende Entwürfe anlegen (idempotent)
#   ask                  EINE gebündelte Telegram-Nachricht mit allen offenen Warum-Fragen
#   ingest [--wait S]    Munirs Antworten einpflegen, Status -> active
#   list                 Stand aller Entwürfe
#
# Guardrails, die hier hart gelten:
#   - Kein `git` im Vault (obsidian-git synct; er committet auch Konfliktmarker blind).
#   - Journal wird NIE verändert — der Verarbeitungsstand steht in den Notes selbst.
#   - Keine erfundenen Begründungen: ohne Munirs Text bleibt `Warum` leer und `draft`.
#   - Telegram-Bodies immer über stdin an curl (MSYS zerlegt UTF-8 in argv).

set -uo pipefail

VAULT="${VAULT_DIR:-$HOME/Documents/Ai_Brain}"
JOURNAL="$VAULT/01 Journal"
DECISIONS="$VAULT/08 Decisions"
SECRETS_FILE="${SECRETS_FILE:-$HOME/.secrets/master.env}"
TG_STATE_FILE="${TG_STATE_FILE:-$HOME/.telegram-mcp-state.json}"
MARKER="⚖️ Decision-Kandidat:"

die() { echo "decisions: $*" >&2; exit 1; }

read_secret() {
  local name="$1" val
  val="${!name:-}"
  if [ -z "$val" ] && [ -f "$SECRETS_FILE" ]; then
    val=$(grep -m1 "^${name}=" "$SECRETS_FILE" | cut -d= -f2- | tr -d '\r')
  fi
  [ -n "$val" ] || die "$name nicht in env oder $SECRETS_FILE"
  printf '%s' "$val"
}

tg_post() { curl -s -X POST "$1" -H 'Content-Type: application/json' --data-binary @-; }

# Stabile ID aus der Marker-Zeile: derselbe Marker ergibt immer dieselbe ID,
# damit ein zweiter Lauf keine Dublette erzeugt.
marker_id() { printf '%s' "$1" | sha256sum | cut -c1-8 | tr 'a-f' 'A-F' | sed 's/^/D-/'; }

slugify() {
  printf '%s' "$1" \
    | sed -e 's/ä/ae/g; s/ö/oe/g; s/ü/ue/g; s/Ä/ae/g; s/Ö/oe/g; s/Ü/ue/g; s/ß/ss/g' \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-\+//' -e 's/-\+$//' \
    | cut -c1-60
}

# Die Notes selbst sind die Wahrheit über „schon verarbeitet" — kein Statusfile,
# das von den Daten wegdriften kann.
note_for_id() {
  [ -d "$DECISIONS" ] || return 0
  grep -rl "^decision_id: $1\$" "$DECISIONS" 2>/dev/null | head -1
}

journal_files() {
  local days="$1" f
  for i in $(seq 0 "$days"); do
    f="$JOURNAL/$(date -d "-$i day" +%Y-%m)/$(date -d "-$i day" +%Y-%m-%d).md"
    [ -f "$f" ] && printf '%s\n' "$f"
  done
}

# ---------------------------------------------------------------- collect
do_collect() {
  local days=7
  while [ $# -gt 0 ]; do
    case "$1" in
      --days) days="$2"; shift 2;;
      *) die "unbekannte Option: $1";;
    esac
  done
  [ -d "$JOURNAL" ] || die "Journal nicht gefunden: $JOURNAL"
  mkdir -p "$DECISIONS"

  local created=0 skipped=0 seen=0
  while IFS= read -r file; do
    while IFS= read -r line; do
      case "$line" in *"$MARKER"*) ;; *) continue;; esac
      # Der Marker zählt nur im dokumentierten Format `- 🐝 <Agent>: ⚖️ …`.
      # Ohne das fängt der Sammler jede Zeile, die den Marker bloss ERWÄHNT —
      # gemessen: die buzz#11-Zusammenfassung zitiert ihn in Backticks und
      # hätte eine Geister-Entscheidung erzeugt.
      local prefix="${line%%"$MARKER"*}"
      case "$prefix" in
        *'`'*) continue;;
        *": ") [ "${#prefix}" -le 40 ] || continue;;
        *) continue;;
      esac
      seen=$((seen+1))
      local id agent text title slug target
      id=$(marker_id "$line")
      if [ -n "$(note_for_id "$id")" ]; then skipped=$((skipped+1)); continue; fi

      agent=$(printf '%s' "$line" | sed -n 's/^[[:space:]]*-[[:space:]]*🐝[[:space:]]*\([^:]*\):.*/\1/p')
      [ -n "$agent" ] || agent="unbekannt"
      text=${line#*"$MARKER"}
      text=$(printf '%s' "$text" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      [ -n "$text" ] || continue

      # Titel = erster Sinnabschnitt bis zum ersten Gedankenstrich/Punkt.
      title=$(printf '%s' "$text" | sed -e 's/ — .*//' -e 's/\. .*//' | cut -c1-80)
      slug=$(slugify "$title")
      [ -n "$slug" ] || slug=$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')
      target="$DECISIONS/$slug.md"
      [ -e "$target" ] && target="$DECISIONS/$slug-$(printf '%s' "$id" | cut -c3-).md"

      local journal_note; journal_note=$(basename "$file" .md)
      {
        printf -- '---\n'
        printf 'type: decision\n'
        printf 'status: draft\n'
        printf 'created: %s\n' "$(date +%Y-%m-%d)"
        printf 'decision_id: %s\n' "$id"
        printf 'source_journal: "%s"\n' "$journal_note"
        printf 'agent: %s\n' "$agent"
        printf 'tags:\n  - decision\n  - agent-draft\n'
        printf -- '---\n\n'
        printf '# %s\n\n' "$title"
        printf '## Kontext\n\n'
        printf -- '- Aufgelesen aus der Tagesnotiz [[%s]] (Marker gesetzt von `%s`).\n' "$journal_note" "$agent"
        printf -- '- Dieser Entwurf wurde maschinell erzeugt (`.empire/tools/decision-drafts.sh`, buzz#42) und ist **kein** Kanon, solange `status: draft` steht.\n\n'
        printf '## Entscheidung\n\n'
        printf -- '- %s\n\n' "$text"
        printf '## Munirs Warum\n\n'
        printf -- '> **offen** — ohne Munirs Begründung bleibt diese Note `draft`.\n'
        printf -- '> Antwort-Format im Telegram-Chat: `%s <dein Warum>`\n\n' "$id"
        printf '## Konsequenzen\n\n'
        printf -- '- (ergibt sich aus dem Warum — bewusst leer gelassen statt geraten)\n'
      } > "$target"
      created=$((created+1))
      echo "angelegt: $id -> $(basename "$target")"
    done < "$file"
  done < <(journal_files "$days")

  echo "collect: $seen Marker gesehen, $created Entwürfe angelegt, $skipped bereits vorhanden"
}

# -------------------------------------------------------------------- ask
open_drafts() {
  [ -d "$DECISIONS" ] || return 0
  grep -rl '^status: draft$' "$DECISIONS" 2>/dev/null | while IFS= read -r f; do
    grep -q '^decision_id: D-' "$f" || continue
    printf '%s\t%s\t%s\n' \
      "$(sed -n 's/^decision_id: //p' "$f" | head -1)" \
      "$(sed -n 's/^# //p' "$f" | head -1)" \
      "$f"
  done
}

do_ask() {
  local rows; rows=$(open_drafts)
  [ -n "$rows" ] || { echo "ask: keine offenen Entwürfe — nichts zu fragen"; return 0; }

  local n; n=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
  local msg; msg=$(printf '⚖️ %s offene Entscheidung(en) brauchen dein WARUM\n\nAgenten haben sie markiert und als Entwurf abgelegt. Ohne deine Begründung bleiben sie `draft` und zählen nicht als Kanon.\n\n' "$n")
  while IFS=$'\t' read -r id title _; do
    msg+=$(printf '%s\n  %s\n\n' "$id" "$title")
  done <<< "$rows"
  msg+=$(printf 'Antworte je Entscheidung mit:  <ID> <dein Warum>\nBeispiel:  D-1A2B3C4D weil der Scope-Schutz nie gemessen war\n\nEine Nachricht pro Antwort reicht; mehrere IDs in einer Nachricht gehen auch.')

  local token chat api
  token=$(read_secret TELEGRAM_BOT_TOKEN); chat=$(read_secret TELEGRAM_CHAT_ID)
  api="${TELEGRAM_API_BASE:-https://api.telegram.org/bot$token}"

  local resp; resp=$(jq -n --arg c "$chat" --arg t "$msg" \
      '{chat_id:$c, text:$t, disable_web_page_preview:true}' | tg_post "$api/sendMessage")
  [ "$(jq -r '.ok' <<<"$resp")" = "true" ] \
    || die "Telegram sendMessage fehlgeschlagen: $(jq -r '.description // "?"' <<<"$resp")"
  echo "ask: 1 Nachricht mit $n Frage(n) zugestellt (message_id=$(jq -r '.result.message_id' <<<"$resp"))"
}

# ----------------------------------------------------------------- ingest
# PEEK wie in gate.sh: der Offset aus ~/.telegram-mcp-state.json wird gelesen,
# aber NIE fortgeschrieben — telegram-mcp bleibt Besitzer des Lesezeigers.
do_ingest() {
  local wait=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --wait) wait="$2"; shift 2;;
      *) die "unbekannte Option: $1";;
    esac
  done
  local rows; rows=$(open_drafts)
  [ -n "$rows" ] || { echo "ingest: keine offenen Entwürfe"; return 0; }

  local token chat api offset deadline
  token=$(read_secret TELEGRAM_BOT_TOKEN); chat=$(read_secret TELEGRAM_CHAT_ID)
  api="${TELEGRAM_API_BASE:-https://api.telegram.org/bot$token}"
  offset=$(jq -r '.offset // 0' "$TG_STATE_FILE" 2>/dev/null || echo 0)
  deadline=$(( $(date +%s) + wait ))

  local filled=0
  while :; do
    local ups; ups=$(jq -n --argjson o "$offset" \
        '{offset:$o, timeout:0, allowed_updates:["message"]}' | tg_post "$api/getUpdates")
    if [ "$(jq -r '.ok' <<<"$ups")" = "true" ]; then
      while IFS=$'\t' read -r id title file; do
        [ -f "$file" ] || continue
        grep -q '^status: draft$' "$file" || continue
        local why
        # Nur aus Munirs eigenem Privatchat, und der Text NACH der ID zählt.
        why=$(jq -r --arg gate "$id" --arg chat "$chat" '
          [ .result[]
            | select(.message != null) | .message as $m
            | select(($m.chat.id|tostring) == $chat)
            | select((($m.from.id // -1)|tostring) == $chat)
            | ($m.text // $m.caption // "") as $t
            | select($t | ascii_upcase | contains($gate))
            | ($t | sub("(?i).*" + $gate + "[:,]?\\s*"; "")) ]
          | map(select(length > 2)) | last // empty' <<<"$ups")
        [ -n "$why" ] || continue

        local tmp="$file.tmp.$$"
        awk -v why="$why" '
          /^status: draft$/ && !s { print "status: active"; s=1; next }
          /^> \*\*offen\*\*/ { print "- " why; skip=1; next }
          skip && /^> Antwort-Format/ { skip=0; next }
          { print }
        ' "$file" > "$tmp" && mv "$tmp" "$file"
        filled=$((filled+1))
        echo "eingepflegt: $id ($title)"
      done <<< "$rows"
    fi
    [ "$filled" -gt 0 ] && break
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 5
  done
  echo "ingest: $filled Begründung(en) eingepflegt"
}

do_list() {
  [ -d "$DECISIONS" ] || { echo "list: kein $DECISIONS"; return 0; }
  grep -rl '^decision_id: D-' "$DECISIONS" 2>/dev/null | while IFS= read -r f; do
    printf '%s  %-8s  %s\n' \
      "$(sed -n 's/^decision_id: //p' "$f" | head -1)" \
      "$(sed -n 's/^status: //p' "$f" | head -1)" \
      "$(basename "$f")"
  done
}

case "${1:-}" in
  collect) shift; do_collect "$@";;
  ask)     shift; do_ask "$@";;
  ingest)  shift; do_ingest "$@";;
  list)    shift; do_list "$@";;
  *) sed -n '2,25p' "$0"; exit 1;;
esac
