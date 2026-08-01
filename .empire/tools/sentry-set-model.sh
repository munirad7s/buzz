#!/usr/bin/env bash
# Modellwechsel fuer den Dauer-Agenten "Sentry" — mit Beweis und Selbst-Rollback (buzz#77).
#
# WOFUER
# ------
# Sentry haengt an einem FREIEN OpenRouter-Modell. Freie Modelle sind kein Vertrag:
# sie laufen in Rate-Limits (`429`), verschwinden ohne Ankuendigung (`404`) oder
# vertragen die Tool-Schemata des Harness nicht (`422 ... schema references`). Dann
# ist der Agent still — der Prozess laeuft, die Antwort bleibt aus.
#
# Der Wechsel selbst ist eine Zeile in der Env-Datei. Gefaehrlich ist nicht der
# Wechsel, sondern der ungepruefte Wechsel: ein Tippfehler im Modellnamen macht den
# Agenten genauso stumm wie das kaputte Modell, nur merkt es niemand, weil "ich habe
# ja umgestellt" wie eine Loesung aussieht. Deshalb beweist dieses Script den neuen
# Zustand, bevor es ihn behaelt — und stellt sonst selbst zurueck.
#
#   bash sentry-set-model.sh <modell>     # z. B. deepseek/deepseek-chat-v3.1:free
#   bash sentry-set-model.sh --show       # aktuelles Modell
#
# Exit 0 = neues Modell aktiv UND bewiesen. Exit 1 = zurueckgerollt (altes Modell
# wieder aktiv und ebenfalls geprueft). Exit 2 = Rollback selbst fehlgeschlagen —
# nur dann ist Handarbeit noetig, und dann sagt es das deutlich.
set -uo pipefail

CONF="${SENTRY_CONF:-/opt/buzz-agents/sentry.conf}"
PROBE="${SENTRY_LIVENESS_PROBE:-/opt/buzz-agents/liveness-probe.sh}"
UNIT="${SENTRY_UNIT:-buzz-sentry}"
PROBE_TIMEOUT="${SENTRY_SET_MODEL_TIMEOUT:-120}"

current() { sed -n 's/^OPENROUTER_MODEL=//p' "$CONF" | tr -d '\r'; }

[ -w "$CONF" ] || { echo "FEHLER: $CONF nicht schreibbar (als root ausfuehren)"; exit 2; }

if [ "${1:-}" = "--show" ] || [ $# -eq 0 ]; then
  echo "MODELL=$(current)"
  [ $# -eq 0 ] && { echo "Aufruf: sentry-set-model.sh <modell>"; exit 1; }
  exit 0
fi

NEW="$1"
OLD="$(current)"
[ -n "$OLD" ] || { echo "FEHLER: OPENROUTER_MODEL steht nicht in $CONF"; exit 2; }
[ "$NEW" = "$OLD" ] && { echo "MODELL=$OLD (unveraendert, nichts zu tun)"; exit 0; }
echo "ALT=$OLD"
echo "NEU=$NEW"

apply() {
  # Punkte und Schraegstriche in Modellnamen: sed-Trennzeichen ist deshalb '|'.
  sed -i "s|^OPENROUTER_MODEL=.*|OPENROUTER_MODEL=$1|" "$CONF"
  systemctl restart "$UNIT" || return 1
  sleep 12
  return 0
}

verify() {
  # --no-push: ein Modelltest darf den Heartbeat nicht faelschen. Der Heartbeat
  # gehoert dem planmaessigen Timer, nicht diesem Handlauf.
  SENTRY_LIVENESS_TIMEOUT="$PROBE_TIMEOUT" bash "$PROBE" --no-push
}

cp "$CONF" "$CONF.bak-setmodel"
if ! apply "$NEW"; then
  echo "RESULT=FAIL"; echo "REASON=restart-failed"; apply "$OLD" >/dev/null 2>&1; exit 2
fi

if verify; then
  echo "RESULT=OK"
  echo "MODELL=$NEW aktiv und durch eine echte Antwort belegt"
  exit 0
fi

echo "--- Neues Modell antwortet nicht -> automatischer Rollback auf $OLD ---"
if ! apply "$OLD"; then
  echo "RESULT=FAIL"; echo "REASON=rollback-restart-failed"
  echo "FIX=$CONF.bak-setmodel zurueckkopieren und '$UNIT' von Hand starten"
  exit 2
fi
if verify; then
  echo "RESULT=FAIL"
  echo "REASON=new-model-silent"
  echo "MODELL=$OLD wieder aktiv und geprueft — der Agent ist nicht schlechter dran als vorher"
  exit 1
fi
echo "RESULT=FAIL"
echo "REASON=rollback-verify-failed"
echo "FIX=Weder '$NEW' noch '$OLD' antworten. Ursache ist dann NICHT das Modell —"
echo "    Relay-Abriss oder OpenRouter-Key pruefen: journalctl -u $UNIT -n 50"
exit 2
