<#
.SYNOPSIS
Phase 3 - Run the (patched) uupdump download+conversion script and verify
the produced ISO.

.DESCRIPTION
  1. Executes uup_download_windows.cmd with a per-attempt timeout.
  2. On failure retries the whole script once (aria2 resumes with -c, so the
     already-downloaded UUP payload is kept).
  3. Verifies that exactly one ISO exists and is larger than 1 GB.
#>
param(
    [string]$WorkDir = '',
    [int]$AttemptTimeoutMin = 200
)

$ErrorActionPreference = 'Stop'
$moduleDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $moduleDir 'Common.psm1') -Force

Write-Section 'Phase 3/5: download & convert'

if (-not $WorkDir) {
    if ($env:UUP_WORK_DIR) { $WorkDir = $env:UUP_WORK_DIR }
    elseif (Test-Path 'D:\') { $WorkDir = 'D:\uupwork' }
    else { $WorkDir = (Join-Path (Get-Location) '.temp\uupwork') }
}
$cmdPath = Join-Path $WorkDir 'uup_download_windows.cmd'
if (-not (Test-Path -LiteralPath $cmdPath)) { Fail "uup_download_windows.cmd not found in $WorkDir - did phase 2 run?" }
Write-Log ("Working directory: {0}" -f $WorkDir)

$state = Get-State
$tag = $state.tag

function Invoke-DownloadScript {
    <# Runs the cmd with a timeout; returns the exit code, or 'TIMEOUT'.
       stdout/stderr are inherited (NOT redirected) so every line of the
       uupdump script lands directly in the Actions step log. #>
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = '/c ""' + $cmdPath + '""'
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $null = $p.Start()
    $deadline = (Get-Date).AddMinutes($AttemptTimeoutMin)
    while (-not $p.HasExited) {
        if ((Get-Date) -gt $deadline) {
            Write-LogWarn ("Attempt exceeded {0} minutes - killing process tree" -f $AttemptTimeoutMin)
            taskkill.exe /PID $p.Id /T /F | Out-Null
            Start-Sleep -Seconds 5
            $p.Refresh()
            return 'TIMEOUT'
        }
        Start-Sleep -Seconds 20
    }
    return $p.ExitCode
}

$maxAttempts = 2
$exitCode = $null
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    if ($attempt -gt 1) {
        Write-Log ("Attempt {0}/{1}: re-running with aria2 resume (-c)..." -f $attempt, $maxAttempts)
        Start-Sleep -Seconds 10
    }
    $exitCode = Invoke-DownloadScript
    if ($exitCode -eq 0) { break }
    Write-LogWarn ("Download script exit code: {0}" -f $exitCode)
}

if ($exitCode -ne 0) {
    Fail ("uup_download_windows.cmd failed after {0} attempt(s), exit code {1}. See aria2_download.log in the logs artifact." -f $maxAttempts, $exitCode)
}

# --- verify ISO -----------------------------------------------------------------
$isos = @(Get-ChildItem -LiteralPath $WorkDir -Filter '*.iso' -File -ErrorAction SilentlyContinue)
if ($isos.Count -eq 0) { Fail "No ISO file produced in $WorkDir - conversion failed silently (check logs artifact)." }
if ($isos.Count -gt 1) { Write-LogWarn ("Multiple ISO files found, using the largest: {0}" -f (($isos | Sort-Object Length -Descending | Select-Object -First 1).Name)) }
$iso = ($isos | Sort-Object Length -Descending | Select-Object -First 1)
$sizeGb = [Math]::Round($iso.Length / 1GB, 2)
Write-Log ("ISO: {0} ({1} GB)" -f $iso.Name, $sizeGb)
if ($iso.Length -lt 1GB) { Fail ("ISO is only {0} MB - suspiciously small, refusing to publish" -f [Math]::Round($iso.Length / 1MB)) }

Write-ActionOutput -Key 'isoName' -Value $iso.Name
Write-ActionOutput -Key 'isoPath' -Value $iso.FullName
Write-LogOk ("Phase 3 complete: {0}" -f $iso.Name)
exit 0
