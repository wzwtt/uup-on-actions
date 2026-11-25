<#
.SYNOPSIS
Phase 2 - Generate the uupdump download package on the runner itself and
patch it for unattended execution.

.DESCRIPTION
Reads the persisted state from phase 1 and:
  1. POSTs to uupdump.net/get.php to generate the download package
     (equivalent to clicking "Create download package" on the website).
  2. Extracts it into the working directory.
  3. Patches ConvertConfig.ini and uup_download_windows.cmd so the scripts
     never wait for keyboard input and never ask for UAC elevation.
  4. (dry-run) performs a pre-flight check against api.uupdump.net and stops.
#>
param(
    [string]$WorkDir = ''
)

$ErrorActionPreference = 'Stop'
$moduleDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $moduleDir 'Common.psm1') -Force

Write-Section 'Phase 2/5: generate download package'

# --- working directory -------------------------------------------------------
if (-not $WorkDir) {
    if ($env:UUP_WORK_DIR) { $WorkDir = $env:UUP_WORK_DIR }
    elseif (Test-Path 'D:\') { $WorkDir = 'D:\uupwork' }
    else { $WorkDir = (Join-Path (Get-Location) '.temp\uupwork') }
}
if ($WorkDir -match ' ') { Fail "Working directory '$WorkDir' must not contain spaces (uupdump scripts refuse them)." }
if (Test-Path -LiteralPath $WorkDir) {
    Write-Log "Cleaning existing working directory $WorkDir"
    Remove-Item -LiteralPath $WorkDir -Recurse -Force
}
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
Write-Log ("Working directory: {0}" -f $WorkDir)

$state = Get-State
$guid = $state.guid
$language = $state.language
$editions = @($state.editions)
$virtual = @($state.virtualEditions | Where-Object { $_ })
$options = $state.options
$esd = (ConvertTo-Bool ([string]$options.esd))
$updates = (ConvertTo-Bool ([string]$options.updates))
$cleanup = (ConvertTo-Bool ([string]$options.cleanup))
$netfx3 = (ConvertTo-Bool ([string]$options.netfx3))
$dryRun = (ConvertTo-Bool ([string]$state.dryRun))

# --- build the POST form -----------------------------------------------------
$formParts = @()
if ($virtual.Count -gt 0) { $formParts += 'autodl=3' } else { $formParts += 'autodl=2' }
if ($updates) { $formParts += 'updates=1' }
if ($cleanup)  { $formParts += 'cleanup=1' }
if ($netfx3)   { $formParts += 'netfx=1' }
if ($esd)      { $formParts += 'esd=1' }
foreach ($v in $virtual) { $formParts += ('virtualEditions%5B%5D=' + (Get-UrlEncoded $v)) }
$body = $formParts -join '&'

$editionQuery = (@($editions) -join ';')
$getUri = ('https://uupdump.net/get.php?id={0}&pack={1}&edition={2}' -f $guid, $language, $editionQuery)
Write-Log ("Generating package: POST {0}" -f $getUri)
Write-Log ("Form: {0}" -f $body)

$resp = Invoke-UupRequest -Uri $getUri -Method Post -Body $body -Warmup
$zipPath = Join-Path $WorkDir 'uup_package.zip'
[System.IO.File]::WriteAllBytes($zipPath, $resp.RawContentStream.ToArray())
$zipSize = (Get-Item -LiteralPath $zipPath).Length
Write-Log ("Package downloaded: {0} bytes" -f $zipSize)
if ($zipSize -lt 2000) {
    $head = ([System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($zipPath)) -replace '\s+', ' ').Substring(0, [Math]::Min(300, $zipSize))
    Fail ("The generated 'package' is only {0} bytes and is not a zip - most likely an invalid language/edition combination. Response head: {1}" -f $zipSize, $head)
}

# --- extract ------------------------------------------------------------------
$7z = (Get-Command 7z.exe -ErrorAction SilentlyContinue).Source
if (-not $7z) { $7z = (Get-Command 7z -ErrorAction SilentlyContinue).Source }
if (-not $7z) { Fail '7z.exe not found on PATH (GitHub Windows runners ship 7-Zip as `7z`)' }
& $7z x $zipPath "-o$WorkDir" -y | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "7z failed to extract the package (exit $LASTEXITCODE)" }
$cmdPath = Join-Path $WorkDir 'uup_download_windows.cmd'
if (-not (Test-Path -LiteralPath $cmdPath)) { Fail "Package extracted but $cmdPath not found inside" }
Write-LogOk 'Package generated and extracted'

# --- patch ConvertConfig.ini ----------------------------------------------------
$iniPath = Join-Path $WorkDir 'ConvertConfig.ini'
$ini = Get-Content -LiteralPath $iniPath -Raw -Encoding Default

function Set-IniValue {
    param([string]$Text, [string]$Section, [string]$Key, [string]$Value)
    # $Section comes WITH its brackets, e.g. '[convert-UUP]'
    $pattern = ('(?ms)({0}[^\[]*?^\s*{1}\s*)=\s*[^\r\n]*' -f [regex]::Escape($Section), [regex]::Escape($Key))
    if ($Text -match $pattern) {
        return [regex]::Replace($Text, $pattern, ('$1= ' + $Value), [System.Text.RegularExpressions.RegexOptions]::None)
    }
    Write-LogWarn ("ini key '{0}' in {1} not found - value not written ({2}={3})" -f $Key, $Section, $Key, $Value)
    return $Text
}

$ini = Set-IniValue $ini '[convert-UUP]' 'AutoExit' '1'
$ini = Set-IniValue $ini '[convert-UUP]' 'AutoStart' '1'
if ($virtual.Count -gt 0) { $ini = Set-IniValue $ini '[convert-UUP]' 'StartVirtual' '1' } else { $ini = Set-IniValue $ini '[convert-UUP]' 'StartVirtual' '0' }
$ini = Set-IniValue $ini '[convert-UUP]' 'wim2esd' ($(if ($esd) { '1' } else { '0' }))
$ini = Set-IniValue $ini '[create_virtual_editions]' 'vwim2esd' ($(if ($esd) { '1' } else { '0' }))
if ($virtual.Count -gt 0) { $ini = Set-IniValue $ini '[create_virtual_editions]' 'vAutoStart' '1' }

# Apply every user option that has an ini target
$schema = Get-UupOptionSchema
foreach ($k in $options.Keys) {
    $s = $schema[$k]
    if (-not $s -or -not $s.ini) { continue }   # workflow-only key
    if ($k -eq 'esd') { continue }              # handled above
    $iniKey = ($s.ini.Split('.')) | Select-Object -Last 1
    $section = '[' + (($s.ini.Split('.'))[0].TrimStart('[').TrimEnd(']')) + ']'
    $val = ([string]$options[$k]).Trim()
    if ($s.bool) { $val = $(if (ConvertTo-Bool $val) { '1' } else { '0' }) }
    $ini = Set-IniValue $ini $section $iniKey $val
}
Set-Content -LiteralPath $iniPath -Value $ini -Encoding Default
Write-LogOk 'ConvertConfig.ini patched (AutoExit=1, AutoStart=1, unattended)'

# --- patch uup_download_windows.cmd --------------------------------------------
$cmd = Get-Content -LiteralPath $cmdPath -Raw -Encoding Default
# 1. skip the UAC-elevation + path-space-check prologue by jumping straight
#    to :START_PROCESS (inserted right after `cd /d "%~dp0"`)
$cmd = $cmd -replace '(?m)(^cd /d "%~dp0"\r?$)', "`$1`r`ngoto :START_PROCESS"
# 2. replace every interactive `pause` with a log line (keeps `& exit /b 1`
#    chains intact - `rem` would swallow them)
$cmd = $cmd -replace '\bpause\b', 'echo [uup-auto] pause skipped'
# 3. use pwsh instead of Windows PowerShell 5.1. Not cosmetic: this step runs
#    inside a pwsh (PS7) workflow step whose PSModulePath (PS7 module dirs)
#    leaks into child powershell.exe sessions, breaking cmdlet autoloading
#    there (get_aria2.ps1 dies with "Get-FileHash: command not found").
$cmd = $cmd -replace '(?m)\bpowershell\b', 'pwsh'
Set-Content -LiteralPath $cmdPath -Value $cmd -Encoding Default
if ($cmd -notmatch 'goto :START_PROCESS') { Fail 'Failed to inject the START_PROCESS jump into uup_download_windows.cmd' }
Write-LogOk 'uup_download_windows.cmd patched (no UAC prompt, no interactive pause, pwsh)'

# --- pre-flight (dry-run only) --------------------------------------------------
if ($dryRun) {
    Write-Section 'Pre-flight check (dry-run)'
    $apiUri = ('https://api.uupdump.net/get.php?id={0}&lang={1}&edition={2}' -f $guid, $language, $editionQuery)
    try {
        $api = Invoke-UupApi -Uri $apiUri
        $txt = [string]$api.Content
        if ($txt -match '"error"') {
            $errTxt = [regex]::Match($txt, '"error"\s*:\s*"(.*?)"').Groups[1].Value
            Fail ("Pre-flight: uupdump API reports an error for this combination: {0}" -f $errTxt)
        }
        $sizes = [regex]::Matches($txt, '"size"\s*:\s*"(\d+)"') | ForEach-Object { [long]$_.Groups[1].Value }
        $fileCount = ([regex]::Matches($txt, '"sha256"\s*:')).Count
        $totalGb = [Math]::Round((($sizes | Measure-Object -Sum).Sum) / 1GB, 2)
        Write-LogOk ("Pre-flight OK: {0} files, ~{1} GB total download from Microsoft CDN" -f $fileCount, $totalGb)
        Write-Summary ("## Dry-run result`n`nCombination is valid.`n`n| Check | Value |`n|---|---|`n| Files | {0} |`n| Estimated download | ~{1} GB |`n| Tag | `{2}` |`n`nDry-run stops here - no download/conversion performed.`n" -f $fileCount, $totalGb, $state.tag)
    } catch {
        Write-LogWarn ("Pre-flight API check failed ({0}) - treating as warning only. The real download would still verify server-side." -f $_.Exception.Message)
        Write-Summary ("## Dry-run result`n`nPackage generated successfully (form accepted). API pre-flight check could not complete: {0}`n" -f $_.Exception.Message)
    }
    Write-LogOk 'Phase 2 complete (dry-run)'
    exit 0
}

# --- pre-fetch the runtime dependencies ----------------------------------------------
# uup_download_windows.cmd normally downloads aria2c.exe (via get_aria2.ps1)
# and the converter binaries on first run; those first-hop downloads are the
# flaky part behind CDNs. Pre-fetch everything here (with retry/backoff and
# hash verification) so the cmd scripts only ever verify & skip.
Write-Section 'Pre-fetch runtime dependencies'
$filesDir = Join-Path $WorkDir 'files'

# 1) aria2c.exe - URL and expected sha256 come from the package's own
#    get_aria2.ps1, so the version always matches what the cmd script expects.
$gaPath = Join-Path $filesDir 'get_aria2.ps1'
$aria2Target = Join-Path $filesDir 'aria2c.exe'
if (Test-Path -LiteralPath $gaPath) {
    $ga = Get-Content -LiteralPath $gaPath -Raw
    $aria2Url = [regex]::Match($ga, 'https?://[^\s''"]+aria2c\.exe').Value
    $aria2Hash = [regex]::Match($ga, '\$hash\s*=\s*''([0-9a-fA-F]{64})''').Groups[1].Value
    if (-not $aria2Url) { $aria2Url = 'https://uupdump.net/misc/aria2c.exe' }
    $resp = Invoke-UupRequest -Uri $aria2Url -Warmup
    [System.IO.File]::WriteAllBytes($aria2Target, $resp.RawContentStream.ToArray())
    $dlHash = Get-FileSha256 $aria2Target
    if ($aria2Hash -and ($dlHash -ne $aria2Hash.ToLowerInvariant())) {
        Fail ("aria2c.exe hash mismatch after download (expected {0}, got {1})" -f $aria2Hash, $dlHash)
    }
    Write-LogOk ("aria2c.exe pre-fetched and verified ({0} bytes)" -f (Get-Item $aria2Target).Length)
} else {
    Write-LogWarn 'get_aria2.ps1 not found in package - skipping aria2 pre-fetch'
}

# 2) converter binaries listed in files/converter_windows (aria2 input list)
$convListPath = Join-Path $filesDir 'converter_windows'
if (Test-Path -LiteralPath $convListPath) {
    $convEntries = @()
    foreach ($line in (Get-Content -LiteralPath $convListPath)) {
        $t = $line.Trim()
        if (-not $t) { continue }
        if ($t -match '^(https?://.+)$') { $convEntries += [pscustomobject]@{ url = $Matches[1]; out = ''; sum = '' } }
        elseif ($convEntries.Count -gt 0) {
            if ($t -match '^out=(.+)$') { $convEntries[-1].out = $Matches[1] }
            elseif ($t -match '^checksum=sha-256=([0-9a-fA-F]{64})') { $convEntries[-1].sum = $Matches[1].ToLowerInvariant() }
        }
    }
    foreach ($e in $convEntries) {
        if (-not $e.url -or -not $e.out) { continue }
        $target = Join-Path $filesDir $e.out
        if ((Test-Path -LiteralPath $target) -and $e.sum -and ((Get-FileSha256 $target) -eq $e.sum)) {
            Write-Log ("{0} already present, hash OK - skipping" -f $e.out)
            continue
        }
        Write-Log ("Pre-fetching {0}..." -f $e.out)
        $r2 = Invoke-UupRequest -Uri $e.url
        [System.IO.File]::WriteAllBytes($target, $r2.RawContentStream.ToArray())
        if ($e.sum -and ((Get-FileSha256 $target) -ne $e.sum)) {
            Fail ("{0} hash mismatch after download (expected {1})" -f $e.out, $e.sum)
        }
        Write-LogOk ("{0} pre-fetched ({1} bytes)" -f $e.out, (Get-Item $target).Length)
    }
} else {
    Write-LogWarn 'files/converter_windows not found - converter binaries left to the cmd script'
}

# --- disk space check ----------------------------------------------------------
$workDrive = (Get-Item $WorkDir).PSDrive
$freeGb = [Math]::Round($workDrive.Free / 1GB, 1)
Write-Log ("Free disk space on {0}: {1} GB" -f $workDrive.Name, $freeGb)
if ($freeGb -lt 25) {
    Fail ("Only {0} GB free on {1}: - at least 25 GB is required (UUP set + ISO + temp). Reduce editions/virtual editions or pick a smaller build." -f $freeGb, $workDrive.Name)
}

Write-ActionOutput -Key 'workdir' -Value $WorkDir
Write-LogOk 'Phase 2 complete'
exit 0
