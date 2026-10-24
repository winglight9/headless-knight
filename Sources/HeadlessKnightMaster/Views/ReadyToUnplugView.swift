import SwiftUI

struct ReadyToUnplugView: View {
    @EnvironmentObject private var state: AppState

    private var sleepFailureReason: String? {
        if case let .failed(reason) = state.sleepOutcome { return reason }
        return nil
    }

    private var subtitle: String {
        if sleepFailureReason != nil {
            return "电脑还醒着，别急着装包"
        }
        if let remaining = state.unplugCountdown, state.displaysDetached {
            return "\(remaining) 秒后自动睡眠"
        }
        return "拔线后 \(state.sleepDelaySeconds) 秒自动睡眠"
    }

    var body: some View {
        PopupScaffold(status: sleepFailureReason == nil ? .ready : .attention, title: "无头骑士大师") {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    if sleepFailureReason == nil {
                        SuccessBadge(size: 50)
                            .padding(.top, 26)
                    } else {
                        LockGlyph(size: 44)
                            .padding(.top, 26)
                    }
                    Text(sleepFailureReason == nil ? "可以拔掉显示器了" : "还没能睡着")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .padding(.top, 14)
                    NoteText(text: subtitle)
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
                if let reason = sleepFailureReason {
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
                }

                // 兜底：万一哪台机器的显示器拓扑识别不出来，用户还能直接按一下。
                // 产品不能因为「自动检测猜错了」就把人卡死在这一页。
                //
                // 名字必须写清它是干什么的。以前叫「现在就让电脑睡眠」，用户会当成
                // 「我想现在睡」去点——可显示器还插着的时候，这一按只会让屏幕黑一下
                // 又亮回来。它真正的用途是「我拔了，你没发现」。
                if sleepFailureReason == nil, !state.displaysDetached {
                    PopupButton(title: "我已经拔线了，让它睡", style: .ghost, isEnabled: !state.isBusy) {
                        state.retrySleep()
                    }
                    .padding(.top, 12)
                }

                // 这个按钮不是「关掉一个弹窗」：它会把已经改掉的设置全部恢复原样。
                // 所以不能叫「取消」，要直接说清楚它干的是什么。
                PopupButton(title: "结束外出模式", style: .ghost) {
                    state.cancelReadyToUnplug()
                }
                .padding(.top, sleepFailureReason == nil && !state.displaysDetached ? 8 : 14)
            }
        }
    }
}
