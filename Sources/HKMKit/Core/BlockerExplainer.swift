import Foundation

/// 检测页每行的那两句话：它在挡什么、能怎么办。
public struct BlockerExplanation: Sendable, Equatable {
    public let reason: String
    public let suggestion: String?

    public init(reason: String, suggestion: String? = nil) {
        self.reason = reason
        self.suggestion = suggestion
    }
}

/// 把 `pmset -g assertions` 翻成人话。
///
/// 断言名是各个程序自己起的，没有标准：Chrome 叫 `AudioPlayback`，powerd 叫
/// `Prevent sleep while display is on`，MacHead 叫 `MacHead: Headless mode active`。
/// 所以只能按关键词猜，猜不出来就退回断言类型。宁可说得粗一点（「不许电脑空闲
/// 睡眠」），也不要为了好看编一个具体理由——用户会照着这句话去关东西。
public enum BlockerExplainer {
    public static func explain(_ blocker: SleepBlocker) -> BlockerExplanation {
        BlockerExplanation(reason: reason(for: blocker), suggestion: suggestion(for: blocker))
    }

    // MARK: - 它在挡什么

    /// 顺序有意义：先认具体理由（放声音、备份），都认不出来才说断言类型。
    private static let nameRules: [(needles: [String], reason: String)] = [
        (["audio", "playing", "playback", "sound"], "正在放音频"),
        (["video", "movie", "fullscreen"], "正在放视频"),
        (["headless"], "它也在做无头模式"),
        (["caffeinate"], "caffeinate 在保活"),
        (["display is on"], "屏幕亮着就不许睡"),
        (["time machine", "timemachine", "backup"], "正在备份"),
        (["download", "upload", "transfer"], "正在传文件"),
        (["sync"], "正在同步"),
        (["call", "meeting", "conference"], "正在通话或开会"),
        (["burn"], "正在刻录")
    ]

    public static func reason(for blocker: SleepBlocker) -> String {
        // 只挡屏幕的断言和「电脑能不能睡」无关，先单独说清楚，
        // 不然用户会以为它才是罪魁祸首。
        if blocker.kind == .displayOnly {
            return L("只让屏幕不灭")
        }
        let names = blocker.assertionNames.map { $0.lowercased() }
        for rule in nameRules where names.contains(where: { name in rule.needles.contains(where: name.contains) }) {
            return L(rule.reason)
        }
        return typeReason(blocker.assertionTypes)
    }

    static func typeReason(_ types: [String]) -> String {
        if types.contains("PreventSystemSleep") {
            return L("不许电脑睡眠")
        }
        if types.contains("InternalPreventSleep") {
            return L("系统内部保持唤醒")
        }
        if types.contains("PreventUserIdleSystemSleep") || types.contains("NoIdleSleepAssertion") {
            return L("不许电脑空闲睡眠")
        }
        if types.contains(where: AssertionScanner.displayOnlyTypes.contains) {
            return L("只让屏幕不灭")
        }
        return L("阻止电脑睡眠")
    }

    // MARK: - 能怎么办

    /// 顺序 = 从「只关一部分就够」到「只能整个退出」。
    ///
    /// 这里全部用小写子串匹配 bundle id：写死完整 id 太脆（同一个 App 的
    /// 正式版 / Beta / 企业版 id 都不一样），而 "chrome" 这种片段几乎不会误伤。
    public static func suggestion(for blocker: SleepBlocker) -> String? {
        if blocker.kind == .displayOnly {
            return L("不影响睡眠，可以不管它")
        }
        let bundle = (blocker.bundleIdentifier ?? "").lowercased()
        let name = blocker.processName.lowercased()

        func matches(_ needles: [String]) -> Bool {
            needles.contains { bundle.contains($0) || name.contains($0) }
        }

        if matches(["netease.uu", "uuremote"]) || name.hasPrefix("uu") {
            return L("在 UU 里关掉「防休眠」，就不用退出它")
        }
        if matches(["zoom", "teams", "tencent.meeting", "lark", "dingtalk", "webex"]) {
            return L("会开完它自己就放开了；现在退出等于挂断")
        }
        if matches(["chrome", "edgemac", "brave.browser", "thebrowser.browser", "safari", "firefox", "vivaldi", "opera"]) {
            return L("关掉在放声音的那个标签页就好")
        }
        if matches(["vlc", "iina", "spotify", "apple.music", "mpv", "quicktime"]) {
            return L("暂停播放就放开了")
        }
        if matches(["amphetamine", "keepingyouawake", "theine", "caffeine", "jiggler", "owly"]) || name == "caffeinate" {
            return L("这类保活工具直接退出就行")
        }
        if matches(["docker"]) {
            return L("容器在跑就会一直保活，先停掉容器")
        }
        if matches(["headlessknight", "machead"]) || name.contains("无头骑士") {
            return L("它和你在做同一件事，退出它")
        }
        if name == "electron" {
            return L("某个 Electron 应用在保活，退出它最省事")
        }
        return L("退出它，或者在它的设置里关掉保活")
    }
}
