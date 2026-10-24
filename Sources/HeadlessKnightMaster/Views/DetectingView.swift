import HKMKit
import SwiftUI

/// 检测到「有人在挡睡眠」之后的那一页。
///
/// 以前这里是一个 20 秒倒计时，数完就自己动手。用户的原话是「20 秒还是有点
/// 吓人」——一个会自己关掉你程序的界面，等多久都吓人，而且数着数还没看完就得
/// 做决定。现在没有倒计时了，只剩一个明确的动作：一键全关。
///
/// 用户也可以自己动手关。他不需要回来点任何「我关好了」——关没关掉机器自己
/// 查得出来，清单会实时变短，全空了自动往下走。
struct DetectingView: View {
    @EnvironmentObject private var state: AppState

    private var title: String {
        state.blockers.isEmpty
            ? "没有程序在阻止睡眠"
            : "\(state.blockers.count) 个程序在挡睡眠"
    }

    var body: some View {
        PopupScaffold(status: .preparing, title: "无头骑士大师") {
            VStack(spacing: 0) {
                VStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    if let note = sideNote {
                        NoteText(text: note, alignment: .center)
                    }
                }
                .padding(.top, 22)

                if !state.blockers.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(state.blockers.prefix(4).enumerated()), id: \.element.id) { index, blocker in
                            if index > 0 {
                                Rectangle()
                                    .fill(Theme.rowDivider)
                                    .frame(height: 0.5)
                            }
                            blockerRow(blocker)
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Theme.listBorder, lineWidth: 0.5)
                    )
                    .padding(.top, 15)

                    if state.blockers.count > 4 {
                        NoteText(text: "另有 \(state.blockers.count - 4) 个会一起关掉", alignment: .center)
                            .padding(.top, 8)
                    }
                }

                chooseSection

                Button(action: { state.cancelDetecting() }) {
                    Text("取消，先不出门")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryInk)
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
            }
        }
    }

    /// 标题下面那一行。只讲「清单为什么只有这几个」，不重复标题说过的意思。
    private var sideNote: String? {
        var parts: [String] = []
        if state.displayOnlyCount > 0 {
            parts.append("另有 \(state.displayOnlyCount) 个只让屏幕不灭，不会动它们")
        }
        if state.systemBlockerCount > 0 {
            parts.append("\(state.systemBlockerCount) 个系统进程会自己退出")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "；")
    }

    private var chooseSection: some View {
        VStack(spacing: 9) {
            Text("手动关掉它们，或者点下面一键关闭")
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
            PopupButton(title: "一键全部关闭", isEnabled: !state.isBusy) {
                state.closeImmediately()
            }
            Text("会直接退出这些程序，没保存的会丢")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 16)
    }

    /// 一行一个程序：左边名字，右边「它挡住了什么」，下面一行「怎么处理」。
    private func blockerRow(_ blocker: SleepBlocker) -> some View {
        let explanation = blocker.explanation
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor(for: blocker))
                    .frame(width: 6, height: 6)
                Text(blocker.processName)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(explanation.reason)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryInk)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            if let suggestion = explanation.suggestion {
                Text(suggestion)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryInk)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 12)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
    }

    private func dotColor(for blocker: SleepBlocker) -> Color {
        if blocker.kind == .displayOnly {
            return Theme.grayDot
        }
        if blocker.isAudioAssertion || blocker.durationSeconds >= 3600 {
            return Theme.red
        }
        return Theme.grayDot
    }
}

/// 正在扫描断言。`pmset -g assertions` 加每个进程一次 `ps`，几百毫秒，
/// 这段时间要有个看得见的东西，否则用户以为按钮没反应。
struct ScanningView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        PopupScaffold(status: .working, title: "无头骑士大师") {
            VStack(spacing: 11) {
                ProgressView()
                    .controlSize(.small)
                NoteText(text: "正在检查谁在挡着睡眠…", alignment: .center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
            .padding(.bottom, 40)
        }
    }
}
