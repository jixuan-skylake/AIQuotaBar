import Foundation
import JavaScriptCore

// MARK: - Chrome 实例选择 / PID 定址 / 读取流程的确定性自检
//
// 职责：用合成候选、可编程 mock 传输层与虚拟单调时钟覆盖 0.2.14（含 R1 整改）与 0.2.15（Codex 地址适配）的浏览器读取行为。
// 所有测试不触碰真实 Chrome、不发送任何 Apple Event、不读取用户数据；就绪探针用 JavaScriptCore 在假 document 上真实执行。
// 覆盖：实例分类与严格身份（内核启动时间精确相等、缺失 fail-closed、自动化优先）；严格网址契约（表驱动正反例）；
// 就绪探针（Current-session-only / 全栏目 / 加载中 / 空白 / 错误页）；传输边界（发送前身份、回复后身份、预算、取消、
// 等待上限）；读取流程契约（reload 失败 / 未就绪 / 寻址失败 / 标签消失一律不读取、不产生可当成功的数值）；
// 预算与看门狗（阻塞枚举后多窗口、多目标、超时后第二轮全部零事件）；端到端沿用（T0 成功 → T1 各类失败不覆盖 → T2 才更新）。

final class MockChromeReadClock: ChromeReadClock {
    private(set) var current: TimeInterval = 1_000
    private(set) var sleeps: [TimeInterval] = []

    func uptime() -> TimeInterval { current }

    func sleep(_ seconds: TimeInterval) {
        sleeps.append(seconds)
        current += seconds
    }

    /// 模拟某次调用阻塞了这么久才返回。
    func advance(_ seconds: TimeInterval) {
        current += seconds
    }
}

/// 可编程的 Chrome 传输层 mock：与真实传输层一样在每次调用的边界检查预算 / 取消与身份（发送前 + 回复后），
/// 记录每一次调用，按脚本返回成功 / 失败 / loading / 就绪。
final class MockChromeTransport: ChromeTransport {
    struct Tab: Equatable {
        var tabID: String
        var url: String
    }

    let pid: pid_t
    var windows: [(id: String, tabs: [Tab])]
    var budget: ChromeReadBudget?
    var clock: MockChromeReadClock?
    private(set) var log: [String] = []
    var identityFailureAfterCalls: Int?
    var identityFailureReason = "Chrome 进程已退出（mock）"
    private(set) var identityCalls = 0
    /// 第 N 次事件发送前身份失效（传输边界）。
    var boundaryIdentityFailAtEvent: Int?
    /// 第 N 次事件回复到达后身份失效（回复不得采纳）。
    var boundaryIdentityFailAfterReplyOfEvent: Int?
    private(set) var eventAttempts = 0
    var windowsError: ChromeEventError?
    var tabsErrors: [String: ChromeEventError] = [:]
    var urlErrors: Set<String> = []
    /// 0.2.15：操作前复核（用 `tab id … of window id …` 重新读 URL）时返回的网址覆盖。
    /// 枚举快照仍是原网址，所以能单独测到「枚举之后、操作之前标签跳到无关页面」这一道复核。
    var liveURLOverrides: [String: String] = [:]
    var reloadErrors: [String: ChromeEventError] = [:]
    var probeErrors: [String: ChromeEventError] = [:]
    var readErrors: [String: ChromeEventError] = [:]
    /// tab 在第 n 次快照（含）之前 loading = true。
    var loadingUntilSnapshot: [String: Int] = [:]
    var readyAfterProbe: [String: Int] = [:]
    var pageText: [String: String] = [:]
    var afterSnapshot: ((MockChromeTransport, Int) -> Void)?
    /// 真实线程阻塞（看门狗线程测试）。
    var windowsDelay: TimeInterval = 0
    /// 虚拟时钟推进：模拟调用阻塞很久才返回。
    var windowsVirtualDelay: TimeInterval = 0
    var reloadVirtualDelay: TimeInterval = 0
    var probeVirtualDelay: TimeInterval = 0
    /// 按标签的探测阻塞时长（模拟"最后一个目标慢响应"）。
    var probeVirtualDelays: [String: TimeInterval] = [:]
    private(set) var snapshotCount = 0
    private(set) var probeCounts: [String: Int] = [:]

    init(pid: pid_t, windows: [(id: String, tabs: [Tab])]) {
        self.pid = pid
        self.windows = windows
    }

    var eventLog: [String] { log }

    var eventCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for entry in sentEvents {
            let key = String(entry.split(separator: " ").first ?? "")
            counts[key, default: 0] += 1
        }
        return counts
    }

    /// 真正发出的事件（不含 identity / refused / discarded 记录）。
    var sentEvents: [String] {
        log.filter { !$0.hasPrefix("identity") && !$0.hasPrefix("refused ") && !$0.hasPrefix("discarded ") }
    }

    func calls(withPrefix prefix: String) -> [String] {
        sentEvents.filter { $0.hasPrefix(prefix) }
    }

    /// 与真实传输层同一套边界：发送前 checkpoint + 等待粒度判定（整轮 / 页面阶段），回复后 deadline 与阶段上限判定。
    private func boundary<T>(_ label: String, stage: ChromeEventError.Stage, _ body: () throws -> T) throws -> T {
        eventAttempts += 1
        let index = eventAttempts
        if let budget {
            do {
                try budget.checkpoint(label)
            } catch {
                log.append("refused \(label)")
                throw error
            }
            if budget.eventWait(default: 15) == nil {
                log.append("refused \(label)")
                throw ChromeAppleEventTransport.insufficientBudgetError(budget: budget, stage: stage)
            }
        }
        if let limit = boundaryIdentityFailAtEvent, index >= limit {
            log.append("refused \(label)")
            throw ChromeEventError(stage: .identity, code: nil, message: "发送前身份核验失败（mock 事件 \(index)）")
        }
        log.append(label)
        let result = try body()
        if let limit = boundaryIdentityFailAfterReplyOfEvent, index >= limit {
            log.append("discarded \(label)")
            throw ChromeEventError(stage: .identity, code: nil, message: "回复到达后身份已变化，回复未采纳（mock 事件 \(index)）")
        }
        if let budget {
            do {
                try budget.checkpoint("回复后 \(label)")
            } catch let error as ChromeEventError {
                log.append("discarded \(label)")
                throw ChromeEventError(stage: .watchdog, code: nil, message: "回复到达时已超出整轮预算或已取消，回复未采纳: \(error.message)")
            }
            if budget.stageExceeded {
                log.append("discarded \(label)")
                throw ChromeEventError(stage: stage, code: nil, message: "回复到达时已超过页面就绪上限，回复不采纳", isStageLimit: true)
            }
        }
        return result
    }

    func verifyIdentity() throws {
        identityCalls += 1
        log.append("identity")
        if let limit = identityFailureAfterCalls, identityCalls > limit {
            throw ChromeEventError(stage: .identity, code: nil, message: identityFailureReason)
        }
    }

    /// `afterSnapshot(mock, n)` 在第 n 次快照（窗口 + 标签）完整结束之后、第 n+1 次快照开始之前触发。
    func windowIDs() throws -> [String] {
        if snapshotCount > 0 {
            afterSnapshot?(self, snapshotCount)
        }
        return try boundary("windows", stage: .enumerateWindows) {
            if windowsDelay > 0 { Thread.sleep(forTimeInterval: windowsDelay) }
            if windowsVirtualDelay > 0 { clock?.advance(windowsVirtualDelay) }
            if let windowsError { throw windowsError }
            snapshotCount += 1
            return windows.map(\.id)
        }
    }

    func tabs(inWindow windowID: String) throws -> [ChromeTabRef] {
        try boundary("tabs \(windowID)", stage: .enumerateTabs) {
            if let error = tabsErrors[windowID] { throw error }
            guard let window = windows.first(where: { $0.id == windowID }) else {
                throw ChromeEventError.fromOSStatus(-1728, stage: .enumerateTabs, chromeMessage: nil)
            }
            return window.tabs.map { ChromeTabRef(windowID: windowID, tabID: $0.tabID, url: $0.url) }
        }
    }

    private func tab(_ windowID: String, _ tabID: String) -> Tab? {
        windows.first(where: { $0.id == windowID })?.tabs.first(where: { $0.tabID == tabID })
    }

    func tabURL(windowID: String, tabID: String) throws -> String {
        try boundary("url \(windowID)/\(tabID)", stage: .verifyTarget) {
            if urlErrors.contains(tabID) {
                throw ChromeEventError.fromOSStatus(-1728, stage: .verifyTarget, chromeMessage: nil)
            }
            guard let tab = tab(windowID, tabID) else {
                throw ChromeEventError.fromOSStatus(-1728, stage: .verifyTarget, chromeMessage: nil)
            }
            // 标签仍然存在，但复核读到的网址已经变了（模拟操作前跳转）。
            return liveURLOverrides[tabID] ?? tab.url
        }
    }

    func tabLoading(windowID: String, tabID: String) throws -> Bool {
        try boundary("loading \(windowID)/\(tabID)", stage: .probe) {
            guard tab(windowID, tabID) != nil else {
                throw ChromeEventError.fromOSStatus(-1728, stage: .probe, chromeMessage: nil)
            }
            if let until = loadingUntilSnapshot[tabID] {
                return snapshotCount <= until
            }
            return false
        }
    }

    func reload(windowID: String, tabID: String) throws {
        try boundary("reload \(windowID)/\(tabID)", stage: .reload) {
            if reloadVirtualDelay > 0 { clock?.advance(reloadVirtualDelay) }
            if let error = reloadErrors[tabID] { throw error }
        }
    }

    func executeJavaScript(windowID: String, tabID: String, script: String, purpose: ChromeJavaScriptPurpose) throws -> String {
        switch purpose {
        case .probe:
            return try boundary("probe \(windowID)/\(tabID)", stage: .probe) {
                if probeVirtualDelay > 0 { clock?.advance(probeVirtualDelay) }
                if let delay = probeVirtualDelays[tabID], delay > 0 { clock?.advance(delay) }
                if let error = probeErrors[tabID] { throw error }
                probeCounts[tabID, default: 0] += 1
                return probeCounts[tabID, default: 0] >= (readyAfterProbe[tabID] ?? 1) ? "1" : "0"
            }
        case .read:
            return try boundary("read \(windowID)/\(tabID)", stage: .read) {
                if let error = readErrors[tabID] { throw error }
                return pageText[tabID] ?? ""
            }
        }
    }
}

extension SelfTest {
    static let mockCodexText = """
    Codex 分析
    每周使用限额
    68% 剩余
    重置时间: 2026年9月8日 10:00
    """

    static let mockCodexTextT2 = """
    Codex 分析
    每周使用限额
    40% 剩余
    重置时间: 2026年9月8日 10:00
    """

    /// 用户 2026-10-04 新页面截图的逐字文本（Root 已确认）。周额度下方紧跟着充值余额与重置历史，
    /// 说明句里也顺带提到「每周限额」——这三处正是必须挡住的误取来源。
    /// 83% 只是截图时刻的值，仅作合成回归用，不代表任何线上结果。
    static let mockCodexScreenshotText = """
    使用情况
    概览
    分析
    套餐限额
    Codex、Work、工作空间智能体和 ChatGPT for Excel 共享使用额度。Chat 模式下的对话不计入此用量。
    每周限额
    5 天 17 小时后重置
    剩余 83%
    立即重置你的用量限制
    购买即时重置
    额度
    剩余额度：62,500
    当前余额
    自动充值
    使用限额重置
    使用一次重置，即可恢复你的 5 小时限额、每周限额，或同时恢复两者
    可用 0
    历史记录
    过去 30 天
    已使用重置次数
    9月30日
    GMT+8 09:12
    """

    /// 用户 2026-10-11 新 usage 页截图的逐字文本（Root 已确认）。与 10-04 那份的差别只有一处结构性变化：
    /// 倒计时写成「6天15小时 后重置」—— 数字与单位之间不再留空格，而**单位与「后重置」之间多了一处空白**
    /// （真实 DOM 在这里断行 / 插空格）。0.2.16 的中文倒计时要求单位紧贴「后重置」，所以这一份整条失配。
    /// 91% / 58,612 只是截图时刻的值，仅作合成回归用，不代表任何线上结果。
    static let mockCodexSpacingScreenshotText = """
    套餐限额
    每周限额
    6天15小时 后重置
    剩余 91%
    立即重置你的用量限制
    购买即时重置
    额度
    剩余额度：58,612
    当前余额
    自动充值
    使用限额重置
    使用一次重置，即可恢复你的5小时限额、每周限额，或同时恢复两者
    """

    static let mockClaudeText = """
    Plan usage limits
    Current session
    23% used
    Resets in 3h 12m
    All models
    41% used
    Claude Design
    7% used
    """

    static let mockClaudeSessionOnlyText = """
    Plan usage limits
    Current session
    7% used
    Resets in 3h 12m
    Last updated: less than a minute ago
    """

    /// 用户 2026-10-11 新中文用量页截图的逐字文本（Root 已确认）。总周额度「本周」下方紧跟着
    /// 「本周 Fable」的单独每周限额，再往下是四个没有百分比的栏目（限额重置 / 云会话额度 /
    /// 包含的额度 / 用量额度 US$…）—— Fable 的 3% 正是必须挡住的误取来源。
    /// 0% / 68% / 3% 只是截图时刻的值，仅作合成回归用，不代表任何线上结果。
    static let mockClaudeScreenshotText = """
    您的用量 Max (20x)
    进展正常。您应该能够宽裕地用到明天的重置时间。
    当前会话
    从您的第一条消息开始
    已使用 0%
    本周
    星期一05:00 重置
    已使用 68%
    本周 Fable
    Fable 的单独每周限额 · 星期一
    05:00 重置
    已使用 3%
    限额重置
    暂无重置
    您获得后，它会连同到期日期一起显示在此处。
    云会话额度
    自动应用于云会话。该额度用完或过期后，将按您套餐的常规用量计算。
    包含的额度
    11月5日 GMT+8 15:59 过期
    剩余 US$250（共 US$250）
    用量额度
    US$0
    """

    /// 用户 2026-10-26 两张新布局截图的逐字文本（Root 已确认）：第一张周栏折叠，第二张展开，
    /// 展开那张就是折叠那张**后面紧跟**更多栏目，所以这里把折叠全文原样写在展开全文的开头
    /// （下面有一条断言钉住这个前缀关系）。与 10-11 那份比有四处结构性变化，每一处都让 0.2.17 失配：
    ///   1. 总周额度的标题从「本周」换成全称「每周限额 · 所有模型」（0.2.17 完全不认识这个标题）；
    ///   2. 当前会话的倒计时是中文小时 + 分钟复合写法「1小时 37 分钟后重置」（0.2.17 的中文倒计时
    ///      只接受单个单位，复合写法整条失配，于是当前会话缺值）；
    ///   3. 重置的星期写成简称「周一」而不是「星期一」；
    ///   4. 展开后多出 Fable（标题也从「本周 Fable」变成「Fable」）、限额重置、以及
    ///      「您使用 Claude 的地方」里按产品的请求占比 —— `Claude Code` / `100%` 是本轮新增的、
    ///      必须挡住的误取来源（它是请求占比，不是额度）。
    /// 8% / 2% / 0% / 100% 只是截图时刻的值，仅作合成回归用，不代表任何线上结果。
    static let mockClaudeCollapsedScreenshotText = """
    当前会话
    1小时 37 分钟后重置
    已使用 8%
    每周限额 · 所有模型
    周一05:00 重置
    已使用 2%
    """

    static let mockClaudeExpandedScreenshotText = """
    当前会话
    1小时 37 分钟后重置
    已使用 8%
    每周限额 · 所有模型
    周一05:00 重置
    已使用 2%
    Fable
    最多为您每周限额的 50%
    周一05:00 重置
    已使用 0%
    限额重置
    暂无重置
    您使用 Claude 的地方
    按产品
    按设备
    占您本周请求的比例
    Claude Code
    100%
    """

    /// 新布局里「总周额度缺值、当前会话有值」的页面：总周额度标题与重置都在，就是没有数值，
    /// 下面紧跟着 Fable 的 0%。这一份同时是解析层（不借 Fable 的值）与状态栏层（选 All models
    /// 时必须显示 `--`，不能回退到当前会话的数）两处回归的锚点。
    static let mockClaudeWeekMissingText = """
    当前会话
    1小时 37 分钟后重置
    已使用 8%
    每周限额 · 所有模型
    周一05:00 重置
    Fable
    最多为您每周限额的 50%
    周一05:00 重置
    已使用 0%
    """

    /// Root 2026-10-26 真实页面实测（正式整改 1/3）。初稿独立构建 2693 项全过，但真实 Claude 页上
    /// 总周额度只有标题、没有数值；Root 在独立临时副本里只给 Swift 解析器加了元数据日志
    /// （不改 Chrome 传输与页面脚本、不输出正文），对完整精确标题「每周限额 · 所有模型」之后的 3 行
    /// 只报码位数、单码位行才报码点，两个 Claude 标签结果一致：
    ///   第 1 行 码位数 1、码点 e02a ／ 第 2 行 码位数 10 ／ 第 3 行 码位数 6
    /// （证据 /tmp/AIQuotaBar-layout-fix-20261026-rI4QJU/metadata-live-read.txt）
    /// 也就是「标题 / 一个 U+E02A（私用区图标字体字符）/ 周一05:00 重置（10 码位）/ 已使用 N%（6 码位）」。
    /// 初稿的图标白名单里没有 U+E02A，所以这一栏整条失配——本轮只登记这一个实测字符，
    /// **不**推断另一折叠状态对应的其它私用区字符。那份临时日志代码不进产品源码。
    /// 8% / 2% 只是合成回归用的值，不代表任何线上结果。
    static let mockClaudeIconMarkerText = """
    当前会话
    1小时 37 分钟后重置
    已使用 8%
    每周限额 · 所有模型
    \u{e02a}
    周一05:00 重置
    已使用 2%
    """

    /// 同一个实测图标，但总周额度这一栏没有数值，后面紧跟 Fable 的 0% 与按产品占比的 100%。
    /// 登记图标**只打开「标题之后一个已登记字面量」这一个槽位**，不会让后面的数字变得可借。
    static let mockClaudeIconMarkerWeekMissingText = """
    当前会话
    1小时 37 分钟后重置
    已使用 8%
    每周限额 · 所有模型
    \u{e02a}
    周一05:00 重置
    Fable
    最多为您每周限额的 50%
    周一05:00 重置
    已使用 0%
    限额重置
    暂无重置
    您使用 Claude 的地方
    按产品
    按设备
    占您本周请求的比例
    Claude Code
    100%
    """

    static let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    static let laterNow = Date(timeIntervalSince1970: 1_800_000_600)

    static func startTime(_ seconds: Int = 1_800_000_000, _ microseconds: Int32 = 123_456) -> ChromeProcessStartTime {
        ChromeProcessStartTime(seconds: seconds, microseconds: microseconds)
    }

    static func candidate(
        _ pid: pid_t,
        arguments: [String]?,
        startTime: ChromeProcessStartTime? = startTime(),
        bundle: String? = "/Applications/Google Chrome.app",
        launch: TimeInterval? = 1_800_000_000
    ) -> ChromeInstanceCandidate {
        ChromeInstanceCandidate(
            pid: pid,
            startTime: startTime,
            launchDate: launch.map { Date(timeIntervalSince1970: $0) },
            bundleURL: bundle.map { URL(fileURLWithPath: $0) },
            arguments: arguments,
            argumentError: arguments == nil ? "mock: 读取失败" : nil
        )
    }

    static func chromeArguments(_ flags: [String]) -> [String] {
        ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"] + flags
    }

    static func standardWindows() -> [(id: String, tabs: [MockChromeTransport.Tab])] {
        [
            (id: "10", tabs: [
                MockChromeTransport.Tab(tabID: "100", url: BrowserUsageTargets.codexUsageURL),
                MockChromeTransport.Tab(tabID: "101", url: "https://example.com/private-page"),
                MockChromeTransport.Tab(tabID: "102", url: "https://example.test/?next=claude.ai/new#settings/usage")
            ]),
            (id: "20", tabs: [
                MockChromeTransport.Tab(tabID: "200", url: "https://claude.ai/new?redirect=claude.com&via=static_google_success#settings/usage")
            ])
        ]
    }

    static func standardMockTransport(pid: pid_t = 100) -> MockChromeTransport {
        MockChromeTransport(pid: pid, windows: standardWindows())
    }

    static func standardOptions(reload: Bool = true, timeout: Double = 30, settle: Double = 2) -> ChromeReadOptions {
        ChromeReadOptions(reloadBeforeRead: reload, reloadWaitSeconds: settle, reloadTimeoutSeconds: timeout)
    }

    struct ReaderRun {
        let report: ChromeReadReport
        let clock: MockChromeReadClock
        let transport: MockChromeTransport
        let budget: ChromeReadBudget
    }

    /// 读取流程测试入口：mock 传输层与读取器共用同一份预算与虚拟时钟。
    static func runReader(
        options: ChromeReadOptions = standardOptions(),
        budgetSeconds: TimeInterval? = nil,
        cancelBeforeStart: Bool = false,
        now: Date = fixedNow,
        configure: (MockChromeTransport) -> Void = { _ in }
    ) -> ReaderRun {
        let clock = MockChromeReadClock()
        let budget = ChromeReadBudget(clock: clock, seconds: budgetSeconds ?? options.watchdogSeconds)
        let transport = standardMockTransport()
        transport.clock = clock
        transport.budget = budget
        transport.pageText = ["100": mockCodexText, "200": mockClaudeText]
        configure(transport)
        if cancelBeforeStart { budget.cancel() }
        let reader = ChromeQuotaReader(transport: transport, clock: clock, options: options, budget: budget, now: { now })
        return ReaderRun(report: reader.read(), clock: clock, transport: transport, budget: budget)
    }

    static func outcome(_ run: ReaderRun, options: ChromeReadOptions = standardOptions()) -> ChromeQuotaReadOutcome {
        let decision = ChromeInstanceDiscovery.decide(candidates: [candidate(run.transport.pid, arguments: chromeArguments([]))])
        return ChromeQuotaReadOutcome(
            options: options,
            decision: decision,
            report: run.report,
            watchdogTimedOut: false,
            eventLog: run.transport.eventLog,
            eventCounts: run.transport.eventCounts,
            elapsed: 0
        )
    }

    /// 端到端服务依赖：合成候选 + mock 传输层（共用服务创建的预算）+ 虚拟时钟 + 固定墙钟。
    static func mockDependencies(
        candidates: [ChromeInstanceCandidate],
        now: Date = fixedNow,
        clock: MockChromeReadClock = MockChromeReadClock(),
        configure: @escaping (MockChromeTransport) -> Void = { _ in }
    ) -> (ChromeQuotaReadService.Dependencies, TransportBox) {
        let box = TransportBox()
        var dependencies = ChromeQuotaReadService.Dependencies()
        dependencies.useWatchdogThread = false
        dependencies.clock = clock
        dependencies.now = { now }
        dependencies.discover = { candidates }
        dependencies.makeTransport = { identity, budget in
            let transport = standardMockTransport(pid: identity.pid)
            transport.clock = clock
            transport.budget = budget
            transport.pageText = ["100": mockCodexText, "200": mockClaudeText]
            configure(transport)
            box.transports[identity.pid] = transport
            return transport
        }
        return (dependencies, box)
    }

    final class TransportBox {
        var transports: [pid_t: MockChromeTransport] = [:]
    }

    static func freePID() -> pid_t {
        var candidate: pid_t = 99_000
        while candidate > 1_000 {
            if kill(candidate, 0) != 0, errno == ESRCH { return candidate }
            candidate -= 7
        }
        return 99_000
    }

    // MARK: 实例分类、选择与严格身份

    static func testChromeInstanceSelection(_ reporter: TestReporter) {
        reporter.group("Chrome 实例分类与选择")
        let normalArguments = chromeArguments([])
        let automationArguments = chromeArguments(["--disable-field-trial-config", "--user-data-dir=/tmp/playwright_profile", "--remote-debugging-pipe", "--no-startup-window"])

        let single = ChromeInstanceDiscovery.decide(candidates: [candidate(100, arguments: normalArguments)])
        reporter.equal("单普通实例被选中", single.selectedIdentity?.pid, 100)
        reporter.equal("选中身份带内核启动时间", single.selectedIdentity?.startTime, startTime())
        reporter.check("单普通实例没有失败原因", single.failureLines.isEmpty)

        let mixed = ChromeInstanceDiscovery.decide(candidates: [
            candidate(200, arguments: automationArguments, launch: nil),
            candidate(100, arguments: normalArguments)
        ])
        reporter.equal("普通+自动化只选普通实例", mixed.selectedIdentity?.pid, 100)
        reporter.check("自动化实例被标记且列出参数",
                       mixed.reports.first { $0.pid == 200 }?.classification == .automation(markers: ["--remote-debugging-pipe"]),
                       "\(String(describing: mixed.reports.first { $0.pid == 200 }?.classification))")
        reporter.check("候选摘要不含参数值", !mixed.candidateLines.joined().contains("playwright_profile"))

        let onlyAutomation = ChromeInstanceDiscovery.decide(candidates: [candidate(200, arguments: automationArguments)])
        reporter.equal("仅自动化实例不选择", onlyAutomation.selection, .onlyAutomation([200]))
        reporter.check("仅自动化实例给出可操作原因", onlyAutomation.failureLines.contains { $0.contains("PID 200") && $0.contains("--remote-debugging-pipe") })

        reporter.equal("无实例 = 未运行", ChromeInstanceDiscovery.decide(candidates: []).selection, .notRunning)

        let multiple = ChromeInstanceDiscovery.decide(candidates: [
            candidate(100, arguments: normalArguments),
            candidate(300, arguments: chromeArguments(["--profile-directory=Profile 2"]))
        ])
        reporter.equal("多个普通实例不选择", multiple.selection, .multipleNormal([100, 300]))

        let unreadable = ChromeInstanceDiscovery.decide(candidates: [candidate(400, arguments: nil)])
        reporter.equal("argv 读取失败 = 无法确认", unreadable.selection, .unverifiable([400]))
        reporter.equal("普通+无法确认也不猜（保守）",
                       ChromeInstanceDiscovery.decide(candidates: [candidate(100, arguments: normalArguments), candidate(400, arguments: nil)]).selection,
                       .unverifiable([400]))

        let customProfile = ChromeInstanceDiscovery.decide(candidates: [
            candidate(100, arguments: chromeArguments(["--user-data-dir=/Users/me/Profiles/work", "--no-startup-window"]))
        ])
        reporter.equal("自定义 user-data-dir 不被误排除", customProfile.selectedIdentity?.pid, 100)
        reporter.check("user-data-dir 只作记录", customProfile.reports[0].classification == .normal(notes: ["--user-data-dir", "--no-startup-window"]))

        for flag in ["--headless=new", "--headless", "--remote-debugging-port=9222", "--enable-automation", "--test-type=webdriver", "--remote-allow-origins=*", "--disable-blink-features=AutomationControlled"] {
            let classification = ChromeInstanceClassifier.classify(candidate(1, arguments: chromeArguments([flag])))
            reporter.check("\(flag) 判定为自动化", { if case .automation = classification { return true } else { return false } }(), "\(classification)")
        }
        reporter.equal("--disable-blink-features 其它值不算自动化", ChromeInstanceClassifier.classify(candidate(1, arguments: chromeArguments(["--disable-blink-features=Foo"]))), .normal(notes: []))
        reporter.equal("可执行路径里的字样不算参数", ChromeInstanceClassifier.classify(candidate(1, arguments: ["/tmp/--headless/Google Chrome"])), .normal(notes: []))
        reporter.equal("空参数表 = 无法确认", ChromeInstanceClassifier.classify(candidate(1, arguments: [])), .uncertain(reason: "启动参数为空"))

        reporter.group("Chrome 实例身份完整性（fail-closed）")
        let noStart = ChromeInstanceDiscovery.decide(candidates: [candidate(100, arguments: normalArguments, startTime: nil)])
        reporter.equal("普通候选缺内核启动时间 = 无法确认，不选择", noStart.selection, .unverifiable([100]))
        reporter.check("原因说明启动时间不可读", noStart.failureLines.contains { $0.contains("内核启动时间") })
        let noBundle = ChromeInstanceDiscovery.decide(candidates: [candidate(100, arguments: normalArguments, bundle: nil)])
        reporter.equal("普通候选缺 bundle 路径 = 无法确认，不选择", noBundle.selection, .unverifiable([100]))
        reporter.check("LS 启动时间缺失不影响（只用内核时间）", ChromeInstanceDiscovery.decide(candidates: [candidate(100, arguments: normalArguments, launch: nil)]).selectedIdentity?.pid == 100)
        let automationNoStart = candidate(200, arguments: automationArguments, startTime: nil, launch: nil)
        reporter.check("已明确自动化且启动时间缺失仍是自动化", { if case .automation = ChromeInstanceClassifier.classify(automationNoStart) { return true } else { return false } }())
        reporter.equal("只有该自动化实例 = 仅自动化（不是无法确认）", ChromeInstanceDiscovery.decide(candidates: [automationNoStart]).selection, .onlyAutomation([200]))
        reporter.equal("普通 + 缺启动时间的自动化 → 仍选普通", ChromeInstanceDiscovery.decide(candidates: [candidate(100, arguments: normalArguments), automationNoStart]).selectedIdentity?.pid, 100)
        reporter.check("身份不完整的候选无法构成身份", ChromeInstanceIdentity(candidate: candidate(100, arguments: normalArguments, startTime: nil)) == nil)

        reporter.group("Chrome 实例身份核验（精确、无容差）")
        let identity = ChromeInstanceIdentity(pid: 100, startTime: startTime(), bundleURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"))
        let bundle = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        reporter.check("同进程核验通过", identity.mismatchReason(currentStartTime: startTime(), bundleIdentifier: "com.google.Chrome", bundleURL: bundle) == nil)
        reporter.check("启动时间差 1 微秒也失效（无 0.5 秒容差）",
                       identity.mismatchReason(currentStartTime: startTime(1_800_000_000, 123_457), bundleIdentifier: "com.google.Chrome", bundleURL: bundle)?.contains("复用") == true)
        reporter.check("启动时间差 0.3 秒也失效",
                       identity.mismatchReason(currentStartTime: startTime(1_800_000_000, 423_456), bundleIdentifier: "com.google.Chrome", bundleURL: bundle)?.contains("复用") == true)
        reporter.check("当前身份缺失 = 已退出", identity.mismatchReason(currentStartTime: nil, bundleIdentifier: "com.google.Chrome", bundleURL: bundle)?.contains("已退出") == true)
        reporter.check("bundle id 变化被拒绝", identity.mismatchReason(currentStartTime: startTime(), bundleIdentifier: "com.other.app", bundleURL: bundle) != nil)
        reporter.check("当前 bundle 路径不可读 = 失效（不绕过）", identity.mismatchReason(currentStartTime: startTime(), bundleIdentifier: "com.google.Chrome", bundleURL: nil)?.contains("不可读") == true)
        reporter.check("bundle 路径变化被拒绝", identity.mismatchReason(currentStartTime: startTime(), bundleIdentifier: "com.google.Chrome", bundleURL: URL(fileURLWithPath: "/Volumes/X/Google Chrome.app")) != nil)

        reporter.group("内核启动时间（sysctl KERN_PROC）")
        let selfStart = KernelProcessInfo.startTime(pid: getpid())
        reporter.check("当前进程有内核启动时间", selfStart != nil)
        reporter.equal("两次读取完全相同", KernelProcessInfo.startTime(pid: getpid()), selfStart)
        let free = freePID()
        reporter.equal("不存在的 PID 读不到启动时间", KernelProcessInfo.startTime(pid: free), nil)
        if let selfStart {
            let selfIdentity = ChromeInstanceIdentity(pid: getpid(), startTime: selfStart, bundleURL: bundle)
            reporter.check("内核核验：同进程通过", selfIdentity.verifyKernel() == nil)
            let shifted = ChromeInstanceIdentity(pid: getpid(), startTime: startTime(selfStart.seconds, selfStart.microseconds &+ 1), bundleURL: bundle)
            reporter.check("内核核验：启动时间差 1 微秒失效", shifted.verifyKernel()?.contains("复用") == true)
            reporter.check("完整核验：当前进程不是 Chrome 而失效", selfIdentity.verifyLive() != nil)
            reporter.check("内核核验：进程不存在失效", ChromeInstanceIdentity(pid: free, startTime: selfStart, bundleURL: bundle).verifyKernel()?.contains("已退出") == true)
        }

        reporter.group("进程参数读取（KERN_PROCARGS2）")
        func buffer(argc: Int32, execPath: String, arguments: [String], environment: [String] = ["HOME=/x"]) -> [UInt8] {
            var bytes: [UInt8] = []
            withUnsafeBytes(of: argc) { bytes.append(contentsOf: $0) }
            bytes.append(contentsOf: Array(execPath.utf8) + [0, 0, 0])
            for argument in arguments { bytes.append(contentsOf: Array(argument.utf8) + [0]) }
            for variable in environment { bytes.append(contentsOf: Array(variable.utf8) + [0]) }
            return bytes
        }
        reporter.equal("解析合成参数表", ProcessArguments.parse(buffer: buffer(argc: 3, execPath: "/bin/app", arguments: ["/bin/app", "--b=c", "d"])), ["/bin/app", "--b=c", "d"])
        reporter.equal("参数个数不足返回 nil", ProcessArguments.parse(buffer: buffer(argc: 3, execPath: "/bin/app", arguments: ["/bin/app", "--b"], environment: [])), nil)
        reporter.equal("argc 为 0 返回 nil", ProcessArguments.parse(buffer: buffer(argc: 0, execPath: "/bin/app", arguments: [])), nil)
        reporter.equal("空缓冲返回 nil", ProcessArguments.parse(buffer: []), nil)
        switch ProcessArguments.read(pid: getpid()) {
        case .success(let arguments):
            reporter.check("读取自身 argv 含 --self-test", arguments.contains("--self-test"), "\(arguments)")
        case .failure(let error):
            reporter.check("读取自身 argv", false, "\(error)")
        }
    }

    // MARK: 严格网址契约

    static func testBrowserURLContract(_ reporter: TestReporter) {
        reporter.group("严格网址契约（URLComponents · 表驱动）")
        let claudePositive = [
            "https://claude.ai/new#settings/usage",
            "https://claude.ai/new?redirect=claude.com&via=static_google_success#settings/usage",
            "https://claude.ai/new/#settings/usage",
            "https://claude.ai/settings/usage",
            "https://claude.ai/settings/usage?x=1",
            "https://claude.ai/settings/usage/",
            "https://CLAUDE.AI/new#settings/usage",
            "HTTPS://claude.ai/new#settings/usage"
        ]
        let claudeNegative = [
            "http://claude.ai/new#settings/usage",
            "https://example.test/?next=claude.ai/new#settings/usage",
            "https://claude.ai.evil.com/new#settings/usage",
            "https://evil.com/claude.ai/new#settings/usage",
            "https://claude.ai/new/extra#settings/usage",
            "https://claude.ai/newx#settings/usage",
            "https://claude.ai/new#settings/usage-not",
            "https://claude.ai/new#/settings/usage",
            "https://claude.ai/new?x=%23settings/usage",
            "https://claude.ai/new",
            "https://claude.ai:8443/new#settings/usage",
            "https://user@claude.ai/new#settings/usage",
            "https://claude.ai/settings/usage/../x",
            "https://claude.ai/settings/usagex",
            "https://claude.ai#settings/usage",
            "claude.ai/new#settings/usage",
            "https://chatgpt.com/new#settings/usage",
            "https://chatgpt.com/settings/usage?tab=overview",
            ""
        ]
        for url in claudePositive {
            reporter.check("Claude 接受 \(url)", BrowserUsageTargets.isClaudeUsageURL(url) && ChromeTargetKind.kind(for: url) == .claude)
        }
        for url in claudeNegative {
            reporter.check("Claude 拒绝 \(url.isEmpty ? "(空)" : url)", !BrowserUsageTargets.isClaudeUsageURL(url) && ChromeTargetKind.kind(for: url) != .claude)
        }

        // 0.2.15 新地址 /settings/usage：tab 缺省或唯一 overview 才接受；无关查询参数与 fragment 不参与判定。
        // 旧 analytics 地址作为兼容回归留在同一张表里，它的 query 完全不参与匹配（含自己的 ?tab=weekly）。
        let codexPositive = [
            "https://chatgpt.com/settings/usage?tab=overview",
            "https://chatgpt.com/settings/usage",
            "https://chatgpt.com/settings/usage/",
            "https://chatgpt.com/settings/usage/?tab=overview",
            "https://chatgpt.com/settings/usage?",
            "https://chatgpt.com/settings/usage?tab=overview#top",
            "https://chatgpt.com/settings/usage#top",
            "https://chatgpt.com/settings/usage?utm_source=chatgpt&tab=overview",
            "https://chatgpt.com/settings/usage?tab=overview&utm_source=chatgpt",
            "https://chatgpt.com/settings/usage?ref=codex",
            "https://chatgpt.com/settings/usage?tabs=billing",
            "https://chatgpt.com/settings/usage?tab=over%76iew",
            "https://CHATGPT.COM/settings/usage?tab=overview",
            "HTTPS://chatgpt.com/settings/usage?tab=overview",
            "https://chatgpt.com/codex/cloud/settings/analytics",
            "https://chatgpt.com/codex/cloud/settings/analytics?tab=weekly",
            "https://chatgpt.com/codex/cloud/settings/analytics?tab=weekly&tab=monthly",
            "https://chatgpt.com/codex/cloud/settings/analytics/",
            "https://chatgpt.com/codex/cloud/settings/analytics#top"
        ]
        let codexNegative = [
            // 新地址的 tab 策略：其它 tab 值、空值、无值、重复 tab（即使都是 overview）一律拒绝，不刷新非 overview 页面。
            "https://chatgpt.com/settings/usage?tab=billing",
            "https://chatgpt.com/settings/usage?tab=weekly",
            "https://chatgpt.com/settings/usage?tab=",
            "https://chatgpt.com/settings/usage?tab",
            "https://chatgpt.com/settings/usage?tab=Overview",
            "https://chatgpt.com/settings/usage?tab=overviewx",
            "https://chatgpt.com/settings/usage?tab=overview%20",
            "https://chatgpt.com/settings/usage?tab=overview&tab=overview",
            "https://chatgpt.com/settings/usage?tab=overview&tab=billing",
            "https://chatgpt.com/settings/usage?tab=billing&tab=overview",
            "https://chatgpt.com/settings/usage?%74ab=billing",
            "https://chatgpt.com/settings/usage?TAB=billing",
            // 新地址的 scheme / 主机 / 端口 / 凭据 / 路径 / query 混淆。
            "http://chatgpt.com/settings/usage?tab=overview",
            "https://chatgpt.com:8443/settings/usage?tab=overview",
            "https://a:b@chatgpt.com/settings/usage?tab=overview",
            "https://user@chatgpt.com/settings/usage?tab=overview",
            "https://www.chatgpt.com/settings/usage?tab=overview",
            "https://notchatgpt.com/settings/usage?tab=overview",
            "https://chatgpt.com.evil.com/settings/usage?tab=overview",
            "https://evil.com/chatgpt.com/settings/usage?tab=overview",
            "https://chatgpt.com/?u=/settings/usage&tab=overview",
            "https://chatgpt.com/settings/usage/extra?tab=overview",
            "https://chatgpt.com/settings/usagex?tab=overview",
            "https://chatgpt.com/settings?tab=overview",
            "https://chatgpt.com/settings/usage/../x?tab=overview",
            "https://chatgpt.com//settings/usage?tab=overview",
            "https://chatgpt.com/settings//usage?tab=overview",
            "chatgpt.com/settings/usage?tab=overview",
            "https://claude.ai/settings/usage?tab=overview",
            // 旧地址负例（0.2.14 起沿用，不因新地址放宽）。
            "http://chatgpt.com/codex/cloud/settings/analytics",
            "https://chatgpt.com/codex/cloud/settings/analytics/extra",
            "https://chatgpt.com/codex/cloud/settings",
            "https://chatgpt.com/?u=/codex/cloud/settings/analytics",
            "https://notchatgpt.com/codex/cloud/settings/analytics",
            "https://chatgpt.com.evil.com/codex/cloud/settings/analytics",
            "https://evil.com/chatgpt.com/codex/cloud/settings/analytics",
            "https://chatgpt.com:8443/codex/cloud/settings/analytics",
            "https://a:b@chatgpt.com/codex/cloud/settings/analytics",
            "https://www.chatgpt.com/codex/cloud/settings/analytics",
            "https://claude.ai/codex/cloud/settings/analytics"
        ]
        for url in codexPositive {
            reporter.check("Codex 接受 \(url)", BrowserUsageTargets.isCodexUsageURL(url) && ChromeTargetKind.kind(for: url) == .codex)
        }
        for url in codexNegative {
            reporter.check("Codex 拒绝 \(url)", !BrowserUsageTargets.isCodexUsageURL(url) && ChromeTargetKind.kind(for: url) != .codex)
        }
        reporter.check("nil 不是额度页", !BrowserUsageTargets.isClaudeUsageURL(nil) && !BrowserUsageTargets.isCodexUsageURL(nil) && ChromeTargetKind.kind(for: nil) == nil)
        reporter.check("常量地址本身满足契约", BrowserUsageTargets.isCodexUsageURL(BrowserUsageTargets.codexUsageURL) && BrowserUsageTargets.isClaudeUsageURL(BrowserUsageTargets.claudeUsageURL))

        // 默认链接断言（0.2.15）：常量就是用户给的完整地址，菜单入口 / 目标 usageURL 与它同一个值。
        reporter.equal("Codex 默认地址 = 用户给的完整地址", BrowserUsageTargets.codexUsageURL, "https://chatgpt.com/settings/usage?tab=overview")
        reporter.equal("兼容的旧 Codex 地址常量", BrowserUsageTargets.codexLegacyUsageURL, "https://chatgpt.com/codex/cloud/settings/analytics")
        reporter.equal("Claude 默认地址未改动", BrowserUsageTargets.claudeUsageURL, "https://claude.ai/new#settings/usage")
        reporter.equal("Codex 目标 usageURL = 默认地址", ChromeTargetKind.codex.usageURL, BrowserUsageTargets.codexUsageURL)
        reporter.equal("Claude 目标 usageURL = 默认地址", ChromeTargetKind.claude.usageURL, BrowserUsageTargets.claudeUsageURL)
        reporter.equal("默认地址被识别为 codex", ChromeTargetKind.kind(for: BrowserUsageTargets.codexUsageURL), ChromeTargetKind.codex)
        reporter.equal("旧地址仍被识别为 codex", ChromeTargetKind.kind(for: BrowserUsageTargets.codexLegacyUsageURL), ChromeTargetKind.codex)
    }

    // MARK: 就绪探针（JavaScriptCore 真实执行）

    static func evaluateProbe(_ kind: ChromeTargetKind, readyState: String, text: String?) -> String? {
        guard let context = JSContext() else { return nil }
        var document: [String: Any] = ["readyState": readyState]
        if let text {
            document["body"] = ["innerText": text]
        } else {
            document["body"] = NSNull()
        }
        context.setObject(document, forKeyedSubscript: "document" as NSString)
        return context.evaluateScript(ChromePageScripts.readinessProbe(for: kind))?.toString()
    }

    static func testReadinessProbe(_ reporter: TestReporter) {
        reporter.group("就绪探针 · 与已支持额度字段和加载状态一致")
        let sessionOnly = mockClaudeSessionOnlyText
        reporter.equal("Claude 只有 Current session 也就绪", evaluateProbe(.claude, readyState: "complete", text: sessionOnly), "1")
        reporter.equal("Claude 全栏目页就绪", evaluateProbe(.claude, readyState: "complete", text: mockClaudeText), "1")
        reporter.equal("Claude 只有 All models 也就绪", evaluateProbe(.claude, readyState: "complete", text: "Plan usage limits\nAll models\n41% used"), "1")
        reporter.equal("Claude 只有 Claude Design 也就绪", evaluateProbe(.claude, readyState: "complete", text: "Claude Design\n7% used"), "1")
        reporter.equal("Claude 中文页就绪", evaluateProbe(.claude, readyState: "complete", text: "当前会话\n12% 已使用"), "1")
        reporter.equal("Claude 页面加载中不就绪", evaluateProbe(.claude, readyState: "loading", text: mockClaudeText), "0")
        reporter.equal("Claude interactive 不就绪", evaluateProbe(.claude, readyState: "interactive", text: mockClaudeText), "0")
        reporter.equal("Claude 空白正文不就绪", evaluateProbe(.claude, readyState: "complete", text: ""), "0")
        reporter.equal("Claude 无 body 不就绪", evaluateProbe(.claude, readyState: "complete", text: nil), "0")
        reporter.equal("Claude 错误页不就绪", evaluateProbe(.claude, readyState: "complete", text: "Something went wrong. Please try again."), "0")
        reporter.equal("Claude 只有导航标签没有百分比不就绪（骨架屏）", evaluateProbe(.claude, readyState: "complete", text: "Settings\nUsage\nCurrent session\nAll models\nLoading…"), "0")
        reporter.equal("Claude 登录页不就绪", evaluateProbe(.claude, readyState: "complete", text: "Log in to Claude\nContinue with Google"), "0")
        // 0.2.16：新中文页。旧条件只认后缀式 `12% 已使用`，读不到「已使用 0%」—— 这正是 Claude 页就绪超时的原因。
        reporter.equal("Claude 新中文页就绪（前缀式 已使用 0%）", evaluateProbe(.claude, readyState: "complete", text: mockClaudeScreenshotText), "1")
        reporter.equal("Claude 新中文页只有本周也就绪", evaluateProbe(.claude, readyState: "complete", text: "本周\n星期一05:00 重置\n已使用 68%"), "1")
        reporter.equal("Claude 新中文页只有 Fable 不就绪（Fable 不冒充总周额度）", evaluateProbe(.claude, readyState: "complete", text: "本周 Fable\nFable 的单独每周限额\n已使用 3%"), "0")
        reporter.equal("Claude 新中文页加载中不就绪", evaluateProbe(.claude, readyState: "loading", text: mockClaudeScreenshotText), "0")
        reporter.equal("Claude 仅美元额度不就绪", evaluateProbe(.claude, readyState: "complete", text: "云会话额度\n包含的额度\n剩余 US$250（共 US$250）\n用量额度\nUS$0"), "0")

        reporter.equal("Codex 中文页就绪", evaluateProbe(.codex, readyState: "complete", text: mockCodexText), "1")
        reporter.equal("Codex 英文页就绪", evaluateProbe(.codex, readyState: "complete", text: "Codex analytics\nWeekly limit\n40% remaining\nResets Sep 30"), "1")
        reporter.equal("Codex 只有标签没有百分比不就绪", evaluateProbe(.codex, readyState: "complete", text: "Codex 分析\n每周使用限额\n加载中"), "0")
        reporter.equal("Codex 加载中不就绪", evaluateProbe(.codex, readyState: "loading", text: mockCodexText), "0")
        reporter.equal("Codex 空白不就绪", evaluateProbe(.codex, readyState: "complete", text: ""), "0")
        reporter.equal("Codex 页面文本不会让 Claude 探针就绪", evaluateProbe(.claude, readyState: "complete", text: mockCodexText), "0")
        reporter.equal("Claude 页面文本不会让 Codex 探针就绪", evaluateProbe(.codex, readyState: "complete", text: mockClaudeText), "0")

        reporter.group("就绪探针与解析器口径一致")
        let sessionMetrics = BrowserUsageParser.parseClaude(lines: LineTools.normalize([sessionOnly], deduplicate: false))
        reporter.equal("Current-session-only 页解析出 Current session 7% used", sessionMetrics.first { $0.label == "Current session" }?.usedPercent, 7)
        reporter.check("Current-session-only 页没有 All models（不伪造）", !sessionMetrics.contains { $0.label == "All models" })
        let fullMetrics = BrowserUsageParser.parseClaude(lines: LineTools.normalize([mockClaudeText], deduplicate: false))
        reporter.equal("全栏目页仍解析 3 个百分比指标", fullMetrics.filter { $0.usedPercent != nil }.count, 3)
        reporter.equal("骨架屏解析不出百分比", BrowserUsageParser.parseClaude(lines: ["Settings", "Usage", "Current session", "All models", "Loading…"]).filter { $0.usedPercent != nil }.count, 0)
        reporter.equal("Codex 中文页解析 68%", BrowserUsageParser.parseCodex(lines: LineTools.normalize([mockCodexText], deduplicate: false)).first?.remainingPercent, 68)
        let screenshotClaude = BrowserUsageParser.parseClaude(lines: LineTools.normalize([mockClaudeScreenshotText], deduplicate: false))
        reporter.equal("新中文页解析出 当前会话 0% / 本周 68%",
                       [screenshotClaude.first { $0.label == "Current session" }?.usedPercent, screenshotClaude.first { $0.label == "All models" }?.usedPercent],
                       [0, 68])
        reporter.check("新中文页不产出 Fable 指标", !screenshotClaude.contains { $0.label.contains("Fable") })
        reporter.check("新中文页不产出美元额度指标", !screenshotClaude.contains { ($0.value ?? "").contains("US$") })
    }

    // MARK: Codex 周额度契约（0.2.15 R2：解析器与就绪探针跑同一份用例矩阵）

    /// 一份矩阵同时驱动 Swift 解析器与 JavaScriptCore 上真实执行的就绪探针：
    /// 期望值非 nil ⇔ 必须解析出该百分比且探针就绪；nil ⇔ 必须解析不出任何指标且探针不就绪。
    /// 两者共用 `BrowserUsageParser.codexWeeklyRemainingPattern`，所以这里钉的是同一条契约的两端。
    static func testCodexWeeklyContract(_ reporter: TestReporter) {
        reporter.group("Codex 周额度契约 · 解析器与就绪探针两引擎对照矩阵（整改 1/3）")
        // 每行断言 4 件事：解析出的百分比、指标数、JavaScriptCore 上真实执行的探针就绪位、以及重置信息。
        // 期望百分比非 nil ⇔ 探针必须就绪；重置信息必须来自与百分比同一次匹配，拿不到就是 nil。
        let spaces150 = String(repeating: " ", count: 150)
        let matrix: [(name: String, text: String, percent: Double?, reset: String?)] = [
            // 真实样例与既有正向用例
            ("新页面截图全文", mockCodexScreenshotText, 83, "5 天 17 小时后重置"),
            ("截图字段折叠到同一行", "套餐限额\n每周限额 5 天 17 小时后重置 剩余 83%\n额度", 83, "5 天 17 小时后重置"),
            ("剩余与数值换行拆分", "每周限额\n5 天 17 小时后重置\n剩余\n83%", 83, "5 天 17 小时后重置"),
            ("标题与数值之间有空行", "每周限额\n\n剩余 77%", 77, nil),
            ("只有小时倒计时", "每周限额\n17 小时后重置\n剩余 83%", 83, "17 小时后重置"),
            ("旧中文后缀 68% 剩余", mockCodexText, 68, "重置时间: 2026年9月8日 10:00"),
            ("旧英文后缀 40% remaining", "Codex analytics\nWeekly limit\n40% remaining\nResets Sep 30", 40, nil),
            ("旧英文 Resets in 在数值之前", "Weekly limit\nResets in 3h 12m\n40% remaining", 40, "Resets in 3h 12m"),
            ("旧英文长标签", "Weekly usage limit\n55% remaining", 55, nil),
            ("新标签配英文后缀", "每周限额\n83% remaining", 83, nil),
            ("0%", "每周限额\n剩余 0%", 0, nil),
            ("100%", "每周限额\n剩余 100%", 100, nil),
            ("小数 83.5%", "每周限额\n剩余 83.5%", 83.5, nil),
            ("超过 100 拒绝", "每周限额\n剩余 150%", nil, nil),
            ("数字粘连 183% 拒绝", "每周限额\n183% 剩余", nil, nil),
            ("100.5% 拒绝", "每周限额\n剩余 100.5%", nil, nil),
            ("周额度没有值（加载中）", "每周限额\n加载中", nil, nil),
            ("只有充值与历史记录", "额度\n剩余额度：62,500\n当前余额\n自动充值\n可用 0\n历史记录\n过去 30 天", nil, nil),
            ("used 百分比不当剩余", "每周限额\n已使用 17%", nil, nil),
            ("相邻充值文案不当剩余", "每周限额\n43%\n剩余额度：62,500", nil, nil),
            ("空白页", "", nil, nil),
            ("Claude 页面文本", mockClaudeText, nil, nil),

            // 整改 1/3 · 问题 1：标题必须是完整字段，说明句前缀不算标题
            ("标题是说明句前缀", "每周限额会在用完后暂停服务，示例为剩余 83%", nil, nil),
            ("标题是说明句前缀 · 冒号变体", "每周限额：用完后暂停服务，示例为剩余 83%", nil, nil),
            ("标题是说明句前缀 · 括号变体", "每周限额（说明）剩余 83%", nil, nil),
            ("标题是更长词的前缀", "每周限额说明\n剩余 83%", nil, nil),
            ("说明句提及每周限额，后方有百分比", "使用限额重置\n使用一次重置，即可恢复你的 5 小时限额、每周限额，或同时恢复两者\n剩余 40%", nil, nil),

            // 整改 1/3 · 问题 2：标题与百分比之间只允许已知字段，未知正文一律停止
            ("下一栏目 · 5 小时使用限额", "每周限额\n加载中\n5 小时使用限额\n剩余 99%", nil, nil),
            ("下一栏目 · 代码审查", "每周限额\n加载中\n代码审查\n剩余 99%", nil, nil),
            ("下一栏目 · 不在任何黑名单里的未知栏目", "每周限额\n加载中\n未列入任何停止关键词的栏目\n剩余 42%", nil, nil),
            ("周额度加载中，后方充值区有百分比", "每周限额\n加载中\n额度\n剩余额度：62,500\n剩余 40%", nil, nil),

            // 整改 1/3 · 问题 3：数值必须是完整合法字段，不能跳过非法前缀取尾数
            ("千分位 1,50%", "每周限额\n1,50% 剩余", nil, nil),
            ("千分位 · 前缀式", "每周限额\n剩余 1,50%", nil, nil),
            ("Unicode 负号 −5%", "每周限额\n\u{2212}5% 剩余", nil, nil),
            ("Unicode 负号 · 前缀式", "每周限额\n剩余 \u{2212}5%", nil, nil),
            ("ASCII 负号加空格 - 5%", "每周限额\n- 5% 剩余", nil, nil),
            ("ASCII 负号加空格 · 前缀式", "每周限额\n剩余 - 5%", nil, nil),
            ("紧贴负号 -5%", "每周限额\n剩余 -5%", nil, nil),
            ("加号 +5%", "每周限额\n+5% 剩余", nil, nil),
            ("多小数点 5.5.5%", "每周限额\n5.5.5% 剩余", nil, nil),
            ("数字之间有空格 1 2%", "每周限额\n1 2% 剩余", nil, nil),

            // 整改 1/3 · 问题 4：两引擎的数字语义与归一化必须一致
            ("全角数字 ８3%", "每周限额\n８3% 剩余", nil, nil),
            ("全角数字 · 前缀式", "每周限额\n剩余 ８3%", nil, nil),
            ("全角百分号 83％", "每周限额\n83％ 剩余", nil, nil),
            ("标题与数值之间 150 个空格", "每周限额" + spaces150 + "剩余 83%", 83, nil),
            ("不间断空格与制表符", "每周限额\n\u{00a0}\t剩余 83%", 83, nil),
            ("CRLF 换行", "每周限额\r\n5 天 17 小时后重置\r\n剩余 83%", 83, "5 天 17 小时后重置"),
            ("开尔文符号冒充 Weekly 的 k", "Wee\u{212a}ly limit\n40% remaining", nil, nil),
            ("英文标题全大写", "WEEKLY LIMIT\n40% REMAINING", 40, nil),

            // 整改 2/3 · 字段结束约束：整条匹配之后本行只能剩空白，不能停在非法字段或更长单词中间
            ("剩余后同行还有正文（空格绕过）", "每周限额\n43%\n剩余 额度：62,500", nil, nil),
            ("remaining 只是更长单词的前缀", "Weekly limit\n43% remainingCredits: 62,500", nil, nil),
            ("remaining 后同行还有别的字段", "Weekly limit\n40% remaining Credits: 62,500", nil, nil),
            ("百分号重复 83%%", "每周限额\n剩余 83%%", nil, nil),
            ("百分号重复 100%%", "每周限额\n剩余 100%%", nil, nil),
            ("数值尾部跟字母", "每周限额\n剩余 83%x", nil, nil),
            ("数值尾部跟句号", "每周限额\n剩余 83%。", nil, nil),
            ("后缀式标记尾部跟字母", "每周限额\n83% 剩余x", nil, nil),
            ("非法字段后另起合法行也不跳过去", "每周限额\n剩余 83%%\n剩余 77%", nil, nil),
            ("下一行是充值文案仍取本行", "每周限额\n剩余 83%\n剩余额度：62,500", 83, nil),
            ("同行重置 · 前缀式", "每周限额\n剩余 83% 5 天 17 小时后重置", 83, "5 天 17 小时后重置"),
            ("同行重置 · 后缀式", "每周限额\n68% 剩余 5 天 17 小时后重置", 68, "5 天 17 小时后重置"),
            ("行尾留空格", "每周限额\n剩余 83% ", 83, nil),
            ("正文以换行结尾", "每周限额\n剩余 83%\n", 83, nil),

            // 重置信息必须与百分比同一次匹配，不从别处拼接
            ("重置属于另一个栏目", "每周限额\n剩余 83%\n5 小时限额\n3 天后重置", 83, nil),
            ("重置属于另一个周额度标题", "每周限额\n剩余 83%\n每周使用限额\n3 天后重置", 83, nil),
            ("重置紧跟数值", "每周限额\n剩余 83%\n重置时间: 10:00", 83, "重置时间: 10:00"),

            // 0.2.17 · 2026-10-11 截图：中文倒计时的**单位与「后重置」之间**出现空白（DOM 在这里断行 / 插空格）。
            // 正例：已知词元边界上的任何一种归一化空白都要读出 91；负例：边界上出现正文、或「后重置」本身被拆开，一律拒绝。
            ("截图 · 单位与后重置之间一个空格", "每周限额\n6天15小时 后重置\n剩余 91%", 91, "6天15小时 后重置"),
            ("截图 · 单位与后重置之间 DOM 换行", "每周限额\n6天15小时\n后重置\n剩余 91%", 91, "6天15小时 后重置"),
            ("截图 · 制表符", "每周限额\n6天15小时\t后重置\n剩余 91%", 91, "6天15小时 后重置"),
            ("截图 · 不间断空格", "每周限额\n6天15小时\u{00a0}后重置\n剩余 91%", 91, "6天15小时 后重置"),
            ("截图 · U+FEFF", "每周限额\n6天15小时\u{feff}后重置\n剩余 91%", 91, "6天15小时 后重置"),
            ("截图 · 图标占位符 U+FFFC", "每周限额\n6天15小时\u{fffc}后重置\n剩余 91%", 91, "6天15小时 后重置"),
            ("截图 · 每个词元边界都断行", "每周限额\n6\n天\n15\n小时\n后重置\n剩余 91%", 91, "6 天 15 小时 后重置"),
            ("截图 · 只有小时", "每周限额\n15小时 后重置\n剩余 91%", 91, "15小时 后重置"),
            ("截图 · 只有分钟", "每周限额\n30分钟 后重置\n剩余 91%", 91, "30分钟 后重置"),
            ("截图 · 重置在数值之后", "每周限额\n剩余 91%\n6天15小时 后重置", 91, "6天15小时 后重置"),
            ("截图全文", mockCodexSpacingScreenshotText, 91, "6天15小时 后重置"),
            ("截图 · 单位与后重置之间夹正文", "每周限额\n6天15小时 其他说明 后重置\n剩余 91%", nil, nil),
            ("截图 · 单位与后重置之间夹未知栏目", "每周限额\n6天15小时\n未列入白名单的栏目\n后重置\n剩余 91%", nil, nil),
            ("截图 · 后重置被拆开", "每周限额\n6天15小时 后 重置\n剩余 91%", nil, nil),
            ("截图 · 拆行负号", "每周限额\n6天15小时 后重置\n-\n91% 剩余", nil, nil),
            ("截图 · 错误百分比 191", "每周限额\n6天15小时 后重置\n剩余 191%", nil, nil),
            ("截图 · 充值数字冒充百分比", "每周限额\n6天15小时 后重置\n剩余额度：58,612", nil, nil),
            ("截图 · 倒计时数字超位数", "每周限额\n1234天 后重置\n剩余 91%", nil, nil)
        ]
        for entry in matrix {
            let metrics = BrowserUsageParser.parseCodex(lines: LineTools.normalize([entry.text], deduplicate: false))
            reporter.equal("解析 · \(entry.name)", metrics.first?.remainingPercent, entry.percent)
            reporter.equal("指标数 · \(entry.name)", metrics.count, entry.percent == nil ? 0 : 1)
            reporter.equal("探针 · \(entry.name)", evaluateProbe(.codex, readyState: "complete", text: entry.text), entry.percent == nil ? "0" : "1")
            reporter.equal("重置 · \(entry.name)", metrics.first?.reset, entry.reset)
        }

        reporter.group("Codex 周额度契约 · 两端共用同一条正则与同一套归一化")
        let condition = ChromePageScripts.readinessCondition(for: .codex)
        reporter.check("探针用的就是解析器那条正则", condition.contains(BrowserUsageParser.codexWeeklyRemainingPattern))
        reporter.check("探针里带上了解析器那套归一化", condition.contains(BrowserUsageParser.codexHorizontalSpace) && condition.contains(BrowserUsageParser.codexObjectReplacement))
        // 整改 3/3：两张码位表必须与 Foundation 的集合严格相等 —— `LineTools.normalize` 就是按它们分行与 trim。
        // 两个集合都只落在 BMP（Zs 与换行类没有非 BMP 成员），扫 0…U+FFFF 足够。
        var foundationNewlines: [UInt32] = [], foundationWhitespace: [UInt32] = []
        for value in UInt32(0)...UInt32(0xFFFF) {
            guard let scalar = UnicodeScalar(value) else { continue }
            if CharacterSet.newlines.contains(scalar) { foundationNewlines.append(value) }
            if CharacterSet.whitespaces.contains(scalar) { foundationWhitespace.append(value) }
        }
        reporter.equal("换行码位表 == CharacterSet.newlines", BrowserUsageParser.codexLineBreakScalars, foundationNewlines)
        reporter.equal("横向空白码位表 == CharacterSet.whitespaces + U+FEFF", BrowserUsageParser.codexHorizontalSpaceScalars, foundationWhitespace + [0xFEFF])
        reporter.check("两张表不相交（VT/FF 只能算换行）", Set(BrowserUsageParser.codexLineBreakScalars).isDisjoint(with: Set(BrowserUsageParser.codexHorizontalSpaceScalars)))
        // 字符类必须全是 ASCII 可打印字符：一旦混进字面换行（含 U+2028/U+2029），JS 的正则字面量就是语法错误。
        reporter.check("字符类只含 ASCII 可打印字符", (BrowserUsageParser.codexLineBreak + BrowserUsageParser.codexHorizontalSpace).allSatisfy { $0.isASCII && !$0.isWhitespace })
        reporter.equal("换行字符类的转义条数 == 码位表长度", BrowserUsageParser.codexLineBreak.filter { $0 == "u" }.count, BrowserUsageParser.codexLineBreakScalars.count)
        reporter.equal("横向空白字符类的转义条数 == 码位表长度", BrowserUsageParser.codexHorizontalSpace.filter { $0 == "u" }.count, BrowserUsageParser.codexHorizontalSpaceScalars.count)
        reporter.equal("图标占位符归一化成空格", BrowserUsageParser.codexNormalized("a" + BrowserUsageParser.codexObjectReplacement + "b"), "a b")
        reporter.check("正则只用 ASCII 数字类，不用 \\d", !BrowserUsageParser.codexWeeklyRemainingPattern.contains(#"\d"#) && BrowserUsageParser.codexWeeklyRemainingPattern.contains("[0-9]"))
        reporter.check("正则只用显式空白类，不用 \\s", !BrowserUsageParser.codexWeeklyRemainingPattern.contains(#"\s"#))
        reporter.check("两端都不靠 i 标志，大小写已展开进正则", !condition.contains("/i.test(") && BrowserUsageParser.codexWeeklyRemainingPattern.contains("[wW]"))
        reporter.check("字段结束约束在位，且不用两端语义不同的 $", BrowserUsageParser.codexWeeklyRemainingPattern.hasSuffix(#"(?![ ]*[^ \n])"#) && !BrowserUsageParser.codexWeeklyRemainingPattern.contains("$"))
        reporter.check("后缀式不再留 (?!额度) 特判，由字段结束约束统一承担", !BrowserUsageParser.codexWeeklyRemainingPattern.contains("(?!额度)"))
        // 标签不再以字面量出现在正则里（英文已逐字符展开），改为按行为断言：每个标签都能读出数值。
        for label in BrowserUsageParser.codexWeeklyLabels {
            let page = "\(label)\n剩余 83%"
            reporter.equal("标签可用 · \(label)", BrowserUsageParser.parseCodex(lines: LineTools.normalize([page], deduplicate: false)).first?.remainingPercent, 83)
            reporter.equal("标签可用 · \(label) · 探针", evaluateProbe(.codex, readyState: "complete", text: page), "1")
            reporter.equal("标签大小写变体 · \(label)", BrowserUsageParser.parseCodex(lines: LineTools.normalize(["\(label.uppercased())\n剩余 83%"], deduplicate: false)).first?.remainingPercent, 83)
        }
        reporter.equal("归一化把全角空格与制表符压成一个空格", BrowserUsageParser.codexNormalized("a\u{3000}\t b\r\nc"), "a b\nc")
        reporter.equal("截图页展示名称仍是每周使用限额", BrowserUsageParser.parseCodex(lines: LineTools.normalize([mockCodexScreenshotText], deduplicate: false)).first?.label, "每周使用限额")
        reporter.check("截图页不把充值余额 62,500 当额度", !(BrowserUsageParser.parseCodex(lines: LineTools.normalize([mockCodexScreenshotText], deduplicate: false)).first?.description.contains("62,500") ?? true))
        reporter.check("Claude 解析未受影响", BrowserUsageParser.parseClaude(lines: LineTools.normalize([mockClaudeText], deduplicate: false)).filter { $0.usedPercent != nil }.count == 3)

        // 整改 3/3：逐个换行字符对照两端。原文一律先过生产链路 `LineTools.normalize(_:deduplicate:false)`
        // 再交给 parseCodex（与 ChromeQuotaReader 构造 BrowserTextPage 的调用完全一致），探针则直接吃原文，
        // 所以这里比的是「真实分行之后的解析」对「真实探针」，不是对着原文自说自话。
        reporter.group("Codex 周额度契约 · 换行字符两端对齐（整改 3/3 · 经过生产 LineTools 链路）")
        func throughProduction(_ raw: String) -> [BrowserUsageParser.CodexMetric] {
            BrowserUsageParser.parseCodex(lines: LineTools.normalize([raw], deduplicate: false))
        }
        func compareEnds(_ name: String, _ raw: String, _ expected: Double?) {
            reporter.equal("解析(生产链路) · \(name)", throughProduction(raw).first?.remainingPercent, expected)
            reporter.equal("指标数 · \(name)", throughProduction(raw).count, expected == nil ? 0 : 1)
            reporter.equal("探针 · \(name)", evaluateProbe(.codex, readyState: "complete", text: raw), expected == nil ? "0" : "1")
        }
        // 审查给出的两条原文，一字不改。
        compareEnds("审查原文 VT", "Weekly\u{000b}limit\n83%\u{000b}remaining", nil)
        compareEnds("审查原文 FF", "Weekly\u{000c}limit\n83%\u{000c}remaining", nil)
        for (name, breaker) in [("LF", "\n"), ("VT U+000B", "\u{000b}"), ("FF U+000C", "\u{000c}"), ("CR", "\r"),
                                ("CRLF", "\r\n"), ("NEL U+0085", "\u{0085}"), ("LS U+2028", "\u{2028}"), ("PS U+2029", "\u{2029}")] {
            // 标题与百分比之间：就是一次正常换行，两端都应读出 83。
            compareEnds("标题与百分比之间 · \(name)", "每周限额\(breaker)剩余 83%", 83)
            // 标题单词内部：Foundation 在这里分行，标题不再是完整字段 —— 两端一致拒绝。
            compareEnds("标题单词内部 · \(name)", "Weekly\(breaker)limit\n83% remaining", nil)
            // 数值字段内部：数值被拆开，不是完整字段 —— 两端一致拒绝。
            compareEnds("数值字段内部 · \(name)", "每周限额\n8\(breaker)3% 剩余", nil)
            // 百分号与标记之间：仍是一次换行，两端都应读出 83。
            compareEnds("百分号与剩余标记之间 · \(name)", "每周限额\n83%\(breaker)剩余", 83)
        }
        // U+200B 在 CharacterSet.whitespaces 里，LineTools 会在行首行尾 trim 掉；两端按横向空白处理才一致。
        compareEnds("标题行尾零宽空格", "每周限额\u{200b}\n剩余 83%", 83)
        compareEnds("数值行首零宽空格", "每周限额\n\u{200b}剩余 83%", 83)
        compareEnds("行内零宽空格", "每周限额\n剩余\u{200b}83%", 83)
        let screenshotMetric = throughProduction(mockCodexScreenshotText).first
        reporter.equal("截图全文经生产链路仍是 83", screenshotMetric?.remainingPercent, 83)
        reporter.equal("截图全文经生产链路仍带倒计时", screenshotMetric?.reset, "5 天 17 小时后重置")

        // 0.2.17 · 「单位与后重置之间有空白」的截图：经生产链路仍要读出 91，且展示用重置必须是单行
        // （卡片详情与进度条副标题都是单行控件，字段内部那次 DOM 换行要压回一个空格）。
        let spacingMetric = throughProduction(mockCodexSpacingScreenshotText).first
        reporter.equal("空白截图全文经生产链路是 91", spacingMetric?.remainingPercent, 91)
        reporter.equal("空白截图全文的倒计时", spacingMetric?.reset, "6天15小时 后重置")
        reporter.check("空白截图全文不把充值余额 58,612 当额度", !(spacingMetric?.description.contains("58,612") ?? true))
        reporter.check("Codex 重置文本永远不含换行",
                       [mockCodexSpacingScreenshotText, "每周限额\n6天15小时\n后重置\n剩余 91%", "每周限额\n6\n天\n15\n小时\n后重置\n剩余 91%", mockCodexScreenshotText]
                        .allSatisfy { raw in throughProduction(raw).allSatisfy { !($0.reset ?? "").contains("\n") } })
    }

    // MARK: Claude 用量契约（0.2.16：解析器与就绪探针跑同一份用例矩阵）

    /// 一份矩阵同时驱动 Swift 解析器与 JavaScriptCore 上真实执行的就绪探针。
    /// 每行给出三个栏目各自的期望值（nil = 这一栏必须没有数值，包括「标题在但缺值」与「整栏不存在」）；
    /// 探针就绪位 = 「是否至少有一栏读出数值」—— 两端共用 `BrowserUsageParser.claudeUsedPattern`，
    /// 所以这里钉的是同一条契约的两端。
    /// 原文一律先过生产链路 `LineTools.normalize(_:deduplicate:false)` 再交给 parseClaude
    /// （与 ChromeQuotaReader 构造 BrowserTextPage 的调用完全一致），探针则直接吃原文，
    /// 比的是「真实分行之后的解析」对「真实探针」，不是对着原文自说自话。
    static func testClaudeUsageContract(_ reporter: TestReporter) {
        func throughProduction(_ raw: String) -> [BrowserUsageParser.ClaudeMetric] {
            BrowserUsageParser.parseClaude(lines: LineTools.normalize([raw], deduplicate: false))
        }
        func used(_ metrics: [BrowserUsageParser.ClaudeMetric], _ label: String) -> Double? {
            metrics.first { $0.label == label }?.usedPercent
        }
        /// 一行用例的四条断言：三个栏目的数值 + 真实探针的就绪位。
        func compareEnds(_ name: String, _ raw: String, session: Double? = nil, week: Double? = nil, design: Double? = nil) {
            let metrics = throughProduction(raw)
            reporter.equal("当前会话 · \(name)", used(metrics, "Current session"), session)
            reporter.equal("本周(All models) · \(name)", used(metrics, "All models"), week)
            reporter.equal("Claude Design · \(name)", used(metrics, "Claude Design"), design)
            let ready = [session, week, design].contains { $0 != nil } ? "1" : "0"
            reporter.equal("探针 · \(name)", evaluateProbe(.claude, readyState: "complete", text: raw), ready)
        }

        reporter.group("Claude 用量契约 · 新中文页（截图逐字）")
        compareEnds("新中文页截图全文", mockClaudeScreenshotText, session: 0, week: 68)
        compareEnds("只保留三个栏目",
                    "当前会话\n从您的第一条消息开始\n已使用 0%\n本周\n星期一05:00 重置\n已使用 68%\n本周 Fable\nFable 的单独每周限额 · 星期一\n05:00 重置\n已使用 3%",
                    session: 0, week: 68)
        compareEnds("顺序变化 · 本周在当前会话之前",
                    "本周\n星期一05:00 重置\n已使用 68%\n当前会话\n从您的第一条消息开始\n已使用 0%",
                    session: 0, week: 68)
        compareEnds("Fable 在前", "本周 Fable\nFable 的单独每周限额\n已使用 3%\n本周\n星期一05:00 重置\n已使用 68%", week: 68)
        compareEnds("Fable 在后", "本周\n星期一05:00 重置\n已使用 68%\n本周 Fable\nFable 的单独每周限额\n已使用 3%", week: 68)
        compareEnds("只有 Fable", "本周 Fable\nFable 的单独每周限额 · 星期一\n05:00 重置\n已使用 3%")
        compareEnds("Fable 折叠到同一行", "本周 Fable 已使用 3%")
        compareEnds("本周缺值 + 下方 Fable 有值 → 总周额度必须缺失",
                    "当前会话\n从您的第一条消息开始\n已使用 0%\n本周\n星期一05:00 重置\n本周 Fable\nFable 的单独每周限额\n已使用 3%",
                    session: 0)
        compareEnds("当前会话缺值不借本周数值",
                    "当前会话\n从您的第一条消息开始\n本周\n星期一05:00 重置\n已使用 68%",
                    week: 68)
        compareEnds("没有说明行", "当前会话\n已使用 0%\n本周\n已使用 68%", session: 0, week: 68)
        compareEnds("整栏折叠到同一行", "当前会话 已使用 0%\n本周 星期一05:00 重置 已使用 68%", session: 0, week: 68)
        compareEnds("标题带半角冒号", "本周: 已使用 68%", week: 68)
        compareEnds("标题带全角冒号", "本周：已使用 68%", week: 68)
        compareEnds("新中文页后缀式百分比", "本周\n星期一05:00 重置\n68% 已使用", week: 68)
        // 重置字段内部允许跨一次换行（星期 ↔ 时刻），这是截图里 Fable 那栏真实的 DOM 断行位置。
        compareEnds("重置被 DOM 拆成两行", "本周\n星期一\n05:00 重置\n已使用 68%", week: 68)
        // 整改 1/3：说明位置只接受已登记的字面量，未登记文案一律 fail closed（宁缺勿错）。
        // 下面三条在 0.2.16 初稿里分别读出 68 / 68 / 缺值，现在统一是缺值。
        compareEnds("未登记说明 1 行 → 缺值", "本周\n说明一\n已使用 68%")
        compareEnds("未登记说明 2 行 + 重置行 → 缺值", "本周\n说明一\n说明二\n05:00 重置\n已使用 68%")
        compareEnds("未登记说明 3 行 → 缺值", "本周\n说明一\n说明二\n说明三\n已使用 68%")
        compareEnds("已登记说明字段照常跨过去", "当前会话\n从您的第一条消息开始\n已使用 0%", session: 0)
        compareEnds("已登记说明 + 重置 + 数值", "当前会话\n从您的第一条消息开始\n05:00 重置\n已使用 0%", session: 0)
        compareEnds("已登记说明字段只认完整字面量 · 多字", "当前会话\n从您的第一条消息开始吧\n已使用 0%")
        compareEnds("已登记说明字段只认完整字面量 · 缺字", "当前会话\n从您的第一条消息\n已使用 0%")
        compareEnds("已登记说明字段前后不许夹正文", "当前会话\n说明：从您的第一条消息开始\n已使用 0%")
        compareEnds("旧英文说明文案", "Current session\nSince your first message\n23% used", session: 23)

        // 0.2.18：2026-10-26 新布局。下面四组只钉本轮三处新字段（全称标题 / 周一简称 / 复合倒计时）
        // 与一处新误取来源（按产品占比的 Claude Code 100%），其余边界沿用上一轮的口径不再重复。
        func resetText(_ raw: String, _ label: String) -> String? {
            throughProduction(raw).first { $0.label == label }?.reset
        }

        reporter.group("Claude 用量契约 · 新布局（2026-10-26 折叠 / 展开截图逐字）")
        reporter.check("展开截图就是折叠截图后面紧跟更多栏目", mockClaudeExpandedScreenshotText.hasPrefix(mockClaudeCollapsedScreenshotText))
        compareEnds("折叠截图全文", mockClaudeCollapsedScreenshotText, session: 8, week: 2)
        compareEnds("展开截图全文", mockClaudeExpandedScreenshotText, session: 8, week: 2)
        compareEnds("只有新布局总周额度（可单独就绪）", "每周限额 · 所有模型\n周一05:00 重置\n已使用 2%", week: 2)
        compareEnds("只有新布局当前会话", "当前会话\n1小时 37 分钟后重置\n已使用 8%", session: 8)
        compareEnds("两栏顺序颠倒", "每周限额 · 所有模型\n周一05:00 重置\n已使用 2%\n当前会话\n1小时 37 分钟后重置\n已使用 8%", session: 8, week: 2)
        reporter.equal("展开截图只产出两个栏目", throughProduction(mockClaudeExpandedScreenshotText).map { $0.label }, ["Current session", "All models"])
        reporter.check("展开截图不产出 Fable 指标", !throughProduction(mockClaudeExpandedScreenshotText).contains { $0.label.contains("Fable") })
        reporter.check("展开截图里没有任何指标等于 0（Fable 的 0% 不冒充任何栏目）",
                       !throughProduction(mockClaudeExpandedScreenshotText).contains { $0.usedPercent == 0 })
        reporter.check("展开截图里没有任何指标等于 100（按产品占比的 100% 不冒充任何栏目）",
                       !throughProduction(mockClaudeExpandedScreenshotText).contains { $0.usedPercent == 100 })
        compareEnds("总周额度缺值 + Fable 有值 → 总周额度必须缺失", mockClaudeWeekMissingText, session: 8)
        let newWeekMissing = throughProduction(mockClaudeWeekMissingText)
        reporter.check("总周额度缺值时仍产出缺值的 All models", newWeekMissing.contains { $0.label == "All models" && $0.usedPercent == nil })
        reporter.check("总周额度缺值时没有任何指标等于 0（Fable 不冒充总周额度）", !newWeekMissing.contains { $0.usedPercent == 0 })

        reporter.group("Claude 用量契约 · 新全称标题「每周限额 · 所有模型」仍是完整字段")
        compareEnds("全称标题 + 数值", "每周限额 · 所有模型\n已使用 2%", week: 2)
        compareEnds("全称标题 · 分隔符两侧无空白", "每周限额·所有模型\n已使用 2%", week: 2)
        compareEnds("全称标题 · 分隔符处被 DOM 拆行", "每周限额 ·\n所有模型\n已使用 2%", week: 2)
        compareEnds("全称标题 · 分隔符两侧都拆行", "每周限额\n·\n所有模型\n已使用 2%", week: 2)
        compareEnds("全称标题带半角冒号", "每周限额 · 所有模型: 已使用 2%", week: 2)
        compareEnds("全称标题带全角冒号", "每周限额 · 所有模型：已使用 2%", week: 2)
        // 「每周限额」单独成行是 Codex 的栏目标题，它不是 Claude 的总周额度标题 —— 不借它取值。
        compareEnds("只有「每周限额」不是 Claude 标题", "每周限额\n已使用 2%")
        compareEnds("只有「所有模型」不是 Claude 标题", "所有模型\n已使用 2%")
        compareEnds("全称标题中间夹正文 → 缺值", "每周限额 说明 所有模型\n已使用 2%")
        compareEnds("分隔符换成顿号 → 缺值", "每周限额、所有模型\n已使用 2%")
        compareEnds("分隔符换成实心点 → 缺值", "每周限额 • 所有模型\n已使用 2%")
        compareEnds("全称标题是更长词的前缀 → 缺值", "每周限额 · 所有模型说明\n已使用 2%")
        compareEnds("全称标题是说明句前缀 → 缺值", "每周限额 · 所有模型的用量会在周一重置，已使用 2%")
        compareEnds("Fable 说明句里的「每周限额」不是标题", "Fable\n最多为您每周限额的 50%\n周一05:00 重置\n已使用 0%")
        compareEnds("Fable 整栏在前不冒充总周额度",
                    "Fable\n最多为您每周限额的 50%\n周一05:00 重置\n已使用 0%\n每周限额 · 所有模型\n周一05:00 重置\n已使用 2%",
                    week: 2)
        compareEnds("全称标题 0%", "每周限额 · 所有模型\n已使用 0%", week: 0)
        compareEnds("全称标题 100%", "每周限额 · 所有模型\n已使用 100%", week: 100)
        compareEnds("全称标题 101% 拒绝", "每周限额 · 所有模型\n已使用 101%")
        compareEnds("全称标题负值拒绝", "每周限额 · 所有模型\n已使用 -2%")
        compareEnds("全称标题后缀式百分比", "每周限额 · 所有模型\n2% 已使用", week: 2)
        reporter.equal("全称标题精确映射到既有 All models",
                       BrowserUsageParser.claudeSections.first { $0.titles.contains("每周限额 · 所有模型") }?.label, "All models")

        reporter.group("Claude 用量契约 · 新布局重置字段（周一简称 + 中文小时分钟复合倒计时）")
        reporter.equal("周一05:00 重置", resetText("每周限额 · 所有模型\n周一05:00 重置\n已使用 2%", "All models"), "周一05:00 重置")
        reporter.equal("星期一05:00 重置仍兼容", resetText("本周\n星期一05:00 重置\n已使用 68%", "All models"), "星期一05:00 重置")
        compareEnds("周日简称", "本周\n周日05:00 重置\n已使用 68%", week: 68)
        compareEnds("周天简称", "本周\n周天05:00 重置\n已使用 68%", week: 68)
        compareEnds("周一与时刻被 DOM 拆行", "本周\n周一\n05:00 重置\n已使用 68%", week: 68)
        reporter.equal("周一与时刻拆行后压回一行", resetText("本周\n周一\n05:00 重置\n已使用 68%", "All models"), "周一 05:00 重置")
        compareEnds("不是星期的「周X」→ 缺值", "本周\n周末05:00 重置\n已使用 68%")
        reporter.equal("小时+分钟复合倒计时", resetText("当前会话\n1小时 37 分钟后重置\n已使用 8%", "Current session"), "1小时 37 分钟后重置")
        compareEnds("小时+分钟 · 完全不留空白", "当前会话\n1小时37分钟后重置\n已使用 8%", session: 8)
        compareEnds("小时+分钟 · 词元边界被 DOM 拆行", "当前会话\n1小时\n37 分钟后重置\n已使用 8%", session: 8)
        reporter.equal("复合倒计时拆行后压回一行", resetText("当前会话\n1小时\n37 分钟后重置\n已使用 8%", "Current session"), "1小时 37 分钟后重置")
        compareEnds("天+小时+分钟合法顺序", "本周\n2天 3小时 4分钟后重置\n已使用 68%", week: 68)
        compareEnds("天+分钟（跳过小时）", "本周\n2天 4分钟后重置\n已使用 68%", week: 68)
        compareEnds("单位顺序颠倒 → 新规则不接受（缺值）", "当前会话\n37分钟 1小时后重置\n已使用 8%")
        compareEnds("小时重复 → 新规则不接受（缺值）", "当前会话\n1小时 2小时后重置\n已使用 8%")
        // 新规则只约束它自己那条降序序列，**不是**「禁绝所有重复单位」：
        // 「可选 N天 + 一个单位」是 0.2.17 起 codexResetField 里就有的写法，本轮没有收紧它，
        // 所以天重复照旧被接受（两端一致）。文档不得宣称所有旧重复单位都已被禁绝。
        compareEnds("天重复仍由 codexResetField 兼容继承（照旧读出）", "当前会话\n2天 3天后重置\n已使用 8%", session: 8)
        reporter.equal("天重复时取到的重置文本来自继承的那条",
                       resetText("当前会话\n2天 3天后重置\n已使用 8%", "Current session"), "2天 3天后重置")
        reporter.equal("英文 Resets in 3h 12m 仍由继承的那条兼容",
                       resetText("当前会话\n23% used\nResets in 3h 12m", "Current session"), "Resets in 3h 12m")
        compareEnds("倒计时字段内部夹正文 → 缺值", "当前会话\n1小时 说明 37 分钟后重置\n已使用 8%")
        compareEnds("倒计时缺「后重置」→ 缺值", "当前会话\n1小时 37 分钟\n已使用 8%")
        compareEnds("倒计时数字处有负号 → 缺值", "当前会话\n-1小时 37 分钟后重置\n已使用 8%")
        compareEnds("只有小时倒计时仍兼容", "本周\n17 小时后重置\n已使用 68%", week: 68)
        compareEnds("只有分钟倒计时仍兼容", "本周\n37 分钟后重置\n已使用 68%", week: 68)
        compareEnds("0.2.17 的天+小时写法仍兼容", "本周\n6天15小时 后重置\n已使用 68%", week: 68)

        reporter.group("Claude 用量契约 · 标题后的图标槽位（有限白名单，未知插入行一律缺值）")
        // 白名单 = Root 实测的 U+E02A（见下一组）+ 四个明确的展示箭头（有限兼容，未实测）。
        reporter.equal("白名单 = 实测的 U+E02A 加四个明确的展示箭头",
                       BrowserUsageParser.claudeDisclosureMarkers, ["\u{e02a}", ">", "›", "⌄", "▾"])
        // 私用区字符在日志里不可读，所以用例名统一按码位显示（ASCII 字符原样显示）。
        func markerName(_ marker: String) -> String {
            marker.unicodeScalars.map { scalar in
                scalar.isASCII ? String(Character(scalar)) : "U+" + String(scalar.value, radix: 16, uppercase: true)
            }.joined()
        }
        for marker in BrowserUsageParser.claudeDisclosureMarkers {
            compareEnds("标题后的图标独占一行 · \(markerName(marker))", "每周限额 · 所有模型\n\(marker)\n周一05:00 重置\n已使用 2%", week: 2)
            compareEnds("标题后的图标在同一行 · \(markerName(marker))", "每周限额 · 所有模型 \(marker)\n已使用 2%", week: 2)
            compareEnds("当前会话标题后的图标 · \(markerName(marker))", "当前会话\n\(marker)\n1小时 37 分钟后重置\n已使用 8%", session: 8)
        }
        for unknown in ["»", "→", "-", "\u{2212}", "*", "。", "·", "v", "^", "说明", "⌄⌄"] {
            compareEnds("标题后的未登记插入行 → 缺值 · \(unknown)", "每周限额 · 所有模型\n\(unknown)\n周一05:00 重置\n已使用 2%")
        }
        // 箭头只登记在「标题之后」这一处（旧诊断里那行单字符就在周标题后面）：别的槽位上出现箭头
        // 不是已知结构，缺值而不是猜。新文案 / 新位置要支持就再登记一处，不放宽结构。
        compareEnds("箭头出现在重置之后 → 缺值", "每周限额 · 所有模型\n周一05:00 重置\n⌄\n已使用 2%")
        // 标题**之前**另起一行的东西从来不在匹配里（锚点是标题自己的行首，页面前面的正文一向如此），
        // 所以这一条读出 2 不是新口子：箭头槽位管的是标题之后那一行。
        compareEnds("标题之前另起一行的字符不影响本栏", "⌄\n每周限额 · 所有模型\n已使用 2%", week: 2)
        compareEnds("标题之前另起一行的未知正文同样不影响本栏", "说明\n每周限额 · 所有模型\n已使用 2%", week: 2)

        // 正式整改 1/3 的回归锚点：Root 真实页面实测的那个结构。初稿在这一份上总周额度只有标题、
        // 没有数值（状态栏选 allModels 显示 --），所以首版没有安装。
        reporter.group("Claude 用量契约 · 真实页面实测图标 U+E02A（正式整改 1/3）")
        compareEnds("实测结构全文", mockClaudeIconMarkerText, session: 8, week: 2)
        compareEnds("只保留总周额度那一栏的实测结构", "每周限额 · 所有模型\n\u{e02a}\n周一05:00 重置\n已使用 2%", week: 2)
        compareEnds("实测图标 + 没有重置行", "每周限额 · 所有模型\n\u{e02a}\n已使用 2%", week: 2)
        compareEnds("实测图标与标题在同一行", "每周限额 · 所有模型 \u{e02a}\n周一05:00 重置\n已使用 2%", week: 2)
        compareEnds("实测图标 + 后缀式百分比", "每周限额 · 所有模型\n\u{e02a}\n周一05:00 重置\n2% 已使用", week: 2)
        reporter.equal("实测结构里重置与数值仍来自同一次匹配", resetText(mockClaudeIconMarkerText, "All models"), "周一05:00 重置")
        reporter.equal("实测结构里当前会话不借总周额度的重置", resetText(mockClaudeIconMarkerText, "Current session"), "1小时 37 分钟后重置")
        // Root 的元数据只给出码位数与单码位行的码点，这里把合成文本同三行的码位数钉成实测的 1 / 10 / 6，
        // 保证这份回归钉的就是真实页面那个结构，而不是一个「看起来像」的近似。
        let iconLines = LineTools.normalize([mockClaudeIconMarkerText], deduplicate: false)
        if let titleIndex = iconLines.firstIndex(of: "每周限额 · 所有模型") {
            let after = iconLines.dropFirst(titleIndex + 1)
            reporter.equal("合成文本标题后三行的码位数 = 实测的 1 / 10 / 6",
                           after.prefix(3).map { $0.unicodeScalars.count }, [1, 10, 6])
            reporter.equal("标题后第一行就是实测的那个码点",
                           after.first?.unicodeScalars.first.map { String($0.value, radix: 16) }, "e02a")
        } else {
            reporter.check("合成文本里能定位到完整精确标题", false)
        }
        // 图标槽位只打开「标题之后一个已登记字面量」这一处：后面没有数值时仍然缺值，
        // Fable 的 0% 与按产品占比的 100% 都借不过来。
        compareEnds("实测图标 + 总周额度无数值 → 仍缺值", mockClaudeIconMarkerWeekMissingText, session: 8)
        let iconWeekMissing = throughProduction(mockClaudeIconMarkerWeekMissingText)
        reporter.check("实测图标 + 无数值时仍产出缺值的 All models",
                       iconWeekMissing.contains { $0.label == "All models" && $0.usedPercent == nil })
        reporter.check("实测图标 + 无数值时没有任何指标等于 0 或 100",
                       !iconWeekMissing.contains { $0.usedPercent == 0 || $0.usedPercent == 100 })
        reporter.check("实测图标 + 无数值时不产出 Fable 指标", !iconWeekMissing.contains { $0.label.contains("Fable") })
        // 「禁止略过任意私用区字符」：只登记实测的 U+E02A，相邻 / 边界码位一律不成立。
        for pua in ["\u{e029}", "\u{e02b}", "\u{e000}", "\u{e0ff}", "\u{f8ff}"] {
            let name = "U+" + String(pua.unicodeScalars.first!.value, radix: 16, uppercase: true)
            compareEnds("未登记的私用区字符 → 缺值 · \(name)", "每周限额 · 所有模型\n\(pua)\n周一05:00 重置\n已使用 2%")
            compareEnds("未登记的私用区字符在当前会话也缺值 · \(name)", "当前会话\n\(pua)\n1小时 37 分钟后重置\n已使用 8%")
        }
        compareEnds("两个实测图标连写 → 缺值", "每周限额 · 所有模型\n\u{e02a}\u{e02a}\n已使用 2%")
        compareEnds("实测图标后面接未知正文 → 缺值", "每周限额 · 所有模型\n\u{e02a}\n说明\n已使用 2%")
        compareEnds("实测图标出现在重置之后 → 缺值", "每周限额 · 所有模型\n周一05:00 重置\n\u{e02a}\n已使用 2%")
        compareEnds("实测图标夹在数值字段内部 → 缺值", "每周限额 · 所有模型\n已使用 \u{e02a}2%")
        // 数值之后另起一行的内容不在字段里（与「标题之前另起一行」同理），这一条读出 2 不是新口子。
        compareEnds("数值之后另起一行的图标不影响本栏", "每周限额 · 所有模型\n已使用 2%\n\u{e02a}", week: 2)
        // 结构断言：私用区字符按 `\uXXXX` 转义文本进口径（与换行 / 空白字符类同一套理由——
        // 源码里不出现不可见字符，两端语义相同），而且图标槽位是逐个登记的字面量：没有私用区范围。
        reporter.check("实测图标按 \\uE02A 转义文本进口径（源码与脚本里都不出现不可见字符）",
                       BrowserUsageParser.claudeReadyPattern.contains("\\uE02A"))
        reporter.check("口径里不出现私用区字面字符", !BrowserUsageParser.claudeReadyPattern.contains("\u{e02a}"))
        reporter.check("口径里没有任何码位区间（不是「略过任意私用区字符」）",
                       !BrowserUsageParser.claudeReadyPattern.contains("-\\u"))
        reporter.check("探针脚本里也是转义文本",
                       ChromePageScripts.readinessCondition(for: .claude).contains("\\uE02A")
                        && !ChromePageScripts.readinessCondition(for: .claude).contains("\u{e02a}"))

        reporter.group("Claude 用量契约 · 「您使用 Claude 的地方」按产品占比不可借")
        compareEnds("Claude Code 100% 不是指标", "Claude Code\n100%")
        compareEnds("Claude Code 已使用 100% 也不是指标", "Claude Code\n已使用 100%")
        compareEnds("Claude Code 不冒充 Claude Design", "Claude Code\n已使用 7%")
        compareEnds("按产品占比不被总周额度借走",
                    "每周限额 · 所有模型\n周一05:00 重置\n您使用 Claude 的地方\n按产品\n占您本周请求的比例\nClaude Code\n100%")
        compareEnds("按产品占比不被当前会话借走",
                    "当前会话\n1小时 37 分钟后重置\n占您本周请求的比例\nClaude Code\n100%")

        reporter.group("Claude 用量契约 · 新布局字段的合法空白与换行（两端一致）")
        for (name, space) in [("普通空格", " "), ("Tab", "\t"), ("NBSP U+00A0", "\u{00a0}"), ("零宽空格 U+200B", "\u{200b}"),
                              ("窄 NBSP U+202F", "\u{202f}"), ("U+FEFF", "\u{feff}"), ("图标占位符 U+FFFC", "\u{fffc}"),
                              ("全角空格 U+3000", "\u{3000}")] {
            compareEnds("全称标题分隔符两侧空白 · \(name)", "每周限额\(space)·\(space)所有模型\n已使用 2%", week: 2)
            compareEnds("复合倒计时词元边界空白 · \(name)", "当前会话\n1\(space)小时\(space)37\(space)分钟\(space)后重置\n已使用 8%", session: 8)
            compareEnds("周一与时刻之间空白 · \(name)", "每周限额 · 所有模型\n周一\(space)05:00 重置\n已使用 2%", week: 2)
        }
        for (name, breaker) in [("LF", "\n"), ("VT U+000B", "\u{000b}"), ("FF U+000C", "\u{000c}"), ("CR", "\r"),
                                ("CRLF", "\r\n"), ("NEL U+0085", "\u{0085}"), ("LS U+2028", "\u{2028}"), ("PS U+2029", "\u{2029}")] {
            compareEnds("全称标题分隔符处换行 · \(name)", "每周限额 ·\(breaker)所有模型\n已使用 2%", week: 2)
            compareEnds("复合倒计时词元边界换行 · \(name)", "当前会话\n1小时\(breaker)37 分钟后重置\n已使用 8%", session: 8)
            compareEnds("周一与时刻之间换行 · \(name)", "每周限额 · 所有模型\n周一\(breaker)05:00 重置\n已使用 2%", week: 2)
            // 全称标题的词内部被拆开就不是标题了：分隔符两侧的词仍是精确字面量。
            compareEnds("全称标题词内部换行 · \(name)", "每周限\(breaker)额 · 所有模型\n已使用 2%")
        }

        reporter.group("Claude 用量契约 · 原英文与旧中文布局继续兼容")
        compareEnds("原英文全栏目", mockClaudeText, session: 23, week: 41, design: 7)
        compareEnds("原英文只有 Current session", mockClaudeSessionOnlyText, session: 7)
        compareEnds("旧中文 当前会话 + 12% 已使用", "当前会话\n12% 已使用", session: 12)
        compareEnds("英文标题配中文前缀", "All models\n已使用 68%", week: 68)
        compareEnds("中文标题配英文后缀", "本周\n68% used", week: 68)
        compareEnds("英文标题全大写", "ALL MODELS\n41% USED", week: 41)
        compareEnds("Claude Design 保留", "Claude Design\n7% used", design: 7)
        compareEnds("原英文重置布局（数值之后）", "Current session\n23% used\nResets in 3h 12m", session: 23)
        compareEnds("原英文重置布局 · Resets in 5 minutes", "All models\n41% used\nResets in 5 minutes", week: 41)

        reporter.group("Claude 用量契约 · 数值必须是完整合法字段（0…100 含小数）")
        compareEnds("0%", "本周\n已使用 0%", week: 0)
        compareEnds("100%", "本周\n已使用 100%", week: 100)
        compareEnds("小数 68.5%", "本周\n已使用 68.5%", week: 68.5)
        compareEnds("100.0%", "本周\n已使用 100.0%", week: 100)
        compareEnds("超过 100 拒绝", "本周\n已使用 150%")
        compareEnds("100.5% 拒绝", "本周\n已使用 100.5%")
        compareEnds("数字粘连 168% 拒绝（后缀式）", "本周\n168% 已使用")
        compareEnds("ASCII 负号 -5%", "本周\n已使用 -5%")
        compareEnds("Unicode 负号 \u{2212}5%", "本周\n已使用 \u{2212}5%")
        compareEnds("负号加空格 - 5%", "本周\n已使用 - 5%")
        compareEnds("加号 +5%", "本周\n已使用 +5%")
        compareEnds("千分位 1,50%", "本周\n已使用 1,50%")
        compareEnds("多小数点 5.5.5%", "本周\n已使用 5.5.5%")
        compareEnds("数字之间有空格 1 2%", "本周\n已使用 1 2%")
        compareEnds("全角数字 \u{ff16}8%", "本周\n已使用 \u{ff16}8%")
        compareEnds("全角百分号 68\u{ff05}", "本周\n已使用 68\u{ff05}")
        compareEnds("百分号重复 68%%", "本周\n已使用 68%%")
        compareEnds("数值尾部跟字母", "本周\n已使用 68%x")
        compareEnds("数值尾部跟句号", "本周\n已使用 68%。")
        compareEnds("后缀式标记尾部跟字母", "本周\n68% 已使用x")
        compareEnds("非法字段后另起合法行也不跳过去", "本周\n已使用 68%%\n已使用 68%")

        reporter.group("Claude 用量契约 · 标题必须是完整字段，说明句前缀不算标题")
        compareEnds("标题是说明句前缀", "当前会话的用量会在下一个窗口重置，已使用 0%")
        compareEnds("标题是更长词的前缀", "本周限额说明\n已使用 68%")
        compareEnds("说明句提及重置时间，后方有百分比", "进展正常。您应该能够宽裕地用到明天的重置时间。\n已使用 68%")
        compareEnds("页面标题行不是栏目标题", "您的用量 Max (20x)\n已使用 68%")

        // 正式整改 1/3：独立审查给出的最小反例，原文一字不改。
        // 这一组是本轮的回归锚点 —— 每条都必须两端一致缺值、探针一致为 0。
        reporter.group("Claude 用量契约 · 整改 1/3 审查最小反例")
        compareEnds("审查原文 · 缩进的 Fable", "本周\n 本周 Fable\n已使用 3%")
        compareEnds("审查原文 · 图标占位符缩进的 Fable", "本周\n\u{fffc}本周 Fable\n已使用 3%")
        compareEnds("审查原文 · 拆行的负号", "本周\n-\n5% used")
        compareEnds("审查原文 · 前缀后拆行的负号", "本周\n已使用 -\n5% used")
        compareEnds("审查原文 · 未知栏目标题", "当前会话\n其他额度\n已使用 3%")
        compareEnds("审查原文 · Fable 前有空白行", "本周\n \n本周 Fable\n已使用 3%")
        // 审查套件里 `reset with description` 这一条期望「未登记说明行 + 已知重置」仍读出 68。
        // 它编码的是初稿那套「最多 3 行任意说明行」的旧契约，与本轮「未知行 fail closed」直接冲突；
        // 按整改要求取消任意说明行后，这条必然反转成缺值。原文一字不改地钉在这里，变化是有意的、可见的。
        compareEnds("审查原文 · 未登记说明行 + 已知重置（期望随本轮反转为缺值）",
                    "本周\n说明一\n说明二\n星期一05:00 重置\n已使用 68%")
        // 槽位顺序是「说明 → 重置」，反过来（重置在说明之前）不是已知结构，缺值而不是猜。
        compareEnds("重置排在已知说明之前 → 缺值", "本周\n05:00 重置\n从您的第一条消息开始\n已使用 68%")

        // 前导空白矩阵。两端的归一化链路本来就不同：`LineTools` 会 trim 掉行首的普通空格 / Tab /
        // NBSP / U+200B / 全角空格（Swift 侧），而探针吃的原文不 trim；U+FEFF 与图标占位符 U+FFFC
        // 连 `LineTools` 都不 trim。初稿的前瞻式边界判定正是在这里一端缺值、另一端就绪（甚至两端同时误取）。
        // 现在说明位置只接受白名单字面量，所以无论哪种前导空白，两端都必须给出同一结论。
        reporter.group("Claude 用量契约 · 整改 1/3 前导空白矩阵（两端一致）")
        for (name, indent) in [("无缩进", ""), ("普通空格", " "), ("Tab", "\t"), ("NBSP U+00A0", "\u{00a0}"),
                               ("零宽空格 U+200B", "\u{200b}"), ("窄 NBSP U+202F", "\u{202f}"),
                               ("U+FEFF", "\u{feff}"), ("图标占位符 U+FFFC", "\u{fffc}"), ("全角空格 U+3000", "\u{3000}")] {
            // 缩进的相邻栏目标题不得被当成说明行跨过去。
            compareEnds("缩进的 Fable · \(name)", "本周\n\(indent)本周 Fable\n已使用 3%")
            compareEnds("缩进的未知标题 · \(name)", "当前会话\n\(indent)其他额度\n已使用 3%")
            compareEnds("缩进的拆行负号 · \(name)", "本周\n\(indent)-\n5% used")
            // 缩进的**标题**仍然是标题：本周读出 68，当前会话不得借这个 68。
            compareEnds("缩进的本周标题 · \(name)", "当前会话\n\(indent)本周\n已使用 68%", week: 68)
            // 缩进的已知说明字段照常跨过去。
            compareEnds("缩进的已知说明 · \(name)", "当前会话\n\(indent)从您的第一条消息开始\n已使用 0%", session: 0)
        }

        reporter.group("Claude 用量契约 · 已知栏目标题即边界，数值不跨栏目")
        compareEnds("下一栏是当前会话", "本周\n星期一05:00 重置\n当前会话\n已使用 3%", session: 3)
        compareEnds("下一栏是限额重置", "本周\n星期一05:00 重置\n限额重置\n已使用 3%")
        compareEnds("下一栏是云会话额度", "本周\n星期一05:00 重置\n云会话额度\n已使用 3%")
        compareEnds("下一栏是用量额度", "本周\n星期一05:00 重置\n用量额度\n已使用 3%")
        compareEnds("下一栏是 Plan usage limits", "All models\nResets in 3h 12m\nPlan usage limits\n3% used")

        reporter.group("Claude 用量契约 · 加载中 / 登录 / 空页 / 仅美元额度 / 另一家的页面")
        compareEnds("加载中骨架屏", "您的用量 Max (20x)\n当前会话\n本周\n本周 Fable\n加载中")
        compareEnds("骨架屏（原英文）", "Settings\nUsage\nCurrent session\nAll models\nLoading…")
        compareEnds("登录页", "登录以继续使用 Claude\n使用 Google 账号继续")
        compareEnds("空白页", "")
        compareEnds("错误页", "出了点问题，请重试。")
        compareEnds("仅美元额度",
                    "云会话额度\n自动应用于云会话。该额度用完或过期后，将按您套餐的常规用量计算。\n包含的额度\n11月5日 GMT+8 15:59 过期\n剩余 US$250（共 US$250）\n用量额度\nUS$0")
        compareEnds("Codex 旧中文页文本", mockCodexText)
        compareEnds("Codex 新页截图全文", mockCodexScreenshotText)

        reporter.group("Claude 用量契约 · 缺值与不存在的区别（不伪造栏目）")
        let skeleton = throughProduction("您的用量 Max (20x)\n当前会话\n本周\n本周 Fable\n加载中")
        reporter.check("骨架屏里当前会话标题在 → 产出缺值指标", skeleton.contains { $0.label == "Current session" && $0.usedPercent == nil })
        reporter.check("骨架屏里本周标题在 → 产出缺值指标", skeleton.contains { $0.label == "All models" && $0.usedPercent == nil })
        reporter.check("骨架屏里没有 Claude Design → 整栏不产出", !skeleton.contains { $0.label == "Claude Design" })
        reporter.check("骨架屏不产出任何数值", skeleton.allSatisfy { $0.usedPercent == nil })
        let fableOnly = throughProduction("本周 Fable\nFable 的单独每周限额 · 星期一\n05:00 重置\n已使用 3%")
        reporter.check("只有 Fable 时不产出 All models（本周标题并不单独成行）", !fableOnly.contains { $0.label == "All models" })
        reporter.check("只有 Fable 时不产出任何 Fable 指标", !fableOnly.contains { $0.label.contains("Fable") })
        reporter.equal("只有 Fable 时指标数为 0", fableOnly.count, 0)
        let weekMissing = throughProduction("当前会话\n从您的第一条消息开始\n已使用 0%\n本周\n星期一05:00 重置\n本周 Fable\nFable 的单独每周限额\n已使用 3%")
        reporter.check("本周缺值时仍产出缺值的 All models", weekMissing.contains { $0.label == "All models" && $0.usedPercent == nil })
        reporter.check("本周缺值时没有任何指标等于 3（Fable 不冒充总周额度）", !weekMissing.contains { $0.usedPercent == 3 })

        reporter.group("Claude 用量契约 · 重置文本与百分比来自同一次匹配、同一个栏目")
        func reset(_ raw: String, _ label: String) -> String? {
            throughProduction(raw).first { $0.label == label }?.reset
        }
        reporter.equal("新中文页重置在数值之前", reset("本周\n星期一05:00 重置\n已使用 68%", "All models"), "星期一05:00 重置")
        reporter.equal("重置没有星期前缀", reset("本周\n05:00 重置\n已使用 68%", "All models"), "05:00 重置")
        reporter.equal("重置与数值同一行", reset("本周\n已使用 68% 星期一05:00 重置", "All models"), "星期一05:00 重置")
        reporter.equal("重置在数值之后另起一行", reset("本周\n已使用 68%\n星期一05:00 重置", "All models"), "星期一05:00 重置")
        reporter.equal("原英文重置在数值之后", reset(mockClaudeText, "Current session"), "Resets in 3h 12m")
        reporter.equal("中文倒计时写法（与 Codex 同一份字段）", reset("本周\n3 天后重置\n已使用 68%", "All models"), "3 天后重置")
        // 重置字段内部跨一次换行后，取到的文本把那次换行压回一个空格（卡片详情是单行控件）。
        reporter.equal("重置被 DOM 拆成两行后压成一行", reset("本周\n星期一\n05:00 重置\n已使用 68%", "All models"), "星期一 05:00 重置")
        reporter.check("重置文本永远不含换行",
                       [mockClaudeScreenshotText, "本周\n星期一\n05:00 重置\n已使用 68%", mockClaudeText]
                        .allSatisfy { raw in throughProduction(raw).allSatisfy { !($0.reset ?? "").contains("\n") } })
        // 字段内部只许空白：星期与时刻之间夹正文，这个重置字段就不成立，于是整条匹配失败。
        compareEnds("重置字段内部夹正文 → 缺值", "本周\n星期一\n说明\n05:00 重置\n已使用 68%")
        reporter.equal("重置属于下一栏时不采纳", reset("本周\n已使用 68%\n本周 Fable\n05:00 重置", "All models"), nil)
        reporter.equal("截图全文：本周的重置", reset(mockClaudeScreenshotText, "All models"), "星期一05:00 重置")
        reporter.equal("截图全文：当前会话不借本周的重置", reset(mockClaudeScreenshotText, "Current session"), nil)
        reporter.equal("英文 All models 后面没有重置就是 nil", reset(mockClaudeText, "All models"), nil)
        reporter.equal("英文 Resets 时刻写法", reset("All models\n41% used\nResets Sep 10:00 AM", "All models"), "Resets Sep 10:00 AM")
        reporter.equal("英文 Resets in 5 minutes", reset("All models\n41% used\nResets in 5 minutes", "All models"), "Resets in 5 minutes")
        // 只有日期没有时刻的写法不在重置白名单里（0.2.15 的 Claude 口径同样不接受）：重置留空，但数值照常读出。
        reporter.equal("英文 Resets Sep 30（只有日期）不进重置", reset("All models\n41% used\nResets Sep 30", "All models"), nil)
        reporter.equal("英文 Resets Sep 30 时数值仍读出", used(throughProduction("All models\n41% used\nResets Sep 30"), "All models"), 41)

        reporter.group("Claude 用量契约 · 两端共用同一条正则与同一套归一化")
        let condition = ChromePageScripts.readinessCondition(for: .claude)
        reporter.check("探针用的就是解析口径那条正则", condition.contains(BrowserUsageParser.claudeReadyPattern))
        reporter.check("探针里带上了那套中性归一化", condition.contains(BrowserUsageParser.codexHorizontalSpace) && condition.contains(BrowserUsageParser.codexLineBreak) && condition.contains(BrowserUsageParser.codexObjectReplacement))
        reporter.check("正则只用 ASCII 数字类，不用 \\d", !BrowserUsageParser.claudeReadyPattern.contains(#"\d"#) && BrowserUsageParser.claudeReadyPattern.contains("[0-9]"))
        reporter.check("正则只用显式空白类，不用 \\s", !BrowserUsageParser.claudeReadyPattern.contains(#"\s"#))
        reporter.check("两端都不靠 i 标志，大小写已展开进正则", !condition.contains("/i.test(") && BrowserUsageParser.claudeReadyPattern.contains("[uU]"))
        reporter.check("字段结束约束在位，且不用两端语义不同的 $", BrowserUsageParser.claudeReadyPattern.hasSuffix(#"(?![ ]*[^ \n])"#) && !BrowserUsageParser.claudeReadyPattern.contains("$"))
        // 整改 1/3 的结构保证：口径里不存在任何「任意正文」通配，说明位置只能是白名单字面量。
        // 这三条一起钉住「不靠黑名单、不靠行数、也没有通配」—— 初稿的 `[^\n%]*` 与 `{1,3}?` 都已不在。
        reporter.check("口径里没有任意正文通配（初稿的 [^\\n%]* 已删除）", !BrowserUsageParser.claudeReadyPattern.contains("[^\\n%]"))
        // 初稿的栏目边界是说明行开头那个 `(?!已知标题)` 前瞻，正是它被前导空白回溯绕过。
        // 现在整条口径只剩一个前瞻 —— 末尾的字段结束约束。
        reporter.equal("口径里只剩一个前瞻（字段结束约束）",
                       BrowserUsageParser.claudeReadyPattern.components(separatedBy: "(?!").count - 1, 1)
        // 说明位置是白名单字面量：ASCII 文案在正则里按字符展开成 [sS] 这类字符类，所以逐条用行为断言。
        for field in BrowserUsageParser.claudeDescriptionFields {
            reporter.equal("已登记说明字段可跨过 · \(field)",
                           used(throughProduction("当前会话\n\(field)\n已使用 0%"), "Current session"), 0)
        }
        reporter.equal("已知说明字段只有截图那一条与它的旧英文文案",
                       BrowserUsageParser.claudeDescriptionFields,
                       ["从您的第一条消息开始", "Since your first message"])
        reporter.check("Fable 自己的说明没有登记（Fable 不是指标，不需要跨过它）",
                       !BrowserUsageParser.claudeDescriptionFields.contains { $0.contains("Fable") })
        // 探针与每个栏目用的是同一条正则：除了标题位置（探针取全部指标标题的并集），其余部分逐字相同。
        if let tailRange = BrowserUsageParser.claudeReadyPattern.range(of: ")[ ]*[:：]?") {
            let tail = String(BrowserUsageParser.claudeReadyPattern[tailRange.lowerBound...])
            reporter.check("每个栏目的取值口径与探针口径除标题外逐字相同",
                           BrowserUsageParser.claudeSectionContracts.allSatisfy { $0.usedPattern.hasSuffix(tail) },
                           "\(BrowserUsageParser.claudeSectionContracts.map { $0.label })")
        } else {
            reporter.check("探针口径里能定位到标题之后的部分", false)
        }
        // 大页面不触发病态回溯：截图全文重复 200 次（约 8 万字符），两端都必须很快给出同一结论。
        compareEnds("截图全文重复 200 次", Array(repeating: mockClaudeScreenshotText, count: 200).joined(separator: "\n"), session: 0, week: 68)

        reporter.group("Claude 用量契约 · 栏目标识与用户偏好不受文案变化影响")
        reporter.equal("「本周」精确映射到既有 All models", BrowserUsageParser.claudeSections.first { $0.titles.contains("本周") }?.label, "All models")
        reporter.equal("「当前会话」映射到 Current session", BrowserUsageParser.claudeSections.first { $0.titles.contains("当前会话") }?.label, "Current session")
        reporter.equal("内部标识仍是 0.2.13 起的三个英文名", BrowserUsageParser.claudeSections.map { $0.label }, ["Current session", "All models", "Claude Design"])
        reporter.equal("状态栏 allModels 档读的就是 All models", ClaudeStatusMetric.allModels.label, "All models")
        reporter.check("「本周 Fable」不是任何指标的标题", !BrowserUsageParser.claudeSections.contains { $0.titles.contains("本周 Fable") })
        // 整改 1/3 起不再有栏目边界表：任何不是已知说明 / 已知重置 / 百分比的正文都跨不过去，
        // 所以截图里其余标题（限额重置 / 云会话额度 / 包含的额度 / 用量额度 / 您的用量）与任何
        // 未知标题都不需要预先登记 —— 下面逐条用行为断言代替原来的结构断言。
        for heading in ["本周 Fable", "本周Fable", "限额重置", "云会话额度", "包含的额度", "用量额度", "您的用量",
                        "其他额度", "本月", "Plan usage limits", "Extra usage",
                        // 0.2.18 新布局里新出现的相邻标题：Fable 自己（标题已不带「本周」）、
                        // 「您使用 Claude 的地方」下面的按产品 / 按设备分布，以及全称标题的两个半段。
                        "Fable", "您使用 Claude 的地方", "按产品", "按设备", "占您本周请求的比例",
                        "Claude Code", "每周限额", "所有模型"] {
            compareEnds("未知/相邻标题跨不过去 · \(heading)", "本周\n\(heading)\n已使用 3%")
        }
        for section in BrowserUsageParser.claudeSections {
            for title in section.titles {
                let page = "\(title)\n已使用 68%"
                reporter.equal("标题可用 · \(title)", used(throughProduction(page), section.label), 68)
                reporter.equal("标题可用 · \(title) · 探针", evaluateProbe(.claude, readyState: "complete", text: page), "1")
                reporter.equal("标题大小写变体 · \(title)", used(throughProduction("\(title.uppercased())\n68% used"), section.label), 68)
            }
        }

        reporter.group("Claude 用量契约 · 换行字符两端对齐（经过生产 LineTools 链路）")
        for (name, breaker) in [("LF", "\n"), ("VT U+000B", "\u{000b}"), ("FF U+000C", "\u{000c}"), ("CR", "\r"),
                                ("CRLF", "\r\n"), ("NEL U+0085", "\u{0085}"), ("LS U+2028", "\u{2028}"), ("PS U+2029", "\u{2029}")] {
            // 标题与数值之间：就是一次正常换行，两端都应读出 68。
            compareEnds("标题与数值之间 · \(name)", "本周\(breaker)已使用 68%", week: 68)
            // 重置行与数值之间：同样是一次换行。
            compareEnds("重置与数值之间 · \(name)", "本周\n星期一05:00 重置\(breaker)已使用 68%", week: 68)
            // 标题单词内部：Foundation 在这里分行，标题不再是完整字段 —— 两端一致拒绝。
            compareEnds("标题单词内部 · \(name)", "All\(breaker)models\n68% used")
            // 数值字段内部：数值被拆开，不是完整字段 —— 两端一致拒绝。
            compareEnds("数值字段内部 · \(name)", "本周\n已使用 6\(breaker)8%")
        }
        // 不间断空格 / 制表符 / 全角空格都只是横向空白；U+200B 在 CharacterSet.whitespaces 里，
        // LineTools 会在行首行尾 trim 掉，两端都按横向空白压掉才一致。
        compareEnds("不间断空格与制表符", "本周\n\u{00a0}\t已使用 68%", week: 68)
        compareEnds("全角空格", "本周\u{3000}\n已使用\u{3000}68%", week: 68)
        compareEnds("标题行尾零宽空格", "本周\u{200b}\n已使用 68%", week: 68)
        compareEnds("数值行首零宽空格", "本周\n\u{200b}已使用 68%", week: 68)
        compareEnds("行内零宽空格", "本周\n已使用\u{200b}68%", week: 68)
        compareEnds("标题与数值之间 150 个空格", "本周" + String(repeating: " ", count: 150) + "已使用 68%", week: 68)
        compareEnds("标题与数值之间有空行", "本周\n\n已使用 68%", week: 68)
        compareEnds("正文以换行结尾", "本周\n已使用 68%\n", week: 68)
        compareEnds("图标占位符当空白", "本周\n\u{fffc}已使用 68%", week: 68)

        reporter.group("Claude 用量契约 · 不影响已验收的 Codex 行为")
        reporter.equal("Claude 新中文页不让 Codex 探针就绪", evaluateProbe(.codex, readyState: "complete", text: mockClaudeScreenshotText), "0")
        reporter.equal("Codex 解析 Claude 新中文页 = 空", BrowserUsageParser.parseCodex(lines: LineTools.normalize([mockClaudeScreenshotText], deduplicate: false)).count, 0)
        reporter.check("Claude 截图里的「每周限额」只在句中出现，不在行首",
                       mockClaudeScreenshotText.contains("每周限额") && !mockClaudeScreenshotText.split(separator: "\n").contains { $0.hasPrefix("每周限额") })
        // 0.2.18 新布局把「每周限额」搬到了行首（全称标题的前半段），所以这条边界必须用行为断言钉住：
        // Codex 的周额度口径要求标题之后只能接空白 / 冒号 / 已知重置 / 剩余百分比，`· 所有模型` 三者都不是。
        reporter.check("新布局截图里「每周限额」确实在行首（下面两条才是真正的边界证据）",
                       mockClaudeExpandedScreenshotText.split(separator: "\n").contains { $0.hasPrefix("每周限额") })
        reporter.equal("Codex 解析新布局折叠截图 = 空",
                       BrowserUsageParser.parseCodex(lines: LineTools.normalize([mockClaudeCollapsedScreenshotText], deduplicate: false)).count, 0)
        reporter.equal("Codex 解析新布局展开截图 = 空",
                       BrowserUsageParser.parseCodex(lines: LineTools.normalize([mockClaudeExpandedScreenshotText], deduplicate: false)).count, 0)
        reporter.equal("新布局折叠截图不让 Codex 探针就绪", evaluateProbe(.codex, readyState: "complete", text: mockClaudeCollapsedScreenshotText), "0")
        reporter.equal("新布局展开截图不让 Codex 探针就绪", evaluateProbe(.codex, readyState: "complete", text: mockClaudeExpandedScreenshotText), "0")
        reporter.equal("Claude 新布局的复合倒计时不改变 Codex 中文倒计时",
                       BrowserUsageParser.parseCodex(lines: LineTools.normalize(["每周限额\n1小时 37 分钟后重置\n剩余 83%"], deduplicate: false)).first?.remainingPercent, nil)
        reporter.equal("Codex 新页仍是 83", BrowserUsageParser.parseCodex(lines: LineTools.normalize([mockCodexScreenshotText], deduplicate: false)).first?.remainingPercent, 83)
        reporter.equal("Codex 新页探针仍就绪", evaluateProbe(.codex, readyState: "complete", text: mockCodexScreenshotText), "1")
        reporter.equal("Codex 旧中文页仍是 68", BrowserUsageParser.parseCodex(lines: LineTools.normalize([mockCodexText], deduplicate: false)).first?.remainingPercent, 68)
    }

    // MARK: 状态栏档位绑定（0.2.18：指定指标无值时显示 --，不回退到别的指标）

    /// `Snapshot.claudeHint` 只认被选中的那一个指标。取不到值就返回 nil，状态栏按现成的 UI 行为
    /// 显示 `--`，而不是回退到卡片的 `statusBarHint` —— 那是「所有指标里最低的剩余」，
    /// 选了 All models 却显示 Current session 的数就是错指标（用户看到的是一个看似正常的假值）。
    /// Codex 只有 weekly 一个档位（解析器产出的标签恒等于它），回退行为本轮不动，这里一并钉住。
    static func testClaudeStatusMetricSelection(_ reporter: TestReporter) {
        reporter.group("状态栏档位 · 指定指标无值时显示 --（不回退到别的指标或 statusBarHint）")
        func webCard(_ provider: String, _ progress: [(String, Double)], hint: String?) -> QuotaCard {
            QuotaCard(
                provider: provider,
                headline: "已读取",
                details: [],
                status: .ok,
                remainingUSD: nil,
                statusBarHint: hint,
                progress: progress.map {
                    QuotaProgress(label: $0.0, percent: $0.1, valueText: "\(Int($0.1))% 剩余", detail: nil)
                },
                confirmedAt: fixedNow
            )
        }

        // 只有 Current session 有值：卡片的 statusBarHint 是 92%（最低剩余），All models 档必须是 nil。
        let sessionOnly = Snapshot(updatedAt: fixedNow, cards: [webCard("Claude 网页额度", [("Current session", 92)], hint: "92%")])
        reporter.equal("选 allModels 无值 → nil", sessionOnly.claudeHint(metric: .allModels), nil)
        reporter.equal("选 claudeDesign 无值 → nil", sessionOnly.claudeHint(metric: .claudeDesign), nil)
        reporter.equal("选 currentSession 有值 → 取该指标", sessionOnly.claudeHint(metric: .currentSession), "92%")
        reporter.equal("双行标题 Claude 侧显示 --",
                       sessionOnly.statusTitle(mode: .split, codexMetric: .weekly, claudeMetric: .allModels), "A -- · C --")
        reporter.equal("只显示 Claude 且该档无值 → AI",
                       sessionOnly.statusTitle(mode: .claude, codexMetric: .weekly, claudeMetric: .allModels), "AI")
        reporter.equal("只显示 Claude 且该档有值 → A 92%",
                       sessionOnly.statusTitle(mode: .claude, codexMetric: .weekly, claudeMetric: .currentSession), "A 92%")
        reporter.equal("最低额度档不把别的指标算进来",
                       sessionOnly.statusTitle(mode: .lowest, codexMetric: .weekly, claudeMetric: .allModels), "AI")
        reporter.equal("该档无值时表情回到未知",
                       sessionOnly.statusMood(mode: .claude, codexMetric: .weekly, claudeMetric: .allModels), .unknown)
        reporter.equal("该档有值时表情按该指标算",
                       sessionOnly.statusMood(mode: .claude, codexMetric: .weekly, claudeMetric: .currentSession), .happy)

        // 两个指标都有值：各自取各自的，互不借用。
        let both = Snapshot(updatedAt: fixedNow, cards: [webCard("Claude 网页额度", [("Current session", 92), ("All models", 98)], hint: "92%")])
        reporter.equal("选 allModels = 98%", both.claudeHint(metric: .allModels), "98%")
        reporter.equal("选 currentSession = 92%", both.claudeHint(metric: .currentSession), "92%")

        // 进度条标签与档位不匹配时：Claude 不再回退，Codex 的回退行为本轮不变。
        let claudeMismatch = Snapshot(updatedAt: fixedNow, cards: [webCard("Claude 网页额度", [("别的指标名", 77)], hint: "77%")])
        reporter.equal("Claude 指定指标无值时不回退到 statusBarHint", claudeMismatch.claudeHint(metric: .allModels), nil)
        let codexMismatch = Snapshot(updatedAt: fixedNow, cards: [webCard("Codex 网页额度", [("别的指标名", 77)], hint: "77%")])
        reporter.equal("Codex 档位的回退行为本轮不变", codexMismatch.codexHint(metric: .weekly), "77%")
        // `--` 只出现在**双行 A/C**模式的状态栏图像里。「只显示 Claude」「最低额度」两档在该指标无值时
        // 走的是既有的 `AI` / 有错误卡片时 `AI !`，本轮没有改这一点，文档也不该笼统说「显示 --」。
        let withError = Snapshot(updatedAt: fixedNow, cards: [
            webCard("Claude 网页额度", [("Current session", 92)], hint: "92%"),
            QuotaCard(provider: "Codex 网页额度", headline: "读取失败", details: [], status: .error, remainingUSD: nil, statusBarHint: nil)
        ])
        reporter.equal("只显示 Claude · 该档无值 + 有错误卡片 → AI !",
                       withError.statusTitle(mode: .claude, codexMetric: .weekly, claudeMetric: .allModels), "AI !")
        reporter.equal("最低额度 · 该档无值 + 有错误卡片 → AI !",
                       withError.statusTitle(mode: .lowest, codexMetric: .weekly, claudeMetric: .allModels), "AI !")
        reporter.equal("双行模式下该档无值才是 --",
                       withError.statusTitle(mode: .split, codexMetric: .weekly, claudeMetric: .allModels), "A -- · C --")

        // 没有网页卡片时两边都是 nil（与 0.2.17 一致）。
        let empty = Snapshot(updatedAt: fixedNow, cards: [])
        reporter.equal("没有卡片时 Claude 档位 = nil", empty.claudeHint(metric: .allModels), nil)
        reporter.equal("没有卡片时 Codex 档位 = nil", empty.codexHint(metric: .weekly), nil)
    }

    // MARK: Apple Event 描述符（只构造、不发送）

    static func testChromeAppleEventDescriptors(_ reporter: TestReporter) {
        typealias C = ChromeAppleEventCodes
        reporter.group("Apple Event 描述符构造（不发送）")
        reporter.equal("四字符码编码", AppleEventCode.code("cwin"), 0x6377_696E)
        reporter.equal("四字符码解码", AppleEventCode.text(0x6377_696E), "cwin")

        let target = NSAppleEventDescriptor(processIdentifier: 4242)
        reporter.equal("目标描述符类型 = typeKernelProcessID", target.descriptorType, C.typeKernelProcessID)
        reporter.equal("目标描述符载荷 = PID", target.data.withUnsafeBytes { $0.count >= 4 ? $0.loadUnaligned(as: Int32.self) : -1 }, 4242)

        let clock = MockChromeReadClock()
        let transport = ChromeAppleEventTransport(
            identity: ChromeInstanceIdentity(pid: 4242, startTime: startTime(), bundleURL: URL(fileURLWithPath: "/Applications/Google Chrome.app")),
            budget: ChromeReadBudget(clock: clock, seconds: 60)
        )
        reporter.equal("传输层目标类型 = kpid", transport.targetDescriptor.descriptorType, C.typeKernelProcessID)
        reporter.equal("传输层目标 PID", transport.targetDescriptor.data.withUnsafeBytes { $0.count >= 4 ? $0.loadUnaligned(as: Int32.self) : -1 }, 4242)

        let tab = ChromeSpecifier.tab(id: "7", inWindowID: "3")
        reporter.equal("tab 说明符类型 = obj", tab.descriptorType, C.typeObjectSpecifier)
        reporter.equal("tab 说明符 want = CrTb", tab.forKeyword(C.desiredClass)?.typeCodeValue, C.tabClass)
        reporter.equal("tab 说明符 form = ID", tab.forKeyword(C.keyForm)?.enumCodeValue, C.formUniqueID)
        reporter.equal("tab 说明符 seld = \"7\"（文本）", tab.forKeyword(C.keyData)?.stringValue, "7")
        let window = tab.forKeyword(C.container)
        reporter.equal("容器 = window id", window?.forKeyword(C.desiredClass)?.typeCodeValue, C.windowClass)
        reporter.equal("容器 form = ID", window?.forKeyword(C.keyForm)?.enumCodeValue, C.formUniqueID)
        reporter.equal("容器 seld = \"3\"", window?.forKeyword(C.keyData)?.stringValue, "3")
        reporter.equal("窗口容器 = 应用(null)", window?.forKeyword(C.container)?.descriptorType, C.typeNull)

        let everyWindowIDs = ChromeSpecifier.property(C.idProperty, of: ChromeSpecifier.everyWindow())
        reporter.equal("id of every window: want = prop", everyWindowIDs.forKeyword(C.desiredClass)?.typeCodeValue, C.propertyClass)
        reporter.equal("id of every window: seld = ID", everyWindowIDs.forKeyword(C.keyData)?.typeCodeValue, C.idProperty)
        let everyWindow = everyWindowIDs.forKeyword(C.container)
        reporter.equal("every window: form = indx", everyWindow?.forKeyword(C.keyForm)?.enumCodeValue, C.formAbsolutePosition)
        reporter.equal("every window: seld 类型 = abso", everyWindow?.forKeyword(C.keyData)?.descriptorType, C.typeAbsoluteOrdinal)
        reporter.equal("every window: seld 值 = all", everyWindow?.forKeyword(C.keyData)?.data.withUnsafeBytes { $0.count >= 4 ? $0.loadUnaligned(as: UInt32.self) : 0 }, C.allElements)

        let loading = ChromeSpecifier.property(C.loadingProperty, of: tab)
        reporter.equal("loading 属性说明符 seld = ldng", loading.forKeyword(C.keyData)?.typeCodeValue, C.loadingProperty)

        let getData = ChromeEvent.getData(everyWindowIDs, target: target)
        reporter.equal("getd 事件类", getData.eventClass, C.coreSuite)
        reporter.equal("getd 事件 ID", getData.eventID, C.getData)
        reporter.equal("getd 直接参数存在", getData.paramDescriptor(forKeyword: C.directObject)?.descriptorType, C.typeObjectSpecifier)
        reporter.equal("getd 目标是 kpid", getData.attributeDescriptor(forKeyword: C.addressAttribute)?.descriptorType, C.typeKernelProcessID)

        let reload = ChromeEvent.reload(tab: tab, target: target)
        reporter.equal("reload 事件类 = CrSu", reload.eventClass, C.chromiumSuite)
        reporter.equal("reload 事件 ID = Rlod", reload.eventID, C.reload)
        reporter.equal("reload 直接参数 = tab id 对象", reload.paramDescriptor(forKeyword: C.directObject)?.forKeyword(C.keyData)?.stringValue, "7")

        let execute = ChromeEvent.executeJavaScript(tab: tab, script: "1+1", target: target)
        reporter.equal("execute 事件 ID = ExJa", execute.eventID, C.executeJavaScript)
        reporter.equal("execute javascript 参数", execute.paramDescriptor(forKeyword: C.javascriptParameter)?.stringValue, "1+1")
        reporter.equal("execute 目标 PID", execute.attributeDescriptor(forKeyword: C.addressAttribute)?.data.withUnsafeBytes { $0.count >= 4 ? $0.loadUnaligned(as: Int32.self) : -1 }, 4242)

        reporter.group("Apple Event 回复解析与错误映射")
        let list = NSAppleEventDescriptor.list()
        list.insert(NSAppleEventDescriptor(int32: 12), at: 1)
        list.insert(NSAppleEventDescriptor(string: "34"), at: 2)
        reporter.equal("列表回复 → 文本数组（整数也转文本）", ChromeAppleEventTransport.textList(list), ["12", "34"])
        reporter.equal("单值回复包成一项", ChromeAppleEventTransport.textList(NSAppleEventDescriptor(string: "x")), ["x"])
        reporter.equal("null 回复 → 空", ChromeAppleEventTransport.textList(NSAppleEventDescriptor.null()), [])
        reporter.equal("缺失回复 → 空", ChromeAppleEventTransport.textList(nil), [])

        let denied = ChromeEventError.fromOSStatus(-1743, stage: .enumerateWindows, chromeMessage: nil)
        reporter.check("-1743 = 权限拒绝", denied.isPermissionDenied && denied.message.contains("自动化"))
        reporter.check("-1744 = 需用户确认", ChromeEventError.fromOSStatus(-1744, stage: .reload, chromeMessage: nil).isPermissionDenied)
        reporter.check("-1712 = 超时", ChromeEventError.fromOSStatus(-1712, stage: .read, chromeMessage: nil).isTimeout)
        reporter.check("-600 = 进程消失", ChromeEventError.fromOSStatus(-600, stage: .reload, chromeMessage: nil).isProcessGone)
        reporter.check("身份 / 看门狗是致命错误，其它不是",
                       ChromeEventError(stage: .identity, code: nil, message: "x").isFatal
                        && ChromeEventError(stage: .watchdog, code: nil, message: "x").isFatal
                        && !denied.isFatal)
        let javascriptOff = ChromeEventError.fromOSStatus(-10000, stage: .read, chromeMessage: "Executing JavaScript through AppleScript is turned off.")
        reporter.check("JS 关闭错误保留 Chrome 原文", javascriptOff.isJavaScriptRelated && (javascriptOff.errorDescription ?? "").contains("turned off"))
        reporter.check("错误描述含阶段与代码", (denied.errorDescription ?? "").hasPrefix("枚举窗口失败") && (denied.errorDescription ?? "").contains("[-1743]"))

        reporter.group("Chrome sdef 术语表比对")
        let sdefPath = "/Applications/Google Chrome.app/Contents/Resources/scripting.sdef"
        guard FileManager.default.fileExists(atPath: sdefPath),
              let document = try? XMLDocument(contentsOf: URL(fileURLWithPath: sdefPath), options: []) else {
            reporter.skip("sdef 代码比对", "本机没有安装 Google Chrome 或 sdef 不可读")
            return
        }
        func attribute(_ xpath: String) -> String? {
            (try? document.nodes(forXPath: xpath))?.first?.stringValue
        }
        reporter.equal("sdef: tab 类代码", attribute("//class[@name='tab']/@code"), "CrTb")
        reporter.equal("sdef: window 类代码", attribute("//class[@name='window']/@code"), "cwin")
        reporter.equal("sdef: tab.id 代码", attribute("//class[@name='tab']/property[@name='id']/@code"), "ID  ")
        reporter.equal("sdef: tab.URL 代码", attribute("//class[@name='tab']/property[@name='URL']/@code"), "URL ")
        reporter.equal("sdef: tab.loading 代码", attribute("//class[@name='tab']/property[@name='loading']/@code"), "ldng")
        reporter.equal("sdef: window.id 代码", attribute("//class[@name='window']/property[@name='id']/@code"), "ID  ")
        reporter.equal("sdef: reload 命令代码", attribute("//command[@name='reload']/@code"), "CrSuRlod")
        reporter.equal("sdef: execute 命令代码", attribute("//command[@name='execute']/@code"), "CrSuExJa")
        reporter.equal("sdef: execute.javascript 参数代码", attribute("//command[@name='execute']/parameter[@name='javascript']/@code"), "JvSc")
        reporter.check("sdef: id 类型为 text（按文本发送 ID）", attribute("//class[@name='tab']/property[@name='id']/@type") == "text")
    }

    // MARK: 传输边界（真实传输层 + 注入的假发送）

    static func testChromeTransportBoundary(_ reporter: TestReporter) {
        typealias C = ChromeAppleEventCodes
        reporter.group("传输边界 · 发送前 / 回复后身份核验、预算与取消（真实传输层）")
        let identity = ChromeInstanceIdentity(pid: 4242, startTime: startTime(), bundleURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"))

        func reply(ids: [String]) -> NSAppleEventDescriptor {
            let descriptor = NSAppleEventDescriptor.appleEvent(withEventClass: C.coreSuite, eventID: C.getData, targetDescriptor: nil, returnID: -1, transactionID: 0)
            let list = NSAppleEventDescriptor.list()
            for (index, id) in ids.enumerated() {
                list.insert(NSAppleEventDescriptor(string: id), at: index + 1)
            }
            descriptor.setParam(list, forKeyword: C.directObject)
            return descriptor
        }
        func errorReply(_ code: Int32, message: String) -> NSAppleEventDescriptor {
            let descriptor = NSAppleEventDescriptor.appleEvent(withEventClass: C.coreSuite, eventID: C.getData, targetDescriptor: nil, returnID: -1, transactionID: 0)
            descriptor.setParam(NSAppleEventDescriptor(int32: code), forKeyword: C.errorNumber)
            descriptor.setParam(NSAppleEventDescriptor(string: message), forKeyword: C.errorString)
            return descriptor
        }
        func stage(_ error: Error) -> ChromeEventError.Stage? { (error as? ChromeEventError)?.stage }

        // 1. 发送前身份失效：不发送。
        var rawSends = 0
        let clock1 = MockChromeReadClock()
        let preFail = ChromeAppleEventTransport(
            identity: identity,
            budget: ChromeReadBudget(clock: clock1, seconds: 10),
            rawSend: { _, _ in rawSends += 1; return reply(ids: ["1"]) },
            identityCheck: { "内核启动时间已变化（mock）" }
        )
        do {
            _ = try preFail.windowIDs()
            reporter.check("发送前身份失效应抛错", false)
        } catch {
            reporter.equal("发送前身份失效 = 身份阶段错误", stage(error), .identity)
        }
        reporter.equal("发送前身份失效不发送事件", rawSends, 0)
        reporter.check("事件日志记录未发送原因", preFail.eventLog.last?.contains("未发送（身份失效") == true, "\(preFail.eventLog)")

        // 2. 回复到达后身份失效：回复不采纳。
        rawSends = 0
        var checks = 0
        let postFail = ChromeAppleEventTransport(
            identity: identity,
            budget: ChromeReadBudget(clock: MockChromeReadClock(), seconds: 10),
            rawSend: { _, _ in rawSends += 1; return reply(ids: ["1", "2"]) },
            identityCheck: { checks += 1; return checks == 2 ? "回复后启动时间已变化（mock）" : nil }
        )
        do {
            _ = try postFail.windowIDs()
            reporter.check("回复后身份失效应抛错", false)
        } catch {
            reporter.equal("回复后身份失效 = 身份阶段错误", stage(error), .identity)
            reporter.check("错误说明回复未采纳", (error as? ChromeEventError)?.message.contains("回复未采纳") == true)
        }
        reporter.equal("回复后身份失效：事件已发出 1 次", rawSends, 1)
        reporter.check("事件日志记录回复已丢弃", postFail.eventLog.last?.contains("回复已丢弃") == true, "\(postFail.eventLog)")
        do {
            _ = try postFail.windowIDs()
            reporter.check("身份恢复后（mock 第 3/4 次通过）可再发送", true)
        } catch {
            reporter.check("身份恢复后可再发送", false, "\(error)")
        }

        // 3. 已取消：不发送。
        rawSends = 0
        let cancelledBudget = ChromeReadBudget(clock: MockChromeReadClock(), seconds: 10)
        cancelledBudget.cancel()
        let cancelled = ChromeAppleEventTransport(identity: identity, budget: cancelledBudget, rawSend: { _, _ in rawSends += 1; return reply(ids: []) }, identityCheck: { nil })
        do {
            _ = try cancelled.windowIDs()
            reporter.check("取消后应抛错", false)
        } catch {
            reporter.equal("取消后 = 看门狗阶段错误", stage(error), .watchdog)
        }
        reporter.equal("取消后不发送事件", rawSends, 0)
        reporter.check("取消后日志记录未发送", cancelled.eventLog.last?.contains("未发送") == true)

        // 4. 预算耗尽：不发送。
        rawSends = 0
        let exhaustedClock = MockChromeReadClock()
        let exhaustedBudget = ChromeReadBudget(clock: exhaustedClock, seconds: 10)
        let exhausted = ChromeAppleEventTransport(identity: identity, budget: exhaustedBudget, rawSend: { _, _ in rawSends += 1; return reply(ids: []) }, identityCheck: { nil })
        exhaustedClock.advance(10.5)
        do {
            _ = try exhausted.windowIDs()
            reporter.check("预算耗尽应抛错", false)
        } catch {
            reporter.equal("预算耗尽 = 看门狗阶段错误", stage(error), .watchdog)
        }
        reporter.equal("预算耗尽不发送事件", rawSends, 0)

        // 4b. 身份核验期间越过 deadline：身份核验之后、发送之前再次 checkpoint，零发送。
        rawSends = 0
        let slowIdentityClock = MockChromeReadClock()
        let slowIdentityBudget = ChromeReadBudget(clock: slowIdentityClock, seconds: 10)
        let slowIdentity = ChromeAppleEventTransport(identity: identity, budget: slowIdentityBudget, rawSend: { _, _ in rawSends += 1; return reply(ids: []) }, identityCheck: { slowIdentityClock.advance(11); return nil })
        do {
            _ = try slowIdentity.windowIDs()
            reporter.check("身份核验期间越界应抛错", false)
        } catch {
            reporter.equal("身份核验期间越界 = 看门狗阶段错误", stage(error), .watchdog)
        }
        reporter.equal("身份核验期间越界零发送", rawSends, 0)
        reporter.check("日志记录身份核验后未发送", slowIdentity.eventLog.last?.contains("未发送（身份核验后") == true, "\(slowIdentity.eventLog)")

        // 4c. 身份核验期间看门狗取消：零发送。
        rawSends = 0
        let cancelDuringIdentityBudget = ChromeReadBudget(clock: MockChromeReadClock(), seconds: 10)
        let cancelDuringIdentity = ChromeAppleEventTransport(identity: identity, budget: cancelDuringIdentityBudget, rawSend: { _, _ in rawSends += 1; return reply(ids: []) }, identityCheck: { cancelDuringIdentityBudget.cancel(); return nil })
        do {
            _ = try cancelDuringIdentity.windowIDs()
            reporter.check("身份核验期间取消应抛错", false)
        } catch {
            reporter.equal("身份核验期间取消 = 看门狗阶段错误", stage(error), .watchdog)
        }
        reporter.equal("身份核验期间取消零发送", rawSends, 0)

        // 4d. 回复晚到、没有取消标志：按同一 deadline 丢弃。
        rawSends = 0
        let lateClock = MockChromeReadClock()
        let lateBudget = ChromeReadBudget(clock: lateClock, seconds: 10)
        let late = ChromeAppleEventTransport(identity: identity, budget: lateBudget, rawSend: { _, _ in rawSends += 1; lateClock.advance(10.5); return reply(ids: ["1"]) }, identityCheck: { nil })
        do {
            _ = try late.windowIDs()
            reporter.check("晚到回复应丢弃", false)
        } catch {
            reporter.equal("晚到回复（无取消标志）= 看门狗阶段错误", stage(error), .watchdog)
            reporter.check("错误说明回复未采纳", (error as? ChromeEventError)?.message.contains("回复未采纳") == true)
        }
        reporter.equal("晚到回复：事件已发出 1 次", rawSends, 1)
        reporter.check("日志记录回复已丢弃且没有取消标志", late.eventLog.last?.contains("回复已丢弃") == true && !lateBudget.isCancelled)

        // 5. 事件等待时间不超过剩余预算；剩余不足 0.1 秒时拒绝而不是扩大。
        var observedTimeouts: [TimeInterval] = []
        let timeoutClock = MockChromeReadClock()
        let timeoutBudget = ChromeReadBudget(clock: timeoutClock, seconds: 10)
        let bounded = ChromeAppleEventTransport(identity: identity, budget: timeoutBudget, rawSend: { _, timeout in observedTimeouts.append(timeout); return reply(ids: ["9"]) }, identityCheck: { nil })
        reporter.equal("预算充足时等待 = min(15, 剩余 10)", try? bounded.windowIDs(), ["9"])
        timeoutClock.advance(9.4)
        _ = try? bounded.windowIDs()
        // 虚拟时钟做减法有浮点尾数（0.6000000000000227），按毫秒取整比较。
        let milliseconds: ([TimeInterval]) -> [Int] = { $0.map { Int(($0 * 1000).rounded()) } }
        reporter.equal("等待时间序列", milliseconds(observedTimeouts), [10_000, 600])
        timeoutClock.advance(0.55)
        do {
            _ = try bounded.windowIDs()
            reporter.check("剩余 0.05 秒应拒绝", false)
        } catch {
            reporter.equal("剩余 0.05 秒 = 看门狗阶段错误（不扩大到 0.1）", stage(error), .watchdog)
        }
        reporter.equal("剩余 0.05 秒没有发送", milliseconds(observedTimeouts), [10_000, 600])

        // 5b. 页面就绪阶段上限传入传输层：等待受阶段剩余约束，不足时非致命拒绝，回复晚于阶段上限则丢弃。
        observedTimeouts = []
        let stageClock = MockChromeReadClock()
        let stageBudget = ChromeReadBudget(clock: stageClock, seconds: 62)
        var stageAdvance: TimeInterval = 0
        let staged = ChromeAppleEventTransport(identity: identity, budget: stageBudget, rawSend: { _, timeout in observedTimeouts.append(timeout); stageClock.advance(stageAdvance); return reply(ids: ["s"]) }, identityCheck: { nil })
        stageBudget.beginStage(deadline: stageClock.uptime() + 5)
        _ = try? staged.windowIDs()
        reporter.equal("阶段内等待 = 阶段剩余 5（整轮剩余 62）", observedTimeouts, [5])
        stageClock.advance(4.95)
        do {
            _ = try staged.tabLoading(windowID: "1", tabID: "2")
            reporter.check("阶段剩余 0.05 应拒绝", false)
        } catch {
            let chromeError = error as? ChromeEventError
            reporter.check("阶段不足 = 非致命阶段限制错误（探测阶段）", chromeError?.isStageLimit == true && chromeError?.isFatal == false && chromeError?.stage == .probe, "\(String(describing: chromeError))")
        }
        reporter.equal("阶段不足没有发送", observedTimeouts, [5])
        stageBudget.endStage()
        stageBudget.beginStage(deadline: stageClock.uptime() + 5)
        stageAdvance = 6
        do {
            _ = try staged.tabLoading(windowID: "1", tabID: "2")
            reporter.check("回复晚于阶段上限应丢弃", false)
        } catch {
            let chromeError = error as? ChromeEventError
            reporter.check("回复晚于阶段上限 = 非致命阶段限制，回复不采纳", chromeError?.isStageLimit == true && chromeError?.isFatal == false && chromeError?.message.contains("不采纳") == true, "\(String(describing: chromeError))")
        }
        reporter.check("整轮预算仍未耗尽", stageBudget.remaining() > 40)
        stageBudget.endStage()
        stageAdvance = 0
        _ = try? staged.windowIDs()
        reporter.equal("结束阶段后等待恢复为 min(15, 整轮剩余)", observedTimeouts.last, 15)

        // 6. 回复到达时看门狗已取消：回复不采纳。
        rawSends = 0
        let raceClock = MockChromeReadClock()
        let raceBudget = ChromeReadBudget(clock: raceClock, seconds: 10)
        let raced = ChromeAppleEventTransport(identity: identity, budget: raceBudget, rawSend: { _, _ in rawSends += 1; raceBudget.cancel(); return reply(ids: ["1"]) }, identityCheck: { nil })
        do {
            _ = try raced.windowIDs()
            reporter.check("回复到达时已取消应抛错", false)
        } catch {
            reporter.equal("回复到达时已取消 = 看门狗阶段错误", stage(error), .watchdog)
            reporter.check("错误说明回复未采纳", (error as? ChromeEventError)?.message.contains("回复未采纳") == true)
        }
        reporter.check("日志记录回复已丢弃（看门狗）", raced.eventLog.last?.contains("回复已丢弃（看门狗") == true)

        // 7. 回复里的 errn / errs 映射；发送抛出的 OSStatus 映射。
        let deniedTransport = ChromeAppleEventTransport(identity: identity, budget: ChromeReadBudget(clock: MockChromeReadClock(), seconds: 10), rawSend: { _, _ in errorReply(-1743, message: "not permitted") }, identityCheck: { nil })
        do {
            _ = try deniedTransport.windowIDs()
            reporter.check("errn -1743 应抛错", false)
        } catch {
            reporter.check("errn -1743 → 权限拒绝", (error as? ChromeEventError)?.isPermissionDenied == true)
            reporter.equal("阶段 = 枚举窗口", stage(error), .enumerateWindows)
        }
        let timedOut = ChromeAppleEventTransport(identity: identity, budget: ChromeReadBudget(clock: MockChromeReadClock(), seconds: 10), rawSend: { _, _ in throw NSError(domain: NSOSStatusErrorDomain, code: -1712) }, identityCheck: { nil })
        do {
            _ = try timedOut.reload(windowID: "1", tabID: "2")
            reporter.check("-1712 应抛错", false)
        } catch {
            reporter.check("发送超时 → isTimeout", (error as? ChromeEventError)?.isTimeout == true)
            reporter.equal("阶段 = reload", stage(error), .reload)
        }

        // 8. loading / 列表回复解析与事件计数。
        let boolReply = NSAppleEventDescriptor.appleEvent(withEventClass: C.coreSuite, eventID: C.getData, targetDescriptor: nil, returnID: -1, transactionID: 0)
        boolReply.setParam(NSAppleEventDescriptor(boolean: true), forKeyword: C.directObject)
        let loadingTransport = ChromeAppleEventTransport(identity: identity, budget: ChromeReadBudget(clock: MockChromeReadClock(), seconds: 10), rawSend: { _, _ in boolReply }, identityCheck: { nil })
        reporter.equal("loading 布尔回复解析", try? loadingTransport.tabLoading(windowID: "1", tabID: "2"), true)
        reporter.equal("事件计数按类别/代码", loadingTransport.eventCounts["core/getd"], 1)
    }

    // MARK: 读取流程契约（mock 传输层）

    static func testChromeReaderFlow(_ reporter: TestReporter) {
        reporter.group("读取流程 · 新鲜值契约：loading → 探针 → 读取，稳定 ID 与操作前复核")
        let happy = runReader { mock in
            mock.readyAfterProbe = ["100": 2, "200": 2]
            mock.loadingUntilSnapshot = ["200": 2]
        }
        let report = happy.report
        let transport = happy.transport
        reporter.equal("读到两个页面", report.pages.count, 2)
        reporter.equal("两个目标都已确认", report.confirmedTargets.count, 2)
        reporter.equal("确认时间 = 注入的墙钟", report.targets.first?.confirmedAt, fixedNow)
        reporter.check("没有致命错误且报告干净", report.fatalError == nil && report.isClean, "\(report.warningLines)")
        reporter.equal("Claude 目标 URL 是真实的 /new?redirect=…#settings/usage", report.targets(of: .claude).first?.page?.url, "https://claude.ai/new?redirect=claude.com&via=static_google_success#settings/usage")
        reporter.equal("快照统计: 窗口 / 标签", [report.stats.windowCount, report.stats.tabCount], [2, 4])
        reporter.equal("嵌在其它主机 query 里的字样不是目标", report.targets.count, 2)
        reporter.equal("非额度页标签没有收到任何事件", transport.log.filter { $0.hasSuffix("/101") || $0.hasSuffix("/102") }.count, 0)

        reporter.equal("reload 用稳定 ID 对象", transport.calls(withPrefix: "reload"), ["reload 10/100", "reload 20/200"])
        let sent = transport.sentEvents
        var verifiedBeforeSend = true
        for (index, entry) in sent.enumerated() {
            let ids = entry.split(separator: " ").last.map(String.init) ?? ""
            if entry.hasPrefix("reload ") || entry.hasPrefix("loading ") || entry.hasPrefix("read ") {
                if index == 0 || sent[index - 1] != "url \(ids)" { verifiedBeforeSend = false }
            } else if entry.hasPrefix("probe ") {
                if index < 2 || sent[index - 1] != "loading \(ids)" || sent[index - 2] != "url \(ids)" { verifiedBeforeSend = false }
            }
        }
        reporter.check("每次 reload / loading / 探测 / 读取前都用同一 ID 对象复核 URL", verifiedBeforeSend, "\(sent)")
        reporter.equal("Claude loading 时不探测（第 1 轮）", transport.calls(withPrefix: "probe 20/200").count, 2)
        reporter.equal("Codex 就绪后不再重复探测", transport.probeCounts["100"], 2)
        reporter.equal("每个目标只读取 1 次", transport.calls(withPrefix: "read").count, 2)
        reporter.equal("退避 0.75 → 1 → 2，然后 settle 2 秒", happy.clock.sleeps, [0.75, 1, 2, 2])
        reporter.equal("轮询 3 轮", report.pollRounds, 3)
        reporter.equal("报告耗时 = 全部等待之和", report.elapsed, 5.75)
        reporter.check("报告与诊断不含页面正文", !report.warningLines.joined().contains("每周使用限额"))
        let happyCards = ChromeCardBuilder.cards(from: outcome(happy))
        reporter.check("成功卡片带 confirmedAt 与进度", happyCards.allSatisfy { $0.confirmedAt == fixedNow && !$0.progress.isEmpty })
        reporter.check("成功卡片写明读取确认", happyCards[0].details.contains { $0.hasPrefix("读取确认:") && $0.contains("reload 成功") })

        reporter.group("读取流程 · reload 失败但 DOM 仍有数值 → 不读取、不成功")
        let reloadFailed = runReader { mock in
            mock.reloadErrors = ["100": ChromeEventError.fromOSStatus(-1708, stage: .reload, chromeMessage: nil)]
        }
        reporter.equal("reload 失败的目标没有 loading / 探测 / 读取", reloadFailed.transport.sentEvents.filter { $0.hasSuffix("/100") && !$0.hasPrefix("url") && !$0.hasPrefix("reload") }.count, 0)
        reporter.check("reload 失败的目标没有页面、未确认", reloadFailed.report.targets(of: .codex).first?.page == nil && reloadFailed.report.confirmedTargets.count == 1)
        reporter.equal("另一目标正常确认", reloadFailed.report.targets(of: .claude).first?.isConfirmed, true)
        let reloadFailedCards = ChromeCardBuilder.cards(from: outcome(reloadFailed))
        reporter.equal("reload 失败卡片标题", reloadFailedCards[0].headline, "reload 失败，本次不采用")
        reporter.check("reload 失败卡片无进度、无百分比、无 confirmedAt", reloadFailedCards[0].progress.isEmpty && reloadFailedCards[0].statusBarHint == nil && reloadFailedCards[0].confirmedAt == nil)
        reporter.check("reload 失败卡片含错误代码", reloadFailedCards[0].details.contains { $0.contains("-1708") })

        reporter.group("读取流程 · 永不就绪 / 仍在加载 → 超时后不读取、不成功")
        let neverReady = runReader(options: standardOptions(timeout: 10, settle: 1)) { mock in
            mock.readyAfterProbe = ["100": 99, "200": 99]
        }
        reporter.check("到达全局上限", neverReady.report.deadlineReached)
        // 上限 10 秒从 reload 后 0.75 秒起算：1 → 2 → 4 封顶，最后一次退避被截到上限（3 秒），超时后不 settle。
        reporter.equal("退避序列 0.75 → 1 → 2 → 4 → 截到上限 3，超时后不 settle", neverReady.clock.sleeps, [0.75, 1, 2, 4, 3])
        reporter.equal("等待总时长恰好等于上限（不越过）", neverReady.clock.sleeps.dropFirst().reduce(0, +), 10)
        reporter.check("超时目标被标记", neverReady.report.targets.allSatisfy(\.readyTimedOut))
        reporter.equal("超时后没有任何读取事件", neverReady.transport.calls(withPrefix: "read").count, 0)
        reporter.equal("超时后没有页面", neverReady.report.pages.count, 0)
        let neverReadyCards = ChromeCardBuilder.cards(from: outcome(neverReady, options: standardOptions(timeout: 10, settle: 1)))
        reporter.equal("超时卡片标题", neverReadyCards[1].headline, "页面未就绪（10 秒内未出现已支持的额度字段）")
        reporter.check("超时卡片无进度、无 confirmedAt", neverReadyCards.allSatisfy { $0.progress.isEmpty && $0.confirmedAt == nil && $0.statusBarHint == nil })
        let stillLoading = runReader(options: standardOptions(timeout: 5, settle: 1)) { mock in
            mock.loadingUntilSnapshot = ["100": 99, "200": 99]
        }
        reporter.equal("一直 loading 的页面从不探测", stillLoading.transport.calls(withPrefix: "probe").count, 0)
        reporter.equal("一直 loading 的页面不读取", stillLoading.transport.calls(withPrefix: "read").count, 0)
        // 上限 5 秒：0.75 起 3 轮（1 → 2 → 截到 2）后恰好到上限，第 4 轮进入前就判超时，不再发事件。
        reporter.equal("loading 轮数进入诊断（上限前 3 轮）", stillLoading.report.targets.first?.stillLoadingRounds, 3)
        reporter.check("到上限后不再有第 4 轮事件", stillLoading.report.pollRounds == 3 && stillLoading.report.deadlineReached)

        reporter.group("读取流程 · 标签移动 / 关闭 / 改网址 / 寻址失败")
        let moved = runReader { mock in
            mock.afterSnapshot = { mock, index in
                guard index == 1 else { return }
                let codexTab = mock.windows[0].tabs.removeFirst()
                mock.windows.append((id: "30", tabs: [codexTab]))
            }
        }
        reporter.equal("移动前 reload 发给当时所在窗口", moved.transport.calls(withPrefix: "reload"), ["reload 10/100", "reload 20/200"])
        reporter.equal("窗口重排后按 tab id 定位到新窗口再读取", moved.transport.calls(withPrefix: "read 30/100"), ["read 30/100"])
        reporter.equal("旧窗口不再收到该标签的探测 / 读取", moved.transport.sentEvents.filter { $0.hasPrefix("probe 10/100") || $0.hasPrefix("read 10/100") }.count, 0)
        reporter.equal("移动的标签仍被确认", moved.report.targets(of: .codex).first?.isConfirmed, true)

        let closed = runReader { mock in
            mock.afterSnapshot = { mock, index in
                guard index == 1 else { return }
                mock.windows[1].tabs.removeAll()
            }
        }
        reporter.equal("关闭后的标签不再 loading / 探测 / 读取", closed.transport.sentEvents.filter { $0.hasSuffix("/200") && !$0.hasPrefix("url") && !$0.hasPrefix("reload") }.count, 0)
        reporter.equal("其它目标照常确认", closed.report.confirmedTargets.count, 1)
        reporter.check("关闭原因进入警告行", closed.report.warningLines.contains { $0.contains("Claude 网页额度") && $0.contains("跳过") })
        reporter.equal("关闭标签的卡片标题", ChromeCardBuilder.cards(from: outcome(closed))[1].headline, "标签已关闭或已不是额度页")

        let changed = runReader { mock in
            mock.afterSnapshot = { mock, index in
                guard index == 1 else { return }
                mock.windows[1].tabs[0].url = "https://claude.ai/new"
            }
        }
        reporter.equal("网址已不是额度页的标签不再探测 / 读取", changed.transport.sentEvents.filter { $0.hasSuffix("/200") && ($0.hasPrefix("probe") || $0.hasPrefix("loading") || $0.hasPrefix("read")) }.count, 0)
        reporter.check("原因是已不是额度页", changed.report.targets(of: .claude).first?.skippedReason?.contains("额度页") == true)

        let addressing = runReader { mock in
            mock.urlErrors = ["100"]
        }
        reporter.check("寻址失败计数", (addressing.report.targets(of: .codex).first?.resolveFailures ?? 0) > 0)
        reporter.equal("寻址失败的标签不会被 reload / 读取", addressing.transport.sentEvents.filter { $0.hasSuffix("/100") && !$0.hasPrefix("url") }.count, 0)
        reporter.equal("另一目标不受影响", addressing.report.confirmedTargets.count, 1)
        let addressingCards = ChromeCardBuilder.cards(from: outcome(addressing))
        reporter.equal("寻址失败卡片标题", addressingCards[0].headline, "reload 未发送，本次不采用")
        reporter.check("寻址失败卡片含原因", addressingCards[0].details.contains { $0.contains("寻址失败") })

        // 0.2.15 地址适配：标准 mock 的 tab 100 已经是新地址（standardWindows 用 codexUsageURL 常量），
        // 这里显式钉住新地址的 reload / 读取成功、旧地址的兼容回归，以及「操作前标签跳到无关页面」
        // 在 resolve 的第二道复核（稳定 ID 重新读 URL）上被拒绝：只有那一条 url 复核事件，没有 reload / 探测 / 读取。
        reporter.group("读取流程 · Codex 新地址 / 旧地址兼容 / 操作前跳走后拒绝事件（0.2.15）")
        let newAddress = runReader()
        let newCodex = newAddress.report.targets(of: .codex).first
        reporter.equal("新地址被识别为 codex 目标", newCodex?.url, BrowserUsageTargets.codexUsageURL)
        reporter.equal("新地址 reload 发给稳定 ID 对象", newAddress.transport.calls(withPrefix: "reload 10/100"), ["reload 10/100"])
        reporter.equal("新地址读取 1 次", newAddress.transport.calls(withPrefix: "read 10/100"), ["read 10/100"])
        reporter.equal("新地址目标是本轮新鲜值", newCodex?.isConfirmed, true)
        reporter.equal("新地址页面 URL 原样保留", newCodex?.page?.url, BrowserUsageTargets.codexUsageURL)
        let newAddressMetrics = BrowserUsageParser.parseCodex(lines: newCodex?.page?.lines ?? [])
        reporter.equal("新地址只解析出每周使用限额 1 项", newAddressMetrics.count, 1)
        reporter.equal("新地址每周额度剩余", newAddressMetrics.first?.remainingPercent, 68)

        let legacyAddress = runReader { mock in
            mock.windows[0].tabs[0].url = BrowserUsageTargets.codexLegacyUsageURL
        }
        reporter.equal("旧地址仍被识别为 codex 目标", legacyAddress.report.targets(of: .codex).first?.url, BrowserUsageTargets.codexLegacyUsageURL)
        reporter.equal("旧地址 reload / 读取各 1 次", [legacyAddress.transport.calls(withPrefix: "reload 10/100").count, legacyAddress.transport.calls(withPrefix: "read 10/100").count], [1, 1])
        reporter.equal("旧地址两个目标都确认（无回归）", legacyAddress.report.confirmedTargets.count, 2)

        let nonOverview = runReader { mock in
            mock.windows[0].tabs[0].url = "https://chatgpt.com/settings/usage?tab=billing"
        }
        reporter.equal("非 overview 的 tab 不是额度页目标", nonOverview.report.targets(of: .codex).count, 0)
        reporter.equal("非 overview 的 tab 一条事件都不收（不刷新非 overview 页面）", nonOverview.transport.sentEvents.filter { $0.hasSuffix("/100") }.count, 0)
        reporter.equal("Claude 目标不受影响", nonOverview.report.confirmedTargets.count, 1)

        let navigatedAway = runReader { mock in
            mock.liveURLOverrides = ["100": "https://chatgpt.com/settings/usage?tab=billing"]
        }
        reporter.equal("操作前跳到非 overview 子页：只有 URL 复核事件", navigatedAway.transport.sentEvents.filter { $0.hasSuffix("/100") }, ["url 10/100"])
        reporter.check("跳走的目标没有页面、未确认", navigatedAway.report.targets(of: .codex).first?.page == nil && navigatedAway.report.confirmedTargets.count == 1)
        reporter.check("原因写明复核时已不是额度页", navigatedAway.report.warningLines.contains { $0.contains("Codex 网页额度") && $0.contains("复核时标签已不是额度页") }, "\(navigatedAway.report.warningLines)")

        let navigatedAwayUnrelated = runReader { mock in
            mock.liveURLOverrides = ["100": "https://example.com/private-page"]
        }
        reporter.equal("操作前跳到完全无关页面：同样只有 URL 复核事件", navigatedAwayUnrelated.transport.sentEvents.filter { $0.hasSuffix("/100") }, ["url 10/100"])
        reporter.equal("跳走后另一目标照常确认", navigatedAwayUnrelated.report.confirmedTargets.count, 1)
        reporter.check("跳走的原因不含其它网页正文或网址", !navigatedAwayUnrelated.report.warningLines.joined().contains("example.com"))

        // 0.2.15 R2：新 URL + 新页面真实文本的全链路——reload → 就绪 → 读取 → 卡片。
        let screenshot = runReader { mock in
            mock.pageText["100"] = mockCodexScreenshotText
        }
        let screenshotCodex = screenshot.report.targets(of: .codex).first
        reporter.equal("新页面全链路：目标 URL 是新地址", screenshotCodex?.url, BrowserUsageTargets.codexUsageURL)
        reporter.equal("新页面全链路：reload / 读取各 1 次", [screenshot.transport.calls(withPrefix: "reload 10/100").count, screenshot.transport.calls(withPrefix: "read 10/100").count], [1, 1])
        reporter.equal("新页面全链路：已确认新鲜值", screenshotCodex?.isConfirmed, true)
        let screenshotCard = ChromeCardBuilder.cards(from: outcome(screenshot))[0]
        reporter.equal("新页面卡片标题", screenshotCard.headline, "最低 83% 剩余")
        reporter.equal("新页面状态栏提示", screenshotCard.statusBarHint, "83%")
        reporter.equal("新页面进度条标签", screenshotCard.progress.first?.label, "每周使用限额")
        reporter.equal("新页面进度条百分比", screenshotCard.progress.first?.percent, 83)
        reporter.equal("新页面进度条副标题 = 重置倒计时", screenshotCard.progress.first?.detail, "5 天 17 小时后重置")
        reporter.equal("新页面卡片 confirmedAt", screenshotCard.confirmedAt, fixedNow)
        reporter.equal("新页面只产出一条额度指标", screenshotCard.progress.count, 1)
        reporter.check("新页面卡片不含充值余额 / 重置历史", !screenshotCard.details.joined().contains("62,500") && !screenshotCard.details.joined().contains("历史记录") && !screenshotCard.details.joined().contains("GMT"), "\(screenshotCard.details)")

        // 0.2.17：「6天15小时 后重置」这份截图的全链路——reload → 就绪探针 → 读取 → 卡片 → 状态栏 91%。
        // 这是本轮的验收点：0.2.16 在这一份上探针返回 0（就绪超时），即便读到正文也只会出「未解析到额度」。
        let spacing = runReader { mock in
            mock.pageText["100"] = mockCodexSpacingScreenshotText
        }
        let spacingCodex = spacing.report.targets(of: .codex).first
        reporter.equal("空白截图全链路：reload / 读取各 1 次", [spacing.transport.calls(withPrefix: "reload 10/100").count, spacing.transport.calls(withPrefix: "read 10/100").count], [1, 1])
        reporter.equal("空白截图全链路：已确认新鲜值", spacingCodex?.isConfirmed, true)
        reporter.equal("空白截图就绪探针（JavaScriptCore 真实执行同一条正则）", evaluateProbe(.codex, readyState: "complete", text: mockCodexSpacingScreenshotText), "1")
        let spacingCards = ChromeCardBuilder.cards(from: outcome(spacing))
        let spacingCard = spacingCards[0]
        reporter.equal("空白截图卡片标题", spacingCard.headline, "最低 91% 剩余")
        reporter.equal("空白截图进度条", [spacingCard.progress.first?.label, spacingCard.progress.first.map { "\($0.percent)" }], ["每周使用限额", "91.0"])
        reporter.equal("空白截图进度条副标题 = 单行倒计时", spacingCard.progress.first?.detail, "6天15小时 后重置")
        reporter.equal("空白截图只产出一条额度指标", spacingCard.progress.count, 1)
        reporter.equal("空白截图状态栏 = 91%", Snapshot(updatedAt: fixedNow, cards: spacingCards).codexHint(metric: .weekly), "91%")
        reporter.check("空白截图卡片不含充值余额 58,612", !spacingCard.details.joined().contains("58,612"), "\(spacingCard.details)")
        reporter.check("空白截图卡片副标题是单行", !(spacingCard.progress.first?.detail ?? "").contains("\n"))

        // 0.2.16：Claude 新中文页真实文本的全链路——reload → 就绪 → 读取 → 卡片 → 状态栏。
        // 验收点就是截图样本：当前会话 0% used、本周(All models) 68% used，状态栏选 allModels 时
        // 显示剩余 32%（不是把 Fable 的 3% 当周额度得到的 97%，也不是只看当前会话得到的 100%）。
        let claudePage = runReader { mock in
            mock.pageText["200"] = mockClaudeScreenshotText
        }
        let claudeTarget = claudePage.report.targets(of: .claude).first
        reporter.equal("Claude 新页全链路：目标 URL 仍是 Claude 额度页", ChromeTargetKind.kind(for: claudeTarget?.url), ChromeTargetKind.claude)
        reporter.equal("Claude 新页全链路：reload / 读取各 1 次", [claudePage.transport.calls(withPrefix: "reload 20/200").count, claudePage.transport.calls(withPrefix: "read 20/200").count], [1, 1])
        reporter.equal("Claude 新页全链路：已确认新鲜值", claudeTarget?.isConfirmed, true)
        reporter.equal("Claude 新页就绪探针（JavaScriptCore 真实执行同一条正则）", evaluateProbe(.claude, readyState: "complete", text: mockClaudeScreenshotText), "1")
        let claudeCards = ChromeCardBuilder.cards(from: outcome(claudePage))
        let claudeCard = claudeCards[1]
        reporter.equal("Claude 新页卡片提供方", claudeCard.provider, "Claude 网页额度")
        reporter.equal("Claude 新页卡片标题", claudeCard.headline, "最高 68% used")
        reporter.equal("Claude 新页卡片 confirmedAt", claudeCard.confirmedAt, fixedNow)
        reporter.check("Claude 新页卡片写明读取确认", claudeCard.details.contains { $0.hasPrefix("读取确认:") && $0.contains("reload 成功") && $0.contains("已解析") })
        reporter.equal("Claude 新页进度条只有两个已存在的栏目", claudeCard.progress.map(\.label), ["Current session", "All models"])
        reporter.equal("Claude 新页 All models 剩余 = 32", claudeCard.progress.first { $0.label == "All models" }?.percent, 32)
        reporter.equal("Claude 新页 All models 副标题含 used 与重置", claudeCard.progress.first { $0.label == "All models" }?.detail, "68% used · 星期一05:00 重置")
        reporter.equal("Claude 新页状态栏提示 = 最低剩余 32%", claudeCard.statusBarHint, "32%")
        let claudeSnapshot = Snapshot(updatedAt: fixedNow, cards: claudeCards)
        reporter.equal("状态栏选 allModels = 32%", claudeSnapshot.claudeHint(metric: .allModels), "32%")
        reporter.equal("状态栏选 currentSession = 100%", claudeSnapshot.claudeHint(metric: .currentSession), "100%")
        reporter.check("状态栏不会出现 97%（Fable 的 3% 没被当成周额度）", claudeSnapshot.claudeHint(metric: .allModels) != "97%")
        reporter.check("Claude 新页卡片不含 Fable / 美元额度 / 重置历史",
                       !claudeCard.details.joined().contains("Fable") && !claudeCard.details.joined().contains("US$") && !claudeCard.details.joined().contains("GMT"),
                       "\(claudeCard.details)")

        // 0.2.18：Claude 新布局（2026-10-26 展开截图）的全链路——reload → 就绪 → 读取 → 卡片 → 状态栏。
        // 验收点就是截图样本：当前会话 8% used（剩余 92）、总周额度 2% used（剩余 98）；
        // 同一页上还有 Fable 的 0% 与按产品占比的 Claude Code 100%，两者都不得出现在任何指标里。
        let claudeLayout = runReader { mock in
            mock.pageText["200"] = mockClaudeExpandedScreenshotText
        }
        reporter.equal("新布局全链路：已确认新鲜值", claudeLayout.report.targets(of: .claude).first?.isConfirmed, true)
        reporter.equal("新布局就绪探针（JavaScriptCore 真实执行同一条正则）",
                       evaluateProbe(.claude, readyState: "complete", text: mockClaudeExpandedScreenshotText), "1")
        let layoutCards = ChromeCardBuilder.cards(from: outcome(claudeLayout))
        let layoutCard = layoutCards[1]
        reporter.equal("新布局进度条只有两个已存在的栏目", layoutCard.progress.map(\.label), ["Current session", "All models"])
        reporter.equal("新布局 Current session 剩余 = 92", layoutCard.progress.first { $0.label == "Current session" }?.percent, 92)
        reporter.equal("新布局 All models 剩余 = 98", layoutCard.progress.first { $0.label == "All models" }?.percent, 98)
        reporter.equal("新布局 Current session 副标题 = used + 复合倒计时",
                       layoutCard.progress.first { $0.label == "Current session" }?.detail, "8% used · 1小时 37 分钟后重置")
        reporter.equal("新布局 All models 副标题 = used + 周一重置",
                       layoutCard.progress.first { $0.label == "All models" }?.detail, "2% used · 周一05:00 重置")
        reporter.equal("新布局卡片标题 = 最高 8% used", layoutCard.headline, "最高 8% used")
        reporter.equal("新布局卡片 confirmedAt", layoutCard.confirmedAt, fixedNow)
        let layoutSnapshot = Snapshot(updatedAt: fixedNow, cards: layoutCards)
        reporter.equal("新布局状态栏选 allModels = 98%", layoutSnapshot.claudeHint(metric: .allModels), "98%")
        reporter.equal("新布局状态栏选 currentSession = 92%", layoutSnapshot.claudeHint(metric: .currentSession), "92%")
        reporter.equal("新布局状态栏选 claudeDesign（整栏不存在）= nil", layoutSnapshot.claudeHint(metric: .claudeDesign), nil)
        reporter.check("新布局卡片不含 Fable / Claude Code / 按产品占比",
                       !layoutCard.details.joined().contains("Fable")
                        && !layoutCard.details.joined().contains("Claude Code")
                        && !layoutCard.details.joined().contains("按产品"),
                       "\(layoutCard.details)")

        // 0.2.18 错指标防回退的全链路锚点：总周额度缺值、当前会话有值时，卡片的 statusBarHint
        // 仍然是「所有指标里最低的剩余」= 92%，但状态栏选 All models 必须显示 `--`，不能借这个 92%。
        let weekMissingRun = runReader { mock in
            mock.pageText["200"] = mockClaudeWeekMissingText
        }
        let weekMissingCards = ChromeCardBuilder.cards(from: outcome(weekMissingRun))
        let weekMissingCard = weekMissingCards[1]
        reporter.equal("总周额度缺值时进度条只有当前会话", weekMissingCard.progress.map(\.label), ["Current session"])
        reporter.equal("总周额度缺值时卡片 statusBarHint 仍是最低剩余 92%", weekMissingCard.statusBarHint, "92%")
        let weekMissingSnapshot = Snapshot(updatedAt: fixedNow, cards: weekMissingCards)
        reporter.equal("选 allModels 且该指标无值 → nil（UI 显示 --）", weekMissingSnapshot.claudeHint(metric: .allModels), nil)
        reporter.equal("选 currentSession 仍正确 = 92%", weekMissingSnapshot.claudeHint(metric: .currentSession), "92%")
        reporter.equal("双行标题里 Claude 侧显示 --",
                       weekMissingSnapshot.statusTitle(mode: .split, codexMetric: .weekly, claudeMetric: .allModels), "A -- · C 68%")
        reporter.equal("双行标题里选 currentSession 正常显示",
                       weekMissingSnapshot.statusTitle(mode: .split, codexMetric: .weekly, claudeMetric: .currentSession), "A 92% · C 68%")

        // 正式整改 1/3：Root 真实页面实测结构（标题后一行 U+E02A）的全链路 + 真实卡片构建。
        // 这就是本轮的验收点——初稿在这一份上总周额度只有标题、没有进度条、状态栏 allModels 显示 --。
        let iconRun = runReader { mock in
            mock.pageText["200"] = mockClaudeIconMarkerText
        }
        reporter.equal("实测图标结构全链路：已确认新鲜值", iconRun.report.targets(of: .claude).first?.isConfirmed, true)
        reporter.equal("实测图标结构就绪探针（JavaScriptCore 真实执行同一条正则）",
                       evaluateProbe(.claude, readyState: "complete", text: mockClaudeIconMarkerText), "1")
        let iconCards = ChromeCardBuilder.cards(from: outcome(iconRun))
        let iconCard = iconCards[1]
        reporter.equal("实测图标结构进度条两栏都在", iconCard.progress.map(\.label), ["Current session", "All models"])
        reporter.equal("实测图标结构 All models 剩余 = 98", iconCard.progress.first { $0.label == "All models" }?.percent, 98)
        reporter.equal("实测图标结构 All models 副标题 = used + 周一重置",
                       iconCard.progress.first { $0.label == "All models" }?.detail, "2% used · 周一05:00 重置")
        reporter.equal("实测图标结构 Current session 剩余 = 92", iconCard.progress.first { $0.label == "Current session" }?.percent, 92)
        reporter.equal("实测图标结构卡片标题 = 最高 8% used", iconCard.headline, "最高 8% used")
        reporter.equal("实测图标结构卡片 confirmedAt", iconCard.confirmedAt, fixedNow)
        reporter.check("卡片详情里不出现页面上那个图标字符",
                       !iconCard.details.joined().contains("\u{e02a}"), "\(iconCard.details)")
        let iconSnapshot = Snapshot(updatedAt: fixedNow, cards: iconCards)
        reporter.equal("实测图标结构状态栏选 allModels = 98%", iconSnapshot.claudeHint(metric: .allModels), "98%")
        reporter.equal("实测图标结构状态栏选 currentSession = 92%", iconSnapshot.claudeHint(metric: .currentSession), "92%")
        reporter.equal("实测图标结构双行标题两侧都有数",
                       iconSnapshot.statusTitle(mode: .split, codexMetric: .weekly, claudeMetric: .allModels), "A 98% · C 68%")

        // 同一个实测图标、但总周额度没有数值：仍然只有当前会话有值，选 allModels 仍是 --（不借 92%）。
        let iconWeekMissingRun = runReader { mock in
            mock.pageText["200"] = mockClaudeIconMarkerWeekMissingText
        }
        let iconWeekMissingCards = ChromeCardBuilder.cards(from: outcome(iconWeekMissingRun))
        reporter.equal("实测图标 + 无数值时进度条只有当前会话", iconWeekMissingCards[1].progress.map(\.label), ["Current session"])
        reporter.equal("实测图标 + 无数值时选 allModels → nil",
                       Snapshot(updatedAt: fixedNow, cards: iconWeekMissingCards).claudeHint(metric: .allModels), nil)
        reporter.equal("实测图标 + 无数值时双行标题 Claude 侧 --",
                       Snapshot(updatedAt: fixedNow, cards: iconWeekMissingCards)
                        .statusTitle(mode: .split, codexMetric: .weekly, claudeMetric: .allModels), "A -- · C 68%")

        reporter.group("读取流程 · 枚举失败 / 权限拒绝 / 单窗口失败")
        let denied = runReader { mock in
            mock.windowsError = ChromeEventError.fromOSStatus(-1743, stage: .enumerateWindows, chromeMessage: nil)
        }
        reporter.equal("致命错误阶段 = 枚举窗口", denied.report.fatalError?.stage, .enumerateWindows)
        reporter.check("识别为权限拒绝", denied.report.fatalError?.isPermissionDenied == true)
        reporter.equal("权限拒绝后不再发送其它事件", denied.transport.sentEvents, ["windows"])
        let deniedCards = ChromeCardBuilder.cards(from: outcome(denied))
        reporter.equal("两张卡片都说明权限被拒绝", deniedCards.map(\.headline), ["自动化权限被拒绝", "自动化权限被拒绝"])
        reporter.check("卡片给出系统设置路径", deniedCards[0].details.contains(ChromeCardBuilder.permissionHint))

        let partialWindow = runReader { mock in
            mock.tabsErrors = ["10": ChromeEventError.fromOSStatus(-1728, stage: .enumerateTabs, chromeMessage: nil)]
        }
        reporter.check("单窗口枚举失败被记录（非致命）", !partialWindow.report.stats.windowErrors.isEmpty && partialWindow.report.fatalError == nil)
        reporter.equal("其它窗口仍被确认", partialWindow.report.confirmedTargets.count, 1)
        let partialWindowCards = ChromeCardBuilder.cards(from: outcome(partialWindow))
        reporter.equal("无页面一侧仍是「未找到页面」", partialWindowCards[0].headline, "未找到已打开页面")
        reporter.check("无页面一侧保留读取诊断", partialWindowCards[0].details.contains { $0.contains("窗口枚举失败") })

        reporter.group("读取流程 · JS 关闭 / 部分成功 / 无匹配页 / 不 reload")
        let javascriptOff = ChromeEventError.fromOSStatus(-10000, stage: .probe, chromeMessage: "Executing JavaScript through AppleScript is turned off.")
        let jsDisabled = runReader(options: standardOptions(timeout: 5, settle: 0)) { mock in
            mock.probeErrors = ["100": javascriptOff, "200": javascriptOff]
        }
        reporter.equal("JS 关闭时没有页面", jsDisabled.report.pages.count, 0)
        reporter.equal("JS 关闭时不读取", jsDisabled.transport.calls(withPrefix: "read").count, 0)
        reporter.check("JS 错误不被吞掉", jsDisabled.report.warningLines.contains { $0.contains("turned off") })
        let jsCards = ChromeCardBuilder.cards(from: outcome(jsDisabled))
        reporter.equal("JS 关闭卡片提示开启精确读取", jsCards.map(\.headline), ["需要开启 Chrome 精确读取", "需要开启 Chrome 精确读取"])
        reporter.check("JS 关闭卡片含 Chrome 菜单路径", jsCards[1].details.contains(ChromeCardBuilder.javascriptHint))

        let partial = runReader { mock in
            mock.readErrors = ["200": ChromeEventError.fromOSStatus(-10000, stage: .read, chromeMessage: "Executing JavaScript through AppleScript is turned off.")]
        }
        reporter.equal("部分成功: 只有 1 个已确认", partial.report.confirmedTargets.count, 1)
        reporter.check("失败方诊断保留", partial.report.targets(of: .claude).first?.readError != nil)
        let partialCards = ChromeCardBuilder.cards(from: outcome(partial))
        reporter.check("成功方正常显示进度并已确认", !partialCards[0].progress.isEmpty && partialCards[0].confirmedAt != nil)
        reporter.equal("失败方卡片不是「未找到页面」", partialCards[1].headline, "需要开启 Chrome 精确读取")
        reporter.check("失败方卡片含错误原文且无 confirmedAt", partialCards[1].details.contains { $0.contains("turned off") } && partialCards[1].confirmedAt == nil)

        let noTargets = runReader { mock in
            mock.windows = [(id: "10", tabs: [MockChromeTransport.Tab(tabID: "101", url: "https://example.com")])]
        }
        reporter.equal("无匹配页: 目标为空", noTargets.report.targets.count, 0)
        reporter.equal("无匹配页: 只有枚举事件", noTargets.transport.sentEvents, ["windows", "tabs 10"])
        reporter.equal("无匹配页: 不等待", noTargets.clock.sleeps, [])
        reporter.equal("无匹配页卡片", ChromeCardBuilder.cards(from: outcome(noTargets)).map(\.headline), ["未找到已打开页面", "未找到已打开页面"])

        let noReload = runReader(options: standardOptions(reload: false))
        reporter.equal("关闭 reload 时没有 reload", noReload.transport.calls(withPrefix: "reload").count, 0)
        reporter.equal("关闭 reload 时仍做 loading + 探针再读取", [noReload.transport.calls(withPrefix: "loading").count, noReload.transport.calls(withPrefix: "probe").count, noReload.transport.calls(withPrefix: "read").count], [2, 2, 2])
        reporter.equal("关闭 reload 时不等待", noReload.clock.sleeps, [])
        reporter.check("关闭 reload 时仍需就绪才算确认", noReload.report.confirmedTargets.count == 2)
        let noReloadNotReady = runReader(options: standardOptions(reload: false, timeout: 5)) { mock in
            mock.readyAfterProbe = ["100": 99, "200": 99]
        }
        reporter.equal("关闭 reload 且未就绪时不读取", noReloadNotReady.transport.calls(withPrefix: "read").count, 0)

        reporter.group("读取流程 · 身份失效必须终止整轮（外圈 + 传输边界，各阶段零后续事件）")
        let outerLost = runReader { mock in
            mock.identityFailureAfterCalls = 2
        }
        reporter.equal("外圈核验失效 = 致命(身份)", outerLost.report.fatalError?.stage, .identity)
        reporter.equal("外圈核验失效后没有读取", outerLost.transport.calls(withPrefix: "read").count, 0)
        let happySent = happy.transport.sentEvents
        for prefix in ["tabs", "reload", "loading", "probe", "read"] {
            guard let firstIndex = happySent.firstIndex(where: { $0.hasPrefix(prefix) }) else {
                reporter.check("阶段 \(prefix) 存在", false)
                continue
            }
            let eventNumber = firstIndex + 1
            let preLost = runReader { mock in
                mock.readyAfterProbe = ["100": 2, "200": 2]
                mock.loadingUntilSnapshot = ["200": 2]
                mock.boundaryIdentityFailAtEvent = eventNumber
            }
            reporter.equal("\(prefix) 阶段发送前身份失效: 致命(身份)", preLost.report.fatalError?.stage, .identity)
            reporter.equal("\(prefix) 阶段发送前身份失效: 之后零事件", preLost.transport.sentEvents.count, eventNumber - 1)
            reporter.equal("\(prefix) 阶段发送前身份失效: 无页面", preLost.report.pages.count, 0)
            let postLost = runReader { mock in
                mock.readyAfterProbe = ["100": 2, "200": 2]
                mock.loadingUntilSnapshot = ["200": 2]
                mock.boundaryIdentityFailAfterReplyOfEvent = eventNumber
            }
            reporter.equal("\(prefix) 阶段回复后身份失效: 致命(身份)", postLost.report.fatalError?.stage, .identity)
            reporter.equal("\(prefix) 阶段回复后身份失效: 该事件后零事件", postLost.transport.sentEvents.count, eventNumber)
            reporter.check("\(prefix) 阶段回复后身份失效: 回复被丢弃", postLost.transport.log.contains { $0.hasPrefix("discarded \(prefix)") })
            reporter.equal("\(prefix) 阶段回复后身份失效: 无已确认页面", postLost.report.confirmedTargets.count, 0)
        }
        let lostCards = ChromeCardBuilder.cards(from: outcome(outerLost))
        reporter.equal("身份失效卡片", lostCards[0].headline, "Chrome 进程已退出或身份变化")
        reporter.check("身份失效卡片无进度", lostCards.allSatisfy { $0.progress.isEmpty && $0.confirmedAt == nil })

        let cancelled = runReader(cancelBeforeStart: true)
        reporter.equal("开始前已取消 = 致命(看门狗)", cancelled.report.fatalError?.stage, .watchdog)
        reporter.equal("取消后不发送任何事件", cancelled.transport.sentEvents.count, 0)

        reporter.group("读取流程 · 就绪上限只算一次，不被标签 / 错误重置")
        let notReset = runReader(options: standardOptions(timeout: 10, settle: 0)) { mock in
            mock.probeErrors = ["100": ChromeEventError.fromOSStatus(-1728, stage: .probe, chromeMessage: nil)]
            mock.readyAfterProbe = ["200": 99]
            mock.urlErrors = []
        }
        reporter.equal("探测错误不延长等待：退避 0.75 → 1 → 2 → 4 → 截到上限 3", notReset.clock.sleeps, [0.75, 1, 2, 4, 3])
        // 最后一次退避恰好睡到上限，下一轮进入前剩余 0 < 最小粒度，直接判超时，不再发第 5 轮任何事件。
        reporter.equal("轮询 4 轮后到上限（上限处不再发任何就绪事件）", notReset.report.pollRounds, 4)
        reporter.check("两目标都超时且无读取", notReset.report.targets.allSatisfy(\.readyTimedOut) && notReset.transport.calls(withPrefix: "read").isEmpty)
    }

    // MARK: 预算 / 看门狗

    static func testChromeReadBudget(_ reporter: TestReporter) {
        reporter.group("读取预算 · 单调 deadline、事件等待上限、睡眠不超预算")
        let clock = MockChromeReadClock()
        let budget = ChromeReadBudget(clock: clock, seconds: 10)
        reporter.equal("剩余预算", budget.remaining(), 10)
        reporter.equal("事件等待 = min(默认, 剩余)", budget.eventWait(default: 15), ChromeReadBudget.EventWait(timeout: 10, limitedByStage: false))
        reporter.check("checkpoint 通过", (try? budget.checkpoint("x")) != nil)
        try? budget.sleep(upTo: 30, reason: "test")
        reporter.equal("睡眠被截到剩余预算", clock.sleeps, [10])
        reporter.check("预算耗尽后 checkpoint 抛看门狗错误", { if let error = try? { try budget.checkpoint("y") }() { _ = error; return false } else { return true } }())
        do {
            try budget.checkpoint("y")
            reporter.check("耗尽后 checkpoint 应抛错", false)
        } catch {
            reporter.equal("耗尽错误阶段 = 看门狗", (error as? ChromeEventError)?.stage, .watchdog)
        }
        reporter.equal("耗尽后事件等待为 nil（拒绝发送，不扩大到 0.1）", budget.eventWait(default: 15), nil)
        let cancelBudget = ChromeReadBudget(clock: MockChromeReadClock(), seconds: 10)
        cancelBudget.cancel(reason: "测试取消")
        do {
            try cancelBudget.checkpoint("z")
            reporter.check("取消后 checkpoint 应抛错", false)
        } catch {
            reporter.check("取消原因进入错误", (error as? ChromeEventError)?.message.contains("测试取消") == true)
        }

        reporter.group("读取预算 · 页面就绪阶段上限")
        let stageClock = MockChromeReadClock()
        let stageBudget = ChromeReadBudget(clock: stageClock, seconds: 62)
        stageBudget.beginStage(deadline: stageClock.uptime() + 5)
        reporter.equal("阶段内事件等待受页面上限约束", stageBudget.eventWait(default: 15), ChromeReadBudget.EventWait(timeout: 5, limitedByStage: true))
        stageClock.advance(4.95)
        reporter.equal("阶段剩余 0.05 → 拒绝而不是扩大到 0.1", stageBudget.eventWait(default: 15), nil)
        reporter.check("整轮预算仍充足、checkpoint 通过", stageBudget.remaining() > 50 && (try? stageBudget.checkpoint("stage")) != nil)
        let stageError = ChromeAppleEventTransport.insufficientBudgetError(budget: stageBudget, stage: .probe)
        reporter.check("阶段拒绝为非致命的阶段限制错误", stageError.isStageLimit && !stageError.isFatal && stageError.stage == .probe)
        stageClock.advance(0.1)
        reporter.check("阶段已超", stageBudget.stageExceeded)
        stageBudget.endStage()
        reporter.equal("结束阶段后恢复整轮剩余", stageBudget.eventWait(default: 15)?.timeout, 15)
        let tightClock = MockChromeReadClock()
        let tightBudget = ChromeReadBudget(clock: tightClock, seconds: 10)
        tightClock.advance(9.95)
        let tightError = ChromeAppleEventTransport.insufficientBudgetError(budget: tightBudget, stage: .read)
        reporter.check("整轮剩余不足时拒绝为看门狗（致命）", tightError.isFatal && !tightError.isStageLimit)

        reporter.group("预算 · 阻塞枚举返回后（多窗口）零后续事件")
        let blocked = runReader { mock in
            mock.windowsVirtualDelay = 70
        }
        reporter.equal("阻塞的枚举返回后不再枚举任何窗口标签", blocked.transport.sentEvents, ["windows"])
        reporter.equal("致命 = 看门狗 / 预算", blocked.report.fatalError?.stage, .watchdog)
        reporter.equal("没有页面", blocked.report.pages.count, 0)
        // 读取器自己的 checkpoint 已先拒绝；再直接调用传输层，验证传输边界独立于上层也会拒绝。
        do {
            _ = try blocked.transport.tabs(inWindow: "10")
            reporter.check("预算耗尽后传输边界应直接拒绝", false)
        } catch {
            reporter.equal("预算耗尽后传输边界拒绝 = 看门狗", (error as? ChromeEventError)?.stage, .watchdog)
        }
        reporter.check("传输边界的拒绝进入日志", blocked.transport.log.contains { $0.hasPrefix("refused tabs 10") }, "\(blocked.transport.log)")
        reporter.equal("被拒绝的请求不计入已发送事件", blocked.transport.sentEvents, ["windows"])

        reporter.group("预算 · 多目标 reload 途中耗尽")
        let midReload = runReader { mock in
            mock.reloadVirtualDelay = 70
        }
        reporter.equal("只发出了第一个 reload", midReload.transport.calls(withPrefix: "reload").count, 1)
        reporter.equal("之后没有 loading / 探测 / 读取", midReload.transport.sentEvents.filter { $0.hasPrefix("loading") || $0.hasPrefix("probe") || $0.hasPrefix("read") }.count, 0)
        reporter.equal("致命 = 看门狗 / 预算", midReload.report.fatalError?.stage, .watchdog)

        reporter.group("预算 · 超时后不会有第二轮")
        let secondRound = runReader { mock in
            mock.probeVirtualDelay = 70
            mock.readyAfterProbe = ["100": 99, "200": 99]
        }
        reporter.equal("只有初始快照 + 第 1 轮快照", secondRound.transport.calls(withPrefix: "windows").count, 2)
        reporter.equal("只探测了 1 次", secondRound.transport.calls(withPrefix: "probe").count, 1)
        reporter.equal("没有读取", secondRound.transport.calls(withPrefix: "read").count, 0)
        reporter.equal("致命 = 看门狗 / 预算", secondRound.report.fatalError?.stage, .watchdog)

        reporter.group("预算 · 退避睡眠不超过剩余预算")
        let tight = runReader(options: standardOptions(timeout: 30, settle: 2), budgetSeconds: 3) { mock in
            mock.readyAfterProbe = ["100": 99, "200": 99]
        }
        reporter.check("所有睡眠之和不超过预算", tight.clock.sleeps.reduce(0, +) <= 3, "\(tight.clock.sleeps)")
        reporter.equal("预算耗尽 = 看门狗", tight.report.fatalError?.stage, .watchdog)
        reporter.equal("没有读取", tight.transport.calls(withPrefix: "read").count, 0)
    }

    // MARK: 端到端服务

    static func testChromeReadService(_ reporter: TestReporter) {
        reporter.group("端到端 · 不向自动化实例发送事件")
        let normalArguments = chromeArguments([])
        let automationArguments = chromeArguments(["--remote-debugging-pipe", "--user-data-dir=/tmp/playwright_x"])
        let (dependencies, box) = mockDependencies(candidates: [candidate(58926, arguments: automationArguments, launch: nil), candidate(92241, arguments: normalArguments)])
        let outcome = ChromeQuotaReadService.run(options: standardOptions(), dependencies: dependencies)
        reporter.equal("选中普通实例", outcome.decision.selectedIdentity?.pid, 92241)
        reporter.equal("只为选中 PID 创建传输层", Array(box.transports.keys), [92241])
        reporter.equal("自动化实例 PID 58926 收到 0 个事件", box.transports[58926]?.sentEvents.count ?? 0, 0)
        reporter.check("选中实例收到事件", (box.transports[92241]?.sentEvents.count ?? 0) > 0)
        reporter.equal("两个目标都已确认", outcome.report?.confirmedTargets.count, 2)
        let cards = ChromeCardBuilder.cards(from: outcome)
        reporter.equal("卡片 provider 顺序不变", cards.map(\.provider), ["Codex 网页额度", "Claude 网页额度"])
        reporter.equal("Codex 状态栏百分比", cards[0].statusBarHint, "68%")
        reporter.equal("Claude All models 剩余", cards[1].progress.first { $0.label == "All models" }?.percent, 59)
        reporter.check("成功卡片 confirmedAt = 注入墙钟", cards.allSatisfy { $0.confirmedAt == fixedNow })
        let diagnostics = outcome.diagnosticLines.joined(separator: "\n")
        reporter.check("诊断输出含候选 PID 与分类", diagnostics.contains("PID 58926") && diagnostics.contains("自动化") && diagnostics.contains("PID 92241"))
        reporter.check("诊断输出含 kpid 目标与内核启动时间", diagnostics.contains("typeKernelProcessID(kpid) → PID 92241") && diagnostics.contains("内核启动 1800000000.123456"))
        reporter.check("诊断输出含已确认计数", diagnostics.contains("已确认新鲜值 2/2"))
        reporter.check("诊断输出不含页面正文", !diagnostics.contains("每周使用限额") && !diagnostics.contains("Plan usage limits"))
        reporter.check("诊断输出不含非额度页 URL", !diagnostics.contains("example.com/private-page") && !diagnostics.contains("example.test"))

        reporter.group("端到端 · 实例选择失败时不创建传输层、不发事件")
        var factoryCalls = 0
        var (failing, _) = mockDependencies(candidates: [candidate(58926, arguments: automationArguments, launch: nil)])
        failing.makeTransport = { identity, _ in factoryCalls += 1; return standardMockTransport(pid: identity.pid) }
        let failingOutcome = ChromeQuotaReadService.run(options: standardOptions(), dependencies: failing)
        reporter.equal("只有自动化实例: 不创建传输层", factoryCalls, 0)
        let failingCards = ChromeCardBuilder.cards(from: failingOutcome)
        reporter.equal("卡片标题说明仅自动化", failingCards.map(\.headline), ["仅检测到自动化 Chrome", "仅检测到自动化 Chrome"])
        reporter.check("卡片含 PID 与参数", failingCards[0].details.contains { $0.contains("58926") && $0.contains("--remote-debugging-pipe") })
        reporter.check("卡片没有进度、不伪造成功", failingCards.allSatisfy { $0.progress.isEmpty && $0.statusBarHint == nil && $0.confirmedAt == nil })
        var (unverifiable, _) = mockDependencies(candidates: [candidate(100, arguments: normalArguments), candidate(400, arguments: nil)])
        unverifiable.makeTransport = { identity, _ in factoryCalls += 1; return standardMockTransport(pid: identity.pid) }
        reporter.equal("无法确认: 不创建传输层", { _ = ChromeQuotaReadService.run(options: standardOptions(), dependencies: unverifiable); return factoryCalls }(), 0)
        var (noStart, _) = mockDependencies(candidates: [candidate(100, arguments: normalArguments, startTime: nil)])
        noStart.makeTransport = { identity, _ in factoryCalls += 1; return standardMockTransport(pid: identity.pid) }
        reporter.equal("身份不完整: 不创建传输层", { _ = ChromeQuotaReadService.run(options: standardOptions(), dependencies: noStart); return factoryCalls }(), 0)
        let (notRunning, _) = mockDependencies(candidates: [])
        reporter.equal("未运行卡片沿用旧文案", ChromeCardBuilder.cards(from: ChromeQuotaReadService.run(options: standardOptions(), dependencies: notRunning)).map(\.headline), ["Chrome 未运行", "Chrome 未运行"])

        reporter.group("端到端 · 看门狗线程：超时后全部后续请求为零")
        var (threaded, threadedBox) = mockDependencies(candidates: [candidate(92241, arguments: normalArguments)], clock: MockChromeReadClock())
        threaded.useWatchdogThread = true
        threaded.clock = SystemChromeReadClock()
        threaded.makeTransport = { identity, budget in
            let transport = standardMockTransport(pid: identity.pid)
            transport.budget = budget
            transport.pageText = ["100": mockCodexText, "200": mockClaudeText]
            threadedBox.transports[identity.pid] = transport
            return transport
        }
        let quickOutcome = ChromeQuotaReadService.run(options: standardOptions(reload: false), dependencies: threaded)
        reporter.check("正常读取时看门狗不触发", !quickOutcome.watchdogTimedOut && quickOutcome.report?.confirmedTargets.count == 2, "timedOut=\(quickOutcome.watchdogTimedOut)")
        reporter.equal("看门狗上限 = 超时 + settle + 30", standardOptions(timeout: 30, settle: 2).watchdogSeconds, 62)

        var hungDependencies = threaded
        let hungBox = TransportBox()
        hungDependencies.makeTransport = { identity, budget in
            let transport = standardMockTransport(pid: identity.pid)
            transport.budget = budget
            transport.windowsDelay = 1.5
            transport.pageText = ["100": mockCodexText, "200": mockClaudeText]
            hungBox.transports[identity.pid] = transport
            return transport
        }
        hungDependencies.watchdogSecondsOverride = 0.3
        let started = Date()
        let hungOutcome = ChromeQuotaReadService.run(options: standardOptions(reload: false), dependencies: hungDependencies)
        let elapsed = Date().timeIntervalSince(started)
        reporter.check("看门狗在上限后返回（不等阻塞结束）", hungOutcome.watchdogTimedOut && elapsed < 1.4, "elapsed=\(elapsed)")
        reporter.check("看门狗触发时没有报告且 readWarning 说明看门狗", hungOutcome.report == nil && hungOutcome.readWarning?.contains("看门狗") == true)
        let hungCards = ChromeCardBuilder.cards(from: hungOutcome)
        reporter.equal("看门狗卡片标题", hungCards.map(\.headline), ["读取超时（看门狗）", "读取超时（看门狗）"])
        reporter.check("看门狗卡片不伪造成功", hungCards.allSatisfy { $0.progress.isEmpty && $0.statusBarHint == nil && $0.confirmedAt == nil })
        Thread.sleep(forTimeInterval: 2.0)
        let hung = hungBox.transports[92241]
        reporter.equal("被放弃的线程在阻塞返回后没有任何后续请求（tabs/url/loading/reload/probe/read 全为零）", hung?.sentEvents ?? [], ["windows"])
        reporter.check("阻塞返回的回复被丢弃", hung?.log.contains { $0.hasPrefix("discarded windows") } == true, "\(hung?.log ?? [])")
    }

    // MARK: 诊断 CLI

    static func testBrowserDiagnosticsCommand(_ reporter: TestReporter) {
        reporter.group("--browser-diagnostics（mock 传输层）")
        let normalArguments = chromeArguments([])
        let (dependencies, box) = mockDependencies(candidates: [candidate(92241, arguments: normalArguments), candidate(58926, arguments: chromeArguments(["--remote-debugging-pipe"]), launch: nil)])
        var captured = ""
        let enumerateOnly = BrowserDiagnosticsCommand.run(arguments: ["--browser-diagnostics"], dependencies: dependencies) { captured += $0 }
        reporter.equal("仅枚举退出码 0", enumerateOnly, 0)
        let enumerateTransport = box.transports[92241]
        reporter.equal("仅枚举只有窗口 / 标签枚举事件", enumerateTransport?.sentEvents, ["windows", "tabs 10", "tabs 20"])
        reporter.check("输出含候选 PID、分类与 kpid 目标", captured.contains("PID 92241") && captured.contains("PID 58926") && captured.contains("自动化") && captured.contains("kpid) → PID 92241"))
        reporter.check("输出含匹配额度页的 window/tab id 与 URL", captured.contains("window id 10 · tab id 100") && captured.contains(BrowserUsageTargets.codexUsageURL))
        reporter.check("输出不含非额度页 URL", !captured.contains("example.com/private-page") && !captured.contains("example.test"))
        reporter.check("仅枚举输出不含页面正文", !captured.contains("每周使用限额") && !captured.contains("Codex 分析"))
        reporter.check("输出含事件计数与退出码", captured.contains("Apple Events 计数") && captured.contains("退出码: 0"))

        box.transports = [:]
        captured = ""
        let withRead = BrowserDiagnosticsCommand.run(arguments: ["--browser-diagnostics", "--read"], dependencies: dependencies) { captured += $0 }
        let readTransport = box.transports[92241]
        reporter.equal("--read 退出码 0", withRead, 0)
        reporter.equal("--read 不 reload", readTransport?.calls(withPrefix: "reload").count, 0)
        reporter.equal("--read 先 loading + 探针再读取", [readTransport?.calls(withPrefix: "loading").count, readTransport?.calls(withPrefix: "probe").count, readTransport?.calls(withPrefix: "read").count], [2, 2, 2])
        reporter.equal("--read 不触碰非额度页", readTransport?.sentEvents.filter { $0.hasSuffix("/101") || $0.hasSuffix("/102") }.count, 0)
        reporter.check("--read 输出解析后的指标而不是正文", captured.contains("68% 剩余") && !captured.contains("Codex 分析"), captured)

        var (notReady, notReadyBox) = mockDependencies(candidates: [candidate(92241, arguments: normalArguments)]) { mock in
            mock.readyAfterProbe = ["100": 99]
            mock.loadingUntilSnapshot = ["200": 99]
        }
        _ = notReadyBox
        captured = ""
        reporter.equal("--read 有未就绪目标退出码 3", BrowserDiagnosticsCommand.run(arguments: ["--browser-diagnostics", "--read"], dependencies: notReady) { captured += $0 }, 3)
        reporter.check("未就绪目标不读取并说明原因", captured.contains("未就绪") && !captured.contains("68% 剩余") && !captured.contains("41% used"))
        notReady.discover = { [candidate(58926, arguments: chromeArguments(["--remote-debugging-pipe"]), launch: nil)] }
        captured = ""
        reporter.equal("只有自动化实例退出码 1", BrowserDiagnosticsCommand.run(arguments: ["--browser-diagnostics"], dependencies: notReady) { captured += $0 }, 1)
        reporter.check("只有自动化实例时说明原因且计数为 0", captured.contains("--remote-debugging-pipe") && captured.contains("Apple Events 计数: 0"))

        let (denied, _) = mockDependencies(candidates: [candidate(92241, arguments: normalArguments)]) { mock in
            mock.windowsError = ChromeEventError.fromOSStatus(-1743, stage: .enumerateWindows, chromeMessage: nil)
        }
        captured = ""
        reporter.equal("枚举失败退出码 2", BrowserDiagnosticsCommand.run(arguments: ["--browser-diagnostics"], dependencies: denied) { captured += $0 }, 2)
        reporter.check("枚举失败输出含权限原因", captured.contains("枚举失败") && captured.contains("1743"))

        let (readFailing, _) = mockDependencies(candidates: [candidate(92241, arguments: normalArguments)]) { mock in
            mock.readErrors = ["100": ChromeEventError.fromOSStatus(-10000, stage: .read, chromeMessage: "JavaScript off")]
        }
        captured = ""
        reporter.equal("--read 有失败退出码 3", BrowserDiagnosticsCommand.run(arguments: ["--browser-diagnostics", "--read"], dependencies: readFailing) { captured += $0 }, 3)
        reporter.check("--read 失败一方保留原文、成功一方仍解析", captured.contains("JavaScript off") && captured.contains("41% used"), captured)
    }

    // MARK: 发现层：原始观测 → 候选（不可读不等于退出）

    static func testChromeDiscoveryObservations(_ reporter: TestReporter) {
        reporter.group("发现层 · 原始观测 → 候选：不可读不等于退出")
        func observation(_ pid: pid_t, terminated: Bool = false) -> ChromeProcessObservation {
            ChromeProcessObservation(pid: pid, isTerminated: terminated, launchDate: Date(timeIntervalSince1970: 1_800_000_000), bundleURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"))
        }
        var probes = ChromeDiscoveryProbes()
        probes.readArguments = { pid in pid == 100 ? .success(chromeArguments([])) : .failure(.sysctlFailed(errno: EPERM)) }
        probes.readStartTime = { pid in pid == 100 ? startTime() : nil }
        probes.isProcessGone = { _ in false }
        let observations = [observation(100), observation(500)]
        let candidates = ChromeInstanceDiscovery.discover(observations: observations, probes: probes)
        reporter.equal("存活但 argv 与启动时间都不可读的进程仍是候选", candidates.map(\.pid), [100, 500])
        reporter.check("不可读候选没有参数与启动时间", candidates.last?.arguments == nil && candidates.last?.startTime == nil)
        let decision = ChromeInstanceDiscovery.decide(candidates: candidates)
        reporter.equal("普通 + 双不可读存活 → 无法确认，不自动选择", decision.selection, .unverifiable([500]))
        var factoryCalls = 0
        var dependencies = ChromeQuotaReadService.Dependencies()
        dependencies.useWatchdogThread = false
        dependencies.discover = { ChromeInstanceDiscovery.discover(observations: observations, probes: probes) }
        dependencies.makeTransport = { identity, _ in factoryCalls += 1; return standardMockTransport(pid: identity.pid) }
        let outcome = ChromeQuotaReadService.run(options: standardOptions(), dependencies: dependencies)
        reporter.equal("零事件：不创建传输层", factoryCalls, 0)
        reporter.check("outcome 无报告、无事件", outcome.report == nil && outcome.eventCounts.isEmpty)
        reporter.check("卡片说明无法确认且含 PID 500 与原因", ChromeCardBuilder.cards(from: outcome)[0].details.contains { $0.contains("PID 500") && $0.contains("不可读") })

        var gone = probes
        gone.isProcessGone = { $0 == 500 }
        let goneCandidates = ChromeInstanceDiscovery.discover(observations: observations, probes: gone)
        reporter.equal("内核确认退出（ESRCH）的进程被忽略", goneCandidates.map(\.pid), [100])
        reporter.equal("忽略后正常选中普通实例", ChromeInstanceDiscovery.decide(candidates: goneCandidates).selectedIdentity?.pid, 100)
        let terminated = ChromeInstanceDiscovery.discover(observations: [observation(100), observation(500, terminated: true)], probes: probes)
        reporter.equal("LaunchServices 标记已终止的进程被忽略", terminated.map(\.pid), [100])
        var argvOKNoStart = probes
        argvOKNoStart.readArguments = { _ in .success(chromeArguments([])) }
        let partial = ChromeInstanceDiscovery.discover(observations: observations, probes: argvOKNoStart)
        reporter.equal("argv 可读但启动时间不可读仍保留为候选", partial.map(\.pid), [100, 500])
        reporter.equal("该候选归入无法确认", ChromeInstanceDiscovery.decide(candidates: partial).selection, .unverifiable([500]))
        var automationNoStart = probes
        automationNoStart.readArguments = { pid in pid == 100 ? .success(chromeArguments([])) : .success(chromeArguments(["--remote-debugging-pipe"])) }
        let automationPartial = ChromeInstanceDiscovery.discover(observations: observations, probes: automationNoStart)
        reporter.equal("启动时间不可读的自动化实例仍是自动化，普通实例照常选中", ChromeInstanceDiscovery.decide(candidates: automationPartial).selectedIdentity?.pid, 100)
        var allGone = probes
        allGone.isProcessGone = { _ in true }
        allGone.readArguments = { _ in .failure(.sysctlFailed(errno: ESRCH)) }
        reporter.equal("全部确凿退出 → 未运行", ChromeInstanceDiscovery.decide(candidates: ChromeInstanceDiscovery.discover(observations: observations, probes: allGone)).selection, .notRunning)

        reporter.group("发现层 · 真实观测（只读）")
        let real = ChromeInstanceDiscovery.observe()
        reporter.check("真实观测的每个进程 PID > 0", real.allSatisfy { $0.pid > 0 })
        reporter.equal("默认 discover() 与显式观测路径一致", Set(ChromeInstanceDiscovery.discover().map(\.pid)), Set(ChromeInstanceDiscovery.discover(observations: real).map(\.pid)))
    }

    // MARK: 页面就绪上限（阶段 deadline 传入事件等待与前后校验）

    static func testReadinessStageLimit(_ reporter: TestReporter) {
        reporter.group("页面就绪上限 · 慢最后目标晚到 ready 不采纳，其它目标保留")
        let slowLast = runReader { mock in
            mock.readyAfterProbe = ["100": 1, "200": 1]
            mock.probeVirtualDelays = ["200": 31]
        }
        reporter.equal("Codex 在上限内就绪并读取", slowLast.report.targets(of: .codex).first?.isConfirmed, true)
        reporter.equal("Claude 晚到的 ready 不采纳", slowLast.report.targets(of: .claude).first?.ready, false)
        reporter.check("Claude 标记超时且回复晚到", slowLast.report.targets(of: .claude).first.map { $0.readyTimedOut && $0.lateReply } == true)
        reporter.equal("只读取 Codex", slowLast.transport.calls(withPrefix: "read"), ["read 10/100"])
        reporter.check("不是致命错误（整轮预算仍在）", slowLast.report.fatalError == nil, "\(String(describing: slowLast.report.fatalError))")
        reporter.check("页面上限已到", slowLast.report.deadlineReached)
        let slowLastCards = ChromeCardBuilder.cards(from: outcome(slowLast))
        reporter.check("Codex 成功卡片已确认", slowLastCards[0].confirmedAt != nil && !slowLastCards[0].progress.isEmpty)
        reporter.equal("Claude 卡片为未就绪", slowLastCards[1].headline, "页面未就绪（30 秒内未出现已支持的额度字段）")
        reporter.check("Claude 卡片说明回复晚于上限、无进度", slowLastCards[1].details.contains { $0.contains("晚于页面上限") } && slowLastCards[1].progress.isEmpty)

        reporter.group("页面就绪上限 · 慢枚举（就绪阶段快照晚到）")
        let slowSnapshot = runReader { mock in
            mock.readyAfterProbe = ["100": 99, "200": 99]
            mock.afterSnapshot = { mock, index in mock.windowsVirtualDelay = index == 1 ? 31 : 0 }
        }
        reporter.equal("晚到的快照后没有任何探测", slowSnapshot.transport.calls(withPrefix: "probe").count, 0)
        reporter.equal("没有读取", slowSnapshot.transport.calls(withPrefix: "read").count, 0)
        reporter.check("全部目标超时、非致命", slowSnapshot.report.targets.allSatisfy(\.readyTimedOut) && slowSnapshot.report.fatalError == nil, "\(String(describing: slowSnapshot.report.fatalError))")
        reporter.check("原因进入警告行", slowSnapshot.report.warningLines.contains { $0.contains("快照超过页面上限") })
        reporter.check("整轮预算未耗尽（62 秒内）", slowSnapshot.clock.current - 1_000 < 62)

        reporter.group("页面就绪上限 · 多目标耗尽：每条事件受页面剩余约束")
        let exhausted = runReader { mock in
            mock.readyAfterProbe = ["100": 99, "200": 99]
            mock.probeVirtualDelay = 12
        }
        reporter.equal("Codex 探测 2 次、Claude 1 次后停止", [exhausted.transport.probeCounts["100"] ?? 0, exhausted.transport.probeCounts["200"] ?? 0], [2, 1])
        reporter.equal("没有读取", exhausted.transport.calls(withPrefix: "read").count, 0)
        reporter.check("全部超时、非致命", exhausted.report.targets.allSatisfy(\.readyTimedOut) && exhausted.report.fatalError == nil, "\(String(describing: exhausted.report.fatalError))")
        reporter.check("整轮预算未耗尽", exhausted.clock.current - 1_000 < 62)

        reporter.group("页面就绪上限 · 晚到的全员 ready 不采纳")
        let lateAll = runReader { mock in
            mock.readyAfterProbe = ["100": 1, "200": 1]
            mock.probeVirtualDelay = 31
        }
        reporter.equal("没有任何目标就绪", lateAll.report.confirmedTargets.count, 0)
        reporter.equal("晚到后不再探测第二个目标", lateAll.transport.calls(withPrefix: "probe").count, 1)
        reporter.equal("没有读取", lateAll.transport.calls(withPrefix: "read").count, 0)
        reporter.check("非致命、全部超时", lateAll.report.fatalError == nil && lateAll.report.targets.allSatisfy(\.readyTimedOut))
        let lateCards = ChromeCardBuilder.cards(from: outcome(lateAll))
        reporter.check("两张卡片都是未就绪且无进度、无 confirmedAt", lateCards.allSatisfy { $0.headline.hasPrefix("页面未就绪") && $0.progress.isEmpty && $0.confirmedAt == nil })
        reporter.check("整轮预算、settle 与读取边界未被替代（预算上限仍为 62 秒）", standardOptions().watchdogSeconds == 62)
    }

    // MARK: 「本次读取详情」入口

    static func testReadDetailsEntry(_ reporter: TestReporter) {
        reporter.group("本次读取详情 · 菜单入口与内容（无错误 / 错误 / 连续不同失败 / 长条与圆环）")
        let candidates = [candidate(92241, arguments: chromeArguments([]))]
        func run(now: Date, configure: @escaping (MockChromeTransport) -> Void = { _ in }) -> Snapshot {
            let (dependencies, _) = mockDependencies(candidates: candidates, now: now, configure: configure)
            let outcome = ChromeQuotaReadService.run(options: standardOptions(), dependencies: dependencies)
            return Snapshot(updatedAt: now, cards: ChromeCardBuilder.cards(from: outcome), diagnosticsLines: outcome.diagnosticLines)
        }
        let delegate = AppDelegate()
        reporter.check("尚未读取时说明无数据", delegate.readDetailsText().contains("尚未读取过数据"))
        let menuBefore = delegate.makeMenu()
        let entryBefore = menuBefore.items.first { $0.title == "本次读取详情…" }
        reporter.check("菜单有「本次读取详情…」入口", entryBefore != nil)
        reporter.equal("没有 snapshot 时入口禁用", entryBefore.map { delegate.validateMenuItem($0) }, false)
        reporter.check("其它菜单项不受影响（立即刷新仍启用）", menuBefore.items.first { $0.title == "立即刷新" }.map { delegate.validateMenuItem($0) } == true)

        delegate.store(latest: run(now: fixedNow))
        let ok = delegate.readDetailsText()
        reporter.check("无错误：两项已确认并显示读取确认时间", ok.contains("Codex 网页额度") && ok.contains("Claude 网页额度") && ok.components(separatedBy: "本轮已确认新鲜值").count == 3 && ok.contains("读取确认:"))
        reporter.check("无错误：没有失败提示", !ok.contains("本次读取未成功") && !ok.contains("⚠"))
        reporter.check("含实例诊断（候选 PID、选中 PID）", ok.contains("浏览器实例诊断") && ok.contains("PID 92241"))
        reporter.check("说明不会重新抓网页", ok.contains("不会重新抓取网页"))
        reporter.check("不含页面正文", !ok.contains("Plan usage limits") && !ok.contains("Codex 分析"))
        reporter.equal("有 snapshot 时入口启用", delegate.makeMenu().items.first { $0.title == "本次读取详情…" }.map { delegate.validateMenuItem($0) }, true)

        delegate.store(latest: run(now: laterNow) { $0.windowsError = ChromeEventError.fromOSStatus(-1743, stage: .enumerateWindows, chromeMessage: nil) })
        let denied = delegate.readDetailsText()
        reporter.check("错误：显示本次失败标题与阶段/错误码", denied.contains("本次读取未成功: 自动化权限被拒绝") && denied.contains("枚举窗口失败") && denied.contains("-1743"))
        reporter.check("错误：显示可操作建议", denied.contains(ChromeCardBuilder.permissionHint))
        reporter.check("错误：显示旧成功时间与旧值", denied.contains("已确认的上次成功值") && denied.contains(Formatters.date(fixedNow)) && denied.contains("68% 剩余"))
        reporter.check("错误：标注本轮未确认新鲜值", denied.contains("本轮未确认新鲜值"))
        reporter.check("错误：面板备注同样出现在详情", denied.contains("⚠ 本次未成功: 自动化权限被拒绝"))
        reporter.check("错误：诊断行含本轮阶段错误", denied.contains("阶段错误"))

        delegate.store(latest: run(now: laterNow) { $0.reloadErrors = ["100": ChromeEventError.fromOSStatus(-1708, stage: .reload, chromeMessage: nil), "200": ChromeEventError.fromOSStatus(-1708, stage: .reload, chromeMessage: nil)] })
        let reloadFailed = delegate.readDetailsText()
        reporter.check("连续不同失败：只显示最新失败", reloadFailed.contains("reload 失败，本次不采用") && reloadFailed.contains("-1708") && !reloadFailed.contains("自动化权限被拒绝") && !reloadFailed.contains("-1743"))
        reporter.check("连续不同失败：仍显示旧成功时间与旧值", reloadFailed.contains(Formatters.date(fixedNow)) && reloadFailed.contains("68% 剩余"))

        let bars = ReadDetailsText.render(snapshot: delegate.currentSnapshot, style: .bars, isRefreshing: false, lastRefreshAt: nil)
        let rings = ReadDetailsText.render(snapshot: delegate.currentSnapshot, style: .rings, isRefreshing: false, lastRefreshAt: nil)
        reporter.check("长条视图标注", bars.contains("视图: 长条"))
        reporter.check("圆环视图标注", rings.contains("视图: 圆环"))
        let strip: (String) -> String = { $0.components(separatedBy: "\n").filter { !$0.hasPrefix("视图:") }.joined(separator: "\n") }
        reporter.equal("长条 / 圆环内容一致（视图不影响详情）", strip(bars), strip(rings))
        reporter.check("刷新中标注仍显示上一轮结果", ReadDetailsText.render(snapshot: delegate.currentSnapshot, style: .bars, isRefreshing: true, lastRefreshAt: nil).contains("正在刷新"))
    }

    // MARK: 最终展示层：沿用逻辑端到端（T0 成功 → T1 各类失败 → T2 真成功）

    static func testWebCardContinuityEndToEnd(_ reporter: TestReporter) {
        reporter.group("最终展示层 · T0 成功 → T1 失败不覆盖 → T2 真成功才更新")
        let normalArguments = chromeArguments([])
        let candidates = [candidate(92241, arguments: normalArguments)]

        func display(_ delegate: AppDelegate, _ outcome: ChromeQuotaReadOutcome) -> Snapshot {
            delegate.applyWebCardContinuity(to: Snapshot(
                updatedAt: Date(),
                cards: ChromeCardBuilder.cards(from: outcome),
                diagnosticsLines: outcome.diagnosticLines
            ))
        }
        func run(now: Date, options: ChromeReadOptions = standardOptions(), configure: @escaping (MockChromeTransport) -> Void = { _ in }) -> ChromeQuotaReadOutcome {
            let (dependencies, _) = mockDependencies(candidates: candidates, now: now, configure: configure)
            return ChromeQuotaReadService.run(options: options, dependencies: dependencies)
        }
        let t0Time = Formatters.date(fixedNow)
        let t2Time = Formatters.date(laterNow)

        // 没有 T0：如实显示失败，不伪造新鲜数据。
        let fresh = AppDelegate()
        let noHistory = display(fresh, run(now: fixedNow) { $0.reloadErrors = ["100": ChromeEventError.fromOSStatus(-1708, stage: .reload, chromeMessage: nil), "200": ChromeEventError.fromOSStatus(-1708, stage: .reload, chromeMessage: nil)] })
        reporter.equal("没有 T0 时 reload 失败如实显示", noHistory.cards[0].headline, "reload 失败，本次不采用")
        reporter.check("没有 T0 时无进度、无百分比、无沿用", noHistory.cards.allSatisfy { $0.progress.isEmpty && $0.statusBarHint == nil && $0.note == nil })
        reporter.check("没有 T0 时诊断行保留", !noHistory.diagnosticsLines.isEmpty)

        // T0 成功。
        let delegate = AppDelegate()
        let t0 = display(delegate, run(now: fixedNow))
        reporter.check("T0 两张卡片已确认", t0.cards.allSatisfy { $0.confirmedAt == fixedNow && !$0.progress.isEmpty })
        reporter.equal("T0 Codex 68%", t0.cards[0].statusBarHint, "68%")

        func assertKeepsT0(_ label: String, _ snapshot: Snapshot, index: Int = 0, expectHeadlinePart: String) {
            let card = snapshot.cards[index]
            reporter.check("\(label): 沿用 T0 值与时间", card.headline.contains("沿用 \(Formatters.clock(fixedNow))") && card.details.contains { $0.contains(t0Time) }, card.headline)
            reporter.check("\(label): 进度与百分比来自 T0", card.statusBarHint == (index == 0 ? "68%" : "59%") && !card.progress.isEmpty)
            reporter.check("\(label): 沿用卡片不是已确认", card.confirmedAt == nil)
            reporter.check("\(label): 保留本次失败标题", card.details.first?.contains(expectHeadlinePart) == true, "\(card.details)")
            reporter.check("\(label): 面板备注说明本次失败", card.note?.contains(expectHeadlinePart) == true)
            reporter.check("\(label): 诊断行保留", !snapshot.diagnosticsLines.isEmpty)
        }

        // T1a reload 失败但 DOM 仍有数值。
        let t1a = display(delegate, run(now: laterNow) { mock in
            mock.reloadErrors = ["100": ChromeEventError.fromOSStatus(-1708, stage: .reload, chromeMessage: nil), "200": ChromeEventError.fromOSStatus(-1708, stage: .reload, chromeMessage: nil)]
            mock.pageText = ["100": mockCodexTextT2, "200": mockClaudeText]
        })
        assertKeepsT0("T1a reload 失败", t1a, expectHeadlinePart: "reload 失败")
        reporter.check("T1a 保留 OSStatus", t1a.cards[0].details.contains { $0.contains("-1708") })
        reporter.check("T1a 不显示 DOM 里的新数值", !t1a.cards[0].details.contains { $0.contains("40% 剩余") } && t1a.cards[0].statusBarHint == "68%")

        // T1b 永不就绪。
        let t1b = display(delegate, run(now: laterNow, options: standardOptions(timeout: 5)) { mock in
            mock.readyAfterProbe = ["100": 99, "200": 99]
            mock.pageText = ["100": mockCodexTextT2, "200": mockClaudeText]
        })
        assertKeepsT0("T1b 永不就绪", t1b, expectHeadlinePart: "页面未就绪")
        reporter.check("T1b 保留超时原因", t1b.cards[0].details.contains { $0.contains("就绪超时") })

        // T1c 权限拒绝（枚举失败）。
        let t1c = display(delegate, run(now: laterNow) { $0.windowsError = ChromeEventError.fromOSStatus(-1743, stage: .enumerateWindows, chromeMessage: nil) })
        assertKeepsT0("T1c 权限拒绝", t1c, expectHeadlinePart: "自动化权限被拒绝")
        reporter.check("T1c 保留 -1743 与可操作提示", t1c.cards[0].details.contains { $0.contains("-1743") } && t1c.cards[0].details.contains(ChromeCardBuilder.permissionHint))
        assertKeepsT0("T1c 权限拒绝（Claude）", t1c, index: 1, expectHeadlinePart: "自动化权限被拒绝")

        // T1d 身份失效。
        let t1d = display(delegate, run(now: laterNow) { $0.identityFailureAfterCalls = 1 })
        assertKeepsT0("T1d 身份失效", t1d, expectHeadlinePart: "身份变化")

        // T1e 看门狗（无报告）。
        let watchdogOutcome = ChromeQuotaReadOutcome(
            options: standardOptions(),
            decision: ChromeInstanceDiscovery.decide(candidates: candidates),
            report: nil,
            watchdogTimedOut: true,
            eventLog: [],
            eventCounts: [:],
            elapsed: 62
        )
        let t1e = display(delegate, watchdogOutcome)
        assertKeepsT0("T1e 看门狗", t1e, expectHeadlinePart: "看门狗")

        // T1f 部分失败：Codex 真成功（更新），Claude JS 关闭（沿用）。
        let t1f = display(delegate, run(now: laterNow) { mock in
            mock.pageText = ["100": mockCodexTextT2, "200": mockClaudeText]
            mock.readErrors = ["200": ChromeEventError.fromOSStatus(-10000, stage: .read, chromeMessage: "Executing JavaScript through AppleScript is turned off.")]
        })
        reporter.check("T1f Codex 更新为新值与新时间", t1f.cards[0].confirmedAt == laterNow && t1f.cards[0].statusBarHint == "40%")
        assertKeepsT0("T1f Claude 沿用", t1f, index: 1, expectHeadlinePart: "精确读取")
        reporter.check("T1f Claude 保留 JS 原文与菜单提示", t1f.cards[1].details.contains { $0.contains("turned off") } && t1f.cards[1].details.contains(ChromeCardBuilder.javascriptHint))

        // 连续失败不累积。
        var counts: [Int] = []
        for _ in 0..<3 {
            let again = display(delegate, run(now: laterNow) { $0.windowsError = ChromeEventError.fromOSStatus(-1743, stage: .enumerateWindows, chromeMessage: nil) })
            counts.append(again.cards[1].details.count)
        }
        reporter.equal("连续失败沿用卡片行数固定", Set(counts).count, 1)

        // T2 真成功：Claude 更新（Codex 已在 T1f 更新）。
        let t2 = display(delegate, run(now: laterNow) { $0.pageText = ["100": mockCodexTextT2, "200": mockClaudeSessionOnlyText] })
        reporter.check("T2 两张卡片都已确认为新时间", t2.cards.allSatisfy { $0.confirmedAt == laterNow })
        reporter.equal("T2 Claude 只有 Current session 也是有效成功（7% used → 93% 剩余）", t2.cards[1].statusBarHint, "93%")
        let afterT2 = display(delegate, run(now: laterNow) { $0.windowsError = ChromeEventError.fromOSStatus(-1743, stage: .enumerateWindows, chromeMessage: nil) })
        reporter.check("T2 之后沿用的是 T2 的值与时间", afterT2.cards[1].statusBarHint == "93%" && afterT2.cards[1].details.contains { $0.contains(t2Time) } && !afterT2.cards[1].details.contains { $0.contains(t0Time) }, "\(afterT2.cards[1].details)")
    }
}
