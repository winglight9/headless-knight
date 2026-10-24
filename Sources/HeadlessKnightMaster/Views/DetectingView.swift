import HKMKit
import SwiftUI

struct DetectingView: View {
    @EnvironmentObject private var state: AppState

    private var title: String {
        if state.blockers.isEmpty {
            return "没有程序在阻止睡眠"
        }
        return "检测到 \(state.blockers.count) 个程序"
    }

    private var subtitle: String {
        state.blockers.isEmpty ? "可以直接开始" : "它们在阻止电脑睡眠"
    }

    var body: some View {
        PopupScaffold(dot: Theme.amber, title: "无头骑士大师") {
            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    NoteText(text: subtitle)
                }
                .padding(.top, 24)

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
                    .padding(.top, 16)

                    if state.blockers.count > 4 {
                        TinyText(text: "另有 \(state.blockers.count - 4) 个程序会一起退出")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 8)
                    }
                }

                if state.displayOnlyCount > 0 {
                    TinyText(text: "另有 \(state.displayOnlyCount) 个只让屏幕不灭，不会退出")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                }

                if state.systemBlockerCount > 0 {
                    TinyText(text: "还有 \(state.systemBlockerCount) 个系统进程会自己退出")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 6)
                }

                HStack(spacing: 6) {
                    Text("\(state.countdownTotal) 秒后自动退出")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryInk)
                    Spacer(minLength: 6)
                    // 等宽数字：倒计时每秒变一次，比例数字会让整行左右抖。
                    Text("\(state.countdown)")
                        .font(.system(size: 17, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(Theme.fieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(.top, 16)

                HStack(spacing: 8) {
                    PopupButton(title: "现在就退出") {
                        state.closeImmediately()
                    }
                    PopupButton(title: "取消", style: .ghost) {
                        state.cancelDetecting()
                    }
                }
                .padding(.top, 12)

                TinyText(text: "退出后可能丢失未保存的内容", alignment: .center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            }
        }
    }

    /// 一行一个程序：左边名字，右边「它挡住了什么」，下面一行「怎么处理」。
    ///
    /// 以前右边只写「已持续 50 小时」——用户看得出来它挡了很久，却不知道挡的是
    /// 睡眠还是屏幕，也不知道该去关哪儿。理由比时长有用得多。
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
