# start-agent.ps1 — startet einen Buzz-Agenten (buzz-acp-Harness) auf Windows losgelöst
# von der aufrufenden Shell. Vorlage zu .empire/ONBOARDING.md §4.6.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File start-agent.ps1 `
#       -Conf "$env:USERPROFILE\.secrets\buzz-agent-<rolle>.env" `
#       -Bin  "C:\Users\<user>\projects\buzz\target\release" `
#       -Root "C:\Users\<user>\buzz-agents"
#
# Der Agent läuft NEBEN einer installierten Buzz-App: eigener Prozess, eigene Identität,
# eigenes Arbeitsverzeichnis. %APPDATA%\xyz.block.buzz.app\ wird nicht angefasst.
#
# Die Konfigurationsdatei enthält Secret-Key und LLM-Zugang → gehört unter ~/.secrets,
# nie ins Repo. Format: KEY=VALUE je Zeile (siehe ONBOARDING.md §4.6).

param(
  [Parameter(Mandatory = $true)] [string] $Conf,
  [Parameter(Mandatory = $true)] [string] $Bin,
  [string] $Root = "$env:USERPROFILE\buzz-agents",
  [string] $Name = "agent"
)

$logs = Join-Path $Root "logs"
$work = Join-Path $Root "work"
New-Item -ItemType Directory -Force -Path $logs, $work | Out-Null

if (-not (Test-Path $Conf)) { throw "Konfigurationsdatei nicht gefunden: $Conf" }
if (-not (Test-Path (Join-Path $Bin "buzz-acp.exe"))) { throw "buzz-acp.exe nicht in $Bin" }

Get-Content $Conf | ForEach-Object {
  if ($_ -match '^([A-Z_0-9]+)=(.*)$') {
    [System.Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
  }
}

# Ohne die Binaries im PATH findet der Agent die buzz-CLI nicht und antwortet ins Leere.
$env:PATH = "$Bin;$env:PATH"

$p = Start-Process -FilePath (Join-Path $Bin "buzz-acp.exe") `
  -WorkingDirectory $work `
  -RedirectStandardOutput (Join-Path $logs "$Name.out.log") `
  -RedirectStandardError  (Join-Path $logs "$Name.err.log") `
  -WindowStyle Hidden -PassThru

$p.Id | Out-File -Encoding ascii (Join-Path $logs "$Name.pid")
Write-Output "$Name pid=$($p.Id)  logs=$logs"
