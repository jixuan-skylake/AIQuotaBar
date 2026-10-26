import AppKit
import Darwin
import Foundation

// MARK: - Chrome 主进程发现、分类、选择与严格身份
//
// 职责：只用本机公开 API（`NSRunningApplication` + `sysctl KERN_PROCARGS2` + `sysctl KERN_PROC`）枚举 bundle id 为
// com.google.Chrome 的主进程，按只读启动参数把每个进程分成「普通 / 自动化 / 无法确认」，并按保守规则决定唯一的
// 读取目标。0.2.13 用 `tell application "Google Chrome"` 按名称路由，两个同名同 bundle id 的 Chrome 同时运行时
// 会被 LaunchServices 解析到另一个工程的自动化实例；这里改为按进程决策，再由 `ChromeAppleEventTransport` 按 PID 定址。
//
// 流程：`discover()` 每次刷新重新枚举 → `ChromeInstanceClassifier.classify()` 逐个分类（自动化判定优先，其次身份是否完整）
// → `decide()` 只在「恰好一个普通候选、且没有无法确认的候选」时选中。
//
// 身份（R1 整改）：选中身份 = (pid, 内核启动时间 kinfo_proc.p_starttime, bundle 路径)。内核启动时间精确到微秒、
// 同一 PID 被复用时必然不同，比较时不允许任何容差；LaunchServices 的 launchDate 只用于显示。启动时间或 bundle
// 路径读不到的候选一律 fail-closed（无法确认），不会降级成 pid + bundle 放行；已明确自动化的实例即使身份不完整也仍是自动化。
// `verifyKernel()` 供传输层在每条事件发送前 / 回复到达后调用，`verifyLive()` 供读取流程在每轮关键阶段调用。
//
// 错误：候选为空、只有自动化实例、多个普通实例、参数或身份无法确认，都以带原因的失败返回，绝不静默取最老 / 首个，
// 也不会回退到按名称读取。
//
// 边界：不读取 profile / cookie / 历史 / 账户数据，只看 argv；`--user-data-dir`、`--no-startup-window`、`--profile-directory`
// 单独不构成自动化证据（Chrome 后台模式登录项、自定义 profile 目录都会带这些参数）。

/// 只读读取指定进程的启动参数（argv）。只解析 argv，不返回环境变量。
enum ProcessArguments {
    enum ReadError: Error, Equatable, CustomStringConvertible {
        case sysctlFailed(errno: Int32)
        case malformed

        var description: String {
            switch self {
            case .sysctlFailed(let code):
                return "sysctl KERN_PROCARGS2 失败(errno \(code): \(String(cString: strerror(code))))"
            case .malformed:
                return "KERN_PROCARGS2 数据格式无法解析"
            }
        }
    }

    static func read(pid: pid_t) -> Result<[String], ReadError> {
        // 缓冲区按 KERN_ARGMAX 分配：KERN_PROCARGS2 不支持用空指针探测长度。
        var argmaxName: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var argmaxLength = MemoryLayout<Int32>.size
        guard sysctl(&argmaxName, UInt32(argmaxName.count), &argmax, &argmaxLength, nil, 0) == 0, argmax > 0 else {
            return .failure(.sysctlFailed(errno: errno))
        }

        var length = Int(argmax)
        var buffer = [UInt8](repeating: 0, count: length)
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let status = buffer.withUnsafeMutableBytes { raw -> Int32 in
            sysctl(&name, UInt32(name.count), raw.baseAddress, &length, nil, 0)
        }
        guard status == 0 else {
            return .failure(.sysctlFailed(errno: errno))
        }
        guard let arguments = parse(buffer: Array(buffer.prefix(length))) else {
            return .failure(.malformed)
        }
        return .success(arguments)
    }

    /// KERN_PROCARGS2 布局：`[Int32 argc][可执行路径\0][若干 \0 对齐][argv[0]\0 … argv[argc-1]\0][环境变量…]`。
    /// argc 与实际读到的参数个数不一致时返回 nil，不把半截数据当成参数表。
    static func parse(buffer: [UInt8]) -> [String]? {
        let headerSize = MemoryLayout<Int32>.size
        guard buffer.count > headerSize else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc > 0 else { return nil }

        var index = headerSize
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        guard index < buffer.count else { return nil }
        while index < buffer.count, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        while arguments.count < argc, index < buffer.count {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.count == argc ? arguments : nil
    }
}

/// 内核记录的进程启动时间（`kinfo_proc.kp_proc.p_starttime`，微秒精度）。PID 被复用时新进程的该值必然不同。
struct ChromeProcessStartTime: Equatable, CustomStringConvertible {
    let seconds: Int
    let microseconds: Int32

    var description: String {
        String(format: "%ld.%06d", seconds, microseconds)
    }
}

enum KernelProcessInfo {
    /// `sysctl KERN_PROC / KERN_PROC_PID`：进程不存在时内核返回 0 字节，视为 nil；返回的 pid 不一致也视为 nil。
    static func startTime(pid: pid_t) -> ChromeProcessStartTime? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        guard info.kp_proc.p_pid == pid else {
            return nil
        }
        let start = info.kp_proc.p_starttime
        return ChromeProcessStartTime(seconds: start.tv_sec, microseconds: start.tv_usec)
    }
}

/// 一次发现中看到的单个 Chrome 主进程。`arguments == nil` 表示参数读取失败（原因在 `argumentError`）；
/// `startTime` / `bundleURL` 为 nil 表示身份不完整，普通候选会因此被判为「无法确认」。
struct ChromeInstanceCandidate: Equatable {
    let pid: pid_t
    let startTime: ChromeProcessStartTime?
    let launchDate: Date?
    let bundleURL: URL?
    let arguments: [String]?
    let argumentError: String?

    init(pid: pid_t, startTime: ChromeProcessStartTime?, launchDate: Date?, bundleURL: URL?, arguments: [String]?, argumentError: String? = nil) {
        self.pid = pid
        self.startTime = startTime
        self.launchDate = launchDate
        self.bundleURL = bundleURL
        self.arguments = arguments
        self.argumentError = argumentError
    }
}

enum ChromeInstanceClass: Equatable {
    /// `notes` 只是记录下来的信息性参数（如 --user-data-dir），不参与判定。
    case normal(notes: [String])
    /// `markers` 是命中的明确自动化参数名。
    case automation(markers: [String])
    /// 参数不可读、身份不完整等原因导致无法判断；绝不自动选择。
    case uncertain(reason: String)

    var label: String {
        switch self {
        case .normal: return "普通"
        case .automation: return "自动化"
        case .uncertain: return "无法确认"
        }
    }
}

enum ChromeInstanceClassifier {
    /// 明确的自动化证据：只有远程调试 / WebDriver / 无头模式 / 自动化框架才会设置这些参数。
    static let automationFlags: Set<String> = [
        "--remote-debugging-pipe",
        "--remote-debugging-port",
        "--remote-allow-origins",
        "--enable-automation",
        "--headless",
        "--test-type"
    ]

    /// 只记录不判定：普通用户的自定义 profile 目录、登录项后台启动都会出现。
    static let informationalFlags: Set<String> = [
        "--user-data-dir",
        "--no-startup-window",
        "--profile-directory"
    ]

    static func classify(_ candidate: ChromeInstanceCandidate) -> ChromeInstanceClass {
        guard let arguments = candidate.arguments else {
            return .uncertain(reason: "启动参数不可读: \(candidate.argumentError ?? "未知原因")")
        }
        guard !arguments.isEmpty else {
            return .uncertain(reason: "启动参数为空")
        }

        var markers: [String] = []
        var notes: [String] = []
        // argv[0] 是可执行文件路径，路径文本里出现的字样不算参数。
        for argument in arguments.dropFirst() {
            let name = String(argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(argument))
            if automationFlags.contains(name) {
                markers.append(name)
            } else if name == "--disable-blink-features", argument.contains("AutomationControlled") {
                // 只有自动化框架为了隐藏 navigator.webdriver 才会设置。
                markers.append("--disable-blink-features=AutomationControlled")
            } else if informationalFlags.contains(name) {
                notes.append(name)
            }
        }

        // 自动化判定优先于身份完整性：启动时间缺失的自动化实例仍是自动化，绝不会被当成普通目标。
        if !markers.isEmpty {
            return .automation(markers: uniqueOrdered(markers))
        }
        // 普通候选必须身份完整（fail-closed），否则无法在发送事件前严格核验、无法防 PID 复用。
        guard candidate.startTime != nil else {
            return .uncertain(reason: "内核启动时间不可读，无法严格核验身份")
        }
        guard candidate.bundleURL != nil else {
            return .uncertain(reason: "bundle 路径不可读，无法严格核验身份")
        }
        return .normal(notes: uniqueOrdered(notes))
    }

    private static func uniqueOrdered(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// 选中实例的严格身份：PID + 内核启动时间 + bundle 路径，三者缺一不可。
/// 任何字段当前读不到、或与发现时不完全相等，都按失效处理（不降级、不容差）。
struct ChromeInstanceIdentity: Equatable {
    static let bundleIdentifier = "com.google.Chrome"

    let pid: pid_t
    let startTime: ChromeProcessStartTime
    let bundleURL: URL
    /// LaunchServices 的启动时间，只用于显示；核验一律用内核 `startTime`。
    let launchDate: Date?

    init(pid: pid_t, startTime: ChromeProcessStartTime, bundleURL: URL, launchDate: Date? = nil) {
        self.pid = pid
        self.startTime = startTime
        self.bundleURL = bundleURL
        self.launchDate = launchDate
    }

    /// 身份不完整的候选不能构成身份（返回 nil），由 `decide()` 归入无法确认。
    init?(candidate: ChromeInstanceCandidate) {
        guard let startTime = candidate.startTime, let bundleURL = candidate.bundleURL else { return nil }
        self.init(pid: candidate.pid, startTime: startTime, bundleURL: bundleURL, launchDate: candidate.launchDate)
    }

    /// 纯比较：当前看到的进程属性是否仍是发现时的同一个进程。返回 nil 表示一致，否则是原因。
    /// 启动时间必须精确相等（无容差）；当前 bundle 路径读不到也算失效（fail-closed）。
    func mismatchReason(currentStartTime: ChromeProcessStartTime?, bundleIdentifier: String?, bundleURL currentBundleURL: URL?) -> String? {
        guard let currentStartTime else {
            return "Chrome 进程 PID \(pid) 已退出"
        }
        guard currentStartTime == startTime else {
            return "PID \(pid) 的内核启动时间已变化（\(startTime) → \(currentStartTime)）：原进程已退出，PID 被复用"
        }
        guard bundleIdentifier == Self.bundleIdentifier else {
            return "PID \(pid) 已不是 Google Chrome（bundle id \(bundleIdentifier ?? "无")）"
        }
        guard let currentBundleURL else {
            return "PID \(pid) 的 bundle 路径当前不可读，无法核验（按失效处理）"
        }
        guard currentBundleURL.standardizedFileURL.path == bundleURL.standardizedFileURL.path else {
            return "PID \(pid) 的 bundle 路径已变化"
        }
        return nil
    }

    /// 传输边界的核验（每条事件发送前 / 回复到达后）：内核仍有该 PID 且启动时间精确相等。
    func verifyKernel() -> String? {
        guard let current = KernelProcessInfo.startTime(pid: pid) else {
            return "Chrome 进程 PID \(pid) 已退出"
        }
        guard current == startTime else {
            return "PID \(pid) 的内核启动时间已变化（\(startTime) → \(current)）：原进程已退出，PID 被复用"
        }
        return nil
    }

    /// 完整核验（读取流程每轮关键阶段）：内核身份 + LaunchServices 的 bundle id / bundle 路径。
    func verifyLive() -> String? {
        let current = KernelProcessInfo.startTime(pid: pid)
        guard let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated else {
            return current == nil ? "Chrome 进程 PID \(pid) 已退出" : "PID \(pid) 不再是已注册的应用进程"
        }
        return mismatchReason(
            currentStartTime: current,
            bundleIdentifier: application.bundleIdentifier,
            bundleURL: application.bundleURL
        )
    }
}

struct ChromeInstanceReport: Equatable {
    let candidate: ChromeInstanceCandidate
    let classification: ChromeInstanceClass

    var pid: pid_t { candidate.pid }

    /// CLI / 调试输出用的一行摘要：只含 PID、分类、参数名、内核启动时间、LS 启动时间与 bundle 路径，不含参数值。
    var summaryLine: String {
        var parts = ["PID \(pid)", "分类: \(classification.label)"]
        switch classification {
        case .normal(let notes):
            parts.append("自动化参数: 无")
            if !notes.isEmpty { parts.append("记录参数: \(notes.joined(separator: ", "))") }
        case .automation(let markers):
            parts.append("自动化参数: \(markers.joined(separator: ", "))")
        case .uncertain(let reason):
            parts.append(reason)
        }
        parts.append("内核启动: \(candidate.startTime.map { $0.description } ?? "不可读")")
        if let launchDate = candidate.launchDate {
            parts.append("LS 启动: \(Formatters.date(launchDate))")
        }
        parts.append("bundle: \(candidate.bundleURL?.path ?? "不可读")")
        return parts.joined(separator: " · ")
    }
}

enum ChromeInstanceSelection: Equatable {
    case selected(ChromeInstanceIdentity)
    case notRunning
    case onlyAutomation([pid_t])
    case multipleNormal([pid_t])
    case unverifiable([pid_t])
}

/// 一次发现 + 分类 + 选择的完整结果。`failureLines` 是给菜单卡片的可操作原因，`candidateLines` 给 CLI。
struct ChromeInstanceDecision {
    let reports: [ChromeInstanceReport]
    let selection: ChromeInstanceSelection

    var selectedIdentity: ChromeInstanceIdentity? {
        if case .selected(let identity) = selection { return identity }
        return nil
    }

    var candidateLines: [String] {
        reports.map(\.summaryLine)
    }

    var selectionLine: String {
        switch selection {
        case .selected(let identity):
            return "PID \(identity.pid)（唯一的普通 Chrome 实例，内核启动 \(identity.startTime)）"
        case .notRunning:
            return "未选择（Google Chrome 未运行）"
        case .onlyAutomation(let pids):
            return "未选择（只有自动化实例: \(pids.map(String.init).joined(separator: ", "))）"
        case .multipleNormal(let pids):
            return "未选择（多个普通实例: \(pids.map(String.init).joined(separator: ", "))）"
        case .unverifiable(let pids):
            return "未选择（无法确认实例: \(pids.map(String.init).joined(separator: ", "))）"
        }
    }

    var failureHeadline: String? {
        switch selection {
        case .selected, .notRunning: return nil
        case .onlyAutomation: return "仅检测到自动化 Chrome"
        case .multipleNormal: return "多个普通 Chrome，无法确定目标"
        case .unverifiable: return "Chrome 实例无法确认"
        }
    }

    var failureLines: [String] {
        switch selection {
        case .selected, .notRunning:
            return []
        case .onlyAutomation:
            var lines = ["检测到的 Google Chrome 都是自动化/测试实例，AIQuotaBar 不会向它们发送任何事件:"]
            for report in reports {
                if case .automation(let markers) = report.classification {
                    lines.append("PID \(report.pid): \(markers.joined(separator: ", "))")
                }
            }
            lines.append("请在你日常使用的 Chrome 里打开额度页；如果它没有运行，请先启动它，再点「立即刷新」。")
            return lines
        case .multipleNormal(let pids):
            return [
                "检测到 \(pids.count) 个普通 Google Chrome 主进程，无法确定读取哪一个: PID \(pids.map(String.init).joined(separator: ", "))",
                "AIQuotaBar 不会猜测目标。请只保留一个普通 Chrome 实例，关闭多余实例后点「立即刷新」。"
            ]
        case .unverifiable:
            var lines = ["有 Google Chrome 进程无法确认是否为自动化实例或身份不完整，AIQuotaBar 不会猜测目标:"]
            for report in reports {
                if case .uncertain(let reason) = report.classification {
                    lines.append("PID \(report.pid): \(reason)")
                }
            }
            lines.append("请关闭该实例或重新启动 Chrome 后点「立即刷新」。")
            return lines
        }
    }
}

/// 发现层的原始观测：LaunchServices 看到的单个 Chrome 主进程属性。与「读参数 / 读内核启动时间 / 存活判断」
/// 三个探针分开，便于用合成观测确定性地测试 discover() 本身，而不只是手工拼候选再 decide()。
struct ChromeProcessObservation: Equatable {
    let pid: pid_t
    let isTerminated: Bool
    let launchDate: Date?
    let bundleURL: URL?
}

/// 发现层用到的三个只读探针；生产用真实实现，自检可注入。
struct ChromeDiscoveryProbes {
    var readArguments: (pid_t) -> Result<[String], ProcessArguments.ReadError> = { ProcessArguments.read(pid: $0) }
    var readStartTime: (pid_t) -> ChromeProcessStartTime? = { KernelProcessInfo.startTime(pid: $0) }
    /// 只有内核确认不存在（kill(pid, 0) 返回 ESRCH）才算确凿退出；EPERM 等仍视为存活。
    var isProcessGone: (pid_t) -> Bool = { pid in kill(pid, 0) != 0 && errno == ESRCH }

    init() {}
}

enum ChromeInstanceDiscovery {
    /// 原始观测：每次刷新都重新枚举，不缓存上一轮的 PID。
    static func observe() -> [ChromeProcessObservation] {
        NSRunningApplication.runningApplications(withBundleIdentifier: ChromeInstanceIdentity.bundleIdentifier).map {
            ChromeProcessObservation(
                pid: $0.processIdentifier,
                isTerminated: $0.isTerminated,
                launchDate: $0.launchDate,
                bundleURL: $0.bundleURL
            )
        }
    }

    static func discover() -> [ChromeInstanceCandidate] {
        discover(observations: observe())
    }

    /// 观测 → 候选。参数读取失败时，只有「确凿已退出」（LaunchServices 标记终止，或内核 ESRCH）才移除；
    /// 参数与内核启动时间读不到都**不证明退出**，该进程保留为候选并由分类判成「无法确认」，
    /// 从而阻止另一个可读的普通候选被错误地自动选中。
    static func discover(observations: [ChromeProcessObservation], probes: ChromeDiscoveryProbes = ChromeDiscoveryProbes()) -> [ChromeInstanceCandidate] {
        observations.compactMap { observation -> ChromeInstanceCandidate? in
            let pid = observation.pid
            let startTime = probes.readStartTime(pid)
            switch probes.readArguments(pid) {
            case .success(let arguments):
                return ChromeInstanceCandidate(
                    pid: pid,
                    startTime: startTime,
                    launchDate: observation.launchDate,
                    bundleURL: observation.bundleURL,
                    arguments: arguments
                )
            case .failure(let error):
                if observation.isTerminated || probes.isProcessGone(pid) {
                    return nil
                }
                return ChromeInstanceCandidate(
                    pid: pid,
                    startTime: startTime,
                    launchDate: observation.launchDate,
                    bundleURL: observation.bundleURL,
                    arguments: nil,
                    argumentError: error.description
                )
            }
        }
    }

    /// 纯决策：可用合成候选确定性测试。
    /// 只有「恰好一个普通候选、且没有无法确认的候选」才选中；其余情况全部带原因停止。
    static func decide(candidates: [ChromeInstanceCandidate]) -> ChromeInstanceDecision {
        let reports = candidates.map { ChromeInstanceReport(candidate: $0, classification: ChromeInstanceClassifier.classify($0)) }
        let normal = reports.filter { if case .normal = $0.classification { return true } else { return false } }
        let automation = reports.filter { if case .automation = $0.classification { return true } else { return false } }
        let uncertain = reports.filter { if case .uncertain = $0.classification { return true } else { return false } }

        let selection: ChromeInstanceSelection
        if reports.isEmpty {
            selection = .notRunning
        } else if !uncertain.isEmpty {
            // 无法确认的候选可能就是用户的普通 Chrome，也可能是自动化实例：不猜。
            selection = .unverifiable(uncertain.map(\.pid))
        } else if normal.count == 1 {
            if let identity = ChromeInstanceIdentity(candidate: normal[0].candidate) {
                selection = .selected(identity)
            } else {
                selection = .unverifiable([normal[0].pid])
            }
        } else if normal.isEmpty {
            selection = .onlyAutomation(automation.map(\.pid))
        } else {
            selection = .multipleNormal(normal.map(\.pid))
        }
        return ChromeInstanceDecision(reports: reports, selection: selection)
    }
}
