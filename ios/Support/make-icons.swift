#!/usr/bin/env swift
//
//  Génère les icônes de l'application à partir du même tracé que la favicon du
//  site : une polyligne de supervision turquoise sur fond sombre.
//
//  Trois variantes, comme le demande iOS depuis la version 18 :
//   • clair   — carré opaque, le système applique lui-même le masque arrondi ;
//   • sombre  — tracé seul sur fond transparent, le système pose le fond ;
//   • teintée — tracé en niveaux de gris, le système applique la teinte.
//
//  Usage : swift Support/make-icons.swift
//
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side = 1024

/// `M5 21 l5-8 4 5 4-9 4 7 5-4` de la favicon, dans son viewBox 32×32 d'origine.
let polyline: [CGPoint] = [
    CGPoint(x: 5, y: 21),
    CGPoint(x: 10, y: 13),
    CGPoint(x: 14, y: 18),
    CGPoint(x: 18, y: 9),
    CGPoint(x: 22, y: 16),
    CGPoint(x: 27, y: 12),
]

/// Épaisseur du trait, exprimée dans le repère du viewBox.
let strokeUnits: CGFloat = 2.5

/// Part du côté occupée par le tracé, contour compris.
///
/// iOS masque l'icône en superellipse et la réduit jusqu'à 20 px : un glyphe
/// collé aux bords se fait rogner aux angles, et la favicon d'origine — pensée
/// pour un carré de 32 px sans masque — est trop large pour être reprise telle
/// quelle. On recadre donc sur sa boîte englobante.
let safeAreaRatio: CGFloat = 0.62

/// Transformation qui centre le tracé dans la zone sûre et l'y met à l'échelle.
let layout: (scale: CGFloat, offset: CGPoint) = {
    let half = strokeUnits / 2
    let minX = polyline.map(\.x).min()! - half
    let maxX = polyline.map(\.x).max()! + half
    let minY = polyline.map(\.y).min()! - half
    let maxY = polyline.map(\.y).max()! + half

    let width = maxX - minX
    let height = maxY - minY
    // La plus grande dimension commande l'échelle : les proportions du tracé
    // d'origine sont conservées.
    let scale = CGFloat(side) * safeAreaRatio / max(width, height)
    let offset = CGPoint(
        x: (CGFloat(side) - width * scale) / 2 - minX * scale,
        y: (CGFloat(side) - height * scale) / 2 - minY * scale)
    return (scale, offset)
}()

let strokeWidth = strokeUnits * layout.scale
let teal = CGColor(srgbRed: 0, green: 0.831, blue: 0.667, alpha: 1)

func makeContext() -> CGContext {
    guard let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("Contexte graphique indisponible") }
    // Le SVG a l'origine en haut à gauche, CoreGraphics en bas à gauche.
    context.translateBy(x: 0, y: CGFloat(side))
    context.scaleBy(x: 1, y: -1)
    return context
}

func drawBackground(in context: CGContext) {
    // Dégradé discret plutôt qu'un aplat : à 1024 px, un fond parfaitement plat
    // paraît terne à côté des icônes système.
    let colors = [
        CGColor(srgbRed: 0.078, green: 0.098, blue: 0.133, alpha: 1),
        CGColor(srgbRed: 0.027, green: 0.039, blue: 0.063, alpha: 1),
    ] as CFArray
    guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   colors: colors, locations: [0, 1])
    else { return }
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: CGFloat(side)),
                               end: CGPoint(x: 0, y: 0),
                               options: [])
}

func drawPolyline(in context: CGContext, color: CGColor, glow: Bool) {
    let path = CGMutablePath()
    for (index, point) in polyline.enumerated() {
        let placed = CGPoint(x: point.x * layout.scale + layout.offset.x,
                             y: point.y * layout.scale + layout.offset.y)
        index == 0 ? path.move(to: placed) : path.addLine(to: placed)
    }

    context.setLineWidth(strokeWidth)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(color)

    if glow {
        // Une lueur très douce donne du relief sans trahir le tracé d'origine.
        context.saveGState()
        context.setShadow(offset: .zero, blur: strokeWidth * 0.5,
                          color: color.copy(alpha: 0.5))
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    context.addPath(path)
    context.strokePath()
}

func write(_ image: CGImage, to name: String) {
    let directory = URL(fileURLWithPath: "MBA/Resources/Assets.xcassets/AppIcon.appiconset")
    let url = directory.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("Écriture impossible : \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Encodage PNG échoué") }
    print("✓ \(name)")
}

// Variante claire : fond opaque + tracé turquoise.
do {
    let context = makeContext()
    drawBackground(in: context)
    drawPolyline(in: context, color: teal, glow: true)
    write(context.makeImage()!, to: "icon.png")
}

// Variante sombre : tracé seul, fond laissé transparent au système.
do {
    let context = makeContext()
    drawPolyline(in: context, color: teal, glow: true)
    write(context.makeImage()!, to: "icon-dark.png")
}

// Variante teintée : niveaux de gris, sans lueur — le système colore le tracé et
// une lueur turquoise résiduelle jurerait avec la teinte choisie par l'utilisateur.
do {
    let context = makeContext()
    drawPolyline(in: context,
                 color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                 glow: false)
    write(context.makeImage()!, to: "icon-tinted.png")
}
