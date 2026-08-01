#!/usr/bin/env bash
# Test für decision-drafts.sh (buzz#42) gegen einen lokalen Telegram-Mock.
#
# Der Mock ersetzt AUSSCHLIESSLICH den Transport (TELEGRAM_API_BASE) — Sammler,
# Format-Filter, jq-Extraktion und das Umschreiben der Note sind echt. Getestet
# wird auch das, was NICHT passieren darf: fremder Chat, fremder Absender und
# eine Nachricht ohne ID dürfen keine Begründung einpflegen.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../decision-drafts.sh"
TMP="${TMPDIR:-/tmp}/dd-test-$$"
VAULT="$TMP/vault"
OWNER_CHAT=5504083685
fails=0

ok() { if [ "$2" = "1" ]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s — %s\n' "$1" "${3:-}"; fails=$((fails+1)); fi; }

mkdir -p "$VAULT/01 Journal/$(date +%Y-%m)" "$VAULT/08 Decisions" "$TMP"
cat > "$VAULT/01 Journal/$(date +%Y-%m)/$(date +%Y-%m-%d).md" <<'JOURNAL'
# Tagesnotiz

- 🐝 tester: ⚖️ Decision-Kandidat: Testentscheidung äöüß — Alternativen verworfen
- 🐝 tester: normale Zeile ohne Marker
- 🐝 tester: Doku erwähnt den `⚖️ Decision-Kandidat:`-Marker nur in Backticks
JOURNAL

# --- Mock: liefert eine feste getUpdates-Antwort, akzeptiert sendMessage ------
cat > "$TMP/mock.mjs" <<'MOCK'
import { createServer } from "node:http";
const updates = JSON.parse(process.env.MOCK_UPDATES);
createServer((req, res) => {
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    res.setHeader("content-type", "application/json");
    if (req.url.endsWith("/getUpdates")) res.end(JSON.stringify({ ok: true, result: updates }));
    else res.end(JSON.stringify({ ok: true, result: { message_id: 4242 } }));
  });
}).listen(Number(process.env.MOCK_PORT), () => console.error("mock up"));
MOCK

msg() { # chat from text
  jq -cn --argjson c "$1" --argjson f "$2" --arg t "$3" \
    '{update_id:1, message:{message_id:9, chat:{id:$c}, from:{id:$f}, date:9, text:$t}}'
}

run() { TELEGRAM_API_BASE="http://127.0.0.1:$PORT" TELEGRAM_BOT_TOKEN=x \
        TELEGRAM_CHAT_ID="$OWNER_CHAT" VAULT_DIR="$VAULT" bash "$SCRIPT" "$@"; }

start_mock() {
  MOCK_UPDATES="[$1]" MOCK_PORT="$PORT" node "$TMP/mock.mjs" 2>/dev/null &
  MOCK_PID=$!
  for _ in $(seq 1 40); do curl -s "http://127.0.0.1:$PORT/x" >/dev/null 2>&1 && return 0; sleep 0.25; done
}
stop_mock() { kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; }

PORT=$(( 20000 + RANDOM % 20000 ))

echo "decision-drafts test"

out=$(run collect --days 0 2>&1)
ok "Sammler nimmt nur das dokumentierte Format" \
   "$([ "$(grep -c 'angelegt:' <<<"$out")" = "1" ] && echo 1 || echo 0)" "$out"

ID=$(run list | awk '{print $1}' | head -1)
NOTE=$(grep -rl "^decision_id: $ID\$" "$VAULT/08 Decisions")

out=$(run collect --days 0 2>&1)
ok "Zweiter Lauf erzeugt keine Dublette" \
   "$([ "$(grep -c 'angelegt:' <<<"$out")" = "0" ] && echo 1 || echo 0)" "$out"

start_mock "$(msg 999 999 "$ID weil fremder Chat")"
run ingest >/dev/null 2>&1
stop_mock
ok "Fremder Chat pflegt NICHTS ein" "$(grep -q '^status: draft$' "$NOTE" && echo 1 || echo 0)"

start_mock "$(msg $OWNER_CHAT 424242 "$ID weil fremder Absender")"
run ingest >/dev/null 2>&1
stop_mock
ok "Fremder Absender pflegt NICHTS ein" "$(grep -q '^status: draft$' "$NOTE" && echo 1 || echo 0)"

start_mock "$(msg $OWNER_CHAT $OWNER_CHAT "einfach nur ok")"
run ingest >/dev/null 2>&1
stop_mock
ok "Antwort ohne ID pflegt NICHTS ein" "$(grep -q '^status: draft$' "$NOTE" && echo 1 || echo 0)"

start_mock "$(msg $OWNER_CHAT $OWNER_CHAT "$ID weil der Scope nie gemessen war — äöüß")"
out=$(run ingest 2>&1)
stop_mock
ok "Munirs Warum wird eingepflegt" \
   "$(grep -q '^status: active$' "$NOTE" && grep -q 'weil der Scope nie gemessen war' "$NOTE" && echo 1 || echo 0)" "$out"
ok "Umlaute überleben das Einpflegen" "$(grep -q 'äöüß' "$NOTE" && echo 1 || echo 0)"
ok "Platzhalter ist weg" "$(grep -qv 'offen' "$NOTE" && ! grep -q '\*\*offen\*\*' "$NOTE" && echo 1 || echo 0)"

out=$(run ask 2>&1)
ok "Ohne offene Entwürfe wird nicht gefragt" \
   "$(grep -q 'keine offenen Entwürfe' <<<"$out" && echo 1 || echo 0)" "$out"

start_mock "$(msg $OWNER_CHAT $OWNER_CHAT noop)"
cat >> "$VAULT/01 Journal/$(date +%Y-%m)/$(date +%Y-%m-%d).md" <<'MORE'
- 🐝 tester: ⚖️ Decision-Kandidat: Zweite Testentscheidung — nur fuer das Buendel
MORE
run collect --days 0 >/dev/null 2>&1
out=$(run ask 2>&1)
stop_mock
ok "Fragen gehen als EINE gebündelte Nachricht" \
   "$(grep -q '1 Nachricht mit 1 Frage' <<<"$out" && echo 1 || echo 0)" "$out"

echo
if [ "$fails" -eq 0 ]; then echo "decision-drafts: alle Proben PASS"; else echo "decision-drafts: $fails FEHLGESCHLAGEN"; fi
exit "$fails"
