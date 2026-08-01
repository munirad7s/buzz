@echo off
REM .empire/tools/ritual-task.cmd — Startrampe fuer die Windows-Aufgabenplanung (buzz#10)
REM
REM   ritual-task.cmd morgenbrief
REM   ritual-task.cmd gate-batch
REM   ritual-task.cmd wochen-review     (buzz#63, So 18:00)
REM
REM Warum die Aufgabenplanung und nicht der Buzz-Workflow-Cron: der Relay-
REM Scheduler feuert die Ritual-Workflows nachweislich nicht (Messung in
REM .empire/AGENTS.md). Nebeneffekt: die Aufgabenplanung rechnet in Ortszeit,
REM damit ist der Winterzeit-Bruch der UTC-Crons erledigt.
REM
REM Die Aufgabe MUSS als eingeloggter Benutzer laufen: buzzx.ps1 liest den
REM Relay-Schluessel aus dem Windows Credential Manager, und dessen
REM Benutzer-Tresor ist ohne Benutzersitzung nicht entschluesselbar.
setlocal
if not "%~1"=="" goto :havemode
echo usage: ritual-task.cmd morgenbrief ^| gate-batch ^| wochen-review
exit /b 64
:havemode

set "GITBASH=C:\Program Files\Git\bin\bash.exe"
if not exist "%GITBASH%" set "GITBASH=%ProgramFiles%\Git\bin\bash.exe"
if not exist "%GITBASH%" (echo Git Bash nicht gefunden & exit /b 2)

REM Exit-Code-Weitergabe (Rot-Probe 2026-08-01): das abschliessende `echo` IN der
REM bash-Zeichenkette wurde zum Exit-Status der Shell — `bash -lc "false; echo x"`
REM liefert 0. Die Aufgabenplanung meldete deshalb fuer JEDEN Ausgang Ergebnis 0,
REM auch fuer Ergebnis 64 (kein Brief) und Ergebnis 3 (Transport gescheitert).
REM Gemessen: ritual.sh gab 64 zurueck, die .cmd 0. Ein Detektor, der nicht rot
REM werden kann, ist kein Detektor. Deshalb: rc merken, loggen, weiterreichen.
set "HERE=%~dp0"
"%GITBASH%" -lc "mkdir -p ~/.buzz; echo \"=== $(date -Is) ritual %~1 ===\" >> ~/.buzz/ritual.log; bash '%HERE:\=/%ritual.sh' %~1 --post --telegram --vault >> ~/.buzz/ritual.log 2>&1; rc=$?; echo \"exit=$rc\" >> ~/.buzz/ritual.log; exit $rc"
set "RC=%ERRORLEVEL%"

REM Herzschlag an Uptime Kuma (buzz#101) — MUSS nach dem Sichern von RC stehen,
REM sonst ueberschreibt der Push den zu meldenden Exit-Code. Der Push bekommt RC
REM uebergeben und bildet ihn ab; er ueberschreibt ihn nie: ein gescheitertes
REM Ritual bleibt rot, auch wenn der Push gelingt. Umgekehrt darf ein
REM gescheiterter Push nicht still bleiben — ein Monitor ohne Beat ist derselbe
REM blinde Fleck, den dieses Ticket schliesst.
"%GITBASH%" -lc "bash '%HERE:\=/%ritual-push.sh' %~1 %RC%"
set "PUSHRC=%ERRORLEVEL%"

REM ritual.sh: 0 = alle Quellen geliefert · 1 = Brief zugestellt, mit benannten
REM Luecken · 2 = kein Brief · 3 = Transport gescheitert · 64 = Usage.
REM 0 und 1 heissen beide "der Brief hat Munir erreicht" -> gruen. Alles ab 2
REM heisst "er hat ihn NICHT erreicht" -> muss rot sein. Wuerde auch 1 rot
REM melden, waere die Aufgabe an praktisch jedem Tag rot (Luecken sind der
REM Normalfall) und niemand schaute mehr hin.
REM Rangfolge: Ritual-Fehler schlaegt Herzschlag-Fehler. Ist das Ritual gruen,
REM aber der Herzschlag kaputt, meldet die Aufgabe 4 — sonst wuesste niemand,
REM dass der Waechter selbst blind ist.
if not "%RC%"=="0" if not "%RC%"=="1" exit /b %RC%
if not "%PUSHRC%"=="0" exit /b 4
exit /b 0
