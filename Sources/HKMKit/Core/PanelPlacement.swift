import CoreGraphics

/// 菜单栏面板该摆在哪。
///
/// 抽成纯函数是有原因的：2026-10-25 早上那扇窗口整块掉到了屏幕下面（顶边在
/// y=281，高 466，底边 -185），按钮全在屏幕外，面板又设了 `isMovable = false`，
/// 用户既拖不动也点不到，只能看着一句「还没能睡着」干着急。
///
/// 原来的摆法只做两件事：贴在状态栏按钮下面、横向夹进屏幕；纵向只在「放不下」
/// 的时候把窗口翻到菜单栏**上方**——那个位置整块都在屏幕外，等于把窗口弄丢。
/// 现在统一走一次「算完再夹进可用区域」，任何情况下都不会有像素留在屏幕外。
public enum PanelPlacement {
    /// 面板顶边离菜单栏的距离。
    public static let gap: CGFloat = 6
    /// 离屏幕边缘至少留这么多。
    public static let margin: CGFloat = 8

    /// - Parameters:
    ///   - anchor: 状态栏按钮在屏幕坐标系里的矩形。拿不到就贴在菜单栏下面。
    ///   - content: 面板尺寸。
    ///   - visible: 屏幕的可用区域（`NSScreen.visibleFrame`，已经扣掉菜单栏和程序坞）。
    public static func origin(anchor: CGRect?, content: CGSize, visible: CGRect) -> CGPoint {
        var x: CGFloat
        var y: CGFloat
        if let anchor {
            x = anchor.midX - content.width / 2
            y = anchor.minY - content.height - gap
        } else {
            x = visible.midX - content.width / 2
            y = visible.maxY - content.height - margin
        }

        let minX = visible.minX + margin
        let maxX = max(minX, visible.maxX - content.width - margin)
        x = min(max(minX, x), maxX)

        // 内容比可用高度还高的时候 maxY < minY，这里会退化成「底边贴着下沿」，
        // 顶边被菜单栏盖住一点——总比整块掉到屏幕外面强。
        let minY = visible.minY + margin
        let maxY = visible.maxY - content.height - margin
        y = max(minY, min(y, maxY))

        return CGPoint(x: x, y: y)
    }

    /// 这块矩形是不是完整落在可用区域里（留了边距）。
    public static func isFullyVisible(_ frame: CGRect, in visible: CGRect) -> Bool {
        visible.insetBy(dx: margin, dy: margin).contains(frame)
    }
}
