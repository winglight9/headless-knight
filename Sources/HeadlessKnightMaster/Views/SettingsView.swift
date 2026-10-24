import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        PopupScaffold(dot: Theme.grayDot, title: "设置", onClose: { state.dismissSettings() }) {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    SettingsRow {
                        Text("开机自启")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink)
                    } trailing: {
                        CapsuleToggle(isOn: state.settings.launchAtLogin) {
                            state.toggleLaunchAtLogin()
                        }
                    }
                    HairlineDivider()
                    SettingsRow {
                        Text("拔线后等待")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink)
                    } trailing: {
                        Button(action: { state.cycleSleepDelay() }) {
                            Text("\(state.sleepDelaySeconds) 秒 ›")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondaryInk)
                        }
                        .buttonStyle(.plain)
                    }
                    HairlineDivider()
                    SettingsRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("强力模式")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.ink)
                            Text("没结束外出、机器又醒着满 10 分钟，就强制它再睡一次")
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
                            Text("通知")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.ink)
                            Text(state.notificationStatus)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.tertiaryInk)
                        }
                    } trailing: {
                        Button(action: { state.sendTestNotification() }) {
                            Text("试一下 ›")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondaryInk)
                        }
                        .buttonStyle(.plain)
                    }
                    HairlineDivider()
                    SettingsRow {
                        Text("后台服务")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink)
                    } trailing: {
                        Text(state.helperInstalled ? "已安装" : "未安装")
                            .font(.system(size: 12))
                            .foregroundStyle(state.helperInstalled ? Theme.green : Theme.red)
                    }
                    HairlineDivider()
                    SettingsRow {
                        Text("重新查看引导")
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
                            Text("退出无头骑士大师")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.ink)
                            if state.isAwayPhase {
                                Text("会先结束外出、把设置恢复原样")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.tertiaryInk)
                            }
                        }
                    } trailing: {
                        Button(action: { state.quitApp() }) {
                            Text("退出 ›")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondaryInk)
                        }
                        .buttonStyle(.plain)
                        .disabled(state.isBusy)
                    }
                }
                .padding(.top, 6)

                TinyText(text: "无头骑士大师 \(state.appVersion)　·　⌘Q 也可以退出", alignment: .center)
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
