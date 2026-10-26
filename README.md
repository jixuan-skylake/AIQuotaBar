# AIQuotaBar

AIQuotaBar 是一个原生 macOS 状态栏应用，用来查看 Codex 和 Claude 的**网页订阅额度**，以及 Codex / Claude Code 的**本机 token 统计**。它常驻菜单栏，默认用双行小字显示 `A`（Claude）和 `C`（Codex）的剩余额度，点击后展开可视化面板。

它不是 OpenAI / Anthropic 的官方产品，也不隶属于两家公司；见文末[免责声明](#免责声明)。

**English summary.** AIQuotaBar is a native macOS menu-bar app that shows your Codex and Claude *web subscription* quota plus local Codex / Claude Code token statistics. It locates the quota pages you already have open in Google Chrome by enumerating window and tab metadata, then asks Chrome over Apple Events for `document.body.innerText` on those two pages only and parses the text the page already displays. To keep the numbers fresh it has Chrome reload those two pages, so Chrome talks to the services exactly as it would if you hit refresh yourself — AIQuotaBar itself makes no network requests and has no telemetry, which is not the same thing as the whole flow being offline. It never reads login credentials (cookies, session tokens), browser profiles or history, and needs no API key: the legacy API-cost code paths have no callers and are unreachable. macOS 13.0+. Unofficial, MIT-licensed, not affiliated with OpenAI or Anthropic.

---

## 下载最新版（Apple Silicon）

**[⬇ 下载 AIQuotaBar-macOS-arm64.dmg](https://github.com/jixuan-skylake/AIQuotaBar/releases/latest/download/AIQuotaBar-macOS-arm64.dmg)** —— 当前版本 **0.2.18**（build 20）

- 适用于 **Apple Silicon（arm64）** 的 Mac，需要 **macOS 13.0 或更高版本**。
- **没有提供、也没有测试 Intel 或 Universal 版本。**
- 也可以直接去 [Releases 页面](https://github.com/jixuan-skylake/AIQuotaBar/releases/latest) 看全部资产与校验值。

### 安装步骤

1. 打开下载好的 DMG，把 **AIQuotaBar** 拖到 **Applications（应用程序）** 文件夹。
2. 首次打开：**macOS 可能会阻止**打开这个 app。请先自己确认来源、并核对下面的校验值；确认没问题后打开「系统设置 → 隐私与安全性」，找到针对 AIQuotaBar 的提示，按那里给出的选项处理。
3. 按下面 **使用前提：Chrome 与 macOS 权限** 一节配置 Chrome 与自动化权限，然后在菜单里点「立即刷新」。

> ⚠️ 这个包**未经 Apple 公证（notarization）**，只有本地 ad-hoc 签名，所以 macOS 可能会阻止打开它。
>
> 具体提示文案与可用选项取决于你的 macOS 版本和设备管理策略。本文档**不保证**只会被拦一次，也**不保证**某个特定操作（例如右键打开）在所有机器上都有效；在某些策略或系统版本下，未经公证的 app 可能**根本无法打开**。Apple 的官方说明见 [如何打开来自身份不明开发者的 Mac App](https://support.apple.com/en-us/102445)。
>
> **不需要、也不建议**为此关闭 Gatekeeper 或系统完整性保护；本文档也不会提供移除 quarantine 属性之类的绕过命令。如果你的环境不允许运行未公证的 app，请改为从源码自行构建 —— 见下面的 **构建、测试与打包** 一节。

### 校验下载（可选）

Release 里附带 `SHA256SUMS`。把它和 DMG 放在同一个目录，然后：

```zsh
shasum -a 256 -c SHA256SUMS
```

### 关于更新

这个应用**没有自动更新**，也不会联网检查新版本。要升级请回到 Releases 页面重新下载、重新拖一次。注意：换了构建之后 macOS 的自动化权限可能需要重新授权一次。

## 版本与更新记录

每个公开版本的新增、修复与已知限制都记在 **[CHANGELOG.md](CHANGELOG.md)**。

0.2.18 是第一个公开安装包；在它之前的版本只存在于私有构建，没有公开发布历史，所以更新记录不会为它们编造条目。维护者的发布流程见 **[RELEASING.md](RELEASING.md)**。

## 功能概览

- **状态栏常驻**：双行 `A`/`C` 剩余额度，或改为「最低额度」/「只显示 Claude」/「只显示 Codex」。
- **可视化面板**：长条视图与圆环视图可切换，选择自动保存。
- **状态栏表情**：按当前显示指标的剩余量显示单色线性表情（充足 / 正常 / 偏低 / 紧张 / 未知），颜色跟随状态栏文字。
- **可选指标**：Codex 的「每周使用限额」；Claude 的 Current Session / All Models / Claude Design。选中的指标本次没有数值时不会借用其它指标的数字，而是显示 `--` 或 `AI`。
- **自动刷新**：可选每 1 / 3 / 5 / 10 分钟，默认 **5 分钟**；另有「节能模式」（默认开启）——低电量模式下自动刷新间隔至少 10 分钟，系统睡眠 / 屏幕关闭期间暂停，唤醒后只在真正过期时补一次。
- **失败不回退成空值**：某轮网页读取失败但之前成功过时，状态栏沿用上次成功值，并在菜单详情里写明本轮未读到完整网页。
- **单实例运行**：启动时创建用户级锁文件，重复启动的副本会自动退出。

## 数据来源与读取范围

| 来源 | 读什么 | 默认 |
| --- | --- | --- |
| Codex 网页额度 | 已登录 Chrome 中 `https://chatgpt.com/settings/usage?tab=overview` 的页面文本，只取每周使用限额；旧地址 `https://chatgpt.com/codex/cloud/settings/analytics` 仍兼容 | 开 |
| Claude 网页额度 | 已登录 Chrome 中 `https://claude.ai/new#settings/usage` 的页面文本，把 Current Session / All Models / Claude Design 的 used 百分比换算成剩余百分比；旧地址 `https://claude.ai/settings/usage` 仍兼容 | 开 |
| Codex 本机记录 | `~/.codex/state_5.sqlite` 里的本地线程 token 用量，显示今日与近 7 天 | 开 |
| Claude Code 本机记录 | `~/.claude/projects/*.jsonl` 里的 `message.usage`，显示今日与近 7 天 token、消息 / 会话数量与输入 / 输出 / cache 拆分 | 开 |

**本机 token 统计的口径**：统计窗口是「本地日历今天 + 前 6 天」，不是 168 小时滚动窗口；「最近事件时间」统计全历史；会话数跨文件去重。Claude 网页和 Claude Desktop 的聊天本身没有稳定公开的 token 明细，因此这里的 Claude token 统计对应的是 **Claude Code 的本机 JSONL 记录**，不是网页订阅用量。

**关于 API 计费与遗留代码**：真实的采集链是 `QuotaCollector.collect()`，它只调用上表那三个采集函数（Codex 本机、Claude Code 本机、Chrome 网页额度）。源码里还留着 OpenAI / Anthropic API 计费卡片（`openAICostsCard` / `anthropicCostsCard`）和 Claude Desktop 目录探测（`claudeDesktopPresenceCard`）的实现，但**它们没有任何调用者，不在采集链上**：即使把配置里的 `sources.openAICosts` / `sources.anthropicCosts` / `sources.claudeDesktopPresence` 改成 `true`，这些卡片也不会显示、不会发起任何请求、不会读取任何 Keychain 项。本仓库不包含把 Admin Key 写入 Keychain 的助手脚本，本轮也不恢复这些功能。因此这个构建不需要、也不会读取、存储或发送任何 API 凭据。

**配置文件**：`~/Library/Application Support/AIQuotaBar/config.json`，首次运行自动生成默认值；可用环境变量 `AIQUOTABAR_CONFIG` 指向别处。

## 使用前提：Chrome 与 macOS 权限

网页额度是最接近订阅剩余量的数据源，需要三个前提：

1. **在 Chrome 的已登录个人资料里保持上面两个额度页打开**。AIQuotaBar 不会替你登录，也不会在 Chrome 没运行时启动 Chrome；页面关掉就读不到。
2. **在 Chrome 菜单开启**「查看 → 开发者 → 允许 Apple 事件中的 JavaScript」。关闭时 Chrome 会直接拒绝执行，应用会把这个原因显示在菜单卡片里。
3. **在 macOS 授予自动化权限**：首次读取时系统会弹窗询问，或手动到「系统设置 → 隐私与安全性 → 自动化」里允许 AIQuotaBar 控制 Google Chrome。从终端直接运行可执行文件时，这项权限归属于终端应用而不是 AIQuotaBar。

满足后，每轮刷新只对这两个额度页执行 reload，等页面进入 `complete` 并出现关键额度字段后执行一次 `document.body.innerText`，解析页面已经显示的文字。

目前只支持 **Google Chrome**（bundle id `com.google.Chrome`）。为避免把事件发给 Playwright / Puppeteer / WebDriver 启动的测试实例，应用每轮都重新枚举 Chrome 主进程并按只读的启动参数分类，只有在**恰好识别出一个普通实例**时才读取；出现多个普通实例、只有自动化实例或参数读不到时，会在卡片里写明原因并停止，不会猜一个。自 0.2.14 起没有辅助功能（Accessibility）备用读取路径。

## 隐私说明

- **不读取登录凭据。** 不读 cookie、会话 token、浏览器 profile、历史或书签。读取 Chrome 启动参数走只读的 `sysctl KERN_PROCARGS2`，只用来分类实例、不读 profile 内容。额度数字本身当然是你的账户数据 —— 把它取出来显示就是这个工具的全部用途；它只在本机解析，不离开你的电脑。
- **只对额度页执行 JavaScript，不采集非目标页正文。** 为了定位额度页，会枚举 Chrome 窗口与标签的元数据（window id、tab id、URL、`loading` 状态）。URL 用 `URLComponents` 严格校验 scheme / host / path（Claude 新地址还要求 fragment 精确匹配），嵌在其它主机或路径里的相似字样不算额度页。只有通过校验的额度页才会被执行 JavaScript 并取 `innerText`；其它标签页的正文不会被读取、保存或输出。
- **AIQuotaBar 自身不联网，也没有遥测。** 它不向任何服务器上报数据，源码里也没有可达的出站 HTTP 代码路径。但这**不等于整个流程离线**：为了拿到新鲜数值，每轮刷新都会让 Chrome reload 这两个额度页，这会由 Chrome 向对应服务端发起正常的页面请求 —— 和你自己按一下刷新完全一样。菜单里的「打开 Codex / Claude 网页额度」是交给系统默认浏览器打开链接，同样不传任何数据。
- **本机缓存只存聚合数字和文件元数据，不存聊天正文。** 可选的磁盘缓存 `~/Library/Application Support/AIQuotaBar/claude-usage-cache.json` 含项目路径与 session id，属私有数据：文件以 `0600` 创建后原子替换，专用目录收紧为 `0700`；设 `AIQUOTABAR_CACHE_FILE=off` 可完全关闭磁盘持久化。
- **诊断输出不含网页正文。** `--browser-diagnostics` 默认只枚举，不 reload、不执行页面 JavaScript、不输出正文。

## 构建、测试与打包

需要 macOS 13.0 或更高版本，以及 Xcode 命令行工具（提供 `swiftc`、`codesign`、`iconutil`）。

```zsh
make test     # 默认测试：plutil 校验 Info.plist、校验签名、--version、--self-test
make app      # 只构建 .app
make dmg      # 快速打一个本地 DMG 到 dist/AIQuotaBar.dmg（不是正式发布包）
make selftest # 只跑 --self-test
```

正式公开发布包走单独的入口，不要用 `make dmg` 代替：

```zsh
./Scripts/build-release.sh --check   # 只做前置校验，不构建、不打包
./Scripts/build-release.sh           # 构建并打出 dist/AIQuotaBar-macOS-arm64.dmg + SHA256SUMS
```

它把架构与最低系统钉死为 `arm64-apple-macos13.0`、签名身份固定为 ad-hoc（不受环境里的 `CODESIGN_IDENTITY` 影响），在独立临时目录里构建、构建后跑 `make test`、从 Mach-O 的 load commands 核实架构与 `minos`、按白名单裁剪 app bundle、ad-hoc 重新签名并核实签名形态、`hdiutil verify`、只读挂载后逐文件比对并从挂载点跑 `--version` / `--self-test`。

DMG 先在临时目录里生成并完成全部校验，**只有全部通过才会落地到输出目录**，所以失败时不会留下未经验证的半成品包。产物**永不覆盖**：三个输出叶子（DMG、`SHA256SUMS`、来源证据）任何一个已存在、或是符号链接 / 目录，都会直接拒绝 —— 要重新打包请先移走旧产物，或用 `--output` 指向一个新目录。落地用 `O_CREAT|O_EXCL` 原子独占创建加 SHA256 回验，而不是 `mv`，所以不会覆盖并发出现的文件，也不会沿着目录符号链接把产物写到别处；跨卷输出同样支持。它不安装、不启动 GUI、不读浏览器、不改任何用户配置。完整流程见 **[RELEASING.md](RELEASING.md)**。

`make test` 是完全本地、确定性的：全部使用仓库内的合成文本与临时目录，不需要 Chrome 自动化权限，不读取用户会话内容。`--self-test` 结束时会打印自己的断言通过 / 失败计数，退出码非 0 即失败。

安装脚本的校验逻辑另有一份独立回归（不经 Makefile，直接运行）：

```zsh
./Tests/install_check_test.sh
```

它只调用 `install-launch-agent.sh --check`，在任务私有的临时目录里用合成的最小 `.app` 覆盖各种拒绝边界，并逐项断言退出码与「临时目录未被改动」。它**不执行任何真实安装动作**，不碰 `~/Applications`、LaunchAgent 或你的配置，也从不运行那个占位可执行文件。它不是真实安装的集成测试。

以下目标**不在** `make test` 里，需要额外权限或会读取本机数据，请按需单独运行：

```zsh
make benchmark   # 本机统计性能基准；会读取 ~/.claude/projects，只输出聚合值
make diagnostics # 浏览器实例诊断；需要 Chrome 自动化权限
make snapshot    # 会 reload 已打开的额度页并读取；需要 Chrome 自动化权限
```

构建目录和签名身份都可以覆盖：

```zsh
make test BUILD_DIR=/tmp/AIQuotaBar-build CODESIGN_IDENTITY="你的代码签名证书名称"
```

- `BUILD_DIR` 默认 `/tmp/AIQuotaBar-build`，产物是 `$BUILD_DIR/AIQuotaBar.app`。
- `CODESIGN_IDENTITY` 默认 `-`，即 **ad-hoc 签名**。

> ⚠️ **`make clean` 会 `rm -rf` 掉整个 `$BUILD_DIR` 和整个 `dist/` 目录**，包括你放在里面的其它文件。运行前先确认 `BUILD_DIR` 的值。

### 签名与公证

- 默认构建是 ad-hoc 签名，**没有经过 Apple 公证（notarization）**。首次打开可能需要在「系统设置 → 隐私与安全性」里对这一个 app 显式允许 —— 不需要、也不建议为此关掉 Gatekeeper。
- 本机自签名或 ad-hoc 签名**不具备 Developer ID 身份，也没有 Apple 公证**，因此不具备分发信任：别人拿到这样的构建产物时 Gatekeeper 不会直接放行，需要他们自己确认来源后放行。这不是说不许分发（MIT 许可本身允许），而是**不能保证在别人的 Mac 上双击即开**；要做到那一步需要 Developer ID 签名加 Apple 公证。
- macOS 的隐私权限是按签名身份记账的。**换了签名身份或改成 ad-hoc 重新构建后，自动化权限可能失效，需要重新授权一次**；反复替换 app 时这种情况尤其常见。如果本机有稳定的代码签名身份，用它构建可以减少重新授权的次数。

## 安装与开机常驻

构建完成后可以安装到 `~/Applications` 并写入 LaunchAgent。建议先只校验，确认路径对了再安装：

```zsh
./Scripts/install-launch-agent.sh --check /tmp/AIQuotaBar-build/AIQuotaBar.app   # 只校验
./Scripts/install-launch-agent.sh /tmp/AIQuotaBar-build/AIQuotaBar.app           # 校验并安装
```

不传路径时脚本取 `${BUILD_DIR:-/tmp/AIQuotaBar-build}/AIQuotaBar.app`，与 `make` 的 `BUILD_DIR` 默认值一致；**显式传入的路径优先**。`--check` 只做校验就退出：不安装、不启动或终止任何进程、不创建目录、不写任何文件。

安装会：关掉已加载的同名 LaunchAgent 并结束正在运行的 AIQuotaBar → 用 `ditto` 把 app 复制到 `~/Applications/AIQuotaBar.app`（**会先 `rm -rf` 掉同名目标**）→ 写入 `~/Library/LaunchAgents/com.local.aiquotabar.plist` → `bootstrap` 并 `kickstart`。之后登录 macOS 会自动启动。所有校验都在产生任何副作用之前完成。

退出码：

| 码 | 含义 |
| --- | --- |
| 0 | 校验通过（`--check`）或安装完成 |
| 64 | 用法错误：未知选项，或给了多于一个路径 |
| 65 | 源不是有效的 `AIQuotaBar.app`：缺 `Contents/Info.plist`、`CFBundleIdentifier` 不符，或缺少带可执行位的 `Contents/MacOS/AIQuotaBar` |
| 66 | 源路径不可用：为空、是根目录、不存在，或不是目录 |
| 69 | 源与安装目标冲突：同一路径，或任一位于另一个内部 |
| 73 | 安装目标不可用：它本身是符号链接，或已存在但不是合法的 `AIQuotaBar.app` |

安装会在 `ditto` 之前 `rm -rf` 安装目标，所以 69 和 73 这两组检查都是必要的：

- **69**：源等于目标、或任一位于另一个内部时必须拒绝，否则会把源一起删掉。源路径会被完整物理规范化，用别名或 `..` 绕回目标也挡得下；比较时还会把安装目标的叶子换成磁盘上的真实拼写并兜底比对设备号 + inode，所以在 Mac 默认的大小写不敏感卷上，`aiquotabar.app` 与 `AIQuotaBar.app` 这种「同一个文件、不同拼写」同样会被认出来（大小写敏感卷上两者确实是不同 bundle，不会被误拒）。
- **73**：源与目标的解析方式**刻意不对称**。源只被读取，所以整条路径（含叶子）都做物理规范化；安装目标会被删除并写入，所以**只规范化父目录，叶子保持字面量**。如果 `~/Applications/AIQuotaBar.app` 本身是一个符号链接，跟随它就会把链接指向的目录整个删掉 —— 所以直接拒绝，由你决定怎么处理那个链接（`~/Applications` 自己是符号链接没问题，那是常见布局）。同理，已存在的目标必须确实是一个合法的 `AIQuotaBar.app` 才允许被替换：不会因为目录名字像 app 就删掉它。

## 卸载

本节只是说明，**脚本不会帮你执行**。确认每条命令后再自行运行：

```zsh
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.local.aiquotabar.plist
rm -f ~/Library/LaunchAgents/com.local.aiquotabar.plist
rm -rf ~/Applications/AIQuotaBar.app
rm -rf ~/Library/Application\ Support/AIQuotaBar   # 配置与本机统计缓存
```

然后到「系统设置 → 隐私与安全性 → 自动化」里移除 AIQuotaBar 控制 Google Chrome 的授权。

## 已知限制

- **解析依赖网页结构。** 额度页的文案或布局一变，解析就可能失效或缺值；本仓库的解析规则是对照截至 **2026-10-26** 的页面校准的。缺值时应用显示「缺值」而不是猜一个数字，但你仍然需要等一次更新。
- **只支持 Google Chrome**，不支持 Safari / Arc / Edge / Chromium 衍生版本；页面必须已登录并保持打开。
- **需要用户在 Chrome 和系统设置里各开一个开关**，无法完全自动完成。
- 界面与菜单目前只有中文。
- 源码里有一批**不可达的遗留代码**：API 计费卡片、Claude Desktop 目录探测，以及未接入任何菜单项的 `revealSetupScriptAction`。它们都没有调用者，运行时执行不到（见上面「关于 API 计费与遗留代码」）。其中的提示文案还引用着 `Scripts/set-key.sh`，而这个脚本不在本仓库里 —— 那些文案本身也永远不会被显示。本轮不做清理，以保持与已验收构建逐字节一致。
- `Tests/run_snapshot_test.sh` 需要 Chrome 自动化权限，并依赖 `rg`（ripgrep）；它不在 `make test` 里。

## 免责声明

AIQuotaBar 是**第三方非官方**工具，与 OpenAI、Anthropic 及 Google 没有任何隶属、赞助或背书关系。Codex、ChatGPT、Claude、Chrome 等名称归各自权利人所有。它读取的是你自己已登录、已打开的页面所显示的文字，不绕过任何登录或访问控制；数值仅供参考，请以官方页面为准。按 MIT 许可「按原样」提供，不含任何担保。

## 许可证

[MIT](LICENSE) © 2026 jixuan-skylake
