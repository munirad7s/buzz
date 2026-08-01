# .empire/tools/buzzx.ps1 — Key-Beschaffer fuer die Buzz-CLI (buzz#10)
#
# Der Buzz-Desktop legt seine Nostr-Schluessel im Windows Credential Manager ab
# (Target `secrets.buzz-desktop`, ein JSON mit den Keys `identity` und
# `agent:<pubkey-hex>`). Headless-Agenten kommen sonst nicht an den Relay.
#
# Dieses Script liest den gewuenschten Schluessel, setzt ihn NUR als
# Prozess-Env fuer buzz.exe und gibt ihn niemals aus. Nichts landet auf der
# Platte, nichts in der Shell-History, nichts in argv.
#
# Aufruf (Argumente zeilenweise in einer UTF-8-Datei, damit PowerShell 5.1
# keine Multibyte-/Quoting-Verstuemmelung anrichtet):
#   powershell -File buzzx.ps1 -Key identity -ArgFile C:\path\args.txt
#
# -Key: "identity" (Munirs Owner-Key) oder "agent:<pubkey-hex>"
param(
  [string]$Key = "identity",
  [Parameter(Mandatory=$true)][string]$ArgFile,
  [string]$Relay = "https://adaswin.communities.buzz.xyz"
)

$ErrorActionPreference = "Stop"

$sig = @"
using System;
using System.Runtime.InteropServices;
public class BuzzCred {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct CREDENTIAL {
    public uint Flags; public uint Type; public IntPtr TargetName; public IntPtr Comment;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
    public uint CredentialBlobSize; public IntPtr CredentialBlob; public uint Persist;
    public uint AttributeCount; public IntPtr Attributes; public IntPtr TargetAlias; public IntPtr UserName;
  }
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);
  [DllImport("advapi32.dll")] public static extern void CredFree(IntPtr cred);
  public static string Read(string target) {
    IntPtr p;
    if (!CredRead(target, 1, 0, out p)) return null;
    CREDENTIAL c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
    byte[] b = new byte[c.CredentialBlobSize];
    Marshal.Copy(c.CredentialBlob, b, 0, (int)c.CredentialBlobSize);
    CredFree(p);
    return System.Text.Encoding.Unicode.GetString(b);
  }
}
"@
if (-not ("BuzzCred" -as [type])) { Add-Type -TypeDefinition $sig -Language CSharp }

$blob = [BuzzCred]::Read("secrets.buzz-desktop")
if ($null -eq $blob) { Write-Error "Credential 'secrets.buzz-desktop' nicht lesbar"; exit 3 }
$keys = $blob | ConvertFrom-Json
$sk = $keys.$Key
if ([string]::IsNullOrEmpty($sk)) { Write-Error "Kein Schluessel '$Key' im Credential"; exit 3 }

$cliArgs = @(
  Get-Content -LiteralPath $ArgFile -Encoding UTF8 |
    Where-Object { $_ -ne $null -and $_.Trim() -ne "" } |
    ForEach-Object { [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_.Trim())) }
)

# Agenten-Keys brauchen zusaetzlich die NIP-OA-Owner-Attestierung, sonst
# antwortet der Relay mit 403 relay_membership_required. Sie liegt im
# Desktop-Agent-Record, nicht im Credential-Store.
$env:BUZZ_AUTH_TAG = $null
if ($Key -like "agent:*") {
  $pk = $Key.Substring(6)
  $mfile = Join-Path $env:APPDATA "xyz.block.buzz.app\agents\managed-agents.json"
  if (Test-Path $mfile) {
    $rec = (Get-Content -LiteralPath $mfile -Raw -Encoding UTF8 | ConvertFrom-Json) |
      Where-Object { $_.pubkey -eq $pk -and $_.auth_tag } | Select-Object -First 1
    if ($rec) {
      $at = $rec.auth_tag
      if ($at -isnot [string]) { $at = ($at | ConvertTo-Json -Compress -Depth 20) }
      $env:BUZZ_AUTH_TAG = $at
    }
  }
}

# PowerShell 5.1 zerlegt beim nativen Aufruf (`& exe @args`) jedes Argument, das
# Leerzeichen, Anfuehrungszeichen oder Zeilenumbrueche enthaelt — ein
# mehrzeiliger YAML-Body kommt als Dutzend Einzelargumente an ("unexpected
# argument '13'"). Deshalb wird die Kommandozeile selbst nach den
# MSVCRT-Regeln gequotet und der Prozess direkt gestartet.
function Quote-Arg([string]$a) {
  if ($a -eq "") { return '""' }
  if ($a -notmatch '[\s"]') { return $a }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  $bs = 0
  foreach ($ch in $a.ToCharArray()) {
    if ($ch -eq '\') { $bs++; continue }
    if ($ch -eq '"') { [void]$sb.Append('\' * ($bs * 2 + 1)); [void]$sb.Append('"'); $bs = 0; continue }
    if ($bs -gt 0) { [void]$sb.Append('\' * $bs); $bs = 0 }
    [void]$sb.Append($ch)
  }
  [void]$sb.Append('\' * ($bs * 2))
  [void]$sb.Append('"')
  return $sb.ToString()
}

$exe = Join-Path $env:LOCALAPPDATA "Buzz\buzz.exe"
$cmdline = ($cliArgs | ForEach-Object { Quote-Arg $_ }) -join ' '

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.Arguments = $cmdline
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
$psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
$psi.EnvironmentVariables["BUZZ_PRIVATE_KEY"] = $sk
$psi.EnvironmentVariables["BUZZ_RELAY_URL"] = $Relay
if ($env:BUZZ_AUTH_TAG) { $psi.EnvironmentVariables["BUZZ_AUTH_TAG"] = $env:BUZZ_AUTH_TAG }
$sk = $null
$env:BUZZ_AUTH_TAG = $null

$p = [System.Diagnostics.Process]::Start($psi)
$so = $p.StandardOutput.ReadToEndAsync()
$se = $p.StandardError.ReadToEndAsync()
$p.WaitForExit()
$out = $so.Result; $err = $se.Result
# Rohe UTF-8-Bytes nach stdout: die Konsolen-Codepage wuerde Umlaute sonst
# durch '?' ersetzen und JSON unparsbar machen (gemessen).
$stdout = [Console]::OpenStandardOutput()
$stderr = [Console]::OpenStandardError()
if ($out) { $b = [System.Text.Encoding]::UTF8.GetBytes($out); $stdout.Write($b, 0, $b.Length); $stdout.Flush() }
if ($err) { $b = [System.Text.Encoding]::UTF8.GetBytes($err); $stderr.Write($b, 0, $b.Length); $stderr.Flush() }
exit $p.ExitCode
