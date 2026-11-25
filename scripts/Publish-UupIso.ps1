<#
.SYNOPSIS
Phase 4 - Publish the ISO: hash it, upload to buzzheavier.com, create the
GitHub release with checksums + manifest, and write the job summary.

.DESCRIPTION
  1. SHA-256 of the produced ISO.
  2. Whole-file PUT upload to https://w.buzzheavier.com/<filename>
     (buzzheavier imposes no file-size cap; anonymous, no account needed).
     Mirror failure does NOT fail the build - the release still ships.
  3. GitHub release via `gh` containing SHA256SUMS.txt and manifest.json only
     (per project policy the ISO itself lives on the mirror, not in GitHub).
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
if (-not $IsoPath) {
    if ($env:UUP_ISO_PATH) { $IsoPath = $env:UUP_ISO_PATH }
    else { Fail 'No ISO path known - did phase 3 run?' }
}
if (-not (Test-Path -LiteralPath $IsoPath)) { Fail "ISO not found at $IsoPath" }
$iso = Get-Item -LiteralPath $IsoPath

# --- 1. hash ----------------------------------------------------------------------
Write-Log 'Computing SHA-256 of the ISO...'
$sha = Get-FileSha256 -Path $IsoPath
Write-Log ("SHA-256: {0}" -f $sha)

$outDir = $iso.DirectoryName
$sumsPath = Join-Path $outDir 'SHA256SUMS.txt'
('{0}  {1}' -f $sha, $iso.Name) | Set-Content -LiteralPath $sumsPath -Encoding ASCII

# --- 2. buzzheavier upload ----------------------------------------------------------
$buzzUrl = $null
$buzzUploadedAt = $null
$buzzError = $null
if ($state.mirrors -eq 'buzzheavier' -or $state.mirrors -eq 'release+buzzheavier') {
    Write-Log 'Uploading ISO to buzzheavier (anonymous PUT, no size cap)...'
    $remoteName = Get-UrlEncoded $iso.Name
    $uploadUrl = ('https://w.buzzheavier.com/{0}' -f $remoteName)
    $respPath = Join-Path $outDir 'buzz_response.json'

    $curl = (Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue).Source
    if (-not $curl) { $curlError = 'curl.exe not found'; }
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
    Write-LogWarn ("Mirror upload failed: {0} - the release will still be created with hashes only." -f $buzzError)
    Write-Summary ("## :warning: Mirror upload failed`n`nbuzzheavier upload did not succeed ({0}). The release still exists with checksums, but there is no downloadable ISO link. Re-run the workflow to retry.`n" -f $buzzError)
}

# --- 3. manifest ---------------------------------------------------------------------
$runUrl = $null
if ($env:GITHUB_SERVER_URL -and $env:GITHUB_REPOSITORY -and $env:GITHUB_RUN_ID) {
    $runUrl = ('{0}/{1}/actions/runs/{2}' -f $env:GITHUB_SERVER_URL, $env:GITHUB_REPOSITORY, $env:GITHUB_RUN_ID)
}
$manifest = [ordered]@{
    tag            = $tag
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
    buzzheavier     = if ($buzzUrl) { @{ url = $buzzUrl; uploadedAt = $buzzUploadedAt } } else { $null }
    generatedAt    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    runUrl         = $runUrl
    source         = 'uupdump.net'
    disclaimer     = 'For evaluation purposes only. Not affiliated with or supported by Microsoft Corporation. Do not use for any purpose other than evaluation.'
}
$manifestPath = Join-Path $outDir 'manifest.json'
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

# --- 4. release body ------------------------------------------------------------------
$sizeGb = [Math]::Round($iso.Length / 1GB, 2)
$optionsNonDefault = @()
foreach ($k in ($state.options.PSObject.Properties.Name | Sort-Object)) {
    $v = [string]$state.options.$k
    if ($v -notin @('false', '0', '') -and $k -ne 'esd') { $optionsNonDefault += ('{0}={1}' -f $k, $v) }
}
$esdLine = 'wim2esd (esd)=' + $state.options.esd

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
$body += ('| SHA-256 | `{0}` |' -f $sha)
$body += ''
$body += '## Download'
if ($buzzUrl) {
    $body += ('- **Full ISO (buzzheavier):** {0}' -f $buzzUrl)
    $body += '- No multi-part download, no re-joining needed - the file above is the complete ISO.'
    $body += '- Anonymous uploads on buzzheavier expire after 8 days of inactivity, but every download extends the lifetime by 2 days (up to 60 days; 60+ downloads in 30 days make it permanent).'
} else {
    $body += '- :warning: Mirror upload failed for this run - no ISO download available. Re-run the workflow to regenerate.'
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
$body += ('- {0}' -f $esdLine)
foreach ($o in $optionsNonDefault) { $body += ('- {0}' -f $o) }
if ($optionsNonDefault.Count -eq 0) { $body += '- none' }
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
if (-not $env:GITHUB_TOKEN) { Fail 'GITHUB_TOKEN is not set - this script must run inside GitHub Actions' }

$releaseArgs = @('release', 'create', $tag, '--target', $targetSha, '--title', $tag, '--notes-file', $bodyPath, $sumsPath, $manifestPath)
if (ConvertTo-Bool ([string]$state.draft)) { $releaseArgs += '--draft' }
Write-Log ('gh release create ' + ($releaseArgs -join ' '))
& gh @releaseArgs
if ($LASTEXITCODE -ne 0) { Fail "gh release create failed with exit code $LASTEXITCODE" }
$releaseUrl = ('{0}/{1}/releases/tag/{2}' -f $env:GITHUB_SERVER_URL, $env:GITHUB_REPOSITORY, $tag)

# --- 6. summary --------------------------------------------------------------------------
Write-Summary ("## Published: `{0}``n`n| | |`n|---|---|`n| Release | [{1}]({1}) |`n| ISO | {2} ({3} GB) |`n| SHA-256 | `{4}` |`n| buzzheavier | {5} |`n" -f `
    $tag, $releaseUrl, $iso.Name, $sizeGb, $sha, `
    ($(if ($buzzUrl) { $buzzUrl } else { '(upload failed - see warning above)' })))

Write-ActionOutput -Key 'releaseUrl' -Value $releaseUrl
Write-ActionOutput -Key 'buzzUrl' -Value $buzzUrl
Write-ActionOutput -Key 'sha256' -Value $sha

Write-LogOk ("Phase 4 complete: {0}" -f $releaseUrl)
exit 0
