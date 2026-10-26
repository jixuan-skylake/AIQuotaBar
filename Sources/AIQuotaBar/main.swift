import AppKit
import ApplicationServices
import Darwin
import Foundation
import Security

let appName = "AIQuotaBar"
/// 0.2.14 / build 16：Chrome 读取改为按已验证 PID 定址的原生 Apple Events（ChromeInstances.swift / ChromeAppleEvents.swift / ChromeQuotaReader.swift）。
/// 0.2.15 / build 17：只做 Codex 额度页地址适配（`BrowserUsageTargets`）——默认地址改为 `/settings/usage?tab=overview`，
/// 旧的 `/codex/cloud/settings/analytics` 继续兼容；实例定址、逐事件身份、预算、稳定 ID、解析口径与节能行为都未改动。
/// 0.2.16 / build 18：只做 Claude 新中文用量页的解析兼容——`BrowserUsageParser` 的 Claude 口径与
/// `ChromePageScripts` 的 Claude 就绪探针改为同一条有界正则：新增前缀式「已使用 0%」，新中文标题「本周」
/// 精确映射既有内部标识 `All models`（用户已选的 allModels 档不受影响），「本周 Fable」是另一个栏目、
/// 不冒充总周额度。Codex 口径、实例定址、逐事件身份、预算、稳定 ID、节能行为与签名均未改动。
/// 　├ 正式整改 1/3（2026-10-11 独立审查）：标题到百分比之间取消「任意说明行 + 已知标题黑名单」，
/// 　│ 改成「空白 + 完整字面量白名单（已知说明 / 已知重置）」的定长槽位。修掉前导空白回溯绕过边界
/// 　│ （含 ICU/JSC 两端分叉）与任意说明行吞掉非法字段 / 未知标题两个洞；详见 `BrowserUsageParser`
/// 　│ 里的「Claude 用量契约」注释与 dist/CLAUDE-USAGE-R1-RESULT-20261011.md。版本号不变。
/// 0.2.17 / build 19：只修 Codex 中文倒计时**字段内部**的空白——2026-10-11 截图写成「6天15小时 后重置」，
/// 单位与「后重置」之间多了一处空白，0.2.16 要求两者相连，于是周额度字段两端一起失配（解析为空 + 探针 0）。
/// 现在数字 ↔ 单位 ↔「后重置」之间允许归一化空白（含 DOM 换行），字面量与数字位数不变；展示用重置压成单行。
/// Claude 口径、周额度其余判据、网址契约、实例定址、预算与节能行为均未改动。
/// 0.2.18 / build 20：只做 Claude 2026-10-26 新布局的局部兼容 + 一处错指标修复。
/// 　├ 解析 / 就绪两端（仍共用同一条正则与同一套归一化）只登记三处新写法：总周额度全称标题
/// 　│ 「每周限额 · 所有模型」（仍映射内部 `All models`，只放宽「·」分隔符两侧的空白）、中文复合倒计时
/// 　│ 「1小时 37 分钟后重置」（天 → 小时 → 分钟的合法降序，放宽只在词元边界）、星期简称「周一」；
/// 　│ 外加「标题之后」一个可选的图标白名单：首项 `U+E02A` 是 Root 真实页面实测的字符
/// 　│ （正式整改 1/3，初稿缺它导致真实页上总周额度只有标题没有数值），其余四个箭头是有限兼容。
/// 　│ 未登记的正文 / 字符一律 fail closed。
/// 　└ `Snapshot.claudeHint` 取消 `?? card.statusBarHint` 回退：选中的 Claude 指标无值时返回 nil、
/// 　  双行 A/C 模式显示 `--`（只显示 Claude / 最低额度两档维持既有的 `AI` / `AI !`），
/// 　  不再把别的指标的数当成它。Codex 的口径与回退行为一个字符都没改；
/// 　  网址契约、实例定址、逐事件身份、预算、稳定 ID、reload / 就绪等待与节能行为均未改动。
let appVersion = "0.2.18"
private let keychainService = "AIQuotaBar"

struct AppConfig: Codable {
    struct MonthlyBudgetsUSD: Codable {
        var openAI: Double?
        var anthropic: Double?
    }

    struct Paths: Codable {
        var codexStateSQLite: String
        var claudeApplicationSupport: String
        var claudeProjects: String?
    }

    struct Sources: Codable {
        var openAICosts: Bool
        var anthropicCosts: Bool
        var codexLocalUsage: Bool
        var claudeDesktopPresence: Bool
        var chromeBrowserUsage: Bool?
        var claudeCodeLocalUsage: Bool?
    }

    var refreshIntervalSeconds: Double
    var monthlyBudgetsUSD: MonthlyBudgetsUSD
    var paths: Paths
    var sources: Sources
    var browserReloadBeforeRead: Bool?
    var browserReloadWaitSeconds: Double?
    var browserReloadTimeoutSeconds: Double?

    static let defaultValue = AppConfig(
        refreshIntervalSeconds: 300,
        monthlyBudgetsUSD: MonthlyBudgetsUSD(openAI: nil, anthropic: nil),
        paths: Paths(
            codexStateSQLite: "~/.codex/state_5.sqlite",
            claudeApplicationSupport: "~/Library/Application Support/Claude",
            claudeProjects: "~/.claude/projects"
        ),
        sources: Sources(
            openAICosts: false,
            anthropicCosts: false,
            codexLocalUsage: true,
            claudeDesktopPresence: false,
            chromeBrowserUsage: true,
            claudeCodeLocalUsage: true
        ),
        browserReloadBeforeRead: true,
        browserReloadWaitSeconds: 2,
        browserReloadTimeoutSeconds: 30
    )
}

enum StatusLevel: String, Codable {
    case ok
    case warning
    case unavailable
    case error

    var menuPrefix: String {
        switch self {
        case .ok: return "[OK]"
        case .warning: return "[WARN]"
        case .unavailable: return "[SETUP]"
        case .error: return "[ERR]"
        }
    }
}

struct QuotaProgress {
    let label: String
    let percent: Double
    let valueText: String
    let detail: String?

    var clampedPercent: Double {
        min(100, max(0, percent))
    }
}

struct QuotaCard {
    let provider: String
    let headline: String
    let details: [String]
    let status: StatusLevel
    let remainingUSD: Double?
    let statusBarHint: String?

    let progress: [QuotaProgress]
    /// 只有满足新鲜值契约（reload 成功 + 就绪确认 + 读取成功 + 解析到额度）的网页卡片才有值；
    /// AppDelegate 的沿用逻辑只信任它，reload 失败 / 未就绪 / 看门狗 / 身份失效 / 权限失败的卡片永远为 nil。
    let confirmedAt: Date?
    /// 面板在标题下方额外显示的一行（沿用上次成功值时说明本次失败原因，避免被进度条吞掉）。
    let note: String?

    init(
        provider: String,
        headline: String,
        details: [String],
        status: StatusLevel,
        remainingUSD: Double?,
        statusBarHint: String?,
        progress: [QuotaProgress] = [],
        confirmedAt: Date? = nil,
        note: String? = nil
    ) {
        self.provider = provider
        self.headline = headline
        self.details = details
        self.status = status
        self.remainingUSD = remainingUSD
        self.statusBarHint = statusBarHint
        self.progress = progress
        self.confirmedAt = confirmedAt
        self.note = note
    }
}

enum QuotaMood: Equatable {
    case happy
    case steady
    case worried
    case urgent
    case unknown

    static func from(remainingPercents: [Double], hasError: Bool) -> QuotaMood {
        if hasError {
            return .urgent
        }
        guard let lowest = remainingPercents.min() else {
            return .unknown
        }
        if lowest < 15 {
            return .urgent
        }
        if lowest < 40 {
            return .worried
        }
        if lowest < 70 {
            return .steady
        }
        return .happy
    }

    var accessibilityLabel: String {
        switch self {
        case .happy: return "额度充足"
        case .steady: return "额度正常"
        case .worried: return "额度偏低"
        case .urgent: return "额度紧张"
        case .unknown: return "额度未知"
        }
    }
}

enum StatusDisplayMode: String, CaseIterable {
    case split
    case lowest
    case claude
    case codex

    private static let defaultsKey = "statusDisplayMode"

    static func load() -> StatusDisplayMode {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let mode = StatusDisplayMode(rawValue: raw) else {
            return .split
        }
        return mode
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }

    var menuTitle: String {
        switch self {
        case .split: return "双行 A/C"
        case .lowest: return "最低额度"
        case .claude: return "只显示 Claude"
        case .codex: return "只显示 Codex"
        }
    }
}

enum CodexStatusMetric: String, CaseIterable {
    case weekly

    private static let defaultsKey = "codexStatusMetric"

    static func load() -> CodexStatusMetric {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let metric = CodexStatusMetric(rawValue: raw) else {
            return .weekly
        }
        return metric
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }

    var label: String {
        switch self {
        case .weekly: return "每周使用限额"
        }
    }

    var menuTitle: String {
        switch self {
        case .weekly: return "Codex: 每周使用限额"
        }
    }
}

enum ClaudeStatusMetric: String, CaseIterable {
    case currentSession
    case allModels
    case claudeDesign

    private static let defaultsKey = "claudeStatusMetric"

    static func load() -> ClaudeStatusMetric {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let metric = ClaudeStatusMetric(rawValue: raw) else {
            return .allModels
        }
        return metric
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }

    var label: String {
        switch self {
        case .currentSession: return "Current session"
        case .allModels: return "All models"
        case .claudeDesign: return "Claude Design"
        }
    }

    var menuTitle: String {
        switch self {
        case .currentSession: return "Claude: Current Session"
        case .allModels: return "Claude: All Models"
        case .claudeDesign: return "Claude: Claude Design"
        }
    }
}

struct Snapshot {
    let updatedAt: Date
    let cards: [QuotaCard]
    /// 浏览器实例诊断行（候选 PID、选择结果、阶段错误、事件计数）：只进 CLI 输出，菜单面板不显示。
    var diagnosticsLines: [String] = []

    var statusTitle: String {
        statusTitle(mode: .split, codexMetric: .weekly, claudeMetric: .allModels)
    }

    func codexHint(metric: CodexStatusMetric) -> String? {
        hint(provider: "Codex 网页额度", label: metric.label)
            ?? cards.first { $0.provider == "Codex 网页额度" }?.statusBarHint
    }

    /// 0.2.18：状态栏的 Claude 档位只认**被选中的那一个指标**。这一栏没有数值就返回 nil。
    /// nil 的呈现按各档既有的 UI 行为：**双行 A/C** 档显示 `--`（`makeSplitStatusImage` 里的
    /// `claude ?? "--"`）；「只显示 Claude」与「最低额度」两档维持原样，退回 `AI`（有错误卡片时 `AI !`）。
    /// 原先的回退 `?? card.statusBarHint` 已删除：那是「所有指标里最低的剩余」，
    /// 选了 All models 而这一栏缺值时会把 Current session 的数显示出来 —— 一个看着正常的错指标。
    /// Codex 只有 weekly 一个档位（解析器产出的标签恒等于它，回退实际取不到），那边本轮不动。
    func claudeHint(metric: ClaudeStatusMetric) -> String? {
        hint(provider: "Claude 网页额度", label: metric.label)
    }

    func statusTitle(mode: StatusDisplayMode, codexMetric: CodexStatusMetric, claudeMetric: ClaudeStatusMetric) -> String {
        let codexHint = codexHint(metric: codexMetric)
        let claudeHint = claudeHint(metric: claudeMetric)

        switch mode {
        case .split:
            let claude = claudeHint ?? "--"
            let codex = codexHint ?? "--"
            return "A \(claude) · C \(codex)"
        case .lowest:
            if let lowest = lowestHint(codexMetric: codexMetric, claudeMetric: claudeMetric) {
                return "AI \(lowest)"
            }
        case .claude:
            if let claudeHint {
                return "A \(claudeHint)"
            }
        case .codex:
            if let codexHint {
                return "C \(codexHint)"
            }
        }

        if cards.contains(where: { $0.status == .error }) {
            return "AI !"
        }

        return "AI"
    }

    func statusMood(mode: StatusDisplayMode, codexMetric: CodexStatusMetric, claudeMetric: ClaudeStatusMetric) -> QuotaMood {
        let codexValue = Self.percentValue(from: codexHint(metric: codexMetric))
        let claudeValue = Self.percentValue(from: claudeHint(metric: claudeMetric))
        let values: [Double]

        switch mode {
        case .split, .lowest:
            values = [claudeValue, codexValue].compactMap { $0 }
        case .claude:
            values = [claudeValue].compactMap { $0 }
        case .codex:
            values = [codexValue].compactMap { $0 }
        }

        return QuotaMood.from(
            remainingPercents: values,
            hasError: cards.contains(where: { $0.status == .error })
        )
    }

    private func lowestHint(codexMetric: CodexStatusMetric, claudeMetric: ClaudeStatusMetric) -> String? {
        let values = [
            ("A", claudeHint(metric: claudeMetric)),
            ("C", codexHint(metric: codexMetric))
        ].compactMap { label, hint -> (String, String, Double)? in
            guard let hint, let value = Self.percentValue(from: hint) else { return nil }
            return (label, hint, value)
        }
        return values.min { $0.2 < $1.2 }.map { "\($0.0) \($0.1)" }
    }

    private func hint(provider: String, label: String) -> String? {
        guard let card = cards.first(where: { $0.provider == provider }),
              let progress = card.progress.first(where: { $0.label == label }) else {
            return nil
        }
        return "\(Int(progress.clampedPercent.rounded()))%"
    }

    private static func percentValue(from hint: String?) -> Double? {
        guard let hint else { return nil }
        let cleaned = hint.replacingOccurrences(of: "%", with: "")
        return Double(cleaned.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum Formatters {
    static let integer: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    static let oneDecimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    static let menuDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    static func integer(_ value: Int64) -> String {
        integer.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func money(_ value: Double) -> String {
        "$" + String(format: "%.2f", value)
    }

    static func compactMoney(_ value: Double) -> String {
        if abs(value) >= 1000 {
            return "$" + String(format: "%.1fK", value / 1000)
        }
        if abs(value) >= 100 {
            return "$" + String(format: "%.0f", value)
        }
        return "$" + String(format: "%.2f", value)
    }

    static func compactNumber(_ value: Int64) -> String {
        if abs(value) >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if abs(value) >= 1_000 {
            return String(format: "%.0fK", Double(value) / 1_000)
        }
        return "\(value)"
    }

    static func percent(_ value: Double) -> String {
        oneDecimal.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }

    static func percentCompact(_ value: Double) -> String {
        if value.rounded() == value {
            return "\(Int(value))"
        }
        return percent(value)
    }

    static let menuClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    static func date(_ date: Date) -> String {
        menuDate.string(from: date)
    }

    static func clock(_ date: Date) -> String {
        menuClock.string(from: date)
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

enum VisualizationStyle: String {
    case bars
    case rings

    private static let defaultsKey = "visualizationStyle"

    static func load() -> VisualizationStyle {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let style = VisualizationStyle(rawValue: raw) else {
            return .bars
        }
        return style
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }

    var menuTitle: String {
        switch self {
        case .bars: return "长条"
        case .rings: return "圆环"
        }
    }
}

enum RefreshCadence: String, CaseIterable {
    case oneMinute
    case threeMinutes
    case fiveMinutes
    case tenMinutes

    private static let defaultsKey = "refreshCadence"

    /// 0.2.13 起默认 5 分钟（原 3 分钟）。已经保存过 1/3/5/10 分钟选择的用户不受影响。
    static func load() -> RefreshCadence {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let cadence = RefreshCadence(rawValue: raw) else {
            return .fiveMinutes
        }
        return cadence
    }

    static var hasStoredPreference: Bool {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey) else { return false }
        return RefreshCadence(rawValue: raw) != nil
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }

    var seconds: TimeInterval {
        switch self {
        case .oneMinute: return 60
        case .threeMinutes: return 180
        case .fiveMinutes: return 300
        case .tenMinutes: return 600
        }
    }

    var menuTitle: String {
        switch self {
        case .oneMinute: return "每 1 分钟刷新"
        case .threeMinutes: return "每 3 分钟刷新"
        case .fiveMinutes: return "每 5 分钟刷新"
        case .tenMinutes: return "每 10 分钟刷新"
        }
    }
}

/// 节能模式：默认开启。开启时低电量模式下自动刷新至少 10 分钟一次，
/// 系统睡眠 / 屏幕关闭期间暂停自动刷新，唤醒后只在真正过期时补一次。
enum PowerSavingSetting {
    private static let defaultsKey = "powerSavingEnabled"

    /// 默认 true；只有用户显式关闭过才是 false。
    static func load() -> Bool {
        guard UserDefaults.standard.object(forKey: defaultsKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static func save(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: defaultsKey)
    }

    /// 低电量模式下自动刷新的最小间隔。
    static let lowPowerMinimumInterval: TimeInterval = 600
}

/// 自动刷新的纯策略：不依赖 AppKit / 计时器 / 真实时间，可确定性测试。
struct RefreshSchedulerPolicy: Equatable {
    /// 定时器最短延迟，避免手动刷新后立刻又被自动刷新顶上。
    static let minimumDelay: TimeInterval = 15

    var baseInterval: TimeInterval
    var powerSavingEnabled: Bool
    var lowPowerModeEnabled: Bool
    var systemAsleep: Bool
    var screensAsleep: Bool

    init(
        baseInterval: TimeInterval,
        powerSavingEnabled: Bool,
        lowPowerModeEnabled: Bool = false,
        systemAsleep: Bool = false,
        screensAsleep: Bool = false
    ) {
        self.baseInterval = baseInterval
        self.powerSavingEnabled = powerSavingEnabled
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.systemAsleep = systemAsleep
        self.screensAsleep = screensAsleep
    }

    /// 实际生效间隔：节能模式 + 低电量模式时至少 10 分钟（取较大值，不叠加）。
    var effectiveInterval: TimeInterval {
        guard powerSavingEnabled, lowPowerModeEnabled else { return baseInterval }
        return max(baseInterval, PowerSavingSetting.lowPowerMinimumInterval)
    }

    var isLowPowerRelaxed: Bool {
        effectiveInterval > baseInterval
    }

    /// 自动刷新被暂停的原因；nil 表示正常运行。手动刷新不受此限制。
    var pauseReason: String? {
        guard powerSavingEnabled else { return nil }
        if systemAsleep { return "系统睡眠" }
        if screensAsleep { return "屏幕关闭" }
        return nil
    }

    enum Decision: Equatable {
        case paused
        /// 已过期，应该立刻刷新一次。
        case fire
        /// 还没到期，等这么久之后再判断（用于唤醒后不扎堆补刷）。
        case wait(TimeInterval)
    }

    /// 定时器触发 / 系统唤醒时的统一判定，基于「上一次刷新开始时间」。
    func decide(now: Date, lastRefreshStartedAt: Date?) -> Decision {
        if pauseReason != nil { return .paused }
        guard let lastRefreshStartedAt else { return .fire }
        let remaining = effectiveInterval - now.timeIntervalSince(lastRefreshStartedAt)
        if remaining <= 0 { return .fire }
        return .wait(max(Self.minimumDelay, remaining))
    }

    /// 下一次自动刷新的延迟；nil 表示当前应当停表。
    /// 手动刷新会更新 lastRefreshStartedAt，因此自动定时器会自然顺延一个完整间隔。
    func nextDelay(now: Date, lastRefreshStartedAt: Date?) -> TimeInterval? {
        if pauseReason != nil { return nil }
        guard let lastRefreshStartedAt else { return max(Self.minimumDelay, effectiveInterval) }
        let remaining = effectiveInterval - now.timeIntervalSince(lastRefreshStartedAt)
        return max(Self.minimumDelay, remaining)
    }
}

enum RefreshTrigger {
    /// 用户点「立即刷新」：最高优先级，立即重新抓取网页。
    case manual
    /// 定时器 / 唤醒补刷：utility 优先级。
    case automatic
}

enum PathTools {
    static func expandTilde(_ path: String) -> String {
        if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        if path.hasPrefix("~/") {
            let suffix = String(path.dropFirst(2))
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(suffix).path
        }
        return path
    }
}

enum BrowserUsageTargets {
    /// 0.2.15：Codex 默认地址改为用户给的完整地址，菜单「Codex 网页额度」入口与卡片链接都用它。
    static let codexUsageURL = "https://chatgpt.com/settings/usage?tab=overview"
    /// 0.2.14 及以前的 Codex 地址：仍然识别（已经开着的旧标签照样能读），但不再作为默认打开地址。
    static let codexLegacyUsageURL = "https://chatgpt.com/codex/cloud/settings/analytics"
    static let claudeUsageURL = "https://claude.ai/new#settings/usage"

    private static let codexUsagePath = "/settings/usage"
    private static let codexLegacyUsagePath = "/codex/cloud/settings/analytics"
    /// 新地址唯一接受的 tab 值；query 值按 RFC 3986 是大小写敏感的，所以这里精确比较（`Overview` 不接受）。
    private static let codexOverviewTab = "overview"

    /// 严格网址契约（0.2.14 R1 建立，0.2.15 扩到 Codex 新地址）：用 URLComponents 校验 scheme 必须是 https、
    /// 不能带用户信息或端口、host 与 path 精确匹配（允许尾斜杠）；嵌在其它主机 / 路径 / query 里的字样一律拒绝。
    /// Claude 新地址 `/new` 还要求 fragment 精确为 `settings/usage`（允许真实的 `/new?redirect=…#settings/usage`），
    /// 旧地址 `/settings/usage` 仍接受。
    /// 目标识别与操作前的 URL 复核（ChromeTargetKind.kind(for:)）共用这两个函数。
    static func isCodexUsageURL(_ url: String?) -> Bool {
        guard let components = strictComponents(url, host: "chatgpt.com") else { return false }
        switch normalizedPath(components.path) {
        case codexUsagePath:
            // 新地址：path 之外还要过 tab 策略，避免把非 overview 子页当额度页去 reload / 读取。
            return acceptsCodexOverviewTab(components)
        case codexLegacyUsagePath:
            // 旧 Codex Cloud analytics 地址：沿用 0.2.14 语义，query 完全不参与匹配
            // （该页的 `?tab=weekly` 是它自己的合法值，不能套用新地址的 overview 策略）。
            return true
        default:
            return false
        }
    }

    static func isClaudeUsageURL(_ url: String?) -> Bool {
        guard let components = strictComponents(url, host: "claude.ai") else { return false }
        let path = normalizedPath(components.path)
        if path == "/settings/usage" {
            return true
        }
        if path == "/new" {
            return normalizedFragment(components.fragment) == "settings/usage"
        }
        return false
    }

    /// Codex 新地址 `/settings/usage` 的 tab 策略（0.2.15，唯一的新判据）：
    /// - 没有 tab 参数（含 `?` 这种空 query）→ 接受：该页默认停在 overview；
    /// - 恰好一个 tab 参数且值精确为 `overview` → 接受；
    /// - 其它 tab 值、空值（`?tab=`）、无值（`?tab`）、以及出现多次的 tab（即使都是 overview）→ 拒绝：
    ///   此时无法确定页面当前停在哪个子页，宁可本轮不读，也不刷新非 overview 页面；
    /// - 其它查询参数（`utm_source`、`ref` 之类）一律忽略，不影响判定；
    ///   fragment 同样不参与判定（与旧地址接受 `#top` 一致，站点用 query 而不是 fragment 选 tab）。
    /// 参数名取 `queryItems` 的解码结果并按大小写不敏感比较，`?%74ab=billing`、`?TAB=billing` 这类混淆名也会被拒绝；
    /// 参数值取解码结果精确比较，所以等价编码 `?tab=over%76iew` 接受，`?tab=overview%20`（尾部空格）拒绝。
    private static func acceptsCodexOverviewTab(_ components: URLComponents) -> Bool {
        guard let items = components.queryItems, !items.isEmpty else { return true }
        let tabItems = items.filter { $0.name.lowercased() == "tab" }
        if tabItems.isEmpty { return true }
        guard tabItems.count == 1, let value = tabItems[0].value else { return false }
        return value == codexOverviewTab
    }

    private static func strictComponents(_ url: String?, host: String) -> URLComponents? {
        guard let url, let components = URLComponents(string: url) else { return nil }
        guard components.scheme?.lowercased() == "https" else { return nil }
        guard components.user == nil, components.password == nil, components.port == nil else { return nil }
        guard components.host?.lowercased() == host else { return nil }
        return components
    }

    private static func normalizedPath(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func normalizedFragment(_ fragment: String?) -> String? {
        guard let fragment else { return nil }
        return fragment.hasSuffix("/") ? String(fragment.dropLast()) : fragment
    }
}

final class ConfigStore {
    let configURL: URL
    let applicationSupportURL: URL

    init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(appName, isDirectory: true)
        applicationSupportURL = support

        if let override = ProcessInfo.processInfo.environment["AIQUOTABAR_CONFIG"], !override.isEmpty {
            configURL = URL(fileURLWithPath: PathTools.expandTilde(override))
        } else {
            configURL = support.appendingPathComponent("config.json")
        }
    }

    func loadOrCreate() -> AppConfig {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: applicationSupportURL, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: configURL.path) {
                try write(AppConfig.defaultValue)
            }

            let data = try Data(contentsOf: configURL)
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            try? write(AppConfig.defaultValue)
            return AppConfig.defaultValue
        }
    }

    func write(_ config: AppConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try FileManager.default.createDirectory(at: applicationSupportURL, withIntermediateDirectories: true)
        try data.write(to: configURL, options: [.atomic])
    }

    func openConfigFile() {
        _ = loadOrCreate()
        NSWorkspace.shared.open(configURL)
    }
}

enum KeychainStore {
    static func readSecret(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: kCFBooleanTrue as Any
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func secret(account: String) -> String? {
        if let fromKeychain = readSecret(account: account), !fromKeychain.isEmpty {
            return fromKeychain
        }
        let environment = ProcessInfo.processInfo.environment
        if let fromEnvironment = environment[account], !fromEnvironment.isEmpty {
            return fromEnvironment
        }
        return nil
    }
}

enum Shell {
    struct ShellError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 并发排空 stdout/stderr，再等待子进程退出。
    /// 旧实现先 waitUntilExit() 再读管道，输出超过管道缓冲(64KB)时子进程会阻塞在 write，父进程阻塞在 wait，形成死锁。
    /// `timeout` 为可选看门狗（一次性 asyncAfter，不是轮询），超时后 SIGTERM 子进程，避免刷新任务永久挂起。
    static func run(_ executable: String, arguments: [String], timeout: TimeInterval? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        // 两个读取线程在 waitUntilExit 之前启动并持续排空管道。
        let group = DispatchGroup()
        let drainQueue = DispatchQueue(label: "com.local.aiquotabar.shell.drain", attributes: .concurrent)
        var outData = Data()
        var errData = Data()
        group.enter()
        drainQueue.async {
            outData = stdout.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        drainQueue.async {
            errData = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let timedOut = TimeoutFlag()
        var watchdog: DispatchWorkItem?
        if let timeout, timeout > 0 {
            let item = DispatchWorkItem {
                guard process.isRunning else { return }
                timedOut.set()
                process.terminate()
            }
            watchdog = item
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: item)
        }

        process.waitUntilExit()
        watchdog?.cancel()
        group.wait()

        let output = String(data: outData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errData, encoding: .utf8) ?? ""

        if timedOut.value {
            throw ShellError(message: "命令超时(\(Int(timeout ?? 0))s)已终止: \(executable)")
        }

        guard process.terminationStatus == 0 else {
            let message = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ShellError(message: message.isEmpty ? "命令退出码 \(process.terminationStatus)" : message)
        }

        return output
    }

    private final class TimeoutFlag {
        private let lock = NSLock()
        private var flag = false
        func set() {
            lock.lock(); flag = true; lock.unlock()
        }
        var value: Bool {
            lock.lock(); defer { lock.unlock() }
            return flag
        }
    }
}

enum HTTPClient {
    struct HTTPError: Error, LocalizedError {
        let statusCode: Int
        let body: String

        var errorDescription: String? {
            if body.isEmpty {
                return "HTTP \(statusCode)"
            }
            return "HTTP \(statusCode): \(body.prefix(160))"
        }
    }

    static func json(url: URL, headers: [String: String]) async throws -> Any {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("\(appName)/\(appVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw HTTPError(statusCode: http.statusCode, body: body)
        }
        return try JSONSerialization.jsonObject(with: data)
    }
}

enum JSONTools {
    static func double(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? Int {
            return Double(value)
        }
        if let value = value as? Int64 {
            return Double(value)
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        if let value = value as? String {
            return Double(value)
        }
        return nil
    }

    static func resultArrays(in bucket: [String: Any]) -> [[String: Any]] {
        if let results = bucket["results"] as? [[String: Any]] {
            return results
        }
        if let results = bucket["result"] as? [[String: Any]] {
            return results
        }
        if let result = bucket["result"] as? [String: Any] {
            return [result]
        }
        return []
    }
}

enum DateTools {
    static func monthRange() -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.year, .month], from: now)
        let start = calendar.date(from: components) ?? now
        return (start, now)
    }

    static func startOfTodayMilliseconds() -> Int64 {
        let start = Calendar.current.startOfDay(for: Date())
        return Int64(start.timeIntervalSince1970 * 1000)
    }

    static func startOfToday() -> Date {
        Calendar.current.startOfDay(for: Date())
    }

    static func startOfSevenDayWindowMilliseconds() -> Int64 {
        let startToday = Calendar.current.startOfDay(for: Date())
        let start = Calendar.current.date(byAdding: .day, value: -6, to: startToday) ?? startToday
        return Int64(start.timeIntervalSince1970 * 1000)
    }

    static func startOfSevenDayWindow() -> Date {
        let startToday = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .day, value: -6, to: startToday) ?? startToday
    }

    /// 本地日历「今天 0 点」。与旧实现同语义，但允许注入 calendar/now 以便确定性测试。
    static func startOfToday(calendar: Calendar, now: Date) -> Date {
        calendar.startOfDay(for: now)
    }

    /// 本地日历「今天 + 前 6 天」窗口起点（不是 168 小时滚动窗口）。与旧实现同语义。
    static func startOfSevenDayWindow(calendar: Calendar, now: Date) -> Date {
        let startToday = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -6, to: startToday) ?? startToday
    }
}

struct BrowserTextPage: Equatable {
    let url: String?
    let lines: [String]
    let source: String
}

enum LineTools {
    static func normalize(_ values: [String], deduplicate: Bool = true) -> [String] {
        var seen = Set<String>()
        var lines: [String] = []

        for value in values {
            for raw in value.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard isUseful(line) else { continue }
                if deduplicate {
                    guard !seen.contains(line) else { continue }
                    seen.insert(line)
                }
                lines.append(line)
            }
        }

        return lines
    }

    static func isUseful(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 12_000 else { return false }
        return true
    }
}

// MARK: - Claude Code 本机 token 统计（跨刷新的进程内缓存）

/// 单条 message.usage 的四个 token 计数。语义与 0.2.12 完全一致：合计为 0 视为无效事件。
struct ClaudeCodeUsage {
    let input: Int64
    let output: Int64
    let cacheCreation: Int64
    let cacheRead: Int64

    var total: Int64 {
        input + output + cacheCreation + cacheRead
    }

    init?(json: [String: Any]) {
        input = Self.int64(json["input_tokens"])
        output = Self.int64(json["output_tokens"])
        cacheCreation = Self.int64(json["cache_creation_input_tokens"])
        cacheRead = Self.int64(json["cache_read_input_tokens"])
        if total <= 0 { return nil }
    }

    static func int64(_ value: Any?) -> Int64 {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? Double { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) ?? 0 }
        return 0
    }
}

/// 「今天」或「近 7 天」窗口的汇总。sessions 是跨文件去重的集合，与旧版一致。
struct ClaudeCodeUsagePeriod {
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheCreation: Int64 = 0
    var cacheRead: Int64 = 0
    var messageCount = 0
    var sessions = Set<String>()

    var total: Int64 {
        input + output + cacheCreation + cacheRead
    }

    var cacheTotal: Int64 {
        cacheCreation + cacheRead
    }

    var sessionCount: Int {
        sessions.count
    }

    mutating func merge(_ bucket: ClaudeCodeDayBucket) {
        input += bucket.input
        output += bucket.output
        cacheCreation += bucket.cacheCreation
        cacheRead += bucket.cacheRead
        messageCount += bucket.messageCount
        sessions.formUnion(bucket.sessions)
    }
}

struct ClaudeCodeUsageStats {
    var today = ClaudeCodeUsagePeriod()
    var week = ClaudeCodeUsagePeriod()
    var lastDate: Date?
    var fileCount = 0
}

/// 单个文件在某个「本地日历日」内的汇总。缓存只保存这些聚合数字与 session id，不保存任何聊天正文。
struct ClaudeCodeDayBucket: Codable {
    /// 本地日历当日 0 点的 epoch 秒。
    var dayStart: Int64
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheCreation: Int64 = 0
    var cacheRead: Int64 = 0
    var messageCount: Int = 0
    /// 该文件当日出现过的 session id（同一文件内数量极少，用数组即可）。
    var sessions: [String] = []

    mutating func add(usage: ClaudeCodeUsage, sessionID: String) {
        input += usage.input
        output += usage.output
        cacheCreation += usage.cacheCreation
        cacheRead += usage.cacheRead
        messageCount += 1
        if !sessions.contains(sessionID) {
            sessions.append(sessionID)
        }
    }
}

/// 单个 JSONL 文件的完整缓存内容。
struct ClaudeCodeFileSummary {
    var buckets: [ClaudeCodeDayBucket] = []
    /// 该文件中最新事件的时间；lastDate 统计全历史，不受 7 天窗口限制（与旧版一致）。
    var lastEventEpoch: Double?
    /// 该文件里有行因为超过单行上限而没能解析：结果不是完整成功，必须显式报告。
    var incomplete = false

    mutating func add(usage: ClaudeCodeUsage, sessionID: String, dayStart: Int64, epoch: Double) {
        if lastEventEpoch == nil || epoch > lastEventEpoch! {
            lastEventEpoch = epoch
        }
        if let index = buckets.firstIndex(where: { $0.dayStart == dayStart }) {
            buckets[index].add(usage: usage, sessionID: sessionID)
        } else {
            var bucket = ClaudeCodeDayBucket(dayStart: dayStart)
            bucket.add(usage: usage, sessionID: sessionID)
            buckets.append(bucket)
        }
    }
}

/// 文件身份：设备号 + inode + 大小 + 纳秒级 mtime + 纳秒级 ctime。
/// - 同路径原子替换（size/mtime 都相同）时 inode 会变化。
/// - 原地等长改写后把 mtime 改回旧值时 ctime 仍会前进（ctime 无法被 utimensat 回拨）。
/// - chmod / chown 等权限变化也只体现在 ctime 上，纳入身份后能立刻重新校验可读性。
struct ClaudeCodeFileIdentity: Equatable {
    var device: Int64
    var inode: UInt64
    var size: Int64
    var mtimeSeconds: Int64
    var mtimeNanoseconds: Int64
    var ctimeSeconds: Int64
    var ctimeNanoseconds: Int64
}

struct ClaudeCodeFileStat {
    let isRegular: Bool
    let identity: ClaudeCodeFileIdentity

    /// 用 lstat 而不是 stat：符号链接本身不是普通文件，按旧版 `isRegularFile` 语义整体跳过，
    /// 避免同一个日志文件通过链接被重复统计。
    static func of(path: String) -> ClaudeCodeFileStat? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return ClaudeCodeFileStat(
            isRegular: (info.st_mode & S_IFMT) == S_IFREG,
            identity: ClaudeCodeFileIdentity(
                device: Int64(info.st_dev),
                inode: UInt64(info.st_ino),
                size: Int64(info.st_size),
                mtimeSeconds: Int64(info.st_mtimespec.tv_sec),
                mtimeNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                ctimeSeconds: Int64(info.st_ctimespec.tv_sec),
                ctimeNanoseconds: Int64(info.st_ctimespec.tv_nsec)
            )
        )
    }
}

/// 一次扫描的可观测指标，用于测试断言与 benchmark 输出。
struct ClaudeCodeScanStats {
    var fileCount = 0
    var cachedFiles = 0
    var readFiles = 0
    var failedFiles = 0
    var prunedFiles = 0
    var bytesRead: Int64 = 0
    var linesScanned: Int64 = 0
    var candidateLines: Int64 = 0
    var parsedLines: Int64 = 0
    var oversizeLines: Int64 = 0
    /// 含超长行、统计不完整的文件数（聚合自缓存条目，不只是本轮读取的）。
    var incompleteFiles = 0
    var rebuiltCache = false
    var loadedPersistedCache = false
    var elapsed: TimeInterval = 0

    var isComplete: Bool { incompleteFiles == 0 }

    var summaryLine: String {
        let mb = Double(bytesRead) / 1_048_576.0
        var text = "命中缓存 \(cachedFiles) · 读取 \(readFiles) · \(String(format: "%.2f", mb)) MB · 解析 \(parsedLines) 行 · \(String(format: "%.0f", elapsed * 1000)) ms"
        if incompleteFiles > 0 {
            text += " · 不完整 \(incompleteFiles) 个文件"
        }
        return text
    }
}

enum ByteSearch {
    static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard let base = haystack.baseAddress, haystack.count >= needle.count, !needle.isEmpty else {
            return false
        }
        return needle.withUnsafeBufferPointer { pattern in
            memmem(base, haystack.count, pattern.baseAddress, pattern.count) != nil
        }
    }
}

/// 时间戳解析。快路径只接受 `YYYY-MM-DDTHH:MM:SS[.f{1,3}]Z`（Claude Code 实际写入的格式），
/// 其它一律回落到与 0.2.12 完全相同的 ISO8601DateFormatter，保证语义不变。
enum ISO8601Fast {
    private static let lock = NSLock()

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(from string: String) -> Date? {
        if let fast = fastPath(string) {
            return fast
        }
        lock.lock()
        defer { lock.unlock() }
        return fractionalFormatter.date(from: string) ?? plainFormatter.date(from: string)
    }

    static func formatterDate(from string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return fractionalFormatter.date(from: string) ?? plainFormatter.date(from: string)
    }

    static func fastPath(_ string: String) -> Date? {
        var iterator = string.utf8.makeIterator()

        func digits(_ count: Int) -> Int? {
            var value = 0
            for _ in 0..<count {
                guard let byte = iterator.next(), byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }

        guard let year = digits(4), iterator.next() == 45,
              let month = digits(2), iterator.next() == 45,
              let day = digits(2), iterator.next() == 84,
              let hour = digits(2), iterator.next() == 58,
              let minute = digits(2), iterator.next() == 58,
              let second = digits(2) else {
            return nil
        }

        var fraction = 0.0
        var trailing = iterator.next()
        if trailing == 46 {
            var scale = 0.1
            var digitCount = 0
            trailing = iterator.next()
            while let byte = trailing, byte >= 48, byte <= 57, digitCount < 3 {
                fraction += Double(byte - 48) * scale
                scale /= 10
                digitCount += 1
                trailing = iterator.next()
            }
            guard digitCount > 0 else { return nil }
        }

        // 只接受以 Z 结尾且没有多余字符的形式；其余（含时区偏移、4 位以上小数）回落给 formatter。
        guard trailing == 90, iterator.next() == nil else { return nil }
        guard year >= 1, month >= 1, month <= 12, day >= 1, hour <= 23, minute <= 59, second <= 59 else {
            return nil
        }
        let isLeap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let monthLengths = [31, isLeap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day <= monthLengths[month - 1] else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let epoch = Double(days) * 86_400 + Double(hour * 3600 + minute * 60 + second) + fraction
        return Date(timeIntervalSince1970: epoch)
    }

    /// Howard Hinnant days_from_civil：公历（proleptic Gregorian）到 1970-01-01 的天数，精确无误差。
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}

/// 进程内长期缓存：`QuotaCollector` 每次刷新都会新建，但缓存挂在这个单例上，因此跨刷新有效。
/// 未修改的文件不会被重新读取或解析（bytesRead / parsedLines 均为 0）。
final class ClaudeCodeUsageStore {
    struct Result {
        let stats: ClaudeCodeUsageStats
        let scan: ClaudeCodeScanStats
    }

    private struct Entry {
        var identity: ClaudeCodeFileIdentity
        var summary: ClaudeCodeFileSummary
    }

    private struct PersistedBucketList: Codable {
        var path: String
        var device: Int64
        var inode: UInt64
        var size: Int64
        var mtimeSeconds: Int64
        var mtimeNanoseconds: Int64
        var ctimeSeconds: Int64
        var ctimeNanoseconds: Int64
        var lastEventEpoch: Double?
        var incomplete: Bool
        var buckets: [ClaudeCodeDayBucket]
    }

    private struct PersistedCache: Codable {
        var schema: Int
        var fingerprint: String
        var entries: [PersistedBucketList]
    }

    static let shared: ClaudeCodeUsageStore = {
        let location = ClaudeCodeUsageStore.defaultPersistenceLocation()
        return ClaudeCodeUsageStore(persistenceURL: location.url, ownsDirectory: location.ownsDirectory)
    }()

    // schema 3：文件身份新增纳秒级 ctime，并记录单文件是否统计不完整。
    private static let schemaVersion = 3
    private static let persistMinimumInterval: TimeInterval = 900
    private static let chunkSize = 1 << 20
    /// 单行上限。真实 JSONL 里贴入大文件会产生几十 MB 的合法行，必须能正常解析；
    /// 超过上限的行会被跳过，并把该文件标记为「统计不完整」显式上报，而不是静默漏计。
    static let defaultMaxLineBytes = 256 << 20
    private static let usageNeedle = Array("\"usage\"".utf8)
    private static let messageNeedle = Array("\"message\"".utf8)

    private let lock = NSLock()
    private let persistenceURL: URL?
    /// 只有默认专用目录才允许被收紧到 0700；用户自定义路径不动其祖先目录。
    private let ownsDirectory: Bool
    private let maxLineBytes: Int
    private var entries: [String: Entry] = [:]
    private var fingerprint: String?
    private var didLoadPersistedCache = false
    private var dirty = false
    private var lastPersistedAt: Date?

    init(persistenceURL: URL?, ownsDirectory: Bool = false, maxLineBytes: Int = ClaudeCodeUsageStore.defaultMaxLineBytes) {
        self.persistenceURL = persistenceURL
        self.ownsDirectory = ownsDirectory
        self.maxLineBytes = max(4096, maxLineBytes)
    }

    /// `AIQUOTABAR_CACHE_FILE` 可覆盖缓存文件位置；设为 `off` 关闭磁盘持久化（测试用）。
    static func defaultPersistenceLocation() -> (url: URL?, ownsDirectory: Bool) {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["AIQUOTABAR_CACHE_FILE"] {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.lowercased() == "off" {
                return (nil, false)
            }
            // 自定义路径：只保证文件本身 0600，不去改用户指定的祖先目录权限。
            return (URL(fileURLWithPath: PathTools.expandTilde(trimmed)), false)
        }
        guard let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(appName, isDirectory: true) else {
            return (nil, false)
        }
        return (support.appendingPathComponent("claude-usage-cache.json"), true)
    }

    func usage(rootPath: String, now: Date = Date(), timeZone: TimeZone = TimeZone.current) throws -> Result {
        lock.lock()
        defer { lock.unlock() }

        let started = Date()
        var calendar = Calendar.current
        calendar.timeZone = timeZone

        var scan = ClaudeCodeScanStats()
        let currentFingerprint = Self.makeFingerprint(root: rootPath, timeZone: timeZone, calendar: calendar)
        if fingerprint != currentFingerprint {
            // 根目录 / 时区 / 日历变化：按本地日历分桶的缓存整体失效，必须重建。
            if fingerprint != nil {
                scan.rebuiltCache = true
            }
            entries.removeAll()
            fingerprint = currentFingerprint
            didLoadPersistedCache = false
            dirty = true
        }
        if !didLoadPersistedCache {
            didLoadPersistedCache = true
            scan.loadedPersistedCache = loadPersistedCache(fingerprint: currentFingerprint)
        }

        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
            throw Shell.ShellError(message: "无法枚举 Claude Code 项目记录目录")
        }

        var seenPaths = Set<String>()
        var uncacheableSummaries: [ClaudeCodeFileSummary] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            let path = fileURL.path
            let info = ClaudeCodeFileStat.of(path: path)
            // 与旧版 `values?.isRegularFile ?? true` 一致：stat 失败时仍按普通文件处理。
            guard info?.isRegular ?? true else { continue }
            scan.fileCount += 1
            seenPaths.insert(path)

            if let identity = info?.identity, let entry = entries[path], entry.identity == identity {
                scan.cachedFiles += 1
                continue
            }

            do {
                // 先记录 stat 结果再读取：若读取期间文件被改写，下一轮 identity 不匹配会自动重读。
                let summary = try Self.readFileSummary(url: fileURL, calendar: calendar, maxLineBytes: maxLineBytes, scan: &scan)
                scan.readFiles += 1
                if let identity = info?.identity {
                    entries[path] = Entry(identity: identity, summary: summary)
                    dirty = true
                } else {
                    uncacheableSummaries.append(summary)
                }
            } catch {
                // 读取失败：本轮不计入（与旧版 `try?` 跳过一致），并丢弃缓存条目，下轮自然重试。
                scan.failedFiles += 1
                if entries.removeValue(forKey: path) != nil {
                    dirty = true
                }
            }
        }

        let stalePaths = entries.keys.filter { !seenPaths.contains($0) }
        if !stalePaths.isEmpty {
            for path in stalePaths {
                entries.removeValue(forKey: path)
            }
            scan.prunedFiles = stalePaths.count
            dirty = true
        }

        var stats = ClaudeCodeUsageStats()
        stats.fileCount = scan.fileCount
        let startToday = DateTools.startOfToday(calendar: calendar, now: now)
        let startWeek = DateTools.startOfSevenDayWindow(calendar: calendar, now: now)
        let todayKey = Int64(startToday.timeIntervalSince1970.rounded(.down))
        let weekKey = Int64(startWeek.timeIntervalSince1970.rounded(.down))

        func accumulate(_ summary: ClaudeCodeFileSummary) {
            if summary.incomplete {
                scan.incompleteFiles += 1
            }
            if let epoch = summary.lastEventEpoch {
                let date = Date(timeIntervalSince1970: epoch)
                if stats.lastDate == nil || date > stats.lastDate! {
                    stats.lastDate = date
                }
            }
            for bucket in summary.buckets {
                if bucket.dayStart >= weekKey {
                    stats.week.merge(bucket)
                }
                if bucket.dayStart >= todayKey {
                    stats.today.merge(bucket)
                }
            }
        }

        for entry in entries.values {
            accumulate(entry.summary)
        }
        for summary in uncacheableSummaries {
            accumulate(summary)
        }

        scan.elapsed = Date().timeIntervalSince(started)
        persistIfNeeded(fingerprint: currentFingerprint, now: started, force: false)
        return Result(stats: stats, scan: scan)
    }

    func flushPersistedCache() {
        lock.lock()
        defer { lock.unlock() }
        guard let fingerprint else { return }
        persistIfNeeded(fingerprint: fingerprint, now: Date(), force: true)
    }

    // MARK: 文件读取（分块流式，避免整文件载入）

    private static func readFileSummary(
        url: URL,
        calendar: Calendar,
        maxLineBytes: Int,
        scan: inout ClaudeCodeScanStats
    ) throws -> ClaudeCodeFileSummary {
        // 用原始 read(2) + 复用缓冲区流式读取：不做整文件载入，也不让 Foundation 为每个分块分配 Data。
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw Shell.ShellError(message: "无法打开 \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        // 这些文件只在内容变化时读一次，读完不需要留在统一缓冲区里，避免挤掉用户真正的工作集。
        _ = fcntl(descriptor, F_NOCACHE, 1)

        let fallbackSessionID = url.deletingPathExtension().lastPathComponent
        var summary = ClaudeCodeFileSummary()
        var buffer = [UInt8]()
        buffer.reserveCapacity(chunkSize + 8192)
        var skippingOversizeLine = false

        var bytesRead: Int64 = 0
        var linesScanned: Int64 = 0
        var candidateLines: Int64 = 0
        var parsedLines: Int64 = 0
        var oversizeLines: Int64 = 0

        // 同一文件内事件时间近似单调，缓存当前「本地日」区间，避免逐条走 Calendar（很慢）。
        var cachedDayStart: Date?
        var cachedDayEnd: Date?
        var cachedDayKey: Int64 = 0

        func localDayStart(for date: Date) -> Int64 {
            if let start = cachedDayStart, let end = cachedDayEnd, date >= start, date < end {
                return cachedDayKey
            }
            let start = calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            cachedDayStart = start
            cachedDayEnd = end > start ? end : start.addingTimeInterval(86_400)
            cachedDayKey = Int64(start.timeIntervalSince1970.rounded(.down))
            return cachedDayKey
        }

        func handleLine(_ line: UnsafeRawBufferPointer) {
            // 与旧版 split(omittingEmptySubsequences: true) 一致：空行直接跳过。
            guard line.count > 0, let base = line.baseAddress else { return }
            linesScanned += 1
            guard ByteSearch.contains(line, usageNeedle), ByteSearch.contains(line, messageNeedle) else { return }
            candidateLines += 1
            parsedLines += 1
            // JSONSerialization 会产生大量 autorelease 对象；不逐行释放的话 1GB 冷扫描峰值内存会飙到几百 MB。
            autoreleasepool {
                let data = Data(bytes: base, count: line.count)
                guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let message = root["message"] as? [String: Any],
                      let usageJSON = message["usage"] as? [String: Any],
                      let usage = ClaudeCodeUsage(json: usageJSON),
                      let timestamp = root["timestamp"] as? String,
                      let date = ISO8601Fast.date(from: timestamp) else {
                    return
                }
                let sessionID = (root["sessionId"] as? String) ?? fallbackSessionID
                summary.add(
                    usage: usage,
                    sessionID: sessionID,
                    dayStart: localDayStart(for: date),
                    epoch: date.timeIntervalSince1970
                )
            }
        }

        var chunk = [UInt8](repeating: 0, count: chunkSize)
        while true {
            var count = 0
            while true {
                count = chunk.withUnsafeMutableBytes { raw -> Int in
                    read(descriptor, raw.baseAddress, chunkSize)
                }
                if count >= 0 || errno != EINTR { break }
            }
            guard count > 0 else {
                if count < 0 {
                    throw Shell.ShellError(message: "读取 \(url.lastPathComponent) 失败: \(String(cString: strerror(errno)))")
                }
                break
            }
            bytesRead += Int64(count)
            chunk.withUnsafeBufferPointer { raw in
                buffer.append(contentsOf: UnsafeBufferPointer(rebasing: raw[0..<count]))
            }

            var consumed = 0
            buffer.withUnsafeBufferPointer { view in
                guard let base = view.baseAddress else { return }
                var start = 0
                while start < view.count {
                    guard let hit = memchr(base + start, 0x0A, view.count - start) else { break }
                    let index = UnsafeRawPointer(hit) - UnsafeRawPointer(base)
                    if skippingOversizeLine {
                        skippingOversizeLine = false
                    } else {
                        handleLine(UnsafeRawBufferPointer(start: base + start, count: index - start))
                    }
                    start = index + 1
                }
                consumed = start
            }
            if consumed > 0 {
                buffer.removeFirst(consumed)
            }
            if buffer.count > maxLineBytes {
                // 超过单行上限：跳到下一个换行避免无界内存，并把该文件标记为统计不完整，
                // 不会被当作「完整成功」缓存/展示。
                skippingOversizeLine = true
                oversizeLines += 1
                summary.incomplete = true
                buffer.removeAll(keepingCapacity: false)
                buffer.reserveCapacity(chunkSize + 8192)
            }
        }

        // 文件末尾没有换行符时，最后一条完整 JSON 仍要计入（与旧版行为一致）。
        if !buffer.isEmpty && !skippingOversizeLine {
            buffer.withUnsafeBufferPointer { view in
                guard let base = view.baseAddress else { return }
                handleLine(UnsafeRawBufferPointer(start: base, count: view.count))
            }
        }

        scan.bytesRead += bytesRead
        scan.linesScanned += linesScanned
        scan.candidateLines += candidateLines
        scan.parsedLines += parsedLines
        scan.oversizeLines += oversizeLines
        return summary
    }

    // MARK: 磁盘持久化（可选；每条仍按 size+mtime+inode 校验，过期条目不会被采用）

    private static func makeFingerprint(root: String, timeZone: TimeZone, calendar: Calendar) -> String {
        "v\(schemaVersion)|\(root)|\(timeZone.identifier)|\(calendar.identifier)"
    }

    private func loadPersistedCache(fingerprint: String) -> Bool {
        guard let persistenceURL, let data = try? Data(contentsOf: persistenceURL) else { return false }
        guard let decoded = try? JSONDecoder().decode(PersistedCache.self, from: data),
              decoded.schema == Self.schemaVersion,
              decoded.fingerprint == fingerprint else {
            return false
        }
        for item in decoded.entries {
            entries[item.path] = Entry(
                identity: ClaudeCodeFileIdentity(
                    device: item.device,
                    inode: item.inode,
                    size: item.size,
                    mtimeSeconds: item.mtimeSeconds,
                    mtimeNanoseconds: item.mtimeNanoseconds,
                    ctimeSeconds: item.ctimeSeconds,
                    ctimeNanoseconds: item.ctimeNanoseconds
                ),
                summary: ClaudeCodeFileSummary(
                    buckets: item.buckets,
                    lastEventEpoch: item.lastEventEpoch,
                    incomplete: item.incomplete
                )
            )
        }
        return true
    }

    private func persistIfNeeded(fingerprint: String, now: Date, force: Bool) {
        guard let persistenceURL, dirty else { return }
        if !force, let lastPersistedAt, now.timeIntervalSince(lastPersistedAt) < Self.persistMinimumInterval {
            return
        }

        let payload = PersistedCache(
            schema: Self.schemaVersion,
            fingerprint: fingerprint,
            entries: entries.map { path, entry in
                PersistedBucketList(
                    path: path,
                    device: entry.identity.device,
                    inode: entry.identity.inode,
                    size: entry.identity.size,
                    mtimeSeconds: entry.identity.mtimeSeconds,
                    mtimeNanoseconds: entry.identity.mtimeNanoseconds,
                    ctimeSeconds: entry.identity.ctimeSeconds,
                    ctimeNanoseconds: entry.identity.ctimeNanoseconds,
                    lastEventEpoch: entry.summary.lastEventEpoch,
                    incomplete: entry.summary.incomplete,
                    buckets: entry.summary.buckets
                )
            }
        )

        do {
            let data = try JSONEncoder().encode(payload)
            try Self.writePrivately(data, to: persistenceURL, ownsDirectory: ownsDirectory)
            dirty = false
            lastPersistedAt = now
        } catch {
            // 持久化只是加速手段，失败不影响本轮统计。
            lastPersistedAt = now
        }
    }

    /// 缓存文件含项目路径、session id 与每日统计，属于用户私有数据：
    /// 临时文件与最终文件都必须是 0600；只有我们自己的专用目录才会被收紧到 0700。
    private static func writePrivately(_ data: Data, to url: URL, ownsDirectory: Bool) throws {
        let directory = url.deletingLastPathComponent()
        var attributes: [FileAttributeKey: Any]?
        if ownsDirectory {
            attributes = [.posixPermissions: NSNumber(value: Int16(0o700))]
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
        if ownsDirectory {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: directory.path
            )
        }

        let temporaryPath = directory.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp").path
        unlink(temporaryPath)
        let descriptor = open(temporaryPath, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw Shell.ShellError(message: "无法创建缓存临时文件: \(String(cString: strerror(errno)))")
        }
        // umask 无法放宽 0600，这里再显式收一次，确保临时文件从诞生起就不可被他人读取。
        _ = fchmod(descriptor, 0o600)

        var writeError: String?
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(descriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    writeError = String(cString: strerror(errno))
                    return
                }
                pointer += written
                remaining -= written
            }
        }
        close(descriptor)

        if let writeError {
            unlink(temporaryPath)
            throw Shell.ShellError(message: "写入缓存失败: \(writeError)")
        }
        guard rename(temporaryPath, url.path) == 0 else {
            let message = String(cString: strerror(errno))
            unlink(temporaryPath)
            throw Shell.ShellError(message: "替换缓存文件失败: \(message)")
        }
    }
}

final class QuotaCollector {
    let config: AppConfig

    init(config: AppConfig) {
        self.config = config
    }

    func collect() async -> Snapshot {
        async let codex = codexLocalUsageCard()
        async let claudeCode = claudeCodeLocalUsageCard()
        async let browser = chromeBrowserUsageCards()

        let browserResult = await browser
        var cards = browserResult.cards
        cards.append(await codex)
        cards.append(await claudeCode)
        return Snapshot(updatedAt: Date(), cards: cards, diagnosticsLines: browserResult.diagnostics)
    }

    private func openAICostsCard() async -> QuotaCard {
        guard config.sources.openAICosts else {
            return QuotaCard(
                provider: "Codex / OpenAI API",
                headline: "已在配置中关闭",
                details: ["sources.openAICosts = false"],
                status: .unavailable,
                remainingUSD: nil,
                statusBarHint: nil
            )
        }

        guard let key = KeychainStore.secret(account: "OPENAI_ADMIN_KEY") else {
            return QuotaCard(
                provider: "Codex / OpenAI API",
                headline: "等待配置 Admin Key",
                details: [
                    "未找到 OPENAI_ADMIN_KEY。",
                    "运行 Scripts/set-key.sh OPENAI_ADMIN_KEY 写入 Keychain。",
                    "有预算时会显示本月剩余额度；否则显示本月成本。"
                ],
                status: .unavailable,
                remainingUSD: nil,
                statusBarHint: nil
            )
        }

        do {
            let (start, end) = DateTools.monthRange()
            var components = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
            components.queryItems = [
                URLQueryItem(name: "start_time", value: "\(Int(start.timeIntervalSince1970))"),
                URLQueryItem(name: "end_time", value: "\(Int(end.timeIntervalSince1970))"),
                URLQueryItem(name: "limit", value: "31")
            ]

            let json = try await HTTPClient.json(
                url: components.url!,
                headers: [
                    "Authorization": "Bearer \(key)",
                    "Content-Type": "application/json"
                ]
            )
            let cost = Self.sumOpenAICosts(json)
            return costCard(
                provider: "Codex / OpenAI API",
                cost: cost,
                budget: config.monthlyBudgetsUSD.openAI,
                source: "OpenAI organization costs",
                dateRange: "\(Formatters.date(start)) 到现在"
            )
        } catch {
            return QuotaCard(
                provider: "Codex / OpenAI API",
                headline: "读取失败",
                details: [error.localizedDescription],
                status: .error,
                remainingUSD: nil,
                statusBarHint: nil
            )
        }
    }

    private func anthropicCostsCard() async -> QuotaCard {
        guard config.sources.anthropicCosts else {
            return QuotaCard(
                provider: "Claude / Anthropic API",
                headline: "已在配置中关闭",
                details: ["sources.anthropicCosts = false"],
                status: .unavailable,
                remainingUSD: nil,
                statusBarHint: nil
            )
        }

        guard let key = KeychainStore.secret(account: "ANTHROPIC_ADMIN_KEY") else {
            return QuotaCard(
                provider: "Claude / Anthropic API",
                headline: "等待配置 Admin Key",
                details: [
                    "未找到 ANTHROPIC_ADMIN_KEY。",
                    "运行 Scripts/set-key.sh ANTHROPIC_ADMIN_KEY 写入 Keychain。",
                    "Anthropic 成本接口需要组织 Admin API Key。"
                ],
                status: .unavailable,
                remainingUSD: nil,
                statusBarHint: nil
            )
        }

        do {
            let (start, end) = DateTools.monthRange()
            var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/cost_report")!
            components.queryItems = [
                URLQueryItem(name: "starting_at", value: Formatters.iso8601(start)),
                URLQueryItem(name: "ending_at", value: Formatters.iso8601(end)),
                URLQueryItem(name: "limit", value: "31")
            ]

            let json = try await HTTPClient.json(
                url: components.url!,
                headers: [
                    "x-api-key": key,
                    "anthropic-version": "2023-06-01",
                    "Content-Type": "application/json"
                ]
            )
            let cost = Self.sumAnthropicCosts(json)
            return costCard(
                provider: "Claude / Anthropic API",
                cost: cost,
                budget: config.monthlyBudgetsUSD.anthropic,
                source: "Anthropic cost_report",
                dateRange: "\(Formatters.date(start)) 到现在"
            )
        } catch {
            return QuotaCard(
                provider: "Claude / Anthropic API",
                headline: "读取失败",
                details: [error.localizedDescription],
                status: .error,
                remainingUSD: nil,
                statusBarHint: nil
            )
        }
    }

    private func costCard(provider: String, cost: Double, budget: Double?, source: String, dateRange: String) -> QuotaCard {
        var details = [
            "本月 API 成本: \(Formatters.money(cost))",
            "统计范围: \(dateRange)",
            "来源: \(source)"
        ]
        var remaining: Double?
        var status: StatusLevel = .ok
        var headline = "本月 \(Formatters.money(cost))"

        if let budget {
            let value = budget - cost
            remaining = value
            headline = "剩余 \(Formatters.money(value))"
            details.insert("月预算: \(Formatters.money(budget))", at: 1)
            details.insert(value >= 0 ? "预算剩余: \(Formatters.money(value))" : "已超预算: \(Formatters.money(abs(value)))", at: 2)
            if value < 0 || (budget > 0 && value / budget < 0.15) {
                status = .warning
            }
        } else {
            details.insert("未设置月预算，无法计算剩余额度。", at: 1)
        }

        return QuotaCard(
            provider: provider,
            headline: headline,
            details: details,
            status: status,
            remainingUSD: remaining,
            statusBarHint: nil
        )
    }

    private func codexLocalUsageCard() async -> QuotaCard {
        guard config.sources.codexLocalUsage else {
            return QuotaCard(
                provider: "Codex 本机记录",
                headline: "已在配置中关闭",
                details: ["sources.codexLocalUsage = false"],
                status: .unavailable,
                remainingUSD: nil,
                statusBarHint: nil
            )
        }

        let path = PathTools.expandTilde(config.paths.codexStateSQLite)
        guard FileManager.default.fileExists(atPath: path) else {
            return QuotaCard(
                provider: "Codex 本机记录",
                headline: "未找到状态库",
                details: [path],
                status: .unavailable,
                remainingUSD: nil,
                statusBarHint: nil
            )
        }

        do {
            let todayMs = DateTools.startOfTodayMilliseconds()
            let weekMs = DateTools.startOfSevenDayWindowMilliseconds()
            let sql = """
            SELECT COALESCE(SUM(CASE WHEN COALESCE(updated_at_ms, updated_at * 1000) >= \(todayMs) THEN tokens_used ELSE 0 END),0), COALESCE(SUM(CASE WHEN COALESCE(updated_at_ms, updated_at * 1000) >= \(weekMs) THEN tokens_used ELSE 0 END),0), COUNT(*), COALESCE(MAX(COALESCE(updated_at_ms, updated_at * 1000)),0) FROM threads;
            """
            let output = try Shell.run("/usr/bin/sqlite3", arguments: ["-readonly", "-separator", "\t", path, sql])
            let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
            guard parts.count >= 4,
                  let today = Int64(parts[0]),
                  let week = Int64(parts[1]),
                  let threadCount = Int64(parts[2]),
                  let lastMs = Int64(parts[3]) else {
                throw Shell.ShellError(message: "Codex 状态库返回格式无法解析")
            }

            let lastDate = lastMs > 0 ? Date(timeIntervalSince1970: Double(lastMs) / 1000.0) : nil
            var details = [
                "今日 token: \(Formatters.integer(today))",
                "近 7 天 token: \(Formatters.integer(week))",
                "线程数: \(Formatters.integer(threadCount))",
                "来源: \(path)"
            ]
            if let lastDate {
                details.insert("最近更新: \(Formatters.date(lastDate))", at: 3)
            }

            return QuotaCard(
                provider: "Codex 本机记录",
                headline: "今日 \(Formatters.integer(today)) tokens",
                details: details,
                status: .ok,
                remainingUSD: nil,
                statusBarHint: Formatters.compactNumber(today)
            )
        } catch {
            return QuotaCard(
                provider: "Codex 本机记录",
                headline: "读取失败",
                details: [error.localizedDescription],
                status: .error,
                remainingUSD: nil,
                statusBarHint: nil
            )
        }
    }

    fileprivate func claudeCodeLocalUsageCard() async -> QuotaCard {
        guard config.sources.claudeCodeLocalUsage ?? true else {
            return QuotaCard(
                provider: "Claude Code 本机记录",
                headline: "已在配置中关闭",
                details: ["sources.claudeCodeLocalUsage = false"],
                status: .unavailable,
                remainingUSD: nil,
                statusBarHint: nil
            )
        }

        let path = PathTools.expandTilde(config.paths.claudeProjects ?? "~/.claude/projects")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return QuotaCard(
                provider: "Claude Code 本机记录",
                headline: "未找到项目记录",
                details: [
                    path,
                    "Claude Code 的 token 记录通常位于 ~/.claude/projects/*.jsonl。"
                ],
                status: .unavailable,
                remainingUSD: nil,
                statusBarHint: nil
            )
        }

        do {
            let result = try ClaudeCodeUsageStore.shared.usage(rootPath: path)
            let stats = result.stats
            guard stats.fileCount > 0 else {
                return QuotaCard(
                    provider: "Claude Code 本机记录",
                    headline: "未找到 JSONL 记录",
                    details: [path],
                    status: .unavailable,
                    remainingUSD: nil,
                    statusBarHint: nil
                )
            }

            guard stats.week.total > 0 else {
                return QuotaCard(
                    provider: "Claude Code 本机记录",
                    headline: "暂无 token 记录",
                    details: [
                        "已扫描 \(Formatters.integer(Int64(stats.fileCount))) 个会话文件。",
                        "来源: \(path)"
                    ],
                    status: .unavailable,
                    remainingUSD: nil,
                    statusBarHint: nil
                )
            }

            var details = [
                "今日 token: \(Formatters.integer(stats.today.total))",
                "近 7 天 token: \(Formatters.integer(stats.week.total))",
                "今日消息/会话: \(Formatters.integer(Int64(stats.today.messageCount))) / \(Formatters.integer(Int64(stats.today.sessionCount)))",
                "近 7 天消息/会话: \(Formatters.integer(Int64(stats.week.messageCount))) / \(Formatters.integer(Int64(stats.week.sessionCount)))",
                "今日拆分: 输入 \(Formatters.integer(stats.today.input)) · 输出 \(Formatters.integer(stats.today.output)) · Cache \(Formatters.integer(stats.today.cacheTotal))",
                "近 7 天拆分: 输入 \(Formatters.integer(stats.week.input)) · 输出 \(Formatters.integer(stats.week.output)) · Cache \(Formatters.integer(stats.week.cacheTotal))",
                "来源: \(path)（\(Formatters.integer(Int64(stats.fileCount))) 个会话文件）",
                "缓存: \(result.scan.summaryLine)"
            ]
            if let lastDate = stats.lastDate {
                details.insert("最近更新: \(Formatters.date(lastDate))", at: 4)
            }
            // 有行超过单行上限没能解析时必须显式说明统计不完整，不做静默漏计。
            if !result.scan.isComplete {
                details.insert(
                    "⚠️ 统计不完整: \(result.scan.incompleteFiles) 个文件含超长行（超过 \(ClaudeCodeUsageStore.defaultMaxLineBytes / (1 << 20)) MB）未能解析。",
                    at: 0
                )
            }

            return QuotaCard(
                provider: "Claude Code 本机记录",
                headline: result.scan.isComplete
                    ? "今日 \(Formatters.integer(stats.today.total)) tokens"
                    : "今日 \(Formatters.integer(stats.today.total)) tokens（统计不完整）",
                details: details,
                status: result.scan.isComplete ? .ok : .warning,
                remainingUSD: nil,
                statusBarHint: Formatters.compactNumber(stats.today.total)
            )
        } catch {
            return QuotaCard(
                provider: "Claude Code 本机记录",
                headline: "读取失败",
                details: [error.localizedDescription],
                status: .error,
                remainingUSD: nil,
                statusBarHint: nil
            )
        }
    }

    private func claudeDesktopPresenceCard() async -> QuotaCard {
        guard config.sources.claudeDesktopPresence else {
            return QuotaCard(
                provider: "Claude Desktop",
                headline: "已在配置中关闭",
                details: ["sources.claudeDesktopPresence = false"],
                status: .unavailable,
                remainingUSD: nil,
                statusBarHint: nil
            )
        }

        let path = PathTools.expandTilde(config.paths.claudeApplicationSupport)
        let exists = FileManager.default.fileExists(atPath: path)
        guard exists else {
            return QuotaCard(
                provider: "Claude Desktop",
                headline: "未检测到本机数据目录",
                details: [path],
                status: .unavailable,
                remainingUSD: nil,
                statusBarHint: nil
            )
        }

        var details = [
            "已检测到 Claude Desktop 数据目录。",
            "个人 Claude 聊天剩余额度不在本地公开数据中。",
            "如需 API 成本/预算，请配置 ANTHROPIC_ADMIN_KEY。"
        ]

        if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
           let modified = attributes[.modificationDate] as? Date {
            details.insert("目录更新: \(Formatters.date(modified))", at: 1)
        }

        return QuotaCard(
            provider: "Claude Desktop",
            headline: "已检测到",
            details: details,
            status: .ok,
            remainingUSD: nil,
            statusBarHint: nil
        )
    }

    /// 网页额度：每次刷新重新发现 Chrome 实例 → 只向选中的已验证 PID 发送 Apple Events → 逐阶段报告 → 卡片。
    /// 实例选择失败 / 权限拒绝 / JS 关闭 / 超时都会以各自的原因进入卡片，页面为空时由 AppDelegate 沿用上次成功额度。
    private func chromeBrowserUsageCards() async -> (cards: [QuotaCard], diagnostics: [String]) {
        guard config.sources.chromeBrowserUsage ?? true else {
            return ([], [])
        }
        let outcome = ChromeQuotaReadService.run(options: ChromeReadOptions.from(config: config))
        return (ChromeCardBuilder.cards(from: outcome), outcome.diagnosticLines)
    }

    static func sumOpenAICosts(_ json: Any) -> Double {
        guard let root = json as? [String: Any],
              let data = root["data"] as? [[String: Any]] else {
            return 0
        }

        var total = 0.0
        for bucket in data {
            for result in JSONTools.resultArrays(in: bucket) {
                if let amount = result["amount"] as? [String: Any],
                   let value = JSONTools.double(amount["value"]) {
                    total += value
                } else if let value = JSONTools.double(result["amount"]) {
                    total += value
                }
            }
        }
        return total
    }

    static func sumAnthropicCosts(_ json: Any) -> Double {
        guard let root = json as? [String: Any],
              let data = root["data"] as? [[String: Any]] else {
            return 0
        }

        var totalCents = 0.0
        for bucket in data {
            for result in JSONTools.resultArrays(in: bucket) {
                if let amount = JSONTools.double(result["amount"]) {
                    totalCents += amount
                }
            }
        }
        return totalCents / 100.0
    }
}

enum BrowserUsageParser {
    struct CodexMetric {
        let label: String
        let remainingPercent: Double?
        let reset: String?
        let value: String?

        var description: String {
            var parts = [label]
            if let remainingPercent {
                parts.append("\(Formatters.percent(remainingPercent))% 剩余")
            }
            if let value {
                parts.append(value)
            }
            if let reset {
                parts.append(reset)
            }
            return parts.joined(separator: ": ")
        }
    }

    struct ClaudeMetric {
        let label: String
        let usedPercent: Double?
        let value: String?
        let reset: String?

        var description: String {
            var parts = [label]
            if let usedPercent {
                parts.append("\(Formatters.percent(usedPercent))% used")
            }
            if let value {
                parts.append(value)
            }
            if let reset {
                parts.append(reset)
            }
            return parts.joined(separator: ": ")
        }
    }

    // MARK: Codex 周额度契约（正式整改 1/3，按 2026-10-04 复现文本重写）
    //
    // 真实新页面的周额度区域（截图逐字）：
    //   套餐限额 / 说明句 / 每周限额 / 5 天 17 小时后重置 / 剩余 83%
    // 紧挨着下方就是充值余额（额度 / 剩余额度：62,500 / 当前余额 / 自动充值）与重置历史
    //   （使用限额重置 / 说明句里也写着「每周限额」/ 可用 0 / 历史记录 / 已使用重置次数 …）。
    //
    // 判定改用白名单，不再用「停止关键词黑名单」：
    //   1. 标题必须是完整字段 —— 后面只能接空白 / 冒号 / 已知重置信息 / 剩余百分比，
    //      所以「每周限额会在用完后暂停服务，示例为剩余 83%」这种说明句不是栏目标题；
    //   2. 标题到百分比之间只允许空白和已知重置信息 —— 其余任何正文（加载中、代码审查、
    //      下一个栏目标题）都终止匹配，未知栏目不必预先列进黑名单也跨不过去；
    //   3. 数值因此必须是完整合法字段 —— `1,50%`、`- 5%`、`−5%`（Unicode 负号）前面的
    //      非法前缀同样跨不过去，不会「跳过前缀再匹配尾数」。
    //
    // 解析器（ICU）与就绪探针（JavaScript）共用同一条正则 **和同一套正文归一化**：
    // 只共用正则并不等于口径一致——ICU 的 `\d` 含全角数字而 JS 只认 ASCII，空白压缩与否
    // 也会让两端分叉。所以正则里一律写死 [0-9] / [ \n]，归一化规则也编译进探针脚本。

    /// 周额度栏目标题。新页面是「每周限额」，旧页面的中英文标题一并保留。
    static let codexWeeklyLabels = ["每周限额", "每周使用限额", "Weekly limit", "Weekly usage limit"]

    /// 换行码位，必须与 `CharacterSet.newlines` 完全一致（U+000A…U+000D、U+0085、U+2028、U+2029）。
    /// 生产链路上 `LineTools.normalize` 正是用它分行，所以 Codex 两端只能按同一套语义处理：
    /// VT(U+000B) / FF(U+000C) 尤其不能一端当横向空白、另一端当换行——那样同一段正文会一端解析成功、
    /// 另一端探针就绪却解析为空。自检里有断言钉住这张表与 Foundation 相等。
    static let codexLineBreakScalars: [UInt32] = [0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029]

    /// 横向空白码位，必须与 `CharacterSet.whitespaces` 一致（`LineTools` 按它逐行 trim），
    /// 外加 U+FEFF：它不在任何 Foundation 集合里、`LineTools` 不会 trim 掉，两端都按空白压掉才一致。
    /// 写成码位表而不是 `\s`：ICU 与 JavaScript 对 `\s` 的定义不同，列死码位两端才真正一致；
    /// 字符类在运行时拼出来，源码里不出现不可见字符。
    static let codexHorizontalSpaceScalars: [UInt32] = [
        0x09, 0x20, 0xA0, 0x1680,
        0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x200B,
        0x202F, 0x205F, 0x3000, 0xFEFF
    ]

    /// 图标 / 图片在 innerText 里留下的占位符 U+FFFC，归一化时换成空格。
    static let codexObjectReplacement = String(UnicodeScalar(0xFFFC)!)

    /// 字符类用 `\uXXXX` 转义文本而不是字面字符：换行字符（含 U+2028 / U+2029）直接写进
    /// JavaScript 的正则字面量会是语法错误，转义文本在 ICU 与 JavaScript 里语义相同且可读。
    private static func characterClass(_ scalars: [UInt32]) -> String {
        "[" + scalars.map { String(format: "\\u%04X", $0) }.joined() + "]"
    }

    /// 两端共用的换行 / 横向空白字符类。
    static let codexLineBreak = characterClass(codexLineBreakScalars)
    static let codexHorizontalSpace = characterClass(codexHorizontalSpaceScalars)

    /// 把 ASCII 关键词展开成逐字符的大小写字符类，整条正则因此不需要 `i` 标志。
    /// ICU 的 `i` 用完整 case folding（U+212A 开尔文符号会折叠成 `k`），JavaScript 不带 `u` 标志不会，
    /// `Weekly` 这种含 `k` 的词会让两端分叉；展开后两端只比较 ASCII 字面量，没有折叠这个变量。
    /// 非 ASCII 字母（中文标题）原样保留，大小写对它们本来就没有意义。
    private static func asciiCaseInsensitive(_ word: String) -> String {
        word.map { character in
            guard character.isASCII, character.isLetter else {
                return NSRegularExpression.escapedPattern(for: String(character))
            }
            return "[\(character.lowercased())\(character.uppercased())]"
        }.joined()
    }

    /// 中文倒计时**字段内部**的词元边界（0.2.17）。真实 DOM 会在任意一处词元边界插空格或断行：
    /// 2026-10-11 截图是「6天15小时 后重置」—— 数字紧贴单位，而单位与「后重置」之间多了一处空白，
    /// 0.2.16 要求单位紧贴「后重置」，于是整条周额度字段两端一起失配（解析为空 + 探针 0 = 就绪超时）。
    /// 归一化之后这处空白只会是空格 / `\n` 的任意组合（`LineTools` 只 trim 行首尾，` \n ` 也可能留下），
    /// 所以统一写成 `[ \n]*`，而不是只许一个空格的 `[ ]?`。
    /// 放宽**只发生在词元边界上**：数字位数、单位、「后重置」本身仍是精确字面量，边界上出现任何正文
    /// （未知说明 / 未知栏目 / 被拆行的负号）这个字段就不成立，ICU 与 JavaScript 两端一致 fail closed。
    /// 旧写法（`重置时间: …` 与英文 `Resets …`）本轮没有新的失配证据，边界保持原样，不顺手放宽。
    private static let codexTokenGap = "[ \\n]*"

    /// 标题与百分比之间唯一允许出现的已知字段：重置信息（新页面倒计时 + 旧中英文写法）。
    /// 它同时也是重置信息的取值来源，所以重置必然与百分比来自同一次匹配、同一个周额度区间，
    /// 不会从另一个标题或说明句拼接过来。
    private static let codexResetField: String = {
        let resets = asciiCaseInsensitive("Resets")
        let inWord = asciiCaseInsensitive("in")
        let englishPrefix = "\(resets)(?:[ ]\(inWord))?[ ]"
        let gap = codexTokenGap
        return [
            "(?:[0-9]{1,3}\(gap)天\(gap))?[0-9]{1,3}\(gap)(?:天|小时|分钟)\(gap)后重置",
            #"重置时间[ ]?[:：][ ]?(?:[0-9]{4}年[0-9]{1,2}月[0-9]{1,2}日[ ]?)?[0-9]{1,2}:[0-9]{2}"#,
            englishPrefix + "[0-9]{1,3}[ ]?[hH][ ]?[0-9]{1,2}[ ]?[mM]",
            englishPrefix + "[0-9]{1,3}[ ](?:\(asciiCaseInsensitive("minute"))[sS]?|\(asciiCaseInsensitive("hour"))[sS]?|\(asciiCaseInsensitive("day"))[sS]?)",
            englishPrefix + "[A-Za-z]{3}[ ][0-9]{1,2}:[0-9]{2}(?:[ ]?[AaPp][Mm])?"
        ].joined(separator: "|")
    }()

    /// 周额度「剩余百分比」的唯一判据。捕获组：1 = 百分比之前的重置信息（真实新页面在这里），
    /// 2 / 3 = 数值（前缀式「剩余 83%」/ 后缀式「68% 剩余」），4 = 百分比之后的重置信息
    /// （旧中文页把「重置时间: …」写在数值后面）。
    /// 数值只认 0…100（含小数）。
    ///
    /// 整改 2/3 补上**字段结束约束** `fieldEnd`：整条匹配（含可选的同行 / 下一行重置信息）之后，
    /// 本行只能剩空白。它和开头那条「标题必须是完整字段」是同一个「完整字段」要求的两端，
    /// 不是针对某几条文本的特判：
    ///   - `43% / 剩余 额度：62,500` —— 「剩余」后面同行还有正文，不是完整字段；
    ///   - `43% remainingCredits: 62,500` —— 「remaining」只是更长单词的前缀；
    ///   - `剩余 83%%` —— 「83%」只是非法字段 `83%%` 的前半段。
    /// 因此原先后缀式上那条 `(?!额度)` 特判被它整个取代，已删除。
    /// 用 `(?![ ]*[^ \n])` 而不是 `$`：ICU 的 `$` 还会匹配结尾换行之前的位置，JavaScript 不会，
    /// 两端会分叉（与整改 1/3 统一数字 / 空白语义同一个原则）。
    static let codexWeeklyRemainingPattern: String = {
        let labels = codexWeeklyLabels.map(asciiCaseInsensitive).joined(separator: "|")
        let remaining = asciiCaseInsensitive("remaining")
        let gap = "[ \\n]*"
        let value = #"(100(?:\.0+)?|[0-9]{1,2}(?:\.[0-9]+)?)"#
        let percent = "(?:(?:剩余|\(remaining))\(gap)\(value)\(gap)%|\(value)\(gap)%\(gap)(?:剩余|\(remaining)))"
        let fieldEnd = "(?![ ]*[^ \\n])"
        return "(?:^|\\n)[ ]*(?:\(labels))[ ]*[:：]?\(gap)"
            + "(?:(\(codexResetField))\(gap))?"
            + percent
            + "(?:\(gap)(\(codexResetField)))?"
            + fieldEnd
    }()

    /// 解析器与就绪探针共用的正文归一化：图标占位符 → 空格、**任意一段换行（含 CRLF、VT、FF、
    /// NEL、LS、PS）→ 一个 `\n`**、横向空白压成一个空格。换行整段压成一个，与 `LineTools.normalize`
    /// 丢弃空行的效果对齐；探针脚本编译的是同一套规则。
    static func codexNormalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: codexObjectReplacement, with: " ")
            .replacingOccurrences(of: codexLineBreak + "+", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: codexHorizontalSpace + "+", with: " ", options: .regularExpression)
    }

    /// Codex 周额度解析。只产出完整合法的剩余百分比；解析不出就返回空，卡片会走「未解析到额度」而不是编造数值。
    /// 展示用的内部名称固定为「每周使用限额」，状态栏已选的 weekly 档不受页面文案变化影响。
    static func parseCodex(lines: [String]) -> [CodexMetric] {
        let text = codexNormalized(lines.joined(separator: "\n"))
        // 不加 .caseInsensitive：大小写已经展开进正则，两端因此没有 case folding 这个变量。
        guard let regex = try? NSRegularExpression(pattern: codexWeeklyRemainingPattern, options: []),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let percent = (group(2, match, text) ?? group(3, match, text)).flatMap({ Double($0) }),
              (0...100).contains(percent) else {
            return []
        }
        return [CodexMetric(
            label: "每周使用限额",
            remainingPercent: percent,
            // 词元边界允许 DOM 换行后，取到的倒计时可能带 `\n`；卡片详情与进度条副标题都是单行控件。
            reset: (group(1, match, text) ?? group(4, match, text)).map(resetDisplayText),
            value: nil
        )]
    }

    private static func group(_ index: Int, _ match: NSTextCheckingResult, _ text: String) -> String? {
        guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }

    // MARK: Claude 用量契约（0.2.16，按 2026-10-11 新中文页截图重写）
    //
    // 新中文页一个栏目的结构是「标题 / 可选说明 / 可选重置 / 已使用 N%」（截图逐字）：
    //   当前会话 / 从您的第一条消息开始 / 已使用 0%
    //   本周 / 星期一05:00 重置 / 已使用 68%
    //   本周 Fable / Fable 的单独每周限额 · 星期一 / 05:00 重置 / 已使用 3%
    // 紧接着是四个没有百分比的栏目：限额重置 / 云会话额度 / 包含的额度 / 用量额度（US$…）。
    //
    // 0.2.15 在这页上有三个缺口，本轮一并补掉：
    //   1. 百分比只认后缀（`12% 已使用`），新页面写成前缀（`已使用 0%`）—— 解析器与就绪探针都读不到，
    //      所以 CLI 退出 0 但 Claude 页「就绪超时」；
    //   2. 不认识独立标题「本周」—— 总周额度整栏缺失；
    //   3. 兜底是「标题所在行起 6 行窗口里的任意百分比」—— 「本周」自己没有数值时会把下一栏
    //      「本周 Fable」的 3% 当成总周额度（状态栏会显示 97% 剩余这种假值）。
    //
    // 判定与 Codex 周额度同构，**全白名单**：没有栏目黑名单，也没有任何「任意正文」通配。
    //   1. 标题必须是完整字段 —— 标题后面只能接空白 / 冒号 / 已知说明字段 / 已知重置字段 /
    //      百分比字段 / 行尾。所以「当前会话的用量…」这种说明句前缀不是标题；「本周 Fable」
    //      后面接的是 ` Fable`，既不是已知说明，也不是重置或百分比，因此它冒充不了「本周」；
    //   2. 标题到百分比之间**只允许三种东西**：空白（可跨行）、一段 `claudeDescriptionFields` 里的
    //      已知说明字段、一段 `claudeResetField` 里的已知重置字段。除此之外的任何正文一律就地终止 ——
    //      未知说明行、未知栏目标题（`其他额度`）、被 DOM 拆到上一行的负号（`-`）统统 fail closed，
    //      既不需要栏目黑名单，也不靠行数上限；
    //   3. 数值必须是完整合法字段（0…100 含小数）并以字段结束约束收尾 —— `150%` / `100.5%` /
    //      `-5%` / `−5%`（Unicode 负号）/ `1,50%` / 全角 `８5%` / `85％` / `85%%` / `85%x`
    //      都跨不过去，不会「跳过非法前缀再取尾数」。
    //
    // 正式整改 1/3（2026-10-11 独立审查：123 组 490 断言中 10 组 22 断言失败）修掉的两个洞，
    // 根因都是 0.2.16 初稿「允许任意正文说明行」：
    //   A. 前导空白回溯绕过栏目边界。初稿把边界判定写成说明行开头的 `(?!已知标题)` 前瞻，而它前面的
    //      空白段可以回溯：`本周\n 本周 Fable\n已使用 3%` 里引擎只要把行首空格留在说明行内，前瞻就落
    //      在空格上、不再命中「本周 Fable」，3% 于是被当成总周额度。更糟的是两端还会分叉 ——
    //      `LineTools` 会 trim 掉行首的普通空格 / Tab / NBSP（Swift 侧缺值），探针吃的原文不 trim
    //      （JSC 侧就绪）；U+FEFF 与图标占位符 U+FFFC 连 `LineTools` 都不 trim，两端一起误取。
    //      现在说明位置只能是固定字面量，空白无论怎么回溯都要在字面量处对上，所以普通空格 / Tab /
    //      NBSP / U+FEFF / U+FFFC / U+200B / 全角空格一律缺值、探针一律 0。
    //   B. 任意说明行吞掉非法字段与未知标题。`本周\n-\n5% used` 的 `-`（`-5%` 被 DOM 拆行）与
    //      `当前会话\n其他额度\n已使用 3%` 的 `其他额度` 都被初稿当成说明行跨过去，借到了下一个数字；
    //      现在两者都不是已知字段，匹配就地结束。
    //   取消任意说明行的代价写在明处：标题与百分比之间夹着**未登记**文案时，该栏判成缺值（宁缺勿错，
    //      症状是这一栏没有数值 / 页面不就绪，而不是显示一个错的百分比）。补救办法是把新文案登记进
    //      `claudeDescriptionFields`，不是放宽结构。
    //   重置文本被 DOM 拆行是已知的合法结构，所以允许它在**字段内部**跨一次换行（星期 ↔ 时刻），
    //      这与「跨行吞正文」不是一回事：字段内部仍然只许空白。
    //
    // 两端（ICU 解析器与 JavaScript 就绪探针）共用同一条正则 **和同一套归一化**：正则里一律写死
    // [0-9] / [ \n]、大小写展开进字符类（不靠两端语义不同的 `\d` / `\s` / `i` / `$`），归一化直接复用
    // Codex 整改时建立的那份中性实现（图标占位符 → 空格、任意一段换行 → 一个 `\n`、横向空白 → 一个空格）。
    // 自检里两端跑同一份用例矩阵，并且原文一律先过生产链路 `LineTools.normalize(_:deduplicate:false)`。

    /// 栏目标题 → 内部标识。内部标识保持 0.2.13 起的英文名：`ClaudeStatusMetric.label`、卡片进度条标签
    /// 与用户已保存的 allModels 偏好都按它取值，所以新中文标题只是**新增同义词**，不改内部名。
    /// 「本周」就是总周额度这一栏的新中文标题，精确映射既有的 `All models`。
    /// 0.2.18（2026-10-26 新布局）：总周额度的标题换成了全称「每周限额 · 所有模型」。
    /// 它只是这一栏的**新同义词**，内部标识仍是 `All models`，用户已保存的 allModels 偏好不受影响。
    /// 只登记全称：「每周限额」单独成行是 Codex 的栏目标题，「所有模型」单独成行没有出现过，
    /// 两个半段都不足以认定这一栏。
    static let claudeSections: [(label: String, titles: [String])] = [
        ("Current session", ["Current session", "当前会话"]),
        ("All models", ["All models", "本周", "每周限额 · 所有模型"]),
        ("Claude Design", ["Claude Design"])
    ]

    /// 槽位之间唯一允许的东西：纯空白，可跨行。它不含任何正文字符，所以不可能吞掉标题或数字。
    private static let claudeBlank = "[ \\n]*"

    /// 全称标题里的分隔符（U+00B7）。
    static let claudeTitleSeparator = "·"

    /// 标题字面量 → 正则。默认是「逐字符展开大小写的精确字面量」，与 0.2.16 完全一致。
    /// 唯一的例外是全称标题里的「·」分隔符：真实 DOM 会在这种分隔符上断行 / 插空格
    /// （10-11 截图里 Fable 那栏的说明就是在同一种分隔符上断的行），所以分隔符两侧允许一段空白
    /// （含换行），分隔符本身与两侧的词仍是精确字面量 —— 这就是「允许明确的空白规范化」的全部含义。
    /// 放宽只落在这一个分隔符上：带空格的英文标题（`All models` / `Claude Design`）一个字符都不放宽，
    /// `All\nmodels` 仍然不是标题（自检里逐个换行码位钉住了这一点）。
    private static func claudeTitleLiteral(_ title: String) -> String {
        let parts = title.components(separatedBy: claudeTitleSeparator)
        guard parts.count > 1 else { return asciiCaseInsensitive(title) }
        let separator = claudeBlank + NSRegularExpression.escapedPattern(for: claudeTitleSeparator) + claudeBlank
        return parts
            .map { asciiCaseInsensitive($0.trimmingCharacters(in: CharacterSet(charactersIn: " "))) }
            .joined(separator: separator)
    }

    /// 栏目标题后面那一行图标 / 折叠箭头的白名单（0.2.18）。
    /// 第一项 `U+E02A` 是 Root 2026-10-26 在真实 Claude 页上**实测**的字符（私用区图标字体）：
    /// 完整精确标题「每周限额 · 所有模型」之后那一行只有这一个码位，两个 Claude 标签一致
    /// （证据 dist/CLAUDE-LAYOUT-FIX-R1-RESULT-20261026.md）。初稿的白名单里没有它，
    /// 所以真实页上这一栏只有标题、没有数值 —— 这是正式整改 1/3 要修的那一条。
    /// 其余四个是明确的展示箭头，属于**有限兼容**：它们没有实测证据，只是常见写法，留着不花代价。
    /// 整条是**逐个登记的字面量白名单**，不是「略过一个字符」，也不是「略过私用区」：
    /// 没有码位区间、没有任意单字符通配，所以未登记的字符（相邻私用区码位、未知正文、
    /// 负号 `-` / `−`、顿号、句号、ASCII 字母…）一律让整条字段不成立 —— 宁缺勿错。
    /// 位置也只有这一处：别的槽位上出现这些字符同样不成立。另一折叠状态若用别的私用区字符，
    /// 本轮不推断、不预登记，等实测到再加一项。
    static let claudeDisclosureMarkers: [String] = ["\u{e02a}", ">", "›", "⌄", "▾"]

    /// 图标字符进正则时一律写成 `\uXXXX` 转义文本，理由与 `characterClass` 完全一致：
    /// 私用区 / 不可见字符直接写进源码既不可读，也会跟着探针脚本原样穿过 Apple Event；
    /// 转义文本在 ICU 与 JavaScript 里语义相同。ASCII 字符按常规转义，保持可读。
    private static func claudeMarkerPattern(_ marker: String) -> String {
        marker.unicodeScalars.map { scalar in
            scalar.isASCII
                ? NSRegularExpression.escapedPattern(for: String(Character(scalar)))
                : String(format: "\\u%04X", scalar.value)
        }.joined()
    }

    /// 标题与百分比之间唯一允许出现的「说明字段」白名单（整改 1/3 用它取代了初稿的任意说明行）。
    /// 必须是**完整字面量**：不是前缀、不是通配，也不允许在它前后夹别的正文，所以未知说明行、
    /// 未知栏目标题（`其他额度`）、拆到上一行的负号（`-`）都跨不过去。
    /// 整条白名单目前只有一项来自截图逐字（「当前会话」下面那句），外加同一句的旧英文文案。
    /// 「本周 Fable」自己的说明（`Fable 的单独每周限额 · 星期一`）故意**不**登记：Fable 不是指标，
    /// 不需要跨过它的说明去取值，少一条就少一个可被跨越的位置。
    /// 页面以后新增说明文案时，把文案原文加进这里即可；在那之前该栏是缺值，不会取到错的数。
    static let claudeDescriptionFields: [String] = [
        // 新中文页「当前会话」的说明（2026-10-11 截图逐字）。
        "从您的第一条消息开始",
        // 同一句的旧英文文案。本轮没有英文页截图可逐字核对，按整改要求一并登记；
        // 文案若与真实英文页不同，它只是永不命中的死字面量，不会放宽任何边界。
        "Since your first message"
    ]

    /// 标题与百分比之间、以及百分比之后唯一允许出现的「重置文本」字段。
    /// 英文旧布局（`Resets in 3h 12m` / `Resets in 5 minutes` / `Resets 2 hours` / `Resets Sep 10:00 AM`）
    /// 和中文倒计时 / `重置时间: …` 直接复用 Codex 整改时建立的同一份字段 —— 那份字段本身是中性的、与供应商无关。
    /// 只有日期、没有时刻的 `Resets Sep 30` 不在白名单里（0.2.15 的 Claude 口径同样不接受），重置就留空，
    /// 本轮不扩这条；
    /// 新中文页多出「星期一05:00 重置」「05:00 重置」这种「星期 + 时刻 + 重置」写法。
    /// 它同时是重置信息的唯一取值来源，所以重置必然与百分比来自同一次匹配、同一个栏目，
    /// 不会从另一个标题或说明句拼接过来。
    ///
    /// 星期与时刻之间允许 `[ \n]*`：截图里 Fable 那栏的 DOM 正是在这里断行（`… · 星期一` / `05:00 重置`），
    /// 所以这是**字段内部**一处明确的、可跨行的结构，而不是「跨行吞正文」—— 中间仍然只许空白，
    /// 任何正文都会让这个字段不成立。取到的文本里那次换行会在 `claudeResetText` 里压回一个空格。
    ///
    /// 0.2.18（2026-10-26 新布局）在这里加两样东西，都只加给 Claude：
    ///   - 星期前缀多一种简称写法：截图是「周一05:00 重置」，旧的「星期一」原样保留；
    ///   - 一条中文**复合**倒计时（`claudeChineseCountdown`）：截图是「1小时 37 分钟后重置」。
    /// 新写法一律**追加**在 `codexResetField` 之后：原先能匹配的文本仍由原来那条先命中，
    /// 取到的重置文本逐字不变（自检里 0.2.16 / 0.2.17 的重置断言全部原样保留）。
    private static let claudeResetField: String = {
        // 星期全称「星期一」与简称「周一」；两者之后都允许一次 DOM 断行再接时刻。
        let weekdayClock = #"(?:(?:星期|周)[一二三四五六日天][ \n]*)?[0-9]{1,2}:[0-9]{2}[ ]?重置"#
        return [codexResetField, weekdayClock, claudeChineseCountdown].joined(separator: "|")
    }()

    /// 中文**复合**倒计时（0.2.18，按 2026-10-26 截图的「1小时 37 分钟后重置」）。
    /// `codexResetField` 里那条中文倒计时只接受「可选的 N天 + 一个单位」，所以 0.2.17 在
    /// 「小时 + 分钟」这种两段写法上整条失配 —— 当前会话因此缺值，页面也可能判不就绪。
    ///
    /// 这里按**合法的降序单位**单独写一条：天 → 小时 → 分钟，每个单位最多出现一次、至少出现一个，
    /// 末尾必须是「后重置」。数字位数、单位与「后重置」仍是精确字面量，放宽只发生在词元边界上
    /// （`codexTokenGap` = 一段空白，可跨行，真实 DOM 会在这里断行）。于是**在这条规则里**：
    ///   - 顺序颠倒（`37分钟 1小时后重置`）、小时或分钟重复（`1小时 2小时后重置`）不是合法顺序；
    ///   - 边界上夹任何正文（`1小时 说明 37 分钟后重置`）或负号这个字段就不成立。
    /// 这条规则是**追加**的，不收紧任何既有写法：`codexResetField` 里「可选 N天 + 一个单位」照旧，
    /// 所以 `2天 3天后重置` 这种天重复仍然被接受，英文 `Resets in 3h 12m` 等写法也照旧兼容 ——
    /// 不要把它说成「所有重复单位都已禁绝」。
    /// **只给 Claude 用**：Codex 的重置字段本轮一个字符都不动（那边没有复合写法的证据，
    /// 它的「5 天 17 小时后重置」本来就由原来那条覆盖）。
    private static let claudeChineseCountdown: String = {
        let gap = codexTokenGap
        func unit(_ name: String) -> String { "[0-9]{1,3}\(gap)\(name)\(gap)" }
        let day = unit("天")
        let hour = unit("小时")
        let minute = unit("分钟")
        return "(?:\(day)(?:\(hour))?(?:\(minute))?|\(hour)(?:\(minute))?|\(minute))后重置"
    }()

    /// 一个栏目的「已使用百分比」口径。捕获组：1 = 百分比之前的重置文本（新中文页在这里），
    /// 2 / 3 = 数值（前缀式「已使用 68%」/ 后缀式「23% used」），4 = 百分比之后的重置文本
    /// （原英文布局把 `Resets in 3h 12m` 写在数值后面）。说明字段不捕获，只是被允许跨过去。
    ///
    /// 结构是一串**定长的白名单槽位**：标题 → 可选已知说明 → 可选已知重置 → 百分比 → 可选已知重置。
    /// 槽位之间只有 `blank`（`[ \n]*`，纯空白、可跨行、顺带吃掉只有空白的行），所以：
    ///   - 两个槽位之间塞不进任何正文 —— 这是整改 1/3 取代「任意说明行」的全部机制，不再有
    ///     `[^\n%]*` 这种通配，也不再需要在说明行开头做 `(?!已知标题)` 前瞻；
    ///   - 前导空白怎么回溯都没用：空白退让出来的位置上必须坐着某个白名单字面量，
    ///     ` 本周 Fable` / `\t本周 Fable` / `\u{feff}本周 Fable` / `\u{fffc}本周 Fable` 一律对不上，
    ///     ICU 与 JavaScript 两端同样 fail closed（初稿的洞 A 就在这里）；
    ///   - 槽位是定长的，所以不存在「多给几行就能跨过去」—— 想跨新文案只能把它登记成已知字段。
    /// 字段结束约束 `(?![ ]*[^ \n])` 要求整条匹配（含可选重置）之后本行只剩空白，
    /// 与开头「标题必须是完整字段」是同一个要求的两端。
    private static func claudeUsedPattern(titles: [String]) -> String {
        let labels = titles.map(claudeTitleLiteral).joined(separator: "|")
        let descriptions = claudeDescriptionFields.map(asciiCaseInsensitive).joined(separator: "|")
        // 0.2.18 新增的槽位：标题之后一个可选的图标 / 折叠箭头，同样是定长的白名单字面量。
        let markers = claudeDisclosureMarkers.map(claudeMarkerPattern).joined(separator: "|")
        let blank = claudeBlank
        let value = #"(100(?:\.0+)?|[0-9]{1,2}(?:\.[0-9]+)?)"#
        let usedMark = "(?:已使用|\(asciiCaseInsensitive("used")))"
        let percent = "(?:\(usedMark)\(blank)\(value)\(blank)%|\(value)\(blank)%\(blank)\(usedMark))"
        let fieldEnd = "(?![ ]*[^ \\n])"
        return "(?:^|\\n)[ ]*(?:\(labels))[ ]*[:：]?"
            + "(?:\(blank)(?:\(markers)))?"
            + "(?:\(blank)(?:\(descriptions)))?"
            + "(?:\(blank)(\(claudeResetField)))?"
            + blank
            + percent
            + "(?:\(blank)(\(claudeResetField)))?"
            + fieldEnd
    }

    /// 「标题确实单独成行」的口径：标题后面除了可选冒号只剩空白。用的就是取值口径里那条字段结束约束，
    /// 所以「本周 Fable」不算「本周」的标题，说明句前缀也不算标题。
    /// 0.2.18 的箭头槽位**不**加进这条：它只判断「标题是否单独成行」，用来区分「这一栏缺值」
    /// 与「这一栏不存在」。标题行尾真的带箭头时这一栏会从「缺值」变成「不存在」——
    /// 两者都不产出数值，差别只是卡片详情里少列一行，不影响状态栏与任何取值。
    private static func claudeTitlePattern(titles: [String]) -> String {
        let labels = titles.map(claudeTitleLiteral).joined(separator: "|")
        return "(?:^|\\n)[ ]*(?:\(labels))[ ]*[:：]?(?![ ]*[^ \\n])"
    }

    struct ClaudeSectionContract {
        let label: String
        let usedPattern: String
        let titlePattern: String
    }

    /// 每个栏目两条已编译口径，只在首次使用时拼一次。
    static let claudeSectionContracts: [ClaudeSectionContract] = claudeSections.map {
        ClaudeSectionContract(
            label: $0.label,
            usedPattern: claudeUsedPattern(titles: $0.titles),
            titlePattern: claudeTitlePattern(titles: $0.titles)
        )
    }

    /// 就绪探针的口径：任一**指标**栏目读出完整合法数值就算有数据，用的是同一条正则，
    /// 只把标题位置换成全部指标标题的并集。「本周 Fable」不在并集里，
    /// 所以「只有 Fable 有数值」的页面不算就绪 —— 和解析器一样不会把它当成总周额度。
    static let claudeReadyPattern = claudeUsedPattern(titles: claudeSections.flatMap { $0.titles })

    /// Claude 用量解析。每个栏目独立匹配自己的完整字段；解析不出就留空，绝不跨栏目取数、不编造数值。
    static func parseClaude(lines: [String]) -> [ClaudeMetric] {
        let text = codexNormalized(lines.joined(separator: "\n"))
        var metrics: [ClaudeMetric] = claudeSectionContracts.compactMap { claudeSectionMetric($0, in: text) }

        if let index = lines.firstIndex(where: { $0.localizedCaseInsensitiveContains("Daily included routine runs") || $0.contains("每日") }) {
            let window = Array(lines[index..<min(lines.count, index + 6)])
            if let value = window.first(where: { $0.range(of: #"^\d+\s*/\s*\d+$"#, options: .regularExpression) != nil }) {
                metrics.append(ClaudeMetric(label: "Daily included routine runs", usedPercent: nil, value: value, reset: nil))
            }
        }

        if let index = lines.firstIndex(where: { $0.localizedCaseInsensitiveContains("Last updated") || $0.contains("上次更新") }) {
            metrics.append(ClaudeMetric(label: "Last updated", usedPercent: nil, value: lines[index], reset: nil))
        }

        return metrics
    }

    /// 单个栏目：先按完整契约取「数值 + 同一次匹配里的重置文本」；取不到但标题确实单独成行时，
    /// 产出缺值指标（卡片详情里仍能看到这一栏存在，但不会有进度条，也不会进状态栏百分比）；
    /// 标题根本不在页面上就什么都不产出 —— 不存在的栏目不伪造。
    private static func claudeSectionMetric(_ contract: ClaudeSectionContract, in text: String) -> ClaudeMetric? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        // 不加 .caseInsensitive：大小写已经展开进正则，两端因此没有 case folding 这个变量。
        if let regex = try? NSRegularExpression(pattern: contract.usedPattern, options: []),
           let match = regex.firstMatch(in: text, range: range),
           let percent = (group(2, match, text) ?? group(3, match, text)).flatMap({ Double($0) }),
           (0...100).contains(percent) {
            return ClaudeMetric(
                label: contract.label,
                usedPercent: percent,
                value: nil,
                reset: (group(1, match, text) ?? group(4, match, text)).map(resetDisplayText)
            )
        }
        guard let titleRegex = try? NSRegularExpression(pattern: contract.titlePattern, options: []),
              titleRegex.firstMatch(in: text, range: range) != nil else {
            return nil
        }
        return ClaudeMetric(label: contract.label, usedPercent: nil, value: nil, reset: nil)
    }

    /// 重置字段内部允许在已知词元边界上跨换行（Claude 的星期 ↔ 时刻、0.2.17 起 Codex 中文倒计时的
    /// 数字 ↔ 单位 ↔「后重置」），取到的文本因此可能带 `\n`。卡片详情与进度条副标题都是单行控件，
    /// 这里把换行压回一个空格 —— 两个供应商共用这一处，别处不要再各写一份。
    /// 只处理换行：横向空白早在 `codexNormalized` 里压成单个空格了。
    private static func resetDisplayText(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\n", with: " ")
    }

    // `resetAfter` 原本只给 Codex 周额度用，重置信息改为与百分比同一次匹配后已无调用方，0.2.15 删除。
    // 0.2.15 的 Claude 辅助函数随本轮契约化一并删除，没有其它调用方：
    //   `extractPercent` / `extractAnyPercent`（逐行取百分比，含「任意百分比」兜底）、
    //   `percentAfter`（标题后 140 字符内任意百分比）、`resetEnglishAfter`（标题后 180 字符内找重置）、
    //   `compact`（把换行也压成空格，会让按行的边界判定失效）、`capture`。
    //   它们的职责现在由 `claudeUsedPattern` / `claudeTitlePattern` 这两条有界口径承担。
}

enum SnapshotRenderer {
    static func plainText(_ snapshot: Snapshot) -> String {
        var lines: [String] = []
        lines.append("\(appName) Snapshot \(appVersion)")
        lines.append("Updated: \(Formatters.date(snapshot.updatedAt))")
        lines.append("Status title: \(snapshot.statusTitle)")
        let mood = snapshot.statusMood(mode: .split, codexMetric: .weekly, claudeMetric: .allModels)
        lines.append("Status mood: \(mood.accessibilityLabel)")
        lines.append("")

        for card in snapshot.cards {
            lines.append("\(card.status.menuPrefix) \(card.provider): \(card.headline)")
            for detail in card.details {
                lines.append("  - \(detail)")
            }
            lines.append("")
        }

        // 只在 CLI 输出里附带实例诊断（候选 PID / 选中 PID / 阶段错误 / 事件计数），供独立复核。
        if !snapshot.diagnosticsLines.isEmpty {
            lines.append("浏览器实例诊断:")
            lines.append(contentsOf: snapshot.diagnosticsLines.map { "  \($0)" })
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}

final class SingleInstanceLock {
    private let fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    static func acquire() -> SingleInstanceLock? {
        let fm = FileManager.default
        guard let supportURL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(appName, isDirectory: true) else {
            return nil
        }

        do {
            try fm.createDirectory(at: supportURL, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let lockURL = supportURL.appendingPathComponent("\(appName).lock")
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            return nil
        }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            return nil
        }

        _ = ftruncate(fd, 0)
        if let data = "\(getpid())\n".data(using: .utf8) {
            data.withUnsafeBytes { buffer in
                if let baseAddress = buffer.baseAddress {
                    _ = Darwin.write(fd, baseAddress, data.count)
                }
            }
        }

        return SingleInstanceLock(fileDescriptor: fd)
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        Darwin.close(fileDescriptor)
    }
}

final class QuotaDashboardView: NSView {
    private let snapshot: Snapshot?
    private let style: VisualizationStyle
    private let isRefreshing: Bool
    private let cadenceNote: String?

    init(snapshot: Snapshot?, style: VisualizationStyle, isRefreshing: Bool, cadenceNote: String? = nil) {
        self.snapshot = snapshot
        self.style = style
        self.isRefreshing = isRefreshing
        self.cadenceNote = cadenceNote
        super.init(frame: NSRect(x: 0, y: 0, width: 430, height: Self.preferredHeight(snapshot: snapshot, style: style, isRefreshing: isRefreshing)))
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(rect: bounds).fill()

        let padding: CGFloat = 14
        let contentWidth = bounds.width - padding * 2
        var y: CGFloat = 12

        drawText(
            "\(appName)",
            in: NSRect(x: padding, y: y, width: 210, height: 22),
            font: .systemFont(ofSize: 15, weight: .semibold),
            color: .labelColor
        )
        drawText(
            "\(style.menuTitle)视图",
            in: NSRect(x: bounds.width - padding - 110, y: y + 1, width: 110, height: 18),
            font: .systemFont(ofSize: 12, weight: .medium),
            color: .secondaryLabelColor,
            alignment: .right
        )
        y += 25

        if isRefreshing {
            drawText(
                "正在刷新网页额度...",
                in: NSRect(x: padding, y: y, width: contentWidth, height: 18),
                font: .systemFont(ofSize: 12),
                color: .secondaryLabelColor
            )
        } else if let snapshot {
            let note = cadenceNote.map { " · \($0)" } ?? ""
            drawText(
                "更新于 \(Formatters.date(snapshot.updatedAt))\(note)",
                in: NSRect(x: padding, y: y, width: contentWidth, height: 18),
                font: .systemFont(ofSize: 12),
                color: .secondaryLabelColor
            )
        } else {
            drawText(
                "尚未读取数据",
                in: NSRect(x: padding, y: y, width: contentWidth, height: 18),
                font: .systemFont(ofSize: 12),
                color: .secondaryLabelColor
            )
        }
        y += 28

        guard let snapshot else { return }
        for card in snapshot.cards.prefix(4) {
            let height = Self.cardHeight(for: card, style: style)
            drawCard(card, rect: NSRect(x: padding, y: y, width: contentWidth, height: height))
            y += height + 10
        }
    }

    private static func preferredHeight(snapshot: Snapshot?, style: VisualizationStyle, isRefreshing: Bool) -> CGFloat {
        var height: CGFloat = 74
        if isRefreshing {
            height += 8
        }
        guard let snapshot else { return 132 }
        for card in snapshot.cards.prefix(4) {
            height += cardHeight(for: card, style: style) + 10
        }
        return max(160, min(height + 8, 760))
    }

    /// 沿用上次成功值时标题下方多一行失败原因。
    static let noteHeight: CGFloat = 16

    private static func cardHeight(for card: QuotaCard, style: VisualizationStyle) -> CGFloat {
        let noteExtra: CGFloat = card.note == nil ? 0 : noteHeight
        let progressCount = min(card.progress.count, 6)
        guard progressCount > 0 else { return 108 + noteExtra }

        switch style {
        case .bars:
            return 66 + CGFloat(progressCount) * 48 + noteExtra
        case .rings:
            let rows = Int(ceil(Double(progressCount) / 3.0))
            return 76 + CGFloat(rows) * 84 + noteExtra
        }
    }

    private func drawCard(_ card: QuotaCard, rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
        path.lineWidth = 1
        path.stroke()

        let dotRect = NSRect(x: rect.minX + 14, y: rect.minY + 17, width: 8, height: 8)
        accentColor(for: card.status).setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        drawText(
            card.provider,
            in: NSRect(x: rect.minX + 30, y: rect.minY + 12, width: rect.width - 44, height: 18),
            font: .systemFont(ofSize: 13, weight: .semibold),
            color: .labelColor
        )
        drawText(
            card.headline,
            in: NSRect(x: rect.minX + 14, y: rect.minY + 33, width: rect.width - 28, height: 18),
            font: .systemFont(ofSize: 12),
            color: .secondaryLabelColor
        )

        // 有进度条的卡片不显示 details；沿用上次成功值时必须把本次失败原因单独画出来，否则错误会被进度条吞掉。
        var contentTop: CGFloat = 58
        if let note = card.note {
            drawText(
                note,
                in: NSRect(x: rect.minX + 14, y: rect.minY + 51, width: rect.width - 28, height: 15),
                font: .systemFont(ofSize: 10.5),
                color: .systemOrange
            )
            contentTop += Self.noteHeight
        }
        let content = NSRect(x: rect.minX + 14, y: rect.minY + contentTop, width: rect.width - 28, height: rect.height - contentTop - 8)

        if card.progress.isEmpty {
            drawDetailLines(card.details, rect: content)
        } else {
            switch style {
            case .bars:
                drawBars(card.progress, rect: content)
            case .rings:
                drawRings(card.progress, rect: content)
            }
        }
    }

    private func drawBars(_ progressItems: [QuotaProgress], rect: NSRect) {
        let rowHeight: CGFloat = 48
        var y = rect.minY
        for item in progressItems.prefix(6) {
            drawText(
                item.label,
                in: NSRect(x: rect.minX, y: y, width: rect.width - 110, height: 17),
                font: .systemFont(ofSize: 12, weight: .medium),
                color: .labelColor
            )
            drawText(
                item.valueText,
                in: NSRect(x: rect.maxX - 106, y: y, width: 106, height: 17),
                font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                color: .secondaryLabelColor,
                alignment: .right
            )

            let track = NSRect(x: rect.minX, y: y + 22, width: rect.width, height: 9)
            NSColor.separatorColor.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: track, xRadius: 4.5, yRadius: 4.5).fill()

            let fillWidth = track.width * CGFloat(item.clampedPercent / 100.0)
            if fillWidth > 0 {
                let fillRect = NSRect(x: track.minX, y: track.minY, width: fillWidth, height: track.height)
                accentColor(forRemaining: item.clampedPercent).setFill()
                NSBezierPath(roundedRect: fillRect, xRadius: 4.5, yRadius: 4.5).fill()
            }

            if let detail = item.detail, !detail.isEmpty {
                drawText(
                    detail,
                    in: NSRect(x: rect.minX, y: y + 34, width: rect.width, height: 14),
                    font: .systemFont(ofSize: 10.5),
                    color: .tertiaryLabelColor
                )
            }
            y += rowHeight
        }
    }

    private func drawRings(_ progressItems: [QuotaProgress], rect: NSRect) {
        let columns = 3
        let cellWidth = rect.width / CGFloat(columns)
        let rowHeight: CGFloat = 84
        let radius: CGFloat = 23

        for (index, item) in progressItems.prefix(6).enumerated() {
            let column = index % columns
            let row = index / columns
            let originX = rect.minX + CGFloat(column) * cellWidth
            let originY = rect.minY + CGFloat(row) * rowHeight
            let center = NSPoint(x: originX + cellWidth / 2, y: originY + 27)

            let track = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            track.lineWidth = 6
            NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
            track.stroke()

            let arc = NSBezierPath()
            arc.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: -90,
                endAngle: -90 + CGFloat(360.0 * item.clampedPercent / 100.0),
                clockwise: false
            )
            arc.lineWidth = 6
            accentColor(forRemaining: item.clampedPercent).setStroke()
            arc.stroke()

            drawText(
                "\(Formatters.percentCompact(item.clampedPercent))%",
                in: NSRect(x: center.x - 28, y: center.y - 9, width: 56, height: 18),
                font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                color: .labelColor,
                alignment: .center
            )
            drawText(
                compactLabel(item.label),
                in: NSRect(x: originX + 4, y: originY + 56, width: cellWidth - 8, height: 17),
                font: .systemFont(ofSize: 10, weight: .medium),
                color: .secondaryLabelColor,
                alignment: .center
            )
            if let detail = item.detail {
                drawText(
                    compactDetail(detail),
                    in: NSRect(x: originX + 4, y: originY + 70, width: cellWidth - 8, height: 14),
                    font: .systemFont(ofSize: 9),
                    color: .tertiaryLabelColor,
                    alignment: .center
                )
            }
        }
    }

    private func drawDetailLines(_ details: [String], rect: NSRect) {
        let visible = Array(details.prefix(3))
        if visible.isEmpty {
            drawText(
                "暂无可视化百分比",
                in: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 18),
                font: .systemFont(ofSize: 11),
                color: .tertiaryLabelColor
            )
            return
        }

        for (index, detail) in visible.enumerated() {
            drawText(
                detail,
                in: NSRect(x: rect.minX, y: rect.minY + CGFloat(index) * 18, width: rect.width, height: 16),
                font: .systemFont(ofSize: 11),
                color: index == 0 ? .secondaryLabelColor : .tertiaryLabelColor
            )
        }
    }

    private func drawText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }

    private func accentColor(for status: StatusLevel) -> NSColor {
        switch status {
        case .ok: return .systemGreen
        case .warning: return .systemOrange
        case .unavailable: return .systemGray
        case .error: return .systemRed
        }
    }

    private func accentColor(forRemaining percent: Double) -> NSColor {
        if percent < 15 { return .systemRed }
        if percent < 35 { return .systemOrange }
        return .systemGreen
    }

    private func compactLabel(_ label: String) -> String {
        label
            .replacingOccurrences(of: "GPT-5.3-Codex-Spark ", with: "Spark ")
            .replacingOccurrences(of: "使用限额", with: "")
            .replacingOccurrences(of: "Current session", with: "Session")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func compactDetail(_ detail: String) -> String {
        detail
            .replacingOccurrences(of: "重置时间: ", with: "")
            .replacingOccurrences(of: "Resets in ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 「本次读取详情」文本：只读已保存的 snapshot（沿用卡片里的本轮阶段 / 错误码 / 原因 / 建议与上次成功时间，
/// 以及实例诊断行），不抓网页。菜单入口与自检共用同一生成函数。
enum ReadDetailsText {
    static func render(snapshot: Snapshot?, style: VisualizationStyle, isRefreshing: Bool, lastRefreshAt: Date?) -> String {
        var lines: [String] = []
        lines.append("\(appName) \(appVersion) · 本次读取详情")
        lines.append("视图: \(style.menuTitle) · \(isRefreshing ? "正在刷新（显示的是上一轮结果）" : "空闲")")
        guard let snapshot else {
            lines.append("")
            lines.append("尚未读取过数据。点「立即刷新」后再打开。")
            return lines.joined(separator: "\n")
        }
        lines.append("本轮刷新时间: \(Formatters.date(snapshot.updatedAt))")
        if let lastRefreshAt {
            lines.append("上次刷新: \(Formatters.date(lastRefreshAt))")
        }
        lines.append("")
        for card in snapshot.cards where card.provider.hasSuffix("网页额度") {
            lines.append("\(card.status.menuPrefix) \(card.provider): \(card.headline)")
            if let note = card.note {
                lines.append("  ⚠ \(note)")
            }
            if let confirmedAt = card.confirmedAt {
                lines.append("  本轮已确认新鲜值: \(Formatters.date(confirmedAt))")
            } else {
                lines.append("  本轮未确认新鲜值（状态栏显示的是上次成功值，或无数据）")
            }
            for detail in card.details {
                lines.append("  - \(detail)")
            }
            lines.append("")
        }
        let localCards = snapshot.cards.filter { !$0.provider.hasSuffix("网页额度") }
        if !localCards.isEmpty {
            lines.append("本机记录:")
            for card in localCards {
                lines.append("  \(card.status.menuPrefix) \(card.provider): \(card.headline)")
            }
            lines.append("")
        }
        if !snapshot.diagnosticsLines.isEmpty {
            lines.append("浏览器实例诊断:")
            lines.append(contentsOf: snapshot.diagnosticsLines.map { "  \($0)" })
            lines.append("")
        }
        lines.append("说明: 本窗口只显示已保存的上一轮结果，不会重新抓取网页；点「立即刷新」后再打开可查看新结果。")
        return lines.joined(separator: "\n")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private struct LastGoodWebCard {
        let card: QuotaCard
        let at: Date
    }

    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private let configStore = ConfigStore()
    private let statusIcon = AppDelegate.makeStatusIcon()
    private var config = AppConfig.defaultValue
    private var snapshot: Snapshot?
    private var isRefreshing = false
    private var visualStyle = VisualizationStyle.load()
    private var refreshCadence = RefreshCadence.load()
    private var statusMode = StatusDisplayMode.load()
    private var codexStatusMetric = CodexStatusMetric.load()
    private var claudeStatusMetric = ClaudeStatusMetric.load()

    private var powerSavingEnabled = PowerSavingSetting.load()
    private var systemAsleep = false
    private var screensAsleep = false
    private var lastRefreshStartedAt: Date?
    private var lastSuccessAt: Date?
    private var nextAutoRefreshAt: Date?
    private var pendingManualRefresh = false
    private var lastWakeHandledAt: Date?
    private var menuIsOpen = false
    private var menuNeedsRebuild = false
    /// 最近一次「读到完整网页」的原始卡片。沿用提示每轮都基于这份原件重建，因此不会逐轮叠加。
    private var lastGoodWebCards: [String: LastGoodWebCard] = [:]
    /// 「本次读取详情」窗口：原生滚动文本视图，按需创建，只显示已保存的 snapshot。
    private var detailsWindow: NSWindow?
    private var detailsTextView: NSTextView?

    /// 当前已保存的展示 snapshot（沿用逻辑之后）。
    var currentSnapshot: Snapshot? { snapshot }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        terminateOtherRunningCopies()
        config = configStore.loadOrCreate()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = statusIcon
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
        }
        applyStatusTitle("AI")
        rebuildMenu()
        registerPowerObservers()
        refresh(trigger: .manual)
        scheduleTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        ClaudeCodeUsageStore.shared.flushPersistedCache()
    }

    // MARK: - 电源 / 睡眠事件

    private func registerPowerObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(handleSystemWillSleep(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(handleSystemDidWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(handleScreensDidSleep(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(handleScreensDidWake(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePowerStateChanged(_:)),
            name: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )
    }

    @objc private func handleSystemWillSleep(_ notification: Notification) {
        systemAsleep = true
        applyPauseState()
    }

    @objc private func handleSystemDidWake(_ notification: Notification) {
        systemAsleep = false
        handleWake()
    }

    @objc private func handleScreensDidSleep(_ notification: Notification) {
        screensAsleep = true
        applyPauseState()
    }

    @objc private func handleScreensDidWake(_ notification: Notification) {
        screensAsleep = false
        handleWake()
    }

    @objc private func handlePowerStateChanged(_ notification: Notification) {
        // 该通知可能来自任意线程。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduleTimer()
            self.rebuildMenu()
        }
    }

    /// 唤醒处理：多个唤醒通知只生效一次；只有真的过期才补一次刷新，不做堆积补刷。
    private func handleWake() {
        // 系统唤醒与屏幕唤醒的到达顺序不确定：只要还有任一暂停条件成立就先不消耗去重令牌。
        guard autoRefreshPauseReason == nil else {
            rebuildMenu()
            return
        }

        let now = Date()
        if let lastWakeHandledAt, now.timeIntervalSince(lastWakeHandledAt) < 5 {
            if timer == nil {
                scheduleTimer()
            }
            rebuildMenu()
            return
        }
        lastWakeHandledAt = now

        // 唤醒后只有真的过期才补一次；否则只把定时器排到剩余时间，不扎堆补刷。
        if case .fire = schedulerPolicy.decide(now: now, lastRefreshStartedAt: lastRefreshStartedAt) {
            refresh(trigger: .automatic)
        }
        scheduleTimer()
        rebuildMenu()
    }

    private func applyPauseState() {
        if autoRefreshPauseReason != nil {
            timer?.invalidate()
            timer = nil
            nextAutoRefreshAt = nil
        } else if timer == nil {
            scheduleTimer()
        }
        rebuildMenu()
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        // 用户能看到菜单，说明屏幕肯定是亮的；作为睡眠/唤醒通知丢失时的兜底。
        if screensAsleep || systemAsleep {
            screensAsleep = false
            systemAsleep = false
            handleWake()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        if menuNeedsRebuild {
            menuNeedsRebuild = false
            rebuildMenu()
        }
    }

    private func terminateOtherRunningCopies() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.local.aiquotabar")
            where app.processIdentifier != currentPID {
            app.terminate()
        }
    }

    @objc private func refreshMenuAction(_ sender: NSMenuItem) {
        // 手动刷新永远走完整流程：重新 reload 网页并立即取新数据。
        refresh(trigger: .manual)
    }

    @objc private func showReadDetailsAction(_ sender: NSMenuItem) {
        showReadDetails()
    }

    /// 刷新结束后的统一入口：沿用逻辑 → 保存 snapshot → 更新刷新时间。自检通过它注入 snapshot 后读取详情文本。
    @discardableResult
    func store(latest: Snapshot) -> Snapshot {
        let displaySnapshot = applyWebCardContinuity(to: latest)
        snapshot = displaySnapshot
        lastSuccessAt = displaySnapshot.updatedAt
        return displaySnapshot
    }

    /// 「本次读取详情」的完整文本：只读当前已保存的 snapshot，不抓网页。
    func readDetailsText() -> String {
        ReadDetailsText.render(snapshot: snapshot, style: visualStyle, isRefreshing: isRefreshing, lastRefreshAt: lastSuccessAt)
    }

    /// 原生滚动文本窗口，避免改动仪表盘布局；每次打开都从已保存的 snapshot 重新生成文本。
    private func showReadDetails() {
        let text = readDetailsText()
        if detailsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 660, height: 540),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "\(appName) · 本次读取详情"
            window.isReleasedWhenClosed = false
            window.center()
            let scrollView = NSScrollView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 660, height: 540))
            scrollView.autoresizingMask = [.width, .height]
            scrollView.hasVerticalScroller = true
            scrollView.borderType = .noBorder
            let textView = NSTextView(frame: scrollView.bounds)
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.textContainerInset = NSSize(width: 12, height: 12)
            textView.autoresizingMask = [.width]
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            scrollView.documentView = textView
            window.contentView = scrollView
            detailsWindow = window
            detailsTextView = textView
        }
        detailsTextView?.string = text
        detailsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 刷新结束时，若详情窗口正打开则用新保存的 snapshot 重新生成文本（仍不抓网页）。
    private func refreshReadDetailsWindowIfVisible() {
        guard detailsWindow?.isVisible == true else { return }
        detailsTextView?.string = readDetailsText()
    }

    @objc private func togglePowerSavingAction(_ sender: NSMenuItem) {
        powerSavingEnabled.toggle()
        PowerSavingSetting.save(powerSavingEnabled)
        scheduleTimer()
        rebuildMenu()
    }

    @objc private func openConfigAction(_ sender: NSMenuItem) {
        configStore.openConfigFile()
    }

    @objc private func setBarsStyleAction(_ sender: NSMenuItem) {
        setVisualStyle(.bars)
    }

    @objc private func setRingsStyleAction(_ sender: NSMenuItem) {
        setVisualStyle(.rings)
    }

    @objc private func setOneMinuteRefreshAction(_ sender: NSMenuItem) {
        setRefreshCadence(.oneMinute)
    }

    @objc private func setThreeMinuteRefreshAction(_ sender: NSMenuItem) {
        setRefreshCadence(.threeMinutes)
    }

    @objc private func setFiveMinuteRefreshAction(_ sender: NSMenuItem) {
        setRefreshCadence(.fiveMinutes)
    }

    @objc private func setTenMinuteRefreshAction(_ sender: NSMenuItem) {
        setRefreshCadence(.tenMinutes)
    }

    @objc private func setSplitStatusAction(_ sender: NSMenuItem) {
        setStatusMode(.split)
    }

    @objc private func setLowestStatusAction(_ sender: NSMenuItem) {
        setStatusMode(.lowest)
    }

    @objc private func setClaudeStatusAction(_ sender: NSMenuItem) {
        setStatusMode(.claude)
    }

    @objc private func setCodexStatusAction(_ sender: NSMenuItem) {
        setStatusMode(.codex)
    }

    @objc private func setCodexWeeklyMetricAction(_ sender: NSMenuItem) {
        setCodexStatusMetric(.weekly)
    }

    @objc private func setClaudeCurrentSessionMetricAction(_ sender: NSMenuItem) {
        setClaudeStatusMetric(.currentSession)
    }

    @objc private func setClaudeAllModelsMetricAction(_ sender: NSMenuItem) {
        setClaudeStatusMetric(.allModels)
    }

    @objc private func setClaudeDesignMetricAction(_ sender: NSMenuItem) {
        setClaudeStatusMetric(.claudeDesign)
    }

    @objc private func revealSetupScriptAction(_ sender: NSMenuItem) {
        if let script = Bundle.main.resourceURL?.appendingPathComponent("Scripts/set-key.sh"),
           FileManager.default.fileExists(atPath: script.path) {
            NSWorkspace.shared.activateFileViewerSelecting([script])
        } else {
            NSWorkspace.shared.open(configStore.applicationSupportURL)
        }
    }

    @objc private func openOpenAIUsageAction(_ sender: NSMenuItem) {
        if let url = URL(string: "https://platform.openai.com/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openAnthropicUsageAction(_ sender: NSMenuItem) {
        if let url = URL(string: "https://console.anthropic.com/settings/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openCodexBrowserUsageAction(_ sender: NSMenuItem) {
        if let url = URL(string: BrowserUsageTargets.codexUsageURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openClaudeBrowserUsageAction(_ sender: NSMenuItem) {
        if let url = URL(string: BrowserUsageTargets.claudeUsageURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quitAction(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    private func setVisualStyle(_ style: VisualizationStyle) {
        visualStyle = style
        style.save()
        rebuildMenu()
    }

    private func setRefreshCadence(_ cadence: RefreshCadence) {
        refreshCadence = cadence
        cadence.save()
        scheduleTimer()
        rebuildMenu()
        refresh(trigger: .manual)
    }

    private func setStatusMode(_ mode: StatusDisplayMode) {
        statusMode = mode
        mode.save()
        if let snapshot {
            applyStatusDisplay(snapshot)
        } else {
            applyStatusTitle("AI")
        }
        rebuildMenu()
    }

    private func setCodexStatusMetric(_ metric: CodexStatusMetric) {
        codexStatusMetric = metric
        metric.save()
        if let snapshot {
            applyStatusDisplay(snapshot)
        }
        rebuildMenu()
    }

    private func setClaudeStatusMetric(_ metric: ClaudeStatusMetric) {
        claudeStatusMetric = metric
        metric.save()
        if let snapshot {
            applyStatusDisplay(snapshot)
        }
        rebuildMenu()
    }

    // MARK: - 自动刷新节奏

    private var schedulerPolicy: RefreshSchedulerPolicy {
        RefreshSchedulerPolicy(
            baseInterval: refreshCadence.seconds,
            powerSavingEnabled: powerSavingEnabled,
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            systemAsleep: systemAsleep,
            screensAsleep: screensAsleep
        )
    }

    private var effectiveRefreshInterval: TimeInterval {
        schedulerPolicy.effectiveInterval
    }

    private var isLowPowerRelaxed: Bool {
        schedulerPolicy.isLowPowerRelaxed
    }

    private var autoRefreshPauseReason: String? {
        schedulerPolicy.pauseReason
    }

    /// 一次性定时器 + 每轮重排：间隔可随低电量状态变化，手动刷新后自动顺延，也不会出现补刷堆积。
    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        nextAutoRefreshAt = nil

        guard let delay = schedulerPolicy.nextDelay(now: Date(), lastRefreshStartedAt: lastRefreshStartedAt) else {
            return
        }
        let scheduled = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.handleTimerFired()
        }
        // 约 10% 容差，让系统把唤醒合并到其它定时器上。
        scheduled.tolerance = max(1, delay * 0.1)
        RunLoop.main.add(scheduled, forMode: .default)
        timer = scheduled
        nextAutoRefreshAt = Date().addingTimeInterval(delay)
    }

    private func handleTimerFired() {
        // 手动刷新可能刚刚跑过：按 lastRefreshStartedAt 复核，没到期就只顺延，不重复 reload 网页。
        switch schedulerPolicy.decide(now: Date(), lastRefreshStartedAt: lastRefreshStartedAt) {
        case .paused:
            rebuildMenu()
        case .wait:
            scheduleTimer()
        case .fire:
            if isRefreshing {
                // 上一轮刷新还没结束（比如网页很慢）：记为一次尝试并等一个完整间隔，避免 15 秒一次空转。
                lastRefreshStartedAt = Date()
            } else {
                refresh(trigger: .automatic)
            }
            scheduleTimer()
        }
    }

    private func refresh(trigger: RefreshTrigger) {
        // 暂停期间不做自动刷新；手动刷新可以越过暂停状态。
        if trigger == .automatic, autoRefreshPauseReason != nil {
            return
        }
        // 防重入：正在刷新时最多只累积一个待处理的手动请求，不做无限重试。
        guard !isRefreshing else {
            if trigger == .manual {
                pendingManualRefresh = true
            }
            return
        }

        isRefreshing = true
        lastRefreshStartedAt = Date()
        applyStatusTitle("AI ...")
        rebuildMenu()

        // 自动刷新用 utility 优先级，手动刷新用 userInitiated。
        let priority: TaskPriority = trigger == .manual ? .userInitiated : .utility
        Task(priority: priority) {
            let latestConfig = configStore.loadOrCreate()
            let collector = QuotaCollector(config: latestConfig)
            let latestSnapshot = await collector.collect()

            await MainActor.run {
                self.config = latestConfig
                let displaySnapshot = self.store(latest: latestSnapshot)
                self.isRefreshing = false
                self.applyStatusDisplay(displaySnapshot)
                self.rebuildMenu()
                self.refreshReadDetailsWindowIfVisible()

                if self.pendingManualRefresh {
                    self.pendingManualRefresh = false
                    self.refresh(trigger: .manual)
                } else {
                    // 刷新（含手动刷新）结束后顺延自动定时器，避免几秒后又自动 reload 一次网页。
                    self.scheduleTimer()
                }
            }
        }
    }

    /// 网页读取失败时沿用上次**已确认**的成功数据（`QuotaCard.confirmedAt` 非空）。
    /// 契约：只有 reload 成功 + 就绪确认 + 读取成功 + 解析到额度的卡片才能成为新的 lastGood 并更新成功时间；
    /// reload 失败 / 未就绪 / 看门狗 / 身份失效 / 权限失败的卡片没有 `confirmedAt`，绝不覆盖 lastGood。
    /// 沿用卡片每轮都基于「上次成功的原始卡片 + 本轮失败卡片的具体原因」重建，连续失败不会累积重复提示；
    /// `Snapshot.diagnosticsLines` 原样保留。没有 lastGood 时如实显示本轮失败卡片，不伪造新鲜数据。
    func applyWebCardContinuity(to latest: Snapshot) -> Snapshot {
        var cards = latest.cards
        for provider in ["Codex 网页额度", "Claude 网页额度"] {
            guard let index = cards.firstIndex(where: { $0.provider == provider }) else { continue }
            let card = cards[index]

            if let confirmedAt = card.confirmedAt, !card.progress.isEmpty {
                lastGoodWebCards[provider] = LastGoodWebCard(card: card, at: confirmedAt)
                continue
            }
            guard let lastGood = lastGoodWebCards[provider] else { continue }
            cards[index] = Self.continuityCard(lastGood: lastGood.card, confirmedAt: lastGood.at, current: card)
        }
        return Snapshot(updatedAt: latest.updatedAt, cards: cards, diagnosticsLines: latest.diagnosticsLines)
    }

    /// 沿用卡片：标题 / 进度 / 状态栏百分比来自上次已确认的成功卡片；details 先放本轮失败的标题与全部
    /// 具体原因（阶段、OSStatus、可操作提示），再放上次成功的时间与数值；`note` 让面板在标题下直接显示本次失败原因。
    static func continuityCard(lastGood: QuotaCard, confirmedAt: Date, current: QuotaCard) -> QuotaCard {
        var details = ["本次读取未成功: \(current.headline)"]
        details.append(contentsOf: current.details.filter { $0 != ChromeCardBuilder.continuityNote }.prefix(8))
        details.append("以下是 \(Formatters.date(confirmedAt)) 已确认的上次成功值:")
        details.append(contentsOf: lastGood.details)
        return QuotaCard(
            provider: lastGood.provider,
            headline: "\(lastGood.headline)（沿用 \(Formatters.clock(confirmedAt)) 成功值）",
            details: details,
            status: .warning,
            remainingUSD: lastGood.remainingUSD,
            statusBarHint: lastGood.statusBarHint,
            progress: lastGood.progress,
            confirmedAt: nil,
            note: "本次未成功: \(current.headline) · 显示 \(Formatters.clock(confirmedAt)) 的值"
        )
    }

    private func applyStatusDisplay(_ snapshot: Snapshot) {
        let title = snapshot.statusTitle(mode: statusMode, codexMetric: codexStatusMetric, claudeMetric: claudeStatusMetric)
        let mood = snapshot.statusMood(mode: statusMode, codexMetric: codexStatusMetric, claudeMetric: claudeStatusMetric)
        guard statusMode == .split, let button = statusItem.button else {
            applyStatusTitle(title, showIcon: false, mood: mood)
            return
        }

        button.image = Self.makeSplitStatusImage(
            mood: mood,
            claude: snapshot.claudeHint(metric: claudeStatusMetric),
            codex: snapshot.codexHint(metric: codexStatusMetric)
        )
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = "\(mood.accessibilityLabel) · \(title) · 点击查看 AI 额度"
        button.setAccessibilityTitle("\(mood.accessibilityLabel) \(title)")
    }

    private func applyStatusTitle(_ title: String, showIcon: Bool = true, mood: QuotaMood? = nil) {
        guard let button = statusItem.button else { return }
        let image = mood.map { Self.makeMoodStatusIcon($0) } ?? (showIcon ? statusIcon : nil)
        button.image = image
        button.imagePosition = image == nil ? .noImage : .imageLeading
        if image == nil {
            button.title = title
        } else if title.hasPrefix("AI ") {
            button.title = String(title.dropFirst(3))
        } else if title == "AI" {
            button.title = ""
        } else {
            button.title = title
        }
        let moodPrefix = mood.map { "\($0.accessibilityLabel) · " } ?? ""
        button.toolTip = "\(moodPrefix)\(title) · 点击查看 AI 额度"
        button.setAccessibilityTitle("\(moodPrefix)\(title)")
    }

    /// 菜单打开期间不替换 NSMenu，关闭后再补一次重建。
    private func rebuildMenu() {
        guard !menuIsOpen else {
            menuNeedsRebuild = true
            return
        }
        let menu = makeMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// 菜单第一行：让用户一眼知道数据新鲜度与当前节能状态。
    private func cadenceStatusLine() -> String {
        if let reason = autoRefreshPauseReason {
            return "自动刷新: 已暂停（\(reason)）"
        }
        let minutes = effectiveRefreshInterval / 60
        let minutesText = minutes == minutes.rounded() ? "\(Int(minutes))" : String(format: "%.1f", minutes)
        var text = "自动刷新: 每 \(minutesText) 分钟"
        if isLowPowerRelaxed {
            text += "（低电量已放宽）"
        } else if powerSavingEnabled {
            text += "（节能模式开）"
        }
        return text
    }

    private func freshnessLine() -> String {
        var parts: [String] = []
        if let lastSuccessAt {
            parts.append("上次刷新 \(Formatters.clock(lastSuccessAt))")
        } else {
            parts.append("尚未刷新")
        }
        if isRefreshing {
            parts.append("正在刷新")
        } else if autoRefreshPauseReason != nil {
            parts.append("唤醒后恢复")
        } else if let nextAutoRefreshAt {
            parts.append("下次 \(Formatters.clock(nextAutoRefreshAt))")
        }
        return parts.joined(separator: " · ")
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let dashboard = NSMenuItem()
        dashboard.view = QuotaDashboardView(
            snapshot: snapshot,
            style: visualStyle,
            isRefreshing: isRefreshing,
            cadenceNote: cadenceStatusLine()
        )
        menu.addItem(dashboard)

        menu.addItem(.separator())
        addAction(menu, title: "立即刷新", action: #selector(refreshMenuAction(_:)))
        // 只读入口：展示已保存 snapshot 的阶段 / 错误码 / 原因 / 建议 / 上次成功时间，不会再次抓网页。
        addAction(menu, title: "本次读取详情…", action: #selector(showReadDetailsAction(_:)))
        addAction(menu, title: "打开配置文件", action: #selector(openConfigAction(_:)))

        menu.addItem(.separator())
        addStyleAction(menu, title: "长条视图", style: .bars, action: #selector(setBarsStyleAction(_:)))
        addStyleAction(menu, title: "圆环视图", style: .rings, action: #selector(setRingsStyleAction(_:)))

        menu.addItem(.separator())
        addDisabled(menu, title: "状态栏显示")
        addStatusModeAction(menu, mode: .split, action: #selector(setSplitStatusAction(_:)))
        addStatusModeAction(menu, mode: .lowest, action: #selector(setLowestStatusAction(_:)))
        addStatusModeAction(menu, mode: .claude, action: #selector(setClaudeStatusAction(_:)))
        addStatusModeAction(menu, mode: .codex, action: #selector(setCodexStatusAction(_:)))

        menu.addItem(.separator())
        addDisabled(menu, title: "Codex 状态栏指标")
        addCodexMetricAction(menu, metric: .weekly, action: #selector(setCodexWeeklyMetricAction(_:)))

        menu.addItem(.separator())
        addDisabled(menu, title: "Claude 状态栏指标")
        addClaudeMetricAction(menu, metric: .currentSession, action: #selector(setClaudeCurrentSessionMetricAction(_:)))
        addClaudeMetricAction(menu, metric: .allModels, action: #selector(setClaudeAllModelsMetricAction(_:)))
        addClaudeMetricAction(menu, metric: .claudeDesign, action: #selector(setClaudeDesignMetricAction(_:)))

        menu.addItem(.separator())
        addDisabled(menu, title: "自动刷新额度页")
        addDisabled(menu, title: "  \(cadenceStatusLine())")
        addDisabled(menu, title: "  \(freshnessLine())")
        addPowerSavingToggle(menu)
        addCadenceAction(menu, cadence: .oneMinute, action: #selector(setOneMinuteRefreshAction(_:)))
        addCadenceAction(menu, cadence: .threeMinutes, action: #selector(setThreeMinuteRefreshAction(_:)))
        addCadenceAction(menu, cadence: .fiveMinutes, action: #selector(setFiveMinuteRefreshAction(_:)))
        addCadenceAction(menu, cadence: .tenMinutes, action: #selector(setTenMinuteRefreshAction(_:)))

        menu.addItem(.separator())
        addAction(menu, title: "打开 Codex 网页额度", action: #selector(openCodexBrowserUsageAction(_:)))
        addAction(menu, title: "打开 Claude 网页额度", action: #selector(openClaudeBrowserUsageAction(_:)))

        menu.addItem(.separator())
        addAction(menu, title: "退出", action: #selector(quitAction(_:)))
        return menu
    }

    private func addAction(_ menu: NSMenu, title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func addDisabled(_ menu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addStyleAction(_ menu: NSMenu, title: String, style: VisualizationStyle, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = visualStyle == style ? .on : .off
        menu.addItem(item)
    }

    private func addPowerSavingToggle(_ menu: NSMenu) {
        let item = NSMenuItem(
            title: "节能模式（睡眠/息屏暂停 · 低电量≥10 分钟）",
            action: #selector(togglePowerSavingAction(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.state = powerSavingEnabled ? .on : .off
        menu.addItem(item)
    }

    private func addCadenceAction(_ menu: NSMenu, cadence: RefreshCadence, action: Selector) {
        let item = NSMenuItem(title: cadence.menuTitle, action: action, keyEquivalent: "")
        item.target = self
        item.state = refreshCadence == cadence ? .on : .off
        menu.addItem(item)
    }

    private func addStatusModeAction(_ menu: NSMenu, mode: StatusDisplayMode, action: Selector) {
        let item = NSMenuItem(title: mode.menuTitle, action: action, keyEquivalent: "")
        item.target = self
        item.state = statusMode == mode ? .on : .off
        menu.addItem(item)
    }

    private func addCodexMetricAction(_ menu: NSMenu, metric: CodexStatusMetric, action: Selector) {
        let item = NSMenuItem(title: metric.menuTitle, action: action, keyEquivalent: "")
        item.target = self
        item.state = codexStatusMetric == metric ? .on : .off
        menu.addItem(item)
    }

    private func addClaudeMetricAction(_ menu: NSMenu, metric: ClaudeStatusMetric, action: Selector) {
        let item = NSMenuItem(title: metric.menuTitle, action: action, keyEquivalent: "")
        item.target = self
        item.state = claudeStatusMetric == metric ? .on : .off
        menu.addItem(item)
    }

    private static func makeStatusIcon() -> NSImage? {
        let image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "AIQuotaBar")
        image?.isTemplate = true
        return image
    }

    private static func makeSplitStatusImage(mood: QuotaMood, claude: String?, codex: String?) -> NSImage {
        let size = NSSize(width: 63, height: 22)
        return NSImage(size: size, flipped: true) { rect in
            NSColor.clear.setFill()
            NSBezierPath(rect: rect).fill()

            drawMoodGlyph(mood, in: NSRect(x: 1, y: 3, width: 15, height: 15))

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            paragraph.lineBreakMode = .byClipping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]

            let claudeText = "A \(claude ?? "--")"
            let codexText = "C \(codex ?? "--")"
            (claudeText as NSString).draw(in: NSRect(x: 19, y: 1, width: size.width - 20, height: 10), withAttributes: attributes)
            (codexText as NSString).draw(in: NSRect(x: 19, y: 11, width: size.width - 20, height: 10), withAttributes: attributes)
            return true
        }
    }

    private static func makeMoodStatusIcon(_ mood: QuotaMood) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        return NSImage(size: size, flipped: true) { rect in
            NSColor.clear.setFill()
            NSBezierPath(rect: rect).fill()
            drawMoodGlyph(mood, in: rect.insetBy(dx: 1.5, dy: 1.5))
            return true
        }
    }

    private static func drawMoodGlyph(_ mood: QuotaMood, in rect: NSRect) {
        let stroke = NSColor.labelColor
        stroke.setStroke()

        let face = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
        face.lineWidth = 1.5
        face.stroke()

        func dot(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat = 0.9) {
            let path = NSBezierPath(ovalIn: NSRect(x: rect.minX + rect.width * x - radius, y: rect.minY + rect.height * y - radius, width: radius * 2, height: radius * 2))
            stroke.setFill()
            path.fill()
        }

        dot(0.36, 0.42)
        dot(0.64, 0.42)

        let mouth = NSBezierPath()
        mouth.lineWidth = 1.45
        mouth.lineCapStyle = .round
        mouth.lineJoinStyle = .round

        switch mood {
        case .happy:
            mouth.move(to: NSPoint(x: rect.minX + rect.width * 0.31, y: rect.minY + rect.height * 0.58))
            mouth.curve(
                to: NSPoint(x: rect.minX + rect.width * 0.69, y: rect.minY + rect.height * 0.58),
                controlPoint1: NSPoint(x: rect.minX + rect.width * 0.40, y: rect.minY + rect.height * 0.74),
                controlPoint2: NSPoint(x: rect.minX + rect.width * 0.60, y: rect.minY + rect.height * 0.74)
            )
        case .steady, .unknown:
            mouth.move(to: NSPoint(x: rect.minX + rect.width * 0.34, y: rect.minY + rect.height * 0.65))
            mouth.line(to: NSPoint(x: rect.minX + rect.width * 0.66, y: rect.minY + rect.height * 0.65))
        case .worried:
            mouth.move(to: NSPoint(x: rect.minX + rect.width * 0.31, y: rect.minY + rect.height * 0.72))
            mouth.curve(
                to: NSPoint(x: rect.minX + rect.width * 0.69, y: rect.minY + rect.height * 0.72),
                controlPoint1: NSPoint(x: rect.minX + rect.width * 0.40, y: rect.minY + rect.height * 0.56),
                controlPoint2: NSPoint(x: rect.minX + rect.width * 0.60, y: rect.minY + rect.height * 0.56)
            )
        case .urgent:
            let openMouth = NSBezierPath(ovalIn: NSRect(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.58, width: rect.width * 0.12, height: rect.height * 0.22))
            openMouth.lineWidth = 1.3
            openMouth.stroke()
        }

        if mood != .urgent {
            mouth.stroke()
        }

        if mood == .urgent {
            let brow = NSBezierPath()
            brow.lineWidth = 1.25
            brow.lineCapStyle = .round
            brow.move(to: NSPoint(x: rect.minX + rect.width * 0.27, y: rect.minY + rect.height * 0.31))
            brow.line(to: NSPoint(x: rect.minX + rect.width * 0.43, y: rect.minY + rect.height * 0.35))
            brow.move(to: NSPoint(x: rect.minX + rect.width * 0.73, y: rect.minY + rect.height * 0.31))
            brow.line(to: NSPoint(x: rect.minX + rect.width * 0.57, y: rect.minY + rect.height * 0.35))
            brow.stroke()
        }
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// 「本次读取详情…」只有在已保存过 snapshot 时可用；其它菜单项维持原有启用状态。
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(showReadDetailsAction(_:)) {
            return snapshot != nil
        }
        return true
    }
}

// MARK: - 本地确定性回归测试 / benchmark（不依赖 Chrome 权限，不读取用户会话内容）

final class TestReporter {
    private(set) var passed = 0
    private(set) var failed = 0
    private(set) var skipped = 0
    private var currentGroup = ""

    func group(_ name: String) {
        currentGroup = name
        print("\n── \(name)")
    }

    func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            passed += 1
            print("  PASS  \(name)")
        } else {
            failed += 1
            let extra = detail()
            print("  FAIL  \(name)\(extra.isEmpty ? "" : " — \(extra)")")
        }
    }

    func equal<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
        check(name, actual == expected, "actual=\(actual) expected=\(expected)")
    }

    func skip(_ name: String, _ reason: String) {
        skipped += 1
        print("  SKIP  \(name) — \(reason)")
    }

    func finish() -> Int32 {
        print("\n结果: \(passed) 通过 · \(failed) 失败 · \(skipped) 跳过")
        return failed == 0 ? 0 : 1
    }
}

enum SelfTestFixture {
    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// 合成一条与 Claude Code 结构一致的 JSONL 记录（不含任何真实聊天正文）。
    static func line(session: String?, date: Date, input: Int64, output: Int64, cacheCreation: Int64 = 0, cacheRead: Int64 = 0) -> String {
        let sessionField = session.map { "\"sessionId\":\"\($0)\"," } ?? ""
        return "{\"type\":\"assistant\",\(sessionField)\"timestamp\":\"\(isoFormatter.string(from: date))\","
            + "\"message\":{\"role\":\"assistant\",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),"
            + "\"cache_creation_input_tokens\":\(cacheCreation),\"cache_read_input_tokens\":\(cacheRead)}}}"
    }

    static func write(_ lines: [String], to path: String, trailingNewline: Bool) throws {
        let text = lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(toFile: path, atomically: false, encoding: .utf8)
    }

    /// 原地覆写（保持 inode 不变），用于验证 ctime 检测。
    static func writeInPlace(_ text: String, to path: String) {
        let descriptor = open(path, O_WRONLY | O_TRUNC)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    static func permissions(of path: String) -> Int32 {
        var info = stat()
        guard lstat(path, &info) == 0 else { return -1 }
        return Int32(info.st_mode & 0o777)
    }

    /// 写一个包含超长（但结构合法）usage JSON 行的文件，filler 分块写出避免一次性构造巨大字符串。
    static func writeOversizeLine(
        to path: String,
        fillerBytes: Int,
        session: String,
        date: Date,
        input: Int64,
        output: Int64,
        trailingLines: [String]
    ) {
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }

        func emit(_ text: String) {
            let bytes = Array(text.utf8)
            bytes.withUnsafeBufferPointer { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
        }

        emit("{\"type\":\"assistant\",\"sessionId\":\"\(session)\",\"timestamp\":\"\(isoFormatter.string(from: date))\","
             + "\"message\":{\"role\":\"assistant\",\"note\":\"")
        let block = String(repeating: "a", count: 1 << 20)
        var remaining = fillerBytes
        while remaining > 0 {
            let size = min(remaining, block.count)
            emit(size == block.count ? block : String(block.prefix(size)))
            remaining -= size
        }
        emit("\",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),"
             + "\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}\n")
        for line in trailingLines {
            emit(line + "\n")
        }
    }

    static func modificationTime(of path: String) -> timespec? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return info.st_mtimespec
    }

    static func setModificationTime(_ time: timespec, at path: String) {
        let times = [time, time]
        _ = times.withUnsafeBufferPointer { buffer in
            utimensat(AT_FDCWD, path, buffer.baseAddress, 0)
        }
    }
}

enum SelfTest {
    static func run() -> Int32 {
        let reporter = TestReporter()
        let rootDirectory = NSTemporaryDirectory() + "AIQuotaBar-selftest-\(getpid())"
        setenv("AIQUOTABAR_CACHE_FILE", rootDirectory + "/shared-cache.json", 1)
        try? FileManager.default.createDirectory(atPath: rootDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: rootDirectory) }

        print("AIQuotaBar 本地回归测试 \(appVersion)")
        print("临时目录: \(rootDirectory)")

        testUsageCache(reporter, rootDirectory: rootDirectory)
        testReviewFixes(reporter, rootDirectory: rootDirectory)
        testTimestampParsing(reporter)
        testScheduler(reporter)
        testShell(reporter)
        testChromeInstanceSelection(reporter)
        testChromeDiscoveryObservations(reporter)
        testBrowserURLContract(reporter)
        testReadinessProbe(reporter)
        testCodexWeeklyContract(reporter)
        testClaudeUsageContract(reporter)
        testClaudeStatusMetricSelection(reporter)
        testChromeAppleEventDescriptors(reporter)
        testChromeTransportBoundary(reporter)
        testChromeReaderFlow(reporter)
        testChromeReadBudget(reporter)
        testReadinessStageLimit(reporter)
        testChromeReadService(reporter)
        testBrowserDiagnosticsCommand(reporter)
        testBrowserParsing(reporter)
        testWebCardContinuity(reporter)
        testWebCardContinuityEndToEnd(reporter)
        testReadDetailsEntry(reporter)
        testVersionConsistency(reporter)
        testDefaults(reporter)

        return reporter.finish()
    }

    // MARK: Claude Code 缓存

    private static func testUsageCache(_ reporter: TestReporter, rootDirectory: String) {
        let timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 15, minute: 30))!
        func dayStart(_ offset: Int) -> Date {
            calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
        }
        func moment(_ dayOffset: Int, _ hour: Int) -> Date {
            dayStart(dayOffset).addingTimeInterval(TimeInterval(hour) * 3600)
        }

        let root = rootDirectory + "/rootA"
        let fileA = root + "/projA/s1.jsonl"
        let store = ClaudeCodeUsageStore(persistenceURL: nil)

        func scan(_ at: Date = now, tz: TimeZone = timeZone) -> ClaudeCodeUsageStore.Result? {
            do {
                return try store.usage(rootPath: root, now: at, timeZone: tz)
            } catch {
                reporter.check("扫描 \(root)", false, "\(error)")
                return nil
            }
        }

        reporter.group("Claude 缓存 · 基线与无末尾换行")
        // 今日 2 条 + 3 天前 1 条，文件末尾没有换行符。
        let baseLines = [
            SelfTestFixture.line(session: "S1", date: moment(0, 9), input: 100, output: 10),
            SelfTestFixture.line(session: "S1", date: moment(0, 11), input: 200, output: 20, cacheCreation: 5, cacheRead: 7),
            SelfTestFixture.line(session: "S1", date: moment(-3, 9), input: 1000, output: 100)
        ]
        try? SelfTestFixture.write(baseLines, to: fileA, trailingNewline: false)

        guard let first = scan() else { return }
        reporter.equal("文件数", first.stats.fileCount, 1)
        reporter.equal("今日 token", first.stats.today.total, 342)
        reporter.equal("近 7 天 token", first.stats.week.total, 1442)
        reporter.equal("今日消息数", first.stats.today.messageCount, 2)
        reporter.equal("近 7 天消息数", first.stats.week.messageCount, 3)
        reporter.equal("近 7 天会话数", first.stats.week.sessionCount, 1)
        reporter.equal("解析行数", first.scan.parsedLines, 3)
        reporter.check("冷扫描有读取字节", first.scan.bytesRead > 0, "bytesRead=\(first.scan.bytesRead)")
        reporter.equal("末行无换行仍计入(最后一条 1000+100)", first.stats.week.input, 1300)

        reporter.group("Claude 缓存 · 命中缓存零读取零解析")
        guard let warm = scan() else { return }
        reporter.equal("命中文件数", warm.scan.cachedFiles, 1)
        reporter.equal("读取文件数", warm.scan.readFiles, 0)
        reporter.equal("读取字节", warm.scan.bytesRead, 0)
        reporter.equal("解析行数", warm.scan.parsedLines, 0)
        reporter.equal("统计不变(今日)", warm.stats.today.total, first.stats.today.total)
        reporter.equal("统计不变(7 天)", warm.stats.week.total, first.stats.week.total)

        reporter.group("Claude 缓存 · 补末尾换行不重复计数")
        try? SelfTestFixture.write(baseLines, to: fileA, trailingNewline: true)
        guard let newline = scan() else { return }
        reporter.equal("重新读取", newline.scan.readFiles, 1)
        reporter.equal("今日 token 不变", newline.stats.today.total, 342)
        reporter.equal("7 天 token 不变", newline.stats.week.total, 1442)
        reporter.equal("消息数不变", newline.stats.week.messageCount, 3)

        reporter.group("Claude 缓存 · 追加")
        try? SelfTestFixture.write(
            baseLines + [SelfTestFixture.line(session: "S1", date: moment(0, 13), input: 7, output: 3)],
            to: fileA,
            trailingNewline: true
        )
        guard let appended = scan() else { return }
        reporter.equal("追加后今日 token", appended.stats.today.total, 352)
        reporter.equal("追加后消息数", appended.stats.today.messageCount, 3)
        reporter.equal("追加触发重读", appended.scan.readFiles, 1)

        reporter.group("Claude 缓存 · 截断替换")
        try? SelfTestFixture.write(
            [SelfTestFixture.line(session: "S9", date: moment(0, 8), input: 1, output: 1)],
            to: fileA,
            trailingNewline: true
        )
        guard let truncated = scan() else { return }
        reporter.equal("截断后今日 token", truncated.stats.today.total, 2)
        reporter.equal("截断后 7 天 token", truncated.stats.week.total, 2)
        reporter.equal("截断后会话", truncated.stats.week.sessionCount, 1)

        reporter.group("Claude 缓存 · 同 size 同 mtime 原子替换(inode 变化)")
        let fileB = root + "/projA/s2.jsonl"
        let originalB = SelfTestFixture.line(session: "SB", date: moment(0, 9), input: 111, output: 111)
        let replacedB = SelfTestFixture.line(session: "SB", date: moment(0, 9), input: 222, output: 222)
        reporter.equal("替换前后字节数相同", originalB.utf8.count, replacedB.utf8.count)
        try? SelfTestFixture.write([originalB], to: fileB, trailingNewline: true)
        _ = scan()
        let mtimeB = SelfTestFixture.modificationTime(of: fileB)
        let temporaryB = root + "/projA/s2.replacement"
        try? SelfTestFixture.write([replacedB], to: temporaryB, trailingNewline: true)
        if let mtimeB {
            SelfTestFixture.setModificationTime(mtimeB, at: temporaryB)
        }
        var beforeInode = stat()
        _ = stat(fileB, &beforeInode)
        rename(temporaryB, fileB)
        var afterInode = stat()
        _ = stat(fileB, &afterInode)
        reporter.check("inode 已变化", beforeInode.st_ino != afterInode.st_ino, "\(beforeInode.st_ino) vs \(afterInode.st_ino)")
        reporter.equal("size 未变", Int64(beforeInode.st_size), Int64(afterInode.st_size))
        reporter.equal("mtime 未变", Int64(beforeInode.st_mtimespec.tv_sec), Int64(afterInode.st_mtimespec.tv_sec))
        reporter.equal("mtime 纳秒未变", Int64(beforeInode.st_mtimespec.tv_nsec), Int64(afterInode.st_mtimespec.tv_nsec))
        guard let replaced = scan() else { return }
        reporter.equal("原子替换被检出", replaced.stats.today.total, 2 + 444)
        reporter.check("原子替换触发重读", replaced.scan.readFiles >= 1, "readFiles=\(replaced.scan.readFiles)")

        reporter.group("Claude 缓存 · 删除文件")
        try? FileManager.default.removeItem(atPath: fileB)
        guard let deleted = scan() else { return }
        reporter.equal("删除后文件数", deleted.stats.fileCount, 1)
        reporter.equal("删除后今日 token", deleted.stats.today.total, 2)
        reporter.check("过期条目被清理", deleted.scan.prunedFiles >= 1, "pruned=\(deleted.scan.prunedFiles)")

        reporter.group("Claude 缓存 · 跨会话去重 / 文件名兜底 sessionId")
        let sharedA = root + "/projB/shared-a.jsonl"
        let sharedB = root + "/projB/shared-b.jsonl"
        try? SelfTestFixture.write([SelfTestFixture.line(session: "SHARED", date: moment(0, 9), input: 10, output: 0)], to: sharedA, trailingNewline: true)
        try? SelfTestFixture.write([SelfTestFixture.line(session: "SHARED", date: moment(0, 10), input: 20, output: 0)], to: sharedB, trailingNewline: true)
        let anonymousA = root + "/projB/anon-1.jsonl"
        let anonymousB = root + "/projB/anon-2.jsonl"
        try? SelfTestFixture.write([SelfTestFixture.line(session: nil, date: moment(0, 9), input: 5, output: 0)], to: anonymousA, trailingNewline: true)
        try? SelfTestFixture.write([SelfTestFixture.line(session: nil, date: moment(0, 10), input: 5, output: 0)], to: anonymousB, trailingNewline: true)
        guard let shared = scan() else { return }
        // S9(1) + SHARED(1) + anon-1 + anon-2 = 4 个不同会话
        reporter.equal("跨文件共享会话只算一个", shared.stats.today.sessionCount, 4)
        reporter.equal("消息数累加", shared.stats.today.messageCount, 5)
        reporter.equal("token 累加", shared.stats.today.total, 2 + 10 + 20 + 5 + 5)

        reporter.group("Claude 缓存 · 无效行按旧语义跳过")
        let noisy = root + "/projC/noisy.jsonl"
        try? SelfTestFixture.write([
            "",
            "这不是 JSON 但包含 \"usage\" 和 \"message\"",
            "{\"message\":{\"usage\":{\"input_tokens\":0,\"output_tokens\":0}},\"timestamp\":\"\(SelfTestFixture.isoFormatter.string(from: moment(0, 9)))\"}",
            "{\"message\":{\"usage\":{\"input_tokens\":50,\"output_tokens\":0}}}",
            "{\"message\":{\"role\":\"user\"},\"timestamp\":\"\(SelfTestFixture.isoFormatter.string(from: moment(0, 9)))\"}",
            SelfTestFixture.line(session: "NOISY", date: moment(0, 9), input: 3, output: 0)
        ], to: noisy, trailingNewline: true)
        guard let noisyResult = scan() else { return }
        reporter.equal("只有有效行被计入", noisyResult.stats.today.total, 2 + 10 + 20 + 5 + 5 + 3)
        reporter.equal("噪声文件也计入文件数", noisyResult.stats.fileCount, 6)

        reporter.group("Claude 缓存 · lastDate 统计全历史")
        let ancient = root + "/projC/ancient.jsonl"
        try? SelfTestFixture.write([SelfTestFixture.line(session: "OLD", date: moment(-400, 9), input: 999, output: 0)], to: ancient, trailingNewline: true)
        guard let history = scan() else { return }
        reporter.equal("400 天前不进 7 天窗口", history.stats.week.total, noisyResult.stats.week.total)
        reporter.check("lastDate 是最新事件", history.stats.lastDate.map { abs($0.timeIntervalSince(moment(0, 10))) < 1 } ?? false, "lastDate=\(String(describing: history.stats.lastDate))")

        reporter.group("Claude 缓存 · 本地日历 7 天边界")
        let boundary = root + "/projD/boundary.jsonl"
        try? SelfTestFixture.write([
            SelfTestFixture.line(session: "B6", date: dayStart(-6), input: 60, output: 0),
            SelfTestFixture.line(session: "B7", date: dayStart(-6).addingTimeInterval(-1), input: 70, output: 0)
        ], to: boundary, trailingNewline: true)
        guard let boundaryResult = scan() else { return }
        reporter.equal("第 6 天 0 点整计入", boundaryResult.stats.week.total, history.stats.week.total + 60)
        reporter.check("第 7 天不计入", boundaryResult.stats.week.sessions.contains("B6") && !boundaryResult.stats.week.sessions.contains("B7"))

        reporter.group("Claude 缓存 · 跨日重算不重读文件")
        guard let tomorrow = scan(calendar.date(byAdding: .day, value: 1, to: now)!) else { return }
        reporter.equal("跨日零读取", tomorrow.scan.bytesRead, 0)
        reporter.equal("跨日零解析", tomorrow.scan.parsedLines, 0)
        reporter.equal("跨日后今日清空", tomorrow.stats.today.total, 0)
        reporter.equal("跨日后 7 天丢掉第 6 天", tomorrow.stats.week.total, boundaryResult.stats.week.total - 60)
        reporter.check("跨日不触发缓存重建", !tomorrow.scan.rebuiltCache)

        reporter.group("Claude 缓存 · 时区变化强制重算")
        let utcStore = ClaudeCodeUsageStore(persistenceURL: nil)
        let tzRoot = rootDirectory + "/rootTZ"
        let utcNow = Date(timeIntervalSince1970: 1_788_638_400) // 2026-09-05T20:00:00Z
        let event = Date(timeIntervalSince1970: 1_788_602_400)  // 2026-09-05T10:00:00Z
        try? SelfTestFixture.write([SelfTestFixture.line(session: "TZ", date: event, input: 42, output: 0)], to: tzRoot + "/p/tz.jsonl", trailingNewline: true)
        do {
            let utc = try utcStore.usage(rootPath: tzRoot, now: utcNow, timeZone: TimeZone(identifier: "UTC")!)
            reporter.equal("UTC 下算今天", utc.stats.today.total, 42)
            let shanghai = try utcStore.usage(rootPath: tzRoot, now: utcNow, timeZone: timeZone)
            reporter.check("换时区触发重建", shanghai.scan.rebuiltCache)
            reporter.check("换时区重新读取", shanghai.scan.bytesRead > 0, "bytesRead=\(shanghai.scan.bytesRead)")
            reporter.equal("上海时区下不算今天", shanghai.stats.today.total, 0)
            reporter.equal("上海时区下仍在 7 天窗口", shanghai.stats.week.total, 42)
        } catch {
            reporter.check("时区测试", false, "\(error)")
        }

        reporter.group("Claude 缓存 · 根目录切换")
        let rootB = rootDirectory + "/rootB"
        try? SelfTestFixture.write([SelfTestFixture.line(session: "RB", date: moment(0, 9), input: 88, output: 0)], to: rootB + "/p/b.jsonl", trailingNewline: true)
        do {
            let switched = try store.usage(rootPath: rootB, now: now, timeZone: timeZone)
            reporter.check("换根触发重建", switched.scan.rebuiltCache)
            reporter.equal("换根后只统计新根", switched.stats.today.total, 88)
            reporter.equal("换根后文件数", switched.stats.fileCount, 1)
            let back = try store.usage(rootPath: root, now: now, timeZone: timeZone)
            reporter.equal("换回旧根统计恢复", back.stats.today.total, boundaryResult.stats.today.total)
        } catch {
            reporter.check("根目录切换测试", false, "\(error)")
        }

        reporter.group("Claude 缓存 · 读取失败与恢复")
        if getuid() == 0 {
            reporter.skip("读取失败恢复", "以 root 运行时 chmod 000 无效")
        } else {
            let locked = root + "/projE/locked.jsonl"
            try? SelfTestFixture.write([SelfTestFixture.line(session: "LK", date: moment(0, 9), input: 500, output: 0)], to: locked, trailingNewline: true)
            guard let readable = scan() else { return }
            let withLocked = readable.stats.today.total
            try? SelfTestFixture.write([
                SelfTestFixture.line(session: "LK", date: moment(0, 9), input: 500, output: 0),
                SelfTestFixture.line(session: "LK", date: moment(0, 10), input: 1, output: 0)
            ], to: locked, trailingNewline: true)
            chmod(locked, 0o000)
            guard let failed = scan() else { return }
            reporter.equal("读取失败计数", failed.scan.failedFiles, 1)
            reporter.equal("失败文件仍计入文件数", failed.stats.fileCount, readable.stats.fileCount)
            reporter.equal("失败文件不贡献统计", failed.stats.today.total, withLocked - 500)
            chmod(locked, 0o644)
            guard let recovered = scan() else { return }
            reporter.equal("恢复后重新读取", recovered.scan.failedFiles, 0)
            reporter.equal("恢复后统计正确", recovered.stats.today.total, withLocked + 1)
        }

        reporter.group("Claude 缓存 · 跨 collector 复用同一缓存")
        let liveRoot = rootDirectory + "/rootLive"
        let liveNow = Date()
        try? SelfTestFixture.write([SelfTestFixture.line(session: "LIVE", date: liveNow, input: 123, output: 0)], to: liveRoot + "/p/live.jsonl", trailingNewline: true)
        var config = AppConfig.defaultValue
        config.paths.claudeProjects = liveRoot
        config.sources.chromeBrowserUsage = false
        let semaphore = DispatchSemaphore(value: 0)
        var firstDetails: [String] = []
        var secondDetails: [String] = []
        Task {
            firstDetails = await QuotaCollector(config: config).claudeCodeLocalUsageCard().details
            secondDetails = await QuotaCollector(config: config).claudeCodeLocalUsageCard().details
            semaphore.signal()
        }
        semaphore.wait()
        let firstCacheLine = firstDetails.first { $0.hasPrefix("缓存: ") } ?? ""
        let secondCacheLine = secondDetails.first { $0.hasPrefix("缓存: ") } ?? ""
        reporter.check("第一次 collector 读取了文件", firstCacheLine.contains("读取 1"), firstCacheLine)
        reporter.check("第二次 collector 命中缓存", secondCacheLine.contains("读取 0 ·"), secondCacheLine)
        reporter.check("第二次 collector 零解析", secondCacheLine.contains("解析 0 行"), secondCacheLine)
        reporter.check("统计值一致", firstDetails.first == secondDetails.first, "\(String(describing: firstDetails.first))")
    }

    // MARK: 交付前审查修复回归

    private static func testReviewFixes(_ reporter: TestReporter, rootDirectory: String) {
        let timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 15, minute: 30))!
        let moment = calendar.startOfDay(for: now).addingTimeInterval(9 * 3600)

        // ---- 1. 身份包含 ctime：原地等长改写并回拨 mtime ----
        reporter.group("审查修复 1 · 原地等长改写 + 回拨 mtime 仍被检出（ctime）")
        let ctimeRoot = rootDirectory + "/fixCtime"
        let ctimeFile = ctimeRoot + "/p/inplace.jsonl"
        let storeCtime = ClaudeCodeUsageStore(persistenceURL: nil)
        let before = SelfTestFixture.line(session: "IP", date: moment, input: 111, output: 0)
        let after = SelfTestFixture.line(session: "IP", date: moment, input: 222, output: 0)
        reporter.equal("改写前后等长", before.utf8.count, after.utf8.count)
        try? SelfTestFixture.write([before], to: ctimeFile, trailingNewline: true)

        do {
            let warm = try storeCtime.usage(rootPath: ctimeRoot, now: now, timeZone: timeZone)
            reporter.equal("预热值", warm.stats.today.total, 111)
            var originalStat = stat()
            _ = lstat(ctimeFile, &originalStat)
            let savedMtime = originalStat.st_mtimespec

            SelfTestFixture.writeInPlace(after + "\n", to: ctimeFile)
            SelfTestFixture.setModificationTime(savedMtime, at: ctimeFile)

            var replacedStat = stat()
            _ = lstat(ctimeFile, &replacedStat)
            reporter.equal("inode 未变", UInt64(replacedStat.st_ino), UInt64(originalStat.st_ino))
            reporter.equal("size 未变", Int64(replacedStat.st_size), Int64(originalStat.st_size))
            reporter.equal("mtime 秒已回拨", Int64(replacedStat.st_mtimespec.tv_sec), Int64(savedMtime.tv_sec))
            reporter.equal("mtime 纳秒已回拨", Int64(replacedStat.st_mtimespec.tv_nsec), Int64(savedMtime.tv_nsec))
            reporter.check("ctime 已前进（无法回拨）",
                           replacedStat.st_ctimespec.tv_sec > originalStat.st_ctimespec.tv_sec
                            || (replacedStat.st_ctimespec.tv_sec == originalStat.st_ctimespec.tv_sec
                                && replacedStat.st_ctimespec.tv_nsec > originalStat.st_ctimespec.tv_nsec))

            let detected = try storeCtime.usage(rootPath: ctimeRoot, now: now, timeZone: timeZone)
            reporter.equal("原地改写被检出并重读", detected.scan.readFiles, 1)
            reporter.equal("统计已更新", detected.stats.today.total, 222)
        } catch {
            reporter.check("ctime 回归", false, "\(error)")
        }

        // ---- 1b. 仅 chmod（内容不变）也必须重新校验 ----
        reporter.group("审查修复 1b · 仅撤销读权限也会被检出")
        if getuid() == 0 {
            reporter.skip("chmod 000 检出", "以 root 运行时 chmod 000 无效")
        } else {
            let permRoot = rootDirectory + "/fixPerm"
            let permFile = permRoot + "/p/perm.jsonl"
            let storePerm = ClaudeCodeUsageStore(persistenceURL: nil)
            try? SelfTestFixture.write([SelfTestFixture.line(session: "PM", date: moment, input: 22, output: 0)], to: permFile, trailingNewline: true)
            do {
                let warm = try storePerm.usage(rootPath: permRoot, now: now, timeZone: timeZone)
                reporter.equal("预热值", warm.stats.today.total, 22)
                chmod(permFile, 0o000)
                let revoked = try storePerm.usage(rootPath: permRoot, now: now, timeZone: timeZone)
                reporter.equal("权限撤销后读取失败", revoked.scan.failedFiles, 1)
                reporter.equal("不再沿用旧缓存值", revoked.stats.today.total, 0)
                reporter.equal("文件数仍计入", revoked.stats.fileCount, 1)
                chmod(permFile, 0o644)
                let restored = try storePerm.usage(rootPath: permRoot, now: now, timeZone: timeZone)
                reporter.equal("恢复权限后重新读取", restored.scan.readFiles, 1)
                reporter.equal("恢复后统计正确", restored.stats.today.total, 22)
            } catch {
                reporter.check("权限回归", false, "\(error)")
            }
        }

        // ---- 2. 符号链接不重复计数 ----
        reporter.group("审查修复 2 · 符号链接按旧版语义排除")
        let linkRoot = rootDirectory + "/fixLink"
        let realFile = linkRoot + "/p/real.jsonl"
        let linkFile = linkRoot + "/p/link.jsonl"
        let storeLink = ClaudeCodeUsageStore(persistenceURL: nil)
        try? SelfTestFixture.write([SelfTestFixture.line(session: "LN", date: moment, input: 22, output: 0)], to: realFile, trailingNewline: true)
        reporter.equal("创建符号链接", symlink(realFile, linkFile), 0)
        do {
            let result = try storeLink.usage(rootPath: linkRoot, now: now, timeZone: timeZone)
            reporter.equal("符号链接不计入文件数", result.stats.fileCount, 1)
            reporter.equal("token 不翻倍", result.stats.today.total, 22)
            reporter.equal("消息数不翻倍", result.stats.today.messageCount, 1)
        } catch {
            reporter.check("符号链接回归", false, "\(error)")
        }

        // ---- 3. 持久化缓存权限 ----
        reporter.group("审查修复 3 · 缓存文件 0600、专用目录 0700")
        let secureRoot = rootDirectory + "/fixPerms"
        let dataRoot = secureRoot + "/data"
        try? SelfTestFixture.write([SelfTestFixture.line(session: "SEC", date: moment, input: 5, output: 0)], to: dataRoot + "/p/a.jsonl", trailingNewline: true)

        let ownedDirectory = secureRoot + "/owned"
        let ownedCache = ownedDirectory + "/claude-usage-cache.json"
        let ownedStore = ClaudeCodeUsageStore(persistenceURL: URL(fileURLWithPath: ownedCache), ownsDirectory: true)
        _ = try? ownedStore.usage(rootPath: dataRoot, now: now, timeZone: timeZone)
        reporter.check("缓存文件已写出", FileManager.default.fileExists(atPath: ownedCache))
        reporter.equal("缓存文件权限 0600", SelfTestFixture.permissions(of: ownedCache), 0o600)
        reporter.equal("专用目录权限 0700", SelfTestFixture.permissions(of: ownedDirectory), 0o700)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: ownedDirectory))?.filter { $0.hasSuffix(".tmp") } ?? []
        reporter.equal("没有残留临时文件", leftovers.count, 0)

        let externalDirectory = secureRoot + "/external"
        try? FileManager.default.createDirectory(atPath: externalDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: NSNumber(value: Int16(0o755))])
        let externalCache = externalDirectory + "/cache.json"
        let externalStore = ClaudeCodeUsageStore(persistenceURL: URL(fileURLWithPath: externalCache), ownsDirectory: false)
        _ = try? externalStore.usage(rootPath: dataRoot, now: now, timeZone: timeZone)
        reporter.equal("自定义路径的文件仍是 0600", SelfTestFixture.permissions(of: externalCache), 0o600)
        reporter.equal("不修改用户指定的祖先目录权限", SelfTestFixture.permissions(of: externalDirectory), 0o755)

        // 覆盖持久化往返（含 ctime / incomplete 字段）
        let reloadStore = ClaudeCodeUsageStore(persistenceURL: URL(fileURLWithPath: ownedCache), ownsDirectory: true)
        do {
            let restored = try reloadStore.usage(rootPath: dataRoot, now: now, timeZone: timeZone)
            reporter.check("从磁盘缓存恢复", restored.scan.loadedPersistedCache)
            reporter.equal("磁盘缓存命中零读取", restored.scan.bytesRead, 0)
            reporter.equal("磁盘缓存统计一致", restored.stats.today.total, 5)
        } catch {
            reporter.check("持久化往返", false, "\(error)")
        }

        // ---- 4. 超长行 ----
        reporter.group("审查修复 4 · 超长行不再静默漏计")
        let longRoot = rootDirectory + "/fixLong"
        let longFile = longRoot + "/p/long.jsonl"
        // 4a：人为把上限压到很小，验证「跳过 + 显式报告不完整」，且不会被当成完整成功。
        let normalLine = SelfTestFixture.line(session: "OK", date: moment, input: 32, output: 0)
        SelfTestFixture.writeOversizeLine(
            to: longFile,
            fillerBytes: 2 << 20,
            session: "BIG",
            date: moment,
            input: 22,
            output: 0,
            trailingLines: [normalLine]
        )
        let cappedStore = ClaudeCodeUsageStore(persistenceURL: nil, maxLineBytes: 4096)
        do {
            let capped = try cappedStore.usage(rootPath: longRoot, now: now, timeZone: timeZone)
            reporter.equal("超长行被跳过后其余仍计入", capped.stats.today.total, 32)
            reporter.check("记录了超长行", capped.scan.oversizeLines >= 1, "oversize=\(capped.scan.oversizeLines)")
            reporter.equal("显式标记不完整文件数", capped.scan.incompleteFiles, 1)
            reporter.check("不算完整成功", !capped.scan.isComplete)
            reporter.check("摘要行说明不完整", capped.scan.summaryLine.contains("不完整"), capped.scan.summaryLine)
            let cachedAgain = try cappedStore.usage(rootPath: longRoot, now: now, timeZone: timeZone)
            reporter.check("命中缓存后仍报告不完整", !cachedAgain.scan.isComplete)
            reporter.equal("命中缓存后不完整文件数保持", cachedAgain.scan.incompleteFiles, 1)
        } catch {
            reporter.check("超长行上限回归", false, "\(error)")
        }

        // 4b：生产上限下，65 MiB 的合法 usage 行必须被正确解析。
        reporter.equal("生产单行上限 256 MB", ClaudeCodeUsageStore.defaultMaxLineBytes, 256 << 20)
        let hugeRoot = rootDirectory + "/fixHuge"
        let hugeFile = hugeRoot + "/p/huge.jsonl"
        SelfTestFixture.writeOversizeLine(
            to: hugeFile,
            fillerBytes: 65 << 20,
            session: "BIG",
            date: moment,
            input: 22,
            output: 0,
            trailingLines: [normalLine]
        )
        let hugeStore = ClaudeCodeUsageStore(persistenceURL: nil)
        do {
            let huge = try hugeStore.usage(rootPath: hugeRoot, now: now, timeZone: timeZone)
            reporter.equal("65 MB 合法行被正确解析", huge.stats.today.total, 54)
            reporter.equal("两条消息都计入", huge.stats.today.messageCount, 2)
            reporter.check("结果是完整成功", huge.scan.isComplete)
            reporter.equal("没有超长行", huge.scan.oversizeLines, 0)
        } catch {
            reporter.check("65 MB 行回归", false, "\(error)")
        }
        try? FileManager.default.removeItem(atPath: hugeRoot)

        // ---- 5. Chrome 稳定 ID 对象寻址 ----
        // 0.2.14 起 AppleScript 已移除；等价行为断言（reload/探测/读取都发给 tab id … of window id …、
        // 发送前复核 URL、寻址失败显式上报、找不到目标跳过）见 ChromeSelfTests.swift「读取流程」各组。
    }

    // MARK: 时间戳

    private static func testTimestampParsing(_ reporter: TestReporter) {
        reporter.group("时间戳快路径与 ISO8601DateFormatter 一致")
        let samples = [
            "2026-09-05T00:00:00Z",
            "2026-09-05T23:59:59.999Z",
            "2024-02-29T12:00:00.500Z",
            "2000-01-01T00:00:00.000Z",
            "1970-01-01T00:00:00Z",
            "2100-03-01T05:06:07.123Z",
            "2026-12-31T23:59:59Z",
            "1999-12-31T23:59:59.001Z"
        ]
        for sample in samples {
            let fast = ISO8601Fast.fastPath(sample)
            let slow = ISO8601Fast.formatterDate(from: sample)
            guard let fast, let slow else {
                reporter.check("快路径解析 \(sample)", false, "fast=\(String(describing: fast)) slow=\(String(describing: slow))")
                continue
            }
            reporter.check("快路径 == formatter \(sample)", abs(fast.timeIntervalSince1970 - slow.timeIntervalSince1970) < 1e-6,
                           "\(fast.timeIntervalSince1970) vs \(slow.timeIntervalSince1970)")
        }
        for fallback in ["2026-09-05T10:00:00+08:00", "2026-09-05T10:00:00.123456Z", "not-a-date", "2026-02-30T00:00:00Z", "2026-09-05T10:00:00"] {
            reporter.check("非标准格式回落 formatter: \(fallback)", ISO8601Fast.fastPath(fallback) == nil)
        }
        reporter.check("带时区偏移仍能解析", ISO8601Fast.date(from: "2026-09-05T10:00:00+08:00") != nil)
    }

    // MARK: 自动刷新调度策略

    private static func testScheduler(_ reporter: TestReporter) {
        reporter.group("自动刷新调度策略")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let normal = RefreshSchedulerPolicy(baseInterval: 300, powerSavingEnabled: true)

        reporter.equal("默认间隔 5 分钟", normal.effectiveInterval, 300)
        reporter.equal("从未刷新时立即刷新", normal.decide(now: now, lastRefreshStartedAt: nil), .fire)
        reporter.equal("过期后触发", normal.decide(now: now, lastRefreshStartedAt: now.addingTimeInterval(-400)), .fire)
        reporter.equal("未过期时等待剩余时间", normal.decide(now: now, lastRefreshStartedAt: now.addingTimeInterval(-100)), .wait(200))
        reporter.equal("手动刷新后自动顺延", normal.nextDelay(now: now, lastRefreshStartedAt: now.addingTimeInterval(-5)), 295)
        reporter.equal("刚刷新完顺延整个间隔", normal.nextDelay(now: now, lastRefreshStartedAt: now), 300)
        reporter.equal("临界处不小于最小延迟", normal.nextDelay(now: now, lastRefreshStartedAt: now.addingTimeInterval(-299.9)),
                       RefreshSchedulerPolicy.minimumDelay)
        reporter.equal("过期后 nextDelay 也不为 0", normal.nextDelay(now: now, lastRefreshStartedAt: now.addingTimeInterval(-9999)),
                       RefreshSchedulerPolicy.minimumDelay)

        let lowPower = RefreshSchedulerPolicy(baseInterval: 300, powerSavingEnabled: true, lowPowerModeEnabled: true)
        reporter.equal("低电量至少 10 分钟", lowPower.effectiveInterval, 600)
        reporter.check("低电量标记为已放宽", lowPower.isLowPowerRelaxed)
        reporter.equal("低电量下 400 秒未到期", lowPower.decide(now: now, lastRefreshStartedAt: now.addingTimeInterval(-400)), .wait(200))

        let lowPowerOff = RefreshSchedulerPolicy(baseInterval: 300, powerSavingEnabled: false, lowPowerModeEnabled: true)
        reporter.equal("关闭节能模式不放宽", lowPowerOff.effectiveInterval, 300)

        let tenMinute = RefreshSchedulerPolicy(baseInterval: 600, powerSavingEnabled: true, lowPowerModeEnabled: true)
        reporter.equal("10 分钟档取较大值不叠加", tenMinute.effectiveInterval, 600)

        let asleep = RefreshSchedulerPolicy(baseInterval: 300, powerSavingEnabled: true, systemAsleep: true)
        reporter.equal("系统睡眠暂停", asleep.decide(now: now, lastRefreshStartedAt: nil), .paused)
        reporter.equal("系统睡眠停表", asleep.nextDelay(now: now, lastRefreshStartedAt: nil), nil)
        reporter.equal("暂停原因", asleep.pauseReason, "系统睡眠")

        let screenOff = RefreshSchedulerPolicy(baseInterval: 300, powerSavingEnabled: true, screensAsleep: true)
        reporter.equal("屏幕关闭暂停", screenOff.decide(now: now, lastRefreshStartedAt: nil), .paused)
        reporter.equal("屏幕关闭原因", screenOff.pauseReason, "屏幕关闭")

        let screenOffNoSaving = RefreshSchedulerPolicy(baseInterval: 300, powerSavingEnabled: false, screensAsleep: true)
        reporter.equal("关闭节能模式不暂停", screenOffNoSaving.pauseReason, nil)

        // 唤醒场景：睡了 2 小时 -> 只补一次；睡了 10 秒 -> 不补刷。
        let wokeLate = normal.decide(now: now, lastRefreshStartedAt: now.addingTimeInterval(-7200))
        reporter.equal("长时间睡眠后补一次", wokeLate, .fire)
        let wokeEarly = normal.decide(now: now, lastRefreshStartedAt: now.addingTimeInterval(-10))
        reporter.equal("短暂息屏后不补刷", wokeEarly, .wait(290))
    }

    // MARK: Shell

    private static func testShell(_ reporter: TestReporter) {
        reporter.group("Shell.run 大输出不死锁")
        do {
            // stdout 4MB + stderr 4MB，远超 64KB 管道缓冲：旧实现会死锁。
            let output = try Shell.run(
                "/bin/sh",
                arguments: ["-c", "dd if=/dev/zero bs=1000 count=4000 2>/dev/null; dd if=/dev/zero bs=1000 count=4000 1>&2 2>/dev/null"],
                timeout: 60
            )
            reporter.equal("stdout 完整读取", output.utf8.count, 4_000_000)
        } catch {
            reporter.check("大输出读取", false, "\(error)")
        }

        reporter.group("Shell.run 看门狗")
        let started = Date()
        do {
            _ = try Shell.run("/bin/sleep", arguments: ["30"], timeout: 1)
            reporter.check("超时应抛错", false)
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            reporter.check("超时在 10 秒内返回", elapsed < 10, "elapsed=\(elapsed)")
            reporter.check("超时错误信息包含超时", "\(error)".contains("超时"), "\(error)")
        }
    }

    // MARK: 网页解析

    private static func testBrowserParsing(_ reporter: TestReporter) {
        reporter.group("网页文本解析（合成页面）")
        let codexText = """
        Codex 分析
        每周使用限额
        68% 剩余
        重置时间: 2026年9月8日 10:00
        """
        let claudeText = """
        Plan usage limits
        Current session
        23% used
        Resets in 3h 12m
        All models
        41% used
        Claude Design
        7% used
        """
        let pages = [
            BrowserTextPage(url: BrowserUsageTargets.codexUsageURL, lines: LineTools.normalize([codexText], deduplicate: false), source: "合成页面"),
            BrowserTextPage(url: BrowserUsageTargets.claudeUsageURL, lines: LineTools.normalize([claudeText], deduplicate: false), source: "合成页面")
        ]
        reporter.equal("合成两个页面", pages.count, 2)

        guard pages.count == 2 else { return }
        reporter.check("Codex URL 识别", BrowserUsageTargets.isCodexUsageURL(pages[0].url))
        reporter.check("Claude URL 识别", BrowserUsageTargets.isClaudeUsageURL(pages[1].url))

        let codexMetrics = BrowserUsageParser.parseCodex(lines: pages[0].lines)
        reporter.equal("Codex 指标数量", codexMetrics.count, 1)
        reporter.equal("Codex 周额度剩余", codexMetrics.first?.remainingPercent, 68)
        reporter.equal("Codex 指标名称未变", codexMetrics.first?.label, "每周使用限额")

        let claudeMetrics = BrowserUsageParser.parseClaude(lines: pages[1].lines)
        reporter.equal("Current session used", claudeMetrics.first(where: { $0.label == "Current session" })?.usedPercent, 23)
        reporter.equal("All models used", claudeMetrics.first(where: { $0.label == "All models" })?.usedPercent, 41)
        reporter.equal("Claude Design used", claudeMetrics.first(where: { $0.label == "Claude Design" })?.usedPercent, 7)
    }

    // MARK: 沿用上次成功

    private static func testWebCardContinuity(_ reporter: TestReporter) {
        reporter.group("网页沿用上次成功：只信任 confirmedAt，不叠加，不吞错误")
        let delegate = AppDelegate()
        let confirmedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let goodCard = QuotaCard(
            provider: "Claude 网页额度",
            headline: "最高 41% used",
            details: ["Current session: 23% used", "All models: 41% used", "来源: Chrome DOM"],
            status: .ok,
            remainingUSD: nil,
            statusBarHint: "59%",
            progress: [QuotaProgress(label: "All models", percent: 59, valueText: "59% 剩余", detail: nil)],
            confirmedAt: confirmedAt
        )
        let unconfirmedWithProgress = QuotaCard(
            provider: "Claude 网页额度",
            headline: "未确认的进度",
            details: ["不应被沿用"],
            status: .ok,
            remainingUSD: nil,
            statusBarHint: "1%",
            progress: [QuotaProgress(label: "All models", percent: 1, valueText: "1% 剩余", detail: nil)]
        )
        let badCard = QuotaCard(
            provider: "Claude 网页额度",
            headline: "自动化权限被拒绝",
            details: ["枚举窗口失败: macOS 拒绝了对 Google Chrome 的自动化控制 [-1743]", ChromeCardBuilder.permissionHint, ChromeCardBuilder.continuityNote],
            status: .unavailable,
            remainingUSD: nil,
            statusBarHint: nil
        )

        let noHistory = delegate.applyWebCardContinuity(to: Snapshot(updatedAt: Date(), cards: [badCard]))
        reporter.equal("没有上次成功时如实显示失败", noHistory.cards[0].headline, "自动化权限被拒绝")
        reporter.check("没有上次成功时无进度无百分比", noHistory.cards[0].progress.isEmpty && noHistory.cards[0].statusBarHint == nil)

        _ = delegate.applyWebCardContinuity(to: Snapshot(updatedAt: Date(), cards: [unconfirmedWithProgress]))
        let stillNoHistory = delegate.applyWebCardContinuity(to: Snapshot(updatedAt: Date(), cards: [badCard]))
        reporter.equal("有进度但没有 confirmedAt 的卡片不会成为上次成功", stillNoHistory.cards[0].headline, "自动化权限被拒绝")

        _ = delegate.applyWebCardContinuity(to: Snapshot(updatedAt: Date(), cards: [goodCard]))
        var detailCounts: [Int] = []
        var hints: [String?] = []
        var last: Snapshot?
        for _ in 0..<4 {
            let result = delegate.applyWebCardContinuity(to: Snapshot(updatedAt: Date(), cards: [badCard], diagnosticsLines: ["候选 Chrome 主进程: 2"]))
            detailCounts.append(result.cards[0].details.count)
            hints.append(result.cards[0].statusBarHint)
            last = result
        }
        let card = last?.cards[0]
        reporter.equal("警告行数每轮固定（不累积）", Set(detailCounts).count, 1)
        reporter.equal("行数 = 本次标题 1 + 本次原因 2 + 分隔 1 + 上次 3", detailCounts.first, 7)
        reporter.check("状态栏百分比沿用", hints.allSatisfy { $0 == "59%" }, "\(hints)")
        reporter.check("保留本轮阶段与 OSStatus", card?.details.contains { $0.contains("枚举窗口失败") && $0.contains("-1743") } == true, "\(String(describing: card?.details))")
        reporter.check("保留本轮可操作原因", card?.details.contains(ChromeCardBuilder.permissionHint) == true)
        reporter.check("保留上次成功值与时间", card?.details.contains("Current session: 23% used") == true && card?.headline.contains(Formatters.clock(confirmedAt)) == true, "\(String(describing: card?.headline))")
        reporter.equal("诊断行原样保留", last?.diagnosticsLines, ["候选 Chrome 主进程: 2"])
        reporter.check("沿用卡片自身不是已确认", card?.confirmedAt == nil)
        reporter.check("面板备注说明本次失败", card?.note?.contains("自动化权限被拒绝") == true)
        reporter.equal("进度条沿用", card?.progress.count, 1)
        reporter.equal("状态降级为 warning", card?.status, .warning)

        let laterAt = confirmedAt.addingTimeInterval(600)
        let newGood = QuotaCard(
            provider: "Claude 网页额度",
            headline: "最高 50% used",
            details: ["All models: 50% used", "来源: Chrome DOM"],
            status: .ok,
            remainingUSD: nil,
            statusBarHint: "50%",
            progress: [QuotaProgress(label: "All models", percent: 50, valueText: "50% 剩余", detail: nil)],
            confirmedAt: laterAt
        )
        _ = delegate.applyWebCardContinuity(to: Snapshot(updatedAt: Date(), cards: [newGood]))
        let afterUpdate = delegate.applyWebCardContinuity(to: Snapshot(updatedAt: Date(), cards: [badCard]))
        reporter.check("真成功后沿用的是新值与新时间",
                       afterUpdate.cards[0].headline.contains("50% used") && afterUpdate.cards[0].headline.contains(Formatters.clock(laterAt)),
                       afterUpdate.cards[0].headline)
        reporter.equal("真成功后状态栏百分比更新", afterUpdate.cards[0].statusBarHint, "50%")
    }

    // MARK: 版本号一致性

    /// `--version` 打印的 `appVersion` 必须与随包 Info.plist 对齐：短版本号逐字相等、
    /// `CFBundleVersion` 是正整数 build 号。0.2.18 起钉住这一条，避免下次升版本时只改一处。
    /// 只有从 .app 包里跑自检时才有 Info.plist（`make test` 正是这样跑的）；直接跑可执行文件时跳过。
    private static func testVersionConsistency(_ reporter: TestReporter) {
        reporter.group("版本号一致性（appVersion ↔ Info.plist）")
        guard let info = Bundle.main.infoDictionary,
              let shortVersion = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String else {
            reporter.skip("appVersion 与 Info.plist 一致", "当前不是从 .app 包里运行，读不到 Info.plist")
            return
        }
        reporter.equal("CFBundleShortVersionString = appVersion", shortVersion, appVersion)
        reporter.check("CFBundleVersion 是正整数 build 号", (Int(build) ?? 0) > 0, build)
    }

    // MARK: 默认值

    private static func testDefaults(_ reporter: TestReporter) {
        reporter.group("默认设置")
        if UserDefaults.standard.string(forKey: "refreshCadence") == nil {
            reporter.equal("没有保存过选择时默认 5 分钟", RefreshCadence.load(), .fiveMinutes)
            reporter.check("确认未保存过", !RefreshCadence.hasStoredPreference)
        } else {
            reporter.check("已保存的刷新档位被尊重", RefreshCadence.hasStoredPreference)
            reporter.equal("加载值与保存值一致",
                           RefreshCadence.load().rawValue,
                           UserDefaults.standard.string(forKey: "refreshCadence"))
        }
        reporter.equal("1 分钟档 = 60s", RefreshCadence.oneMinute.seconds, 60)
        reporter.equal("3 分钟档 = 180s", RefreshCadence.threeMinutes.seconds, 180)
        reporter.equal("5 分钟档 = 300s", RefreshCadence.fiveMinutes.seconds, 300)
        reporter.equal("10 分钟档 = 600s", RefreshCadence.tenMinutes.seconds, 600)
        if UserDefaults.standard.object(forKey: "powerSavingEnabled") == nil {
            reporter.check("节能模式默认开启", PowerSavingSetting.load())
        } else {
            reporter.skip("节能模式默认值", "本机已保存过用户选择")
        }
        reporter.equal("低电量最小间隔 10 分钟", PowerSavingSetting.lowPowerMinimumInterval, 600)
        reporter.check("API 计费默认关闭", !AppConfig.defaultValue.sources.openAICosts && !AppConfig.defaultValue.sources.anthropicCosts)
    }
}

enum Benchmark {
    static func run(arguments: [String]) -> Int32 {
        var root = PathTools.expandTilde("~/.claude/projects")
        if let index = arguments.firstIndex(of: "--root"), index + 1 < arguments.count {
            root = PathTools.expandTilde(arguments[index + 1])
        }
        var warmRounds = 3
        if let index = arguments.firstIndex(of: "--rounds"), index + 1 < arguments.count,
           let value = Int(arguments[index + 1]), value > 0 {
            warmRounds = value
        }

        print("AIQuotaBar Benchmark \(appVersion)")
        print("统计根目录: \(root)")
        print("说明: 只输出聚合数字与性能指标，不输出任何会话内容。")

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
            print("错误: 目录不存在 \(root)")
            return 1
        }

        // 独立实例 + 不落盘：每次运行都是真正的冷缓存，结果可重复。
        let store = ClaudeCodeUsageStore(persistenceURL: nil)
        let now = Date()

        do {
            let cold = try store.usage(rootPath: root, now: now)
            print("")
            print("冷缓存: \(format(seconds: cold.scan.elapsed)) · 读取 \(format(bytes: cold.scan.bytesRead)) · 扫描 \(cold.scan.linesScanned) 行 · 解析 \(cold.scan.parsedLines) 行")
            print("        文件 \(cold.scan.fileCount) 个 · 读取 \(cold.scan.readFiles) · 失败 \(cold.scan.failedFiles) · 超长行 \(cold.scan.oversizeLines)")

            for round in 1...warmRounds {
                let warm = try store.usage(rootPath: root, now: now)
                print("热缓存 #\(round): \(format(seconds: warm.scan.elapsed)) · 读取 \(format(bytes: warm.scan.bytesRead)) · 解析 \(warm.scan.parsedLines) 行 · 命中 \(warm.scan.cachedFiles)")
            }

            let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
            let crossDay = try store.usage(rootPath: root, now: nextDay)
            print("跨日重算: \(format(seconds: crossDay.scan.elapsed)) · 读取 \(format(bytes: crossDay.scan.bytesRead)) · 解析 \(crossDay.scan.parsedLines) 行")

            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            print("峰值内存 maxRSS: \(format(bytes: Int64(usage.ru_maxrss)))")

            print("")
            print("汇总（聚合值）:")
            print("  今日 token \(cold.stats.today.total) · 消息 \(cold.stats.today.messageCount) · 会话 \(cold.stats.today.sessionCount)")
            print("  近 7 天 token \(cold.stats.week.total) · 消息 \(cold.stats.week.messageCount) · 会话 \(cold.stats.week.sessionCount)")
            print("  近 7 天拆分: 输入 \(cold.stats.week.input) · 输出 \(cold.stats.week.output) · Cache \(cold.stats.week.cacheTotal)")
            if let lastDate = cold.stats.lastDate {
                print("  最近事件: \(Formatters.date(lastDate))")
            }
            return 0
        } catch {
            print("错误: \(error.localizedDescription)")
            return 1
        }
    }

    private static func format(seconds: TimeInterval) -> String {
        seconds >= 1 ? String(format: "%.3f s", seconds) : String(format: "%.1f ms", seconds * 1000)
    }

    private static func format(bytes: Int64) -> String {
        if bytes >= 1_048_576 { return String(format: "%.2f MB", Double(bytes) / 1_048_576.0) }
        if bytes >= 1024 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
        return "\(bytes) B"
    }
}

func runSnapshotAndExit() {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let config = ConfigStore().loadOrCreate()
        let snapshot = await QuotaCollector(config: config).collect()
        let text = SnapshotRenderer.plainText(snapshot)
        FileHandle.standardOutput.write(Data(text.utf8))
        semaphore.signal()
    }
    semaphore.wait()
}

if CommandLine.arguments.contains("--version") {
    print("\(appName) \(appVersion)")
    exit(0)
}

if CommandLine.arguments.contains("--self-test") {
    exit(SelfTest.run())
}

if CommandLine.arguments.contains("--benchmark") {
    exit(Benchmark.run(arguments: CommandLine.arguments))
}

if CommandLine.arguments.contains("--browser-diagnostics") {
    // 窄用途诊断：候选 PID / 分类 / 选择结果 / 枚举计数 / 阶段错误 / 事件计数。
    // 默认不 reload、不执行页面 JavaScript、不输出正文；`--read` 才读取并解析已匹配的额度页。
    exit(BrowserDiagnosticsCommand.run(arguments: CommandLine.arguments))
}

if CommandLine.arguments.contains("--print-snapshot") {
    runSnapshotAndExit()
    exit(0)
}

let singleInstanceLock = SingleInstanceLock.acquire()
if singleInstanceLock == nil {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
withExtendedLifetime(singleInstanceLock) {
    app.run()
}
