import SwiftUI

struct BlockedView: View {
    @EnvironmentObject private var state: AppState

    private var completedText: String {
        if state.completedActions.isEmpty {
            return "已经完成的：无"
        }
        return "已经完成的：\n" + state.completedActions.joined(separator: " · ")
    }

    var body: some View {
        PopupScaffold(dot: Theme.amber, title: "无头骑士大师") {
            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    Text("有 \(state.criticalFailures.count) 项没能完成")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    NoteText(text: "现在走的话，电脑可能睡不着")
                }
                .padding(.top, 24)

                VStack(spacing: 8) {
                    ForEach(state.criticalFailures) { item in
                        WarningBox {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Theme.ink)
                                Text(item.detail)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.secondaryInk)
                                    .lineSpacing(2)
                            }
                        }
                    }
                }
                .padding(.top, 16)

                TinyText(text: completedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 14)

                // 蓝牙关不掉是唯一「用户自己能立刻解决」的关键项：
                // 要么给权限，要么在控制中心手动关掉。给个出口，别让他干瞪眼。
                if state.bluetoothFailure != nil {
                    TinyText(text: "蓝牙也可以在控制中心手动关掉，关完点「我处理好了」。")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)

                    PopupButton(title: "打开蓝牙权限设置", style: .ghost) {
                        state.openBluetoothSettings()
                    }
                    .padding(.top, 8)
                }

                PopupButton(title: "我处理好了", isEnabled: !state.isBusy) {
                    state.retryAfterManualFix()
                }
                .padding(.top, 16)

                if state.needsHelperInstall {
                    PopupButton(title: "安装后台服务", isEnabled: !state.isBusy) {
                        state.installHelperFromBlocked()
                    }
                    .padding(.top, 8)
                }

                PopupButton(title: "仍然继续", style: .ghost) {
                    state.continueAnyway()
                }
                .padding(.top, 8)

                PopupButton(title: "算了，恢复原设置", style: .ghost, isEnabled: !state.isBusy) {
                    state.abortAway()
                }
                .padding(.top, 8)

                TinyText(text: "选择继续，报告里会标注这次可能没睡成", alignment: .center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            }
        }
    }
}
