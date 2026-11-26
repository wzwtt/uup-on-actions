# UUP on Actions

[English](README.md) | [简体中文](README.zh-CN.md)

在 GitHub Actions 运行环境中，基于统一更新平台（Unified Update Platform，UUP）文件集自动构建 Windows 安装介质（ISO 镜像）。

## 概述

流水线完整运行于 GitHub Actions 的 Windows 运行器之上：

1. 依据 uupdump.net 目录解析目标构建——可为最新的完整构建，或按分类、构建号、GUID、URL 指定。
2. 在运行时向 uupdump 生成端点提交相应表单参数以生成下载包，并对脚本进行无人值守化修补（移除提权检查与交互提示）。
3. 使用 aria2 从微软分发服务器获取 UUP 文件集，并转换为完整 ISO 镜像。
4. 校验镜像（存在性、最小体积、SHA-256）并发布。

ISO 镜像以单一文件形式传输至 buzzheavier.com 文件托管服务；GitHub Release 记录校验值、结构化构建元数据及下载位置。定时监测工作流在每日设定时间窗口内解析受监测的 uupdump 分类，并对新出现的构建派发构建任务；其配置受版本控制并存放于专用孤儿分支（`watch`），使 `main` 分支的历史仅包含流水线代码。仓库不存放任何构建数据或已下载的载荷。

产出镜像仅限评估用途，详见[法律声明](#法律声明)。

## 目录

1. [工作流](#工作流)
2. [手动构建——输入字段参考](#手动构建输入字段参考)
3. [高级转换选项](#高级转换选项)
4. [Release 命名](#release-命名)
5. [定时监测](#定时监测)
6. [发布产物](#发布产物)
7. [运行特征](#运行特征)
8. [错误处理](#错误处理)
9. [仓库结构](#仓库结构)
10. [许可证](#许可证)
11. [法律声明](#法律声明)

## 工作流

| 文件 | 触发条件 | 功能 |
|---|---|---|
| `.github/workflows/build-iso.yml` | 手动（`workflow_dispatch`）或由监测工作流调用 | 单次构建；全部构建参数以输入形式开放。 |
| `.github/workflows/watch.yml` | `schedule`（两小时间隔）及手动 | 解析受监测的 uupdump 分类，并为新出现的构建派发构建任务。 |

```
手动触发 ─┐
          ├─ 解析 ── 幂等检查 ── 下载包生成 ── 载荷下载与转换 ── 校验 ── 发布
定时监测 ─┘
```

## 手动构建——输入字段参考

手动运行共定义十项输入；默认组合选择 retail 通道最新的完整构建、`amd64`、`zh-cn`、专业版。`arch`、`language` 与 `mirrors` 呈现为下拉选择（取值集合稳定）；其余输入为文本字段。

### `build`

spec 显式指定产品线或更新通道；“最新”内在于形式本身——需要较旧的具体构建时，以构建号、GUID 或 URL 指定。目录覆盖多条产品线（Windows 11 / Windows 10 / Windows Server），故不存在跨产品线的“全目录最新”形式。

| 形式 | 示例 | 语义 |
|---|---|---|
| `<category>` | `w11-25h2` | 指定分类内最新的完整构建。 |
| `<ring>` | `retail` | 指定更新通道上当前发布的最新完整构建；经 uupdump 的通道查询（fetchupd.php）向微软更新服务器解析。 |
| `<category>@<ring>` | `w11-24h2@retail` | 指定产品线在该通道上的最新完整构建——在通道当前发布的构建中选取与分类产品线匹配者；通道未发布该产品线时，运行失败并告知通道当前内容。 |
| `<构建号>` | `26200.10075` | 按构建号精确匹配。 |
| `<GUID>` | `bb653e4f-2f06-4aa6-9994-d5c692e24009` | 直接引用 uupdump 构建编号。 |
| URL | `https://uupdump.net/selectlang.php?id=…` | 任意含 `id=<GUID>` 的 uupdump.net 链接；GUID 被自动提取。 |

`<ring>` 与 `<category>@<ring>` 形式接受的通道（uupdump fetchupd.php 取值及别名）：

| 通道 | 含义 | 接受的别名 |
|---|---|---|
| `retail` | 正式发布（Public Release）通道 | `public`、`release` |
| `rp` | Release Preview 通道 | `preview`、`releasepreview` |
| `wif` | Insider Fast 通道 | `fast`、`insiderfast` |
| `wis` | Insider Slow 通道 | `slow`、`insiderslow` |
| `beta` | Beta 通道 | — |
| `canary` | Canary 通道 | — |

通道查询返回相应通道当前的同步更新状态；在返回条目中选取最新的完整构建。完整构建依标题判定（以 "Windows 11"、"Windows 10" 或 "Windows Server" 开头）；服务性条目——累积更新、.NET 更新、Critical OOBE 更新、服务器热修补——被排除。`<category>@<ring>` 形式按条目标题中的版本号判定产品线匹配；标题不含版本号的 Insider 通道条目仅适用于 `<ring>` 形式。

分类与 uupdump 下载页的筛选器一致（该页面为权威来源，分类可能随时间演进）。当前取值：

| 分类 | 分支 |
|---|---|
| `future` | 开发通道 |
| `w11-26h2-experimental` | Windows 11 26H2，实验通道 |
| `w11-26h2` / `w11-26h1` | Windows 11 26H2 / 26H1 |
| `w11-25h2-beta` / `w11-25h2` | Windows 11 25H2，测试 / 稳定 |
| `w11-24h2-beta` / `w11-24h2` | Windows 11 24H2，测试 / 稳定 |
| `w11-23h2` / `w11-22h2` / `w11-21h2` | Windows 11 23H2 / 22H2 / 21H2 |
| `server-24h2` / `server-23h2` / `server-22h2` / `server-21h2` | Windows Server，按发布年度 |
| `w10-22h2` / `w10-21h2` / `w10-1809` | Windows 10 22H2 / 21H2 / 1809 |

### `arch`

| 取值 | 架构 | 接受的别名 |
|---|---|---|
| `amd64` | x64 | `x64` |
| `arm64` | ARM64 | `aarch64` |
| `x86` | 32 位 x86 | `i386`、`32` |

当 `build` 以 GUID 或 URL 形式给出时，构建的实际架构与 `arch` 输入不符将在解析阶段立即失败。

### `language`

单一 uupdump 语言代码（下拉选择）。取值集合与 uupdump 构建的语言列表一致：`zh-cn`、`zh-tw`、`en-us`、`en-gb`、`ja-jp`、`ko-kr`、`de-de`、`fr-fr`、`fr-ca`、`ru-ru`、`es-es`、`es-mx`、`pt-br`、`pt-pt`、`it-it`、`nl-nl`、`pl-pl`、`cs-cz`、`sv-se`、`da-dk`、`fi-fi`、`nb-no`、`et-ee`、`lv-lv`、`lt-lt`、`bg-bg`、`hr-hr`、`el-gr`、`hu-hu`、`ro-ro`、`sk-sk`、`sl-si`、`sr-latn-rs`、`uk-ua`、`he-il`、`ar-sa`、`th-th`、`tr-tr`、`vi-vn`、`id-id`，以及 `neutral`（任意语言）。特定构建可用的语言集合以其语言选择页为准；不受支持的组合在下载包生成阶段失败，早于载荷传输，并附 uupdump 的错误信息。

### `editions`

以逗号分隔的目标版本列表；多个版本被组装为单一多版本镜像。

| 取值 | 版本 |
|---|---|
| `professional` | Windows 专业版 |
| `core` | Windows 家庭版 |
| `corecountryspecific` | Windows 家庭中文版 |
| `coren` / `professionaln` | 家庭 N 版 / 专业 N 版 |
| `education` / `educationn` | 教育版 |
| `enterprise` / `enterprisen` | 企业版 |
| `iotenterprise` | IoT 企业版 |
| `serverstandard`、`serverdatacenter` 等 | Server 系列版本（适用于 Server 分支构建） |

特定构建支持的版本集合可通过 `dry_run` 调用确认。

### `virtual_editions`

以逗号分隔的附加虚拟版本列表，在转换后经 DISM 生成（对应 uupdump 的 `autodl=3` 模式）。任何非空取值启用该特性；空值表示禁用。

| 取值 | 版本 |
|---|---|
| `CoreSingleLanguage` | 家庭单语言版 |
| `ProfessionalWorkstation` | 专业工作站版 |
| `ProfessionalEducation` | 专业教育版 |
| `Education` | 教育版 |
| `Enterprise` | 企业版 |
| `ServerRdsh` | 企业多会话 / 虚拟桌面版 |
| `IoTEnterprise` | IoT 企业版 |

### `esd`

| 取值 | 效果 |
|---|---|
| `false`（默认） | `install.wim`；镜像较大、转换较快，工具兼容性最广。 |
| `true` | `install.esd` 固实压缩；镜像减小约 1–1.5 GB，转换延长 10–20 分钟；部分部署工具不支持 ESD 的挂载与编辑。 |

### `mirrors`

| 取值 | 行为 |
|---|---|
| `buzzheavier`（默认） | ISO 以单一文件上传；Release 载有校验值与元数据。 |
| `release+buzzheavier` | 额外以不超过 1900 MB 的 7z 分卷作为 Release 资产（低于 GitHub 单资产体积上限），提供独立于镜像托管的存档副本。 |

### `dry_run`

在不传输载荷数据的前提下验证组合（生成下载包，并向 uupdump API 查询文件数与预计载荷体积）。

### `draft`

Release 以草稿状态创建，需手动发布。

### `options`

对逐项转换参数的自由形式覆盖；见下一节。

## 高级转换选项

`options` 输入接受以换行分隔的 `Key=Value` 记录。键名不区分大小写；布尔值接受 `true/false/1/0/yes/no`。键依据固定白名单校验——未知键将终止运行并列出全部合法键。以 `#` 起始的行视为注释。全部键写入转换器的 `ConvertConfig.ini`。

### `[convert-UUP]` 段参数

| 键 | 默认 | 说明 |
|---|---|---|
| `updates` | `true` | 集成当前累积更新。 |
| `cleanup` | `false` | 组件清理（WinSxS 压缩）；转换时间增加 20–40 分钟。 |
| `netfx3` | `false` | 集成 .NET Framework 3.5。 |
| `esd` | `false` | 固实压缩；与 `esd` 输入等价（此处优先）。 |
| `resetbase` | `false` | WinSxS 重置基；产出的镜像不再支持卸载已集成更新。 |
| `wim2swm` | `false` | 输出拆分的 `.swm` 文件。 |
| `skipiso` | `false` | 跳过 ISO 打包（仅产出 WIM/ESD）。 |
| `skipwinre` | `false` | 跳过 Windows 恢复环境处理。 |
| `lcuwinre` | `false` | 以 LCU 更新 WinRE。 |
| `lcuexpand` | `false` | 集成前展开 LCU MSU。 |
| `updtbootfiles` | `false` | 更新引导文件。 |
| `forcedism` | `false` | 强制使用 DISM 替代 wimlib。 |
| `refesd` | `false` | 以 ESD 作为引用源。 |
| `skiplcumsu` | `false` | 跳过 LCU MSU 集成。 |
| `skipedge` | `false` | 跳过 Microsoft Edge 集成。 |
| `disabledupdatingupgrade` | `false` | 禁用安装程序的动态升级。 |
| `adddrivers` | `false` | 集成 `drv_source` 指定的驱动。 |
| `drv_source` | （空） | 运行器上的驱动目录路径。 |

### `[Store_Apps]` 段参数

| 键 | 默认 | 说明 |
|---|---|---|
| `skipapps` | `false` | 跳过 Microsoft Store 应用集成。 |
| `appslevel` | `0` | 应用集成级别（数值）。 |
| `stubappsfull` | `false` | 完整安装 Stub 应用。 |
| `customlist` | `false` | 启用包内 `CustomAppsList.txt` 选择。 |

### `[create_virtual_editions]` 段参数

启用虚拟版本时生效。

| 键 | 默认 | 说明 |
|---|---|---|
| `vdeletedsource` | `false` | 虚拟转换后删除源 WIM。 |
| `vpreserve` | `false` | 保留中间文件。 |
| `vsorteditions` | `false` | 虚拟版本按字母排序。 |

### 工作流级键

| 键 | 默认 | 说明 |
|---|---|---|
| `force` | `false` | 同名 Release 存在时强制重建：先删除既有 Release 与标签再构建。 |
| `tag_suffix` | （空） | 为 Release 标签附加自定义后缀。 |

示例：

```
updates=true
cleanup=true
skipedge=true
tag_suffix=test
```

## Release 命名

```
<build>-<arch>-<language>-<editions>[+ve][-<hash>][suffix]
```

| 组成 | 示例 | 出现条件 |
|---|---|---|
| 构建号 | `26200.10075` | 恒有 |
| 架构 | `amd64` | 恒有 |
| 语言 | `zh-cn` | 恒有 |
| 版本 | `core-professional` | 恒有（按字母排序） |
| `+ve` | `+ve` | 启用虚拟版本 |
| 选项哈希 | `-5ea0` | 任一转换选项偏离默认组合时出现；为选项集的四位十六进制摘要 |
| 后缀 | `-hotfix` | 提供了 `tag_suffix` |

解析结果与既有标签一致的运行将提前终止；仅当 `force=true` 时对既有 Release 予以重建。

## 定时监测

`watch.yml` 以两小时间隔调度。GitHub Actions 的 cron 表达式不支持按次参数化且可能漂移，故规划脚本依据配置执行自身的时间窗口判定。

### 配置

监测配置为文件 `uup-watch.json`，存放于 `watch` 分支——与 `main` 不共享历史的孤儿分支。由此，配置在其独立时间线上受版本控制：对其的变更仅在 `watch` 分支产生提交，`main` 分支的历史仅包含流水线代码。工作流在每周期从该分支获取配置文件；变更自下一周期生效。分支或文件缺失时采用内置默认值；配置文件格式非法时，该周期以解析错误终止，从而使配置错误得以暴露而非被静默忽略。

```json
{
  "window": "17:00-21:00+0800",
  "max_parallel": 2,
  "targets": [
    {
      "build": "w11-25h2",
      "arch": "amd64",
      "language": "zh-cn",
      "editions": "professional",
      "virtual_editions": "",
      "esd": "false",
      "mirrors": "buzzheavier",
      "options": "",
      "draft": "false"
    },
    {
      "build": "w11-24h2",
      "arch": "amd64",
      "language": "zh-cn",
      "editions": "professional,core",
      "options": "esd=true"
    }
  ]
}
```

| 字段 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `window` | 否 | `17:00-21:00+0800` | 每日生效窗口，`HH:MM-HH:MM±偏移`；支持跨零点窗口（如 `22:00-06:00+0800`）。 |
| `max_parallel` | 否 | `2` | 每周期内并发构建任务的上限。 |
| `targets` | 是 | （见上文） | 监测目标数组；各目标字段与手动构建同名输入一一对应。 |
| `targets[].build` | 是 | — | 通常为分类（如 `w11-25h2`）或 `<category>@<ring>`；接受全部构建 spec 形式。 |
| `targets[].arch` / `language` / `editions` | 否 | `amd64` / `zh-cn` / `professional` | 同手动构建。 |
| `targets[].virtual_editions` | 否 | （空） | 同手动构建。 |
| `targets[].esd` | 否 | `"false"` | 字符串布尔值。 |
| `targets[].mirrors` | 否 | `buzzheavier` | 同手动构建。 |
| `targets[].options` | 否 | （空） | 同手动构建；多条记录以 JSON 字符串内的 `\n` 编码。 |
| `targets[].draft` | 否 | `"false"` | 字符串布尔值。 |

配置文件位于仓库中的 `watch:uup-watch.json`；该分支另载有说明其用途的 README。

### 派发语义

当解析得到的最新完整构建对应的 Release 标签尚不存在时，该目标被派发执行；既有标签抑制重复执行，使相邻周期间的判定具有幂等性。某一周期内无法解析的目标（例如目录页出现瞬时访问质询）被跳过，并在下一周期重新评估。

监测工作流的手动调用接受 `bypass_window` 输入，用于在窗口外进行测试性评估。

## 发布产物

每次构建产生一个 Release：

- `SHA256SUMS.txt` —— ISO 的 SHA-256 摘要。
- `manifest.json` —— 结构化记录：标签、构建号、标题、GUID、架构、语言、版本、虚拟版本、生效选项、ISO 文件名、体积、SHA-256、镜像 URL 与上传时间戳、分卷信息（如适用）、生成时间戳、工作流运行链接、数据来源，以及评估用途声明。
- Release 正文 —— 元数据摘要、校验值、获取说明、非默认选项汇总与法律声明。
- 单一文件 ISO 的 buzzheavier URL。
- 当 `mirrors=release+buzzheavier` 时：`<名称>.7z.001`… 各分卷（单卷不超过 1900 MB）。原始 ISO 可经 `7z x <名称>.7z.001` 还原；各分卷摘要记录于 `manifest.json`。

镜像上传的留存与获取受该托管服务自身政策的约束。镜像留存的自动化维护可由 [Buzzheavier-Keeper](https://github.com/wzwtt/Buzzheavier-Keeper) 实现。

## 运行特征

| 阶段 | 典型时长 |
|---|---|
| 解析、下载包生成、预检 | 2–4 分钟 |
| 载荷下载 | 10–25 分钟 |
| 转换 | 40–90 分钟（`esd` 与 `cleanup` 关闭时更短） |
| 摘要计算与镜像上传 | 5–25 分钟 |

运行器上磁盘峰值占用为 25–35 GB（载荷、镜像与临时文件）；转换开始前校验剩余空间。作业超时上限为 360 分钟。私有仓库中 Windows 运行器按每分钟 2 倍费率计费。

## 错误处理

| 条件 | 处理 |
|---|---|
| 非 429 的客户端错误（HTTP 4xx） | 不重试；uupdump 返回错误页（如不支持的语言、非法的语言/版本组合）时，原文透出其错误信息。 |
| uupdump 限流（HTTP 429/403） | 指数退避（5/15/45 秒），每请求最多三次尝试。 |
| 目录页出现 Cloudflare 质询 | 退避重试；持续失败时运行终止并给出处置指引（GUID/URL 直输可绕过目录页）；监测周期跳过受影响目标。 |
| 转换失败 | 重新执行一次下载脚本；aria2 自断点续传。 |
| ISO 低于 1 GiB | 视为疑似不完整转换，在发布前拒绝。 |
| 镜像上传失败 | Release 照常创建；运行摘要记录错误。上传响应中的摘要与本地摘要比对以验证传输完整性。 |
| 监测配置文件非法 | 该周期以解析错误终止；分支或文件缺失时采用内置默认值。 |
| 任意步骤失败 | `aria2_download.log` 与 `ConvertConfig.ini` 以保留 7 天的工件形式附带。 |

## 仓库结构

```
main 分支：
.github/workflows/build-iso.yml    构建工作流（手动与被调用）
.github/workflows/watch.yml        定时监测工作流
scripts/Common.psm1                日志、HTTP 重试、选项模式、标签计算、目录解析
scripts/Resolve-UupBuild.ps1      阶段一——输入解析与标签计算
scripts/New-UupPackage.ps1        阶段二——下载包生成、修补、依赖预取、预检
scripts/Invoke-UupConvert.ps1     阶段三——载荷下载、转换、校验
scripts/Publish-UupIso.ps1        阶段四——摘要、镜像上传、Release 创建、摘要输出
scripts/Watch-UupBuilds.ps1       定时周期——目标解析与矩阵规划

watch 分支（孤儿）：
uup-watch.json                     定时监测配置
```

## 许可证

以 [MIT 许可证](LICENSE) 发布。该许可证适用于本仓库的流水线代码；流水线产出的镜像仍受下述评估用途条款约束。

## 法律声明

本流水线产出的镜像仅限评估用途，不受 Microsoft Corporation 支持，本项目与 Microsoft 无关联。内容取自 uupdump.net 与微软更新服务器；相关服务的条款适用。

> AI生成
