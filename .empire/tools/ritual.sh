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
# Sechs statt zwölf: der Batch ist nur etwas wert, wenn Munir ihn abends
# wirklich durchgeht. Zwölf Entscheidungen sind auf dem Telefon eine Wand und
# werden weggewischt; die Sortierung (P1-money zuerst) sorgt dafür, dass die
# sechs teuersten oben stehen, und der Rest wird gezählt statt verschwiegen.
BRIEF_LIMIT="${RITUAL_GATE_LINES:-6}"
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
# Der Brief spricht Deutsch — auch im Datum. `date '+%a'` liefert unter MSYS
# "Sat", und ein englischer Wochentag in einem deutschen Brief ist genau die
# Sorte Systemgeruch, die hier weg soll.
DATE_DE="$(printf '%s, %s' \
  "$(printf 'Sonntag Montag Dienstag Mittwoch Donnerstag Freitag Samstag' | cut -d' ' -f$(( $(date '+%w') + 1 )))" \
  "$(date '+%d.%m.%Y')")"
CLOCK="$(date '+%H:%M')"
# Eine Lücke gehört dorthin, wo der Leser sie sonst als 0 lesen würde — nicht in
# einen Sammelblock am Ende. Deshalb trägt jede Lücke ihre Zielabschnitte mit
# (Leerzeichen-getrennt): geld · menschen · tag · laeuft · entscheidungen · sonst.
GAPFILE="$TMP/gaps"; : > "$GAPFILE"
gap() { printf '%s\t%s\n' "$1" "$2" >> "$GAPFILE"; }
gaps_for() { awk -F'\t' -v w="$1" '{n=split($1,c," "); for(i=1;i<=n;i++) if(c[i]==w){print $2; break}}' "$GAPFILE"; }
gaps_flat() { cut -f2- "$GAPFILE"; }
# Im Brief steht kein Stichwort-Fragment, sondern ein Satz — auch die Luecke.
gaps_satz() { gaps_for "$1" | sed 's/[^.…!?]$/&./'; }
has_gap() { [ -n "$(gaps_for "$1")" ]; }
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
  local blocks="$1" extra="${2:-}"
  # $extra ist bewusst unquoted: es traegt hoechstens das Wort --amounts.
  bash "$HERE/lagebild.sh" --format json --blocks "$blocks" $extra > "$TMP/lage.json" 2>"$TMP/lage.err"
  local rc=$?
  if [ ! -s "$TMP/lage.json" ] || ! jq -e . "$TMP/lage.json" >/dev/null 2>&1; then
    gap "geld laeuft entscheidungen" "Das Lagebild hat nichts geliefert (exit $rc): $(head -c 120 "$TMP/lage.err" | tr -d '\n')"
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
    local st reason cat name
    st="$(jq -r --arg b "$b" '.[$b].state // "fehlt"' "$TMP/lage.json" | tr -d "$CR")"
    reason="$(jq -r --arg b "$b" '.[$b].reason // "ohne Begründung"' "$TMP/lage.json" | tr -d "$CR")"
    case "$b" in
      backlog) cat="entscheidungen"; name="der Backlog" ;;
      pay)     cat="geld";           name="die Zahlungen" ;;
      *)       cat="laeuft";         name="$b" ;;
    esac
    case "$st" in
      ok) ;;
      warn) [ "$b" = "backlog" ] && gap "$cat" "Der Backlog wurde nur unvollständig gelesen: $reason" ;;
      *)    gap "$cat" "Ich konnte $name nicht messen ($st): $reason" ;;
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
    gap "entscheidungen" "Die Projektsuche hat nichts zurückgegeben — ich kenne heute nur die gepflegte Projektliste, es können Projekte fehlen"
  elif [ "$(printf '%s\n' "$found" | wc -l | tr -d ' ')" -ge "$lim" ]; then
    gap "entscheidungen" "Die Projektsuche lief ins Limit ($lim) — es können weitere Projekte mit offenen Entscheidungen existieren"
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
      # `body` kommt mit: der Gate-Batch schreibt die Folgen eines Ja und eines
      # Nein aus, und die stehen im Ticket selbst (## Mission / ## Money-Link).
      # Ohne den Text müsste der Brief sie erfinden — das ist verboten.
      if out="$(gh issue list -R "$repo" --state open --label blocked-munir -L "$limit" \
                 --json number,title,labels,createdAt,url,body 2>/dev/null </dev/null)"; then
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
  # Eine Liste mit 25 Repo-Namen ist im Brief eine Wand. Zahl + Beispiele
  # sagen dasselbe und bleiben lesbar; die Vollstaendigkeit steht im Log.
  [ -n "$unreadable" ] && gap "entscheidungen" "$(kuerzeliste "$unreadable" "Projekte konnte ich nicht lesen") — was dort auf dich wartet, fehlt hier (das ist keine Null)"

  if ! ls "$TMP/bl"/*.json >/dev/null 2>&1; then
    gap "entscheidungen" "Kein einziges Projekt war lesbar — ich weiß heute nicht, was auf dich wartet"
    # KEINE leere Liste erzeugen. Eine leere Liste wäre eine stille Null und
    # der Batch würde "Heute kein Munir-Gate" melden — die gefährlichste
    # denkbare Falschaussage dieses Rituals (gemessen als Bug, dann behoben).
    return 1
  fi
  jq -s 'add | map({repo, number, url, title, body,
                    labels: (.labels|map(.name)),
                    createdAt})
        | sort_by( (if (.labels|index("P1-money")) then 0
                    elif (.labels|index("P1")) then 1
                    elif (.labels|index("P2")) then 2 else 3 end), .createdAt )' \
    "$TMP/bl"/*.json > "$TMP/blocked.json" 2>/dev/null \
    || { gap "entscheidungen" "Die offenen Entscheidungen ließen sich nicht zusammenführen"; rm -f "$TMP/blocked.json"; return 1; }
  jq -e 'type == "array"' "$TMP/blocked.json" >/dev/null 2>&1 \
    || { gap "entscheidungen" "Die Liste der offenen Entscheidungen kam beschädigt zurück"; rm -f "$TMP/blocked.json"; return 1; }
  return 0
}

# (c) Menschen — wer geschrieben hat und wer wartet.
#
# Der Brief zählt keine Nachrichten mehr, er nennt Menschen. Grund, gemessen am
# 01.08.: die 50 neuesten Posteingangs-Nachrichten der letzten FÜNF Tage waren
# ausnahmslos Maschinen — GitHub-CI, das eigene Monitoring, Revolut, Werbung.
# Die alte Zeile "≥50 neue, davon ≥43 ungelesen" maß also reines CI-Rauschen,
# und weil gmail_search bei 50 deckelt, wäre eine echte Kundenmail dahinter
# UNSICHTBAR geblieben. Deshalb wird das Rauschen serverseitig ausgeschlossen,
# bevor der Deckel greift — und das, was danach übrig bleibt, wird namentlich
# genannt statt gezählt.
# Was hier hängen bleibt, ist gemessen und nicht geraten (Absenderliste vom
# 01.08.): Absender, die nie antworten (no-reply, mailer-daemon, Versand-
# Subdomains), Rollen-Postfächer von Dienstleistern (support@, service@,
# invoice…, billing@) — und, der größte Posten, Munirs EIGENE Systeme, die ihm
# in sein eigenes Postfach schreiben (mondsamt@, autopilot@, foerderwerk@,
# kontakt@ auf den eigenen Domains). Ein Kunde schreibt nicht von adas.team.
# Bewusster Preis: schriebe ein echter Kunde von support@seinefirma.de, landete
# er in dieser Zählung. Deshalb steht die Zahl der Aussortierten IM Brief —
# sichtbar falsch ist besser als unsichtbar weg.
MACHINE_RE='noreply|no-reply|no_reply|donotreply|do-not-reply|mailer-daemon|postmaster|bounce|notifications@|notification@|newsletter|@notify\.|@mail\.|@email\.|@e\.|automated|@bot\.|^support@|^service@|^alerts?@|^invoice|^billing@|^team@|^accounts?@|^security@'
OWN_DOMAINS="${RITUAL_OWN_DOMAINS:-adas\.team|adasgroup\.de|adas\.jetzt|adas\.casa}"
PEOPLE_CAP=8
REST_CAP=3
collect_people() {
  local out q
  # Serverseitig weg: eigene Post, Chats, Entwürfe, Werbung, Soziales und die
  # beiden gemessen lautesten Absender. Fenster 7 Tage, damit "wartet seit
  # vorgestern" überhaupt sichtbar werden kann.
  # Der Ausschluss gehoert in die ABFRAGE, nicht hinter sie: gmail_search
  # deckelt bei 50, und wenn 48 dieser 50 Plaetze von Maschinen belegt sind,
  # bleibt eine echte Kundenmail unsichtbar hinter dem Deckel. Gemessen genau
  # so am 01.08. Was hier serverseitig wegfaellt, faellt drinnen nochmal durch
  # MACHINE_RE — zwei Netze, weil das Gmail-Matching unscharf ist.
  q='in:inbox newer_than:7d -in:sent -in:chats -in:drafts'
  q="$q -category:promotions -category:social"
  q="$q -from:notifications@github.com -from:adas.team -from:adasgroup.de"
  q="$q -from:noreply -from:no-reply -from:mailer-daemon -from:notification"
  if ! out="$(node "$HERE/mcp-call.mjs" --server google-mcp --tool gmail_search \
              --config "$MCP_CONFIG" --timeout 90000 \
              --args "$(jq -cn --arg q "$q" '{query:$q, maxResults:50}')" 2>"$TMP/people.err")"; then
    gap "menschen" "Ich komme heute nicht ans Postfach: $(head -c 120 "$TMP/people.err" | tr -d '\n'). Ob jemand geschrieben hat, weiß ich nicht."
    return 1
  fi
  printf '%s' "$out" | jq -e '.messages' >/dev/null 2>&1 || {
    gap "menschen" "Das Postfach hat geantwortet, aber ohne Nachrichtenliste — ob jemand geschrieben hat, weiß ich nicht."; return 1; }
  printf '%s' "$out" > "$TMP/mail.json"
  [ "$(jq -r '.messages|length' "$TMP/mail.json")" -ge 50 ] && \
    gap "menschen" "Das Postfach lief ins Abfrage-Limit (50) — es können ältere Nachrichten fehlen"

  # Maschinen aussortieren. Die Zahl der Aussortierten wird genannt, nicht
  # verschwiegen: sonst sähe ein leerer Menschen-Block wie ein Messfehler aus.
  jq --arg re "$MACHINE_RE" --arg own "$OWN_DOMAINS" '
    def addr: (.from | capture("<(?<a>[^>]+)>").a) // .from | ascii_downcase;
    def person: (.from | sub(" *<.*>$";"") | sub("^\"";"") | sub("\"$";"") | gsub("^ +| +$";""));
    [ .messages[] | . + {email: addr, person: (if (person|length) > 0 then person else addr end)} ]
    | map(. + {machine: ((.email | test($re)) or (.email | test("@(" + $own + ")$")))})
    | {humans: [.[] | select(.machine|not)], machines: ([.[] | select(.machine)] | length)}
  ' "$TMP/mail.json" > "$TMP/people-raw.json" 2>/dev/null \
    || { gap "menschen" "Die Post ließ sich nicht auswerten — ob jemand geschrieben hat, weiß ich nicht."; return 1; }

  # Einordnung: zahlender Kunde vor Interessent vor Rest. Zwei Quellen, beide
  # nur lesend — Vault-Kundenordner (Zusagen-Kanon) und CRM (Pipeline-Wahrheit).
  local vaultdir="${RITUAL_CLIENT_DIR:-$HOME/Documents/Ai_Brain/04 Areas/clients}"
  if [ -d "$vaultdir" ]; then
    ls -1 "$vaultdir" 2>/dev/null | sed 's#/$##' | grep -v '^_' | grep -v '\.md$' > "$TMP/clients.txt"
  else
    : > "$TMP/clients.txt"
    gap "menschen" "Die Kundenliste im Vault ist nicht lesbar ($vaultdir) — ich kann heute nicht sagen, wer davon zahlender Kunde ist"
  fi

  local n; n="$(jq -r '.humans|length' "$TMP/people-raw.json")"
  if [ "$n" -gt "$PEOPLE_CAP" ]; then
    gap "menschen" "Mehr als $PEOPLE_CAP Menschen im Fenster — ich habe nur die $PEOPLE_CAP jüngsten eingeordnet"
  fi

  mkdir -p "$TMP/crm"
  local i=0 mail
  while IFS= read -r mail; do
    [ -z "$mail" ] && continue
    i=$((i+1)); [ "$i" -gt "$PEOPLE_CAP" ] && break
    (
      for ent in Contact Lead; do
        node "$HERE/mcp-call.mjs" --server espo-mcp --tool espo_search \
          --config "$MCP_CONFIG" --timeout 60000 \
          --args "$(jq -cn --arg q "$mail" --arg e "$ent" '{entityType:$e, query:$q, maxSize:3}')" \
          > "$TMP/crm/$i.$ent.json" 2>/dev/null || rm -f "$TMP/crm/$i.$ent.json"
      done
    ) &
  done < <(jq -r '.humans[].email' "$TMP/people-raw.json" | awk '!seen[$0]++')
  wait

  # Ein CRM, das nicht antwortet, darf nicht wie "kein Kunde" aussehen.
  local crm_ok=1
  if [ "$n" -gt 0 ] && ! ls "$TMP/crm"/*.json >/dev/null 2>&1; then
    crm_ok=0
    gap "menschen" "Das CRM hat nicht geantwortet — ich konnte nicht prüfen, wer davon Kunde und wer Interessent ist"
  fi

  # Die Einordnung bleibt in der Shell: jq soll nicht raten, welche CRM-Antwort
  # zu welchem Menschen gehört — das weiß nur die Schleife, die sie geholt hat.
  : > "$TMP/people.jsonl"
  i=0
  while IFS= read -r mail; do
    [ -z "$mail" ] && continue
    i=$((i+1)); [ "$i" -gt "$PEOPLE_CAP" ] && break
    local klasse="" quelle=""
    if [ -s "$TMP/crm/$i.Contact.json" ] && [ "$(jq -r '.total // 0' "$TMP/crm/$i.Contact.json" 2>/dev/null || echo 0)" -gt 0 ]; then
      klasse="kunde"; quelle="CRM-Kontakt"
    elif [ -s "$TMP/crm/$i.Lead.json" ] && [ "$(jq -r '.total // 0' "$TMP/crm/$i.Lead.json" 2>/dev/null || echo 0)" -gt 0 ]; then
      if jq -e '[.list[].status] | index("Converted")' "$TMP/crm/$i.Lead.json" >/dev/null 2>&1; then
        klasse="kunde"; quelle="CRM (gewonnen)"
      else
        klasse="interessent"; quelle="CRM-Lead"
      fi
    fi
    # Vault schlägt CRM: dort stehen die Zusagen, und ein Ordner unter
    # 04 Areas/clients existiert nur für jemanden, mit dem es echt läuft.
    local dom slug
    dom="$(printf '%s' "$mail" | sed 's/.*@//; s/\.[a-z]*$//' | tr 'A-Z' 'a-z')"
    if [ -n "$dom" ] && [ -s "$TMP/clients.txt" ]; then
      slug="$(grep -i -m1 -- "$dom" "$TMP/clients.txt" 2>/dev/null || true)"
      [ -n "$slug" ] && { klasse="kunde"; quelle="Kundenordner $slug"; }
    fi
    jq -c --arg mail "$mail" --arg k "$klasse" --arg q "$quelle" '
      [.humans[] | select(.email == $mail)] | sort_by(.date) | last
      | {person, email, subject, date, unread: ((.labelIds//[]) | index("UNREAD") != null),
         klasse: $k, quelle: $q, anzahl: 1}' "$TMP/people-raw.json" >> "$TMP/people.jsonl" 2>/dev/null
  done < <(jq -r '.humans[].email' "$TMP/people-raw.json" | awk '!seen[$0]++')

  jq -s --argjson machines "$(jq -r '.machines' "$TMP/people-raw.json")" \
        --argjson crm_ok "$crm_ok" \
        --argjson total "$n" '
     { machines: $machines, crm_ok: $crm_ok, total_humans: $total,
       people: (. | sort_by(if .klasse=="kunde" then 0 elif .klasse=="interessent" then 1 else 2 end,
                            .date) ) }' "$TMP/people.jsonl" > "$TMP/people.json" 2>/dev/null \
    || { gap "menschen" "Die Menschen-Liste ließ sich nicht zusammenstellen"; rm -f "$TMP/people.json"; return 1; }
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
    gap "tag" "Deinen Kalender habe ich heute nicht erreicht: $(head -c 120 "$TMP/cal.err" | tr -d '\n'). Verlass dich nicht darauf, dass der Tag frei ist."
    return 1
  fi
  printf '%s' "$out" | jq -e '.events' >/dev/null 2>&1 || {
    gap "tag" "Der Kalender hat geantwortet, aber ohne Termine — verlass dich nicht darauf, dass der Tag frei ist."; return 1; }
  printf '%s' "$out" > "$TMP/cal.json"
  # Ein einzelner unlesbarer Kalender darf nicht wie ein leerer Tag aussehen.
  local bad; bad="$(jq -r '.unreadable|length' "$TMP/cal.json")"
  [ "$bad" -gt 0 ] && gap "tag" "$bad Kalender waren nicht lesbar — die Terminliste ist unvollständig"
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
    gap "laeuft" "Den Werkzeug-Check konnte ich nicht ausführen (exit $rc): $why"
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
  command -v ssh >/dev/null || { gap "sonst" "Die Löschspur im CRM habe ich nicht geprüft (ssh fehlt) — das ist kein \"nichts gelöscht\""; return 1; }
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
    gap "sonst" "Die Löschspur im CRM habe ich nicht geprüft: $(head -c 100 "$TMP/crm.err" 2>/dev/null | tr '\n' ' ') — das ist kein \"nichts gelöscht\""
    rm -f "$TMP/crm.raw"; return 1
  fi
  if ! grep -q '^crm_ok=1$' "$TMP/crm.raw"; then
    gap "sonst" "Die Löschspur im CRM habe ich nicht geprüft: $(grep -m1 '^crm_err=' "$TMP/crm.raw" | cut -d= -f2- || echo 'ohne Begründung') — das ist kein \"nichts gelöscht\""
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
  # Das Fenster ist ein Parameter: das Wochen-Review fragt nach der Woche, der
  # Gate-Batch am Abend nach HEUTE. Zwei Leser, zwei Zeitraeume, ein Sammler.
  local seit="${1:-$WEEK_START}"
  local repo capped="" unreadable=""
  mkdir -p "$TMP/cl"
  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    (
      slug="$(printf '%s' "$repo" | tr '/' '~')"
      if out="$(gh issue list -R "$repo" --state closed --search "closed:>=$seit" \
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
  [ -n "$unreadable" ] && gap "sonst" "$(kuerzeliste "$unreadable" "Projekte konnte ich nicht auf fertige Aufgaben prüfen") — sie fehlen in der Summe und zählen NICHT als 0"
  [ -n "$capped" ] && gap "sonst" "geschlossene Aufgaben am Limit ($CLOSED_LIMIT) in:$capped — die Summe ist eine Untergrenze"

  if ! ls "$TMP/cl"/*.json >/dev/null 2>&1; then
    gap "sonst" "Kein einziges Projekt war lesbar — was heute fertig wurde, weiß ich nicht"
    return 1
  fi
  jq -s 'add | sort_by(.closedAt) | reverse' "$TMP/cl"/*.json > "$TMP/closed.json" 2>/dev/null \
    || { gap "sonst" "Die geschlossenen Aufgaben ließen sich nicht zusammenführen"; rm -f "$TMP/closed.json"; return 1; }
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
    gap "sonst" "Vorschlag: P1-Auffüller nicht erhoben (gh search fehlgeschlagen) — Block 4 kann kürzer als 3 sein"
    return 1
  fi
  printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1 || {
    gap "sonst" "Vorschlag: P1-Auffüller lieferte kein Array — Block 4 kann kürzer als 3 sein"; return 1; }
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
  [ -d "$SNAPDIR" ] || { gap "sonst" "Vergleichsbasis fehlt — noch kein Snapshot-Verzeichnis ($SNAPDIR). Die Bewegungszahlen unter 3) sind NICHT 0, sondern unbekannt."; return 1; }
  local prev
  prev="$(ls -1 "$SNAPDIR"/*.json 2>/dev/null | sort | awk -v cur="$SNAPDIR/$WEEK_ID.json" '$0 < cur' | tail -1)"
  if [ -z "$prev" ] || [ ! -s "$prev" ] || ! jq -e '.blocked' "$prev" >/dev/null 2>&1; then
    gap "sonst" "Vergleichsbasis fehlt — kein verwertbarer Snapshot vor $WEEK_ID. Die Bewegungszahlen unter 3) sind NICHT 0, sondern unbekannt."
    return 1
  fi
  cp "$prev" "$TMP/prev.json"
  PREV_WEEK="$(jq -r '.week // "unbekannt"' "$TMP/prev.json")"
  # Ein Snapshot, dem Repos fehlten, erzeugt Phantom-"neu" und Phantom-"gelöst".
  local pu; pu="$(jq -r '.repos_unreadable // [] | join(" ")' "$TMP/prev.json")"
  [ -n "$pu" ] && gap "sonst" "Vergleichs-Snapshot $PREV_WEEK war unvollständig (nicht gelesen: $pu) — neu/gelöst können Messartefakte enthalten"
  return 0
}

write_snapshot() {
  [ "$SNAPSHOT" = "1" ] || { echo "snapshot: --no-snapshot gesetzt, nichts geschrieben" >&2; return 0; }
  mkdir -p "$SNAPDIR" || { gap "sonst" "Snapshot-Verzeichnis $SNAPDIR nicht anlegbar — nächste Woche fehlt die Vergleichsbasis"; return 1; }
  local unread="[]"
  grep -q 'Diese Projekte konnte ich nicht lesen' "$GAPFILE" 2>/dev/null && \
    unread="$(grep -m1 'Diese Projekte konnte ich nicht lesen' "$GAPFILE" | sed 's/.*lesen://; s/ — was dort.*//' | tr ' ' '\n' | awk 'NF' | jq -R . | jq -s .)"
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
    || { gap "sonst" "Snapshot $WEEK_ID.json konnte nicht geschrieben werden"; return 1; }
  echo "snapshot: $SNAPDIR/$WEEK_ID.json geschrieben" >&2
  return 0
}

# (d) Foki — die drei #-Überschriften aus Now.md. Vault ist Kanon.
collect_foki() {
  if [ ! -f "$NOW_MD" ]; then
    gap "sonst" "Now.md nicht lesbar ($NOW_MD) — Top-3 fehlen"; return 1
  fi
  grep -E '^## #[123] ' "$NOW_MD" | sed -E 's/^## #[123] //' | head -3 > "$TMP/foki.txt"
  [ -s "$TMP/foki.txt" ] || { gap "sonst" "Now.md enthält keine '## #1..#3'-Foki — Top-3 fehlen"; return 1; }
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

# ---------------------------------------------------------------- Sprache
#
# Munir liest den Brief um 08:45 auf dem Telefon, mit einem drei Wochen alten
# Baby und zwei Drittversuch-Klausuren in der Woche. Er hat zwei Minuten. Was
# hier steht, muss in ganzen Sätzen stehen, kurz sein und ohne Fachjargon
# auskommen — Ticket-Nummern gehören in Klammern ans Zeilenende, nie in den
# Satz. Deshalb rendern die Briefe REINEN TEXT: kein Markdown, keine Tabellen,
# keine Codeblöcke. Was auf dem Telefon zerfallen kann, kommt hier nicht vor.

WOCHENTAG_DE="Sonntag Montag Dienstag Mittwoch Donnerstag Freitag Samstag"
ZAHL_DE="null eine zwei drei vier fünf sechs sieben acht neun zehn elf zwölf"

zahlwort() { # 3 -> "drei"; ab 13 die Ziffer (Zahlwörter werden dann unlesbar)
  local n="$1"
  [ "$n" -ge 0 ] 2>/dev/null || { printf '%s' "$n"; return; }
  [ "$n" -gt 12 ] && { printf '%s' "$n"; return; }
  printf '%s' "$(printf '%s' "$ZAHL_DE" | cut -d' ' -f$((n+1)))"
}

wann() { # Zeitstempel -> "heute um 09:12" / "gestern um 14:40" / "am Mittwoch"
  local raw="$1" ts now hm dmsg dnow dyest tage wd
  ts="$(date -d "$raw" '+%s' 2>/dev/null)"
  [ -z "$ts" ] && { printf 'zu unbekannter Zeit'; return; }
  now="$(date '+%s')"
  hm="$(date -d "@$ts" '+%H:%M')"
  dmsg="$(date -d "@$ts" '+%Y-%m-%d')"
  dnow="$(date '+%Y-%m-%d')"
  dyest="$(date -d 'yesterday' '+%Y-%m-%d' 2>/dev/null)"
  if [ "$dmsg" = "$dnow" ]; then printf 'heute um %s' "$hm"
  elif [ "$dmsg" = "$dyest" ]; then printf 'gestern um %s' "$hm"
  else
    tage=$(( (now - ts) / 86400 ))
    wd="$(printf '%s' "$WOCHENTAG_DE" | cut -d' ' -f$(( $(date -d "@$ts" '+%w') + 1 )))"
    if [ "$tage" -le 7 ]; then printf 'am %s um %s' "$wd" "$hm"
    else printf 'vor %s Tagen' "$tage"; fi
  fi
}

# Markdown und Ticket-Nummern aus fremdem Text (Issue-Bodies) entfernen: der
# Brief zitiert die Tickets, aber er soll nicht nach Ticket klingen.
entmarkdown() {
  sed -e 's/\*\*//g' -e 's/`//g' -e 's/\[\([^]]*\)\](\([^)]*\))/\1/g' \
      -e 's/[[:space:]]\+/ /g' -e 's/^ //' -e 's/ $//'
}

# Telefon-Breite. Ein Satz, der als eine 190 Zeichen lange Zeile ankommt, wird
# von Telegram und vom Buzz-Client irgendwo umgebrochen — meist mitten im Wort
# und ohne Einrückung. Deshalb bricht der Brief selbst um, am Wortende, und
# rückt Folgezeilen ein, damit die Struktur auf dem Telefon stehen bleibt.
BREITE="${RITUAL_WIDTH:-64}"
falte() {
  awk -v w="$BREITE" '{
    match($0, /^ */); ind = substr($0, 1, RLENGTH); rest = substr($0, RLENGTH + 1)
    if (length($0) <= w || rest == "") { print; next }
    cont = ind "   "
    n = split(rest, word, " ")
    line = ind word[1]
    for (i = 2; i <= n; i++) {
      if (length(line) + 1 + length(word[i]) > w) { print line; line = cont word[i] }
      else { line = line " " word[i] }
    }
    print line
  }'
}

kuerzeliste() { # " a b c d" + "Text" -> "4 Projekte Text (u. a. a, b, c)"
  local items="$1" text="$2" n joined
  # shellcheck disable=SC2086 — die Wortaufteilung ist hier gewollt
  set -- $(printf '%s' "$items" | tr ' ' '\n' | sed 's#^munirad7s/##' | awk 'NF')
  n=$#
  if [ "$n" -gt 3 ]; then
    printf '%s %s (u. a. %s, %s, %s)' "$n" "$text" "$1" "$2" "$3"
  else
    joined="$(printf '%s\n' "$@" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
    printf '%s %s (%s)' "$n" "$text" "$joined"
  fi
}

kurz() { # $1 Text, $2 Maximallänge — schneidet an der letzten Wortgrenze
  local s="$1" n="$2"
  s="$(printf '%s' "$s" | entmarkdown)"
  if [ "${#s}" -gt "$n" ]; then
    s="${s:0:$n}"; s="${s% *}"; printf '%s …' "$s"
  else printf '%s' "$s"; fi
}

titel_klar() { # "[GATE] Foo anlegen — Bar (5-Min-Handgriff Munir)" -> "Foo anlegen — Bar"
  printf '%s' "$1" | sed -e 's/^\[[A-Za-z-]*\] *//' -e 's/ *([^()]*)$//' -e 's/^ *//'
}

ref_of() { # munirad7s/agency-infra + 138 -> "agency-infra 138"
  printf '%s %s' "$(printf '%s' "$1" | sed 's#^munirad7s/##')" "$2"
}

# ------------------------------------------------------- Befunde aus den Daten
#
# Kopfzeile, Läuft-Block und die Zwei-Minuten-Empfehlung müssen dieselbe Lage
# beurteilen. Deshalb wird sie EINMAL ermittelt und dann nur noch formuliert.

KAPUTT=""          # eine Zeile je kaputter Sache
KAPUTT_KURZ=""     # dieselbe Sache in Kopfzeilen-Länge
WARTET_NAME=""; WARTET_SEIT=""; WARTET_KLASSE=""
GELD_ALARM=""

# Euro deutsch: 49.99 ist eine Maschinenzahl, 49,99 ist ein Betrag.
euro() { printf '%s' "$1" | sed 's/\./,/'; }

befunde() {
  KAPUTT=""
  if [ -f "$TMP/lage.json" ]; then
    local z
    z="$(jq -r '
      [ (if (.server.state? // "ok") != "ok" then
           "Auf dem Server stimmt etwas nicht: "
           + ([ (if ((.server.kuma_down // [])|length) > 0
                 then "die Überwachung meldet " + ((.server.kuma_down)|join(", ")) + " als ausgefallen" else empty end),
                (if ((.server.containers_unhealthy // 0)|tonumber? // 0) > 0
                 then ((.server.containers_unhealthy|tostring)) + " Dienste sind ungesund" else empty end),
                (if ((.server.disk_used_pct // 0)|tonumber? // 0) >= 90
                 then "die Festplatte ist zu " + (.server.disk_used_pct|tostring) + " Prozent voll" else empty end),
                # agency-infra#134: ein Monitor ohne Benachrichtigung wird nie
                # rot GEMELDET. Er kann also nur hier auffallen — sonst fällt
                # er nie auf, und das ist der gefährlichere Zustand als "rot".
                (if ((.server.kuma_silent // [])|length) > 0
                 then "diese Überwachung meldet sich bei niemandem: "
                      + ((.server.kuma_silent)|join(", ")) else empty end)
              ] | if length == 0 then ["Genaueres steht im Lagebild"] else . end | join("; ")) + "."
         else empty end),
        (if (.n8n.state? // "ok") != "ok" and ((.n8n.errors_total // 0)|tonumber? // 0) > 0 then
           "In der Automatisierung sind " + (.n8n.errors_total|tostring)
           + " Läufe schiefgegangen"
           + (if ((.n8n.by_workflow // [])|length) > 0
              then ", am häufigsten " + (.n8n.by_workflow[0].workflow) else "" end) + "."
         else empty end),
        # adas-empire#85: Eine Fehlerzahl aus einem Fenster, das die Historie
        # gar nicht abdeckt, ist eine Untergrenze — und sie sieht aus wie eine
        # Entwarnung. Das muss im Brief stehen, nicht nur im Lagebild-JSON.
        (if (.n8n.retention_known? == false) then
           "Von der Automatisierung ist unklar, wie weit ihr Gedächtnis zurückreicht — die Fehlerzahl oben ist deshalb nicht belastbar."
         elif (.n8n.retention_covers_window? == false) then
           "Die Automatisierung erinnert sich nur bis " + (.n8n.retention_oldest // "?")
           + "; alles davor ist gelöscht. Die Fehlerzahl oben ist eine Untergrenze, keine Entwarnung."
         else empty end),
        (if ((.n8n.stale_workflows? // [])|length) > 0 then
           "Seit über " + ((.n8n.stale_days // "?")|tostring) + " Tagen nicht mehr gelaufen: "
           + ((.n8n.stale_workflows)|join(", ")) + " (bei Wochen-Takt ein Ausfall, bei Monats-Takt normal)."
         else empty end)
      ] | .[]' "$TMP/lage.json" 2>/dev/null | tr -d "$CR")"
    [ -n "$z" ] && KAPUTT="$z"
  fi
  if [ -f "$TMP/nest.json" ]; then
    local nz
    nz="$(jq -r '
      ([.servers[]|select(.status!="ok")|.name]) as $bad |
      [ (if ($bad|length) > 0 then "Werkzeuge fehlen den Agenten: " + ($bad|join(", ")) + "." else empty end),
        (if .trust_accepted != "true" then "Die Agenten vertrauen ihrer eigenen Werkzeugliste nicht — sie arbeiten ohne." else empty end),
        (if .process_drift == "ja" then "Die laufenden Agenten haben noch den alten Werkzeugkasten; ein Neustart im Desktop holt sie ab." else empty end)
      ] | .[]' "$TMP/nest.json" 2>/dev/null | tr -d "$CR")"
    [ -n "$nz" ] && KAPUTT="${KAPUTT:+$KAPUTT
}$nz"
  fi

  # Die Kopfzeile darf nicht "irgendwas ist kaputt" sagen und den Leser nach
  # unten schicken — sie muss allein tragen. Also: dieselbe erste Sache, nur
  # kurz genug für eine Zeile.
  KAPUTT_KURZ=""
  [ -n "$KAPUTT" ] && KAPUTT_KURZ="$(kurz "$(printf '%s\n' "$KAPUTT" | head -1 \
      | sed -e 's/^Auf dem Server stimmt etwas nicht: //' -e 's/\.$//' -e 's/;.*//')" 62)"

  GELD_ALARM=""
  if [ -f "$TMP/lage.json" ]; then
    local f; f="$(jq -r '.pay.last24_failed_after_method // 0' "$TMP/lage.json" | tr -d "$CR")"
    [ "${f:-0}" -gt 0 ] 2>/dev/null && GELD_ALARM="$f"
  fi

  WARTET_NAME=""; WARTET_SEIT=""; WARTET_KLASSE=""
  if [ -f "$TMP/people.json" ]; then
    local w
    w="$(jq -r '[.people[] | select(.unread) | select(.klasse=="kunde" or .klasse=="interessent")]
                | sort_by(if .klasse=="kunde" then 0 else 1 end, .date) | .[0]
                | if . == null then "" else "\(.klasse)\t\(.person)\t\(.date)" end' \
         "$TMP/people.json" 2>/dev/null | tr -d "$CR")"
    if [ -n "$w" ]; then
      WARTET_KLASSE="$(printf '%s' "$w" | cut -f1)"
      WARTET_NAME="$(printf '%s' "$w" | cut -f2)"
      WARTET_SEIT="$(wann "$(printf '%s' "$w" | cut -f3)")"
    fi
  fi
}

# Genau EINE Handlung. Die Reihenfolge ist die Rangfolge: ein wartender Kunde
# schlägt jede Entscheidung, eine Geld-Entscheidung schlägt jede andere.
zwei_minuten() {
  if [ -n "$WARTET_NAME" ] && [ "$WARTET_KLASSE" = "kunde" ]; then
    printf 'Antworte %s. Zwei Sätze reichen — Hauptsache, es kommt heute etwas zurück.\n' "$(kurz "$WARTET_NAME" 40)"
    return
  fi
  if [ -f "$TMP/blocked.json" ] && [ "$(jq -r 'length' "$TMP/blocked.json")" -gt 0 ]; then
    local e t r n
    e="$(jq -r '([.[] | select(.labels|index("P1-money"))] + .) | .[0] | "\(.title)\t\(.repo)\t\(.number)"' \
         "$TMP/blocked.json" | tr -d "$CR")"
    t="$(titel_klar "$(printf '%s' "$e" | cut -f1)")"
    r="$(printf '%s' "$e" | cut -f2)"; n="$(printf '%s' "$e" | cut -f3)"
    [ "$REDACT" = "1" ] && t="‹Titel geschwärzt›"
    printf 'Entscheide das hier: %s (%s)\n' "$(kurz "$t" 60)" "$(ref_of "$r" "$n")"
    printf 'Antwort genügt, den Rest übernehmen wir.\n'
    return
  fi
  if [ -n "$WARTET_NAME" ]; then
    printf 'Schreib %s kurz zurück — dort wartet jemand.\n' \
      "$([ "$REDACT" = "1" ] && printf '‹Name geschwärzt›' || kurz "$WARTET_NAME" 40)"
    return
  fi
  if [ -s "$TMP/foki.txt" ] && [ "$REDACT" != "1" ]; then
    printf 'Nichts Dringendes von außen. Nimm dir: %s\n' "$(kurz "$(head -1 "$TMP/foki.txt")" 62)"
    return
  fi
  printf 'Nichts. Der Tag gehört dir.\n'
}

# --------------------------------------------------------------- Morgenbrief

render_morgenbrief() {
  local out="$TMP/brief.md"
  befunde
  {
    # --- Kopfzeile: ganze Worte, keine Zahl, kein Status-Code. Wer nur diese
    # Zeile liest, muss trotzdem wissen, woran er ist.
    printf 'Guten Morgen. %s\n' "$DATE_DE"
    printf '\n'
    if [ -n "$WARTET_NAME" ] && [ "$WARTET_KLASSE" = "kunde" ]; then
      printf 'Ein Kunde wartet auf dich, seit %s.\n' "$WARTET_SEIT"
    elif [ -n "$KAPUTT" ]; then
      printf 'Etwas läuft nicht: %s.\n' "$KAPUTT_KURZ"
    elif [ -n "$GELD_ALARM" ]; then
      printf 'Jemand wollte zahlen und kam nicht durch.\n'
    elif [ -n "$WARTET_NAME" ]; then
      printf 'Jemand wartet auf eine Antwort, seit %s.\n' "$WARTET_SEIT"
    elif [ -n "$(gaps_for menschen)" ] || [ -n "$(gaps_for laeuft)" ] || [ -n "$(gaps_for geld)" ]; then
      printf 'Ruhig, soweit ich sehen konnte — ich kam heute nicht an alles heran.\n'
    elif [ -f "$TMP/blocked.json" ] && [ "$(jq -r 'length' "$TMP/blocked.json")" -gt 0 ]; then
      printf 'Ruhig. Nichts brennt — heute Abend warten Entscheidungen auf dich.\n'
    else
      printf 'Ruhig. Nichts wartet auf dich.\n'
    fi

    # --- Geld
    printf '\n💶 Geld\n'
    # NUR ok/warn tragen Zahlen. Ein Block mit state "error" enthält trotzdem
    # ein .pay-Objekt, und `// 0` würde daraus "Kein Zahlungseingang" und
    # "kein Abo" machen — zwei zuversichtliche Falschaussagen aus einer toten
    # Quelle. Genau das trat in der Rot-Probe auf und ist der Grund für diese
    # Bedingung; "fehlt" allein zu prüfen reichte nicht.
    local pst="fehlt"
    [ -f "$TMP/lage.json" ] && pst="$(jq -r '.pay.state // "fehlt"' "$TMP/lage.json" | tr -d "$CR")"
    if [ "$pst" != "ok" ] && [ "$pst" != "warn" ]; then
      if [ -n "$(gaps_for geld)" ]; then gaps_satz geld | sed 's/^/   /'
      else printf '   Ich konnte die Zahlungen heute nicht abfragen. Das heißt nicht, dass nichts kam.\n'; fi
    else
      jq -r --argjson redact "$REDACT" '
        .pay as $p |
        ( if ($p.last24_paid // 0) > 0 then
            "   " + (if ($p.last24_paid) == 1 then "Eine Zahlung ist eingegangen"
                     else ($p.last24_paid|tostring) + " Zahlungen sind eingegangen" end)
            + (if $redact == 0 and $p.last24_paid_eur != null
               then ", zusammen " + (($p.last24_paid_eur|tostring)|sub("[.]";",")) + " Euro" else "" end)
            + (if (($p.last24_paid_methods // [])|length) > 0
               then " (" + (($p.last24_paid_methods)|join(", ")) + ")" else "" end) + "."
          else "   Kein Zahlungseingang in den letzten 24 Stunden." end ),
        ( if ($p.last24_failed_after_method // 0) > 0 then
            "   Achtung: " + (($p.last24_failed_after_method)|tostring)
            + " Mal hat jemand die Zahlungsart schon gewählt und ist dann hängengeblieben."
          else empty end ),
        ( if ($p.subscriptions_active // 0) > 0 then
            "   " + (if ($p.subscriptions_active) == 1 then "Ein Abo läuft weiter"
                     else ($p.subscriptions_active|tostring) + " Abos laufen weiter" end)
            + (if $redact == 0 and $p.mrr_eur != null
               then " und bringt " + (($p.mrr_eur|tostring)|sub("[.]";",")) + " Euro im Monat" else "" end) + "."
          else "   Es läuft aktuell kein Abo." end ),
        ( if ($p.payments_window_complete // true) then empty
          else "   Ich sehe nur die letzten 50 Zahlungen — ältere von gestern können fehlen." end ),
        # Zweiter Zahlungsweg (buzz#36). Getrennt genannt, nie dazugerechnet —
        # und wenn er fehlt, steht das hier, statt dass „Kein Zahlungseingang"
        # so klingt, als wäre es die ganze Wahrheit.
        ( ($p.stripe.state // "fehlt") as $st |
          if $st == "unconfigured"
            then "   Stripe kann ich nicht sehen — dort könnte Geld eingegangen sein, das in dieser Zeile fehlt."
          elif $st == "error"
            then "   Stripe hat nicht geantwortet. Was dort ankam, weiß ich heute nicht."
          elif $st == "fehlt"
            then "   Stripe habe ich gar nicht erst abgefragt — die Zeilen oben sind nur Mollie."
          elif ($p.stripe.last24_paid // 0) > 0
            then "   Bei Stripe sind zusätzlich "
                 + (if ($p.stripe.last24_paid) == 1 then "eine Zahlung" else (($p.stripe.last24_paid)|tostring) + " Zahlungen" end)
                 + " eingegangen"
                 + (if $redact == 0 and $p.stripe.last24_paid_eur != null
                    then ", zusammen " + (($p.stripe.last24_paid_eur|tostring)|sub("[.]";",")) + " Euro" else "" end) + "."
          else "   Bei Stripe kam ebenfalls nichts an"
               + (if ($p.stripe.subscriptions_active // 0) > 0
                  then " (" + (($p.stripe.subscriptions_active)|tostring) + " laufende Abos)" else "" end) + "."
          end )
      ' "$TMP/lage.json" | tr -d "$CR"
      gaps_satz geld | sed 's/^/   /'
    fi

    # --- Menschen
    printf '\n✉️ Menschen\n'
    if [ ! -f "$TMP/people.json" ]; then
      if [ -n "$(gaps_for menschen)" ]; then gaps_satz menschen | sed 's/^/   /'
      else printf '   Ich komme heute nicht ans Postfach — ob jemand geschrieben hat, weiß ich nicht.\n'; fi
    else
      local np; np="$(jq -r '.people|length' "$TMP/people.json")"
      if [ "$np" -eq 0 ]; then
        printf '   Niemand hat geschrieben.\n'
      else
        while IFS=$'\t' read -r klasse person subject date unread; do
          [ -z "$person" ] && continue
          local rolle=""
          case "$klasse" in
            kunde) rolle=" (Kunde)" ;;
            interessent) rolle=" (Interessent)" ;;
          esac
          if [ "$REDACT" = "1" ]; then person="‹Name geschwärzt›"; subject="‹Betreff geschwärzt›"; fi
          printf '   %s%s hat %s geschrieben.\n' "$(kurz "$person" 34)" "$rolle" "$(wann "$date")"
          printf '      Betreff: %s%s\n' "$(kurz "$subject" 46)" \
            "$([ "$unread" = "true" ] && printf ' — wartet noch auf Antwort')"
        # Kein Feld darf leer sein: `read` mit IFS=TAB behandelt den Tabulator
        # als Whitespace und schluckt führende Leerfelder — dann rutscht die
        # ganze Zeile um eine Spalte und der Betreff steht als Absender im
        # Brief. Genau das ist beim Bau passiert. Also überall ein Platzhalter.
        #
        # Kunden und Interessenten stehen VOLLSTÄNDIG da; vom Rest nur die
        # ältesten drei, damit ein Dienstleister-Postfach keinen wartenden
        # Kunden aus dem Blick schiebt. Was übrig bleibt, wird gezählt.
        done < <(jq -r --argjson restcap "$REST_CAP" '
                        ([.people[] | select(.klasse=="kunde" or .klasse=="interessent")]
                         + ([.people[] | select(.klasse!="kunde" and .klasse!="interessent")][0:$restcap]))[] |
                        [ (if (.klasse // "") == "" then "rest" else .klasse end),
                          (if (.person // "") == "" then "Unbekannt" else .person end),
                          (if (.subject // "") == "" then "(ohne Betreff)" else .subject end),
                          (if (.date // "") == "" then "-" else .date end),
                          (.unread|tostring) ] | @tsv' \
                 "$TMP/people.json" | tr -d "$CR")
      fi
      local nrest nm
      nrest="$(jq -r --argjson c "$REST_CAP" \
        '([.people[] | select(.klasse!="kunde" and .klasse!="interessent")]|length) - $c
         | if . < 0 then 0 else . end' "$TMP/people.json")"
      [ "${nrest:-0}" -gt 0 ] 2>/dev/null && \
        printf '   Dazu %s weitere Absender, keiner davon Kunde oder Interessent.\n' "$nrest"
      nm="$(jq -r '.machines' "$TMP/people.json")"
      [ "${nm:-0}" -gt 0 ] 2>/dev/null && \
        printf '   Und %s automatische Benachrichtigungen — die habe ich weggelassen.\n' "$nm"
      gaps_satz menschen | sed 's/^/   /'
    fi

    # --- Dein Tag
    printf '\n📅 Dein Tag\n'
    if [ ! -f "$TMP/cal.json" ]; then
      if [ -n "$(gaps_for tag)" ]; then gaps_satz tag | sed 's/^/   /'
      else printf '   Deinen Kalender habe ich nicht erreicht — plane nicht mit einem freien Tag.\n'; fi
    else
      local nev; nev="$(jq -r '.events|length' "$TMP/cal.json")"
      if [ "$nev" -eq 0 ]; then
        if [ "$(jq -r '.unreadable|length' "$TMP/cal.json")" -gt 0 ]; then
          printf '   In den Kalendern, die ich lesen konnte, steht nichts — aber nicht alle waren lesbar.\n'
        else
          printf '   Keine Termine. Der Tag gehört dir.\n'
        fi
      else
        # Termine sind Privatsache: unter --redact (öffentlicher Beleg) bleibt
        # die Uhrzeit stehen, der Inhalt nicht.
        jq -r --arg heute "$(date '+%Y-%m-%d')" --argjson redact "$REDACT" '
          def was($s): if $redact == 1 then "‹Termin geschwärzt›" else ($s|.[0:44]) end;
          [.events[]|select(.allDay)] as $a |
          [.events[]|select(.allDay|not)] as $t |
          ([ $a[] | "   Den ganzen Tag: " + was(.summary) + "." ]
           + [ $t[] | (if (.start|.[0:10]) == $heute then "   Um " else "   Morgen um " end)
                      + (.start|.[11:16]) + " " + was(.summary)
                      + (if .location and $redact == 0 then " (" + (.location|.[0:22]) + ")" else "" end) + "." ])[0:6] | .[]
        ' "$TMP/cal.json" | tr -d "$CR"
        [ "$nev" -gt 6 ] && printf '   Danach stehen noch %s weitere Einträge im Kalender.\n' "$((nev-6))"
      fi
      gaps_satz tag | sed 's/^/   /'
    fi

    # --- Läuft (nur wenn etwas kaputt ist)
    printf '\n⚙️ Läuft\n'
    if [ -n "$KAPUTT" ]; then
      printf '%s\n' "$KAPUTT" | sed 's/^/   /'
    elif [ -n "$(gaps_for laeuft)" ]; then
      printf '   Ich konnte die Technik nicht vollständig prüfen:\n'
    else
      printf '   Alles läuft. Nichts kaputt.\n'
    fi
    gaps_satz laeuft | sed 's/^/   /'

    # --- Wenn du zwei Minuten hast
    printf '\n⏱️ Wenn du zwei Minuten hast\n'
    zwei_minuten | sed 's/^/   /'
  } | falte > "$out"
  printf '%s' "$out"
}

# ---------------------------------------------------------------- Gate-Batch

# Die Folgen eines Ja und eines Nein werden dem Ticket ENTNOMMEN, nie erfunden:
# "Ja" ist die Mission des Tickets (der Zustand, den es herstellt), "Nein" ist
# der Satz aus dem Money-Link, der mit "Ohne" beginnt (der Preis des Nichtstuns).
# Fehlt einer der beiden, steht dort ein ehrlicher Platzhalter — kein erfundener
# Nutzen und kein erfundener Schaden.
render_gate_lines() { # $1 = Anzahl — nummeriert, damit "1 ja, 2 nein" funktioniert
  local n="$1"
  jq -r --argjson n "$n" --argjson redact "$REDACT" '
    def clean: gsub("\\*\\*";"") | gsub("`";"") | gsub("\\[(?<t>[^]]*)\\]\\([^)]*\\)";"\(.t)")
               | gsub("\\s+";" ") | gsub("^ +| +$";"");
    def section($h):
      ("\n" + ((.body // "") | gsub("\r";"")))
      | split("\n## ") | map(select(startswith($h))) | (.[0] // "")
      | split("\n") | .[1:] | map(select(test("\\S"))) | (.[0] // "") | clean;
    def satz1: . as $t
      | ([ $t | match("[.!?](\\s|$)"; "g").offset ] | map(select(. >= 25)) | .[0]) as $i
      | (if $i == null then $t else $t[0:$i+1] end);
    def schnitt($n): if (.|length) > $n then (.[0:$n] | sub(" [^ ]*$";"")) + " …" else . end;
    # Klammer-Einschuebe raus, BEVOR gekuerzt wird: sie kosten die Haelfte der
    # Zeile und tragen fuer die Entscheidung nichts bei. Erst danach schneiden —
    # sonst endet jeder zweite Satz mitten in einer technischen Aufzaehlung.
    def entklammert: gsub("\\s*\\([^()]*\\)";"") | gsub("\\s+";" ") | gsub("^ +| +$";"");
    def titel: (.title | sub("^\\[[A-Za-z-]*\\] *";"") | sub(" *\\([^()]*\\)$";"")) | clean;
    .[0:$n] | to_entries[] |
    (.value.repo | sub("^munirad7s/";"")) as $repo |
    (.value | section("Mission") | satz1 | entklammert | schnitt(150)) as $ja |
    (.value | section("Money-Link") | split(". ")
      | map(select(test("^([Oo]hne |Solange |Bis dahin )"))) | (.[0] // "") | clean | entklammert | schnitt(150)) as $nein |
    "\(.key+1)) " + (if $redact == 1 then "‹Titel geschwärzt›" else (.value | titel | schnitt(58)) end),
    "   (\($repo) \(.value.number))",
    "   Sagst du ja: " + (if $redact == 1 then "‹geschwärzt›"
                          elif ($ja|length) > 0 then $ja
                          else "das Vorhaben läuft weiter — was genau dabei herauskommt, steht im Ticket." end),
    "   Sagst du nein oder gar nichts: " + (if $redact == 1 then "‹geschwärzt›"
                          elif ($nein|length) > 0 then ($nein | if test("[.!?…]$") then . else . + "." end)
                          else "es bleibt genau so liegen wie jetzt, und die Frage kommt morgen wieder." end),
    ""
  ' "$TMP/blocked.json"
}

# CRM-Löschzeile — buzz#79. Schwelle NICHT geraten, sondern aus 8 Tagen
# Aktionshistorie gemessen: 26.07.–31.07. löschte täglich genau `n8n-agent`
# 1× Lead + 1× CTouchpoint (der Funnel-Probe aus buzz#53) — sonst nichts.
# Alles darüber und jeder andere User ist erklärungsbedürftig.
# 0 Löschungen ist KEIN Ruhezustand: dann hat der Probe nicht gelöscht.
plural_del() { [ "$1" -eq 1 ] && printf 'Löschung' || printf 'Löschungen'; }

render_crm_deletions() {
  local win="${RITUAL_CRM_WINDOW_H:-24}"
  if [ ! -f "$TMP/crm.raw" ]; then
    printf '   Ob im CRM etwas gelöscht wurde, konnte ich heute nicht prüfen. Das heißt nicht, dass nichts gelöscht wurde.\n'
    return
  fi
  local total probe rest last comp
  total="$(awk -F'|' '/^crm_row=/{s+=$3} END{print s+0}' "$TMP/crm.raw")"
  probe="$(awk -F'|' '/^crm_row=/{u=$1; sub(/^crm_row=/,"",u);
             if (u=="n8n-agent" && ($2=="Lead" || $2=="CTouchpoint")) s += ($3>1 ? 1 : $3)}
           END{print s+0}' "$TMP/crm.raw")"
  rest=$((total - probe))
  last="$(grep -m1 '^crm_last=' "$TMP/crm.raw" | cut -d= -f2-)"

  # Jede Aussage ist EINE logische Zeile — den Umbruch macht `falte`, sonst
  # bricht erst das printf und dann nochmal der Falter, und der Satz zerfällt.
  if [ "$total" -eq 0 ]; then
    # 0 ist hier KEIN Ruhezustand: die tägliche Funnel-Probe löscht ihre eigenen
    # Testdaten wieder. Löscht sie nichts, dann lief sie nicht.
    printf '   Im CRM wurde nichts gelöscht — auch die tägliche Testbuchung nicht. Die räumt sonst immer hinter sich auf, also läuft sie vermutlich nicht mehr. Letzte Löschung überhaupt: %s.\n' "${last:--}"
  elif [ "$rest" -eq 0 ]; then
    comp="$(awk -F'|' '/^crm_row=/{ c = c (c=="" ? "" : ", ") $3 "× " $2 } END{print c}' "$TMP/crm.raw")"
    printf '   Im CRM hat in %s Stunden nur die tägliche Testbuchung gelöscht (%s). So soll es sein.\n' "$win" "$comp"
  else
    printf '   Achtung: im CRM wurde %s Mal gelöscht, davon %s Mal nicht von der täglichen Testbuchung. Das gehört angeschaut:\n' "$total" "$rest"
    if [ "$REDACT" = "1" ]; then
      printf '      (wer genau, ist hier geschwärzt)\n'
    else
      awk -F'|' '/^crm_row=/{
            u=$1; sub(/^crm_row=/,"",u);
            a[u] = a[u] (a[u]=="" ? "" : ", ") $3 "× " $2;
            t[u] += $3 }
          END{ for (u in t) printf "%d\t      %s: %s\n", t[u], u, a[u] }' "$TMP/crm.raw" \
        | sort -rn | cut -f2- | head -3
    fi
    [ "$probe" -eq 0 ] && printf '      Die tägliche Testbuchung lief dabei gar nicht.\n'
  fi
}

render_gate_batch() {
  local out="$TMP/brief.md"
  local nb=0; [ -f "$TMP/blocked.json" ] && nb="$(jq -r 'length' "$TMP/blocked.json")"
  local zeige="$nb"; [ "$zeige" -gt "$BRIEF_LIMIT" ] && zeige="$BRIEF_LIMIT"
  {
    printf 'Guten Abend. %s\n\n' "$DATE_DE"
    if [ ! -f "$TMP/blocked.json" ]; then
      printf 'Ich konnte heute nicht nachsehen, was auf dich wartet.\n'
      printf 'Das heißt ausdrücklich nicht, dass nichts wartet.\n'
      gaps_satz entscheidungen | sed 's/^/   /'
    elif [ "$nb" -eq 0 ]; then
      if [ -n "$(gaps_for entscheidungen)" ]; then
        printf 'In dem, was ich lesen konnte, wartet nichts — aber ich konnte nicht alles lesen.\n'
        gaps_satz entscheidungen | sed 's/^/   /'
      else
        printf 'Heute nichts zu entscheiden. Nichts wartet auf dich.\n'
      fi
    else
      # Kopfzeile: wie viele Entscheidungen und wie lange das dauert.
      local minuten=$(( (zeige + 1) / 2 )); [ "$minuten" -lt 1 ] && minuten=1
      printf '%s %s, etwa %s %s.\n' \
        "$(zahlwort "$zeige" | sed 's/^./\U&/')" \
        "$([ "$zeige" -eq 1 ] && printf 'Entscheidung' || printf 'Entscheidungen')" \
        "$(zahlwort "$minuten")" \
        "$([ "$minuten" -eq 1 ] && printf 'Minute' || printf 'Minuten')"
      printf 'Antworte einfach mit den Nummern, zum Beispiel "1 ja, 2 nein".\n\n'
      # Eine Kopfzeile, die sechs Entscheidungen ankündigt, gefolgt von nichts,
      # ist die stillste aller stillen Nullen — sie sieht aus wie ein leerer
      # Abend. Gemessen beim Bau: ein jq-Compilefehler tat genau das. Deshalb
      # wird das Ergebnis erst geprüft und dann gedruckt.
      local zeilen; zeilen="$(render_gate_lines "$zeige" | tr -d "$CR")"
      if [ -z "$zeilen" ]; then
        printf 'Ich konnte die Entscheidungen nicht aufbereiten — sie sind da,\n'
        printf 'aber ich kann sie dir heute nicht vorlegen. Bitte im Backlog\n'
        printf 'nach der Markierung blocked-munir schauen.\n\n'
        gap "entscheidungen" "Die Entscheidungen ließen sich nicht in Textform bringen (Render-Fehler)"
      else
        printf '%s\n\n' "$zeilen"
      fi
      if [ "$nb" -gt "$zeige" ]; then
        printf 'Es warten noch %s weitere, die heute nicht dringend sind.\n' "$((nb-zeige))"
      fi
      gaps_satz entscheidungen | sed 's/^/   /'
    fi

    # Was heute gelaufen ist — höchstens fünf Zeilen, dann Schluss.
    printf '\nWas heute gelaufen ist\n'
    if [ ! -f "$TMP/closed.json" ]; then
      if [ -n "$(gaps_for sonst)" ]; then gaps_satz sonst | head -2 | sed 's/^/   /'
      else printf '   Konnte ich heute nicht zusammenzählen.\n'; fi
    else
      local ct; ct="$(jq -r 'length' "$TMP/closed.json")"
      if [ "$ct" -eq 0 ]; then
        printf '   Heute wurde nichts fertig.\n'
      else
        local top
        top="$(jq -r --argjson redact "$REDACT" '
          group_by(.repo) | sort_by(-length) | .[0:3][] |
          "   " + (.[0].repo|sub("^munirad7s/";"")) + ": "
          + (if $redact == 1 then "‹geschwärzt›"
             else (.[0].title | sub("^\\[[^]]*\\] *";"") | sub("^P[0-9](-money)?: *";"")
                   | if length > 40 then (.[0:40] | sub(" [^ ]*$";"")) else . end) end)
          + (if length > 1 then " und " + ((length-1)|tostring) + " weitere" else "" end)' \
          "$TMP/closed.json" | tr -d "$CR")"
        printf '   %s %s fertig geworden, in %s Projekten:\n' \
          "$(zahlwort "$ct" | sed 's/^./\U&/')" \
          "$([ "$ct" -eq 1 ] && printf 'Aufgabe ist' || printf 'Aufgaben sind')" \
          "$(jq -r '[.[].repo]|unique|length' "$TMP/closed.json")"
        if [ -n "$top" ]; then printf '%s\n' "$top"
        else printf '   Welche genau, konnte ich nicht auflisten.\n'; fi
      fi
    fi
    # Löschungen im CRM (buzz#79) gehören zum Tagesabschluss: sie sind das
    # Einzige aus dem Kundenbestand, das über Nacht unbemerkt verschwinden
    # kann. 0 ist hier kein Ruhezustand — siehe render_crm_deletions.
    render_crm_deletions
  } | falte > "$out"
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
    if [ -s "$GAPFILE" ]; then gaps_flat | sed 's/^/   • /'; else printf '   • keine — alle Quellen haben geliefert\n'; fi
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
    # --amounts: der Geld-Block soll sagen, WIE VIEL sich bewegt hat. Der Brief
    # geht in Munirs privaten Kanal; fuer oeffentliche Belege schwaerzt --redact.
    collect_lagebild "backlog,n8n,server,pay" "$([ "$REDACT" = "1" ] || printf -- '--amounts')"
    collect_nest
    collect_calendar
    collect_people
    collect_blocked
    BRIEF="$(render_morgenbrief)"
    CH="${BUZZ_CHANNEL:-$CH_GENERAL}"; LABEL="🌅 Morgenbrief"
    ;;
  gate-batch)
    collect_blocked
    # „Was heute gelaufen ist" ist der Abschluss des Tages, nicht der Woche.
    collect_closed "$(date '+%Y-%m-%d')"
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
