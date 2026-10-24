import SwiftUI

/// 窗口左上角的状态标签。
///
/// 以前那里只有一个 7pt 的彩色圆点，没有文字。用户的反馈很直接：「窗口左上角的
/// 黄色图标一直显示着，不知道是干嘛用的」。颜色自己不会说话，所以现在是一枚
/// 带字的胶囊：在家 / 准备中 / 外出中 / 需要处理。
struct StatusTag: Equatable {
    let text: String
    let color: Color

    static let home = StatusTag(text: "在家", color: Theme.green)
    static let preparing = StatusTag(text: "准备中", color: Theme.amber)
    static let working = StatusTag(text: "处理中", color: Theme.amber)
    static let ready = StatusTag(text: "可以拔线", color: Theme.green)
    static let away = StatusTag(text: "外出中", color: Theme.amber)
    static let attention = StatusTag(text: "需要处理", color: Theme.red)
    static let auditing = StatusTag(text: "统计中", color: Theme.amber)
    static let done = StatusTag(text: "已回来", color: Theme.green)
    static let settings = StatusTag(text: "设置", color: Theme.grayDot)
    static let firstRun = StatusTag(text: "首次设置", color: Theme.amber)
}

struct StatusPill: View {
    let tag: StatusTag

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tag.color)
                .frame(width: 5, height: 5)
            Text(tag.text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.secondaryInk)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(tag.color.opacity(0.16)))
    }
}

/// Common chrome: the status pill, the app name, and one optional trailing action.
struct PopupScaffold<Content: View>: View {
    let status: StatusTag
    let title: String
    var onGear: (() -> Void)?
    var onClose: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                StatusPill(tag: status)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondaryInk)
                Spacer(minLength: 8)
                if let onGear {
                    // 图标还是 14pt，但可点区域撑到 28×28：以前 14×14 的按钮，
                    // 鼠标稍微偏一点就点空，用户要点好几次才进得去。
                    Button(action: onGear) {
                        GearGlyph()
                            .frame(width: 14, height: 14)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("设置")
                }
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.tertiaryInk)
                            .frame(width: 14, height: 14)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 15)
            .padding(.top, 13)

            content()
                .padding(.horizontal, 15)
                .padding(.bottom, 15)
        }
        .frame(width: Theme.width)
        .background(Theme.surface)
    }
}

struct GearGlyph: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.tertiaryInk, lineWidth: 1.2)
                .frame(width: 4.8, height: 4.8)
            Circle()
                .stroke(Theme.tertiaryInk, style: StrokeStyle(lineWidth: 1.2, dash: [1.5, 2.6]))
                .frame(width: 10, height: 10)
        }
    }
}

struct PopupButton: View {
    enum Style {
        case primary
        case ghost
        case green
    }

    let title: String
    var style: Style = .primary
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(background)
                .foregroundStyle(foreground)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(border)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }

    private var background: Color {
        switch style {
        case .primary: return Theme.buttonBackground
        case .ghost: return .clear
        case .green: return Theme.green
        }
    }

    private var foreground: Color {
        switch style {
        case .primary: return Theme.buttonForeground
        case .ghost: return Theme.ink
        case .green: return .white
        }
    }

    @ViewBuilder
    private var border: some View {
        if style == .ghost {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Theme.ghostBorder, lineWidth: 0.5)
        }
    }
}

struct TinyText: View {
    let text: String
    var alignment: TextAlignment = .leading

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(Theme.tertiaryInk)
            .multilineTextAlignment(alignment)
    }
}

struct NoteText: View {
    let text: String
    var alignment: TextAlignment = .leading
    var lineSpacing: CGFloat = 2

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondaryInk)
            .multilineTextAlignment(alignment)
            .lineSpacing(lineSpacing)
    }
}

struct HairlineDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.rowDivider)
            .frame(height: 0.5)
    }
}

struct CheckRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("✓")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.green)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryInk)
            Spacer(minLength: 0)
        }
    }
}

struct WarningBox<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.warningBackground)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Theme.warningBorder, lineWidth: 0.5)
            )
    }
}

struct BatteryGlyph: View {
    let ratio: Double

    var body: some View {
        HStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .stroke(Theme.batteryBorder, lineWidth: 0.5)
                .frame(width: 19, height: 10)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(fillColor)
                        .frame(width: max(1, 16 * min(1, max(0, ratio))), height: 7)
                        .padding(.leading, 1.5)
                }
            RoundedRectangle(cornerRadius: 0.8, style: .continuous)
                .fill(Theme.batteryBorder)
                .frame(width: 1.6, height: 4)
        }
    }

    private var fillColor: Color {
        if ratio <= 0.10 { return Theme.red }
        if ratio <= 0.20 { return Theme.amber }
        return Theme.green
    }
}

struct SuccessBadge: View {
    var size: CGFloat = 50

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.successTint)
                .frame(width: size, height: size)
            Circle()
                .stroke(Theme.green, lineWidth: 1)
                .frame(width: size, height: size)
            Path { path in
                let scale = size / 52
                path.move(to: CGPoint(x: 15 * scale, y: 26.5 * scale))
                path.addLine(to: CGPoint(x: 22.5 * scale, y: 34 * scale))
                path.addLine(to: CGPoint(x: 37 * scale, y: 19.5 * scale))
            }
            .stroke(Theme.green, style: StrokeStyle(lineWidth: size * 0.058, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }
}

struct SuitcaseGlyph: View {
    var size: CGFloat = 38
    var filled: Bool = false

    var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / 22
            let bodyRect = CGRect(x: 2.6 * scale, y: 6.4 * scale, width: 16.8 * scale, height: 12.2 * scale)
            let bodyPath = Path(roundedRect: bodyRect, cornerRadius: 2.6 * scale)
            if filled {
                context.fill(bodyPath, with: .color(Theme.ink))
            }
            context.stroke(bodyPath, with: .color(Theme.ink), lineWidth: 1.7 * scale)

            var handle = Path()
            handle.move(to: CGPoint(x: 8.2 * scale, y: 6.4 * scale))
            handle.addLine(to: CGPoint(x: 8.2 * scale, y: 4.7 * scale))
            handle.addCurve(
                to: CGPoint(x: 9.8 * scale, y: 3.1 * scale),
                control1: CGPoint(x: 8.2 * scale, y: 3.8 * scale),
                control2: CGPoint(x: 8.9 * scale, y: 3.1 * scale)
            )
            handle.addLine(to: CGPoint(x: 12.2 * scale, y: 3.1 * scale))
            handle.addCurve(
                to: CGPoint(x: 13.8 * scale, y: 4.7 * scale),
                control1: CGPoint(x: 13.1 * scale, y: 3.1 * scale),
                control2: CGPoint(x: 13.8 * scale, y: 3.8 * scale)
            )
            handle.addLine(to: CGPoint(x: 13.8 * scale, y: 6.4 * scale))
            context.stroke(
                handle,
                with: .color(Theme.ink),
                style: StrokeStyle(lineWidth: 1.7 * scale, lineCap: .round)
            )
        }
        .frame(width: size, height: size)
    }
}

struct LockGlyph: View {
    var size: CGFloat = 36

    var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / 22
            let bodyRect = CGRect(x: 4.5 * scale, y: 9.5 * scale, width: 13 * scale, height: 9.5 * scale)
            let bodyPath = Path(roundedRect: bodyRect, cornerRadius: 2.2 * scale)
            context.stroke(bodyPath, with: .color(Theme.ink), lineWidth: 1.6 * scale)

            var shackle = Path()
            shackle.move(to: CGPoint(x: 7.8 * scale, y: 9.5 * scale))
            shackle.addLine(to: CGPoint(x: 7.8 * scale, y: 7.2 * scale))
            shackle.addCurve(
                to: CGPoint(x: 11 * scale, y: 4.1 * scale),
                control1: CGPoint(x: 7.8 * scale, y: 5.5 * scale),
                control2: CGPoint(x: 9.2 * scale, y: 4.1 * scale)
            )
            shackle.addCurve(
                to: CGPoint(x: 14.2 * scale, y: 7.2 * scale),
                control1: CGPoint(x: 12.8 * scale, y: 4.1 * scale),
                control2: CGPoint(x: 14.2 * scale, y: 5.5 * scale)
            )
            shackle.addLine(to: CGPoint(x: 14.2 * scale, y: 9.5 * scale))
            context.stroke(
                shackle,
                with: .color(Theme.ink),
                style: StrokeStyle(lineWidth: 1.6 * scale, lineCap: .round)
            )
        }
        .frame(width: size, height: size)
    }
}

struct CapsuleToggle: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Capsule()
                .fill(isOn ? Theme.green : Theme.fieldBackground)
                .frame(width: 30, height: 17)
                .overlay(
                    Circle()
                        .fill(Color.white)
                        .frame(width: 13, height: 13)
                        .padding(2),
                    alignment: isOn ? .trailing : .leading
                )
        }
        .buttonStyle(.plain)
    }
}

struct DetailDisclosure<Content: View>: View {
    let isExpanded: Bool
    let onToggle: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                Text(isExpanded ? "收起详情" : "查看详情")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryInk)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
                .padding(10)
                .background(Theme.fieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.top, 8)
            }
        }
    }
}
