import HKMKit
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        PopupScaffold(
            status: state.sleepDisabled ? StatusTag(text: L("睡眠被锁"), color: Theme.amber) : .home,
            title: L("无头骑士大师"),
            onGear: { state.showSettings() }
        ) {
            VStack(spacing: 0) {
                VStack(spacing: 5) {
                    Text(L("在家"))
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    NoteText(text: state.sleepDisabled ? L("系统睡眠被锁着（disablesleep=1）") : L("系统可以正常睡眠"))
                }
                .padding(.top, 30)
                .padding(.bottom, 22)

                // 上次恢复没做完：快照还欠着，必须先补上，否则下次拍到的「原始设置」
                // 是上次改过的值，从此再也恢复不回来。
                if state.pendingRestore {
                    WarningBox {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("上次没能恢复原设置"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.ink)
                            Text(L("睡眠设置还停留在外出状态，先恢复，再出门"))
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.tertiaryInk)
                                .lineSpacing(2)
                        }
                    }
                    .padding(.bottom, 10)

                    PopupButton(title: L("重试恢复"), isEnabled: !state.isBusy) {
                        state.retryRestore()
                    }
                    .padding(.bottom, 10)
                }

                PopupButton(title: L("开始外出模式"), isEnabled: !state.isBusy) {
                    state.beginAway()
                }

                VStack(spacing: 0) {
                    HairlineDivider()
                    if let report = state.lastReport {
                        VStack(alignment: .leading, spacing: 7) {
                            NoteText(text: L("上次外出 {0}", report.durationText))
                            HStack(spacing: 12) {
                                Text(L("后台唤醒 {0} 次", report.backgroundWakeCount))
                                    .foregroundStyle(Theme.tertiaryInk)
                                Text(L("真实唤醒 {0} 次", report.realWakeCount))
                                    .foregroundStyle(report.realWakeCount > 0 ? Theme.red : Theme.tertiaryInk)
                            }
                            .font(.system(size: 11))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 13)
                    } else {
                        NoteText(text: L("还没有外出记录"))
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
