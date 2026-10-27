import HKMKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        PopupScaffold(status: .settings, title: L("设置"), onClose: { state.dismissSettings() }) {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    SettingsRow {
                        Text(L("开机自启"))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink)
                    } trailing: {
                        CapsuleToggle(isOn: state.settings.launchAtLogin) {
                            state.toggleLaunchAtLogin()
                        }
                    }
                    HairlineDivider()
                    SettingsRow {
                        Text(L("拔线后等待"))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink)
                    } trailing: {
                        Button(action: { state.cycleSleepDelay() }) {
                            Text(L("{0} 秒 ›", state.sleepDelaySeconds))
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondaryInk)
                        }
                        .buttonStyle(.plain)
                    }
                    HairlineDivider()
                    SettingsRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("增强模式"))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.ink)
                            Text(L("机器连续醒着 5 分钟，又没结束外出，就再睡一次"))
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.tertiaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } trailing: {
                        CapsuleToggle(isOn: state.settings.strongMode) {
                            state.toggleStrongMode()
                        }
                    }
                    HairlineDivider()
                    SettingsRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("没有内建屏"))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.ink)
                            Text(L("拆掉屏的机器勾上，否则拔了线可能不睡"))
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.tertiaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } trailing: {
                        CapsuleToggle(isOn: state.settings.noBuiltinDisplay) {
                            state.toggleNoBuiltinDisplay()
                        }
                    }
                    HairlineDivider()
                    SettingsRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("通知"))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.ink)
                            Text(state.notificationStatus)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.tertiaryInk)
                        }
                    } trailing: {
                        Button(action: { state.sendTestNotification() }) {
                            Text(L("试一下 ›"))
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondaryInk)
                        }
                        .buttonStyle(.plain)
                    }
                    HairlineDivider()
                    // 红字是「有件事需要你处理」，那就得能点。以前这里只有一个
                    // Text，用户点了半天以为坏了。
                    SettingsRow {
                        Text(L("后台服务"))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink)
                    } trailing: {
                        if state.helperInstalled {
                            Text(L("已安装"))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.green)
                        } else {
                            Button(action: { state.installHelper() }) {
                                Text(state.isBusy ? L("安装中…") : L("未安装 · 点这里安装 ›"))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.red)
                            }
                            .buttonStyle(.plain)
                            .disabled(state.isBusy)
                        }
                    }
                    HairlineDivider()
                    SettingsRow {
                        Text(L("重新查看引导"))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink)
                    } trailing: {
                        Button(action: { state.replayOnboarding() }) {
                            Text("›")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.tertiaryInk)
                        }
                        .buttonStyle(.plain)
                    }
                    HairlineDivider()
                    SettingsRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("退出无头骑士大师"))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.ink)
                            if state.isAwayPhase {
                                Text(L("会先结束外出、把设置恢复原样"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.tertiaryInk)
                            }
                        }
                    } trailing: {
                        Button(action: { state.quitApp() }) {
                            Text(L("退出 ›"))
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondaryInk)
                        }
                        .buttonStyle(.plain)
                        .disabled(state.isBusy)
                    }
                }
                .padding(.top, 6)

                TinyText(text: L("无头骑士大师 {0}　·　⌘Q 也可以退出", state.appVersion), alignment: .center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 22)
            }
        }
    }
}

struct SettingsRow<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack {
            leading()
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 10)
    }
}
