import HKMKit
import SwiftUI

/// 「正在自动关闭」这一页。
///
/// 以前这段流程是隐形的：窗口被系统收走，用户只看到鼠标卡了一下，然后突然
/// 出现在「可以拔掉显示器了」。现在这一页一直留在屏幕上，一条一条往下打勾，
/// 用户知道它还在干活、干到哪一步了。
struct ClosingView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        PopupScaffold(status: .working, title: L("无头骑士大师")) {
            VStack(spacing: 0) {
                VStack(spacing: 5) {
                    Text(L("正在自动关闭"))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    NoteText(text: L("一个一个来，关完自动进下一步"), alignment: .center)
                }
                .padding(.top, 22)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(state.completedActions, id: \.self) { action in
                        CheckRow(text: action)
                    }
                    if let step = state.closingStep {
                        HStack(spacing: 7) {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.55)
                                .frame(width: 12, height: 12)
                            Text(step)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.ink)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 18)

                TinyText(text: L("这一步不用你管，窗口会一直留在屏幕上"), alignment: .center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
            }
        }
    }
}
