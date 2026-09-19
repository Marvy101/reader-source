import SwiftUI

enum QuietReaderColor {
    static let paper = Color(
        red: 1,
        green: 1,
        blue: 1
    )
    static let ink = Color(
        red: 29.0 / 255.0,
        green: 29.0 / 255.0,
        blue: 31.0 / 255.0
    )
    static let inkSecondary = Color(
        red: 38.0 / 255.0,
        green: 38.0 / 255.0,
        blue: 42.0 / 255.0
    )
    static let voice = Color(
        red: 138.0 / 255.0,
        green: 138.0 / 255.0,
        blue: 140.0 / 255.0
    )
    static let voiceQuiet = Color(
        red: 168.0 / 255.0,
        green: 168.0 / 255.0,
        blue: 170.0 / 255.0
    )
    static let voiceFaint = Color(
        red: 178.0 / 255.0,
        green: 178.0 / 255.0,
        blue: 180.0 / 255.0
    )
    static let hairline = Color(
        red: 198.0 / 255.0,
        green: 198.0 / 255.0,
        blue: 200.0 / 255.0
    )
    static let progress = Color.black.opacity(0.28)
    static let highlight = Color.black.opacity(0.08)
    static let markRing = Color(
        red: 220.0 / 255.0,
        green: 220.0 / 255.0,
        blue: 220.0 / 255.0
    )
}

extension ReaderHighlightColor {
    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue)
    }
}

enum QuietReaderMetric {
    static let windowHorizontalMargin: CGFloat = 48
    static let menuTop: CGFloat = 88
    static let menuGap: CGFloat = 13
    static let menuSearchExtraGap: CGFloat = 10
    static let menuAccountBottom: CGFloat = 34
    static let contentLeftGutter: CGFloat = 180
    static let contentRightGutter: CGFloat = 60
}

enum QuietUtilityControl {
    static let size: CGFloat = 28
    static let cornerRadius: CGFloat = 10
    static let symbolSize: CGFloat = 16
    static let gap: CGFloat = 8

    static let restingInk = QuietReaderColor.voice
    static let activeInk = QuietReaderColor.ink
    static let selectedBackground = Color.black.opacity(0.05)
    static let selectedHoverBackground = Color.black.opacity(0.10)
    static let hoverBackground = Color.black.opacity(0.04)
}

enum QuietReaderMotion {
    static let screen = Animation.easeInOut(duration: 0.20)
    static let hover = Animation.easeOut(duration: 0.25)
    static let toast = Animation.easeOut(duration: 0.28)
    // Matches the panel motion used by Codex: spring(duration: 0.5, bounce: 0.1).
    static let workspacePanel = Animation.spring(duration: 0.50, bounce: 0.10)
    static let workspaceTab = Animation.spring(duration: 0.28, bounce: 0.06)
    static let libraryReorder = Animation.spring(response: 0.44, dampingFraction: 0.88)
}

enum QuietReaderTypography {
    static func appVoice(size: CGFloat) -> Font {
        .system(size: size, weight: .light).italic()
    }

    static func content(
        size: CGFloat,
        weight: Font.Weight = .regular
    ) -> Font {
        .system(size: size, weight: weight)
    }

    static func reading(
        size: CGFloat,
        serif: Bool,
        weight: Font.Weight = .regular
    ) -> Font {
        serif
            ? .custom("Georgia", size: size).weight(weight)
            : .system(size: size, weight: weight)
    }

    static func tracking(for size: CGFloat) -> CGFloat {
        size * 0.005
    }
}

enum QuietReadingTheme: String, CaseIterable, Codable, Sendable {
    case white
    case cream
    case gray
    case dark

    var background: Color {
        switch self {
        case .white:
            QuietReaderColor.paper
        case .cream:
            Color(
                red: 246.0 / 255.0,
                green: 242.0 / 255.0,
                blue: 232.0 / 255.0
            )
        case .gray:
            Color(
                red: 230.0 / 255.0,
                green: 230.0 / 255.0,
                blue: 230.0 / 255.0
            )
        case .dark:
            Color(
                red: 26.0 / 255.0,
                green: 26.0 / 255.0,
                blue: 28.0 / 255.0
            )
        }
    }

    var ink: Color {
        switch self {
        case .white:
            QuietReaderColor.inkSecondary
        case .cream:
            Color(
                red: 42.0 / 255.0,
                green: 38.0 / 255.0,
                blue: 32.0 / 255.0
            )
        case .gray:
            Color(
                red: 36.0 / 255.0,
                green: 36.0 / 255.0,
                blue: 38.0 / 255.0
            )
        case .dark:
            Color(
                red: 220.0 / 255.0,
                green: 216.0 / 255.0,
                blue: 208.0 / 255.0
            )
        }
    }
}

struct QuietVoiceText: View {
    let text: String
    var size: CGFloat = 13
    var color = QuietReaderColor.voiceQuiet

    var body: some View {
        Text(text.lowercased())
            .font(QuietReaderTypography.appVoice(size: size))
            .tracking(QuietReaderTypography.tracking(for: size))
            .foregroundStyle(color)
    }
}

struct QuietContentText: View {
    let text: String
    var size: CGFloat
    var weight: Font.Weight = .regular
    var color = QuietReaderColor.inkSecondary

    var body: some View {
        Text(text)
            .font(QuietReaderTypography.content(size: size, weight: weight))
            .tracking(QuietReaderTypography.tracking(for: size))
            .foregroundStyle(color)
    }
}

struct QuietActionWord: View {
    let title: String
    var size: CGFloat = 14
    var restingColor = QuietReaderColor.voice
    var activeColor = QuietReaderColor.ink
    var isSelected = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let isActive = isHovered || isSelected

        Button(action: action) {
            VStack(spacing: 2) {
                Text(title.lowercased())
                    .font(QuietReaderTypography.appVoice(size: size))
                    .tracking(QuietReaderTypography.tracking(for: size))
                    .foregroundStyle(isActive ? activeColor : restingColor)

                Rectangle()
                    .fill(isActive ? activeColor : QuietReaderColor.hairline)
                    .frame(height: 1)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .accessibilityLabel(title)
    }
}
