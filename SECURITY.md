# 安全策略

## 支持范围

安全修复只针对最新版本，没有长期支持分支。当前版本见 `Info.plist` 的 `CFBundleShortVersionString`。这是个人维护的小项目，**没有承诺的响应或修复时限**。

## 报告漏洞

**请不要开公开 issue。** 请用 GitHub 的私密漏洞报告：本仓库 **Security → Report a vulnerability**（Private vulnerability reporting）。

该入口需要仓库侧启用 GitHub 的 Private vulnerability reporting 之后才会出现。如果你在 Security 页看不到它，说明此刻尚未启用 —— 这种情况下请先开一个**不含任何敏感细节**的 issue，只说明「有安全问题需要私下沟通」，由维护者联系你；不要在公开 issue 里贴复现步骤。

报告里请尽量包含：

- 影响的版本与 macOS 版本；
- 复现步骤或最小用例；
- 你认为的影响面。

请**不要**在报告里附上真实的 cookie、session token、API Key 或个人用量数据——复现所需的信息用占位值或合成文本就够了。

会尽力在同一个私密线程里同步进展；如果最终发布 advisory，会在其中致谢（可以要求匿名）。如上所述，没有承诺的时限。

## 在意的问题类型

- 本应只对两个额度页执行的 JavaScript 被诱导到其它页面执行（URL 契约绕过）。
- Apple Events 被发给非预期的进程（Chrome 实例身份校验绕过）。
- 本机统计缓存 `~/Library/Application Support/AIQuotaBar/claude-usage-cache.json` 的权限或路径处理问题导致私有数据（项目路径、session id）泄露。
- 解析逻辑在恶意页面文本上导致崩溃、挂死或资源耗尽。
- 构建或安装脚本里的命令注入、不安全的临时文件、非预期的文件删除。

## 不属于漏洞的情况

- 上游额度页改版导致解析失效或缺值——这是功能性 issue，欢迎开公开 issue。
- 需要用户在 Chrome 里开启「允许 Apple 事件中的 JavaScript」、并在系统设置里授予自动化权限：这是设计上必需的，且都由用户显式授权。
- 默认构建是 ad-hoc 签名、未经 Apple 公证，因此首次打开需要用户确认——这是已知且在 README 中说明的限制。
- 同一个用户在正常设计下访问自己的文件（例如你自己能读到自己的配置与统计缓存）不算漏洞。但**意外的信息泄露、越权或权限提升**仍然欢迎报告 —— 比如私有数据被写到设计之外的位置、文件或目录权限比设计更宽、或者非特权上下文能影响本应受保护的行为。
