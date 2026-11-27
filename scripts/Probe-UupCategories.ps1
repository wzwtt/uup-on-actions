<#
.SYNOPSIS
Catalogue health probe - checks which uupdump categories currently provide
full builds for download.

.DESCRIPTION
Full-build entries are identified by Test-UupFullBuildTitle (Windows/Server
prefixes and the "Feature update to Windows …" form that the Windows 10
branches use). A category whose entries are all servicing-only yields no
downloadable full build, and every build spec against it fails at resolution
time.

This script queries the catalogue page of each configured category and
reports, per category: total entries, full builds, servicing entries, the
architectures among the full builds, and the newest full build. Categories
without any full build are reported with a warning annotation, so the
documented category table can be kept in step with the catalogue.

The result is written to the step summary when running inside GitHub Actions
($env:GITHUB_STEP_SUMMARY) and to stdout otherwise. The script exits 0 in
every case - a category becoming servicing-only is an expected drift, not a
pipeline failure; transient access challenges are reported as unverified.

.PARAMETER Categories
Category slugs to probe. Defaults to the categories documented in the
repository README.

.EXAMPLE
./scripts/Probe-UupCategories.ps1
#>

param(
    [string[]]$Categories = @(
        'future', 'w11-26h2-experimental', 'w11-26h2', 'w11-26h1',
        'w11-25h2-beta', 'w11-25h2', 'w11-24h2-beta', 'w11-24h2',
        'w11-23h2', 'w11-22h2', 'w11-21h2',
        'server-24h2', 'server-23h2', 'server-22h2', 'server-21h2',
        'w10-22h2', 'w10-21h2', 'w10-1809'
    )
)

$ErrorActionPreference = 'Stop'
$moduleDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $moduleDir 'Common.psm1') -Force

Write-Section 'Catalogue health probe'
$rowPattern = '<a href="selectlang\.php\?id=([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})"\s*>\s*(.*?)\s*</a>'

$rows = @()
foreach ($cat in $Categories) {
    $uri = ('https://uupdump.net/known.php?q=category%3A{0}&sort=1' -f (Get-UrlEncoded $cat))
    $html = $null
    try {
        $resp = Invoke-UupRequest -Uri $uri -Warmup
        $html = [string]$resp.Content
    } catch {
        Write-LogWarn ("{0}: catalogue page could not be fetched ({1}) - reported as unverified" -f $cat, $_.Exception.Message)
        $rows += [pscustomobject]@{ Category = $cat; Entries = 'n/a'; FullBuilds = 'unverified'; Servicing = 'n/a'; Architectures = 'n/a'; Newest = '' }
        Start-Sleep -Seconds 3
        continue
    }
    $entries = [regex]::Matches($html, $rowPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $full = 0; $servicing = 0
    $archs = @{}
    $newest = ''
    foreach ($m in $entries) {
        $title = ($m.Groups[2].Value -replace '\s+', ' ').Trim()
        # same full-build rule as Find-UupBuild
        if (-not (Test-UupFullBuildTitle $title)) { $servicing++; continue }
        $full++
        $after = $html.Substring($m.Index + $m.Length, [Math]::Min(400, $html.Length - $m.Index - $m.Length))
        $archCell = [regex]::Match($after, '</td><td class="collapsing">\s*(.*?)\s*</td>')
        $rowArch = if ($archCell.Success) { $archCell.Groups[1].Value.Trim().ToLowerInvariant() } else { '?' }
        $archs[$rowArch] = $true
        if (-not $newest) { $newest = $title }
    }
    $archList = if ($archs.Keys.Count) { ($archs.Keys | Sort-Object) -join ', ' } else { '-' }
    $rows += [pscustomobject]@{ Category = $cat; Entries = $entries.Count; FullBuilds = $full; Servicing = $servicing; Architectures = $archList; Newest = $newest }
    Write-Log ("{0}: {1} entries, {2} full builds ({3})" -f $cat, $entries.Count, $full, $archList)
    if ($full -eq 0) {
        Write-LogWarn ("{0}: the category currently provides no downloadable full build - build specs against it fail at resolution" -f $cat)
        Write-Host ("::warning::Catalogue category '{0}' currently provides no downloadable full build - check whether it should be excluded from the documented category table." -f $cat)
    }
    Start-Sleep -Seconds 3
}

$table = "| Category | Entries | Full builds | Servicing | Architectures | Newest full build |`n|---|---|---|---|---|---|`n"
foreach ($r in $rows) {
    $table += ('| `{0}` | {1} | {2} | {3} | {4} | {5} |' -f $r.Category, $r.Entries, $r.FullBuilds, $r.Servicing, $r.Architectures, $r.Newest) + "`n"
}
$stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm UTC')
Write-Summary ("## Catalogue health probe`n`nProbed {0}: {1}`n`n{2}`n" -f $Categories.Count, $stamp, $table)
Write-LogOk 'Probe complete'
exit 0