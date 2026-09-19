import SwiftUI

enum ReaderColors {
    static let canvas = Color("ReaderCanvas")
    static let paper = Color("ReaderPaper")
    static let ink = Color("ReaderInk")
    static let moss = Color(red: 0.22, green: 0.34, blue: 0.26)
    static let voiceQuiet = Color(
        red: 168 / 255,
        green: 168 / 255,
        blue: 170 / 255
    )
    static let hairline = Color.primary.opacity(0.10)

    static func navigationRowBackground(isSelected: Bool, isHovered: Bool) -> Color {
        switch (isSelected, isHovered) {
        case (true, true):
            Color.primary.opacity(0.11)
        case (true, false):
            Color.primary.opacity(0.08)
        case (false, true):
            Color.primary.opacity(0.045)
        case (false, false):
            Color.clear
        }
    }
}
