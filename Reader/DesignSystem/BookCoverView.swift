import SwiftUI

struct BookCoverView: View {
    let book: Book
    var compact = false
    var castsShadow = true

    var body: some View {
        GeometryReader { geometry in
            Group {
                if
                    let coverURL = book.publication?.coverURL,
                    let image = NSImage(contentsOf: coverURL)
                {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .background(palette.background)
                } else {
                    generatedCover
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 2,
                bottomLeadingRadius: 2,
                bottomTrailingRadius: compact ? 5 : 7,
                topTrailingRadius: compact ? 5 : 7,
                style: .continuous
            )
        )
        .shadow(color: .black.opacity(castsShadow ? 0.12 : 0), radius: compact ? 5 : 13, y: compact ? 3 : 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(book.title) by \(book.author)")
    }

    private var generatedCover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: compact ? 8 : 12, style: .continuous)
                .fill(palette.background)
            coverOrnament

            VStack(alignment: .leading, spacing: compact ? 5 : 8) {
                Text(book.title.uppercased())
                    .font(
                        .system(
                            size: compact ? 10 : 14,
                            weight: .semibold,
                            design: .serif
                        )
                    )
                    .tracking(compact ? 0.5 : 1.1)
                    .foregroundStyle(palette.foreground)
                    .lineLimit(3)

                Spacer()

                Rectangle()
                    .fill(palette.foreground.opacity(0.55))
                    .frame(width: compact ? 18 : 28, height: 1)

                Text(book.author)
                    .font(.system(size: compact ? 7 : 10, weight: .medium))
                    .tracking(0.5)
                    .foregroundStyle(palette.foreground.opacity(0.78))
                    .lineLimit(1)
            }
            .padding(compact ? 10 : 17)
        }
    }

    @ViewBuilder
    private var coverOrnament: some View {
        switch book.coverStyle {
        case .forest:
            Circle()
                .stroke(palette.foreground.opacity(0.22), lineWidth: compact ? 8 : 14)
                .padding(compact ? 18 : 30)
        case .night:
            VStack(spacing: compact ? 5 : 9) {
                ForEach(0..<5, id: \.self) { index in
                    Capsule()
                        .fill(palette.foreground.opacity(0.08 + Double(index) * 0.035))
                        .frame(height: compact ? 2 : 3)
                        .padding(.horizontal, CGFloat(index * 7 + 14))
                }
            }
        case .parchment:
            RoundedRectangle(cornerRadius: compact ? 22 : 38, style: .continuous)
                .stroke(palette.foreground.opacity(0.18), lineWidth: 1)
                .padding(compact ? 15 : 27)
        case .clay:
            Circle()
                .fill(palette.foreground.opacity(0.12))
                .frame(width: compact ? 64 : 108)
                .offset(x: compact ? 22 : 38, y: compact ? -38 : -64)
        case .sea:
            VStack(spacing: compact ? 7 : 12) {
                ForEach(0..<4, id: \.self) { _ in
                    Capsule()
                        .stroke(palette.foreground.opacity(0.17), lineWidth: 1)
                        .frame(height: compact ? 12 : 20)
                        .padding(.horizontal, compact ? 8 : 14)
                }
            }
            .rotationEffect(.degrees(-8))
        }
    }

    private var palette: (background: Color, foreground: Color) {
        switch book.coverStyle {
        case .forest:
            (Color(red: 0.16, green: 0.27, blue: 0.21), Color(red: 0.91, green: 0.88, blue: 0.72))
        case .night:
            (Color(red: 0.09, green: 0.11, blue: 0.16), Color(red: 0.84, green: 0.80, blue: 0.67))
        case .parchment:
            (Color(red: 0.86, green: 0.80, blue: 0.67), Color(red: 0.23, green: 0.20, blue: 0.16))
        case .clay:
            (Color(red: 0.57, green: 0.28, blue: 0.20), Color(red: 0.94, green: 0.83, blue: 0.68))
        case .sea:
            (Color(red: 0.20, green: 0.37, blue: 0.43), Color(red: 0.90, green: 0.88, blue: 0.77))
        }
    }
}
