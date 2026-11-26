Set-StrictMode -Version 2.0

# ============================================================================
# Common.psm1 - shared helpers for all UUP-on-Actions scripts
# Compatible with Windows PowerShell 5.1 and PowerShell 7+.
# ============================================================================

$script:UupUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

function Write-Log {
    param([string]$Message)
    Write-Host ("[uup] {0}" -f $Message)
}

function Write-LogOk {
    param([string]$Message)
    Write-Host ("[uup][OK] {0}" -f $Message) -ForegroundColor Green
}

function Write-LogWarn {
    param([string]$Message)
    Write-Host ("[uup][WARN] {0}" -f $Message) -ForegroundColor Yellow
}

function Write-LogFail {
    param([string]$Message)
    Write-Host ("[uup][FAIL] {0}" -f $Message) -ForegroundColor Red
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=== {0} ===" -f $Title) -ForegroundColor Cyan
}

function Fail {
    param([string]$Message)
    Write-LogFail $Message
    throw $Message
}

# ---------------------------------------------------------------------------
# Boolean parsing (workflow inputs arrive as strings)
# ---------------------------------------------------------------------------

function ConvertTo-Bool {
    param([AllowNull()][string]$Value, [bool]$Default = $false)
    if ($null -eq $Value) { return $Default }
    if ($Value -eq '') { return $Default }
    switch -Regex ($Value.Trim().ToLowerInvariant()) {
        '^(1|true|yes|y|on)$'  { return $true }
        '^(0|false|no|n|off)$' { return $false }
        default {
            Fail ("Invalid boolean value: '{0}' (expected true/false/1/0/yes/no)" -f $Value)
        }
    }
}

# ---------------------------------------------------------------------------
# GitHub Actions outputs / summaries
# Safe multivalue (heredoc) writes; never redirect stdout into the files.
# ---------------------------------------------------------------------------

function Get-ActionOutputPath {
    if ($env:GITHUB_OUTPUT) { return $env:GITHUB_OUTPUT }
    return $null
}

function Write-ActionOutput {
    param([string]$Key, [AllowNull()][string]$Value)
    $path = Get-ActionOutputPath
    if (-not $path) { return }
    $v = if ($null -eq $Value) { '' } else { [string]$Value }
    $isMultiline = ($v -match "`n")
    if ($isMultiline) {
        $delim = "EOF_" + [Guid]::NewGuid().ToString('N').Substring(0, 8).ToUpperInvariant()
        [System.IO.File]::AppendAllText($path, ("{0}<<{1}`n{2}`n{1}`n" -f $Key, $delim, $v), [System.Text.Encoding]::UTF8)
    } else {
        [System.IO.File]::AppendAllText($path, ("{0}={1}`n" -f $Key, $v), [System.Text.Encoding]::UTF8)
    }
}

function Write-ActionError {
    param([string]$Message)
    if ($env:GITHUB_STEP_SUMMARY) {
        [System.IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, ("## :x: Build failed`n`n``````n{0}`n``````n" -f $Message), [System.Text.Encoding]::UTF8)
    }
}

function Write-Summary {
    param([string]$Markdown)
    if ($env:GITHUB_STEP_SUMMARY) {
        [System.IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, ($Markdown + "`n"), [System.Text.Encoding]::UTF8)
    }
}

# ---------------------------------------------------------------------------
# Persisted job state (passed between workflow steps)
# ---------------------------------------------------------------------------

function Get-StatePath {
    if ($env:UUP_STATE_PATH) { return $env:UUP_STATE_PATH }
    $base = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { (Join-Path (Get-Location) '.temp') }
    if (-not (Test-Path -LiteralPath $base)) { New-Item -ItemType Directory -Path $base -Force | Out-Null }
    return (Join-Path $base 'uup-state.json')
}

function Set-State {
    param([Parameter(Mandatory)][hashtable]$Data)
    $path = Get-StatePath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Data | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
    Write-Log ("State saved to {0}" -f $path)
}

function Get-State {
    $path = Get-StatePath
    if (-not (Test-Path -LiteralPath $path)) { Fail "No state file found at $path - did the previous phase run?" }
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    return ($raw | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------
# uupdump.net HTTP access with session warm-up + exponential backoff.
# The front-end (uupdump.net) is behind a CDN that rate-limits datacenter
# IPs; api.uupdump.net is a plain JSON endpoint.
# ---------------------------------------------------------------------------

function New-UupWebSession {
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    return $session
}

function Get-HttpErrorBody {
    <# Extracts the response body text from a failed Invoke-WebRequest,
       compatible with PowerShell 5.1 (HttpWebResponse) and 7 (ErrorDetails).
       Returns [string] (possibly empty). #>
    param([AllowNull()]$ErrorRecord)
    if (-not $ErrorRecord) { return '' }
    # PowerShell 7+: ErrorDetails.Message carries the body verbatim
    try {
        $ed = $ErrorRecord.ErrorDetails
        if ($ed -and $ed.Message) {
            $t = [string]$ed.Message
            if ($t.Trim()) { return $t }
        }
    } catch { }
    # PowerShell 5.1 / fallback: read the response stream
    try {
        $resp = $ErrorRecord.Exception.Response
        if ($resp) {
            $stream = $resp.GetResponseStream()
            if ($stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                $t = $reader.ReadToEnd()
                $reader.Dispose()
                return $t
            }
        }
    } catch { }
    return ''
}

function Get-HttpStatusCode {
    param([AllowNull()]$ErrorRecord)
    try {
        if ($ErrorRecord.Exception.Response) { return [int]$ErrorRecord.Exception.Response.StatusCode }
    } catch { }
    return 0
}

function Get-UupdumpErrorText {
    <# Extracts the human-readable message from a uupdump error page
       (HTTP error pages render the message in a <p> element). #>
    param([string]$Body)
    if (-not $Body) { return $null }
    if ($Body -notmatch '(?i)<!DOCTYPE|<html') { return $null }
    foreach ($m in [regex]::Matches($Body, '(?s)<p[^>]*>\s*(.*?)\s*</p>')) {
        $t = ($m.Groups[1].Value -replace '<[^>]+>', '' -replace '\s+', ' ').Trim()
        if ($t -and $t.Length -gt 5 -and $t -notmatch '(?i)theme|©|cookie') { return $t }
    }
    return $null
}

function Invoke-UupRequest {
    <#
    .SYNOPSIS
    Performs an HTTP request to uupdump with warm-up, retries and backoff.

    .DESCRIPTION
    Retry policy: transient conditions (429, 5xx, timeouts, Cloudflare
    managed challenges) are retried with backoff. Non-429 4xx responses are
    client errors - they are never retried; when the response body is a
    uupdump error page, its message is surfaced verbatim.

    .PARAMETER Uri            Target URL.
    .PARAMETER Method         GET (default) or POST.
    .PARAMETER Body           Optional form body (string) for POST.
    .PARAMETER Warmup         Also GET https://uupdump.net/known.php first to
                              obtain CDN cookies.
    .PARAMETER Retries        Number of retries after failure (default 3).
    .PARAMETER TimeoutSec     Per-request timeout.
    .OUTPUTS
    Microsoft.PowerShell.Commands.WebResponseObject
    #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('GET', 'POST')][string]$Method = 'GET',
        [string]$Body = $null,
        [switch]$Warmup,
        [int]$Retries = 3,
        [int]$TimeoutSec = 90
    )

    $session = New-UupWebSession
    $headers = @{
        'User-Agent'       = $script:UupUserAgent
        'Accept'           = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
        'Accept-Language'  = 'en-US,en;q=0.9'
        'Referer'          = 'https://uupdump.net/known.php'
    }
    if ($Warmup) {
        try {
            $null = Invoke-WebRequest -UseBasicParsing -Uri 'https://uupdump.net/known.php' `
                -WebSession $session -Headers $headers -TimeoutSec $TimeoutSec
            Write-Log "Warm-up request OK (CDN cookies obtained)"
            Start-Sleep -Seconds 2
        } catch {
            Write-LogWarn "Warm-up request failed (continuing anyway): $($_.Exception.Message)"
        }
    }

    $delays = @(5, 15, 45)
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            if ($Method -eq 'POST' -and $null -ne $Body) {
                return Invoke-WebRequest -UseBasicParsing -Uri $Uri -Method Post -Body $Body `
                    -ContentType 'application/x-www-form-urlencoded' `
                    -WebSession $session -Headers $headers -TimeoutSec $TimeoutSec
            }
            return Invoke-WebRequest -UseBasicParsing -Uri $Uri -Method $Method `
                -WebSession $session -Headers $headers -TimeoutSec $TimeoutSec
        } catch {
            $bodyText = Get-HttpErrorBody $_
            $statusCode = Get-HttpStatusCode $_
            $cfChallenge = ($bodyText -match '__cf_chl|Just a moment|challenge-platform|cf-chl')

            # --- non-429 client errors: never retried, cause surfaced ----------
            if ($statusCode -ge 400 -and $statusCode -lt 500 -and $statusCode -ne 429) {
                $uupErr = Get-UupdumpErrorText $bodyText
                if ($uupErr) {
                    Fail ("uupdump rejected the request (HTTP {0}): {1} Check the build / language / editions inputs against the uupdump website for this build." -f $statusCode, $uupErr)
                }
                Fail ("Request to {0} failed with HTTP {1} (client error - not retried). The language/edition/build combination is most likely invalid; check it against the uupdump website." -f $Uri, $statusCode)
            }

            # --- transient conditions: backoff and retry -------------------------
            if ($cfChallenge) {
                # A Cloudflare managed challenge will not clear by itself; retry
                # a couple of times (challenges are intermittent), then give up
                # with a clear, actionable message.
                if ($attempt -gt $Retries) {
                    Fail "uupdump.net served a Cloudflare challenge to this IP. This is usually temporary - retry the run in a few minutes, or pass a build GUID / uupdump.net URL directly (bypasses the build-list page)."
                }
                Write-LogWarn ("Cloudflare challenge on attempt {0}; waiting {1}s and retrying..." -f $attempt, $delays[[Math]::Min($attempt - 1, $delays.Count - 1)])
                Start-Sleep -Seconds $delays[[Math]::Min($attempt - 1, $delays.Count - 1)]
                continue
            }
            if ($attempt -gt $Retries) { Fail ("Request to {0} failed after {1} attempts: {2}" -f $Uri, $attempt, $_.Exception.Message) }
            $wait = if ($attempt -le $delays.Count) { $delays[$attempt - 1] } else { 60 }
            Write-LogWarn ("Attempt {0} to {1} failed (HTTP {2}); retrying in {3}s..." -f $attempt, $Uri, $statusCode, $wait)
            Start-Sleep -Seconds $wait
        }
    }
}

function Invoke-UupApi {
    <# Plain JSON API on api.uupdump.net (no CDN warm-up needed). #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [int]$Retries = 3,
        [int]$TimeoutSec = 60
    )
    $delays = @(5, 15, 45)
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return Invoke-WebRequest -UseBasicParsing -Uri $Uri -TimeoutSec $TimeoutSec `
                -Headers @{ 'User-Agent' = $script:UupUserAgent; 'Accept' = 'application/json' }
        } catch {
            $bodyText = Get-HttpErrorBody $_
            $statusCode = Get-HttpStatusCode $_

            # non-429 client errors carry the API's own explanation - report it
            # instead of repeating an identical request
            if ($statusCode -ge 400 -and $statusCode -lt 500 -and $statusCode -ne 429) {
                $apiErr = [regex]::Match([string]$bodyText, '"error"\s*:\s*"(.*?)"').Groups[1].Value
                if ($apiErr) { Fail ("API rejected the request (HTTP {0}): {1}" -f $statusCode, $apiErr) }
                Fail ("API request {0} failed with HTTP {1} (client error - not retried)" -f $Uri, $statusCode)
            }

            if ($attempt -gt $Retries) { Fail ("API request {0} failed after {1} attempts: {2}" -f $Uri, $attempt, $_.Exception.Message) }
            $wait = if ($attempt -le $delays.Count) { $delays[$attempt - 1] } else { 60 }
            Write-LogWarn ("API attempt {0} failed (HTTP {1}); retrying in {2}s..." -f $attempt, $statusCode, $wait)
            Start-Sleep -Seconds $wait
        }
    }
}

# ---------------------------------------------------------------------------
# URL / hash helpers
# ---------------------------------------------------------------------------

function Get-UrlEncoded {
    param([string]$Text)
    return [System.Uri]::EscapeDataString($Text)
}

function Get-ShortHash {
    param([string]$Text, [int]$Length = 4)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash) -replace '-', '').Substring(0, $Length).ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $hash = $sha.ComputeHash($fs)
            return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
        } finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
}

# ---------------------------------------------------------------------------
# Options parsing: "Key=Value" lines into an ordered map, with whitelist.
# Keys are case-insensitive. Values are raw strings; conversion happens later.
# ---------------------------------------------------------------------------

function Get-UupOptionSchema {
    <#
    Definition of every supported key in the `options` input.
    ini    = target inside ConvertConfig.ini (null = workflow-only key).
    bool   = value must be a boolean (else raw text/number).
    tag    = whether the key changes the artifact (thus the tag suffix hash).
    #>
    return [ordered]@{
        updates                  = @{ ini = '[convert-UUP].AddUpdates';            bool = $true;  tag = $true }
        cleanup                   = @{ ini = '[convert-UUP].Cleanup';                 bool = $true;  tag = $true }
        netfx3                    = @{ ini = '[convert-UUP].NetFx3';                  bool = $true;  tag = $true }
        resetbase                 = @{ ini = '[convert-UUP].ResetBase';                bool = $true;  tag = $true }
        skipwinre                 = @{ ini = '[convert-UUP].SkipWinRE';                bool = $true;  tag = $true }
        lcuwinre                  = @{ ini = '[convert-UUP].LCUwinre';                  bool = $true;  tag = $true }
        lcuexpand                 = @{ ini = '[convert-UUP].LCUmsuExpand';            bool = $true;  tag = $true }
        updtbootfiles             = @{ ini = '[convert-UUP].UpdtBootFiles';            bool = $true;  tag = $true }
        forcedism                 = @{ ini = '[convert-UUP].ForceDism';                bool = $true;  tag = $true }
        refesd                    = @{ ini = '[convert-UUP].RefESD';                   bool = $true;  tag = $true }
        skiplcumsu                = @{ ini = '[convert-UUP].SkipLCUmsu';               bool = $true;  tag = $true }
        skipedge                  = @{ ini = '[convert-UUP].SkipEdge';                 bool = $true;  tag = $true }
        wim2swm                   = @{ ini = '[convert-UUP].wim2swm';                  bool = $true;  tag = $true }
        skipiso                   = @{ ini = '[convert-UUP].SkipISO';                   bool = $true;  tag = $true }
        disabledupdatingupgrade   = @{ ini = '[convert-UUP].DisableUpdatingUpgrade';   bool = $true;  tag = $true }
        skipapps                  = @{ ini = '[Store_Apps].SkipApps';                   bool = $true;  tag = $true }
        appslevel                 = @{ ini = '[Store_Apps].AppsLevel';                 bool = $false; tag = $true }
        stubappsfull              = @{ ini = '[Store_Apps].StubAppsFull';               bool = $true;  tag = $true }
        customlist                = @{ ini = '[Store_Apps].CustomList';                 bool = $true;  tag = $true }
        vdeletedsource            = @{ ini = '[create_virtual_editions].vDeleteSource'; bool = $true; tag = $true }
        vpreserve                 = @{ ini = '[create_virtual_editions].vPreserve';    bool = $true;  tag = $true }
        vsorteditions             = @{ ini = '[create_virtual_editions].vSortEditions'; bool = $true;  tag = $true }
        adddrivers                = @{ ini = '[convert-UUP].AddDrivers';                bool = $true;  tag = $true }
        drv_source                = @{ ini = '[convert-UUP].Drv_Source';               bool = $false; tag = $true }
        esd                       = @{ ini = '[convert-UUP].wim2esd';                  bool = $true;  tag = $true }
        # workflow-only keys (never written into the package)
        force                     = @{ ini = $null; bool = $true;  tag = $false }
        tag_suffix                = @{ ini = $null; bool = $false; tag = $false }
    }
}

function ConvertFrom-OptionsText {
    param([AllowNull()][string]$Text)
    $schema = Get-UupOptionSchema
    $result = [ordered]@{}
    if (-not $Text -or -not $Text.Trim()) { return $result }
    $lineNo = 0
    foreach ($line in ($Text -split "`r?`n")) {
        $lineNo++
        $l = $line.Trim()
        if (-not $l) { continue }
        if ($l.StartsWith('#')) { continue }
        $idx = $l.IndexOf('=')
        if ($idx -lt 1) { Fail ("options line {0} is not in Key=Value form: '{1}'" -f $lineNo, $l) }
        $key = $l.Substring(0, $idx).Trim().ToLowerInvariant()
        $val = $l.Substring($idx + 1).Trim()
        if (-not $schema.Contains($key)) {
            $valid = ($schema.Keys | Sort-Object) -join ', '
            Fail ("Unknown options key '{0}' (line {1}). Valid keys: {2}" -f $key, $lineNo, $valid)
        }
        $result[$key] = $val
    }
    return $result
}

# ---------------------------------------------------------------------------
# Normalisation of build inputs
# ---------------------------------------------------------------------------

function Get-NormalizedArch {
    param([string]$Arch)
    switch -Regex ($Arch.Trim().ToLowerInvariant()) {
        '^(amd64|x64)$'    { return 'amd64' }
        '^(arm64|aarch64)$' { return 'arm64' }
        '^(x86|i386|32)$'   { return 'x86' }
        default { Fail ("Invalid arch '{0}' (expected amd64/arm64/x86)" -f $Arch) }
    }
}

function Get-ArchDisplay {
    <# uupdump list pages show "x64" for amd64. #>
    param([string]$Arch)
    if ($Arch -eq 'amd64') { return 'x64' }
    return $Arch
}

function ConvertTo-List {
    param([AllowNull()][string]$Csv)
    if (-not $Csv -or -not $Csv.Trim()) { return @() }
    return @($Csv.Split(',') | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
}

# ---------------------------------------------------------------------------
# Build discovery: turns a build spec into { guid, build, title, arch, date }
# Accepted specs ("newest" is implied by the form itself; an older build is
# requested by build number, GUID or URL):
#   <category>                newest full build inside a catalogue category
#                             (e.g. w11-25h2, server-24h2, w11-26h2-experimental)
#   <ring>                    newest full build published on an update ring
#                             (uupdump fetchupd.php; retail, rp, wif, wis,
#                             beta, canary - plus aliases)
#   <category>@<ring>         newest full build of that product line on that
#                             ring (e.g. w11-24h2@retail)
#   26200.1234                exact build number search
#   <36-char GUID>            direct uupdump build id
#   https://uupdump.net/...   any uupdump URL containing id=<guid>
# ---------------------------------------------------------------------------

$script:UupRingAliases = [ordered]@{
    retail          = 'retail'
    public          = 'retail'
    release         = 'retail'
    rp              = 'rp'
    preview         = 'rp'
    releasepreview  = 'rp'
    wif             = 'wif'
    fast            = 'wif'
    insiderfast     = 'wif'
    wis             = 'wis'
    slow            = 'wis'
    insiderslow     = 'wis'
    beta            = 'beta'
    canary          = 'canary'
}

function Get-UupBuildNumberTuple {
    <# Turns "26200.10075" into a comparable tuple (major, minor). #>
    param([string]$BuildNo)
    if ($BuildNo -match '^(\d+)\.(\d+)$') { return @([int]$Matches[1], [int]$Matches[2]) }
    return @(0, 0)
}

function Compare-UupBuildNumber {
    <# Returns 1 if A > B, -1 if A < B, 0 if equal. #>
    param([string]$A, [string]$B)
    $ta = Get-UupBuildNumberTuple $A
    $tb = Get-UupBuildNumberTuple $B
    if ($ta[0] -ne $tb[0]) { return [Math]::Sign($ta[0] - $tb[0]) }
    return [Math]::Sign($ta[1] - $tb[1])
}

function Test-RingEntryMatchesCategory {
    <# Whether a ring-query full-build entry belongs to the product line
       denoted by a category slug (e.g. w11-24h2, server-24h2,
       w11-26h2-experimental). The version core of the slug (24h2, 1809, …)
       must appear in the entry title; the family prefix (w11 / w10 / server)
       constrains the title family accordingly. Insider ring entries whose
       titles carry no version designation never match. #>
    param([string]$Title, [string]$CategorySlug)

    $core = $CategorySlug.ToLowerInvariant()
    $family = $null
    if ($core -match '^w1[01]-') { $family = $core.Substring(0, 3); $core = $core.Substring(4) }
    elseif ($core -match '^server-') { $family = 'server'; $core = $core.Substring(7) }
    $core = $core -replace '-(beta|experimental)$', ''
    if (-not $core) { return $false }

    if ($Title -notmatch ('(?i)\b' + [regex]::Escape($core) + '\b')) { return $false }
    switch ($family) {
        'w11'    { if ($Title -notmatch '^Windows 11\b') { return $false } }
        'w10'    { if ($Title -notmatch '^Windows 10\b') { return $false } }
        'server' { if ($Title -notmatch '(?i)\bserver\b') { return $false } }
    }
    return $true
}

function Find-UupBuild {
    param(
        [Parameter(Mandatory)][string]$Spec,
        [Parameter(Mandatory)][string]$Arch
    )
    $spec = $Spec.Trim()
    $archN = Get-NormalizedArch $Arch
    $archDisplay = Get-ArchDisplay $archN

    # --- direct GUID / URL ------------------------------------------------
    $guid = $null
    if ($spec -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
        $guid = $spec.ToLowerInvariant()
    } elseif ($spec -match 'id=([0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})') {
        $guid = $Matches[1].ToLowerInvariant()
    }

    if ($guid) {
        Write-Log ("Direct GUID requested: {0} (arch={1})" -f $guid, $archN)
        # Enrich from the JSON API (api.uupdump.net is not behind the CDN).
        # NOTE: parse header fields via regex only - the `files` map can contain
        # case-differing duplicate keys that make ConvertFrom-Json throw.
        $build = $null; $title = '(direct GUID)'; $apiArch = ''
        try {
            $api = Invoke-UupApi -Uri ("https://api.uupdump.net/get.php?id={0}" -f $guid)
            $txt = [string]$api.Content
            $title = [regex]::Match($txt, '"updateName"\s*:\s*"(.*?)"').Groups[1].Value
            $build = [regex]::Match($txt, '"build"\s*:\s*"(.*?)"').Groups[1].Value
            $apiArch = [regex]::Match($txt, '"arch"\s*:\s*"(.*?)"').Groups[1].Value
            if ($build) { Write-Log ("API metadata: {0} (build {1})" -f $title, $build) }
        } catch {
            Write-LogWarn ("Could not fetch metadata for GUID from API: {0}" -f $_.Exception.Message)
        }
        if ($apiArch -and ($apiArch -ne $archN)) {
            Fail ("The build {0} is '{1}' but arch input is '{2}'. Fix the arch input." -f $guid, $apiArch, $archN)
        }
        return @{ guid = $guid; build = $build; title = $title; arch = $archN; date = $null; category = $null }
    }

    # --- ring forms: <ring>, <category>@<ring> (fetchupd.php) --------------
    $specLower = $spec.ToLowerInvariant()
    $ringCategory = $null
    $ring = $null
    if ($specLower -match '^([a-z0-9][a-z0-9-]*)@([a-z]+)$') {
        $ringCategory = $Matches[1]
        $ring = $script:UupRingAliases[$Matches[2]]
        if (-not $ring) {
            $valid = ($script:UupRingAliases.Keys | Sort-Object) -join ', '
            Fail ("Unknown ring '{0}' in spec '{1}'. Valid rings (aliases in parentheses): {2}" -f $Matches[2], $spec, $valid)
        }
    } elseif ($specLower -match '^[a-z]+$') {
        $ring = $script:UupRingAliases[$specLower]
    }

    if ($ring) {
        $uri = ('https://uupdump.net/fetchupd.php?arch={0}&ring={1}' -f $archN, $ring)
        Write-Log ("Fetching update ring: {0} (ring={1}{2})" -f $uri, $ring, $(if ($ringCategory) { ", category={0}" -f $ringCategory } else { '' }))
        $resp = Invoke-UupRequest -Uri $uri -Warmup
        $html = [string]$resp.Content

        $rowPattern = '<a href="selectlang\.php\?id=([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})"\s*>\s*(.*?)\s*</a>'
        $matchesAll = [regex]::Matches($html, $rowPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
        if ($matchesAll.Count -eq 0) {
            Fail ("Ring '{0}' returned no builds for arch '{1}'. The ring may be dormant at the moment - try another ring or a category." -f $ring, $archN)
        }
        # Collect full builds only. Full builds are titled
        # "Windows 11, version …" / "Windows 10, version …" / "Windows
        # Server, version …" / "Windows 11 Insider Preview Feature Update …";
        # servicing entries (cumulative updates, .NET updates, critical OOBE
        # updates, server hotpatches) never start with "Windows".
        $candidates = @()
        $skipped = 0
        foreach ($m in $matchesAll) {
            $title = ($m.Groups[2].Value -replace '\s+', ' ').Trim()
            if ($title -notmatch '^Windows (?:\d|Server\b)') { $skipped++; continue }
            $after = $html.Substring($m.Index + $m.Length, [Math]::Min(400, $html.Length - $m.Index - $m.Length))
            $archCell = [regex]::Match($after, '</td><td class="collapsing">\s*(.*?)\s*</td>')
            $rowArch = if ($archCell.Success) { $archCell.Groups[1].Value.Trim().ToLowerInvariant() } else { '' }
            if ($rowArch -ne $archDisplay) { continue }
            $buildNo = [regex]::Match($title, '(\d{4,6}\.\d{1,5})').Groups[1].Value
            if (-not $buildNo) { continue }
            $candidates += @{ guid = $m.Groups[1].Value.ToLowerInvariant(); build = $buildNo; title = $title; arch = $archN }
        }
        if ($candidates.Count -eq 0) {
            Fail ("Ring '{0}' has no full build for arch '{1}' ({2} servicing entries skipped). Try a category spec or a different ring." -f $ring, $archN, $skipped)
        }

        # <category>@<ring>: restrict to the requested product line
        if ($ringCategory) {
            $filtered = @($candidates | Where-Object { Test-RingEntryMatchesCategory -Title $_.title -CategorySlug $ringCategory })
            if ($filtered.Count -eq 0) {
                $served = ($candidates | ForEach-Object { '{0} ({1})' -f $_.build, $_.title }) -join ' ; '
                Fail ("The '{0}' ring currently publishes no full build of '{1}'. The ring currently serves: {2}. Use the bare ring spec for the newest of those, or the category spec '{1}' - the catalogue tracks every published full build of that product line." -f $ring, $ringCategory, $served)
            }
            $candidates = $filtered
        }

        $picked = @($candidates | Sort-Object -Property @{Expression = { (Get-UupBuildNumberTuple $_.build)[0] }}, @{Expression = { (Get-UupBuildNumberTuple $_.build)[1] }} -Descending)[0]
        $picked['ring'] = $ring
        if ($ringCategory) { $picked['category'] = $ringCategory }
        Write-Log ("Resolved build on ring '{0}': {1}  [{2}]" -f $ring, $picked.build, $picked.title)
        return $picked
    }

    # --- <category> / <build number> ---------------------------------------
    # NOTE: the bare `latest` form is deliberately not supported - the
    # catalogue spans multiple product lines (Windows 11 / 10 / Server), so
    # "newest across everything" is ill-defined; callers specify a
    # category (product line) or a ring (channel) explicitly.
    if ($specLower -eq 'latest' -or $specLower -match '^latest[:@]') {
        $rewritten = $specLower -replace '^latest[:@]', ''
        if ($rewritten) {
            Fail ("The 'latest' keyword is not used - the spec form itself denotes the newest build. Write the category or ring directly: '{0}' becomes '{1}'" -f $spec, $rewritten)
        }
        Fail ("The 'latest' keyword is not used - the spec form itself denotes the newest build. Write a category (e.g. w11-25h2) or a ring (e.g. retail) directly. The bare form is also ill-defined: the catalogue spans multiple product lines.")
    }
    $query = $null
    $category = $null
    $exactBuild = $null
    if ($specLower -match '^(\d+\.\d+)$') {
        $exactBuild = $Matches[1]
        $query = ('q={0}&sort=1' -f (Get-UrlEncoded $exactBuild))
    } elseif ($specLower -match '^[a-z0-9][a-z0-9-]*$') {
        $category = $specLower
        $query = ('q=category%3A{0}&sort=1' -f (Get-UrlEncoded $category))
    } else {
        Fail ("Unrecognised build spec '{0}'. Use: <category> (e.g. w11-25h2) | <category>@<ring> (e.g. w11-24h2@retail) | <ring> (e.g. retail) | <build number> | <GUID> | uupdump URL" -f $spec)
    }

    $uri = "https://uupdump.net/known.php?$query"
    Write-Log ("Fetching build list: {0}" -f $uri)
    $resp = Invoke-UupRequest -Uri $uri -Warmup
    $html = [string]$resp.Content

    # Rows look like:
    #   <tr><td> <i ...></i>
    #   <a href="selectlang.php?id=GUID">TITLE</a>
    #   </td><td class="collapsing"> x64 </td><td class="collapsing"> 2026-.. UTC </td></tr>
    $rowPattern = '<a href="selectlang\.php\?id=([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})"\s*>\s*(.*?)\s*</a>'
    $matchesAll = [regex]::Matches($html, $rowPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($matchesAll.Count -eq 0) { Fail ("No builds found for spec '{0}' (query returned no rows)." -f $spec) }

    $picked = $null
    $skipped = 0
    foreach ($m in $matchesAll) {
        $title = ($m.Groups[2].Value -replace '\s+', ' ').Trim()
        # Only full builds qualify: their titles start with "Windows 11/10"
        # or "Windows Server" (this covers "Feature Update" entries too);
        # servicing entries (KB updates, critical OOBE updates, server
        # hotpatches) never start with "Windows".
        if ($title -notmatch '^Windows (?:\d|Server\b)') { $skipped++; continue }
        # Extract the arch cell that follows this row
        $after = $html.Substring($m.Index + $m.Length, [Math]::Min(400, $html.Length - $m.Index - $m.Length))
        $archCell = [regex]::Match($after, '</td><td class="collapsing">\s*(.*?)\s*</td>')
        $rowArch = if ($archCell.Success) { $archCell.Groups[1].Value.Trim().ToLowerInvariant() } else { '' }
        if ($rowArch -ne $archDisplay) { continue }
        $buildNo = [regex]::Match($title, '(\d{4,6}\.\d{1,5})').Groups[1].Value
        if ($exactBuild -and $buildNo -ne $exactBuild) { continue }
        $picked = @{ guid = $m.Groups[1].Value.ToLowerInvariant(); build = $buildNo; title = $title; arch = $archN; date = $null; category = $category }
        break
    }

    if (-not $picked) {
        Fail ("No full '{0}' build found for arch '{1}' ({2} servicing entries skipped). The category may only contain updates, or the arch is unavailable." -f $spec, $archN, $skipped)
    }
    if (-not $picked.build) {
        Fail ("Could not extract a build number from title '{0}'" -f $picked.title)
    }
    Write-Log ("Resolved build: {0}  [{1}]" -f $picked.build, $picked.title)
    return $picked
}

# ---------------------------------------------------------------------------
# Edition discovery: the 'all' wildcard resolves to whatever the build offers
# ---------------------------------------------------------------------------

function Get-UupAvailableEditions {
    <# Base editions offered by a build for a language - the edition[]
       checkbox values on the build's edition selection page. #>
    param(
        [Parameter(Mandatory)][string]$Guid,
        [Parameter(Mandatory)][string]$Language
    )
    $uri = ('https://uupdump.net/selectedition.php?id={0}&pack={1}' -f $Guid, $Language)
    Write-Log ("Discovering base editions: {0}" -f $uri)
    $resp = Invoke-UupRequest -Uri $uri
    $html = [string]$resp.Content
    $editions = @()
    foreach ($m in [regex]::Matches($html, '<input[^>]*type="checkbox"[^>]*name="edition\[\]"[^>]*value="([^"]+)"')) {
        $v = $m.Groups[1].Value.Trim().ToLowerInvariant()
        if ($v) { $editions += $v }
    }
    if ($editions.Count -eq 0) {
        Fail ("No base editions found for build {0} / language {1} - the edition selection page returned none. Check the build's uupdump pages." -f $Guid, $Language)
    }
    return @($editions | Sort-Object)
}

function Get-UupAvailableVirtualEditions {
    <# Virtual editions offered by a build - the virtualEditions[] checkbox
       values on the download page. May be empty when the build offers none;
       the caller decides whether that is acceptable. #>
    param(
        [Parameter(Mandatory)][string]$Guid,
        [Parameter(Mandatory)][string]$Language
    )
    $uri = ('https://uupdump.net/download.php?id={0}&pack={1}' -f $Guid, $Language)
    Write-Log ("Discovering virtual editions: {0}" -f $uri)
    $resp = Invoke-UupRequest -Uri $uri
    $html = [string]$resp.Content
    $virtual = @()
    foreach ($m in [regex]::Matches($html, '<input[^>]*type="checkbox"[^>]*name="virtualEditions\[\]"[^>]*value="([^"]+)"')) {
        $v = $m.Groups[1].Value.Trim()
        if ($v) { $virtual += $v }
    }
    # preserve the page's casing - the converter writes these values into
    # ConvertConfig.ini verbatim
    return @($virtual | Sort-Object)
}

function Resolve-UupEditionList {
    <# 'all' (or '*') expands to the build's base editions; otherwise the
       literal comma list is used. #>
    param(
        [AllowNull()][string]$EditionsInput,
        [Parameter(Mandatory)][string]$Guid,
        [Parameter(Mandatory)][string]$Language
    )
    if ($EditionsInput -and ($EditionsInput.Trim().ToLowerInvariant() -in @('all', '*'))) {
        return @(Get-UupAvailableEditions -Guid $Guid -Language $Language)
    }
    return @(ConvertTo-List $EditionsInput)
}

function Resolve-UupVirtualEditionList {
    <# 'all' (or '*') expands to the build's virtual editions; otherwise the
       literal comma list (case preserved - the converter expects page casing). #>
    param(
        [AllowNull()][string]$VirtualInput,
        [Parameter(Mandatory)][string]$Guid,
        [Parameter(Mandatory)][string]$Language
    )
    if ($VirtualInput -and ($VirtualInput.Trim().ToLowerInvariant() -in @('all', '*'))) {
        return @(Get-UupAvailableVirtualEditions -Guid $Guid -Language $Language)
    }
    if (-not $VirtualInput -or -not $VirtualInput.Trim()) { return @() }
    return @($VirtualInput.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# ---------------------------------------------------------------------------
# Tag computation. Tag layout:
#   <build>-<arch>-<lang>-<editions-sorted-joined-with-dash>[+ve][-<hash4>][suffix]
# +ve  = virtual editions were appended to the ISO
# -hh  = short hash of every conversion option that differs from the
#        built-in default combination (keeps tags unique per option set,
#        so repeat runs are naturally idempotent)
# ---------------------------------------------------------------------------

function Get-UupDefaultOptions {
    <# Built-in default combination of conversion options. #>
    return @{
        updates   = 'true'
        cleanup   = 'false'
        netfx3    = 'false'
        esd       = 'false'
        resetbase = 'false'; skipwinre = 'false'; lcuwinre  = 'false'; lcuexpand = 'false'
        updtbootfiles = 'false'; forcedism = 'false'; refesd = 'false'; skiplcumsu = 'false'
        skipedge  = 'false'; wim2swm = 'false'; skipiso = 'false'; disabledupdatingupgrade = 'false'
        skipapps  = 'false'; appslevel = '0'; stubappsfull = 'false'; customlist = 'false'
        vdeletedsource = 'false'; vpreserve = 'false'; vsorteditions = 'false'
        adddrivers = 'false'; drv_source = ''
    }
}

function Merge-UupOptions {
    <# Combines the top-level inputs (esd) and the free-form options map
       into one final option table with defaults applied. #>
    param(
        [hashtable]$Defaults,
        [AllowNull()][string]$EsdInput,
        [AllowNull()][System.Collections.IDictionary]$UserOptions
    )
    $final = @{}
    foreach ($k in $Defaults.Keys) { $final[$k] = [string]$Defaults[$k] }
    if ($EsdInput) { $final['esd'] = ([string]$EsdInput).Trim().ToLowerInvariant() }
    if ($UserOptions) {
        foreach ($k in $UserOptions.Keys) { $final[$k] = [string]$UserOptions[$k] }
    }
    return $final
}

function Get-UupTag {
    param(
        [Parameter(Mandatory)][string]$Build,
        [Parameter(Mandatory)][string]$Arch,
        [Parameter(Mandatory)][string]$Language,
        [Parameter(Mandatory)][string[]]$Editions,
        [AllowNull()][string[]]$VirtualEditions,
        [Parameter(Mandatory)][hashtable]$FinalOptions,
        [AllowNull()][string]$TagSuffix
    )
    $archN = Get-NormalizedArch $Arch
    $lang = $Language.Trim().ToLowerInvariant()
    # NOTE: never name this variable $editions - PowerShell variable names are
    # case-insensitive, and assigning to it would coerce the value back into
    # the [string[]] parameter type of the same name.
    $editionsJoined = @($Editions | Sort-Object) -join '-'
    if (-not $editionsJoined) { Fail 'At least one edition is required to compute a tag' }

    $tag = ('{0}-{1}-{2}-{3}' -f $Build, $archN, $lang, $editionsJoined)

    $virtual = @()
    if ($VirtualEditions) { $virtual = @($VirtualEditions | Where-Object { $_ }) }
    if ($virtual.Count -gt 0) { $tag += '+ve' }

    # Options that deviate from the default combination produce a hash suffix
    $defaults = Get-UupDefaultOptions
    $schema = Get-UupOptionSchema
    $diffs = @()
    foreach ($k in ($schema.Keys | Sort-Object)) {
        if (-not $schema[$k].tag) { continue }
        $finalVal = if ($FinalOptions.Contains($k)) { ([string]$FinalOptions[$k]).Trim().ToLowerInvariant() } else { '' }
        $defVal = if ($defaults.Contains($k)) { ([string]$defaults[$k]).Trim().ToLowerInvariant() } else { '' }
        if ($finalVal -ne $defVal) { $diffs += ('{0}={1}' -f $k, $finalVal) }
    }
    if ($diffs.Count -gt 0) {
        $tag += '-' + (Get-ShortHash (($diffs | Sort-Object) -join ';'))
    }

    if ($TagSuffix -and $TagSuffix.Trim()) {
        $suffix = $TagSuffix.Trim() -replace '[^A-Za-z0-9._-]', '-'
        $tag += '-' + $suffix
    }
    return $tag
}

