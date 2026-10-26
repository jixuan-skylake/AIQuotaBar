import ApplicationServices
import Foundation

// MARK: - 按 PID 定址的 Chrome Apple Events 传输层
//
// 职责：把「窗口 / 标签枚举、按稳定 ID 复核 URL、tab loading 状态、reload、execute javascript」封装成发往单个
// 已验证 Chrome 进程的原生 Apple Events。事件目标是 `typeKernelProcessID`（`NSAppleEventDescriptor(processIdentifier:)`），
// 不再经 osascript 的 `tell application "Google Chrome"` 按名称路由，因此多个同名同 bundle id 的 Chrome 主进程
// 同时运行时，事件只会到达构造时给定的那个 PID。
//
// 流程（R1 整改后的传输边界）：每条事件 send() 之前先做「预算 / 取消检查」再做「身份核验」，事件等待时间
// 不超过剩余预算；回复到达后再次核验身份并检查取消标记，身份已变化或已取消的回复直接丢弃、不采纳。
// 对象说明符与 AppleScript 编译结果一致：`tab id X of window id Y`、`id/URL of every tab of window id Y`。
//
// 错误：-1743/-1744 自动化权限、-1712 超时、-600/-609 进程消失、-1728 对象不存在，以及 Chrome 返回的
// 「Apple 事件中的 JavaScript 已关闭」等文本，全部保留原始代码与文本。身份失效 / 看门狗属于致命错误
// （`isFatal`），上层不得把它们当成局部错误继续。
//
// 边界：只发送到构造时的 PID；PID 不存在时事件失败（procNotFound），绝不会启动 Chrome。事件日志只记录
// 事件类别 / 代码 / 目标 PID / 耗时 / 结果，不记录页面正文与 JavaScript 返回值。

enum AppleEventCode {
    /// 四字符码 → UInt32，与 AEDataModel.h 中 'abcd' 字面量同值。
    static func code(_ text: String) -> UInt32 {
        let bytes = Array(text.utf8)
        precondition(bytes.count == 4, "four-char code must be exactly 4 ASCII bytes: \(text)")
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static func text(_ code: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff)
        ]
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Chrome `scripting.sdef`（Google Chrome.app/Contents/Resources）与 AE 数据模型里用到的全部代码。
/// `--self-test` 会把这里的 Chrome 代码和本机 sdef 逐项比对。
enum ChromeAppleEventCodes {
    // Standard Suite
    static let coreSuite = AppleEventCode.code("core")
    static let getData = AppleEventCode.code("getd")

    // Chromium Suite
    static let chromiumSuite = AppleEventCode.code("CrSu")
    static let reload = AppleEventCode.code("Rlod")
    static let executeJavaScript = AppleEventCode.code("ExJa")
    static let javascriptParameter = AppleEventCode.code("JvSc")
    static let windowClass = AppleEventCode.code("cwin")
    static let tabClass = AppleEventCode.code("CrTb")
    static let idProperty = AppleEventCode.code("ID  ")
    static let urlProperty = AppleEventCode.code("URL ")
    static let loadingProperty = AppleEventCode.code("ldng")

    // Apple Event 数据模型
    static let propertyClass = AppleEventCode.code("prop")
    static let directObject = AppleEventCode.code("----")
    static let desiredClass = AppleEventCode.code("want")
    static let container = AppleEventCode.code("from")
    static let keyForm = AppleEventCode.code("form")
    static let keyData = AppleEventCode.code("seld")
    static let formPropertyID = AppleEventCode.code("prop")
    static let formUniqueID = AppleEventCode.code("ID  ")
    static let formAbsolutePosition = AppleEventCode.code("indx")
    static let typeObjectSpecifier = AppleEventCode.code("obj ")
    static let typeAbsoluteOrdinal = AppleEventCode.code("abso")
    static let allElements = AppleEventCode.code("all ")
    static let typeList = AppleEventCode.code("list")
    static let typeNull = AppleEventCode.code("null")
    static let typeKernelProcessID = AppleEventCode.code("kpid")
    static let errorNumber = AppleEventCode.code("errn")
    static let errorString = AppleEventCode.code("errs")
    static let addressAttribute = AppleEventCode.code("addr")
}

/// 对象说明符构造。ID 一律按文本发送：Chrome sdef 把 window/tab 的 id 声明为 text，
/// 0.2.13 的 AppleScript 也是把 id `as text` 后再 `tab id … of window id …`，这是实测可用的形式。
enum ChromeSpecifier {
    private typealias C = ChromeAppleEventCodes

    static func object(want: UInt32, from container: NSAppleEventDescriptor, form: UInt32, seld: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: C.desiredClass)
        record.setDescriptor(container, forKeyword: C.container)
        record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: C.keyForm)
        record.setDescriptor(seld, forKeyword: C.keyData)
        // AERecord → typeObjectSpecifier 只是改记录类型，AE Manager 保证成功；兜底返回 record 只为避免强制解包。
        return record.coerce(toDescriptorType: C.typeObjectSpecifier) ?? record
    }

    /// `every` 元素的绝对序数 'abso'('all ')。数据按本机字节序存放，AE Manager 传输时会对已知的四字符类型做字节序处理。
    static func allOrdinal() -> NSAppleEventDescriptor {
        var all = C.allElements
        return NSAppleEventDescriptor(descriptorType: C.typeAbsoluteOrdinal, bytes: &all, length: MemoryLayout<UInt32>.size)
            ?? NSAppleEventDescriptor(enumCode: C.allElements)
    }

    static func everyWindow() -> NSAppleEventDescriptor {
        object(want: C.windowClass, from: NSAppleEventDescriptor.null(), form: C.formAbsolutePosition, seld: allOrdinal())
    }

    static func window(id windowID: String) -> NSAppleEventDescriptor {
        object(want: C.windowClass, from: NSAppleEventDescriptor.null(), form: C.formUniqueID, seld: NSAppleEventDescriptor(string: windowID))
    }

    static func everyTab(inWindowID windowID: String) -> NSAppleEventDescriptor {
        object(want: C.tabClass, from: window(id: windowID), form: C.formAbsolutePosition, seld: allOrdinal())
    }

    static func tab(id tabID: String, inWindowID windowID: String) -> NSAppleEventDescriptor {
        object(want: C.tabClass, from: window(id: windowID), form: C.formUniqueID, seld: NSAppleEventDescriptor(string: tabID))
    }

    static func property(_ propertyCode: UInt32, of specifier: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        object(want: C.propertyClass, from: specifier, form: C.formPropertyID, seld: NSAppleEventDescriptor(typeCode: propertyCode))
    }
}

/// 事件构造。目标描述符由调用方传入（生产代码只会传 `NSAppleEventDescriptor(processIdentifier:)`）。
enum ChromeEvent {
    private typealias C = ChromeAppleEventCodes

    private static func make(eventClass: UInt32, eventID: UInt32, target: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: eventClass,
            eventID: eventID,
            targetDescriptor: target,
            returnID: AEReturnID(-1),        // kAutoGenerateReturnID
            transactionID: AETransactionID(0) // kAnyTransactionID
        )
    }

    static func getData(_ specifier: NSAppleEventDescriptor, target: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let event = make(eventClass: C.coreSuite, eventID: C.getData, target: target)
        event.setParam(specifier, forKeyword: C.directObject)
        return event
    }

    static func reload(tab: NSAppleEventDescriptor, target: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let event = make(eventClass: C.chromiumSuite, eventID: C.reload, target: target)
        event.setParam(tab, forKeyword: C.directObject)
        return event
    }

    static func executeJavaScript(tab: NSAppleEventDescriptor, script: String, target: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let event = make(eventClass: C.chromiumSuite, eventID: C.executeJavaScript, target: target)
        event.setParam(tab, forKeyword: C.directObject)
        event.setParam(NSAppleEventDescriptor(string: script), forKeyword: C.javascriptParameter)
        return event
    }
}

/// 带阶段信息的 Chrome 事件错误。`code` 是 OSStatus 或 Chrome 回复里的 errn，`chromeMessage` 是 errs 原文。
struct ChromeEventError: Error, LocalizedError, Equatable {
    enum Stage: String, Equatable {
        case identity = "身份核验"
        case enumerateWindows = "枚举窗口"
        case enumerateTabs = "枚举标签"
        case verifyTarget = "稳定 ID 复核"
        case reload = "reload"
        case probe = "就绪探测"
        case read = "读取正文"
        case watchdog = "看门狗"
    }

    let stage: Stage
    let code: Int32?
    let message: String
    let chromeMessage: String?
    /// 页面就绪阶段上限导致的拒绝 / 丢弃：非致命，读取流程据此把等待中的目标判为超时并停止后续就绪探测。
    let isStageLimit: Bool

    init(stage: Stage, code: Int32?, message: String, chromeMessage: String? = nil, isStageLimit: Bool = false) {
        self.stage = stage
        self.code = code
        self.message = message
        self.chromeMessage = chromeMessage
        self.isStageLimit = isStageLimit
    }

    var errorDescription: String? {
        var text = "\(stage.rawValue)失败: \(message)"
        if let chromeMessage, !chromeMessage.isEmpty, !message.contains(chromeMessage) {
            text += "（Chrome: \(chromeMessage)）"
        }
        if let code {
            text += " [\(code)]"
        }
        return text
    }

    /// 身份失效与看门狗 / 预算耗尽必须终止整轮读取，不能被窗口级 / 目标级 catch 降为局部错误。
    var isFatal: Bool { stage == .identity || stage == .watchdog }
    var isPermissionDenied: Bool { code == -1743 || code == -1744 }
    var isTimeout: Bool { code == -1712 }
    var isProcessGone: Bool { code == -600 || code == -609 || stage == .identity }
    /// Chrome 关闭「允许 Apple 事件中的 JavaScript」时返回的错误文本含 JavaScript 字样。
    var isJavaScriptRelated: Bool {
        (stage == .probe || stage == .read)
            && ((chromeMessage ?? "").localizedCaseInsensitiveContains("javascript")
                || message.localizedCaseInsensitiveContains("javascript"))
    }

    static func fromOSStatus(_ code: Int32, stage: Stage, chromeMessage: String?) -> ChromeEventError {
        let message: String
        switch code {
        case -1743:
            message = "macOS 拒绝了对 Google Chrome 的自动化控制（errAEEventNotPermitted）。请在 系统设置 > 隐私与安全性 > 自动化 中允许 AIQuotaBar 控制 Google Chrome；从终端运行时权限归属于终端应用。"
        case -1744:
            message = "自动化权限需要用户在系统弹窗中确认（errAEEventWouldRequireUserConsent）。"
        case -1712:
            message = "Apple Event 等待 Chrome 回复超时（errAETimeout）。"
        case -600, -609:
            message = "目标 Chrome 进程不存在或连接已失效（\(code)）；AIQuotaBar 不会启动 Chrome。"
        case -1728:
            message = "Chrome 中没有这个窗口/标签对象（errAENoSuchObject），可能已关闭或移动。"
        case -1708:
            message = "Chrome 未处理该事件（errAEEventNotHandled）。"
        case -1700, -1703, -1704:
            message = "Chrome 不接受事件参数类型（\(code)）。"
        default:
            if let chromeMessage, !chromeMessage.isEmpty {
                message = chromeMessage
            } else {
                message = "Apple Event 错误 \(code)"
            }
        }
        return ChromeEventError(stage: stage, code: code, message: message, chromeMessage: chromeMessage)
    }
}

struct ChromeTabRef: Equatable {
    let windowID: String
    let tabID: String
    let url: String
}

enum ChromeJavaScriptPurpose: String {
    case probe = "就绪探测"
    case read = "读取正文"
}

/// 面向单个已验证 Chrome 进程的最小事件集合。生产实现是 `ChromeAppleEventTransport`；自检用可编程 mock。
/// 实现者必须在每次调用的边界执行预算 / 取消检查与身份核验（发送前 + 回复后）。
protocol ChromeTransport: AnyObject {
    var pid: pid_t { get }
    var eventLog: [String] { get }
    var eventCounts: [String: Int] { get }
    func verifyIdentity() throws
    func windowIDs() throws -> [String]
    func tabs(inWindow windowID: String) throws -> [ChromeTabRef]
    func tabURL(windowID: String, tabID: String) throws -> String
    func tabLoading(windowID: String, tabID: String) throws -> Bool
    func reload(windowID: String, tabID: String) throws
    func executeJavaScript(windowID: String, tabID: String, script: String, purpose: ChromeJavaScriptPurpose) throws -> String
}

final class ChromeAppleEventTransport: ChromeTransport {
    private typealias C = ChromeAppleEventCodes

    /// 实际发送函数：生产用 `NSAppleEventDescriptor.sendEvent`，自检可注入假回复以覆盖边界逻辑。
    typealias RawSender = (NSAppleEventDescriptor, TimeInterval) throws -> NSAppleEventDescriptor

    static let defaultEventTimeout: TimeInterval = 15
    static let maxLogEntries = 240

    let identity: ChromeInstanceIdentity
    let budget: ChromeReadBudget
    let eventTimeout: TimeInterval
    private let target: NSAppleEventDescriptor
    private let rawSend: RawSender
    private let identityCheck: () -> String?
    private let logLock = NSLock()
    private var log: [String] = []
    private var counts: [String: Int] = [:]

    var pid: pid_t { identity.pid }

    /// - Parameters:
    ///   - budget: 与读取流程共享的取消标记 / 单调 deadline；每条事件发送前检查，等待时间不超过剩余预算。
    ///   - rawSend / identityCheck: 仅自检注入；生产用真实发送与 `identity.verifyKernel()`。
    init(
        identity: ChromeInstanceIdentity,
        budget: ChromeReadBudget,
        eventTimeout: TimeInterval = ChromeAppleEventTransport.defaultEventTimeout,
        rawSend: RawSender? = nil,
        identityCheck: (() -> String?)? = nil
    ) {
        self.identity = identity
        self.budget = budget
        self.eventTimeout = eventTimeout
        target = NSAppleEventDescriptor(processIdentifier: identity.pid)
        self.rawSend = rawSend ?? { event, timeout in
            // canInteract 只允许 Chrome 在已是前台时显示对话框，不带 canSwitchLayer：绝不把 Chrome 切到前台。
            try event.sendEvent(options: [.waitForReply, .canInteract], timeout: timeout)
        }
        self.identityCheck = identityCheck ?? { identity.verifyKernel() }
    }

    var eventLog: [String] {
        logLock.lock(); defer { logLock.unlock() }
        return log
    }

    var eventCounts: [String: Int] {
        logLock.lock(); defer { logLock.unlock() }
        return counts
    }

    /// 目标描述符（自检用于确认类型是 typeKernelProcessID 且载荷是选中的 PID）。
    var targetDescriptor: NSAppleEventDescriptor { target }

    func verifyIdentity() throws {
        if let reason = identity.verifyLive() {
            throw ChromeEventError(stage: .identity, code: nil, message: reason)
        }
    }

    func windowIDs() throws -> [String] {
        let event = ChromeEvent.getData(ChromeSpecifier.property(C.idProperty, of: ChromeSpecifier.everyWindow()), target: target)
        let reply = try send(event, stage: .enumerateWindows, label: "id of every window")
        return Self.textList(reply.paramDescriptor(forKeyword: C.directObject))
    }

    func tabs(inWindow windowID: String) throws -> [ChromeTabRef] {
        let everyTab = ChromeSpecifier.everyTab(inWindowID: windowID)
        let idReply = try send(
            ChromeEvent.getData(ChromeSpecifier.property(C.idProperty, of: everyTab), target: target),
            stage: .enumerateTabs,
            label: "id of every tab of window id \(windowID)"
        )
        let urlReply = try send(
            ChromeEvent.getData(ChromeSpecifier.property(C.urlProperty, of: everyTab), target: target),
            stage: .enumerateTabs,
            label: "URL of every tab of window id \(windowID)"
        )
        let ids = Self.textList(idReply.paramDescriptor(forKeyword: C.directObject))
        let urls = Self.textList(urlReply.paramDescriptor(forKeyword: C.directObject))
        // 两次事件之间标签数变化时按较短的一侧截断；任何操作前还会按稳定 tab id 重新读 URL 复核，不靠这里的配对。
        let count = min(ids.count, urls.count)
        return (0..<count).map { ChromeTabRef(windowID: windowID, tabID: ids[$0], url: urls[$0]) }
    }

    func tabURL(windowID: String, tabID: String) throws -> String {
        let specifier = ChromeSpecifier.property(C.urlProperty, of: ChromeSpecifier.tab(id: tabID, inWindowID: windowID))
        let reply = try send(
            ChromeEvent.getData(specifier, target: target),
            stage: .verifyTarget,
            label: "URL of tab id \(tabID) of window id \(windowID)"
        )
        guard let url = reply.paramDescriptor(forKeyword: C.directObject)?.stringValue else {
            throw ChromeEventError(stage: .verifyTarget, code: nil, message: "Chrome 回复中没有 URL")
        }
        return url
    }

    /// Chrome 的 tab `loading` 属性：导航进行中为 true。就绪判断先看它，再执行 JS 探针。
    func tabLoading(windowID: String, tabID: String) throws -> Bool {
        let specifier = ChromeSpecifier.property(C.loadingProperty, of: ChromeSpecifier.tab(id: tabID, inWindowID: windowID))
        let reply = try send(
            ChromeEvent.getData(specifier, target: target),
            stage: .probe,
            label: "loading of tab id \(tabID) of window id \(windowID)"
        )
        guard let value = reply.paramDescriptor(forKeyword: C.directObject) else {
            throw ChromeEventError(stage: .probe, code: nil, message: "Chrome 回复中没有 loading 状态")
        }
        return value.booleanValue
    }

    func reload(windowID: String, tabID: String) throws {
        let event = ChromeEvent.reload(tab: ChromeSpecifier.tab(id: tabID, inWindowID: windowID), target: target)
        _ = try send(event, stage: .reload, label: "reload tab id \(tabID) of window id \(windowID)")
    }

    func executeJavaScript(windowID: String, tabID: String, script: String, purpose: ChromeJavaScriptPurpose) throws -> String {
        let event = ChromeEvent.executeJavaScript(
            tab: ChromeSpecifier.tab(id: tabID, inWindowID: windowID),
            script: script,
            target: target
        )
        let reply = try send(
            event,
            stage: purpose == .probe ? .probe : .read,
            label: "execute javascript(\(purpose.rawValue)) tab id \(tabID) of window id \(windowID)"
        )
        return reply.paramDescriptor(forKeyword: C.directObject)?.stringValue ?? ""
    }

    // MARK: 发送与回复（传输边界）

    private func send(_ event: NSAppleEventDescriptor, stage: ChromeEventError.Stage, label: String) throws -> NSAppleEventDescriptor {
        let key = "\(AppleEventCode.text(event.eventClass))/\(AppleEventCode.text(event.eventID))"

        // 1. 看门狗 / 预算：已取消或预算耗尽后不再发送任何新事件。
        do {
            try budget.checkpoint(label)
        } catch let error as ChromeEventError {
            record(key: key, label: label, milliseconds: 0, outcome: "未发送（\(error.message)）")
            throw error
        }
        // 2. 发送前身份核验（传输边界，不依赖上层循环）。
        if let reason = identityCheck() {
            record(key: key, label: label, milliseconds: 0, outcome: "未发送（身份失效: \(reason)）")
            throw ChromeEventError(stage: .identity, code: nil, message: "发送前身份核验失败: \(reason)")
        }
        // 3. 身份核验可能耗时：发送前再次核对同一 deadline 与取消标记；等待时间取整轮剩余与页面阶段剩余的较小者；
        //    剩余不足最小等待粒度时拒绝发送，而不是把等待扩大到 0.1 秒。
        //    （OS 层面从 checkpoint 到实际发出之间仍有纳秒级窗口，这里不宣称能消除。）
        do {
            try budget.checkpoint("发送前复核 \(label)")
        } catch let error as ChromeEventError {
            record(key: key, label: label, milliseconds: 0, outcome: "未发送（身份核验后: \(error.message)）")
            throw error
        }
        guard let wait = budget.eventWait(default: eventTimeout) else {
            let error = Self.insufficientBudgetError(budget: budget, stage: stage)
            record(key: key, label: label, milliseconds: 0, outcome: "未发送（\(error.message)）")
            throw error
        }
        let started = Date()
        let reply: NSAppleEventDescriptor
        do {
            reply = try rawSend(event, wait.timeout)
        } catch {
            let nsError = error as NSError
            let chromeMessage = (nsError.userInfo["ErrorString"] as? String)
                ?? (nsError.userInfo[NSLocalizedFailureReasonErrorKey] as? String)
            let mapped = ChromeEventError.fromOSStatus(Int32(clamping: nsError.code), stage: stage, chromeMessage: chromeMessage)
            record(key: key, label: label, milliseconds: elapsedMilliseconds(since: started), outcome: "失败 \(mapped.code.map { String($0) } ?? "?")")
            throw mapped
        }
        // 4. 回复到达后：身份已变化、看门狗已取消、整轮 deadline 已过（即使没有取消标记）、或页面阶段上限已过 → 回复不采纳。
        if let reason = identityCheck() {
            record(key: key, label: label, milliseconds: elapsedMilliseconds(since: started), outcome: "回复已丢弃（回复后身份失效: \(reason)）")
            throw ChromeEventError(stage: .identity, code: nil, message: "回复到达后身份核验失败，回复未采纳: \(reason)")
        }
        do {
            try budget.checkpoint("回复后 \(label)")
        } catch let error as ChromeEventError {
            record(key: key, label: label, milliseconds: elapsedMilliseconds(since: started), outcome: "回复已丢弃（\(error.message)）")
            throw ChromeEventError(stage: .watchdog, code: nil, message: "回复到达时已超出整轮预算或已取消，回复未采纳: \(error.message)")
        }
        if budget.stageExceeded {
            record(key: key, label: label, milliseconds: elapsedMilliseconds(since: started), outcome: "回复已丢弃（超过页面就绪上限）")
            throw ChromeEventError(stage: stage, code: nil, message: "回复到达时已超过页面就绪上限，回复不采纳", isStageLimit: true)
        }
        if let number = reply.paramDescriptor(forKeyword: C.errorNumber)?.int32Value, number != 0 {
            let mapped = ChromeEventError.fromOSStatus(
                number,
                stage: stage,
                chromeMessage: reply.paramDescriptor(forKeyword: C.errorString)?.stringValue
            )
            record(key: key, label: label, milliseconds: elapsedMilliseconds(since: started), outcome: "Chrome 报错 \(number)")
            throw mapped
        }
        record(key: key, label: label, milliseconds: elapsedMilliseconds(since: started), outcome: "ok")
        return reply
    }

    /// 剩余等待不足最小粒度时的拒绝：页面阶段上限导致的是非致命（阶段限制），整轮预算导致的是看门狗（致命）。
    /// mock 传输层复用同一判定，保证自检与生产一致。
    static func insufficientBudgetError(budget: ChromeReadBudget, stage: ChromeEventError.Stage) -> ChromeEventError {
        let overall = budget.remaining()
        let minimum = String(format: "%.2f", ChromeReadBudget.minimumEventWait)
        if let stageRemaining = budget.stageRemaining(), stageRemaining < overall {
            return ChromeEventError(
                stage: stage,
                code: nil,
                message: "页面就绪上限剩余 \(String(format: "%.2f", stageRemaining)) s，不足最小事件等待粒度 \(minimum) s，未发送",
                isStageLimit: true
            )
        }
        return ChromeEventError(
            stage: .watchdog,
            code: nil,
            message: "剩余预算 \(String(format: "%.2f", overall)) s 不足最小事件等待粒度 \(minimum) s，未发送"
        )
    }

    private func elapsedMilliseconds(since started: Date) -> Int {
        Int(Date().timeIntervalSince(started) * 1000)
    }

    private func record(key: String, label: String, milliseconds: Int, outcome: String) {
        logLock.lock(); defer { logLock.unlock() }
        counts[key, default: 0] += 1
        if log.count < Self.maxLogEntries {
            log.append("\(key) \(label) → PID \(pid): \(outcome) \(milliseconds)ms")
        } else if log.count == Self.maxLogEntries {
            log.append("…（事件日志已达上限 \(Self.maxLogEntries) 条）")
        }
    }

    /// 回复直接参数 → 文本数组。单个值也包成一项；无法转成文本的项保留为空串以维持与并行列表的位置对齐。
    static func textList(_ descriptor: NSAppleEventDescriptor?) -> [String] {
        guard let descriptor else { return [] }
        if descriptor.descriptorType == C.typeList {
            return (0..<descriptor.numberOfItems).map { descriptor.atIndex($0 + 1)?.stringValue ?? "" }
        }
        if descriptor.descriptorType == C.typeNull {
            return []
        }
        return [descriptor.stringValue ?? ""]
    }
}
