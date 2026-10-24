import SwiftUI

struct AwayView: View {
    @EnvironmentObject private var state: AppState

    /// 这一行以前是写死的「系统已进入睡眠」，而且蓝牙那半句取的是**改动前**的
    /// 快照值，两个分支都可能是假的。现在只说我们真的验证过的事。
    private var statusLine: String {
        var parts: [String] = []
        if state.completedActions.contains("关闭了蓝牙") {
            parts.append("蓝牙已关闭")
        } else if state.completedActions.contains("蓝牙本来就关着") {
            parts.append("蓝牙本来就关着")
        }
        switch state.sleepOutcome {
        case .slept:
            parts.append("系统已进入睡眠")
        case .requesting:
            parts.append("正在让系统睡眠…")
        case let .failed(reason):
            parts.append("系统没有睡着：\(reason)")
        case .idle:
            parts.append(state.session?.sleepRequestedAt != nil ? "睡眠请求已发出" : "还没请求睡眠")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        PopupScaffold(status: .away, title: "无头骑士大师", onGear: { state.showSettings() }) {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    Text("外出中")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Text("已 \(state.awayDurationText)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.amber)
                        .padding(.top, 5)
                    HStack(spacing: 6) {
                        BatteryGlyph(ratio: state.batteryFillRatio)
                        NoteText(text: state.batteryDropText)
                    }
                    .padding(.top, 9)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 28)
                .padding(.bottom, 20)

                PopupButton(title: "结束外出模式", style: .ghost, isEnabled: !state.isBusy) {
                    Task { await state.finishAway() }
                }

                if let seconds = state.forceSleepCountdown {
                    forceSleepBanner(seconds: seconds)
                }

                VStack(spacing: 0) {
                    HairlineDivider()
                    NoteText(text: "点开即统计，不用等")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 12)
                }
                .padding(.top, 15)

                TinyText(text: statusLine)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)
            }
        }
    }

    /// 强力模式的倒计时。它会在没人管的情况下真的把机器睡掉，所以必须
    /// 看得见、也必须能取消。
    private func forceSleepBanner(seconds: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.red)
                    .frame(width: 6, height: 6)
                Text("\(seconds) 秒后强制睡眠")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.red)
            }
            Text("机器已经醒着 \(state.awakeMinutesText)，没人在的话它会一直烧电")
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: { state.skipForcedSleepOnce() }) {
                Text("这次不睡")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryInk)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.red.opacity(0.08))
        )
        .padding(.top, 10)
    }
}

struct AuditingView: View {
    var body: some View {
        PopupScaffold(status: .auditing, title: "无头骑士大师") {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                NoteText(text: "正在统计唤醒记录，并把设置恢复原样", alignment: .center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 44)
            .padding(.bottom, 44)
        }
    }
}
