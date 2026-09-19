// Run from the repository root: swift Scripts/generate_context_icons.swift
// Original Reader geometry. Codex's pane controls establish the optical metrics:
// a 20-point canvas, ~1.33-point ink, soft corners and rounded terminals.
// Expand strokes to filled SVG paths so asset-catalog and menu rendering agree.
import CoreGraphics
import Foundation

let ink: CGFloat = 1.33
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Reader/Resources/Assets.xcassets")

func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

func path(_ draw: (CGMutablePath) -> Void) -> CGPath {
    let result = CGMutablePath()
    draw(result)
    return result
}

func outline(_ path: CGPath) -> CGPath {
    path.copy(strokingWithWidth: ink, lineCap: .round, lineJoin: .round, miterLimit: 2)
}

func svgPath(_ path: CGPath) -> String {
    func number(_ n: CGFloat) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), Double(n))
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }
    func pair(_ p: CGPoint) -> String { "\(number(p.x)) \(number(p.y))" }
    var commands: [String] = []
    path.applyWithBlock { pointer in
        let e = pointer.pointee
        switch e.type {
        case .moveToPoint: commands.append("M\(pair(e.points[0]))")
        case .addLineToPoint: commands.append("L\(pair(e.points[0]))")
        case .addQuadCurveToPoint: commands.append("Q\(pair(e.points[0])) \(pair(e.points[1]))")
        case .addCurveToPoint: commands.append("C\(pair(e.points[0])) \(pair(e.points[1])) \(pair(e.points[2]))")
        case .closeSubpath: commands.append("Z")
        @unknown default: fatalError("Unsupported path element")
        }
    }
    return commands.joined()
}

let selection = path { p in
    // Each corner has the pane family's gentle transition into a straight edge.
    p.move(to: point(7.2, 3.2)); p.addLine(to: point(6.1, 3.2))
    p.addCurve(to: point(2.8, 6.5), control1: point(3.65, 3.2), control2: point(2.8, 4.05))
    p.addLine(to: point(2.8, 7.5))
    p.move(to: point(12.8, 3.2)); p.addLine(to: point(13.9, 3.2))
    p.addCurve(to: point(17.2, 6.5), control1: point(16.35, 3.2), control2: point(17.2, 4.05))
    p.addLine(to: point(17.2, 7.5))
    p.move(to: point(17.2, 12.5)); p.addLine(to: point(17.2, 13.5))
    p.addCurve(to: point(13.9, 16.8), control1: point(17.2, 15.95), control2: point(16.35, 16.8))
    p.addLine(to: point(12.8, 16.8))
    p.move(to: point(7.2, 16.8)); p.addLine(to: point(6.1, 16.8))
    p.addCurve(to: point(2.8, 13.5), control1: point(3.65, 16.8), control2: point(2.8, 15.95))
    p.addLine(to: point(2.8, 12.5))
}

let page = path { p in
    p.move(to: point(11.5, 3))
    // The outside remains a complete page. The curl is a separate interior seam.
    p.addCurve(to: point(17, 8.5), control1: point(14.538, 3), control2: point(17, 5.462))
    p.addLine(to: point(17, 13.7))
    p.addCurve(to: point(13.7, 17), control1: point(17, 16.15), control2: point(16.15, 17))
    p.addLine(to: point(6.3, 17))
    p.addCurve(to: point(3, 13.7), control1: point(3.85, 17), control2: point(3, 16.15))
    p.addLine(to: point(3, 6.3))
    p.addCurve(to: point(6.3, 3), control1: point(3, 3.85), control2: point(3.85, 3))
    p.closeSubpath()
    p.move(to: point(11.5, 3))
    p.addCurve(to: point(17, 8.5), control1: point(11.5, 7.1), control2: point(12.9, 8.5))
}

let history = path { p in
    p.move(to: point(3.2, 3.4))
    p.addCurve(to: point(1.7, 6.3), control1: point(2.1, 3.65), control2: point(1.7, 4.65))
    p.addLine(to: point(1.7, 13.7))
    p.addCurve(to: point(3.2, 16.6), control1: point(1.7, 15.35), control2: point(2.1, 16.35))
    p.move(to: point(8.3, 3)); p.addLine(to: point(14.2, 3))
    p.addCurve(to: point(17.5, 6.3), control1: point(16.65, 3), control2: point(17.5, 3.85))
    p.addLine(to: point(17.5, 13.7))
    p.addCurve(to: point(14.2, 17), control1: point(17.5, 16.15), control2: point(16.65, 17))
    p.addLine(to: point(8.3, 17))
    p.addCurve(to: point(5, 13.7), control1: point(5.85, 17), control2: point(5, 16.15))
    p.addLine(to: point(5, 6.3))
    p.addCurve(to: point(8.3, 3), control1: point(5, 3.85), control2: point(5.85, 3))
    p.closeSubpath()
}

let book = path { p in
    p.move(to: point(10, 6.1))
    p.addCurve(to: point(6.8, 3.2), control1: point(9.7, 4.05), control2: point(8.65, 3.2))
    p.addLine(to: point(5.6, 3.2))
    p.addCurve(to: point(2.4, 6.4), control1: point(3.25, 3.2), control2: point(2.4, 4.05))
    p.addLine(to: point(2.4, 13.6))
    p.addCurve(to: point(5.6, 16.8), control1: point(2.4, 15.95), control2: point(3.25, 16.8))
    p.addLine(to: point(14.4, 16.8))
    p.addCurve(to: point(17.6, 13.6), control1: point(16.75, 16.8), control2: point(17.6, 15.95))
    p.addLine(to: point(17.6, 6.4))
    p.addCurve(to: point(14.4, 3.2), control1: point(17.6, 4.05), control2: point(16.75, 3.2))
    p.addLine(to: point(13.2, 3.2))
    p.addCurve(to: point(10, 6.1), control1: point(11.35, 3.2), control2: point(10.3, 4.05))
    p.closeSubpath()
    p.move(to: point(10, 6.1)); p.addLine(to: point(10, 16.8))
}

let reveal = path { p in
    p.move(to: point(1.8, 10))
    p.addCurve(to: point(10, 4.6), control1: point(3.65, 6.5), control2: point(6.65, 4.6))
    p.addCurve(to: point(18.2, 10), control1: point(13.35, 4.6), control2: point(16.35, 6.5))
    p.addCurve(to: point(10, 15.4), control1: point(16.35, 13.5), control2: point(13.35, 15.4))
    p.addCurve(to: point(1.8, 10), control1: point(6.65, 15.4), control2: point(3.65, 13.5))
    p.closeSubpath()
    p.move(to: point(10, 7.9)); p.addLine(to: point(10, 12.1))
}

for (asset, filename, geometry) in [
    ("Selection", "selection", selection), ("Page", "page", page),
    ("UpToHere", "up-to-here", history), ("WholeBook", "whole-book", book),
    ("Reveal", "reveal", reveal)
] {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 20 20" fill="none">
      <path d="\(svgPath(outline(geometry)))" fill="currentColor"/>
    </svg>

    """
    try svg.write(to: root.appendingPathComponent("ReaderContext\(asset).imageset/context-\(filename).svg"), atomically: true, encoding: .utf8)
}
