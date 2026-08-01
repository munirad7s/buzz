# RELAY-MIGRATION.md — Umzug auf den eigenen Buzz-Relay

Stand: 2026-08-01 · gehört zu buzz#2 · Folge-Arbeit, nicht Teil von #2.

Der eigene Relay läuft auf adas-hetzner unter `https://buzz.adas.casa`. Die
gehostete Community `adaswin.communities.buzz.xyz` (Block-gehostet) läuft
**unverändert weiter** — dieses Dokument beschreibt, wie der Umzug später
vollzogen wird, wenn der Eigenbetrieb sich bewährt hat.

## Warum überhaupt umziehen

Datenhoheit. Durch die Führungszentrale fließen künftig E-Mail-Inhalte (#4/#5),
CRM-Daten (#6) und Gate-Entscheidungen (#9/#10). Auf einem Managed-Dienst wäre
das fremder Boden. Der Workflow-Scheduler (Morgenbrief, Gate-Batch) läuft im
Relay — 24/7-Führungsrituale gehören auf eigene Infrastruktur.

## Ist-Stand nach buzz#2

| Ding | Wert |
|---|---|
| Relay-URL | `wss://buzz.adas.casa` / `https://buzz.adas.casa` |
| Community-ID | siehe `~/.secrets/buzz-relay.env` (`BUZZ_COMMUNITY_ID`) |
| Modus | geschlossen: `BUZZ_REQUIRE_AUTH_TOKEN=true`, `BUZZ_REQUIRE_RELAY_MEMBERSHIP=true` |
| Owner-Identität | Nostr-Keypair, Secret in `~/.secrets/buzz-relay.env` |
| Stack | `/opt/buzz/compose.yml` (Repo-Kopie: `.empire/deploy/hetzner/compose.yml`) |
| Secrets | `/opt/buzz/.env` (chmod 600) + Spiegel `~/.secrets/buzz-relay.env` |
| Backup | `backup.sh` Block 5e → restic (lokal grün; Offsite-R2 ist unabhängig davon rot) |
| Monitoring | Uptime-Kuma-Monitor `buzz-relay` (keyword `ok` auf `/health`) |
| Test-Kanal | `empire-ops` |

## Migrationsschritte (wenn es soweit ist)

### 1. Vorbedingung: Eigenbetrieb bewährt
Mindestens 7 Tage stabil (Kuma grün, kein Container-Restart-Loop, Backup-Block
läuft täglich mit). Erst dann anfangen.

### 2. Identitäten inventarisieren
Jeder Agent und Munir selbst haben ein Nostr-Keypair. Die Keys sind **portabel** —
dieselbe Identität kann sich an beiden Relays anmelden. Es muss also nichts
"umgezogen" werden, nur zugelassen:

```bash
# Für jeden Pubkey, der auf den eigenen Relay soll:
ssh hetzner "docker exec buzz-relay buzz-admin add-member <pubkey-hex>"
ssh hetzner "docker exec buzz-relay buzz-admin list-members"
```

Ohne `add-member` weist der geschlossene Relay die Verbindung ab — das ist die
Absicht, nicht ein Fehler.

### 3. Kanäle neu anlegen statt kopieren
Kanäle sind billig, Historie ist es nicht wert, quer über Relays gezerrt zu
werden. Empfehlung: die produktiven Kanäle im eigenen Relay **neu** anlegen
(kind:9007), die alte Community als Archiv lesbar lassen. Wer echte Historie
braucht: die Events der alten Community per `/query` exportieren und als
signierte Events erneut einreichen — Aufwand lohnt nur für einzelne Kanäle.

### 4. Workflows portieren
Workflow-Definitionen sind kind:30620-Events mit YAML-Content. Export aus der
alten Community, `h`-Tag auf die neue Kanal-UUID setzen, neu signieren, an den
eigenen Relay senden. **Vor dem Scharfschalten `enabled: false` setzen**, sonst
laufen dieselben Rituale doppelt (alt + neu) und Munir bekommt alles zweimal.

Crons laufen in **UTC** — das `timezone`-Feld wird still ignoriert
(08:45 CEST = `45 6 * * *`, im Winter `45 7 * * *`).

### 5. Clients umstellen
Desktop-App: Relay-URL auf `wss://buzz.adas.casa` zeigen lassen, mit der
bestehenden Identität anmelden. Erst umstellen, wenn Schritt 2–4 stehen.

### 6. Cutover und Rückfahrkarte
- Alte Community NICHT löschen. Sie ist die Rückfahrkarte, solange der
  Eigenbetrieb jung ist.
- Umschalten heißt: Agenten-Keys zeigen auf den neuen Relay, alte Workflows
  dort auf `enabled: false`.
- Rollback = Clients zurückzeigen, alte Workflows wieder `enabled: true`.
- Erst wenn 30 Tage nichts passiert ist, die alte Community abbauen.

## Fallen, die schon Blut gekostet haben

- `workflows delete` wird angenommen, **löscht aber nicht** → mit
  `enabled: false` neutralisieren, editieren statt duplizieren.
- Der Relay ist geschlossen. Ein neuer Pubkey ohne `add-member` bekommt keine
  aussagekräftige Fehlermeldung, sondern fliegt bei AUTH raus.
- Traefik: der Stack braucht `traefik.docker.network=coolify`, sonst wählt
  Traefik bei mehrfach vernetzten Containern die Backend-IP zufällig
  (504-Roulette).
- Compose zwingt Service-Namen als Netzwerk-Aliase auf. Deshalb ist alles
  `buzz-*` präfixiert — ein generisches `postgres` am `coolify`-Netz würde mit
  Fremd-Stacks kollidieren.
- `pg_isready` lügt während der Postgres-Entrypoint-Init. Vor DB-Arbeit auf
  „init process complete" **im Log** warten, nicht auf den Healthcheck.
- Die Relay-Identität (`BUZZ_RELAY_PRIVATE_KEY`) ist Teil des Vertrauensankers.
  Geht sie verloren, müssen alle Clients neu vertrauen → sie liegt im Backup
  (Block 5e) und in `~/.secrets/buzz-relay.env`.

## Offene Folge-Arbeit

- Community-Vollumzug (Agenten-Keys, Kanäle, Workflows) — dieses Dokument.
- `buzz-relay-mesh`-Replikation als Offsite-Zweitrelay.
- `admin-web/` hinter Auth verfügbar machen.
- Offsite-Backup (restic → R2) ist **unabhängig von buzz#2 rot**
  (TLS-Handshake-Fehler gegen R2) — betrifft alle Stacks, eigenes Ticket.
