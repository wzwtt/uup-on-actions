# UUP on Actions

[English](README.md) | [简体中文](README.zh-CN.md)

Construction of Windows installation media (ISO images) from Unified Update Platform (UUP) file sets, executed on GitHub Actions infrastructure.

## Overview

The pipeline operates entirely within a GitHub Actions Windows runner:

1. A build is resolved against the uupdump.net catalogue — either the newest full build, or one specified by category, build number, GUID, or URL.
2. The uupdump download package is generated at runtime by submitting the corresponding form parameters to the uupdump generation endpoint, then patched for unattended execution (elevation check and interactive prompts removed).
3. The UUP payload is retrieved from Microsoft delivery servers with aria2 and converted into a complete ISO image.
4. The image is verified before publication: it is mounted and checked for a complete boot chain, and the image store is confirmed to carry exactly the image entries the edition selection implies; then presence, minimum size and SHA-256 are checked.
5. The release is created and the image is mirrored.

The ISO image is transferred to the buzzheavier.com file hosting service as a single file; the GitHub release records the checksum, structured build metadata, and the download location. A scheduled monitoring workflow resolves configurable uupdump categories within a daily time window and dispatches builds for newly published builds; its configuration is version-controlled on a dedicated orphan branch (`watch`), so that the history of `main` remains confined to pipeline code. The repository contains pipeline code only; no build data or downloaded payloads are stored in git.

Produced images are intended for evaluation purposes only; see the [Legal notice](#legal-notice).

## Contents

1. [Workflows](#workflows)
2. [Manual build — input reference](#manual-build--input-reference)
3. [Advanced conversion options](#advanced-conversion-options)
4. [Release naming](#release-naming)
5. [Scheduled monitoring](#scheduled-monitoring)
6. [Published artifacts](#published-artifacts)
7. [Operational characteristics](#operational-characteristics)
8. [Error handling](#error-handling)
9. [Repository layout](#repository-layout)
10. [License](#license)
11. [Legal notice](#legal-notice)

## Workflows

| File | Trigger | Function |
|---|---|---|
| `.github/workflows/build-iso.yml` | manual (`workflow_dispatch`), or invoked by the watch workflow | A single build; all build parameters are exposed as inputs. |
| `.github/workflows/watch.yml` | `schedule` (three cycles a day) and manual | Resolves monitored uupdump targets, dispatches one concurrent build job per new target, and summarises the outcomes once all builds finish. |
| `.github/workflows/ci.yml` | `push`/`pull_request` on code changes; manual; weekly `schedule` | Runs the Pester unit-test suite; the weekly schedule (and manual dispatch with the `catalogue` input) additionally probes which catalogue categories currently provide full builds. |

```
workflow_dispatch ─┐
                   ├─ resolve ── idempotency check ── package generation ──
schedule (watch) ──┘                                            download & conversion ── verification ── publication
```

## Manual build — input reference

Ten inputs are defined for the manual run; the default combination selects the newest full build on the retail ring, `amd64`, `zh-cn`, professional edition. `arch`, `language`, `mirrors` and `release_state` are rendered as dropdown selections (their value sets are stable); the remaining inputs are text fields.

### `build`

The spec identifies a product line or an update channel explicitly; "newest" is implied by the form itself — a specific older build is requested by build number, GUID, or URL. The catalogue spans multiple product lines (Windows 11 / Windows 10 / Windows Server), so no cross-product-line "newest of everything" form exists.

| Form | Example | Semantics |
|---|---|---|
| `<category>` | `w11-25h2` | Newest full build within the given category. |
| `<ring>` | `retail` | Newest full build currently published on an update ring, resolved through uupdump's ring query (fetchupd.php) against Microsoft update servers. |
| `<category>@<ring>` | `w11-24h2@retail` | Newest full build of that product line on that ring — among the builds the ring currently serves, the one matching the category's product line. When the ring serves none, the run fails with the ring's current offerings. |
| `<build number>` | `26200.10075` | Build selected by exact build number. |
| `<GUID>` | `bb653e4f-2f06-4aa6-9994-d5c692e24009` | Direct reference to a uupdump build id. |
| URL | `https://uupdump.net/selectlang.php?id=…` | Any uupdump.net URL containing `id=<GUID>`; the GUID is extracted automatically. |

Rings accepted by the `<ring>` and `<category>@<ring>` forms (uupdump fetchupd.php values, with aliases):

| Ring | Meaning | Accepted aliases |
|---|---|---|
| `retail` | Public Release channel | `public`, `release` |
| `rp` | Release Preview channel | `preview`, `releasepreview` |
| `wif` | Insider Fast channel | `fast`, `insiderfast` |
| `wis` | Insider Slow channel | `slow`, `insiderslow` |
| `beta` | Beta channel | — |
| `canary` | Canary channel | — |

The ring query returns the current synchronisation state of the respective channel; among the returned entries the newest full build is selected. Full builds are identified by their titles (beginning with "Windows 11", "Windows 10" or "Windows Server"); servicing entries — cumulative and .NET updates, critical OOBE updates, server hotpatches — are excluded. For the `<category>@<ring>` form, the product-line match applies to the version designation in the entry title; insider ring entries whose titles carry no version designation are therefore matched by the bare `<ring>` form only.

Categories correspond to the filter on the uupdump Downloads page (that page is authoritative as categories evolve). Full builds appear under two title families — entries beginning with "Windows 11 / 10 / Server" and entries beginning with "Feature update to Windows …", the form the catalogue uses for the Windows 10 branches (e.g. `Feature update to Windows 10, version 1809 (17763.9487) amd64`). The table is verified by the catalogue health probe (`scripts/Probe-UupCategories.ps1`; last verified 2026-11-27):

| Category | Product line |
|---|---|
| `future` | Windows 11 Insider Preview, future platform (29xxx series) |
| `w11-26h2-experimental` | Windows 11 26H2, experimental channel |
| `w11-26h2` / `w11-26h1` | Windows 11 26H2 / 26H1 |
| `w11-25h2-beta` / `w11-25h2` | Windows 11 25H2, beta / stable |
| `w11-24h2-beta` / `w11-24h2` | Windows 11 24H2, beta / stable |
| `w11-23h2` / `w11-22h2` / `w11-21h2` | Windows 11 23H2 / 22H2 / 21H2 |
| `server-24h2` / `server-23h2` | Windows Server, by release year |
| `w10-22h2` / `w10-21h2` / `w10-1809` | Windows 10 22H2 / 21H2 / 1809 |

Two categories currently provide no full builds and are excluded from the table: `server-22h2` and `server-21h2`. Their catalogue entries are servicing-only (cumulative and .NET updates) — the server branches do not re-sync feature-update entries after their servicing moves to the cumulative channel, unlike the Windows 10 branches, whose feature-update entries keep being refreshed. A build spec against such a category fails at resolution with an explicit message naming the skipped servicing-entry count; builds of those branches can still be requested by build number or GUID while their entries remain in the catalogue.

### `arch`

| Value | Architecture | Accepted aliases |
|---|---|---|
| `amd64` | x64 | `x64` |
| `arm64` | ARM64 | `aarch64` |
| `x86` | 32-bit x86 | `i386`, `32` |

When `build` is given as a GUID or URL, a mismatch between the build's actual architecture and the `arch` input causes an immediate failure during resolution.

### `language`

A single uupdump language code (dropdown). The selection corresponds to the language list of uupdump builds: `zh-cn`, `zh-tw`, `en-us`, `en-gb`, `ja-jp`, `ko-kr`, `de-de`, `fr-fr`, `fr-ca`, `ru-ru`, `es-es`, `es-mx`, `pt-br`, `pt-pt`, `it-it`, `nl-nl`, `pl-pl`, `cs-cz`, `sv-se`, `da-dk`, `fi-fi`, `nb-no`, `et-ee`, `lv-lv`, `lt-lt`, `bg-bg`, `hr-hr`, `el-gr`, `hu-hu`, `ro-ro`, `sk-sk`, `sl-si`, `sr-latn-rs`, `uk-ua`, `he-il`, `ar-sa`, `th-th`, `tr-tr`, and `neutral` (any language). The set of languages available for a particular build is presented on that build's language selection page; an unsupported combination fails during package generation, before payload transfer begins, with the uupdump error message.

### `editions`

Comma-separated list of target editions; multiple editions are assembled into a single multi-edition image. These are the uupdump *base* editions — the checkbox set on the build's edition selection page (directly selectable sources, one image entry per edition). Education, Enterprise, IoT Enterprise and similar are not base editions; they belong to `virtual_editions`.

| Value | Edition |
|---|---|
| `core` | Windows Home |
| `coren` | Windows Home N (builds/market editions providing it) |
| `corecountryspecific` | Windows Home China (Chinese-language builds) |
| `professional` | Windows Pro |
| `professionaln` | Windows Pro N (builds/market editions providing it) |
| `serverstandard`, `serverdatacenter`, … | Server editions (Server branch builds) |

The available set varies per build and per language (e.g. the China edition appears only for Chinese builds, N editions only where applicable); the edition selection page of the build is authoritative. A `dry_run` invocation confirms that a combination is accepted.

`all` (or `*`) selects every base edition the build offers for the chosen language. The set is read from the build's edition selection page at run time, so the image carries whatever the build provides when it is assembled; the resolved set is recorded in the release notes and in `manifest.json`.

### `virtual_editions`

Comma-separated list of additional virtual editions, generated with DISM after conversion (uupdump `autodl=3` mode). Any non-empty value enables the feature; an empty value disables it. Virtual editions add selectable editions to the image without re-downloading the payload; the available set likewise varies per build and follows the "Select additional editions" checkbox set on the download page.

| Value | Edition |
|---|---|
| `CoreSingleLanguage` | Home Single Language |
| `ProfessionalWorkstation` | Pro for Workstations |
| `ProfessionalEducation` | Pro Education |
| `Education` | Education |
| `Enterprise` | Enterprise |
| `ServerRdsh` | Enterprise multi-session / Virtual Desktops |
| `IoTEnterprise` | IoT Enterprise |
| `IoTEnterpriseK` | IoT Enterprise Subscription |

`all` (or `*`) selects every virtual edition the download page offers for the build; the resolved set is recorded in the release notes and in `manifest.json`.

### `esd`

| Value | Effect |
|---|---|
| `false` (default) | `install.wim`; larger image, faster conversion, widest tool compatibility. |
| `true` | Solid `install.esd` compression; image approximately 1–1.5 GB smaller, conversion 10–20 minutes longer; some deployment tools do not support ESD mounting or editing. |

### `mirrors`

| Value | Behaviour |
|---|---|
| `buzzheavier` (default) | The ISO is uploaded as a single file; the release carries checksums and metadata. |
| `release+buzzheavier` | Additionally attaches 7z split volumes of at most 1900 MB as release assets (below the GitHub per-asset size limit), providing archival copies independent of the mirror. |

### `dry_run`

Validates the combination (package generation, plus per-edition queries against the uupdump API reporting file counts and estimated payload sizes) without transferring payload data.

### `release_state`

| Value | Effect |
|---|---|
| `release` (default) | The release is published. |
| `prerelease` | The release is marked as a pre-release. |
| `draft` | The release is created in draft state and requires manual publication. |

### `options`

Free-form overrides for individual conversion parameters; see the next section.

## Advanced conversion options

The `options` input accepts newline-separated `Key=Value` records. Keys are case-insensitive; boolean values accept `true/false/1/0/yes/no`. Keys are validated against a fixed whitelist — an unknown key terminates the run and reports the list of valid keys. Lines beginning with `#` are comments. All keys are written into the converter's `ConvertConfig.ini`.

### `[convert-UUP]` parameters

| Key | Default | Description |
|---|---|---|
| `updates` | `true` | Integrate current cumulative updates. |
| `cleanup` | `false` | Component cleanup (WinSxS compression); adds 20–40 minutes to conversion. |
| `netfx3` | `false` | Integrate .NET Framework 3.5. |
| `esd` | `false` | Solid compression; equivalent to the `esd` input (takes precedence). |
| `resetbase` | `false` | WinSxS reset base; updates cannot be uninstalled from the resulting image. |
| `wim2swm` | `false` | Emit split `.swm` files. |
| `skipiso` | `false` | Skip ISO packaging (WIM/ESD only). |
| `skipwinre` | `false` | Skip Windows Recovery Environment processing. |
| `lcuwinre` | `false` | Update WinRE with the LCU. |
| `lcuexpand` | `false` | Expand LCU MSU before integration. |
| `updtbootfiles` | `false` | Update boot files. |
| `forcedism` | `false` | Force DISM instead of wimlib. |
| `refesd` | `false` | Use ESD as the reference source. |
| `skiplcumsu` | `false` | Skip LCU MSU integration. |
| `skipedge` | `false` | Skip Microsoft Edge integration. |
| `disabledupdatingupgrade` | `false` | Disable setup dynamic upgrade. |
| `adddrivers` | `false` | Integrate drivers from `drv_source`. |
| `drv_source` | *(empty)* | Driver directory path on the runner. |

### `[Store_Apps]` parameters

| Key | Default | Description |
|---|---|---|
| `skipapps` | `false` | Skip Microsoft Store application integration. |
| `appslevel` | `0` | Application integration level (numeric). |
| `stubappsfull` | `false` | Install stub applications in full. |
| `customlist` | `false` | Enable the package's `CustomAppsList.txt` selection. |

### `[create_virtual_editions]` parameters

Effective when virtual editions are enabled.

| Key | Default | Description |
|---|---|---|
| `vdeletedsource` | `false` | Delete the source WIM after virtual conversion. |
| `vpreserve` | `false` | Preserve intermediate files. |
| `vsorteditions` | `false` | Sort virtual editions alphabetically. |

### Workflow-level keys

| Key | Default | Description |
|---|---|---|
| `force` | `false` | Rebuild when a release with the same tag exists: the existing release and tag are deleted before the build. |
| `tag_suffix` | *(empty)* | Append a custom suffix to the release tag. |

Example:

```
updates=true
cleanup=true
skipedge=true
tag_suffix=test
```

## Release naming

```
<build>-<arch>-<language>-<editions>[+ve][-<hash>][suffix]
```

| Component | Example | Presence |
|---|---|---|
| build number | `26200.10075` | Always |
| architecture | `amd64` | Always |
| language | `zh-cn` | Always |
| editions | `core-professional` | Always (alphabetically sorted) |
| `all` | `all` | The selection was given as `all`; the expanded set is recorded in the release notes |
| `+ve` | `+ve` | Virtual editions enabled |
| option hash | `-5ea0` | Any conversion option differing from the default combination; a four-hex-digit digest of the option set |
| suffix | `-hotfix` | `tag_suffix` supplied |

A run resolving to an existing tag terminates early; an existing release is only rebuilt when `force=true`. The tag is computed from the requested selection rather than from the expanded edition set, so that the watch cycle can derive the same tag without querying the edition list, and so that repeated cycles remain idempotent.

## Scheduled monitoring

`watch.yml` runs three times a day (01:00, 09:00 and 17:00 +0800). How often the catalogue is checked is a property of the cron cadence alone — there is no additional time-window gating; idempotent tags make overlapping cycles harmless, so the cadence can be adjusted freely in the workflow file.

### Configuration

The monitoring configuration is the file `uup-watch.json`, stored on the `watch` branch — an orphan branch sharing no history with `main`. The configuration is thereby version-controlled on an independent timeline: changes to it produce commits on `watch` only, and the history of `main` remains confined to pipeline code. Each cycle, the workflow fetches the file from the branch; a change therefore takes effect from the next cycle. Absent the branch or the file, the built-in defaults apply; a malformed configuration file terminates the cycle with the parser error, so that misconfiguration is surfaced rather than silently ignored.

```json
{
  "targets": [
    {
      "build": "retail",
      "arch": "amd64",
      "language": "zh-cn",
      "editions": "all",
      "virtual_editions": "all",
      "esd": "false",
      "mirrors": "buzzheavier",
      "options": "",
      "release_state": "release"
    },
    {
      "build": "beta",
      "arch": "amd64",
      "language": "en-us",
      "editions": "all",
      "virtual_editions": "all",
      "release_state": "prerelease"
    }
  ]
}
```

| Field | Required | Default | Description |
|---|---|---|---|
| `targets` | yes | *(see above)* | Monitoring targets; each target's fields correspond to the manual build inputs of the same names. |
| `targets[].build` | yes | — | Typically a ring (e.g. `retail`, `beta`) or `<category>@<ring>`; accepts every build spec form. |
| `targets[].arch` / `language` / `editions` | no | `amd64` / `zh-cn` / `professional` | As in the manual build; `editions` also accepts `all`. |
| `targets[].virtual_editions` | no | *(empty)* | As in the manual build; accepts `all`. |
| `targets[].esd` | no | `"false"` | String boolean. |
| `targets[].mirrors` | no | `buzzheavier` | As in the manual build. |
| `targets[].options` | no | *(empty)* | As in the manual build; multiple records encoded as `\n` within the JSON string. |
| `targets[].release_state` | no | `release` | `release` / `prerelease` / `draft`, as in the manual build. |

The configuration file resides at `watch:uup-watch.json` in the repository; the branch also carries a README describing its purpose.

### Dispatch and aggregation

A target is dispatched when the release tag computed for the resolved newest full build does not yet exist; existing tags suppress re-execution, which makes successive cycles idempotent. A target that cannot be resolved within a cycle (for example, due to a transient access challenge on the catalogue page) is skipped and re-evaluated in the following cycle.

Each queued target becomes a separate build job and therefore a separate runner; all queued targets start together rather than sharing one runner sequentially. Concurrency is the number of queued targets, bounded only by the concurrent-job limit of the account, so no parallelism setting exists in the configuration.

Once every build job has finished — successfully or not — an aggregation job collects the outcomes and writes one table to the run summary: for each planned target, the release state (`release` / `prerelease` / `draft`, or not published) and the release link. A tag that is absent from the table's published states indicates that its build did not complete; the corresponding job log carries the reason.

Manual invocation accepts one input: `plan_only` (default `false`) resolves and reports the targets in the run summary without dispatching builds.

## Published artifacts

Each build produces one release:

- `SHA256SUMS.txt` — the ISO SHA-256 digest.
- `manifest.json` — structured record: tag, release state, build, title, GUID, architecture, language, editions, virtual editions, effective options, ISO name, size, SHA-256, mirror URL and upload timestamp, release volumes (when applicable), generation timestamp, workflow run URL, data source, and the evaluation-use disclaimer.
- Release body — the metadata summary, checksum, retrieval instructions, non-default option summary, and legal notice.
- The buzzheavier URL of the single-file ISO.
- With `mirrors=release+buzzheavier`: volumes `<name>.7z.001` … (each at most 1900 MB). The original ISO is recovered with `7z x <name>.7z.001`; per-volume digests are recorded in `manifest.json`.

Retention and retrieval of the mirror upload are governed by the policies of the hosting service. Automated mirror-retention maintenance is available through [Buzzheavier-Keeper](https://github.com/wzwtt/Buzzheavier-Keeper).

## Operational characteristics

| Stage | Typical duration |
|---|---|
| Resolution, package generation, pre-flight | 2–4 min |
| Payload download | 10–25 min |
| Conversion | 40–90 min (shorter with `esd` and `cleanup` disabled) |
| Digest computation and mirror upload | 5–25 min |

Peak disk usage on the runner is 25–35 GB (payload, image, temporary files); free space is verified before conversion begins. The job timeout is 360 minutes. Windows runners are billed at twice the per-minute rate on private repositories.

## Error handling

| Condition | Handling |
|---|---|
| Non-429 client errors (HTTP 4xx) | Not retried; when uupdump returns an error page (e.g. an unsupported language or an invalid language/edition combination), its message is reported verbatim. |
| Rate limiting on uupdump (HTTP 429/403) | Exponential backoff (5/15/45 s), up to three attempts per request. |
| Multi-edition payload estimate (`dry_run`) | The metadata API accepts one edition per request; editions are queried individually (first six, when more are selected) and reported per edition, since shared files appear in every listing. |
| Cloudflare challenge on the catalogue page | Backoff and retry; on persistent failure the run terminates with remediation guidance (direct GUID/URL input bypasses the catalogue page); watch cycles skip the affected target. |
| Conversion failure | The download script is re-executed once; aria2 resumes from partial data. |
| ISO below 1 GiB | Rejected prior to publication as a suspected incomplete conversion. |
| Structurally broken image | The finished ISO is mounted before publication; missing boot files or an image store whose entry count does not match the edition selection terminate the run. |
| Split volumes (`release+buzzheavier`) | The archive is integrity-tested with `7z t` before it is attached; a corrupt archive is not published. |
| Mirror upload failure | The release is still created; the run summary records the error. The upload response digest is compared against the local digest to verify transfer integrity. |
| Invalid watch configuration file | The cycle terminates with the parser error; built-in defaults apply when the branch or file is absent. |
| Any step failure | `aria2_download.log` and `ConvertConfig.ini` are attached as an artifact retained for 7 days. |

## Repository layout

```
main branch:
.github/workflows/build-iso.yml    Build workflow (manual and called)
.github/workflows/watch.yml        Scheduled monitoring workflow
.github/workflows/ci.yml           Unit tests; weekly catalogue health probe
scripts/Common.psm1                Logging, HTTP retry, option schema, tag computation, catalogue resolution
scripts/Resolve-UupBuild.ps1      Stage 1 — input resolution and tag computation
scripts/New-UupPackage.ps1        Stage 2 — package generation, patching, dependency pre-fetch, pre-flight
scripts/Invoke-UupConvert.ps1     Stage 3 — payload download, conversion, verification
scripts/Publish-UupIso.ps1        Stage 4 — image verification, digest, mirror upload, release creation, summary
scripts/Watch-UupBuilds.ps1       Scheduled cycle — target resolution and matrix planning
scripts/Summarise-UupCycle.ps1    Scheduled cycle — outcome aggregation after the builds
scripts/Probe-UupCategories.ps1   Catalogue health probe — which categories still provide full builds
tests/Common.Tests.ps1            Pester unit tests for the pure logic in Common.psm1

watch branch (orphan):
uup-watch.json                     Scheduled-monitoring configuration
```

## License

Released under the [MIT License](LICENSE). The license applies to the pipeline code in this repository; images produced by the pipeline remain subject to the evaluation-only terms stated below.

## Legal notice

The images produced by this pipeline are for evaluation purposes only. They are not supported by Microsoft Corporation, and this project is not affiliated with Microsoft. Content is retrieved from uupdump.net and Microsoft update servers; the terms of those services apply.

> AI生成
