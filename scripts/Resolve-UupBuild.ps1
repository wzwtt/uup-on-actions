<#
.SYNOPSIS
Phase 1 - Resolve a build spec into a concrete uupdump build and compute
the release tag + persisted job state.

.DESCRIPTION
Inputs (normally forwarded from the workflow, defaults for local testing):
  -BuildSpec       <category> | <ring> | <category>@<ring> | <build> | <GUID> | uupdump URL
  -Arch            amd64 / arm64 / x86
  -Language        uupdump language code (zh-cn, en-us, ...)
  -Editions        comma separated edition list ('all' = every base edition
                   the build offers)
  -VirtualEditions comma separated virtual editions ('all' = every virtual
                   edition the build offers; empty = disabled)
  -Esd             top-level esd input ('true'/'false')
  -Options         multi-line Key=Value options text
  -Mirrors         buzzheavier / release+buzzheavier
  -DryRun          'true'/'false'
  -Draft           'true'/'false'

Writes:
  - Action outputs: guid, build, title, tag
  - State file: full normalised input set for later phases
#>
param(
    [string]$BuildSpec = 'retail',
    [string]$Arch = 'amd64',
    [string]$Language = 'zh-cn',
    [string]$Editions = 'professional',
    [string]$VirtualEditions = '',
    [string]$Esd = 'false',
    [string]$Mirrors = 'buzzheavier',
    [string]$DryRun = 'false',
    [string]$Draft = 'false',
    [string]$Options = ''
)

$ErrorActionPreference = 'Stop'
$moduleDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $moduleDir 'Common.psm1') -Force

Write-Section 'Phase 1/5: resolve build'

# --- normalise inputs -------------------------------------------------------
$archN = Get-NormalizedArch $Arch
$language = $Language.Trim().ToLowerInvariant()
if (-not $language) { Fail 'language input is empty' }
if ($language -match '[,;]') {
    Fail ("language input must be a single uupdump language code; multiple values are not supported (got '{0}'). Check the language choices on the build's uupdump page." -f $language)
}
if ($language -notmatch '^[a-z]{2,3}(-[a-z]{2,8}(-[a-z]{2,8})?)?$') {
    Write-LogWarn ("language '{0}' does not look like a standard uupdump language code - continuing, the package generation will validate it" -f $language)
}
if ($Editions -and ($Editions.Trim().ToLowerInvariant() -notin @('all','*'))) {
    if (($Editions -replace '\s','') -match '(?:^|,)(?:$|,)') {
        Fail ("editions input '{0}' contains an empty element - remove empty entries between commas" -f $Editions)
    }
}
$optionsMap = ConvertFrom-OptionsText $Options
$esdBool = ConvertTo-Bool $Esd
$dryRunBool = ConvertTo-Bool $DryRun
$draftBool = ConvertTo-Bool $Draft
$mirrorsMode = $Mirrors.Trim().ToLowerInvariant()
if ($mirrorsMode -notin @('buzzheavier', 'release+buzzheavier')) {
    Fail ("Invalid mirrors '{0}' (expected 'buzzheavier' or 'release+buzzheavier')" -f $Mirrors)
}
$force = $false
if ($optionsMap.Contains('force')) { $force = ConvertTo-Bool ([string]$optionsMap['force']) }

# --- resolve the build ------------------------------------------------------
$found = Find-UupBuild -Spec $BuildSpec -Arch $archN
$buildNo = $found.build
if (-not $buildNo) {
    Write-LogWarn 'Build number unknown (GUID input without API metadata); using guid-derived id in tag'
    $buildNo = ('guid-' + $found.guid.Substring(0, 8))
}

# --- expand the edition selections against the build -------------------------
# 'all' resolves to the build's own checkbox set, so the image always carries
# every edition the build offers at run time.
$editionsList = Resolve-UupEditionList -EditionsInput $Editions -Guid $found.guid -Language $language
if ($editionsList.Count -eq 0) { Fail 'editions input is empty - provide at least one edition (or "all")' }
$virtualList = @(Resolve-UupVirtualEditionList -VirtualInput $VirtualEditions -Guid $found.guid -Language $language)
Write-Log ("Editions        : {0}" -f ($editionsList -join ', '))
Write-Log ("Virtual editions: {0}" -f ($(if ($virtualList.Count) { $virtualList -join ', ' } else { '(none)' })))

# --- final option set --------------------------------------------------------
$defaults = Get-UupDefaultOptions
$finalOptions = Merge-UupOptions -Defaults $defaults -EsdInput ([string]$esdBool) -UserOptions $optionsMap

# --- tag inputs ---------------------------------------------------------------
# The tag reflects the requested selection rather than the expanded set. The
# watch job computes tags without querying uupdump for the edition list, so both
# sides must derive the tag from the same information; the editions actually
# written into the image are recorded in the manifest and the release notes.
$tagEditions = $editionsList
$tagVirtual = @($virtualList)
if ($Editions -and ($Editions.Trim().ToLowerInvariant() -in @('all', '*'))) { $tagEditions = @('all') }
if ($VirtualEditions -and ($VirtualEditions.Trim().ToLowerInvariant() -in @('all', '*'))) { $tagVirtual = @('all') }

# --- tag ----------------------------------------------------------------------
$tagSuffix = ''
if ($optionsMap.Contains('tag_suffix')) { $tagSuffix = [string]$optionsMap['tag_suffix'] }
$tag = Get-UupTag -Build $buildNo -Arch $archN -Language $language -Editions $tagEditions `
    -VirtualEditions $tagVirtual -FinalOptions $finalOptions -TagSuffix $tagSuffix

Write-Log ("Build : {0}" -f $found.title)
Write-Log ("GUID  : {0}" -f $found.guid)
Write-Log ("Tag   : {0}" -f $tag)

# --- persist state ------------------------------------------------------------
$state = [ordered]@{
    guid            = $found.guid
    build           = $buildNo
    title           = $found.title
    arch            = $archN
    language        = $language
    editions        = $editionsList
    virtualEditions = $virtualList
    isVirtual       = ($virtualList.Count -gt 0)
    options         = $finalOptions
    esd             = (ConvertTo-Bool ([string]$finalOptions['esd']))
    mirrors         = $mirrorsMode
    dryRun          = $dryRunBool
    draft           = $draftBool
    force           = $force
    tagSuffix       = $tagSuffix
    tag             = $tag
}
Set-State -Data ([hashtable]$state)

Write-ActionOutput -Key 'guid' -Value $found.guid
Write-ActionOutput -Key 'build' -Value $buildNo
Write-ActionOutput -Key 'title' -Value $found.title
Write-ActionOutput -Key 'tag' -Value $tag
Write-ActionOutput -Key 'force' -Value ([string]$force)

Write-Summary ("## Build resolved`n`n| Field | Value |`n|---|---|`n| Title | {0} |`n| GUID | `{1}` |`n| Build | {2} |`n| Arch | {3} |`n| Language | {4} |`n| Editions | {5} |`n| Virtual editions | {6} |`n| Tag | `{7}` |`n" -f `
    $found.title, $found.guid, $buildNo, $archN, $language, ($editionsList -join ', '), `
    ($(if ($virtualList.Count) { $virtualList -join ', ' } else { '(none)' })), $tag)

Write-LogOk 'Phase 1 complete'
exit 0
