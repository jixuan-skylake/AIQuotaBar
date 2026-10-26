# 更新记录

本文件只记录**公开发布**的版本。

0.2.18 是 AIQuotaBar 的**第一个公开安装包**。在它之前的版本只在私有构建里存在过，从未公开发布，也没有过公开下载入口 —— 所以这里不为它们编造发布日期或版本条目。为了不把功劳混在一起，0.2.18 的条目把三类改动分开写：本轮为公开分发新做的、开源准备期间做的、以及应用本体此前已在私有构建中完成、这次才第一次公开发布的。

版本号沿用应用自身的 `CFBundleShortVersionString`，`build` 对应 `CFBundleVersion`。

## 0.2.18（build 20）— 首个公开安装包

### 新增（本轮为公开分发而做）

- **首个公开 DMG**：固定资产名 `AIQuotaBar-macOS-arm64.dmg`，Apple Silicon（arm64），最低 macOS 13.0。
- README 顶部的「下载最新版」入口与 latest 直链，以及本更新记录。
- 可复用的发布打包入口 `Scripts/build-release.sh`：在独立临时目录里构建、把架构与最低系统钉死为 `arm64-apple-macos13.0`、按白名单裁剪 app bundle、ad-hoc 重新签名、生成 DMG、`hdiutil verify`、只读挂载后逐文件比对内容与符号链接、从挂载点跑 `--version` / `--self-test`，最后输出 `SHA256SUMS` 与来源证据。它不安装、不启动 GUI、不读浏览器、不改任何用户配置。
- 维护者发布流程 `RELEASING.md`。
- 打包边界回归 `Tests/release_check_test.sh`：版本一致性、bundle 与 DMG 白名单、脚本安全边界、产物冲突不静默覆盖。已加入 CI。
- `Makefile` 增加 `SWIFTFLAGS` 参数（默认为空，所以默认构建行为与以前完全一致），供发布脚本钉死架构与最低系统。

### 改进（开源准备期间完成，随首个公开包一起发布）

- 安装脚本 `Scripts/install-launch-agent.sh` 加固，全部校验都在产生任何副作用之前完成：
  - 默认源路径与 `make` 的 `BUILD_DIR` 对齐（`${BUILD_DIR:-/tmp/AIQuotaBar-build}/AIQuotaBar.app`），显式参数优先。
  - 拒绝源与安装目标相同或互相包含，别名、`..` 绕回、以及大小写不敏感卷上「同一文件不同拼写」都挡得下（退出码 69）。
  - 拒绝安装目标本身是符号链接，或已存在但不是合法 bundle —— 避免顺着链接删掉它指向的目录，也不会因为目录名字像 app 就删除它（退出码 73）。
  - 新增只读 `--check` 模式：只校验就退出，不安装、不启停进程、不建目录、不写文件。
- 新增 `Tests/install_check_test.sh`：只调用 `--check` 的安装校验回归。
- 文档按真实调用链与真实边界重写：明确「应用自身不联网、无遥测」与「刷新时由 Chrome reload 额度页、因此整个流程并非完全离线」的区别；明确不读登录凭据但额度数字本身就是账户数据；明确源码里 API 计费相关代码路径没有调用者、不在采集链上。

### 修复（应用本体，此前已在私有构建中完成，这是首次公开发布）

- Claude 用量页 2026-10-26 新布局兼容：总周额度的全称标题「每周限额 · 所有模型」同样映射到 `All models`；同一页的 `Fable` 与「您使用 Claude 的地方」按产品占比都不是指标，不会被当成周额度；标题与数值之间出现的私用区图标码位（`U+E02A`）不再导致漏读。
- 状态栏选中的指标本次没有数值时，不再借用其它指标的数字：双行 A/C 模式该侧显示 `--`，「只显示 Claude」与「最低额度」两档退回 `AI`。

### 已知限制

- **只提供 Apple Silicon（arm64）包。** 没有提供、也没有测试 Intel 或 Universal 版本。
- 包是本地 ad-hoc 签名，**未经 Apple 公证**，不具备 Developer ID 身份；首次打开需要你手动确认来源。不需要也不建议为此关闭 Gatekeeper。
- **没有自动更新。** 升级需要到 Releases 页面重新下载。
- 最低系统 macOS 13.0 来自构建时的 deployment target 与 `LSMinimumSystemVersion` 声明，**尚未在 macOS 13 真机上做过兼容测试**。
- 额度读取依赖 Google Chrome 与上游网页结构：需要保持额度页已登录并打开、在 Chrome 开启「允许 Apple 事件中的 JavaScript」、并授予 macOS 自动化权限；页面改版可能导致解析失效或缺值。
- 界面与菜单目前只有中文。

## 以后每个版本都要写什么

每个公开版本至少写明 **新增**、**修复**、**已知限制** 三节，不要留空，也不要只写一句「bug 修复」。另外：

- 解析规则、权限要求、最低系统或支持架构有变化时必须单独点出来 —— 那会直接决定用户要不要重新授权或重新下载。
- 版本号、tag、`Info.plist` 的 `CFBundleShortVersionString` / `CFBundleVersion`、以及 `--version` 的输出必须一致（`Tests/release_check_test.sh` 会检查前几项）。
- 不要在这里写内部评审过程、本机路径或任何真实账号用量。
