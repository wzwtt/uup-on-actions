# UUP on Actions

用 GitHub Actions 的 Windows runner 在云端把 [UUP dump](https://uupdump.net/) 的更新包下载并转换为完整 Windows ISO，再把 ISO 上传到 [buzzheavier](https://buzzheavier.com/) 免费不限容量的文件托管，Release 里只留校验和信息。本地网络慢、反复挂载消耗磁盘的问题一次解决。

- **无需再从 uupdump 网站下载任何 zip 上传进仓库**：runner 自己调用 uupdump 的生成接口现场生成下载包。
- **所有构建选项全部网页表单可改**，默认值开箱即用，改选项不产生任何 commit。
- **定时自动追新**：每天在设定的时间窗口内检查指定 Windows 发布分支（可同时监测多个分支、多套选项），有新版本自动构建发布。
- 代码仓库里只有纯文本脚本，无任何二进制、无数据文件污染历史。

> **法律提示**：产物仅限评估用途（evaluation purposes only），与 Microsoft 无任何关联、不受 Microsoft 支持。请遵循 uupdump 的内容声明。

---

## 目录

1. [工作原理](#工作原理)
2. [快速开始](#快速开始)
3. [手动构建：全部输入字段](#手动构建全部输入字段)
4. [options 高级选项完整键表](#options-高级选项完整键表)
5. [Release 命名（tag）规则](#release-命名tag规则)
6. [定时自动构建（Watch）](#定时自动构建watch)
7. [产物内容](#产物内容)
8. [时长与磁盘开销](#时长与磁盘开销)
9. [故障排查](#故障排查)
10. [仓库结构](#仓库结构)

---

## 工作原理

```
手动 Run workflow ─┐
                   ├─→ ① 解析输入 → uupdump 构建 GUID（支持 latest/版本号/GUID/链接）
定时 Watch 触发 ───┘        ↓
                   ② 幂等检查：该 tag 的 release 已存在 → 直接跳过
                        ↓
                   ③ 在 runner 上调 uupdump 接口生成下载包 → 解压 → 打补丁（无人值守）
                        ↓
                   ④ 执行下载脚本：aria2 从微软 CDN 拉取全部 UUP 文件并转换为 ISO（失败自动整轮重试，aria2 断点续传）
                        ↓
                   ⑤ 校验 ISO（存在、>1GB、SHA-256）→ 上传 buzzheavier（整文件直传，无分卷）
                        ↓
                   ⑥ 创建 GitHub Release：SHA256SUMS.txt + manifest.json + 下载链接
```

两个 workflow：

| 文件 | 触发 | 作用 |
|---|---|---|
| `.github/workflows/build-iso.yml` | 手动（Run workflow）或被 watch 调用 | 单次构建，全部选项可自定义 |
| `.github/workflows/watch.yml` | cron（每 2 小时探测，脚本内再判断时间窗口）+ 手动 | 监测分支新版本，发现即自动拉起构建 |

---

## 快速开始

1. Fork / 使用本仓库，进入 **Actions** 页确保 workflow 已启用。
2. 点 **Build Windows ISO** → **Run workflow**，保持默认（`latest` / `amd64` / `zh-cn` / `professional`）直接运行。
3. 等 1.5～2.5 小时后，Actions 运行摘要和 Release 页都会给出 **buzzheavier 完整 ISO 直链**（Release 页同时附 SHA-256 与 manifest）。

想先验证参数而不真正下载：把 `dry_run` 勾上，约 2 分钟即可确认语言/版本组合有效（会真实向 uupdump 校验并给出文件数与预计下载量）。

---

## 手动构建：全部输入字段

进入 Actions → **Build Windows ISO** → Run workflow，共 10 个输入框。**全部有默认值，全部可改，且互相自由组合**；不修改任何仓库文件。

### ① `build`（必填，默认 `latest`）

要构建哪个 Windows 版本。支持 5 种写法，任选其一：

| 写法 | 示例 | 含义 |
|---|---|---|
| `latest` | `latest` | 全站最新的一个**完整构建**（自动跳过累积更新、OOBE 补丁这类非完整条目） |
| `latest:<分类>` | `latest:w11-25h2` | 指定分类下最新的完整构建 |
| `<版本号>` | `26200.10075` | 精确搜索该 build 号 |
| `<GUID>` | `bb653e4f-2f06-4aa6-9994-d5c692e24009` | 直接指定 uupdump 构建编号（从 uupdump 页面 URL 里的 `id=` 取） |
| uupdump 链接 | `https://uupdump.net/selectlang.php?id=bb653e4f-...` | 粘贴任意 uupdump 页面链接，自动提取 GUID |

可用的**分类名**（即 `latest:` 后面能填什么，来自 uupdump Downloads 页的分类筛选，可随时在其网站上查看最新分类）：

| 分类 | 对应分支 |
|---|---|
| `future` | 未来/开发通道 |
| `w11-26h2-experimental` | Win11 26H2 实验通道 |
| `w11-26h2` / `w11-26h1` | Win11 26H2 / 26H1 |
| `w11-25h2-beta` / `w11-25h2` | Win11 25H2 Beta / 正式 |
| `w11-24h2-beta` / `w11-24h2` | Win11 24H2 Beta / 正式 |
| `w11-23h2` / `w11-22h2` / `w11-21h2` | Win11 23H2 / 22H2 / 21H2 |
| `server-24h2` / `server-23h2` / `server-22h2` / `server-21h2` | Windows Server 各年度版 |
| `w10-22h2` / `w10-21h2` / `w10-1809` | Win10 22H2 / 21H2 / 1809 |

> 说明：`latest:future` 这类 Insider 通道的“最新完整构建”按**加入日期**判断，并自动过滤标题含 Update/Critical 的服务性条目。

### ② `arch`（必填，默认 `amd64`）

| 值 | 含义 | 也接受 |
|---|---|---|
| `amd64` | x64（常用） | `x64` |
| `arm64` | ARM64 | `aarch64` |
| `x86` | 32 位 | `i386`, `32` |

注意：指定 GUID/链接时，若该构建的实际架构与输入不符会在 1 分钟内直接报错（不浪费下载时间）。

### ③ `language`（必填，默认 `zh-cn`）

任何 uupdump 支持的 Windows 语言代码。常用的：

`zh-cn`（简中）、`zh-tw`（繁中）、`en-us`、`en-gb`、`ja-jp`、`ko-kr`、`de-de`、`fr-fr`、`ru-ru`、`es-es`、`pt-br`、`it-it`、`pl-pl`、`tr-tr`、`ar-sa`、`th-th`、`vi-vn`、`id-id` …（完整列表见 uupdump 构建的语言选择页；填错会在生成包阶段立即失败，不会浪费下载时间。）

### ④ `editions`（必填，默认 `professional`）

逗号分隔的一个或多个**目标版本**（多个版本会打进同一 ISO 的多版本安装菜单）。常见的：

| 值 | 版本 |
|---|---|
| `professional` | 专业版 |
| `core` | 家庭版 |
| `corecountryspecific` | 家庭中国版 |
| `coren` / `professionaln` | 家庭 N / 专业 N（欧洲） |
| `education` / `educationn` | 教育版 |
| `enterprise` / `enterprisen` | 企业版 |
| `iotenterprise` | IoT 企业版 |
| `serverstandard` / `serverdatacenter` 等 | Server 系列（对应 Server 分支构建） |

示例：`professional,core,corecountryspecific` → 一个 ISO 里含三个版本。**不确定该 build 支持哪些版本时**，先跑一次 `dry_run`。

### ⑤ `virtual_editions`（选填，默认空 = 关闭）

开启后，在基础版本之外用 DISM **动态生成附加虚拟版本**（下载内容相同、体积几乎不变，但 ISO 里多出几个可选版本）。逗号分隔，可用值（该 build 支持的子集）：

| 值 | 版本 |
|---|---|
| `CoreSingleLanguage` | 家庭单语言版 |
| `ProfessionalWorkstation` | 专业工作站版 |
| `ProfessionalEducation` | 专业教育版 |
| `Education` | 教育版 |
| `Enterprise` | 企业版 |
| `ServerRdsh` | 企业多会话/虚拟桌面版 |
| `IoTEnterprise` | IoT 企业版 |

示例：`Education,Enterprise,IoTEnterprise`。填了任何值即自动启用（对应 uupdump 网页上第 3 个单选项 "Download, add additional editions and convert to ISO"）。

### ⑥ `esd`（默认关闭）

| 值 | 效果 |
|---|---|
| 不勾（默认） | install.wim，LZX 压缩，ISO 约 5～6 GB，转换较快，**通用性最好** |
| 勾选 | install.**esd** 固实压缩，ISO 缩小约 1～1.5 GB，转换多花 10～20 分钟，**部分工具不支持挂载/编辑 ESD** |

不知道它是什么就保持默认（这是项目默认关闭的原因）。也可在 `options` 里用 `esd=true` 覆盖。

### ⑦ `mirrors`（下拉选择，默认 `buzzheavier`）

| 值 | 行为 |
|---|---|
| `buzzheavier` | ISO 完整单文件直传 buzzheavier（默认，无分卷、无合并步骤） |
| `release+buzzheavier` | buzzheavier 之外，同时把 ISO 按 1900 MB 分卷（`.7z.001…N`）作为 GitHub Release 资产（每个分卷低于 GitHub 单资产 2 GiB 上限；需要保底存档时选这个） |

### ⑧ `dry_run`（默认关闭）

勾选后只做：解析输入 → 生成下载包 → 预检（调用 uupdump API 确认组合有效、统计文件数与预计下载量），**不下载任何主体文件**。约 2 分钟。用于验证语言/版本组合、试新分类。

### ⑨ `draft`（默认关闭）

勾选后 Release 以草稿形式创建（需要你手动发布），ISO 照常上传 buzzheavier。

### ⑩ `options`（选填，多行文本，默认空）

高级用户的总开关：**多行 `Key=Value`，逐键覆盖任意转换选项**，白名单校验（写错键名立刻报错并列出全部合法键）。详见下一节。

---

## options 高级选项完整键表

`options` 输入框里每行一个 `Key=Value`，`#` 开头的行是注释。**大小写不敏感**；布尔值接受 `true/false/1/0/yes/no`。所有键都会写进 uupdump 转换器的 `ConvertConfig.ini`。

### 转换行为（`[convert-UUP]` 段）

| 键 | 默认 | 作用 |
|---|---|---|
| `updates` | `true` | 集成最新累积更新（LCU）等（仅 Windows 转换器） |
| `cleanup` | `false` | 组件清理（WinSxS 压缩），显著增加 20～40 分钟转换时间 |
| `netfx3` | `false` | 集成 .NET Framework 3.5（仅 Windows 转换器） |
| `esd` | `false` | 固实压缩（与顶层 `esd` 输入等价，此处优先） |
| `resetbase` | `false` | 清理 WinSxS ResetBase（镜像更小，装完不可卸载更新） |
| `wim2swm` | `false` | 输出拆分的 .swm 多文件 |
| `skipiso` | `false` | 跳过 ISO 打包（仅产出 WIM/ESD） |
| `skipwinre` | `false` | 跳过 WinRE 恢复镜像处理 |
| `lcuwinre` | `false` | 用 LCU 更新 WinRE |
| `lcuexpand` | `false` | 展开集成 LCU 的 MSU |
| `updtbootfiles` | `false` | 更新引导文件（bootfiles） |
| `forcedism` | `false` | 强制使用 DISM 而非 wimlib |
| `refesd` | `false` | 用 ESD 作为引用源 |
| `skiplcumsu` | `false` | 跳过 LCU MSU 集成 |
| `skipedge` | `false` | 跳过 Edge 浏览器集成 |
| `disabledupdatingupgrade` | `false` | 禁止 setup 动态升级 |
| `adddrivers` | `false` | 集成驱动（配合 `drv_source`；驱动需自行可下载） |
| `drv_source` | 空 | 驱动目录路径（runner 上的路径，配合 `adddrivers=true`） |

### Store 应用（`[Store_Apps]` 段）

| 键 | 默认 | 作用 |
|---|---|---|
| `skipapps` | `false` | 跳过 Microsoft Store 应用集成 |
| `appslevel` | `0` | 应用集成级别（数字） |
| `stubappsfull` | `false` | 完整安装 Stub 应用 |
| `customlist` | `false` | 启用包内 CustomAppsList.txt 自定义应用清单 |

### 虚拟版本（`[create_virtual_editions]` 段，仅在启用了 `virtual_editions` 时有意义）

| 键 | 默认 | 作用 |
|---|---|---|
| `vdeletedsource` | `false` | 虚拟转换后删除源 WIM |
| `vpreserve` | `false` | 保留中间文件 |
| `vsorteditions` | `false` | 按字母排序虚拟版本 |

### 工作流级（不写入转换器）

| 键 | 默认 | 作用 |
|---|---|---|
| `force` | `false` | 同名 release 已存在时**强制重建**（自动删除旧 release/tag 后重新构建发布） |
| `tag_suffix` | 空 | 给本次 release 的 tag 追加自定义后缀，如 `tag_suffix=hotfix` → `...-hotfix` |

示例（一次粘贴多行）：

```
updates=true
cleanup=true
skipedge=true
tag_suffix=test
```

---

## Release 命名（tag）规则

```
<build号>-<架构>-<语言>-<版本们按字母排序以-连接>[+ve][-<选项哈希4位>][tag_suffix]
```

| 片段 | 例子 | 何时出现 |
|---|---|---|
| build 号 | `26200.10075` | 总是有 |
| 架构 | `amd64` / `arm64` / `x86` | 总是有 |
| 语言 | `zh-cn` | 总是有 |
| 版本 | `core-professional` | 总是有（排序保证幂等一致） |
| `+ve` | `+ve` | 启用了虚拟版本 |
| `-5ea0` | 4 位短哈希 | **任何与默认组合不同的转换选项**（含 esd=true）都会触发，保证不同选项产出不同 tag、互不覆盖 |
| 后缀 | `-hotfix` | `options` 里给了 `tag_suffix` |

同一 tag 重复运行会被幂等检查直接跳过（除非 `force=true`）。

---

## 定时自动构建（Watch）

`watch.yml` 每 2 小时醒一次，但**真正的构建时间窗口**和**监测目标**由仓库变量 `UUP_WATCH` 控制（改配置不产生任何 commit）。

### 配置格式（JSON，放在仓库 **Settings → Actions → Variables → `UUP_WATCH`**）

```json
{
  "window": "17:00-21:00+0800",
  "max_parallel": 2,
  "targets": [
    {
      "build": "latest:w11-25h2",
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
      "build": "latest:w11-24h2",
      "arch": "amd64",
      "language": "zh-cn",
      "editions": "professional,core",
      "options": "esd=true"
    }
  ]
}
```

字段说明：

| 字段 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `window` | 否 | `17:00-21:00+0800` | 每日构建窗口 `HH:MM-HH:MM±时区偏移`，支持跨零点（如 `22:00-06:00+0800`）。窗口外唤醒只记日志不构建 |
| `max_parallel` | 否 | `2` | 多个新版本同时发现时的并行构建数 |
| `targets` | **是** | 见下方默认 | 监测目标数组，可任意多个；每个目标字段与手动构建的输入同名同义 |
| 每项 `build` | **是** | — | 同手动构建 `build` 字段（通常写 `latest:<分类>`） |
| 每项 `arch` / `language` / `editions` | 否 | `amd64` / `zh-cn` / `professional` | 同手动构建 |
| 每项 `virtual_editions` | 否 | 空 | 同手动构建 |
| 每项 `esd` | 否 | `"false"` | 字符串 `"true"`/`"false"` |
| 每项 `mirrors` | 否 | `buzzheavier` | 同手动构建 |
| 每项 `options` | 否 | 空 | 同手动构建（多行用 `\n` 写在 JSON 字符串里） |
| 每项 `draft` | 否 | `"false"` | 同手动构建 |

**未配置 `UUP_WATCH` 变量时的内置默认**：监测 `w11-25h2` 与 `w11-24h2` 两个分支，`amd64`/`zh-cn`/`professional`，`buzzheavier` 镜像，窗口 17:00–21:00（UTC+8），并行 2。

用命令行写入（不产生 commit）：

```bash
gh variable set UUP_WATCH --body '{"window":"17:00-21:00+0800","max_parallel":2,"targets":[{"build":"latest:w11-25h2","arch":"amd64","language":"zh-cn","editions":"professional"},{"build":"latest:w11-24h2","arch":"amd64","language":"zh-cn","editions":"professional"}]}'
```

（示例文件见 `.github/uup-watch.example.json`，仅供参考，workflow 只读仓库变量。）

### 判定“有新版本”的规则

对每个目标：解析该分类**最新的完整构建**（跳过标题含 Update/Critical 的服务性条目）→ 按其全部选项算出 tag → 该 tag 的 release 已存在则跳过，不存在则自动构建。因此天然幂等：同一天窗口内多次探测不会重复构建；构建完成后同一版本永不重复。

> 手动测试 watch：在 Actions 里运行 **Watch new builds**，勾选 `bypass_window` 可无视时间窗口立即检查。

---

## 产物内容

每次构建产出一个 GitHub Release：

- **ISO 下载链接（buzzheavier）**：完整单文件直链，无需合并分卷。浏览器打开链接点击 Download 即可（部分命令行下载器可能被其 Cloudflare 页面拦截，用浏览器或 IDM 等常规工具）。
- `SHA256SUMS.txt`：ISO 的 SHA-256。
- `manifest.json`：构建号、GUID、标题、语言、版本、虚拟版本、全部生效选项、ISO 名/大小/哈希、镜像链接与上传时间、workflow 运行链接、评估用途声明。
- Release 正文：以上信息的人类可读版本 + 校验命令 + 法律声明。

### buzzheavier 链接的时效（重要）

匿名上传默认约 4 天无人下载就会过期；每次被下载延长 2 天（上限 60 天；30 天内被下载 60 次以上转永久）。**镜像保鲜不在本项目范围内**——由作者另行维护的保鲜方案（定期重传保活）负责，如需长期可用请结合自己的保鲜机制或 `mirrors=release+buzzheavier` 使用 GitHub 分卷存档。

---

## 时长与磁盘开销

| 阶段 | 典型耗时 |
|---|---|
| 解析 + 生成包 + 预检 | 2～4 分钟 |
| aria2 下载 UUP 文件 | 10～25 分钟（微软 CDN，runner 带宽充足） |
| 转换为 ISO | 40～90 分钟（esd 关 / cleanup 关更快） |
| 哈希 + buzzheavier 上传 | 5～25 分钟（runner 出口带宽） |

磁盘：runner 上峰值约 25～35 GB（UUP 原始包 + ISO + 临时），脚本会预检磁盘余量。GitHub 免费额度足够：公共仓库 Actions 分钟免费，Windows runner 计 2 倍分钟（约 5 小时上限内绰绰有余）。

---

## 故障排查

| 症状 | 原因与处理 |
|---|---|
| 解析阶段报 **Cloudflare challenge** | uupdump 对数据中心 IP 间歇性出挑战。脚本已内置 3 次退避重试；仍失败请稍后重跑，或改用 `build` 填 GUID/URL 直连（绕过列表页）。watch 模式遇到时自动跳过该目标，下个周期重试 |
| 生成包报 “不是 zip / 组合无效” | 语言或版本组合该构建不支持。用 `dry_run` 逐项验证 |
| `gh release create` 失败说 tag 占用 | 用 `options` 里 `force=true` 重跑（自动清理旧 release/tag） |
| buzzheavier 上传失败 | Release 仍会创建（带哈希与失败标注），重跑 workflow 重传即可；上传成功后服务器会返回 sha256 与本地比对，不一致会显著告警 |
| 转换中途失败 | workflow 自动整轮重跑一次（aria2 断点续传，不浪费已下载部分）；仍失败时日志（`aria2_download.log` 等）自动作为 7 天保留的 artifact 上传 |
| ISO 尺寸 < 1GB 被拒 | 转换异常中断的产物，默认拒绝发布；重跑 |
| uupdump 429 / 限速 | 脚本已内置 5/15/45 秒退避，实测可恢复 |

---

## 仓库结构

```
.github/workflows/build-iso.yml   # 手动构建（也可被 watch 调用）
.github/workflows/watch.yml        # 定时监测 → 矩阵拉起构建
.github/uup-watch.example.json     # UUP_WATCH 变量示例（仅供参考）
scripts/Common.psm1                # 公共：日志/HTTP退避/选项白名单/tag/构建发现
scripts/Resolve-UupBuild.ps1      # ① 解析输入 → GUID + tag
scripts/New-UupPackage.ps1         # ② 生成下载包 + 补丁 + 预检
scripts/Invoke-UupConvert.ps1      # ③ 下载转换 + 重试 + ISO 校验
scripts/Publish-UupIso.ps1         # ④ 哈希 + buzzheavier + Release + 摘要
scripts/Watch-UupBuilds.ps1        # ⑤ 定时矩阵规划
```

本项目不存储任何 Windows 数据：产物只在 Release 与外部镜像上，代码仓库仅含纯文本脚本。

---

## 法律声明

- 产物镜像**仅限评估用途**，不受 Microsoft Corporation 任何形式支持；与 Microsoft 无任何关联。
- 数据来源为 uupdump.net 与 Microsoft 更新服务器；请遵守其条款。
- 使用者自行承担使用责任。

> AI生成
