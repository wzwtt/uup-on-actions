<#
.SYNOPSIS
Phase 4 - Publish the ISO: compute digests, upload to buzzheavier.com,
create the GitHub release (checksums, manifest, optional split volumes),
and write the job summary.

.DESCRIPTION
  0. The finished ISO is mounted and verified: boot files present, and the
     image store carries exactly the number of image entries the selection
     implies (base plus virtual editions).
  1. SHA-256 of the produced ISO.
  2. With mirrors=release+buzzheavier: 7z split volumes of at most 1900 MB
      are produced, their integrity is tested with `7z t`, and they are
      attached as release assets (below the GitHub per-asset size limit).
  3. Whole-file PUT upload to https://w.buzzheavier.com/<filename>; the
      response digest is compared against the local digest. Mirror failure
      does not fail the build - the release is still created.
  4. GitHub release via `gh` with SHA256SUMS.txt, manifest.json and, when
      applicable, the split volumes.
#>
param(
    [string]$IsoPath = ''
)

$ErrorActionPreference = 'Stop'
$moduleDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $moduleDir 'Common.psm1') -Force

Write-Section 'Phase 4/5: publish'

$state = Get-State
$tag = $state.tag
$releaseState = if ($state.releaseState) { ([string]$state.releaseState).Trim().ToLowerInvariant() } else { 'release' }
if (-not $IsoPath) {
    if ($env:UUP_ISO_PATH) { $IsoPath = $env:UUP_ISO_PATH }
    else { Fail 'No ISO path known - did phase 3 run?' }
}
if (-not (Test-Path -LiteralPath $IsoPath)) { Fail "ISO not found at $IsoPath" }
$iso = Get-Item -LiteralPath $IsoPath

# --- 0. ISO integrity validation ----------------------------------------------
# A conversion can end in a structurally broken ISO (truncated store, missing
# boot files) while the process itself exits successfully; the digest alone
# would not notice. The image is therefore mounted and inspected before
# anything is published.
function Test-IsoIntegrity {
    param([Parameter(Mandatory)][string]$Path, [AllowNull()]$State)
    $mounted = $null
    try {
        try { $mounted = Mount-DiskImage -ImagePath $Path -Access ReadOnly -PassThru -ErrorAction Stop } catch {
            Fail ("The ISO could not be mounted for verification: {0}" -f $_.Exception.Message)
        }
        $vol = Get-Volume -DiskImage $mounted -ErrorAction SilentlyContinue
        if (-not $vol -or -not $vol.DriveLetter) { Fail 'The mounted ISO exposes no readable volume' }
        $root = ('{0}:\' -f $vol.DriveLetter)

        # boot chain
        foreach ($required in @('bootmgr', 'efi\boot', 'sources\boot.wim')) {
            if (-not (Test-Path -LiteralPath (Join-Path $root $required))) {
                Fail ("The ISO lacks the required boot entry '{0}' - the conversion produced a non-bootable image" -f $required)
            }
        }
        $efiBoot = @((Get-ChildItem -LiteralPath (Join-Path $root 'efi\boot') -File -ErrorAction SilentlyContinue) |
            Where-Object { $_.Name -match '^boot(x64|aa64)\.efi$' })
        if ($efiBoot.Count -eq 0) { Fail 'The ISO lacks an EFI boot loader (efi\boot\boot*.efi)' }

        # image store and image count
        $store = Get-ChildItem -LiteralPath (Join-Path $root 'sources') -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^install\.(wim|esd|swm)$' } | Select-Object -First 1
        if (-not $store) { Fail 'The ISO carries no sources\install.wim/.esd/.swm image store' }
        $dismOut = & dism.exe /English /Get-WimInfo ("/WimFile:{0}" -f $store.FullName) 2>&1
        $indices = [regex]::Matches(($dismOut | Out-String), '(?m)^Index\s*:\s*(\d+)')
        if ($indices.Count -eq 0) { Fail ("DISM could not read the image store: {0}" -f (($dismOut | Out-String).Trim())) }
        $imageCount = [int]($indices | ForEach-Object { [int]$_.Groups[1].Value } | Measure-Object -Maximum).Maximum
        $expected = 0
        if ($State) {
            $expected = @($State.editions).Count + @($State.virtualEditions).Count
        }
        Write-Log ("ISO inspection: image store '{0}', {1} image entries, boot chain present" -f $store.Name, $imageCount)
        if ($expected -gt 0 -and $imageCount -ne $expected) {
            Fail ("The image store carries {0} image entries but the selection implies {1} (base editions plus virtual editions) - some editions are missing from the image" -f $imageCount, $expected)
        }
        return $imageCount
    } finally {
        if ($mounted) { $null = Dismount-DiskImage -ImagePath $Path -ErrorAction SilentlyContinue }
    }
}

$imageCount = Test-IsoIntegrity -Path $IsoPath -State $state
Write-LogOk ("ISO integrity check passed ({0} image entries)" -f $imageCount)

# --- 1. hash ----------------------------------------------------------------------
Write-Log 'Computing SHA-256 of the ISO...'
$sha = Get-FileSha256 -Path $IsoPath
Write-Log ("SHA-256: {0}" -f $sha)

$outDir = $iso.DirectoryName
$sumsPath = Join-Path $outDir 'SHA256SUMS.txt'
('{0}  {1}' -f $sha, $iso.Name) | Set-Content -LiteralPath $sumsPath -Encoding ASCII

# --- 1b. release split volumes (mirrors=release+buzzheavier) ----------------------
$volumePaths = @()
if ($state.mirrors -eq 'release+buzzheavier') {
    Write-Section 'Creating release split volumes (mirrors=release+buzzheavier)'
    $drive = $iso.PSDrive
    $freeBytes = $drive.Free
    if ($freeBytes -lt ($iso.Length + 2GB)) {
        Fail ("Insufficient disk space for split volume creation: {0} GB free, {1} GB required" -f `
            [Math]::Round($freeBytes / 1GB, 1), [Math]::Round(($iso.Length + 2GB) / 1GB, 1))
    }
    $sevenZip = (Get-Command 7z.exe -CommandType Application -ErrorAction SilentlyContinue).Source
    if (-not $sevenZip) { $sevenZip = (Get-Command 7z -ErrorAction SilentlyContinue).Source }
    if (-not $sevenZip) { Fail '7z not found on PATH - cannot create release volumes' }
    $volBase = Join-Path $outDir ($iso.BaseName + '.7z')
    & $sevenZip a -t7z -mx0 -v1900m -y $volBase $IsoPath 2>&1 | ForEach-Object { Write-Log ("7z: {0}" -f $_) }
    if ($LASTEXITCODE -ne 0) { Fail "7z volume creation failed with exit code $LASTEXITCODE" }
    $volumePaths = @(Get-ChildItem -LiteralPath $outDir -Filter (($iso.BaseName) + '.7z.*') -File | Sort-Object Name)
    if ($volumePaths.Count -eq 0) { Fail '7z reported success but no volumes were created' }
    & $sevenZip t (Join-Path $outDir ($iso.BaseName + '.7z.001')) 2>&1 | ForEach-Object { Write-Log ("7z t: {0}" -f $_) }
    if ($LASTEXITCODE -ne 0) { Fail "7z reported the split archive as corrupt (exit code $LASTEXITCODE) - not publishing the volumes" }
    Write-LogOk 'Split archive integrity verified with 7z t'
    $volTotal = ($volumePaths | Measure-Object -Sum Length).Sum
    Write-LogOk ("Created {0} volume(s), {1} GB total" -f $volumePaths.Count, [Math]::Round($volTotal / 1GB, 2))
}

# --- 2. buzzheavier upload ----------------------------------------------------------
$buzzUrl = $null
$buzzUploadedAt = $null
$buzzError = $null
if ($state.mirrors -eq 'buzzheavier' -or $state.mirrors -eq 'release+buzzheavier') {
    Write-Log 'Uploading the ISO to buzzheavier (single-file PUT)...'
    $remoteName = Get-UrlEncoded $iso.Name
    $uploadUrl = ('https://w.buzzheavier.com/{0}' -f $remoteName)
    $respPath = Join-Path $outDir 'buzz_response.json'

    $curlCmds = @(Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue)
    if ($curlCmds.Count -eq 0) { Fail 'curl.exe not found on PATH' }
    $curl = $curlCmds[0].Source   # first match (Windows system curl.exe)
    $maxUploadAttempts = 2
    for ($attempt = 1; $attempt -le $maxUploadAttempts; $attempt++) {
        if ($attempt -gt 1) { Write-Log 'Re-trying buzzheavier upload (from scratch - no resume support)...'; Start-Sleep -Seconds 15 }
        & $curl -sS -f -X PUT `
            -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36' `
            -T $IsoPath $uploadUrl `
            --connect-timeout 30 --max-time 14400 `
            --retry 3 --retry-delay 15 --retry-all-errors `
            -o $respPath 2>&1 | ForEach-Object { Write-Log ("curl: {0}" -f $_) }
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $respPath)) {
            try {
                $respJson = (Get-Content -LiteralPath $respPath -Raw | ConvertFrom-Json)
                $fileId = $respJson.data.id
                if ($fileId) {
                    $buzzUrl = ('https://buzzheavier.com/{0}' -f $fileId)
                    $buzzUploadedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                    Write-LogOk ("buzzheavier URL: {0}" -f $buzzUrl)
                    if ($respJson.data.sha256) {
                        if ($respJson.data.sha256 -eq $sha) {
                            Write-LogOk 'Server-side sha256 matches the local hash - upload is intact.'
                        } else {
                            Write-LogWarn ("Server-side sha256 {0} differs from local {1} - the upload may be corrupt!" -f $respJson.data.sha256, $sha)
                        }
                    }
                    break
                }
                $buzzError = 'Response JSON did not contain data.id'
            } catch { $buzzError = "Response was not JSON: $($_.Exception.Message)" }
        } else {
            $buzzError = "curl exit code $LASTEXITCODE"
        }
        Write-LogWarn ("buzzheavier upload attempt {0}/{1} failed: {2}" -f $attempt, $maxUploadAttempts, $buzzError)
    }
} else {
    Write-Log 'buzzheavier mirror disabled (mirrors input) - skipping upload'
}

if (-not $buzzUrl) {
    Write-LogWarn ("Mirror upload failed: {0} - the release is created without a single-file ISO link." -f $buzzError)
    Write-Summary ("## :warning: Mirror upload failed`n`nbuzzheavier upload did not succeed ({0}). The release exists with checksums and metadata, but no single-file ISO download is available. Re-run the workflow to retry.`n" -f $buzzError)
}

# --- 3. manifest ---------------------------------------------------------------------
$runUrl = $null
if ($env:GITHUB_SERVER_URL -and $env:GITHUB_REPOSITORY -and $env:GITHUB_RUN_ID) {
    $runUrl = ('{0}/{1}/actions/runs/{2}' -f $env:GITHUB_SERVER_URL, $env:GITHUB_REPOSITORY, $env:GITHUB_RUN_ID)
}
$manifest = [ordered]@{
    tag            = $tag
    releaseState   = $releaseState
    build          = $state.build
    title          = $state.title
    guid           = $state.guid
    arch           = $state.arch
    language       = $state.language
    editions       = @($state.editions)
    virtualEditions = @($state.virtualEditions)
    options        = $state.options
    isoName        = $iso.Name
    isoSizeBytes   = $iso.Length
    isoSha256      = $sha
    imageEntries   = $imageCount
    buzzheavier     = if ($buzzUrl) { @{ url = $buzzUrl; uploadedAt = $buzzUploadedAt } } else { $null }
    releaseVolumes  = @(if ($volumePaths.Count -gt 0) {
        foreach ($v in $volumePaths) { [ordered]@{ name = $v.Name; sizeBytes = $v.Length; sha256 = (Get-FileSha256 $v.FullName) } }
    } else { @() })
    generatedAt    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    runUrl         = $runUrl
    source         = 'uupdump.net'
    disclaimer     = 'For evaluation purposes only. Not affiliated with or supported by Microsoft Corporation. Do not use for any purpose other than evaluation.'
}
$manifestPath = Join-Path $outDir 'manifest.json'
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

# --- 4. release body ------------------------------------------------------------------
$sizeGb = [Math]::Round($iso.Length / 1GB, 2)
$defaults = Get-UupDefaultOptions
$optionsNonDefault = @()
foreach ($k in ($state.options.PSObject.Properties.Name | Sort-Object)) {
    $v = ([string]$state.options.$k).Trim().ToLowerInvariant()
    $def = if ($defaults.Contains($k)) { ([string]$defaults[$k]).Trim().ToLowerInvariant() } else { '' }
    if ($v -ne $def) { $optionsNonDefault += ('{0}={1}' -f $k, $v) }
}

$body = @()
$body += ('| | |')
$body += ('|---|---|')
$body += ('| Windows build | {0} |' -f $state.build)
$body += ('| Title | {0} |' -f $state.title)
$body += ('| Arch | {0} |' -f $state.arch)
$body += ('| Language | {0} |' -f $state.language)
$body += ('| Editions | {0} |' -f (@($state.editions) -join ', '))
$body += ('| Virtual editions | {0} |' -f ($(if (@($state.virtualEditions).Count) { @($state.virtualEditions) -join ', ' } else { '-' })))
$body += ('| ISO | `{0}` ({1} GB) |' -f $iso.Name, $sizeGb)
$body += ('| Release state | {0} |' -f $releaseState)
$body += ('| Image entries | {0} |' -f $imageCount)
$body += ('| SHA-256 | `{0}` |' -f $sha)
$body += ''
$body += '## Download'
if ($buzzUrl) {
    $body += ('- **ISO image (buzzheavier):** {0}' -f $buzzUrl)
    $body += '- The linked file is the complete ISO image; no multi-part download or reassembly is required.'
    $body += '- Retention and retrieval of the mirror upload are governed by the policies of the hosting service. Automated mirror-retention maintenance is available through [Buzzheavier-Keeper](https://github.com/wzwtt/Buzzheavier-Keeper).'
} else {
    $body += '- :warning: Mirror upload failed for this run - no single-file ISO download is available. Re-run the workflow to retry.'
}
if ($volumePaths.Count -gt 0) {
    $body += ('- **Split volumes (release assets):** {0} file(s), each at most 1900 MB - `{1}.7z.001` … recover the original ISO with `7z x {1}.7z.001`; per-volume digests are recorded in `manifest.json`.' -f $volumePaths.Count, $iso.BaseName)
}
$body += ''
$body += '## Verify'
$body += ('``````')
$body += ('# PowerShell')
$body += ('Get-FileHash -Algorithm SHA256 {0}   # expect {1}' -f $iso.Name, $sha)
$body += ('``````')
$body += ''
$body += ('Checksum file: `SHA256SUMS.txt` - metadata: `manifest.json` (both attached below).')
$body += ''
$body += '## Non-default conversion options'
foreach ($o in $optionsNonDefault) { $body += ('- {0}' -f $o) }
if ($optionsNonDefault.Count -eq 0) { $body += '- none (all defaults)' }
$body += ''
if ($runUrl) { $body += ('Produced by workflow run: {0}' -f $runUrl) }
$body += ''
$body += '## Legal notice'
$body += 'The resulting image may be used **for evaluation purposes only**. It is not supported by Microsoft Corporation in any way. Not affiliated with Microsoft. Source: uupdump.net / Microsoft Update servers.'
$bodyPath = Join-Path $outDir 'release_body.md'
$body -join "`n" | Set-Content -LiteralPath $bodyPath -Encoding UTF8

# --- 5. create the release -------------------------------------------------------------
$targetSha = $env:GITHUB_SHA
if (-not $targetSha) { Fail 'GITHUB_SHA is not set - this script must run inside GitHub Actions' }
if (-not $env:GH_TOKEN -and -not $env:GITHUB_TOKEN) { Fail 'GH_TOKEN/GITHUB_TOKEN is not set - this script must run inside GitHub Actions' }
if (-not $env:GH_TOKEN) { $env:GH_TOKEN = $env:GITHUB_TOKEN }

$assets = @($sumsPath, $manifestPath)
if ($volumePaths.Count -gt 0) { $assets += @($volumePaths | ForEach-Object { $_.FullName }) }
$releaseArgs = @('release', 'create', $tag, '--target', $targetSha, '--title', $tag, '--notes-file', $bodyPath) + $assets
if ($releaseState -eq 'prerelease') { $releaseArgs += '--prerelease' }
if ($releaseState -eq 'draft') { $releaseArgs += '--draft' }
Write-Log ('gh release create ' + ($releaseArgs -join ' '))
& gh @releaseArgs
if ($LASTEXITCODE -ne 0) { Fail "gh release create failed with exit code $LASTEXITCODE" }
$releaseUrl = ('{0}/{1}/releases/tag/{2}' -f $env:GITHUB_SERVER_URL, $env:GITHUB_REPOSITORY, $tag)

# --- 6. summary --------------------------------------------------------------------------
$summaryVolumes = if ($volumePaths.Count -gt 0) { "`n| Release volumes | {0} x <=1900 MB |" -f $volumePaths.Count } else { '' }
Write-Summary ("## Published: `{0}``n`n| | |`n|---|---|`n| Release | [{1}]({1}) |`n| Release state | {2} |`n| ISO | {3} ({4} GB) |`n| SHA-256 | `{5}` |`n| buzzheavier | {6} |{7}`n" -f `
    $tag, $releaseUrl, $releaseState, $iso.Name, $sizeGb, $sha, `
    ($(if ($buzzUrl) { $buzzUrl } else { '(upload failed - see warning above)' })), $summaryVolumes)

Write-ActionOutput -Key 'releaseUrl' -Value $releaseUrl
Write-ActionOutput -Key 'buzzUrl' -Value $buzzUrl
Write-ActionOutput -Key 'sha256' -Value $sha

Write-LogOk ("Phase 4 complete: {0}" -f $releaseUrl)
exit 0
