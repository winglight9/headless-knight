import SwiftUI

struct ReadyToUnplugView: View {
    @EnvironmentObject private var state: AppState

    /// 「没睡成」分两种，不能混着说。
    ///
    /// 以前只有一种：只要验证没通过就写「还没能睡着」。2026-10-25 早上那扇窗口
    /// 就是这么来的——机器睡了一整夜、只掉 4% 的电，页面上却写着「电脑还醒着，
    /// 别急着装包」。
    private enum SleepProblem {
        case none
        /// 确认还醒着。
        case awake(String)
        /// 拿不到证据。
        case unknown(String)
    }

    private var problem: SleepProblem {
        switch state.sleepOutcome {
        case let .failed(reason): return .awake(reason)
        case let .unverified(reason): return .unknown(reason)
        case .idle, .requesting, .slept: return .none
        }
    }

    private var hasProblem: Bool {
        if case .none = problem { return false }
        return true
    }

    private var subtitle: String {
        switch problem {
        case let .awake(reason):
            return "电脑还醒着：\(reason)"
        case .unknown:
            return "读不到电源日志，先别急着装包"
        case .none:
            if let remaining = state.unplugCountdown, state.displaysDetached {
                return "\(remaining) 秒后自动睡眠"
            }
            return "拔线后 \(state.sleepDelaySeconds) 秒自动睡眠"
        }
    }

    private var headline: String {
        switch problem {
        case .awake: return "还没能睡着"
        case .unknown: return "还没能确认睡着"
        case .none: return "可以拔掉显示器了"
        }
    }

    var body: some View {
        PopupScaffold(status: hasProblem ? .attention : .ready, title: "无头骑士大师") {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    if !hasProblem {
                        SuccessBadge(size: 50)
                            .padding(.top, 26)
                    } else {
                        LockGlyph(size: 44)
                            .padding(.top, 26)
                    }
                    Text(headline)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .padding(.top, 14)
                    NoteText(text: subtitle, alignment: .center)
                        .padding(.top, 7)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)

                VStack(spacing: 0) {
                    HairlineDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(state.completedActions, id: \.self) { action in
                            CheckRow(text: action)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 13)
                }
                .padding(.top, 16)

                if !state.optionalFailures.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(state.optionalFailures) { item in
                            TinyText(text: item.optionalNote)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                }

                // 睡眠失败必须明说，绝不能让用户以为已经睡了然后装包走人。
                switch problem {
                case let .awake(reason):
                    WarningBox {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(reason)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.ink)
                                .lineSpacing(2)
                            // 后台重试只在「线已经拔了」的时候才跑。显示器还插着的时候
                            // 说「会自动重试」是假话——它压根不会重试，试了也只是闪屏。
                            Text(state.displaysDetached
                                ? "会自动重试，插回显示器就停"
                                : "拔掉线之后它会自己睡，不用再点")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.tertiaryInk)
                                .lineSpacing(2)
                        }
                    }
                    .padding(.top, 14)

                    PopupButton(title: "再试一次睡眠", isEnabled: !state.isBusy) {
                        state.retrySleep()
                    }
                    .padding(.top, 10)
                case let .unknown(reason):
                    WarningBox {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("查不到睡眠记录，不代表它没睡。看一眼电量就知道：一夜掉得很少就是睡了")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.ink)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(reason)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.tertiaryInk)
                                .lineSpacing(2)
                        }
                    }
                    .padding(.top, 14)

                    PopupButton(title: "再试一次睡眠", isEnabled: !state.isBusy) {
                        state.retrySleep()
                    }
                    .padding(.top, 10)
                case .none:
                    EmptyView()
                }

                // 兜底：万一哪台机器的显示器拓扑识别不出来，用户还能直接按一下。
                // 产品不能因为「自动检测猜错了」就把人卡死在这一页。
                //
                // 名字必须写清它是干什么的。以前叫「现在就让电脑睡眠」，用户会当成
                // 「我想现在睡」去点——可显示器还插着的时候，这一按只会让屏幕黑一下
                // 又亮回来。它真正的用途是「我拔了，你没发现」。
                if !hasProblem, !state.displaysDetached {
                    PopupButton(title: "我已经拔线了，让它睡", style: .ghost, isEnabled: !state.isBusy) {
                        state.retrySleep()
                    }
                    .padding(.top, 12)
                }

                // 这个按钮不是「关掉一个弹窗」：它会把已经改掉的设置全部恢复原样。
                // 所以不能叫「取消」，要直接说清楚它干的是什么。
                //
                // 还原要走后台服务改好几项设置，一两秒是常事。这段时间里按钮必须
                // 当场改口、并且点不动——否则用户以为没反应，会一直点（日志里
                // 连着六次蓝牙还原就是这么来的）。
                PopupButton(
                    title: state.isEndingAway ? "正在恢复设置…" : "结束外出模式",
                    style: .ghost,
                    isEnabled: !state.isEndingAway && !state.isBusy
                ) {
                    state.cancelReadyToUnplug()
                }
                .padding(.top, hasProblem || state.displaysDetached ? 14 : 8)
            }
        }
    }
}
