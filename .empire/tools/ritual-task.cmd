@echo off
REM .empire/tools/ritual-task.cmd — Startrampe fuer die Windows-Aufgabenplanung (buzz#10)
REM
REM   ritual-task.cmd morgenbrief
REM   ritual-task.cmd gate-batch
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
echo usage: ritual-task.cmd morgenbrief ^| gate-batch
exit /b 64
:havemode

set "GITBASH=C:\Program Files\Git\bin\bash.exe"
if not exist "%GITBASH%" set "GITBASH=%ProgramFiles%\Git\bin\bash.exe"
if not exist "%GITBASH%" (echo Git Bash nicht gefunden & exit /b 2)

set "HERE=%~dp0"
"%GITBASH%" -lc "mkdir -p ~/.buzz; echo \"=== $(date -Is) ritual %~1 ===\" >> ~/.buzz/ritual.log; bash '%HERE:\=/%ritual.sh' %~1 --post --telegram --vault >> ~/.buzz/ritual.log 2>&1; echo \"exit=$?\" >> ~/.buzz/ritual.log"
exit /b %ERRORLEVEL%
