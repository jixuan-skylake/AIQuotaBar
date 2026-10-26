# 贡献指南

欢迎 issue 和 pull request。这是一个小项目，流程尽量简单。

## 开发环境

macOS 13.0+ 和 Xcode 命令行工具（需要 `swiftc`、`codesign`、`iconutil`）。没有第三方依赖，也没有包管理器。

```zsh
make test
```

`make test` 必须通过才提 PR。它完全本地、确定性：只用仓库内的合成文本和临时目录，不需要 Chrome 自动化权限，也不读取用户会话内容。`--self-test` 结束时会打印自己的断言通过 / 失败计数。

改动 `Scripts/install-launch-agent.sh` 时还要跑 `./Tests/install_check_test.sh`（只调用 `--check`，不执行真实安装）。两者都在 CI 里作为独立步骤运行。

`make benchmark` / `make diagnostics` / `make snapshot` 会读取本机数据或需要 Chrome 自动化权限，**不在** `make test` 里，请只在本机按需运行，不要加进 CI。

## 改解析规则时

网页额度的解析是这个项目最容易因上游页面改版而失效的部分。如果你要改它：

- 把新页面的**文本**（不是截图，也不要带账号信息）加成 `Sources/AIQuotaBar/ChromeSelfTests.swift` 里的合成用例，正例反例都要有。
- 解析器和「就绪探针」是两套实现，用例需要同时断言两端结论一致——只改一边会被 `--self-test` 拦住。
- 缺值时宁可显示「缺值」，不要借用相邻栏目的数字或猜一个值。

## 提交前请确认

- 不包含任何真实账号数据：用量数字、重置时间、session id、绝对的个人目录路径、API Key、cookie、token。
- 不包含截图里的个人信息。
- 不提交 `build/`、`dist/`、本机 `config.json` 或统计缓存（`.gitignore` 已覆盖，但请再看一眼 `git status`）。
- commit message 用一句话说清改了什么。

## 代码风格

跟着现有代码走：四空格缩进，注释用中文，只注释不自明的边界条件和契约。不引入新依赖。

## 报告安全问题

请不要开公开 issue，见 [SECURITY.md](SECURITY.md)。
