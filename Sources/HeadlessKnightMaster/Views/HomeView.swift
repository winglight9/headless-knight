import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        PopupScaffold(
            status: state.sleepDisabled ? StatusTag(text: "睡眠被锁", color: Theme.amber) : .home,
            title: "无头骑士大师",
            onGear: { state.showSettings() }
        ) {
            VStack(spacing: 0) {
                VStack(spacing: 5) {
                    Text("在家")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    NoteText(text: state.sleepDisabled ? "系统睡眠被锁着（disablesleep=1）" : "系统可以正常睡眠")
                }
                .padding(.top, 30)
                .padding(.bottom, 22)

                // 上次恢复没做完：快照还欠着，必须先补上，否则下次拍到的「原始设置」
                // 是上次改过的值，从此再也恢复不回来。
                if state.pendingRestore {
                    WarningBox {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("上次没能恢复原设置")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.ink)
                            Text("睡眠设置还停留在外出状态，先恢复，再出门")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.tertiaryInk)
                                .lineSpacing(2)
                        }
                    }
                    .padding(.bottom, 10)

                    PopupButton(title: "重试恢复", isEnabled: !state.isBusy) {
                        state.retryRestore()
                    }
                    .padding(.bottom, 10)
                }

                PopupButton(title: "开始外出模式", isEnabled: !state.isBusy) {
                    state.beginAway()
                }

                VStack(spacing: 0) {
                    HairlineDivider()
                    if let report = state.lastReport {
                        VStack(alignment: .leading, spacing: 7) {
                            NoteText(text: "上次外出 \(report.durationText)")
                            HStack(spacing: 12) {
                                Text("后台唤醒 \(report.backgroundWakeCount) 次")
                                    .foregroundStyle(Theme.tertiaryInk)
                                Text("真实唤醒 \(report.realWakeCount) 次")
                                    .foregroundStyle(report.realWakeCount > 0 ? Theme.red : Theme.tertiaryInk)
                            }
                            .font(.system(size: 11))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 13)
                    } else {
                        NoteText(text: "还没有外出记录")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 13)
                    }
                }
                .padding(.top, 16)

                TinyText(text: state.launchAtLoginText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)
            }
        }
    }
}
