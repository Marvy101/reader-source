import SwiftUI

enum QuietAccountMark: Int, CaseIterable, Sendable {
    case horizon
    case arch
    case waves
    case nestedSquares
    case crescent
    case leaf

    static func deterministic(for seed: String) -> QuietAccountMark {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in seed.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let index = Int(hash % UInt64(allCases.count))
        return allCases[index]
    }
}

struct QuietAccountMarkView: View {
    let mark: QuietAccountMark
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle()
                .fill(QuietReaderColor.paper)

            Canvas(rendersAsynchronously: false) { context, canvasSize in
                draw(mark, in: &context, size: canvasSize)
            }

            Circle()
                .stroke(QuietReaderColor.markRing, lineWidth: 1)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private func draw(
        _ mark: QuietAccountMark,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        let scale = min(size.width, size.height) / 40
        let offset = CGPoint(
            x: (size.width - 40 * scale) / 2,
            y: (size.height - 40 * scale) / 2
        )
        var transformed = context
        transformed.translateBy(x: offset.x, y: offset.y)
        transformed.scaleBy(x: scale, y: scale)

        let stroke = StrokeStyle(
            lineWidth: 1,
            lineCap: .round,
            lineJoin: .round
        )
        transformed.stroke(
            path(for: mark),
            with: .color(QuietReaderColor.ink),
            style: stroke
        )

        if mark == .crescent {
            transformed.fill(
                Path(ellipseIn: CGRect(x: 26.4, y: 18.4, width: 3.2, height: 3.2)),
                with: .color(QuietReaderColor.ink)
            )
        }
    }

    private func path(for mark: QuietAccountMark) -> Path {
        switch mark {
        case .horizon:
            var path = Path()
            path.addEllipse(in: CGRect(x: 12, y: 9, width: 16, height: 16))
            path.move(to: CGPoint(x: 6, y: 28))
            path.addCurve(
                to: CGPoint(x: 34, y: 28),
                control1: CGPoint(x: 13, y: 22),
                control2: CGPoint(x: 27, y: 22)
            )
            path.move(to: CGPoint(x: 6, y: 32))
            path.addCurve(
                to: CGPoint(x: 34, y: 32),
                control1: CGPoint(x: 13, y: 26),
                control2: CGPoint(x: 27, y: 26)
            )
            return path

        case .arch:
            var path = Path()
            path.move(to: CGPoint(x: 8, y: 30))
            path.addCurve(
                to: CGPoint(x: 20, y: 8),
                control1: CGPoint(x: 8, y: 14),
                control2: CGPoint(x: 20, y: 8)
            )
            path.addCurve(
                to: CGPoint(x: 32, y: 30),
                control1: CGPoint(x: 20, y: 8),
                control2: CGPoint(x: 32, y: 14)
            )
            path.move(to: CGPoint(x: 20, y: 8))
            path.addLine(to: CGPoint(x: 20, y: 32))
            path.move(to: CGPoint(x: 12, y: 22))
            path.addLine(to: CGPoint(x: 28, y: 22))
            return path

        case .waves:
            var path = Path()
            appendWave(to: &path, y: 20)
            appendWave(to: &path, y: 24)
            path.addEllipse(in: CGRect(x: 17.5, y: 8.5, width: 5, height: 5))
            return path

        case .nestedSquares:
            var path = Path()
            path.addRect(CGRect(x: 9, y: 9, width: 22, height: 22))
            let inner = Path(CGRect(x: 14, y: 14, width: 12, height: 12))
                .applying(
                    CGAffineTransform(translationX: 20, y: 20)
                        .rotated(by: 20 * .pi / 180)
                        .translatedBy(x: -20, y: -20)
                )
            path.addPath(inner)
            path.addEllipse(in: CGRect(x: 17, y: 17, width: 6, height: 6))
            return path

        case .crescent:
            var path = Path()
            path.move(to: CGPoint(x: 26, y: 8))
            path.addCurve(
                to: CGPoint(x: 26, y: 32),
                control1: CGPoint(x: 8, y: 4),
                control2: CGPoint(x: 8, y: 36)
            )
            path.addCurve(
                to: CGPoint(x: 26, y: 8),
                control1: CGPoint(x: 13, y: 34),
                control2: CGPoint(x: 13, y: 6)
            )
            path.closeSubpath()
            return path

        case .leaf:
            var path = Path()
            path.move(to: CGPoint(x: 8, y: 20))
            path.addCurve(
                to: CGPoint(x: 32, y: 20),
                control1: CGPoint(x: 14, y: 8),
                control2: CGPoint(x: 26, y: 8)
            )
            path.addCurve(
                to: CGPoint(x: 8, y: 20),
                control1: CGPoint(x: 26, y: 32),
                control2: CGPoint(x: 14, y: 32)
            )
            path.move(to: CGPoint(x: 8, y: 20))
            path.addLine(to: CGPoint(x: 32, y: 20))
            path.move(to: CGPoint(x: 20, y: 12))
            path.addLine(to: CGPoint(x: 20, y: 28))
            return path
        }
    }

    private func appendWave(to path: inout Path, y: CGFloat) {
        path.move(to: CGPoint(x: 2, y: y))
        path.addCurve(
            to: CGPoint(x: 14, y: y),
            control1: CGPoint(x: 8, y: y - 10),
            control2: CGPoint(x: 8, y: y + 10)
        )
        path.addCurve(
            to: CGPoint(x: 26, y: y),
            control1: CGPoint(x: 20, y: y - 10),
            control2: CGPoint(x: 20, y: y + 10)
        )
        path.addCurve(
            to: CGPoint(x: 38, y: y),
            control1: CGPoint(x: 32, y: y - 10),
            control2: CGPoint(x: 32, y: y + 10)
        )
    }
}

private extension Path {
    init(_ rect: CGRect) {
        self.init()
        addRect(rect)
    }
}
