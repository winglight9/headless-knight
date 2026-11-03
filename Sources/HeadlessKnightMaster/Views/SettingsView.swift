import HKMKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        PopupScaffold(status: .settings, title: L("设置"), onClose: { state.dismissSettings() }) {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    SettingsGroupTitle(L("外出"))

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
                            Text(L("连续醒着 5 分钟再睡一次"))
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
                            Text(L("防止空闲睡眠"))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.ink)
                            Text(idleSleepText)
                                .font(.system(size: 10))
                                .foregroundStyle(idleSleepProblem ? Theme.red : Theme.tertiaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } trailing: {
                        CapsuleToggle(isOn: state.settings.preventIdleSleep) {
                            state.togglePreventIdleSleep()
                        }
                    }
                    HairlineDivider()
                    SettingsRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("没有内建屏"))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.ink)
                            Text(builtinText)
                                .font(.system(size: 10))
                                .foregroundStyle(builtinProblem ? Theme.red : Theme.tertiaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } trailing: {
                        CapsuleToggle(isOn: state.settings.noBuiltinDisplay) {
                            state.toggleNoBuiltinDisplay()
                        }
                        .disabled(!state.isBuiltinCutAvailable || state.isBusy)
                    }

                    SettingsGroupTitle(L("系统"))

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

                    SettingsGroupTitle(L("其他"))

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
                .padding(.top, 2)

                TinyText(text: L("无头骑士大师 {0}　·　⌘Q 也可以退出", state.appVersion), alignment: .center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
            }
        }
    }

    /// 「防止空闲睡眠」那一行的小字。
    ///
    /// 勾着但没拿到断言时要说出来——不然用户以为机器不会睡了，结果半夜自己睡过去。
    private var idleSleepText: String {
        if state.settings.preventIdleSleep, !state.idleSleepHeld {
            return L("系统没允许，这一项没生效")
        }
        return L("不让机器自己睡，出门自动放开")
    }

    private var idleSleepProblem: Bool {
        state.settings.preventIdleSleep && !state.idleSleepHeld
    }

    /// 「没有内建屏」那一行的小字：说现在到底断没断，不替开关说话。
    ///
    /// ⌘H 写在这里，不单独占一行——它就是这个开关的快捷键，放一起才找得到。
    private var builtinText: String {
        guard state.settings.noBuiltinDisplay else {
            return L("拆掉屏就勾上 · ⌘H 切换")
        }
        if case .disconnected = state.builtinCutState {
            return L("已断开 · ⌘H 切换")
        }
        return state.builtinCutState.summary
    }

    /// 勾着「没有内建屏」却还接着，就是有问题，得红字。
    private var builtinProblem: Bool {
        guard state.settings.noBuiltinDisplay else { return false }
        switch state.builtinCutState {
        case .connected, .failed, .unsupported: return true
        case .disconnected, .unknown: return false
        }
    }
}

/// 设置页的分组标题。
///
/// 之前是八行平铺，开关、操作、状态混在一起，用户得一行行读才知道哪些是同一类事。
/// 组标题只占十几像素，但把「出门才用到的」和「装好就不用管的」分开了。
struct SettingsGroupTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack {
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryInk)
            Spacer(minLength: 0)
        }
        .padding(.top, 13)
        .padding(.bottom, 3)
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
        .padding(.vertical, 9)
    }
}
