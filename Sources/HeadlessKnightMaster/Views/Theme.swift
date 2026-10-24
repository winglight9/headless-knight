import AppKit
import SwiftUI

enum Theme {
    static let width: CGFloat = 300

    static let surface = Color(nsColor: .windowBackgroundColor)
    static let ink = Color(nsColor: .labelColor)
    static let secondaryInk = Color(nsColor: .secondaryLabelColor)
    static let tertiaryInk = Color(nsColor: .tertiaryLabelColor)
    static let hairline = Color(nsColor: .separatorColor)

    static let green = Color(red: 0.204, green: 0.780, blue: 0.349)
    static let amber = Color(red: 1.000, green: 0.584, blue: 0.000)
    static let red = Color(red: 1.000, green: 0.231, blue: 0.188)
    static let grayDot = Color(nsColor: .tertiaryLabelColor)

    static let warningBackground = dynamic(
        light: NSColor(red: 1.000, green: 0.969, blue: 0.902, alpha: 1),
        dark: NSColor(red: 0.235, green: 0.180, blue: 0.055, alpha: 1)
    )
    static let warningText = dynamic(
        light: NSColor(red: 0.541, green: 0.353, blue: 0.000, alpha: 1),
        dark: NSColor(red: 0.980, green: 0.780, blue: 0.400, alpha: 1)
    )
    static let warningBorder = dynamic(
        light: NSColor(red: 1.000, green: 0.851, blue: 0.627, alpha: 1),
        dark: NSColor(red: 0.400, green: 0.310, blue: 0.100, alpha: 1)
    )
    static let successTint = dynamic(
        light: NSColor(red: 0.910, green: 0.973, blue: 0.925, alpha: 1),
        dark: NSColor(red: 0.110, green: 0.230, blue: 0.140, alpha: 1)
    )
    static let fieldBackground = dynamic(
        light: NSColor(red: 0.961, green: 0.961, blue: 0.969, alpha: 1),
        dark: NSColor(white: 0.160, alpha: 1)
    )
    static let buttonBackground = dynamic(
        light: NSColor(red: 0.114, green: 0.114, blue: 0.122, alpha: 1),
        dark: NSColor(white: 0.940, alpha: 1)
    )
    static let buttonForeground = dynamic(
        light: .white,
        dark: NSColor(white: 0.090, alpha: 1)
    )
    static let ghostBorder = dynamic(
        light: NSColor(white: 0.0, alpha: 0.2),
        dark: NSColor(white: 1.0, alpha: 0.25)
    )
    static let listBorder = dynamic(
        light: NSColor(white: 0.0, alpha: 0.1),
        dark: NSColor(white: 1.0, alpha: 0.14)
    )
    static let rowDivider = dynamic(
        light: NSColor(white: 0.0, alpha: 0.06),
        dark: NSColor(white: 1.0, alpha: 0.10)
    )
    static let batteryBorder = dynamic(
        light: NSColor(red: 0.780, green: 0.780, blue: 0.800, alpha: 1),
        dark: NSColor(white: 0.55, alpha: 1)
    )

    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}
