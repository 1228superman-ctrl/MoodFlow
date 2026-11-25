#if os(watchOS)
import SwiftUI

enum MoodTheme: String, CaseIterable, Identifiable {
    case sunrise, ink, contour

    var id: String { rawValue }
    var title: String {
        switch self {
        case .sunrise: "日出渐变"
        case .ink: "水墨留白"
        case .contour: "户外等高线"
        }
    }
    var widgetKind: String { MoodFaceSnapshot.kind + "." + rawValue }
    var foreground: Color { self == .contour ? Color(red: 1, green: 0.96, blue: 0.85) : Color(white: 0.13) }

    func colors(for mood: MoodAppearance) -> (base: Color, middle: Color, accent: Color) {
        switch (self, mood) {
        case (.sunrise, .bright): (Color(hue: 0.10, saturation: 0.32, brightness: 1), .orange, .yellow)
        case (.sunrise, .tense): (Color(hue: 0.04, saturation: 0.26, brightness: 1), Color(hue: 0.02, saturation: 0.68, brightness: 0.82), Color(hue: 0.04, saturation: 0.64, brightness: 0.97))
        case (.sunrise, .subdued): (Color(hue: 0.79, saturation: 0.13, brightness: 0.96), Color(hue: 0.80, saturation: 0.32, brightness: 0.68), Color(hue: 0.86, saturation: 0.22, brightness: 0.84))
        case (.sunrise, .calm): (Color(hue: 0.09, saturation: 0.23, brightness: 1), Color(hue: 0.04, saturation: 0.60, brightness: 0.83), Color(hue: 0.11, saturation: 0.60, brightness: 0.99))
        case (.sunrise, .neutral): (Color(hue: 0.09, saturation: 0.12, brightness: 0.96), Color(hue: 0.08, saturation: 0.35, brightness: 0.75), Color(hue: 0.09, saturation: 0.28, brightness: 0.94))
        case (.ink, let mood):
            (Color(red: 0.96, green: 0.93, blue: 0.86), Color(white: 0.15),
             Color(hue: mood == .calm ? 0.02 : accentHue(for: mood), saturation: 0.63, brightness: 0.62))
        case (.contour, let mood):
            (Color(hue: accentHue(for: mood), saturation: 0.69, brightness: 0.16),
             Color(hue: accentHue(for: mood), saturation: 0.44, brightness: 0.65),
             Color(hue: accentHue(for: mood) + 0.15, saturation: 0.49, brightness: 0.95))
        }
    }

    private func accentHue(for mood: MoodAppearance) -> Double {
        switch mood {
        case .neutral: 0.53
        case .calm: 0.47
        case .bright: 0.35
        case .tense: 0.02
        case .subdued: 0.68
        }
    }
}

struct MoodArtwork: View {
    let theme: MoodTheme
    let mood: MoodAppearance
    var compact = false

    var body: some View {
        Canvas { context, size in
            let colors = theme.colors(for: mood)
            let width = size.width
            let height = size.height
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * width, y: y * height) }

            if !compact { context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(colors.base)) }
            switch theme {
            case .sunrise:
                let layout: (sunX: CGFloat, sunY: CGFloat, sunSize: CGFloat, leftRidge: CGFloat, rightRidge: CGFloat, crest: CGFloat) = switch mood {
                case .neutral: (0.84, 0.37, 0.35, 0.52, 0.62, 0.44)
                case .calm: (0.77, 0.36, 0.52, 0.48, 0.59, 0.41)
                case .bright: (0.76, 0.25, 0.68, 0.61, 0.48, 0.51)
                case .tense: (0.92, 0.48, 0.47, 0.36, 0.66, 0.20)
                case .subdued: (0.64, 0.54, 0.32, 0.64, 0.55, 0.59)
                }
                let diameter = min(width, height) * layout.sunSize
                let center = point(layout.sunX, layout.sunY)
                let sun = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
                context.fill(Path(ellipseIn: sun), with: .linearGradient(Gradient(colors: [colors.accent, colors.middle]),
                    startPoint: CGPoint(x: sun.midX, y: sun.minY), endPoint: CGPoint(x: sun.midX, y: sun.maxY)))
                let hills = Path { path in
                    path.move(to: point(0, layout.leftRidge))
                    path.addQuadCurve(to: point(1, layout.rightRidge), control: point(0.44, layout.crest))
                    path.addLine(to: point(1, 0.74))
                    path.addQuadCurve(to: point(0, 0.69), control: point(0.57, 0.51))
                    path.closeSubpath()
                }
                context.fill(hills, with: .color(colors.middle))
                let slope = Path { path in
                    path.move(to: point(0.22, 0.67))
                    path.addQuadCurve(to: point(1, 0.50), control: point(0.68, 0.49))
                    path.addLine(to: point(1, 0.78))
                    path.addQuadCurve(to: point(0.22, 0.67), control: point(0.61, 0.64))
                    path.closeSubpath()
                }
                context.fill(slope, with: .color(colors.accent.opacity(0.82)))
            case .ink:
                let wash: (reach: CGFloat, bend: CGFloat, fall: CGFloat, strokes: Int, opacity: Double) = switch mood {
                case .neutral: (0.48, 0.23, 0.63, 2, 0.28)
                case .calm: (0.70, 0.49, 0.80, 4, 0.42)
                case .bright: (0.98, 0.34, 0.58, 3, 0.59)
                case .tense: (0.98, 0.72, 0.86, 5, 0.86)
                case .subdued: (0.44, 0.26, 1.14, 3, 0.60)
                }
                for index in 0..<wash.strokes {
                    let shift = CGFloat(index) * 0.065
                    let brush = Path { path in
                        path.move(to: point(-0.10, -0.04))
                        path.addLine(to: point(wash.reach - shift, -0.03))
                        path.addQuadCurve(to: point(0.29 + shift, 0.38), control: point(0.02, 0.30 + shift))
                        path.addQuadCurve(to: point(0.04 + shift, wash.fall), control: point(wash.bend - shift, 0.57))
                        path.addLine(to: point(-0.13, wash.fall + 0.10))
                        path.closeSubpath()
                    }
                    context.fill(brush, with: .linearGradient(Gradient(colors: [colors.middle.opacity(wash.opacity), .clear]),
                        startPoint: point(0, 0), endPoint: point(0.77, 0.72)))
                }
                let stamp = width * (compact ? 0.13 : 0.034)
                context.fill(Path(CGRect(x: width * 0.79, y: height * 0.55, width: stamp, height: stamp)), with: .color(colors.accent))
            case .contour:
                let terrain: (centerX: CGFloat, centerY: CGFloat, spacing: CGFloat, ripple: Double, rings: Int) = switch mood {
                case .neutral: (0.84, 0.42, 0.065, 0.10, 8)
                case .calm: (0.76, 0.48, 0.048, 0.18, 11)
                case .bright: (0.68, 0.30, 0.060, 0.22, 10)
                case .tense: (0.91, 0.53, 0.030, 0.30, 16)
                case .subdued: (0.58, 0.63, 0.082, 0.12, 6)
                }
                let count = compact ? (terrain.rings + 1) / 2 : terrain.rings
                for index in 0..<count {
                    let radius = 0.07 + CGFloat(index) * terrain.spacing * (compact ? 1.45 : 1)
                    let line = Path { path in
                        for step in 0..<36 {
                            let angle = Double(step) * .pi * 2 / 36
                            let ripple = 1 + terrain.ripple * sin(3 * angle + Double(index) * 0.14)
                            let vertex = point(terrain.centerX + radius * CGFloat(cos(angle) * ripple),
                                terrain.centerY + radius * CGFloat(sin(angle) * ripple) * 0.88)
                            if step == 0 { path.move(to: vertex) } else { path.addLine(to: vertex) }
                        }
                        path.closeSubpath()
                    }
                    context.stroke(line, with: .color(colors.middle.opacity(index.isMultiple(of: 3) ? 0.82 : 0.40)),
                        lineWidth: compact ? 1 : 0.85)
                }
                let marker = width * (compact ? 0.09 : 0.03)
                let center = point(terrain.centerX, terrain.centerY)
                context.fill(Path(ellipseIn: CGRect(x: center.x - marker / 2, y: center.y - marker / 2,
                    width: marker, height: marker)), with: .color(colors.accent))
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
#endif
