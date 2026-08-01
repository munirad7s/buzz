# .empire/BUILD.md — Buzz-Fork auf Windows bauen (bewiesene Schritte)

Reproduzierbarer Windows-Build des Forks `munirad7s/buzz`, gemessen am 2026-08-01 auf Munirs Maschine
(Windows 11 Pro 26200, 32 Kerne, Git Bash / MINGW64). Jede Angabe hier ist gemessen, nicht abgeleitet.

**Guardrail:** Der Eigen-Build läuft **neben** der installierten Buzz-App. `%LOCALAPPDATA%\Buzz\`,
`%APPDATA%\xyz.block.buzz.app\`, `~/.buzz/` und die produktiven Agenten-Keys werden nie überschrieben.
Der NSIS-Installer wird **gebaut, aber nicht installiert** — er ist der Beweis, nicht der Rollout.

---

## 1. Die zentrale Windows-Wahrheit: Hermit ist tot, das System-Toolchain trägt

Das Repo pinnt seine Toolchain über Hermit (`. ./bin/activate-hermit`, `bin/{just,node,pnpm,cargo,biome,flutter,cmake,…}`).
**Auf Windows funktioniert davon nichts.** Zwei unabhängige Gründe, beide gemessen:

1. **`bin/hermit` kennt Windows nicht.** Das Bootstrap-Script setzt `HERMIT_STATE_DIR` nur in einem
   `case "$(uname -s)"` mit den Zweigen `Darwin` und `Linux`. Git Bash meldet `MINGW64_NT-10.0-26200`
   → keiner der Zweige greift → die Variable bleibt leer und der Bootstrap stirbt unter `set -u`:
   ```
   Bootstrapping /pkg/hermit@stable/hermit from https://github.com/cashapp/hermit/releases/download/stable
   /tmp/tmp.XXXX: line 19: HERMIT_STATE_DIR_RAW: unbound variable
   ```
2. **`git config core.symlinks` = `false`.** Die `bin/*`-Einträge sind deshalb keine Symlinks, sondern
   16–18 Byte große Textdateien mit dem Zielnamen darin (`bin/just` enthält wörtlich `.just-1.46.0.pkg`),
   Modus `-rw-r--r--` — **ohne x-Bit**.

**Folge — und das ist die gute Nachricht:** Jedes Justfile-Rezept beginnt mit
`export PATH="{{justfile_directory()}}/bin:$PATH"`. Auf Windows ist dieses Prepend faktisch ein **No-Op**:
die Shim-Dateien sind nicht ausführbar, die PATH-Suche fällt durch auf das System-Toolchain. Gemessen mit
genau dieser PATH-Reihenfolge:

| Tool | löst auf nach | Version |
|---|---|---|
| `node` | `C:\Program Files\Volta\node` | v24.14.1 (Hermit pinnt 24.15.0) |
| `pnpm` | `C:\Program Files\Volta\pnpm` | 11.4.0 |
| `cargo`/`rustc` | `~/.cargo/bin` (rustup, via `rust-toolchain.toml`) | 1.95.0 |

`just` und `biome` funktionieren **nur**, weil ein System-Äquivalent existiert bzw. weil `pnpm check`
das lokal installierte biome aus `node_modules` benutzt. Tools **ohne** System-Äquivalent fehlen ersatzlos:
`lefthook` (⇒ `just hooks` läuft nicht), `flutter`/`dart` (⇒ `mobile-*` läuft nicht), `cmake` (siehe §2).

> **Regel:** Auf Windows nie `. ./bin/activate-hermit` versuchen. Toolchain system-seitig installieren,
> Versionen gegen `bin/*.pkg` bzw. `rust-toolchain.toml` gegenprüfen.

---

## 2. Einmalige Voraussetzungen (was auf dieser Maschine wirklich nötig war)

Vorhanden waren bereits: Git for Windows (Git Bash = `BUZZ_SHELL`-Laufzeitvoraussetzung, siehe README
„Windows prerequisites"), rustup + `rust-toolchain.toml`-Pin 1.95.0, Volta mit Node 24 / pnpm 11,
Docker Desktop 29.3.1, Visual-Studio-Buildtools (MSVC, Generator „Visual Studio 18 2026").

Nachinstalliert (gehört laut Ticket zum Auftrag, ist kein Blocker):

| Tool | Weg | Warum |
|---|---|---|
| `just` 1.57.0 | `winget install --id Casey.Just -e` | Taskrunner; Hermit-Shim inert |
| `cargo-nextest` 0.9.140 | ZIP von `https://get.nexte.st/latest/windows` → `~/.cargo/bin` | `just test-unit` nimmt sonst den langsamen `run-tests.sh`-Fallback |
| `cmake` 4.3.1 | ZIP von `github.com/Kitware/CMake/releases/.../cmake-4.3.1-windows-x86_64.zip` → `%LOCALAPPDATA%\cmake-portable`, Ordner `bin` an die User-`Path` gehängt | **Pflicht für den Desktop-Build** (§4) |

**Falle — `winget install --id Kitware.CMake` funktioniert hier nicht.** Der Lauf hängt >10 min und
endet mit Exit 6, ohne `C:\Program Files\CMake` anzulegen. Das portable ZIP ist der verlässliche Weg.
`cargo-nextest` bewusst als Prebuilt statt `cargo install` — der Quellbau kollidiert sonst mit einem
laufenden Workspace-Build um den Registry-Lock.

---

## 3. Build-Reihenfolge (genau so, in Git Bash, aus dem Repo-Root)

```bash
cd /c/Users/rescue/projects/buzz

# 1) JS-Workspace (pnpm-Workspace liegt im Repo-Root, NICHT in desktop/)
pnpm install

# 2) Rust-Workspace (Debug) — deckt sich mit `just build`
just build

# 3) Die 5 Sidecars in Release
cargo build --release -p buzz-acp -p buzz-agent -p buzz-dev-mcp -p git-credential-nostr -p buzz-cli

# 4) Sidecars in den Tauri-Bundle-Ordner legen — OHNE Argument!
./scripts/bundle-sidecars.sh

# 5) NSIS-Installer (kein mesh-llm, siehe Nicht-Ziele)
cd desktop
CMAKE_POLICY_VERSION_MINIMUM=3.5 pnpm tauri build --target x86_64-pc-windows-msvc --bundles nsis
```

### Warum `bundle-sidecars.sh` **ohne** Argument

Das Script entscheidet am `$1`, wo es die Binaries sucht:

```bash
if [[ -n "${1:-}" ]]; then SRC_DIR="target/${TARGET}/release"; else SRC_DIR="target/release"; fi
```

Der CI-Windows-Job (`.github/workflows/release.yml`) baut die Sidecars **mit** `--target "$TARGET"`
und ruft das Script deshalb **mit** dem Triple auf. Schritt 3 oben baut ohne `--target` → die Binaries
liegen in `target/release/` → das Script muss **ohne** Argument laufen. `TARGET` fällt dann auf den
Host-Triple aus `rustc -vV` zurück, die Zieldateien heißen trotzdem korrekt
`binaries/<name>-x86_64-pc-windows-msvc.exe`, wie Tauris `externalBin` es erwartet.

Ergebnis von Schritt 4 (gemessen):

```
desktop/src-tauri/binaries/buzz-acp-x86_64-pc-windows-msvc.exe            12.2M
desktop/src-tauri/binaries/buzz-agent-x86_64-pc-windows-msvc.exe           9.2M
desktop/src-tauri/binaries/buzz-dev-mcp-x86_64-pc-windows-msvc.exe        18.9M
desktop/src-tauri/binaries/buzz-x86_64-pc-windows-msvc.exe                13.5M   ← Paket buzz-cli, Binary heißt buzz
desktop/src-tauri/binaries/git-credential-nostr-x86_64-pc-windows-msvc.exe 2.0M
```

---

## 4. Die Stolpersteine, die diesen Build zweimal gekostet haben

### 4.1 `cmake` fehlt → Desktop-Build stirbt im Opus-Codec

Ohne cmake bricht `pnpm tauri build` im Build-Script von `audiopus_sys` (Opus, Voice) ab:

```
running: "cmake" "…\audiopus_sys-0.2.2\opus" "-B" … "-G" "Visual Studio 18 2026" …
thread 'main' panicked at cmake-0.1.58\src\lib.rs:1132:5:
failed to execute command: program not found
is `cmake` not installed?
build script failed, must exit now
```

Das ist der einzige Grund, warum cmake auf der Liste steht — Hermit würde es liefern, kann es hier aber nicht.
`CMAKE_POLICY_VERSION_MINIMUM=3.5` wird gesetzt, weil der CI-Windows-Job es setzt (cmake 4 lehnt sonst
die alten `cmake_minimum_required`-Angaben in C-Abhängigkeiten ab).

### 4.2 Pipe-Maskierung: ein roter Build sieht grün aus

`cargo build … 2>&1 | tail -40` liefert den Exit-Code von **`tail`**, nicht vom Build. Der erste
fehlgeschlagene NSIS-Lauf oben wurde exakt so als „exit code 0" gemeldet. Für jeden Build-Beweis gilt:
in eine Datei umleiten und `$?` direkt lesen, oder `${PIPESTATUS[0]}` auswerten.

### 4.3 `_ensure-sidecar-stubs` erzeugt endungslose Dateien

Das Rezept legt `desktop/src-tauri/binaries/${bin}-${TARGET}` **ohne `.exe`** an. Auf Windows sind das
tote 0-Byte-Dateien neben den echten `.exe`-Sidecars — sie überschreiben nichts (anderer Dateiname) und
Tauri ignoriert sie, aber wer nach dem Bundle-Schritt in den Ordner schaut, darf sich davon nicht
verwirren lassen. `just desktop-standalone` kopiert aus demselben Grund Debug-Binaries auf die
endungslosen Namen — auf Windows greift dort der Sidecar-Pfad nicht.

### 4.4 `just dev` / `just desktop-standalone` laufen auf Windows nicht

Zwei unabhängige Gründe, beide gemessen:

1. **`beforeDevCommand` benutzt das POSIX-Builtin `exec`.** `scripts/instance-env.sh` baut
   `"beforeDevCommand":"exec ./node_modules/.bin/vite --port <p> --strictPort"`. Tauri startet das durch
   die Plattform-Shell — auf Windows `cmd.exe /C`, das kein `exec` kennt:
   ```
   Der Befehl "exec" ist entweder falsch geschrieben oder konnte nicht gefunden werden.
   Error The "beforeDevCommand" terminated with a non-zero status code.
   ```
2. **`desktop-standalone` kopiert endungslos.** Das Rezept macht
   `cp "${TARGET_DIR}/debug/${bin}" "desktop/src-tauri/binaries/${bin}-${TARGET}"`. Auf Windows heißt die
   Quelle `${bin}.exe` — der `cp` findet nichts und das Rezept stirbt an `set -euo pipefail`.

**Windows-Workaround** (isolierte Instanz, ohne die installierte App anzufassen): Vite selbst starten
und `beforeDevCommand` leeren. Der Identifier bleibt `xyz.block.buzz.app.dev` → eigenes App-Data-Verzeichnis
und eigener Single-Instance-Schlüssel, die installierte `xyz.block.buzz.app` bleibt unberührt.

```bash
cd desktop
VITE_RELAY_URL="wss://<community>" ./node_modules/.bin/vite --port 48275 --strictPort &
pnpm exec tauri dev --config '{"build":{"devUrl":"http://localhost:48275","beforeDevCommand":""},
  "identifier":"xyz.block.buzz.app.dev","productName":"Buzz Dev"}'
```

Die `.exe`-Sidecars aus `bundle-sidecars.sh` (§3) reichen dabei aus — die endungslosen Stub-Namen
braucht Windows nicht.

### 4.5 cmake muss in **derselben** Shell auf dem PATH liegen

Die User-`Path`-Erweiterung greift erst in **neuen** Prozessen. Eine bereits offene Shell (und jedes
Tool, das aus ihr startet) sieht sie nicht — der Build stirbt dann erneut in `audiopus_sys` (§4.1),
obwohl cmake „installiert" ist. In laufenden Sessions deshalb explizit:

```bash
export PATH="$LOCALAPPDATA/cmake-portable/cmake-4.3.1-windows-x86_64/bin:$PATH"
```

Das gilt für **jeden** Lauf, der den Desktop-Tauri-Crate anfasst: `pnpm tauri build`, `tauri dev`,
`just desktop-tauri-clippy`, `just desktop-tauri-check`.

### 4.6 `buzz.exe` ist nicht im Bash-PATH

Der CLI-Sidecar heißt `buzz` (Paket `buzz-cli`) und liegt nach dem Build in `target/release/buzz.exe`.
Immer mit vollem Pfad aufrufen; PowerShell 5.1 zerlegt zusätzlich die Argumente — CLI-Kommandos gehören
in Git Bash.

---

## 5. Verifikation (gemessene Ergebnisse, 2026-08-01)

`just check` besteht aus `fmt-check clippy desktop-check desktop-tauri-fmt-check desktop-tauri-clippy web-check mobile-check`.
Einzeln gemessen, weil zwei Teile auf Windows systembedingt nicht grün werden können:

| Teil-Check | Kommando | Ergebnis |
|---|---|---|
| `fmt-check` | `cargo fmt --all -- --check` | ✅ exit 0 |
| `clippy` | `cargo clippy --workspace --all-targets -- -D warnings` | ✅ exit 0, 0 Warnungen |
| `desktop-check` | `cd desktop && pnpm check` | ✅ exit 0 (1752 Dateien, nur `info`-Hinweise) |
| `web-check` | `cd web && pnpm check` | ✅ exit 0 (62 Dateien) |
| `desktop-tauri-fmt-check` | `cargo fmt --manifest-path desktop/src-tauri/Cargo.toml --all -- --check` | ✅ exit 0 |
| `desktop-tauri-clippy` | `cargo clippy --manifest-path desktop/src-tauri/Cargo.toml --all-targets -- -D warnings` | ⚠️ siehe §5.1 |
| `mobile-check` | `dart format … && flutter analyze` | ❌ nicht lauffähig — weder `flutter` noch `dart` auf der Maschine; Hermits `flutter`-Pin ist inert (§1) |

`just test-unit` (cargo-nextest, keine Infrastruktur nötig) — **Basis-Stand des Forks auf Windows:**

```
282 tests run: 282 passed, 0 skipped     (buzz-core + buzz-auth --lib)
  9 tests run:   9 passed, 5 skipped     (buzz-voice --lib)
271 tests run: 271 passed, 0 skipped     (buzz-cli)
 94 tests run:  94 passed, 152 skipped   (buzz-db --lib)
 22 tests run:  22 passed, 0 skipped     (buzz-conformance)
 15 tests run:  15 passed, 6 skipped     (buzz-push-gateway)
────────────────────────────────────────
693 passed · 0 failed · 163 skipped      → exit 0
```

### 5.1 `desktop-tauri-clippy` auf Windows

Der Desktop-Tauri-Crate hält Unix-only-Helfer (`create_symlink`, `symlink_points_to`, `backup_path` in
`src/util.rs`, `known_skill_dirs` in `managed_agents/nest.rs`, `ProbeOutcome` in
`managed_agents/readiness/cli_probe.rs`, …). Auf MSVC sind sie nicht erreichbar und lösen
`dead_code`/`unused_imports` aus — der Release-Build meldet 27 solcher Warnungen.

Gemessen: `cargo clippy --manifest-path desktop/src-tauri/Cargo.toml --all-targets -- -D warnings`
→ **exit 101, 45 Fehler**. Alle 45 gehören ausnahmslos zur Klasse „`… is never used`" bzw.
„unused import" — **kein einziger Logikfehler.** `-D warnings` stuft sie nur hoch.

Das ist damit **Upstream-Verhalten, kein Fork-Schaden**, und der Fork ändert daran nichts
(Doktrin „upstream-freundlich": keine kosmetischen `#[cfg]`-Eingriffe in Upstream-Dateien).
Upstream gibt es für Windows ohnehin nur die manuelle `windows-canary.yml`, die den Lint-Job nicht fährt —
darum fällt es dort nicht auf.

**Konsequenz für den Fork:** `just check` als Ganzes ist auf Windows kein sinnvolles Gate. Das
Windows-Gate ist:

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo fmt --manifest-path desktop/src-tauri/Cargo.toml --all -- --check
(cd desktop && pnpm check)
(cd web && pnpm check)
just test-unit
```

### 5.2 Docker / `just setup` — blockiert durch ein fremdes Live-System

`just setup` = `bootstrap` + `scripts/dev-setup.sh` und will `docker compose up` fahren. Das
`docker-compose.yml` mappt Host-Port **5432 hart** (`"5432:5432"`, nicht parametrisiert). Auf dieser
Maschine hält den Port bereits `boooking-engene-postgres-1` — die Booking-Engine, ein geschütztes
geteiltes Live-System. **Der Buzz-Dev-Stack wurde deshalb bewusst nicht gestartet**; ihn hochzuziehen
hätte entweder den Port-Bind verfehlt oder fremde Container angefasst.

Für den Fork-Build ist das folgenlos: der Desktop-Build, die Sidecars, `just build`, `just check` und
`just test-unit` brauchen **keine** Infrastruktur. Wer den lokalen Relay doch braucht, legt eine
lokale, nicht eingecheckte `docker-compose.override.yml` mit freien Host-Ports an und zieht
`DATABASE_URL`/`PGPORT` in `.env` nach — Compose merged die Override-Datei automatisch, der
Upstream-Compose bleibt unberührt.

---

## 6. Laufzeiten (gemessen, 32 Kerne, warmer Registry-Cache)

| Schritt | Dauer |
|---|---|
| `pnpm install` (Repo-Root, Workspace) | < 1 min |
| `cargo build --release` (5 Sidecars, kalt) | ~ 12 min |
| `just build` (Workspace Debug, warm nach `test-unit`) | 4 min 31 s |
| `just test-unit` (Kompilat 1 min 48 s + 693 Tests in 20 s) | ~ 5 min |
| `cargo clippy --workspace --all-targets` | ~ 8 min kalt |
| `pnpm tauri build … --bundles nsis` | **15 min 30 s** (davon 11 min 34 s Release-Kompilat des Desktop-Crates) |

Ein kompletter Kaltstart liegt damit bei **~45 min**. Inkrementell (nur Desktop-Crate geändert) sind es
wenige Minuten.

Artefakte des NSIS-Laufs (gemessen 2026-08-01 14:24):

```
desktop/src-tauri/target/x86_64-pc-windows-msvc/release/buzz-desktop.exe               88.017.408 B
desktop/src-tauri/target/x86_64-pc-windows-msvc/release/bundle/nsis/Buzz_0.5.3_x64-setup.exe
                                                                                       52.293.976 B
```

`makensis` und `nsis_tauri_utils.dll` lädt Tauri beim ersten Bundle-Lauf selbst nach
(`tauri-apps/binary-releases`, NSIS 3.11) — dafür ist beim ersten Build Netz nötig.

---

## 7. Upstream-Sync-Ritual (1× pro Arbeits-Session, verpflichtend)

`block/buzz` bewegt sich schnell — das CHANGELOG ist 219 KB, `origin` trägt >570 Remote-Branches.
Zeilennummern und Pfade aus Tickets sind deshalb **immer** gegen den aktuellen Stand zu verorten.

```bash
cd /c/Users/rescue/projects/buzz
git fetch upstream
git merge upstream/main          # bei 0 Commits: "Already up to date." — trotzdem fahren und protokollieren
git rev-list --left-right --count upstream/main...HEAD   # links = behind, rechts = ahead
```

**Konfliktregel:**

- Eigene Dateien liegen ausschließlich in `.empire/` und in **neuen** Modulen → kollidieren strukturell nicht.
- Änderungen an Upstream-Dateien bleiben **klein, additiv, feature-geflaggt** und upstream-PR-fähig.
- Bei einem Konflikt in einer Upstream-Datei gewinnt im Zweifel **upstream**; der eigene Anteil wird
  danach als kleiner additiver Patch neu aufgesetzt statt in den Merge hineinverhandelt.
- `.empire/AGENTS.md` und `.empire/PROGRESS.md` sind **geteilte** Dokumente mehrerer Agenten:
  nur die **eigene Sektion/Zeile anhängen**, nie fremde Abschnitte umschreiben. Vor jedem PR
  `git pull --rebase origin main`.

**Push-Weg (der `git-push-main`-Hook blockt direkte Pushes auf `main`):**

```bash
git checkout -b feat/<nr>-<slug>
git add <nur die eigenen Dateien>            # geteilter Working Tree — nie `git add -A`
git commit -m "<warum> (#<nr>)"
git push -u origin feat/<nr>-<slug>
gh pr create --repo munirad7s/buzz --base main --head feat/<nr>-<slug> --fill
gh pr merge <nr> -R munirad7s/buzz --squash --delete-branch
```

> **Falle:** `gh pr create --fill` **ohne** `--repo/--base/--head` zielt bei einem Fork auf
> **upstream `block/buzz`**. Immer explizit adressieren.
>
> **Falle:** Mehrere Empire-Agenten teilen sich diesen einen Working Tree. Vor dem Commit `git status`
> lesen und nur die eigenen Pfade stagen — fremde, noch uncommittete Arbeit nie mitcommitten.

---

## 8. Den Eigen-Build gegen eine Community beweisen (ohne die Produktiv-App anzufassen)

Die installierte App läuft dauerhaft (`buzz-desktop.exe`, Community `adaswin.communities.buzz.xyz`,
5 produktive Agenten). Der gebaute Release-`buzz-desktop.exe` trägt denselben Identifier
`xyz.block.buzz.app` — ihn zu starten hieße, sich in dieselbe App-Data und denselben
Single-Instance-Schlüssel zu setzen. **Wird nicht gemacht.** Zwei saubere Beweiswege stattdessen:

**a) CLI-Sidecar gegen den echten Relay** — voller TLS- + NIP-OA-Roundtrip mit einem frischen
Wegwerf-Keypair (`openssl rand -hex 32`, nie gespeichert, nie ein Agenten-Key):

```bash
./target/release/buzz.exe --relay https://<community> --private-key "$TESTKEY" channels list
# → {"error":"auth_error","message":"relay error 403: relay_membership_required"}   exit 3
```

Exit 3 heißt: der Relay wurde erreicht, hat die Identität geprüft und eine **Policy**-Entscheidung
getroffen. Gegenprobe, damit der Detektor rot werden kann — dasselbe Binary auf einen toten Host:

```bash
./target/release/buzz.exe --relay https://relay-does-not-exist.adas.invalid … channels list
# → {"error":"network_error","message":"… dns error …","retryable":true}            exit 2
```

Zwei verschiedene Fehlerklassen und Exit-Codes ⇒ der Auth-Pfad ist echt durchlaufen, nicht simuliert.
Ergänzend liefert `curl -H 'Accept: application/nostr+json' https://<community>/` das NIP-11-Dokument
(`"name":"Buzz Relay"`, `supported_nips:[1,2,10,11,16,17,23,25,29,33,38,42,50,56,43]`).

**b) Desktop-GUI in einer isolierten Instanz** — Identifier `xyz.block.buzz.app.dev`, eigene App-Data,
eigener Keyring-Service, eigener Single-Instance-Schlüssel (Rezept in §4.4). Läuft parallel zur
installierten App, ohne sie zu berühren.

## 9. Nicht-Ziele

- **Kein `--features mesh-llm`.** Die offiziellen Windows-Builds haben es nicht (Stubs: „mesh-llm feature
  not enabled"); auf Windows ist das Upstream-Arbeit, kein Flag-Flip. Eigenes Ticket.
- **Kein Installieren des gebauten NSIS.** Der Installer würde `%LOCALAPPDATA%\Buzz` überschreiben.
  Er wird gebaut und als Artefakt nachgewiesen, mehr nicht.
- **Keine Release-Tags auf dem Fork.** Nichts an diesem Fork wird veröffentlicht.
- ~~Keine Actions-Läufe auf dem Fork~~ — überholt durch buzz#48: der lokale Build bleibt der Beweis
  für *diese Maschine*, das CI-Gate ist der Beweis für *den Code*. Welche Workflows dabei laufen
  dürfen, steht in §10.

## 10. CI auf dem Fork — welche Workflows laufen dürfen

Seit buzz#48 hängt ein echtes Gate an den Fork-Actions. Ein Gate ist aber nur so viel wert wie die
Stille drumherum: zwischen dauerhaft roten Läufen fällt ein rotes Gate niemandem auf.

**Gemessen am 2026-08-01 vor dem Aufräumen (buzz#113):** *ein* Push auf `main` startete fünf
Workflows — `CI`, `Sprig`, `Docker image`, `helm chart`, `Auto-tag on Release PR Merge`; jeder PR
zusätzlich `Desktop Release Candidate`. `Sprig` war dabei **reproduzierbar rot** (Job „Publish
rolling release" → `release not found`): es gibt kein Rolling-Release auf dem Fork, das der Workflow
aktualisieren könnte. In einer Agenten-Welle mit mehreren Merges pro Stunde war der Actions-Tab damit
reines Rauschen.

### 10.1 Aktiv — nur diese zwei

| Workflow | Trigger auf dem Fork | Warum er bleibt |
|---|---|---|
| `CI` (`ci.yml`) | Push `main`, jeder PR | Die eigentliche Testsuite: Rust Lint, Unit Tests, Desktop E2E, Server-Cross-Compile, `cargo-deny`. Das ist Signal, kein Lärm — der Job `Security` hat am 01.08. RUSTSEC-2026-0224 auf `main` gemeldet, bevor es jemand bemerkt hätte. |
| `Empire Windows Canary` (`empire-windows-canary.yml`) | Push `main` (mit `paths-ignore` für `.empire/**`, `**/*.md`, `docs/**`), Dispatch | Das Gate aus buzz#48: baut der Fork-Code auf Windows? Fork-eigene Datei, weil der Upstream-Canary auf jedem Fork inert ist. |

### 10.2 Stillgelegt per `gh workflow disable` (Stand 2026-08-01)

`disable` statt Datei-Guard, bewusst: der Zustand liegt bei GitHub, nicht im Baum — er überlebt
damit jeden `git merge upstream/main`, ohne eine einzige Upstream-Zeile anzufassen. Ein additiver
`if: github.repository == 'block/buzz'` wäre upstream-PR-fähig, würde aber zwölf Upstream-Dateien
dauerhaft zu Konfliktkandidaten machen — der Fork lebt vom Merge. Rückgängig mit
`rtk gh workflow enable "<Name>" -R munirad7s/buzz`.

| Workflow | Grund |
|---|---|
| `Sprig` | Strukturell rot: aktualisiert ein Rolling-Release, das es nur upstream gibt. Nicht reparierbar. |
| `Docker image` | Baut und pusht Relay-Images nach `ghcr.io/block/buzz` — dorthin darf der Fork nicht schreiben. |
| `helm chart` | Lintet und publiziert Upstream-Charts, die der Fork nie anfasst. |
| `Auto-tag on Release PR Merge` | Feuerte bei **jedem** PR-Close und taggt nach Upstreams Release-Schema. Der Fork taggt nie. |
| `Desktop Release Candidate` | Feuerte bei **jedem** PR, validiert aber nur `version-bump/*`-Branches aus Upstreams Release-Prozess. |
| `Release` | Desktop-Release-Publish auf `desktop-v*`-Tags. Der Fork taggt nie. |
| `Publish Mobile Release Candidate` | Upstream-Store-Prozess, braucht Upstream-Secrets. |
| `push gateway helm chart` | Publish nach `oci://ghcr.io/block/buzz/charts`. |
| `Linux Canary` · `Signed macOS Canary` · `Windows Canary` | **Die gefährlichsten:** dispatch-only mit `if: github.repository == 'block/buzz'`. Auf dem Fork überspringen sie jeden Job und melden trotzdem **grün** — ein Dispatch beweist nichts und sieht aus wie ein Beweis. Genau die Falle, die buzz#48 aufgedeckt hat. `Signed macOS Canary` bräuchte zusätzlich Upstreams Signing-OIDC. |
| `Harbor Buzz Orchestra` | Benchmark unter `benchmarks/harbor-buzz-orchestra/**` — Pfad wird hier nie berührt. |

**Nachgemessen (gleicher Vorgang, nach dem Aufräumen):** PR → nur `CI`. Push auf `main` mit
Code-Anteil → `CI` + `Empire Windows Canary`. Doku-only-Push → nur `CI`.

**Regel für neue Workflows:** Auf diesem Fork läuft nur, was eine Aussage über *Fork-Code* macht.
Alles, was Artefakte veröffentlicht, Upstream-Secrets braucht oder ohne Guard grün meldet, wird
stillgelegt und hier mit Begründung eingetragen.
