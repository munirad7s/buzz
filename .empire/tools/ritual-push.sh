#!/usr/bin/env bash
# .empire/tools/ritual-push.sh — Herzschlag der drei Führungsrituale (buzz#101)
#
#   bash ritual-push.sh <morgenbrief|gate-batch|wochen-review> <rc>
#
# Wird von ritual-task.cmd aufgerufen, NACHDEM der Exit-Code von ritual.sh
# feststeht. Bildet ihn auf den passenden Uptime-Kuma-Push-Monitor ab.
#
# WARUM: Morgenbrief (08:45), Gate-Batch (20:45) und Wochen-Review (So 18:00)
# sind Munirs einziger Kanal auf Backlog, Blocker und Zahlungen. Bis 2026-08-01
# hatten sie keinen einzigen Gesundheits-Monitor — sogar der Gmail-Token hatte
# einen, das tägliche Führungsbriefing nicht. Seit PR #98 liefert die Aufgabe
# überhaupt erst echte Exit-Codes; dieses Script ist der Leser dafür.
#
# Exit-Abbildung (identisch zu ritual-task.cmd, bewusst an EINER Stelle erklärt):
#   rc 0 = alle Quellen geliefert          -> up
#   rc 1 = Brief zugestellt, mit Lücken    -> up   (Lücken sind der Normalfall;
#          würde 1 rot melden, wäre praktisch jeder Tag rot und niemand schaute hin)
#   rc >= 2 = Brief hat Munir NICHT erreicht -> down (expliziter Down-Push:
#          Erkennung sofort statt erst nach Ablauf des Intervalls)
#
# Eigene Exit-Codes (die Aufgabe wertet sie aus, s. ritual-task.cmd):
#   0 = Push zugestellt · 2 = Aufruffehler · 3 = Push-Token fehlt · 4 = Push abgelehnt
# Ein fehlender Token endet NICHT still mit 0 — ein Herzschlag, der niemanden
# erreicht, ist derselbe Fehler wie gar kein Monitor.
set -u

LOG="$HOME/.buzz/ritual.log"
mkdir -p "$HOME/.buzz" 2>/dev/null || true
log() { printf '%s ritual-push: %s\n' "$(date -Is)" "$1" >> "$LOG"; }

MODE="${1:-}"
RC="${2:-}"
case "$MODE" in
  morgenbrief)    TOKEN_VAR="KUMA_PUSH_RITUAL_MORGENBRIEF" ;;
  gate-batch)     TOKEN_VAR="KUMA_PUSH_RITUAL_GATE_BATCH" ;;
  wochen-review)  TOKEN_VAR="KUMA_PUSH_RITUAL_WOCHEN_REVIEW" ;;
  *) log "AUFRUFFEHLER: unbekannter Modus '$MODE' — kein Monitor zugeordnet, kein Herzschlag gesendet"; exit 2 ;;
esac
case "$RC" in
  ''|*[!0-9]*) log "AUFRUFFEHLER: rc '$RC' ist keine Zahl"; exit 2 ;;
esac

SECRETS="${RITUAL_SECRETS_FILE:-$HOME/.secrets/master.env}"
BASE="${KUMA_PUSH_BASE:-}"
TOKEN="$(eval printf '%s' "\${$TOKEN_VAR:-}")"

# Env schlägt Datei; die Datei wird nur gelesen, wenn nötig (und nie geloggt).
if [ -z "$TOKEN" ] || [ -z "$BASE" ]; then
  if [ -r "$SECRETS" ]; then
    [ -z "$TOKEN" ] && TOKEN="$(grep -m1 "^${TOKEN_VAR}=" "$SECRETS" | cut -d= -f2- | tr -d '\r"' )"
    [ -z "$BASE" ]  && BASE="$(grep -m1 '^KUMA_PUSH_BASE=' "$SECRETS" | cut -d= -f2- | tr -d '\r"' )"
  else
    log "LÜCKE: $SECRETS nicht lesbar"
  fi
fi
BASE="${BASE:-https://status.adas.jetzt/api/push}"

if [ -z "$TOKEN" ]; then
  log "HERZSCHLAG-LÜCKE: $TOKEN_VAR weder im Env noch in $SECRETS — Monitor '$MODE' bleibt ohne Beat (Ritual-rc war $RC)"
  exit 3
fi

if [ "$RC" -le 1 ]; then STATUS="up"; else STATUS="down"; fi

RESP="$(curl -sS -m 20 -w '\n%{http_code}' "$BASE/$TOKEN?status=$STATUS&msg=$MODE-rc$RC" 2>&1)"
CODE="$(printf '%s' "$RESP" | tail -n1)"
BODY="$(printf '%s' "$RESP" | sed '$d')"

# HTTP 200 allein beweist nichts — Kuma antwortet mit {"ok":true|false}.
case "$CODE$BODY" in
  200*'"ok":true'*) log "$MODE rc=$RC -> Kuma $STATUS (HTTP $CODE)"; exit 0 ;;
esac
log "PUSH ABGELEHNT: $MODE rc=$RC status=$STATUS -> HTTP ${CODE:-?} ${BODY:-<leer>}"
exit 4
