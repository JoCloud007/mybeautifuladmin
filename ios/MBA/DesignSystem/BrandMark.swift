import SwiftUI

/// Le tracé de marque : la polyligne de supervision partagée par la favicon du
/// site, l'icône de l'application et les écrans d'identité.
///
/// La géométrie est celle de `Support/make-icons.swift` — même viewBox 32×32,
/// même épaisseur, même cadrage sur la boîte englobante. Les deux doivent rester
/// alignés : une icône et un écran d'accueil qui ne montrent pas exactement le
/// même signe se remarquent immédiatement.
struct BrandPolyline: Shape {
    /// `M5 21 l5-8 4 5 4-9 4 7 5-4`, en points absolus du viewBox d'origine.
    private static let points: [CGPoint] = [
        CGPoint(x: 5, y: 21),
        CGPoint(x: 10, y: 13),
        CGPoint(x: 14, y: 18),
        CGPoint(x: 18, y: 9),
        CGPoint(x: 22, y: 16),
        CGPoint(x: 27, y: 12),
    ]

    private static let strokeUnits: CGFloat = 2.5
    /// Part du côté occupée par le tracé, contour compris.
    private static let safeAreaRatio: CGFloat = 0.62

    /// Boîte englobante du tracé, contour compris.
    private static let bounds: CGRect = {
        let half = strokeUnits / 2
        let minX = points.map(\.x).min()! - half
        let maxX = points.map(\.x).max()! + half
        let minY = points.map(\.y).min()! - half
        let maxY = points.map(\.y).max()! + half
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }()

    private static func scale(for side: CGFloat) -> CGFloat {
        side * safeAreaRatio / max(bounds.width, bounds.height)
    }

    /// Épaisseur du trait pour un cadre donné — à passer au `stroke`, puisqu'une
    /// `Shape` ne peut pas décider elle-même de son contour.
    static func lineWidth(for side: CGFloat) -> CGFloat {
        strokeUnits * scale(for: side)
    }

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = Self.scale(for: side)
        let origin = CGPoint(
            x: rect.midX - Self.bounds.width * scale / 2 - Self.bounds.minX * scale,
            y: rect.midY - Self.bounds.height * scale / 2 - Self.bounds.minY * scale)

        var path = Path()
        for (index, point) in Self.points.enumerated() {
            let placed = CGPoint(x: point.x * scale + origin.x, y: point.y * scale + origin.y)
            index == 0 ? path.move(to: placed) : path.addLine(to: placed)
        }
        return path
    }
}

/// Marque de l'application, telle qu'elle apparaît sur l'icône.
struct BrandMark: View {
    var size: CGFloat = 64
    /// Le carré sombre reprend le fond de l'icône. Sans lui, seul le tracé est
    /// dessiné, à la teinte courante — utile en ligne, dans un titre.
    var showsBackground = true

    private var cornerRadius: CGFloat { size * 0.2237 }   // superellipse iOS approchée

    var body: some View {
        BrandPolyline()
            .stroke(showsBackground ? Color.brandTeal : Color.accentColor,
                    style: StrokeStyle(lineWidth: BrandPolyline.lineWidth(for: size),
                                       lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .background {
                if showsBackground {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color(.sRGB, red: 0.078, green: 0.098, blue: 0.133, opacity: 1),
                                     Color(.sRGB, red: 0.027, green: 0.039, blue: 0.063, opacity: 1)],
                            startPoint: .top, endPoint: .bottom))
                }
            }
            .accessibilityHidden(true)
    }
}

extension Color {
    /// Turquoise de marque, identique à celui de la favicon et de l'icône.
    ///
    /// Distinct de `.accentColor`, qui s'assombrit en mode clair pour rester
    /// lisible sur blanc : sur le carré sombre de la marque, c'est la teinte
    /// vive d'origine qu'il faut.
    static let brandTeal = Color(.sRGB, red: 0, green: 0.831, blue: 0.667, opacity: 1)
}

#Preview {
    VStack(spacing: 24) {
        BrandMark(size: 96)
        BrandMark(size: 64)
        BrandMark(size: 40, showsBackground: false)
    }
    .padding()
}
