<#
.SYNOPSIS
Watch phase - aggregate the outcomes of a cycle once every build job has
finished.

.DESCRIPTION
Runs after the build matrix in `watch.yml`. Each planned tag is looked up and
its release state (release / prerelease / draft, or not published) and URL are
reported in one table, so a cycle can be read without opening every job.
A tag missing from the release list indicates that its build did not complete;
the corresponding job log is the place to look.

Inputs:
  -Matrix   matrix JSON produced by Watch-UupBuilds.ps1 (or $env:UUP_MATRIX)
#>
param(
    [string]$Matrix = ''
)

$ErrorActionPreference = 'Stop'
$moduleDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $moduleDir 'Common.psm1') -Force

Write-Section 'Watch: cycle summary'

$raw = if ($Matrix) { $Matrix } elseif ($env:UUP_MATRIX) { $env:UUP_MATRIX } else { '' }
if (-not $raw) { Write-LogWarn 'No matrix supplied - nothing to summarise'; exit 0 }
try { $entries = @((($raw | ConvertFrom-Json)).include) } catch {
    Fail ('matrix output is not valid JSON: {0}' -f $_.Exception.Message)
}
if ($entries.Count -eq 0) { Write-Log 'No targets were queued this cycle'; exit 0 }

$repo = $env:GITHUB_REPOSITORY
$hasGh = [bool](Get-Command gh -ErrorAction SilentlyContinue)
$git = (Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue).Source
if (-not $git -and -not $hasGh) { Fail 'Neither gh nor git is available to look up the planned releases' }

$rows = @()
$counts = @{ release = 0; prerelease = 0; draft = 0; missing = 0; unknown = 0 }

foreach ($e in $entries) {
    $tag = [string]$e.tag
    $target = ('{0} ({1}, {2})' -f $e.build, $e.arch, $e.language)
    $state = 'not published'
    $url = ''

    $found = $false
    $isDraft = $false
    $isPre = $false
    if ($hasGh) {
        $out = & gh release view $tag --json isDraft,isPrerelease,url 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) {
            $rel = ([string]$out | ConvertFrom-Json)
            $found = $true
            $isDraft = [bool]$rel.isDraft
            $isPre = [bool]$rel.isPrerelease
            $url = [string]$rel.url
        }
    } elseif ($git) {
        $out = & $git ls-remote --tags origin ('refs/tags/{0}' -f $tag) 2>$null
        $found = ($null -ne $out -and (@($out).Count -gt 0) -and (("$out" | Out-String).Trim() -ne ''))
    }

    if ($found) {
        if (-not $hasGh) { $state = 'tag exists (state unknown)' }
        elseif ($isDraft) { $state = 'draft' }
        elseif ($isPre) { $state = 'prerelease' }
        else { $state = 'release' }
        if (-not $url -and $env:GITHUB_SERVER_URL -and $repo) {
            $url = ('{0}/{1}/releases/tag/{2}' -f $env:GITHUB_SERVER_URL, $repo, $tag)
        }
        $key = switch -Wildcard ($state) {
            'release' { 'release' }
            'prerelease' { 'prerelease' }
            'draft' { 'draft' }
            default { 'unknown' }
        }
        $counts[$key] = $counts[$key] + 1
        Write-Log ("{0}: {1}" -f $tag, $state)
    } else {
        $counts['missing'] = $counts['missing'] + 1
        Write-LogWarn ("{0}: no release was published - inspect the corresponding build job" -f $tag)
    }

    $rows += [pscustomobject]@{ Tag = $tag; Target = $target; State = $state; Url = $url }
}

$table = "| Tag | Target | Release state | Release |`n|---|---|---|---|`n"
foreach ($r in $rows) {
    $link = if ($r.Url) { ('[{0}]({0})' -f $r.Url) } else { '-' }
    $table += ('| `{0}` | {1} | {2} | {3} |' -f $r.Tag, $r.Target, $r.State, $link) + "`n"
}

$totals = 'Published {0}; pre-release {1}; draft {2}; not published {3}' -f `
    $counts['release'], $counts['prerelease'], $counts['draft'], $counts['missing']
if ($counts['unknown'] -gt 0) { $totals += ('; state unknown {0}' -f $counts['unknown']) }

$footer = ''
if ($env:GITHUB_SERVER_URL -and $repo -and $env:GITHUB_RUN_ID) {
    $footer = "`nThis cycle: {0}/{1}/actions/runs/{2}`n" -f $env:GITHUB_SERVER_URL, $repo, $env:GITHUB_RUN_ID
}

Write-Summary ("## Cycle summary`n`n{0}`n{1}`n{2}" -f $table, $totals, $footer)
Write-LogOk ("Cycle summary complete: {0}" -f $totals)
exit 0