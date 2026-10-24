import AppKit

/// Draws the three menu bar states from the same geometry as `preview/ui.html`
/// (22×22 viewBox, rendered at 18×18).
public enum MenuBarIcon {
    public static let canvasSize = NSSize(width: 18, height: 18)
    private static let viewBox: CGFloat = 22

    public static func image(for state: AppState.IconState, appearance: NSAppearance) -> NSImage {
        switch state {
        case .home:
            return make(filled: false, dot: nil, stroke: .black, isTemplate: true)
        case .away:
            return make(filled: true, dot: nil, stroke: .black, isTemplate: true)
        case .alert:
            let ink = inkColor(for: appearance)
            return make(filled: true, dot: NSColor.systemRed, stroke: ink, isTemplate: false)
        }
    }

    /// Template images are tinted by the system; the alert state is not a
    /// template, so the suitcase has to match the current appearance itself.
    public static func inkColor(for appearance: NSAppearance) -> NSColor {
        let match = appearance.bestMatch(from: [.aqua, .darkAqua])
        if match == .darkAqua {
            return NSColor(white: 0.92, alpha: 1)
        }
        return NSColor(white: 0.14, alpha: 1)
    }

    private static func make(filled: Bool, dot: NSColor?, stroke: NSColor, isTemplate: Bool) -> NSImage {
        let image = NSImage(size: canvasSize, flipped: true) { rect in
            let scale = rect.width / viewBox

            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: x * scale, y: y * scale)
            }

            let body = NSBezierPath(
                roundedRect: NSRect(
                    x: 2.6 * scale,
                    y: 6.4 * scale,
                    width: 16.8 * scale,
                    height: 12.2 * scale
                ),
                xRadius: 2.6 * scale,
                yRadius: 2.6 * scale
            )
            body.lineWidth = 1.7 * scale
            if filled {
                stroke.setFill()
                body.fill()
            }
            stroke.setStroke()
            body.stroke()

            let handle = NSBezierPath()
            handle.move(to: point(8.2, 6.4))
            handle.line(to: point(8.2, 4.7))
            handle.curve(
                to: point(9.8, 3.1),
                controlPoint1: point(8.2, 3.8),
                controlPoint2: point(8.9, 3.1)
            )
            handle.line(to: point(12.2, 3.1))
            handle.curve(
                to: point(13.8, 4.7),
                controlPoint1: point(13.1, 3.1),
                controlPoint2: point(13.8, 3.8)
            )
            handle.line(to: point(13.8, 6.4))
            handle.lineWidth = 1.7 * scale
            handle.lineCapStyle = .round
            stroke.setStroke()
            handle.stroke()

            if let dot {
                let radius = 3.4 * scale
                let center = point(18.6, 4.2)
                let dotRect = NSRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                dot.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            }
            return true
        }
        image.isTemplate = isTemplate
        return image
    }
}
