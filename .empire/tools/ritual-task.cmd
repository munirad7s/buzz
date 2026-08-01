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

REM ritual.sh: 0 = alle Quellen geliefert · 1 = Brief zugestellt, mit benannten
REM Luecken · 2 = kein Brief · 3 = Transport gescheitert · 64 = Usage.
REM 0 und 1 heissen beide "der Brief hat Munir erreicht" -> gruen. Alles ab 2
REM heisst "er hat ihn NICHT erreicht" -> muss rot sein. Wuerde auch 1 rot
REM melden, waere die Aufgabe an praktisch jedem Tag rot (Luecken sind der
REM Normalfall) und niemand schaute mehr hin.
if "%RC%"=="0" exit /b 0
if "%RC%"=="1" exit /b 0
exit /b %RC%
