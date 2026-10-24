import SwiftUI

struct OnboardingOneView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        PopupScaffold(dot: Theme.grayDot, title: "无头骑士大师") {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    SuitcaseGlyph(size: 38)
                        .padding(.top, 18)
                    Text("无头骑士大师")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .padding(.top, 12)
                    NoteText(text: "出门前点一下\n它替你做完这些", alignment: .center, lineSpacing: 3)
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 7) {
                    Text("· 关掉阻止睡眠的程序")
                    Text("· 关闭蓝牙")
                    Text("· 记录被唤醒的痕迹")
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
                .padding(.top, 16)

                PopupButton(title: "继续") {
                    state.advanceOnboarding()
                }
                .padding(.top, 20)

                TinyText(text: "1 / 3", alignment: .center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
            }
        }
    }
}

struct OnboardingTwoView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        PopupScaffold(dot: Theme.grayDot, title: "无头骑士大师") {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    LockGlyph(size: 36)
                        .padding(.top, 20)
                    Text("需要一次授权")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .padding(.top, 12)
                    NoteText(
                        text: "修改系统睡眠设置\n需要管理员权限。\n\n授权后不再重复询问。",
                        alignment: .center,
                        lineSpacing: 3
                    )
                    .padding(.top, 12)
                }
                .frame(maxWidth: .infinity)

                if state.showAuthorizationReason {
                    WarningBox {
                        Text("睡眠设置、定时唤醒和共享服务都在系统域里，只有 root 能改。装一个最小的后台服务，App 通过它执行这些命令，你的密码只在安装时输入一次。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.warningText)
                            .lineSpacing(3)
                    }
                    .padding(.top, 14)
                }

                PopupButton(title: state.helperInstalled ? "已授权" : "授权并安装", isEnabled: !state.isBusy) {
                    state.installHelper()
                }
                .padding(.top, 20)

                Button(action: { state.toggleAuthorizationReason() }) {
                    Text(state.showAuthorizationReason ? "收起 ›" : "为什么要这个？ ›")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryInk)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
            }
        }
    }
}

struct OnboardingThreeView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        PopupScaffold(dot: Theme.grayDot, title: "无头骑士大师") {
            VStack(spacing: 0) {
                Text("出门时会做这些")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 16)

                VStack(alignment: .leading, spacing: 9) {
                    CheckRow(text: "关闭阻止睡眠的程序")
                    CheckRow(text: "关闭蓝牙")
                    CheckRow(text: "关闭网络唤醒")
                    CheckRow(text: "拔线后自动睡眠")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
                .padding(.top, 16)

                WarningBox {
                    Text("关闭程序可能丢失未保存的内容")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.warningText)
                }
                .padding(.top, 14)

                PopupButton(title: "开始使用") {
                    state.finishOnboarding()
                }
                .padding(.top, 16)
            }
        }
    }
}
