// 生成 1024×1024 的应用图标 PNG。用法：swift make-icon.swift <输出路径>
import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("用法：swift make-icon.swift <输出路径>\n".utf8))
    exit(1)
}
let outputPath = arguments[1]
let size = 1024.0

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let context = NSGraphicsContext.current else {
    exit(1)
}
context.imageInterpolation = .high

// 圆角底
let background = NSBezierPath(
    roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
    xRadius: size * 0.22,
    yRadius: size * 0.22
)
NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
background.fill()
NSColor(calibratedWhite: 0.90, alpha: 1).setStroke()
background.lineWidth = size * 0.006
background.stroke()

// 公文包（与菜单栏图标同一套比例，22 单位画布缩放到 0.62×1024）
let scale = size * 0.62 / 22
let offsetX = (size - 22 * scale) / 2
let offsetY = (size - 22 * scale) / 2

func point(_ x: Double, _ y: Double) -> NSPoint {
    NSPoint(x: offsetX + x * scale, y: offsetY + (22 - y) * scale)
}

let ink = NSColor(calibratedWhite: 0.11, alpha: 1)
let bodyRect = NSRect(
    x: offsetX + 2.6 * scale,
    y: offsetY + (22 - 18.6) * scale,
    width: 16.8 * scale,
    height: 12.2 * scale
)
let body = NSBezierPath(roundedRect: bodyRect, xRadius: 2.6 * scale, yRadius: 2.6 * scale)
body.lineWidth = 1.7 * scale
ink.setFill()
body.fill()

let handle = NSBezierPath()
handle.move(to: point(8.2, 6.4))
handle.line(to: point(8.2, 4.7))
handle.curve(to: point(9.8, 3.1), controlPoint1: point(8.2, 3.8), controlPoint2: point(8.9, 3.1))
handle.line(to: point(12.2, 3.1))
handle.curve(to: point(13.8, 4.7), controlPoint1: point(13.1, 3.1), controlPoint2: point(13.8, 3.8))
handle.line(to: point(13.8, 6.4))
handle.lineWidth = 1.7 * scale
handle.lineCapStyle = .round
ink.setStroke()
handle.stroke()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("无法编码 PNG\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outputPath))
