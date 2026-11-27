<#
.SYNOPSIS
Watch phase - decide which builds are new and need to be constructed.

.DESCRIPTION
Runs inside the scheduled `watch.yml` job (or manual watch dispatch):
  1. Reads the monitoring configuration from the file supplied by the
     workflow (fetched from the `watch` orphan branch); a missing file or
     branch falls back to the built-in defaults:
        { "window": "17:00-21:00+0800",
          "targets": [ { "build": "retail", "arch": "amd64",
                         "language": "zh-cn", "editions": "all",
                         "virtual_editions": "all",
                         "release_state": "release" }, ... ] }
  2. Checks the local time is inside the daily window.
  3. For every target resolves the build spec (category / ring / category@ring)
     to a concrete build and
     computes its tag. Targets whose release tag already exists are skipped
     (idempotent - no state files needed).
  4. Emits a GitHub Actions matrix: each queued target becomes its own build
     job and therefore runs on its own runner. All of them start together, so
     concurrency is the matrix size itself - there is no parallelism setting.

Failures to resolve a target (e.g. Cloudflare challenge on the list page)
SKIP that target and continue with the rest - a watch cycle must never
fail because of transient upstream issues. An invalid configuration file
however terminates the cycle, so that misconfiguration is surfaced.
#>
param(
    [string]$BypassWindow = 'false',
    [string]$ConfigPath = ''
)

$ErrorActionPreference = 'Stop'
$moduleDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $moduleDir 'Common.psm1') -Force

Write-Section 'Watch: check for new builds'

# --- default config -------------------------------------------------------------
$defaultConfig = [ordered]@{
    window      = '17:00-21:00+0800'
    targets     = @(
        @{ build = 'retail'; arch = 'amd64'; language = 'zh-cn'; editions = 'all'; virtual_editions = 'all'; release_state = 'release' },
        @{ build = 'retail'; arch = 'amd64'; language = 'en-us'; editions = 'all'; virtual_editions = 'all'; release_state = 'release' }
    )
}

$cfg = $null
$cfgSource = 'built-in default'
if (-not $ConfigPath -and $env:UUP_WATCH_FILE) { $ConfigPath = $env:UUP_WATCH_FILE }
if ($ConfigPath) {
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $cfgSource = ('configuration file {0}' -f $ConfigPath)
        } catch {
            Fail ('watch configuration is not valid JSON: {0}' -f $_.Exception.Message)
        }
    } else {
        Write-LogWarn ('configuration file {0} not found - built-in defaults apply' -f $ConfigPath)
    }
}
if (-not $cfg) { $cfg = $defaultConfig }

# --- time window -----------------------------------------------------------------
if (ConvertTo-Bool $BypassWindow) {
    Write-Log 'Window check bypassed (manual test run)'
} else {
    $win = [string]$cfg.window
    $gate = Test-UupWindow -Window $win -Now (Get-Date)
    $now = $gate.LocalNow
    Write-Log ("Config source: {0}; window {1} (current local time {2:HH:mm})" -f $cfgSource, $win, $now)
    if (-not $gate.InWindow) {
        Write-Log 'Outside the daily window - nothing to do.'
        Write-LogWarn ("No build was dispatched: the cycle is outside the activation window {0} and the current local time is {1:HH:mm}. Scheduled cycles only act inside the window; a manual dispatch passes bypass_window=true for this by default." -f $win, $now)
        Write-Host ("::warning::Outside the activation window {0} (local time {1:HH:mm}) - no build dispatched. Manual dispatch bypasses the window by default." -f $win, $now)
        Write-ActionOutput -Key 'count' -Value '0'
        Write-ActionOutput -Key 'matrix' -Value '{"include":[]}'
        Write-Summary ("## Watch`n`nNo build was dispatched: the cycle ran outside the configured activation window.`n`n| | |`n|---|---|`n| Window | {0} |`n| Current local time | {1:HH:mm} |`n`nScheduled cycles only act inside the window. A manual run bypasses it unless `bypass_window` is set to false.`n" -f $win, $now)
        exit 0
    }
}

# --- resolve targets ----------------------------------------------------------------
$repo = $env:GITHUB_REPOSITORY
if (-not $repo) { Fail 'GITHUB_REPOSITORY not set - must run inside GitHub Actions' }

$targets = @($cfg.targets)
if ($targets.Count -eq 0) { Fail 'Watch config has no targets' }

function Test-ReleaseExists {
    <# On CI: gh api (authoritative - checks the release itself).
       Locally: git ls-remote against origin (tags are only ever created by
       `gh release create`, so tag existence == release existence here). #>
    param([string]$Repo, [string]$Tag)
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        & gh api ('repos/{0}/releases/tags/{1}' -f $Repo, $Tag) *> $null
        return ($LASTEXITCODE -eq 0)
    }
    $git = (Get-Command git.exe -ErrorAction SilentlyContinue).Source
    if (-not $git) {
        foreach ($p in @('C:\Program Files\Git\cmd\git.exe', 'C:\Program Files (x86)\Git\cmd\git.exe', "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe")) {
            if (Test-Path $p) { $git = $p; break }
        }
    }
    if ($git) {
        $out = & $git ls-remote --tags origin ('refs/tags/{0}' -f $Tag) 2>$null
        return ($null -ne $out -and (@($out).Count -gt 0) -and (("$out" | Out-String).Trim() -ne ''))
    }
    Fail 'Neither gh nor git is available to check existing releases'
}

$include = @()
foreach ($t in $targets) {
    $spec = [string]$t.build
    $arch = if ($t.arch) { [string]$t.arch } else { 'amd64' }
    $language = if ($t.language) { [string]$t.language } else { 'zh-cn' }
    $editions = if ($t.editions) { [string]$t.editions } else { 'professional' }
    $virtual = if ($t.virtual_editions) { [string]$t.virtual_editions } else { '' }
    $esd = if ($t.esd) { [string]$t.esd } else { 'false' }
    $mirrors = if ($t.mirrors) { [string]$t.mirrors } else { 'buzzheavier' }
    $options = if ($t.options) { [string]$t.options } else { '' }
    $releaseState = if ($t.release_state) { ([string]$t.release_state).Trim().ToLowerInvariant() } else { 'release' }
    if ($releaseState -notin @('release', 'prerelease', 'draft')) {
        Fail ("Target '{0}': invalid release_state '{1}' (expected release / prerelease / draft)" -f $spec, $t.release_state)
    }

    Write-Log ("Target: {0} (arch={1}, lang={2}, editions={3})" -f $spec, $arch, $language, $editions)
    try {
        $found = Find-UupBuild -Spec $spec -Arch $arch
    } catch {
        Write-LogWarn ("Could not resolve '{0}' this cycle: {1} - skipping target" -f $spec, $_.Exception.Message)
        continue
    }
    if (-not $found.build) {
        Write-LogWarn ("Build number for '{0}' could not be determined - skipping target" -f $spec)
        continue
    }

    $editionsList = ConvertTo-List $editions
    $virtualList = @(ConvertTo-List $virtual)
    $optionsMap = ConvertFrom-OptionsText $options
    $defaults = Get-UupDefaultOptions
    $finalOptions = Merge-UupOptions -Defaults $defaults -EsdInput $esd -UserOptions $optionsMap
    $tagSuffix = ''
    if ($optionsMap.Contains('tag_suffix')) { $tagSuffix = [string]$optionsMap['tag_suffix'] }
    $tag = Get-UupTag -Build $found.build -Arch $arch -Language $language -Editions $editionsList `
        -VirtualEditions $virtualList -FinalOptions $finalOptions -TagSuffix $tagSuffix

    # idempotency: does the release already exist?
    $exists = Test-ReleaseExists -Repo $repo -Tag $tag
    if ($exists) {
        Write-Log ("  -> {0}: already published, skipping" -f $tag)
        continue
    }
    Write-Log ("  -> {0}: NEW, queueing build" -f $tag)
    $include += [ordered]@{
        build            = $spec
        arch             = $arch
        language         = $language
        editions         = $editions
        virtual_editions = $virtual
        esd              = $esd
        mirrors          = $mirrors
        options          = $options
        release_state    = $releaseState
        tag              = $tag
        title            = $found.title
    }
}

$count = [string]$include.Count
$matrixJson = (@{ include = $include } | ConvertTo-Json -Depth 8 -Compress)
# Every queued target becomes its own job on its own runner; the number of
# concurrent jobs follows the matrix size, so no parallelism setting is needed
# (or accepted).
if ($cfg.PSObject.Properties.Name -contains 'max_parallel') {
    Write-LogWarn 'max_parallel in the watch configuration is ignored - each target runs on its own runner and the matrix size determines the concurrency'
}

Write-ActionOutput -Key 'count' -Value $count
Write-ActionOutput -Key 'matrix' -Value $matrixJson

Write-Log ("New builds this cycle: {0}" -f $count)
if ($count -ne '0') {
    foreach ($i in $include) { Write-Log ("  queue: {0} ({1})" -f $i.tag, $i.title) }
}

$summary = "## Watch cycle`n`nConfig source: **{0}**`n`nNew builds: **{1}**`n`n" -f $cfgSource, $count
if ($include.Count -gt 0) {
    $summary += "| Tag | Target | Title |`n|---|---|---|`n"
    foreach ($i in $include) {
        $summary += ("| `{0}` | `{1}` | {2} |`n" -f $i.tag, $i.build, $i.title)
    }
} else {
    $summary += "Nothing new to build.`n"
}
if (ConvertTo-Bool ([string]$env:UUP_PLAN_ONLY)) {
    $summary += "`nPlan-only run: the targets above were resolved and reported, no build job was dispatched.`n"
}
Write-Summary $summary
exit 0
