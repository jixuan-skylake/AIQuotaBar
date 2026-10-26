import Foundation

// MARK: - 额度页读取编排、逐阶段报告、卡片生成与诊断 CLI
//
// 职责：
// - `ChromeReadBudget`：整轮读取共享的取消标记 + 单调时钟 deadline。读取流程每次事件 / 睡眠前、传输层每条事件
//   发送前都要经过它；事件等待时间不超过剩余预算；看门狗触发后没有任何新事件，也没有晚到的更新。
// - `ChromeQuotaReader`：在一个已选定的传输层上执行「快照 → 目标识别 → reload → 就绪等待（tab loading + 已支持
//   额度字段探针，1→2→4 秒退避、上限只算一次）→ settle → 稳定 ID 复核 → 读取」。
//   契约（R1 整改）：只有「(开启 reload 时) reload 已发送且成功 + 就绪确认通过 + 读取成功」的页面才是本轮新鲜值；
//   reload 失败 / 未发送、就绪超时、标签消失、寻址失败的目标不再读取，绝不产生可被当成成功的数值。
//   身份失效与看门狗属于致命错误，终止整轮，不会被窗口 / 目标级 catch 降为局部错误。
// - `ChromeQuotaReadService`：实例发现 → 选择 → 传输层 → 看门狗线程（与 budget 同一 deadline）→ outcome。
//   0.2.14 R1 起不再有辅助功能（AX）备用读取：它无法满足上述契约，也无法按网址契约校验来源。
// - `ChromeCardBuilder`：把 outcome 变成菜单卡片。只有已确认目标的成功卡片带 `confirmedAt`，
//   AppDelegate 的沿用逻辑只信任 `confirmedAt`。
// - `BrowserDiagnosticsCommand`：`--browser-diagnostics` CLI，默认只枚举；`--read` 也先做就绪判断再读取。
//
// 边界：时钟可注入（自检零等待）；报告与诊断输出只含计数、ID、URL（仅额度页）、错误文本，不含任何页面正文。

protocol ChromeReadClock {
    /// 单调时钟（秒），不受系统时间调整影响；只用于 deadline / 退避 / 预算。
    func uptime() -> TimeInterval
    func sleep(_ seconds: TimeInterval)
}

final class SystemChromeReadClock: ChromeReadClock {
    func uptime() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    func sleep(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        Thread.sleep(forTimeInterval: seconds)
    }
}

/// 整轮读取共享的预算：取消标记 + 单调 deadline。线程安全；读取线程与看门狗线程共用同一实例。
final class ChromeReadBudget {
    let clock: ChromeReadClock
    let totalSeconds: TimeInterval
    let deadline: TimeInterval
    private let lock = NSLock()
    private var cancelReason: String?

    init(clock: ChromeReadClock, seconds: TimeInterval) {
        self.clock = clock
        totalSeconds = seconds
        deadline = clock.uptime() + seconds
    }

    func cancel(reason: String = "看门狗已放弃本轮读取") {
        lock.lock()
        if cancelReason == nil { cancelReason = reason }
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelReason != nil
    }

    var cancellationReason: String? {
        lock.lock(); defer { lock.unlock() }
        return cancelReason
    }

    func remaining() -> TimeInterval {
        max(0, deadline - clock.uptime())
    }

    /// 每次事件与睡眠之前调用：已取消或预算耗尽即抛看门狗错误（致命）。
    func checkpoint(_ what: String) throws {
        if let reason = cancellationReason {
            throw ChromeEventError(stage: .watchdog, code: nil, message: "\(reason)，不再执行: \(what)")
        }
        if remaining() <= 0 {
            throw ChromeEventError(stage: .watchdog, code: nil, message: "读取预算 \(Int(totalSeconds)) 秒已耗尽，不再执行: \(what)")
        }
    }

    /// 单条 Apple Event 的最小等待粒度：剩余（整轮或阶段）小于它时直接拒绝发送，而不是把等待扩大到 0.1 秒。
    static let minimumEventWait: TimeInterval = 0.1

    private var stageDeadline: TimeInterval?

    /// 进入有独立上限的阶段（页面就绪等待）：阶段内所有事件的等待与发送前 / 回复后校验都受该 deadline 约束。
    func beginStage(deadline: TimeInterval) {
        lock.lock(); stageDeadline = deadline; lock.unlock()
    }

    /// 结束阶段（幂等）：之后事件只受整轮预算约束（settle 与读取边界保持原样）。
    func endStage() {
        lock.lock(); stageDeadline = nil; lock.unlock()
    }

    func stageRemaining() -> TimeInterval? {
        lock.lock()
        let deadline = stageDeadline
        lock.unlock()
        return deadline.map { max(0, $0 - clock.uptime()) }
    }

    var stageExceeded: Bool {
        stageRemaining().map { $0 <= 0 } ?? false
    }

    struct EventWait: Equatable {
        let timeout: TimeInterval
        let limitedByStage: Bool
    }

    /// 单条事件的等待上限 = min(默认, 整轮剩余, 阶段剩余)。小于最小粒度时返回 nil，调用方必须拒绝发送。
    func eventWait(default seconds: TimeInterval) -> EventWait? {
        let overall = remaining()
        let stage = stageRemaining()
        let timeout = min(seconds, overall, stage ?? overall)
        guard timeout >= Self.minimumEventWait else { return nil }
        return EventWait(timeout: timeout, limitedByStage: stage.map { $0 < overall } ?? false)
    }

    /// 睡眠不超过剩余预算；前后都做 checkpoint。
    func sleep(upTo seconds: TimeInterval, reason: String) throws {
        try checkpoint("等待前(\(reason))")
        let duration = min(max(0, seconds), remaining())
        if duration > 0 {
            clock.sleep(duration)
        }
        try checkpoint("等待后(\(reason))")
    }
}

enum ChromePageScripts {
    /// 已支持额度字段的就绪条件：与 `BrowserUsageParser` 的解析口径**逐字共用同一条正则**，
    /// 任一栏目读出完整合法数值即视为有数据。不要求页面同时出现所有栏目
    /// （真实 Claude 页可能只有 Current session；新中文页也可能只有「当前会话」先渲染出来）。
    static func readinessCondition(for kind: ChromeTargetKind) -> String {
        // 两类页面共用同一套中性归一化：图标占位符 → 空格、任意一段换行 → 一个 `\n`、横向空白 → 一个空格。
        // 只共用正则不够——ICU 的 `\d` 含全角数字而 JS 只认 ASCII、空白压缩与否也会让两端分叉，
        // 所以正则里写死 [0-9]/[ \n]，这里再把解析器那套归一化原样编译进脚本。
        // 换行字符集与 Foundation `CharacterSet.newlines` 对齐（生产链路的 `LineTools` 就按它分行），
        // VT/FF 不能这边当横向空白、那边当换行。
        let normalized = "t.split('\(BrowserUsageParser.codexObjectReplacement)').join(' ')"
            + ".replace(/\(BrowserUsageParser.codexLineBreak)+/g,'\\n')"
            + ".replace(/\(BrowserUsageParser.codexHorizontalSpace)+/g,' ')"
        // 两端都不加 i 标志：大小写已经展开进正则，没有 case folding 这个变量。
        switch kind {
        case .codex:
            return "/\(BrowserUsageParser.codexWeeklyRemainingPattern)/.test(\(normalized))"
        case .claude:
            // 0.2.16：换成 `claudeReadyPattern`（= 解析口径，标题位置取全部指标标题的并集）。
            // 旧条件是「标题 + 140 字符内 + 任意百分比 + 后缀 used/已使用」：既读不到新页面的前缀式
            // 「已使用 0%」（Claude 页就绪超时的直接原因），也会跨栏目把「本周 Fable」的数值算进来。
            return "/\(BrowserUsageParser.claudeReadyPattern)/.test(\(normalized))"
        }
    }

    /// 单次 JS 调用同时判断 `document.readyState === 'complete'` 与已支持额度字段，返回 "1" / "0"。
    static func readinessProbe(for kind: ChromeTargetKind) -> String {
        "(function(){try{var d=document;if(d.readyState!=='complete'){return '0';}var b=d.body;if(!b){return '0';}var t=b.innerText||'';if("
            + readinessCondition(for: kind)
            + "){return '1';}return '0';}catch(e){return '0';}})()"
    }

    static let readScript = "document.body ? document.body.innerText : ''"
}

enum ChromeTargetKind: String, CaseIterable, Equatable {
    case codex
    case claude

    /// 严格网址契约（BrowserUsageTargets 用 URLComponents 校验），操作前复核与目标识别共用。
    static func kind(for url: String?) -> ChromeTargetKind? {
        if BrowserUsageTargets.isCodexUsageURL(url) { return .codex }
        if BrowserUsageTargets.isClaudeUsageURL(url) { return .claude }
        return nil
    }

    var probeScript: String {
        ChromePageScripts.readinessProbe(for: self)
    }

    var providerName: String {
        switch self {
        case .codex: return "Codex 网页额度"
        case .claude: return "Claude 网页额度"
        }
    }

    var usageURL: String {
        switch self {
        case .codex: return BrowserUsageTargets.codexUsageURL
        case .claude: return BrowserUsageTargets.claudeUsageURL
        }
    }
}

struct ChromeReadOptions: Equatable {
    static let eventTimeout: TimeInterval = ChromeAppleEventTransport.defaultEventTimeout

    let reloadBeforeRead: Bool
    /// 页面就绪后的 settle 等待，0…10 秒。
    let settleSeconds: TimeInterval
    /// 等待就绪的全局上限，5…90 秒；整轮只计算一次 deadline。
    let timeoutSeconds: TimeInterval

    init(reloadBeforeRead: Bool, reloadWaitSeconds: Double, reloadTimeoutSeconds: Double) {
        self.reloadBeforeRead = reloadBeforeRead
        settleSeconds = max(0, min(10, reloadWaitSeconds))
        timeoutSeconds = max(5, min(90, reloadTimeoutSeconds))
    }

    static func from(config: AppConfig) -> ChromeReadOptions {
        ChromeReadOptions(
            reloadBeforeRead: config.browserReloadBeforeRead ?? true,
            reloadWaitSeconds: config.browserReloadWaitSeconds ?? 2,
            reloadTimeoutSeconds: config.browserReloadTimeoutSeconds ?? 30
        )
    }

    /// 外层看门狗 / 读取预算上限 = 页面等待上限 + settle + 余量，与 0.2.13 的 osascript 看门狗公式相同。
    var watchdogSeconds: TimeInterval {
        timeoutSeconds + settleSeconds + 30
    }
}

/// 单个额度页标签在本轮读取中的全部阶段结果。
struct ChromeTargetReport: Equatable {
    let kind: ChromeTargetKind
    let tabID: String
    var windowID: String
    var url: String
    var reloadSent = false
    var reloadError: ChromeEventError?
    var loadingChecks = 0
    var stillLoadingRounds = 0
    var probeCount = 0
    /// 就绪确认通过：tab 不在 loading 且探针命中已支持额度字段。
    var ready = false
    /// 仍在等待就绪。
    var waiting = true
    var readyTimedOut = false
    var lastProbeError: ChromeEventError?
    var resolveFailures = 0
    var lastResolveError: ChromeEventError?
    var skippedReason: String?
    var readError: ChromeEventError?
    /// 就绪探测 / loading 的回复晚于页面上限：即使返回就绪也不采纳。
    var lateReply = false
    /// 只有 `ready && reloadError == nil`（且开启 reload 时 reload 已发送）的目标才会读取。
    var page: BrowserTextPage?
    var confirmedAt: Date?

    /// 本轮新鲜值契约：reload 成功（若要求）+ 就绪确认 + 读取成功。
    var isConfirmed: Bool {
        ready && reloadError == nil && page != nil && confirmedAt != nil
    }

    /// 给卡片用的问题行（不含页面正文）。
    var issueLines: [String] {
        var lines: [String] = []
        if let reloadError {
            lines.append("reload 失败，本次不采用该页: \(reloadError.errorDescription ?? reloadError.message)")
        }
        if readyTimedOut {
            lines.append("等待页面就绪超时：页面未加载完成或未出现已支持的额度字段，本次不采用该页。")
        }
        if lateReply {
            lines.append("就绪探测回复晚于页面上限，不采纳该回复，已停止后续就绪探测。")
        }
        if stillLoadingRounds > 0, !ready {
            lines.append("页面仍在加载（loading）\(stillLoadingRounds) 轮。")
        }
        if let lastProbeError, !ready {
            lines.append("就绪探测错误: \(lastProbeError.errorDescription ?? lastProbeError.message)")
        }
        if resolveFailures > 0 {
            let detail = lastResolveError.map { "（\($0.errorDescription ?? $0.message)）" } ?? ""
            lines.append("稳定 ID 寻址失败 \(resolveFailures) 次\(detail)")
        }
        if let skippedReason, page == nil {
            lines.append("跳过: \(skippedReason)")
        }
        if let readError {
            lines.append("读取失败: \(readError.errorDescription ?? readError.message)")
        }
        return lines
    }

    var hasError: Bool {
        reloadError != nil || readyTimedOut || lateReply || (lastProbeError != nil && !ready) || resolveFailures > 0 || readError != nil
    }

    /// CLI 一行：只有 ID / 状态 / 行数，没有正文。
    var diagnosticLine: String {
        var parts = ["\(kind.rawValue) tab \(tabID) @ window \(windowID)"]
        if reloadSent {
            parts.append(reloadError == nil ? "reload 已发送" : "reload 失败")
        } else {
            parts.append("reload 未发送")
        }
        parts.append("loading 检查 \(loadingChecks) 次")
        parts.append("探测 \(probeCount) 次")
        parts.append(ready ? "已就绪" : (readyTimedOut ? "就绪超时" : "未确认就绪"))
        if let page {
            parts.append(isConfirmed ? "读取成功(\(page.lines.count) 行，已确认新鲜值)" : "读取成功(\(page.lines.count) 行，未确认)")
        } else if readError != nil {
            parts.append("读取失败")
        } else if let skippedReason {
            parts.append("跳过(\(skippedReason))")
        } else {
            parts.append("未读取")
        }
        if resolveFailures > 0 {
            parts.append("寻址失败 \(resolveFailures)")
        }
        parts.append("URL \(url)")
        return parts.joined(separator: " · ")
    }
}

struct ChromeSnapshotStats: Equatable {
    var windowCount = 0
    var tabCount = 0
    var windowErrors: [String] = []
}

/// 一轮编排读取的完整报告。`fatalError` 表示流程被迫终止的阶段错误（枚举窗口失败、身份失效、看门狗 / 预算耗尽）。
struct ChromeReadReport: Equatable {
    var stats = ChromeSnapshotStats()
    var targets: [ChromeTargetReport] = []
    var fatalError: ChromeEventError?
    var pollRounds = 0
    var deadlineReached = false
    /// 页面就绪阶段被上限打断的说明（如就绪阶段的快照回复晚到）。
    var readinessNotes: [String] = []
    var elapsed: TimeInterval = 0

    /// 只有已确认目标才有 page。
    var pages: [BrowserTextPage] { targets.compactMap(\.page) }

    var confirmedTargets: [ChromeTargetReport] { targets.filter(\.isConfirmed) }

    func targets(of kind: ChromeTargetKind) -> [ChromeTargetReport] {
        targets.filter { $0.kind == kind }
    }

    /// 汇总给 readWarning 的行：即使没有页面也保留。
    var warningLines: [String] {
        var lines: [String] = []
        if let fatalError {
            lines.append(fatalError.errorDescription ?? fatalError.message)
        }
        if !stats.windowErrors.isEmpty {
            lines.append("\(stats.windowErrors.count) 个窗口枚举失败: \(stats.windowErrors[0])")
        }
        lines.append(contentsOf: readinessNotes)
        for target in targets {
            for issue in target.issueLines {
                lines.append("\(target.kind.providerName): \(issue)")
            }
        }
        return lines
    }

    var isClean: Bool {
        fatalError == nil && stats.windowErrors.isEmpty && !targets.contains(where: \.hasError)
    }
}

struct ChromeTabSnapshot {
    let tabs: [ChromeTabRef]
    let windowCount: Int
    let windowErrors: [String]
}

enum ChromeSnapshotter {
    /// 枚举全部窗口与标签。窗口列表读不到就抛错；单个窗口的标签读不到记录错误后继续。
    /// 每个窗口前都过预算 checkpoint；身份失效 / 看门狗（致命）直接向上抛，终止整轮。
    static func snapshot(_ transport: ChromeTransport, budget: ChromeReadBudget) throws -> ChromeTabSnapshot {
        try budget.checkpoint("枚举窗口")
        let windowIDs = try transport.windowIDs()
        var tabs: [ChromeTabRef] = []
        var errors: [String] = []
        for windowID in windowIDs {
            try budget.checkpoint("枚举标签 window id \(windowID)")
            do {
                tabs.append(contentsOf: try transport.tabs(inWindow: windowID))
            } catch let error as ChromeEventError where !error.isFatal {
                errors.append("window id \(windowID): \(error.errorDescription ?? error.message)")
            }
        }
        return ChromeTabSnapshot(tabs: tabs, windowCount: windowIDs.count, windowErrors: errors)
    }
}

final class ChromeQuotaReader {
    private enum Resolution {
        case found(windowID: String, url: String)
        case addressingFailed
        case skipped
    }

    let transport: ChromeTransport
    let clock: ChromeReadClock
    let options: ChromeReadOptions
    let budget: ChromeReadBudget
    let now: () -> Date

    init(transport: ChromeTransport, clock: ChromeReadClock, options: ChromeReadOptions, budget: ChromeReadBudget, now: @escaping () -> Date = { Date() }) {
        self.transport = transport
        self.clock = clock
        self.options = options
        self.budget = budget
        self.now = now
    }

    func read() -> ChromeReadReport {
        var report = ChromeReadReport()
        let started = clock.uptime()
        execute(into: &report)
        // 就绪阶段无论怎样退出都要清掉阶段上限（幂等），避免影响后续读取或下一轮。
        budget.endStage()
        // 不能用 defer 赋值：defer 在 `return report` 拷贝返回值之后才执行，耗时会一直是 0。
        report.elapsed = clock.uptime() - started
        return report
    }

    /// 页面上限已到：等待中的目标全部按超时处理，之后不再发任何就绪探测（已就绪的目标照常保留）。
    private func timeOutWaitingTargets(_ report: inout ChromeReadReport) {
        report.deadlineReached = true
        for index in report.targets.indices where report.targets[index].waiting {
            report.targets[index].readyTimedOut = true
            report.targets[index].waiting = false
        }
    }

    private func execute(into report: inout ChromeReadReport) {
        do {
            try budget.checkpoint("开始读取")
            try transport.verifyIdentity()

            var snapshot = try takeSnapshot(into: &report, isFirst: true)
            report.targets = snapshot.tabs.compactMap { tab in
                ChromeTargetKind.kind(for: tab.url).map {
                    ChromeTargetReport(kind: $0, tabID: tab.tabID, windowID: tab.windowID, url: tab.url)
                }
            }
            guard !report.targets.isEmpty else { return }

            if options.reloadBeforeRead {
                for index in report.targets.indices {
                    try budget.checkpoint("reload \(report.targets[index].kind.rawValue)")
                    if case .found(let windowID, _) = try resolve(snapshot, &report.targets[index]) {
                        report.targets[index].reloadSent = true
                        do {
                            try transport.reload(windowID: windowID, tabID: report.targets[index].tabID)
                        } catch let error as ChromeEventError where !error.isFatal {
                            report.targets[index].reloadError = error
                        }
                    }
                }
                try budget.sleep(upTo: 0.75, reason: "reload 生效")
            }

            // 就绪等待。页面上限只在这里算一次：不因标签数量、探测错误或寻址失败而重置。
            // 上限通过 budget.beginStage 传入传输层：阶段内每条事件的等待与发送前 / 回复后校验都受它约束（整轮预算照旧）；
            // 每个目标探测前先看页面剩余，回复晚于上限的 ready 不采纳，并停止全部后续就绪探测（已就绪的目标照常保留）。
            let readinessDeadline = clock.uptime() + options.timeoutSeconds
            var pollDelay: TimeInterval = 1
            budget.beginStage(deadline: readinessDeadline)
            readiness: while true {
                try budget.checkpoint("就绪轮询")
                try transport.verifyIdentity()
                guard readinessDeadline - clock.uptime() >= ChromeReadBudget.minimumEventWait else {
                    timeOutWaitingTargets(&report)
                    break
                }
                report.pollRounds += 1
                do {
                    snapshot = try takeSnapshot(into: &report, isFirst: false)
                } catch let error as ChromeEventError where error.isStageLimit {
                    // 就绪阶段的快照回复晚于页面上限（慢枚举）：不再探测，等待中的目标全部按超时处理。
                    report.readinessNotes.append("就绪阶段快照超过页面上限: \(error.message)")
                    timeOutWaitingTargets(&report)
                    break
                }
                for index in report.targets.indices where report.targets[index].waiting {
                    if options.reloadBeforeRead, report.targets[index].reloadError != nil || !report.targets[index].reloadSent {
                        // reload 没有成功发出：即使 DOM 里仍有旧数值也不能算新鲜值，不再等待、不探测、不读取。
                        report.targets[index].waiting = false
                        continue
                    }
                    guard readinessDeadline - clock.uptime() >= ChromeReadBudget.minimumEventWait else {
                        timeOutWaitingTargets(&report)
                        break readiness
                    }
                    try budget.checkpoint("就绪探测 \(report.targets[index].kind.rawValue)")
                    switch try resolve(snapshot, &report.targets[index]) {
                    case .addressingFailed:
                        if budget.stageExceeded {
                            timeOutWaitingTargets(&report)
                            break readiness
                        }
                        continue
                    case .skipped:
                        report.targets[index].waiting = false
                    case .found(let windowID, _):
                        do {
                            report.targets[index].loadingChecks += 1
                            let loading = try transport.tabLoading(windowID: windowID, tabID: report.targets[index].tabID)
                            if clock.uptime() > readinessDeadline {
                                report.targets[index].lateReply = true
                                timeOutWaitingTargets(&report)
                                break readiness
                            }
                            if loading {
                                report.targets[index].stillLoadingRounds += 1
                                continue
                            }
                            report.targets[index].probeCount += 1
                            let value = try transport.executeJavaScript(
                                windowID: windowID,
                                tabID: report.targets[index].tabID,
                                script: report.targets[index].kind.probeScript,
                                purpose: .probe
                            )
                            // 回复晚于页面上限：即使返回 "1" 也不采纳，并停止后续就绪探测。
                            if clock.uptime() > readinessDeadline {
                                report.targets[index].lateReply = true
                                timeOutWaitingTargets(&report)
                                break readiness
                            }
                            if value == "1" {
                                report.targets[index].ready = true
                                report.targets[index].waiting = false
                            }
                        } catch let error as ChromeEventError where error.isStageLimit {
                            report.targets[index].lateReply = true
                            report.targets[index].lastProbeError = error
                            timeOutWaitingTargets(&report)
                            break readiness
                        } catch let error as ChromeEventError where !error.isFatal {
                            report.targets[index].lastProbeError = error
                        }
                    }
                }
                guard report.targets.contains(where: \.waiting) else { break }
                let uptime = clock.uptime()
                if uptime >= readinessDeadline {
                    timeOutWaitingTargets(&report)
                    break
                }
                try budget.sleep(upTo: min(pollDelay, readinessDeadline - uptime), reason: "就绪退避 \(Int(pollDelay))s")
                if pollDelay < 4 { pollDelay *= 2 }
            }
            budget.endStage()

            let readable = report.targets.indices.filter { index in
                let target = report.targets[index]
                return target.ready && target.reloadError == nil && (!options.reloadBeforeRead || target.reloadSent)
            }
            guard !readable.isEmpty else { return }
            // settle 只在 reload 之后有意义（与 0.2.13 一致）；不 reload 时页面早已稳定，不额外等待。
            if options.reloadBeforeRead, options.settleSeconds > 0 {
                try budget.sleep(upTo: options.settleSeconds, reason: "settle")
            }

            try budget.checkpoint("读取正文")
            try transport.verifyIdentity()
            snapshot = try takeSnapshot(into: &report, isFirst: false)
            for index in readable {
                try budget.checkpoint("读取 \(report.targets[index].kind.rawValue)")
                if case .found(let windowID, let url) = try resolve(snapshot, &report.targets[index]) {
                    do {
                        let text = try transport.executeJavaScript(
                            windowID: windowID,
                            tabID: report.targets[index].tabID,
                            script: ChromePageScripts.readScript,
                            purpose: .read
                        )
                        report.targets[index].page = BrowserTextPage(
                            url: url,
                            lines: LineTools.normalize([text], deduplicate: false),
                            source: "Chrome DOM (Apple Events JavaScript, PID \(transport.pid))"
                        )
                        report.targets[index].confirmedAt = now()
                    } catch let error as ChromeEventError where !error.isFatal {
                        report.targets[index].readError = error
                    }
                }
            }
        } catch let error as ChromeEventError {
            report.fatalError = error
        } catch {
            report.fatalError = ChromeEventError(stage: .identity, code: nil, message: error.localizedDescription)
        }
    }

    private func takeSnapshot(into report: inout ChromeReadReport, isFirst: Bool) throws -> ChromeTabSnapshot {
        let snapshot = try ChromeSnapshotter.snapshot(transport, budget: budget)
        if isFirst {
            report.stats.windowCount = snapshot.windowCount
            report.stats.tabCount = snapshot.tabs.count
        }
        report.stats.windowErrors.append(contentsOf: snapshot.windowErrors)
        return snapshot
    }

    /// 与 0.2.13 的 `verifiedTarget` 语义一致：先在最新快照里按持久 tab id 找到所在窗口并核对种类，
    /// 再通过 `tab id … of window id …` 这个稳定 ID 对象本身重新读一次 URL 复核（严格网址契约），最终事件也发给同一对象。
    /// 致命错误（身份 / 看门狗）向上抛，终止整轮。
    private func resolve(_ snapshot: ChromeTabSnapshot, _ target: inout ChromeTargetReport) throws -> Resolution {
        guard let tab = snapshot.tabs.first(where: { $0.tabID == target.tabID }) else {
            target.skippedReason = "标签已关闭或本轮未定位到"
            return .skipped
        }
        guard ChromeTargetKind.kind(for: tab.url) == target.kind else {
            target.skippedReason = "标签已不是额度页"
            return .skipped
        }
        do {
            let url = try transport.tabURL(windowID: tab.windowID, tabID: target.tabID)
            guard ChromeTargetKind.kind(for: url) == target.kind else {
                target.skippedReason = "复核时标签已不是额度页"
                return .skipped
            }
            target.windowID = tab.windowID
            target.url = url
            target.skippedReason = nil
            return .found(windowID: tab.windowID, url: url)
        } catch let error as ChromeEventError where !error.isFatal {
            target.resolveFailures += 1
            target.lastResolveError = error
            return .addressingFailed
        }
    }
}

// MARK: - 端到端服务

struct ChromeQuotaReadOutcome {
    let options: ChromeReadOptions
    let decision: ChromeInstanceDecision
    let report: ChromeReadReport?
    let watchdogTimedOut: Bool
    let eventLog: [String]
    let eventCounts: [String: Int]
    let elapsed: TimeInterval

    /// 汇总给卡片的读取警告；没有任何错误时为 nil。
    var readWarning: String? {
        var lines: [String] = []
        if watchdogTimedOut {
            lines.append("外层看门狗在 \(Int(options.watchdogSeconds)) 秒后放弃了本轮读取")
        }
        if let report {
            lines.append(contentsOf: report.warningLines)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "；")
    }

    /// CLI / 调试输出：候选 PID、分类、选择结果、目标、枚举计数、阶段错误、事件计数。不含页面正文。
    var diagnosticLines: [String] {
        var lines: [String] = []
        lines.append("候选 Chrome 主进程 (\(ChromeInstanceIdentity.bundleIdentifier)): \(decision.reports.count)")
        lines.append(contentsOf: decision.candidateLines.map { "  \($0)" })
        lines.append("选择: \(decision.selectionLine)")
        if let identity = decision.selectedIdentity {
            var line = "Apple Events 目标: typeKernelProcessID(kpid) → PID \(identity.pid)（内核启动 \(identity.startTime)"
            if let launchDate = identity.launchDate {
                line += " · LS 启动 \(Formatters.date(launchDate))"
            }
            line += "）"
            lines.append(line)
        } else if !decision.failureLines.isEmpty {
            lines.append(contentsOf: decision.failureLines.map { "  \($0)" })
        }
        if let report {
            let codexCount = report.targets(of: .codex).count
            let claudeCount = report.targets(of: .claude).count
            lines.append("枚举: 窗口 \(report.stats.windowCount) · 标签 \(report.stats.tabCount) · 额度页目标 \(report.targets.count)（codex \(codexCount) / claude \(claudeCount)）· 窗口枚举错误 \(report.stats.windowErrors.count)")
            lines.append(contentsOf: report.targets.map { "  \($0.diagnosticLine)" })
            lines.append("轮询: \(report.pollRounds) 轮 · 就绪超时: \(report.deadlineReached ? "是" : "否") · reload: \(options.reloadBeforeRead ? "开" : "关") · 已确认新鲜值 \(report.confirmedTargets.count)/\(report.targets.count) · 耗时 \(String(format: "%.1f", report.elapsed)) s")
            let warnings = report.warningLines
            if warnings.isEmpty {
                lines.append("阶段错误: 无")
            } else {
                lines.append("阶段错误: \(warnings.count)")
                lines.append(contentsOf: warnings.map { "  - \($0)" })
            }
        }
        if decision.selectedIdentity != nil {
            lines.append(watchdogTimedOut
                ? "看门狗: 已触发（\(Int(options.watchdogSeconds)) 秒），本轮读取被放弃，超时后不再发送事件"
                : "看门狗: 未触发（预算上限 \(Int(options.watchdogSeconds)) 秒）")
        }
        if !eventCounts.isEmpty {
            let summary = eventCounts.keys.sorted().map { "\($0) ×\(eventCounts[$0] ?? 0)" }.joined(separator: ", ")
            let pidText = decision.selectedIdentity.map { "全部发往 PID \($0.pid)" } ?? ""
            lines.append("Apple Events 计数: \(summary)\(pidText.isEmpty ? "" : "（\(pidText)）")")
            lines.append(contentsOf: eventLog.map { "  \($0)" })
        } else {
            lines.append("Apple Events 计数: 0（未发送任何事件）")
        }
        return lines
    }
}

enum ChromeQuotaReadService {
    /// 可注入依赖：自检用合成候选、mock 传输层与虚拟时钟，生产用默认值。
    struct Dependencies {
        var discover: () -> [ChromeInstanceCandidate] = { ChromeInstanceDiscovery.discover() }
        var makeTransport: (ChromeInstanceIdentity, ChromeReadBudget) -> ChromeTransport = { identity, budget in
            ChromeAppleEventTransport(identity: identity, budget: budget, eventTimeout: ChromeReadOptions.eventTimeout)
        }
        var clock: ChromeReadClock = SystemChromeReadClock()
        /// 确认时间的墙钟（自检注入固定时间以断言沿用逻辑）。
        var now: () -> Date = { Date() }
        /// false 时在当前线程同步执行（自检）；true 时在独立线程执行并由看门狗限时。
        var useWatchdogThread = true
        /// 仅自检使用：覆盖看门狗 / 预算上限，以便秒级验证超时路径。生产始终用 `options.watchdogSeconds`。
        var watchdogSecondsOverride: TimeInterval?

        init() {}
    }

    static func run(options: ChromeReadOptions, dependencies: Dependencies = Dependencies()) -> ChromeQuotaReadOutcome {
        let startedUptime = dependencies.clock.uptime()
        let decision = ChromeInstanceDiscovery.decide(candidates: dependencies.discover())

        guard let identity = decision.selectedIdentity else {
            return ChromeQuotaReadOutcome(
                options: options,
                decision: decision,
                report: nil,
                watchdogTimedOut: false,
                eventLog: [],
                eventCounts: [:],
                elapsed: dependencies.clock.uptime() - startedUptime
            )
        }

        // 看门狗线程与读取线程共用同一份预算（同一 deadline）：超时后读取线程的下一次事件 / 睡眠必然被拒绝。
        let watchdogSeconds = dependencies.watchdogSecondsOverride ?? options.watchdogSeconds
        let budget = ChromeReadBudget(clock: dependencies.clock, seconds: watchdogSeconds)
        let transport = dependencies.makeTransport(identity, budget)
        let reader = ChromeQuotaReader(transport: transport, clock: dependencies.clock, options: options, budget: budget, now: dependencies.now)

        var report: ChromeReadReport?
        var watchdogTimedOut = false
        if dependencies.useWatchdogThread {
            let box = ReportBox()
            let semaphore = DispatchSemaphore(value: 0)
            let thread = Thread {
                box.set(reader.read())
                semaphore.signal()
            }
            thread.name = "com.local.aiquotabar.chrome-read"
            thread.start()
            if semaphore.wait(timeout: .now() + watchdogSeconds) == .timedOut {
                // 取消后：传输层不再发送任何事件，正在等待的事件最多等到剩余预算为 0，回复到达也会被丢弃；
                // 这里不再读取 box，晚到的报告不会成为更新。
                budget.cancel()
                watchdogTimedOut = true
            } else {
                report = box.get()
            }
        } else {
            report = reader.read()
        }

        return ChromeQuotaReadOutcome(
            options: options,
            decision: decision,
            report: report,
            watchdogTimedOut: watchdogTimedOut,
            eventLog: transport.eventLog,
            eventCounts: transport.eventCounts,
            elapsed: dependencies.clock.uptime() - startedUptime
        )
    }

    private final class ReportBox {
        private let lock = NSLock()
        private var value: ChromeReadReport?
        func set(_ report: ChromeReadReport) { lock.lock(); value = report; lock.unlock() }
        func get() -> ChromeReadReport? { lock.lock(); defer { lock.unlock() }; return value }
    }
}

// MARK: - 卡片生成

enum ChromeCardBuilder {
    static let kinds: [ChromeTargetKind] = [.codex, .claude]
    static let javascriptHint = "Chrome 菜单: 查看 > 开发者 > 允许 Apple 事件中的 JavaScript。"
    static let permissionHint = "系统设置 > 隐私与安全性 > 自动化: 允许 AIQuotaBar 控制 Google Chrome。"
    static let continuityNote = "本次未读到已确认的新鲜页面，状态栏沿用上次成功值。"

    static func cards(from outcome: ChromeQuotaReadOutcome) -> [QuotaCard] {
        switch outcome.decision.selection {
        case .notRunning:
            return kinds.map(stoppedCard)
        case .onlyAutomation, .multipleNormal, .unverifiable:
            return kinds.map { instanceFailureCard($0, decision: outcome.decision) }
        case .selected:
            break
        }

        guard let report = outcome.report else {
            return kinds.map { kind in
                QuotaCard(
                    provider: kind.providerName,
                    headline: "读取超时（看门狗）",
                    details: [
                        "外层看门狗在 \(Int(outcome.options.watchdogSeconds)) 秒后放弃了本轮读取，Chrome 可能无响应；超时后不再向 Chrome 发送事件。",
                        continuityNote
                    ],
                    status: .warning,
                    remainingUSD: nil,
                    statusBarHint: nil
                )
            }
        }

        return kinds.map { card(for: $0, report: report, outcome: outcome) }
    }

    private static func card(for kind: ChromeTargetKind, report: ChromeReadReport, outcome: ChromeQuotaReadOutcome) -> QuotaCard {
        let targets = report.targets(of: kind)
        // 同类多个标签时优先取已确认且能解析出额度的页面，其次任意已确认页面，最后才是只有诊断的目标。
        let chosen = targets.first { $0.isConfirmed && $0.page.map { !hasNoMetrics(kind, $0) } == true }
            ?? targets.first { $0.isConfirmed }
            ?? targets.first

        if let fatal = report.fatalError, !(chosen?.isConfirmed ?? false) {
            return fatalCard(kind, error: fatal)
        }
        guard let target = chosen else {
            return noPageCard(kind, warnings: report.warningLines)
        }
        guard target.isConfirmed, let page = target.page, let confirmedAt = target.confirmedAt else {
            return unconfirmedCard(kind, target: target, options: outcome.options)
        }
        return successCard(kind, page: page, confirmedAt: confirmedAt, options: outcome.options)
    }

    private static func hasNoMetrics(_ kind: ChromeTargetKind, _ page: BrowserTextPage) -> Bool {
        switch kind {
        case .codex: return BrowserUsageParser.parseCodex(lines: page.lines).isEmpty
        case .claude: return BrowserUsageParser.parseClaude(lines: page.lines).isEmpty
        }
    }

    static func stoppedCard(_ kind: ChromeTargetKind) -> QuotaCard {
        QuotaCard(
            provider: kind.providerName,
            headline: "Chrome 未运行",
            details: [
                "AIQuotaBar 不会为了读取额度而启动 Chrome。",
                "打开 Chrome 并保留以下页面即可恢复自动读取:",
                kind.usageURL,
                "状态栏会继续沿用上一次成功读取的百分比。"
            ],
            status: .unavailable,
            remainingUSD: nil,
            statusBarHint: nil
        )
    }

    private static func instanceFailureCard(_ kind: ChromeTargetKind, decision: ChromeInstanceDecision) -> QuotaCard {
        QuotaCard(
            provider: kind.providerName,
            headline: decision.failureHeadline ?? "Chrome 实例无法确定",
            details: decision.failureLines + [continuityNote],
            status: .unavailable,
            remainingUSD: nil,
            statusBarHint: nil
        )
    }

    private static func fatalCard(_ kind: ChromeTargetKind, error: ChromeEventError) -> QuotaCard {
        let headline: String
        var status: StatusLevel = .warning
        var details: [String] = [error.errorDescription ?? error.message]
        if error.isPermissionDenied {
            headline = "自动化权限被拒绝"
            status = .unavailable
            details.append(permissionHint)
        } else if error.stage == .identity || error.isProcessGone {
            headline = "Chrome 进程已退出或身份变化"
            status = .unavailable
            details.append("身份失效后本轮已终止，不再向该 PID 发送事件；AIQuotaBar 不会启动 Chrome，下次刷新会重新发现实例。")
        } else if error.isTimeout {
            headline = "读取超时（\(error.stage.rawValue)）"
        } else if error.stage == .watchdog {
            headline = "读取被看门狗中止"
        } else {
            headline = "读取失败（\(error.stage.rawValue)）"
        }
        details.append(continuityNote)
        return QuotaCard(
            provider: kind.providerName,
            headline: headline,
            details: details,
            status: status,
            remainingUSD: nil,
            statusBarHint: nil
        )
    }

    private static func noPageCard(_ kind: ChromeTargetKind, warnings: [String]) -> QuotaCard {
        var details = [
            "在已登录的 Chrome 里打开:",
            kind.usageURL,
            "然后从状态栏点立即刷新。"
        ]
        if !warnings.isEmpty {
            details.append("读取诊断（本轮其它错误）:")
            details.append(contentsOf: warnings.prefix(3))
        }
        return QuotaCard(
            provider: kind.providerName,
            headline: "未找到已打开页面",
            details: details,
            status: .unavailable,
            remainingUSD: nil,
            statusBarHint: nil
        )
    }

    /// 页面存在但没有满足新鲜值契约：按主要原因给标题，细节保留全部阶段错误；绝不带 progress / confirmedAt。
    private static func unconfirmedCard(_ kind: ChromeTargetKind, target: ChromeTargetReport, options: ChromeReadOptions) -> QuotaCard {
        var details = target.issueLines
        var status: StatusLevel = .warning
        let headline: String
        let javascriptRelated = [target.readError, target.lastProbeError].contains { $0?.isJavaScriptRelated == true }
        if javascriptRelated {
            headline = "需要开启 Chrome 精确读取"
            status = .unavailable
            details.append(javascriptHint)
        } else if target.reloadError != nil {
            headline = "reload 失败，本次不采用"
        } else if options.reloadBeforeRead, !target.reloadSent {
            headline = "reload 未发送，本次不采用"
        } else if target.readyTimedOut {
            headline = "页面未就绪（\(Int(options.timeoutSeconds)) 秒内未出现已支持的额度字段）"
        } else if target.readError != nil {
            headline = "页面已找到，读取失败"
        } else if target.skippedReason != nil {
            headline = "标签已关闭或已不是额度页"
        } else if target.resolveFailures > 0 {
            headline = "页面已找到，读取失败（稳定 ID 寻址失败）"
        } else {
            headline = "页面未确认就绪，本次不采用"
        }
        details.append("URL: \(target.url)")
        details.append(continuityNote)
        return QuotaCard(
            provider: kind.providerName,
            headline: headline,
            details: details,
            status: status,
            remainingUSD: nil,
            statusBarHint: nil
        )
    }

    /// 已确认目标的成功 / 未解析卡片，格式与 0.2.13 一致（状态栏百分比与沿用逻辑依赖 progress 的 label）。
    /// 只有解析到额度的卡片带 `confirmedAt`。
    static func successCard(_ kind: ChromeTargetKind, page: BrowserTextPage, confirmedAt: Date, options: ChromeReadOptions) -> QuotaCard {
        let confirmation = "读取确认: \(Formatters.clock(confirmedAt))（\(options.reloadBeforeRead ? "reload 成功" : "未 reload") · 页面就绪 · 已解析）"
        switch kind {
        case .codex:
            let metrics = BrowserUsageParser.parseCodex(lines: page.lines)
            guard !metrics.isEmpty else {
                return notParsedCard(kind, page: page)
            }
            let remainingValues = metrics.compactMap { $0.remainingPercent }
            let minRemaining = remainingValues.min()
            let status: StatusLevel = (minRemaining ?? 100) < 15 ? .warning : .ok
            var details = metrics.map { $0.description }
            details.append("来源: \(page.source)")
            details.append(confirmation)
            let progress = metrics.compactMap { metric -> QuotaProgress? in
                guard let remaining = metric.remainingPercent else { return nil }
                let detail = metric.reset ?? metric.value
                return QuotaProgress(
                    label: metric.label,
                    percent: remaining,
                    valueText: "\(Formatters.percentCompact(remaining))% 剩余",
                    detail: detail
                )
            }
            return QuotaCard(
                provider: kind.providerName,
                headline: minRemaining.map { "最低 \(Formatters.percent($0))% 剩余" } ?? "已读取",
                details: details,
                status: status,
                remainingUSD: nil,
                statusBarHint: minRemaining.map { "\(Int($0.rounded()))%" },
                progress: progress,
                confirmedAt: confirmedAt
            )
        case .claude:
            let metrics = BrowserUsageParser.parseClaude(lines: page.lines)
            guard !metrics.isEmpty else {
                return notParsedCard(kind, page: page)
            }
            let usedValues = metrics.compactMap { $0.usedPercent }
            let maxUsed = usedValues.max()
            let status: StatusLevel = (maxUsed ?? 0) > 85 ? .warning : .ok
            var details = metrics.map { $0.description }
            details.append("来源: \(page.source)")
            details.append(confirmation)
            let progress = metrics.compactMap { metric -> QuotaProgress? in
                guard let used = metric.usedPercent else { return nil }
                let remaining = max(0, 100 - used)
                let detailParts = [
                    "\(Formatters.percentCompact(used))% used",
                    metric.reset
                ].compactMap { $0 }
                return QuotaProgress(
                    label: metric.label,
                    percent: remaining,
                    valueText: "\(Formatters.percentCompact(remaining))% 剩余",
                    detail: detailParts.isEmpty ? metric.value : detailParts.joined(separator: " · ")
                )
            }
            let minRemaining = progress.map(\.clampedPercent).min()
            return QuotaCard(
                provider: kind.providerName,
                headline: maxUsed.map { "最高 \(Formatters.percent($0))% used" } ?? "已读取",
                details: details,
                status: status,
                remainingUSD: nil,
                statusBarHint: minRemaining.map { "\(Int($0.rounded()))%" },
                progress: progress,
                confirmedAt: progress.isEmpty ? nil : confirmedAt
            )
        }
    }

    private static func notParsedCard(_ kind: ChromeTargetKind, page: BrowserTextPage) -> QuotaCard {
        QuotaCard(
            provider: kind.providerName,
            headline: "页面已打开，未解析到额度",
            details: ["URL: \(page.url ?? "未知")", "来源: \(page.source)", continuityNote],
            status: .warning,
            remainingUSD: nil,
            statusBarHint: nil
        )
    }
}

// MARK: - `--browser-diagnostics` CLI

enum BrowserDiagnosticsCommand {
    static let budgetSeconds: TimeInterval = 60

    /// 退出码：0 已选中实例并完成枚举；1 未选中实例（未运行 / 只有自动化 / 多个普通 / 无法确认）；
    /// 2 枚举失败；3 `--read` 时有目标未就绪或读取失败。
    static func run(
        arguments: [String],
        dependencies: ChromeQuotaReadService.Dependencies = ChromeQuotaReadService.Dependencies(),
        output: (String) -> Void = { print($0) }
    ) -> Int32 {
        let readPages = arguments.contains("--read")
        var out: [String] = []
        out.append("\(appName) Browser Diagnostics \(appVersion)")
        out.append("时间: \(Formatters.date(Date()))")
        out.append(readPages
            ? "模式: 枚举 + 就绪判断 + 读取已匹配额度页（不 reload；只执行 loading 检查、就绪探针与 innerText 读取并解析，不输出正文）"
            : "模式: 仅枚举（不 reload、不执行任何页面 JavaScript、不读取正文）")
        out.append("")

        let decision = ChromeInstanceDiscovery.decide(candidates: dependencies.discover())
        out.append("候选 Chrome 主进程 (\(ChromeInstanceIdentity.bundleIdentifier)): \(decision.reports.count)")
        out.append(contentsOf: decision.candidateLines.map { "  \($0)" })
        out.append("选择: \(decision.selectionLine)")

        guard let identity = decision.selectedIdentity else {
            out.append(contentsOf: decision.failureLines.map { "  \($0)" })
            out.append("Apple Events 计数: 0（未发送任何事件）")
            out.append("退出码: 1")
            output(out.joined(separator: "\n"))
            return 1
        }

        var line = "Apple Events 目标: typeKernelProcessID(kpid) → PID \(identity.pid)（内核启动 \(identity.startTime)"
        if let launchDate = identity.launchDate {
            line += " · LS 启动 \(Formatters.date(launchDate))"
        }
        line += "） · \(identity.bundleURL.path)"
        out.append(line)

        let budget = ChromeReadBudget(clock: dependencies.clock, seconds: dependencies.watchdogSecondsOverride ?? budgetSeconds)
        let transport = dependencies.makeTransport(identity, budget)
        var exitCode: Int32 = 0
        defer {
            let counts = transport.eventCounts
            if counts.isEmpty {
                out.append("Apple Events 计数: 0（未发送任何事件）")
            } else {
                out.append("Apple Events 计数: " + counts.keys.sorted().map { "\($0) ×\(counts[$0] ?? 0)" }.joined(separator: ", ") + "（全部发往 PID \(identity.pid)）")
                out.append(contentsOf: transport.eventLog.map { "  \($0)" })
            }
            out.append("退出码: \(exitCode)")
            output(out.joined(separator: "\n"))
        }

        do {
            try transport.verifyIdentity()
            out.append("身份核验: 通过（内核启动时间 + bundle 路径精确一致）")
        } catch {
            out.append("身份核验: 失败 — \(error.localizedDescription)")
            exitCode = 2
            return exitCode
        }

        let snapshot: ChromeTabSnapshot
        do {
            snapshot = try ChromeSnapshotter.snapshot(transport, budget: budget)
        } catch {
            out.append("枚举失败: \(error.localizedDescription)")
            exitCode = 2
            return exitCode
        }

        let targets = snapshot.tabs.compactMap { tab in
            ChromeTargetKind.kind(for: tab.url).map { (kind: $0, tab: tab) }
        }
        let codexCount = targets.filter { $0.kind == .codex }.count
        let claudeCount = targets.filter { $0.kind == .claude }.count
        out.append("枚举: 窗口 \(snapshot.windowCount) · 标签 \(snapshot.tabs.count) · 额度页目标 \(targets.count)（codex \(codexCount) / claude \(claudeCount)）· 窗口枚举错误 \(snapshot.windowErrors.count)")
        out.append(contentsOf: snapshot.windowErrors.map { "  窗口错误: \($0)" })
        out.append(contentsOf: targets.map { "  匹配: \($0.kind.rawValue) · window id \($0.tab.windowID) · tab id \($0.tab.tabID) · \($0.tab.url)" })
        if targets.isEmpty {
            out.append("  （没有匹配的额度页标签；其它标签不列出）")
        }

        if readPages {
            var failures = 0
            for target in targets {
                do {
                    try transport.verifyIdentity()
                    let url = try transport.tabURL(windowID: target.tab.windowID, tabID: target.tab.tabID)
                    guard ChromeTargetKind.kind(for: url) == target.kind else {
                        out.append("读取: \(target.kind.rawValue) tab \(target.tab.tabID) → 跳过（复核时已不是额度页）")
                        continue
                    }
                    if try transport.tabLoading(windowID: target.tab.windowID, tabID: target.tab.tabID) {
                        failures += 1
                        out.append("读取: \(target.kind.rawValue) tab \(target.tab.tabID) → 未就绪（tab 仍在 loading），不读取")
                        continue
                    }
                    let probe = try transport.executeJavaScript(
                        windowID: target.tab.windowID,
                        tabID: target.tab.tabID,
                        script: target.kind.probeScript,
                        purpose: .probe
                    )
                    guard probe == "1" else {
                        failures += 1
                        out.append("读取: \(target.kind.rawValue) tab \(target.tab.tabID) → 未就绪（readyState 未 complete 或没有已支持的额度字段），不读取")
                        continue
                    }
                    let text = try transport.executeJavaScript(
                        windowID: target.tab.windowID,
                        tabID: target.tab.tabID,
                        script: ChromePageScripts.readScript,
                        purpose: .read
                    )
                    let lines = LineTools.normalize([text], deduplicate: false)
                    let descriptions: [String]
                    switch target.kind {
                    case .codex: descriptions = BrowserUsageParser.parseCodex(lines: lines).map(\.description)
                    case .claude: descriptions = BrowserUsageParser.parseClaude(lines: lines).map(\.description)
                    }
                    out.append("读取: \(target.kind.rawValue) tab \(target.tab.tabID) → 就绪，读取成功，\(lines.count) 行；解析 \(descriptions.count) 项")
                    out.append(contentsOf: descriptions.map { "    \($0)" })
                } catch {
                    failures += 1
                    out.append("读取: \(target.kind.rawValue) tab \(target.tab.tabID) → 失败 — \(error.localizedDescription)")
                    if let chromeError = error as? ChromeEventError, chromeError.isFatal {
                        out.append("致命错误，终止后续读取。")
                        break
                    }
                }
            }
            if failures > 0 {
                exitCode = 3
            }
        } else {
            out.append("本诊断未 reload、未执行页面 JavaScript。真实读取: `--print-snapshot`（按配置 reload 后读取）或 `--browser-diagnostics --read`（不 reload，先就绪判断再读取并解析已匹配页）。")
        }
        return exitCode
    }
}
