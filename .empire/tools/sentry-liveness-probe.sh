#!/usr/bin/env bash
# Liveness-Probe fuer den Dauer-Agenten "Sentry" auf adas-hetzner (buzz#77).
#
# WARUM PROZESS-STATUS NICHT REICHT
# ---------------------------------
# `systemctl is-active buzz-sentry` sagt nur, dass ein Prozess laeuft. Gemessen am
# 2026-08-01: der Agent beantwortete eine echte Mention in 3 Sekunden und schrieb
# dabei KEINE EINZIGE ZEILE ins Log (RUST_LOG=buzz_acp=info protokolliert nur
# Lebenszyklus-Ereignisse). Umgekehrt gilt dasselbe: der Prozess kann munter
# weiterlaufen, waehrend der Relay-Draht abgerissen, das LLM-Kontingent erschoepft
# oder der Provider auf 429/422 steht. Weder Prozess noch Log koennen den
# Unterschied zeigen — nur eine echte Antwort kann es.
#
# WAS SIE MISST
# -------------
# Den ganzen Pfad: Relay-Verbindung -> Kanal-Abo -> Allowlist -> Harness -> LLM ->
# Antwort zurueck in den Kanal. Sie postet eine Mention mit einem Einmal-Token und
# akzeptiert nur eine Antwort, die (a) von GENAU Sentrys Pubkey kommt und (b) das
# Token enthaelt. Ein "irgendwer hat irgendwas geschrieben" zaehlt nicht.
#
# EIGENE IDENTITAET, NICHT MUNIRS
# -------------------------------
# Die Probe signiert mit einem eigenen Schluessel (`/opt/buzz-agents/liveness.conf`,
# chmod 600), der auf Sentrys Allowlist steht. Munirs Owner-Key bleibt auf seinem
# Geraet — Schluessel verlassen ihr Geraet nicht (.empire/ONBOARDING.md §4.2).
#
# EIGENER KANAL
# -------------
# Sie laeuft in `diag-liveness`, nicht in Arbeitskanaelen. Sonst waere der Kanal, in
# dem Menschen mitlesen, zu 90 % Probenverkehr.
#
#   bash sentry-liveness-probe.sh              # Probe + Kuma-Heartbeat
#   bash sentry-liveness-probe.sh --no-push    # nur Probe
#
# Exit 0 = Sentry hat geantwortet. Exit 1 = jeder Fehlschlag, mit REASON= in der
# Ausgabe. Fehlschlag pusht NICHT: das Ausbleiben ist der Alarm (Kuma-Push-Monitor
# "sentry-liveness"). Ein einzelner Fehlschlag alarmiert dabei bewusst NICHT sofort
# — siehe Toleranz-Begruendung im Kopf von kuma-add-sentry-liveness.mjs.
set -uo pipefail

CONF="${SENTRY_LIVENESS_CONF:-/opt/buzz-agents/liveness.conf}"
BUZZ_BIN="${BUZZ_BIN:-/opt/buzz-agents/bin/buzz}"
STATUS_FILE="${SENTRY_LIVENESS_STATUS:-/opt/buzz-agents/logs/liveness-status.json}"
SENTRY_PUBKEY="${SENTRY_PUBKEY:-67160ec6fba47d29d6629a3a8aca00a5a0d90fe2c240ac9ff75460664bf3629f}"
DIAG_CHANNEL="${SENTRY_DIAG_CHANNEL:-7e06a1bc-8b3a-4dc5-8658-05a53073aabb}"
TIMEOUT_SEC="${SENTRY_LIVENESS_TIMEOUT:-180}"
KUMA_PUSH_BASE="${KUMA_PUSH_BASE:-https://status.adas.jetzt/api/push}"
PUSH=1
[ "${1:-}" = "--no-push" ] && PUSH=0

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

write_status() {
  # Statusdatei ist Diagnose fuer Menschen, nicht der Alarmweg. Der Alarm ist der
  # ausbleibende Kuma-Push — eine Datei, die niemand liest, alarmiert niemanden.
  printf '{"ts":"%s","result":"%s","reason":"%s","detail":"%s","latency_s":%s}\n' \
    "$started_at" "$1" "${2:-}" "$(printf '%s' "${3:-}" | tr -d '"' | tr '\n' ' ')" "${4:-null}" \
    > "$STATUS_FILE" 2>/dev/null || true
}

fail() {
  write_status "FAIL" "$1" "${2:-}"
  echo "RESULT=FAIL"
  echo "REASON=$1"
  [ -n "${2:-}" ] && echo "DETAIL=$2"
  [ -n "${3:-}" ] && echo "FIX=$3"
  echo "KUMA=kein Push — das Ausbleiben des Heartbeats ist der Alarm"
  exit 1
}

[ -r "$CONF" ] || fail "conf-missing" "$CONF nicht lesbar" "Identitaet der Probe anlegen (siehe buzz#77)"
# shellcheck disable=SC1090
set -a; . "$CONF"; set +a
[ -n "${BUZZ_PRIVATE_KEY:-}" ] || fail "no-private-key" "BUZZ_PRIVATE_KEY fehlt in $CONF"
[ -x "$BUZZ_BIN" ] || fail "buzz-cli-missing" "$BUZZ_BIN nicht ausfuehrbar"
export BUZZ_PRIVATE_KEY
export BUZZ_RELAY_URL="${BUZZ_LIVENESS_RELAY_URL:-https://buzz.adas.casa}"

TOKEN="lp$(date -u +%Y%m%d%H%M%S)$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
echo "TOKEN=$TOKEN"

t0=$(date +%s)
send_out="$("$BUZZ_BIN" --format json messages send --channel "$DIAG_CHANNEL" \
  --mention "$SENTRY_PUBKEY" \
  --content "Liveness-Probe $TOKEN — antworte nur mit: OK $TOKEN" 2>&1)"
send_id="$(printf '%s' "$send_out" | jq -r 'select(.accepted == true) | .event_id // empty' 2>/dev/null)"
[ -z "$send_id" ] && fail "send-failed" "Relay hat die Probe nicht angenommen: $(printf '%s' "$send_out" | head -c 300)" \
  "Relay erreichbar? Mitgliedschaft der Probe-Identitaet noch gueltig?"
echo "SENT=$send_id"

# Antwort einsammeln. Akzeptiert wird ausschliesslich: Absender == Sentry UND Token
# im Text. Ohne die Absenderpruefung wuerde die Probe das eigene Echo als Lebenszeichen
# verkaufen — der Detektor koennte dann nie rot werden.
deadline=$(( t0 + TIMEOUT_SEC ))
reply=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  sleep 10
  msgs="$("$BUZZ_BIN" --format json messages get --channel "$DIAG_CHANNEL" --limit 20 2>/dev/null)"
  reply="$(printf '%s' "$msgs" | jq -r --arg pk "$SENTRY_PUBKEY" --arg tok "$TOKEN" \
    '.[]? | select(.pubkey == $pk) | select(.content | contains($tok)) | .id' 2>/dev/null | head -1)"
  [ -n "$reply" ] && break
done
latency=$(( $(date +%s) - t0 ))

[ -z "$reply" ] && fail "no-reply" \
  "Sentry hat in ${TIMEOUT_SEC}s nicht geantwortet — Prozess kann laufen und trotzdem stumm sein" \
  "journalctl -u buzz-sentry -n 50 und /opt/buzz-agents/logs/sentry.log pruefen; haeufigste Ursache: LLM-Kontingent (429) oder Relay-Abriss"
echo "REPLY=$reply"
echo "LATENCY=${latency}s"

if [ "$PUSH" -eq 0 ]; then
  write_status "OK" "" "no-push" "$latency"
  echo "KUMA=uebersprungen (--no-push)"
  echo "RESULT=OK"
  exit 0
fi

[ -z "${KUMA_PUSH_SENTRY_LIVENESS_TOKEN:-}" ] && fail "kuma-token-missing" \
  "KUMA_PUSH_SENTRY_LIVENESS_TOKEN fehlt in $CONF" \
  "Monitor anlegen: .empire/tools/kuma-add-sentry-liveness.mjs"

code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
  "${KUMA_PUSH_BASE}/${KUMA_PUSH_SENTRY_LIVENESS_TOKEN}?status=up&msg=$(printf 'sentry antwortet in %ss' "$latency" | jq -sRr @uri)" 2>&1)"
[ "$code" != "200" ] && fail "kuma-push-failed" "HTTP $code" "Kuma/Monitor sentry-liveness pruefen"
write_status "OK" "" "" "$latency"
echo "KUMA=heartbeat gepusht"
echo "RESULT=OK"
exit 0
