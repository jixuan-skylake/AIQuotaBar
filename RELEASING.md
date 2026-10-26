# 发布流程（维护者）

这份流程只针对**公开发布**。它刻意是手动的：没有任何一步会自动发布未经审核的代码。

## 不变约定

- **固定资产名** `AIQuotaBar-macOS-arm64.dmg`。README 的 latest 直链依赖它，换名字会直接把所有已发布的下载链接打断。
- **保留旧 Release**。不删除、不改写历史 Release 与资产；老版本的下载链接应当继续可用。
- **版本号四处必须一致**：`Info.plist` 的 `CFBundleShortVersionString`、`Sources/AIQuotaBar/main.swift` 的 `appVersion`、`CHANGELOG.md` 最新条目、以及 git tag（`v` + 版本号）。`CFBundleVersion`（build 号）每次公开发布都要递增。`Tests/release_check_test.sh` 会检查前三项；tag 由发布者负责对上。
- **只发布 Apple Silicon（arm64）**，最低 macOS 13.0。要改架构或最低系统，先改 `Scripts/build-release.sh` 里的常量和 `Info.plist`，让回归测试把它们重新钉住，并在 CHANGELOG 的「已知限制」里写清楚。
- **ad-hoc 签名、不做公证**。不要在流程里加入读取个人证书、导出 Keychain 秘密或关闭 Gatekeeper 的步骤。

## 步骤

### 1. 准备

```zsh
make test                      # 本地确定性测试
./Tests/install_check_test.sh  # 安装脚本校验回归
./Tests/release_check_test.sh  # 打包边界回归
```

更新 `CHANGELOG.md`：新增一节，写明 **新增 / 修复 / 已知限制**。如果版本号要变，同时改 `Info.plist`（`CFBundleShortVersionString` 与 `CFBundleVersion`）和 `main.swift` 的 `appVersion`。

### 2. 评审后合并

开 PR，等 CI 绿。**CI 通过不等于可以发布** —— 代码要经过人工评审才合并。不要用管理员权限绕过保护或跳过检查。

### 3. 从合并后的干净提交构建

公开包必须来自已合并、已审核的提交，不能拿 PR 之前的测试包冒充：

```zsh
git switch main && git pull --ff-only
git status --porcelain        # 必须为空
./Scripts/build-release.sh    # 工作树不干净时会直接拒绝
```

产物在 `dist/`（已被 `.gitignore` 忽略）：

- `AIQuotaBar-macOS-arm64.dmg`
- `SHA256SUMS`
- `AIQuotaBar-macOS-arm64.build-info.txt` —— 来源证据（提交、架构、`minos`、签名方式、版本、bundle 内每个文件的 SHA256）。**只留在本地**，不随 Release 上传。

脚本自己会做：钉死 `arm64-apple-macos13.0`、把签名身份固定为 ad-hoc、构建后跑 `make test`、从 Mach-O 的 load commands 核实架构与 `minos`、按白名单裁剪 bundle、ad-hoc 重签并核实签名形态（`Signature=adhoc`、无 `Authority`、无 `TeamIdentifier`）、`hdiutil verify`、只读挂载后逐文件比对、从挂载点跑 `--version` 与 `--self-test`。

关于失败与覆盖，有三点需要知道：

- **DMG 先在独立临时目录里生成并完成全部校验，只有全部通过才会搬进输出目录。** 任何一步不过就中止，输出目录里不会留下未经验证的半成品包。
- **失败时临时目录会被保留**（路径会打印在 stderr 里），构建日志与 manifest diff 都在里面，便于排查；确认之后请自行移除。成功时它会被自动删除。
- **产物永不覆盖。** 三个输出叶子（DMG、`SHA256SUMS`、来源证据）任何一个已经存在，或者是符号链接 / 目录 / 特殊文件，脚本都会直接拒绝 —— 符号链接尤其危险，写入会落到它指向的地方，所以刻意没有提供任何 `--force` 来绕过。要重新打包请先移走旧产物，或用 `--output` 指向一个新的空目录。
- **落地用独占创建，而不是 `mv`。** 每个叶子都以 `O_CREAT|O_EXCL` 打开后写入，再按 SHA256 回验。这一步不是「先检查再移动」：即使在最后一次检查之后、真正写入之前，叶子上冒出了文件、目录或指向目录的符号链接，提交也会直接失败，不会覆盖、也不会把产物写进链接指向的目录。（普通 `mv` 甚至 `mv -n` 都挡不住「目标是目录符号链接」这一种 —— 它们会把目标当容器，把文件塞进去。）
- **「原子」的确切范围要说清楚。** 原子的是**独占创建那一步**：那个路径要么由本次新建，要么直接失败。**文件内容的复制过程不是原子的**，所以在写入过程中去读那个文件，可能看到不完整的中间状态；也不要把「产物已出现」当成「产物已写完并核验过」。源摘要失败、写入失败、目标摘要执行失败、摘要不匹配这四种情况都会以退出码 70 终止，并删掉本次自己创建的那个半成品文件 —— 只删本次创建的，绝不删既存文件或链接。
- **异常终止与外部替换是已知边界。** 进程被 `SIGKILL` 或机器断电时 trap 不会运行，已创建但没写完的文件**不会**被自动清理；这种情况请把输出目录视为不可信，自行清掉后重新打包。如果外部在创建之后把那个路径换成了别的东西，脚本只能删除该路径上的目录项（`rm` 不跟随符号链接），无法分辨它还是不是自己写的那个文件。
- **跨卷输出是支持的。** 落地是通过文件描述符复制而不是 `rename(2)`，所以输出目录与临时目录不在同一个卷上也能正常工作，且上面那些拒绝规则同样生效。
- **三个文件不是一个整体事务。** 每个叶子单独是原子的；如果中间某一个失败，脚本会把本次已经落地的那几个回滚删掉，所以输出目录里不会留下「只写了一两个」的半套产物。但它不提供「要么三个全有、要么一个都没有」那种数据库级事务保证 —— 失败后请以 stderr 里的回滚提示为准，并重新打包。

另外，脚本要求源码来自**真实的 Git 仓库顶层且有有效 HEAD**：不在仓库里、没有提交、从子目录运行、或 `git status` 查询失败，都会直接拒绝 —— 查不到来源绝不会被降级成「clean」。`--allow-dirty` 只放宽「工作树有改动」，不放宽「没有有效来源」。

核对 `build-info` 里的 `source-commit` 等于你要发布的那个合并 SHA，且 `worktree-state` 是 `clean`。

### 4. 打 tag

```zsh
git tag -a v<版本号> <合并SHA> -m '<中文说明>'
```

tag 必须精确指向那个合并提交。

### 5. 先发 draft，回验后再公开

先建 **draft** Release，上传 `AIQuotaBar-macOS-arm64.dmg` 与 `SHA256SUMS`，写中文版本说明（可直接取 CHANGELOG 对应小节）。

上传时不要覆盖已存在的 Release 或资产。然后**从 Release 页面把 DMG 下载回来回验**：

```zsh
shasum -a 256 -c SHA256SUMS          # 必须 OK
hdiutil verify <下载回来的 dmg>       # 必须通过
```

字节数与 SHA256 都要和本地 `build-info` 对得上。确认无误后才把 Release 从 draft 改为公开并设为 latest。

### 6. 公开之后

确认这两个入口都真的可用：

- Release 页面：`https://github.com/jixuan-skylake/AIQuotaBar/releases/latest`
- 直链：`https://github.com/jixuan-skylake/AIQuotaBar/releases/latest/download/AIQuotaBar-macOS-arm64.dmg`

仓库 homepage 指向 latest Release 页面；仓库简介继续描述产品本身。

## 不要做的事

- 不要让 CI 自动创建 Release 或上传资产。CI 只跑测试，仓库权限保持只读，不需要任何 secret。
- 不要发布未经评审合并的代码，也不要用本地未提交的改动直接打包发布。
- 不要声称已通过 Apple 公证、Gatekeeper 不再提示、Intel 已验证，或已在 macOS 13 真机上测过 —— 除非确实做了并且有证据。deployment target 检查不等于真机兼容测试。
- 不要在 Release 说明、tag 或 commit 里写内部评审过程、本机路径或任何真实账号用量。
