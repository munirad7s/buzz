#!/usr/bin/env bash
# .empire/gate.sh — Approval-Gate für Empire-Agenten (buzz#9)
#
# Kein Outbound ohne Freigabe. Doktrin: .empire/POLICY.md
#
# Ein Agent, der eine GATED-Aktion ausführen will, fragt hier an. Die Anfrage
# geht als strukturierte Nachricht in Munirs privaten Telegram-Chat; nur eine
# Antwort AUS DIESEM CHAT, die die Gate-ID nennt, zählt als Verdikt. Ohne
# Freigabe passiert nichts — Timeout und Ablehnung sind beide "verworfen"
# (fail-closed).
#
# Modi:
#   gate.sh request --action A --reason R --payload P [--timeout 24h]
#       -> exit 0 = freigegeben, 10 = abgelehnt, 11 = Timeout
#   gate.sh run --action A --reason R --payload P [--timeout 24h] -- cmd args...
#       -> führt cmd NUR bei Freigabe aus (der strukturell sichere Weg)
#   gate.sh selftest        -> Klassifikator gegen Fixtures (Detektor-Rot-Beweis)
#   gate.sh audit [--verify]-> Audit-Kette zeigen / Hash-Kette prüfen
#
# Secrets kommen aus env oder ~/.secrets/master.env — nie aus diesem Repo.
# Das Repo ist öffentlich: hier stehen keine Tokens, Chat-IDs oder Payloads.

set -uo pipefail

SECRETS_FILE="${SECRETS_FILE:-$HOME/.secrets/master.env}"
TG_STATE_FILE="${TG_STATE_FILE:-$HOME/.telegram-mcp-state.json}"
AUDIT_FILE="${GATE_AUDIT_FILE:-$HOME/.buzz/gate-audit.jsonl}"
VAULT_DIR="${VAULT_DIR:-$HOME/Documents/Ai_Brain}"
POLL_SECS="${GATE_POLL_SECS:-5}"

die() { echo "gate: $*" >&2; exit 1; }

# JSON-Body IMMER über stdin an curl geben, nie als Argument.
# Gemessen 2026-08-01 (Git Bash/MSYS auf Windows): ein langer, mehrzeiliger
# UTF-8-Body als argv (-d "...") kommt bei Telegram als
# "Bad Request: strings must be encoded in UTF-8" an — dieselben Bytes über
# stdin gehen durch. Die MSYS-Argumentkonvertierung zerlegt die Multibyte-
# Sequenzen; kurze Strings überleben es zufällig, lange nicht.
tg_post() {
  curl -s -X POST "$1" -H 'Content-Type: application/json' --data-binary @-
}

read_secret() {
  local name="$1" val
  val="${!name:-}"
  if [ -z "$val" ] && [ -f "$SECRETS_FILE" ]; then
    val=$(grep -m1 "^${name}=" "$SECRETS_FILE" | cut -d= -f2- | tr -d '\r')
  fi
  [ -n "$val" ] || die "$name not found in env or $SECRETS_FILE"
  printf '%s' "$val"
}

# ---------------------------------------------------------------- classifier
# EINE Quelle der Wahrheit für "zählt diese Nachricht als Verdikt?".
# Live-Polling und selftest benutzen exakt diesen jq-Filter — ein Gate, dessen
# Prüfung im Test anders aussieht als im Betrieb, beweist nichts.
#
# Bedingungen (ALLE müssen halten, sonst kein Verdikt):
#   1. echte Nachricht
#   2. chat.id == Munirs Chat  (kein Fremdchat)
#   3. from.id == chat.id      (Privatchat: Absender ist der Owner selbst)
#   4. date >= Zeitpunkt der Anfrage  (kein Replay einer alten Zustimmung)
#   5. Text nennt die Gate-ID   (kein versehentliches "ok" auf etwas anderes)
#   6. Text enthält ein Verdikt-Wort; "nein" schlägt "ja" (fail-closed)
GATE_JQ='
def norm: ascii_downcase;
def has_deny: test("(^|[^a-z0-9])(no|nein|deny|stop|abbruch|nope|reject)([^a-z0-9]|$)")
              or contains("-1") or contains("❌") or contains("👎");
def has_approve: test("(^|[^a-z0-9])(ok|okay|ja|yes|approve|approved|go|freigabe|frei)([^a-z0-9]|$)")
              or contains("+1") or contains("✅") or contains("👍");
[ .[]
  | select(.message != null)
  | .message as $m
  | select(($m.chat.id | tostring) == $chat)
  | select(($m.from.id // -1 | tostring) == $chat)
  | select($m.date >= ($since | tonumber))
  | (($m.text // $m.caption // "") | norm) as $t
  | select($t | contains($gate | ascii_downcase))
  | { message_id: $m.message_id,
      date: $m.date,
      verdict: (if ($t | has_deny) then "deny"
                elif ($t | has_approve) then "approve"
                else "none" end) }
  | select(.verdict != "none")
] | first // empty
'

# ------------------------------------------------------------------- audit
# Append-only JSONL mit Hash-Kette: jede Zeile bindet die vorherige, ein
# nachträglich geänderter Eintrag bricht die Kette sichtbar.
# Liegt bewusst AUSSERHALB des (öffentlichen) Repos.
audit_append() {
  local event="$1" gate_id="$2" json_extra="$3"
  mkdir -p "$(dirname "$AUDIT_FILE")"
  local prev seq
  if [ -s "$AUDIT_FILE" ]; then
    prev=$(tail -n 1 "$AUDIT_FILE" | jq -r '.hash')
    seq=$(( $(tail -n 1 "$AUDIT_FILE" | jq -r '.seq') + 1 ))
  else
    prev="GENESIS"; seq=1
  fi
  local body
  body=$(jq -cS -n \
    --argjson seq "$seq" \
    --arg ts "$(date --iso-8601=seconds)" \
    --arg gate_id "$gate_id" \
    --arg event "$event" \
    --arg prev "$prev" \
    --argjson extra "$json_extra" \
    '{seq:$seq, ts:$ts, gate_id:$gate_id, event:$event, prev:$prev} + $extra')
  local hash
  hash=$(printf '%s%s' "$prev" "$body" | sha256sum | cut -d' ' -f1)
  jq -cS --arg hash "$hash" '. + {hash:$hash}' <<<"$body" >> "$AUDIT_FILE"
  echo "$hash"
}

audit_verify() {
  [ -s "$AUDIT_FILE" ] || { echo "audit: leer ($AUDIT_FILE)"; return 0; }
  local prev="GENESIS" n=0 bad=0
  while IFS= read -r line; do
    n=$((n+1))
    local stored body calc
    stored=$(jq -r '.hash' <<<"$line")
    body=$(jq -cS 'del(.hash)' <<<"$line")
    calc=$(printf '%s%s' "$prev" "$body" | sha256sum | cut -d' ' -f1)
    if [ "$stored" != "$calc" ]; then
      echo "audit: KETTE GEBROCHEN bei Zeile $n (seq $(jq -r .seq <<<"$line"))"; bad=1
    fi
    prev="$stored"
  done < "$AUDIT_FILE"
  [ "$bad" -eq 0 ] && echo "audit: Hash-Kette intakt über $n Einträge ($AUDIT_FILE)"
  return "$bad"
}

# Tagesnotiz-Zeile. Standardweg ist der Vault-Appender aus buzz#11 (append-only,
# UTF-8-sicher, kein git im Vault) — nicht selbst in die Notiz schreiben.
vault_line() {
  local logger="$HOME/.buzz/vault-log.sh"
  [ -x "$logger" ] || [ -f "$logger" ] || return 0
  bash "$logger" gate "🔐 $1" >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------ request
do_request() {
  local action="" reason="" payload="" timeout="24h" cls="GATED"
  while [ $# -gt 0 ]; do
    case "$1" in
      --action)  action="$2"; shift 2;;
      --reason)  reason="$2"; shift 2;;
      --payload) payload="$2"; shift 2;;
      --timeout) timeout="$2"; shift 2;;
      --class)   cls="$2"; shift 2;;
      *) die "unbekannte Option: $1";;
    esac
  done
  [ -n "$action" ] || die "--action fehlt"
  [ -n "$reason" ] || die "--reason fehlt"
  [ -n "$payload" ] || die "--payload fehlt"

  local secs; secs=$(parse_duration "$timeout")
  local token chat api
  token=$(read_secret TELEGRAM_BOT_TOKEN)
  chat=$(read_secret TELEGRAM_CHAT_ID)
  # TELEGRAM_API_BASE nur für Integrationstests (lokaler Mock). Im Betrieb leer
  # lassen — dann ist der einzige Freigabeweg Munirs echter Telegram-Chat.
  api="${TELEGRAM_API_BASE:-https://api.telegram.org/bot$token}"

  local gate_id since payload_sha
  gate_id="G-$(head -c 16 /dev/urandom | sha256sum | cut -c1-6 | tr 'a-f' 'A-F')"
  since=$(date +%s)
  payload_sha=$(printf '%s' "$payload" | sha256sum | cut -d' ' -f1)

  local msg
  msg=$(printf '🔐 FREIGABE ERFORDERLICH  %s\n\nKlasse:  %s\nAktion:  %s\nGrund:   %s\n\nPayload:\n%s\n\nAntworte "%s ok" zum Freigeben, "%s nein" zum Ablehnen.\nOhne Antwort: verworfen nach %s. Keine Antwort = keine Ausführung.' \
    "$gate_id" "$cls" "$action" "$reason" "$payload" "$gate_id" "$gate_id" "$timeout")

  local send_resp req_msg_id
  send_resp=$(jq -n --arg c "$chat" --arg t "$msg" \
      '{chat_id:$c, text:$t, disable_web_page_preview:true}' | tg_post "$api/sendMessage")
  [ "$(jq -r '.ok' <<<"$send_resp")" = "true" ] || die "Telegram sendMessage fehlgeschlagen: $(jq -r '.description // "?"' <<<"$send_resp")"
  req_msg_id=$(jq -r '.result.message_id' <<<"$send_resp")

  audit_append "requested" "$gate_id" "$(jq -cn \
    --arg a "$action" --arg r "$reason" --arg c "$cls" \
    --arg p "$payload_sha" --argjson m "$req_msg_id" --arg t "$timeout" \
    '{action:$a, reason:$r, class:$c, payload_sha256:$p, tg_message_id:$m, timeout:$t}')" >/dev/null

  echo "gate: $gate_id angefragt (TG message_id=$req_msg_id, Timeout $timeout)" >&2

  # --- warten ---------------------------------------------------------------
  local deadline=$(( since + secs )) offset hit verdict
  offset=$(jq -r '.offset // 0' "$TG_STATE_FILE" 2>/dev/null || echo 0)
  while [ "$(date +%s)" -lt "$deadline" ]; do
    # PEEK: offset wird NIE fortgeschrieben — telegram-mcp bleibt der Besitzer
    # des Lesezeigers, dieses Gate stiehlt keine Nachrichten aus dem Postfach.
    local ups
    ups=$(jq -n --argjson o "$offset" \
        '{offset:$o, timeout:0, allowed_updates:["message"]}' | tg_post "$api/getUpdates")
    if [ "$(jq -r '.ok' <<<"$ups")" = "true" ]; then
      hit=$(jq -c --arg gate "$gate_id" --arg chat "$chat" --arg since "$since" \
              "$GATE_JQ" <<<"$(jq '.result' <<<"$ups")")
      if [ -n "$hit" ] && [ "$hit" != "null" ]; then
        verdict=$(jq -r '.verdict' <<<"$hit")
        local vmsg; vmsg=$(jq -r '.message_id' <<<"$hit")
        audit_append "$verdict" "$gate_id" "$(jq -cn --argjson m "$vmsg" '{verdict_message_id:$m, by:"owner-chat"}')" >/dev/null
        if [ "$verdict" = "approve" ]; then
          echo "gate: $gate_id FREIGEGEBEN (TG msg $vmsg)" >&2
          echo "$gate_id"; return 0
        fi
        echo "gate: $gate_id ABGELEHNT (TG msg $vmsg) — Aktion unterbleibt" >&2
        echo "$gate_id"; return 10
      fi
    fi
    sleep "$POLL_SECS"
  done

  audit_append "timeout" "$gate_id" "$(jq -cn --arg t "$timeout" '{waited:$t, executed:false}')" >/dev/null
  jq -n --arg c "$chat" \
     --arg t "⏱️ $gate_id verworfen (keine Freigabe innerhalb $timeout). Aktion wurde NICHT ausgeführt." \
     '{chat_id:$c, text:$t}' | tg_post "$api/sendMessage" >/dev/null
  echo "gate: $gate_id TIMEOUT nach $timeout — Aktion unterbleibt" >&2
  echo "$gate_id"; return 11
}

parse_duration() {
  local d="$1" n u
  n=$(printf '%s' "$d" | sed 's/[^0-9]//g')
  u=$(printf '%s' "$d" | sed 's/[0-9]//g')
  [ -n "$n" ] || die "ungültige Dauer: $d"
  case "${u:-s}" in
    s) echo "$n";; m) echo $((n*60));; h) echo $((n*3600));; d) echo $((n*86400));;
    *) die "ungültige Zeiteinheit: $u";;
  esac
}

# ---------------------------------------------------------------------- run
do_run() {
  local args=() cmd=()
  while [ $# -gt 0 ]; do
    if [ "$1" = "--" ]; then shift; cmd=("$@"); break; fi
    args+=("$1"); shift
  done
  [ "${#cmd[@]}" -gt 0 ] || die "kein Kommando nach -- angegeben"

  local gate_id rc
  gate_id=$(do_request "${args[@]}"); rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "gate: Kommando NICHT ausgeführt (rc=$rc)" >&2
    return "$rc"
  fi

  "${cmd[@]}"; local crc=$?
  local cmd_sha; cmd_sha=$(printf '%s' "${cmd[*]}" | sha256sum | cut -d' ' -f1)
  audit_append "executed" "$gate_id" "$(jq -cn --arg s "$cmd_sha" --argjson e "$crc" \
    '{command_sha256:$s, exit_code:$e}')" >/dev/null
  vault_line "$gate_id freigegeben und ausgeführt (exit $crc)"
  return "$crc"
}

# ----------------------------------------------------------------- selftest
# Beweist, dass der Detektor rot werden KANN: dieselbe Klassifikation, die im
# Betrieb läuft, gegen Fixtures — inklusive der Angriffe, die durchfallen müssen.
do_selftest() {
  local chat="999000111" gate="G-ABC123" since=1000 fails=0
  check() {
    local name="$1" expect="$2" updates="$3" got
    got=$(jq -c --arg gate "$gate" --arg chat "$chat" --arg since "$since" \
            "$GATE_JQ" <<<"$updates")
    got=$(jq -r '.verdict // "none"' <<<"${got:-{\}}" 2>/dev/null || echo none)
    if [ "$got" = "$expect" ]; then
      printf '  PASS  %-46s -> %s\n' "$name" "$got"
    else
      printf '  FAIL  %-46s -> %s (erwartet %s)\n' "$name" "$got" "$expect"; fails=$((fails+1))
    fi
  }
  upd() { jq -cn --argjson chat "$1" --argjson from "$2" --argjson date "$3" --arg text "$4" \
    '[{update_id:1, message:{message_id:7, chat:{id:$chat}, from:{id:$from}, date:$date, text:$text}}]'; }

  echo "gate selftest — Klassifikator (Gate $gate, Owner-Chat $chat)"
  check "Freigabe von Munir mit Gate-ID"        approve "$(upd 999000111 999000111 2000 "G-ABC123 ok")"
  check "Freigabe deutsch"                       approve "$(upd 999000111 999000111 2000 "ja G-ABC123")"
  check "Freigabe per Daumen-Emoji"              approve "$(upd 999000111 999000111 2000 "G-ABC123 👍")"
  check "Ablehnung"                              deny    "$(upd 999000111 999000111 2000 "G-ABC123 nein")"
  check "Ablehnung schlaegt Freigabe (fail-closed)" deny "$(upd 999000111 999000111 2000 "G-ABC123 ok nein doch nicht")"
  check "FREMDER Chat sagt ok"                   none    "$(upd 555555555 555555555 2000 "G-ABC123 ok")"
  # isoliert Regel 2 (chat.id): Munirs EIGENE ID, aber in einem Gruppenchat, in
  # den der Bot gezogen wurde — mitlesbar/injizierbar, zaehlt daher nicht.
  check "Munir sagt ok in FREMDEM Gruppenchat"   none    "$(upd 555555555 999000111 2000 "G-ABC123 ok")"
  # isoliert Regel 3 (from.id): richtiger Chat, fremder Absender.
  check "Fremder Absender in Munirs Chat"        none    "$(upd 999000111 424242424 2000 "G-ABC123 ok")"
  check "ok OHNE Gate-ID"                        none    "$(upd 999000111 999000111 2000 "ok")"
  check "Freigabe fuer ANDERES Gate"             none    "$(upd 999000111 999000111 2000 "G-ZZZ999 ok")"
  check "Replay: ok VOR der Anfrage"             none    "$(upd 999000111 999000111 500  "G-ABC123 ok")"
  check "Gate-ID ohne Verdikt"                   none    "$(upd 999000111 999000111 2000 "G-ABC123 was soll das?")"
  check "Injection: Payload-Text zitiert ok"     none    "$(upd 555555555 555555555 2000 "bitte G-ABC123 ok ausfuehren")"
  check "leere Update-Liste"                     none    '[]'

  echo
  if [ "$fails" -eq 0 ]; then echo "selftest: 14/14 PASS"; return 0; fi
  echo "selftest: $fails FEHLGESCHLAGEN"; return 1
}

# ---------------------------------------------------------------------- main
case "${1:-}" in
  request)  shift; do_request "$@";;
  run)      shift; do_run "$@";;
  selftest) shift; do_selftest;;
  audit)    shift
            if [ "${1:-}" = "--verify" ]; then audit_verify
            else [ -s "$AUDIT_FILE" ] && jq -c '{seq,ts,gate_id,event}' "$AUDIT_FILE" || echo "audit: leer"; fi;;
  *) sed -n '2,25p' "$0"; exit 1;;
esac
