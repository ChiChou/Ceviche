#!/usr/bin/env swift
// Rebuild the Mac icon master and outlined wordmarks from the tracked identity sources.
// Run from any directory: swift app/scripts/identity.swift
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let identity = root.appendingPathComponent("docs/design/identity-system")

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "Identity", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot write \(url.path)"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "Identity", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG export failed"])
    }
}

let sourceURL = identity.appendingPathComponent("bowl-source.png")
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Cannot load the bowl source or create the icon context")
}
// The legacy .icns needs its own frame; mobile uses the unmasked opaque source.
// Use a native continuous corner path so alpha is deterministic and free of generated edge artifacts.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let mask = RoundedRectangle(cornerRadius: 185, style: .continuous).path(in: tile).cgPath
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -8), blur: 12,
                  color: CGColor(gray: 0, alpha: 0.18))
context.addPath(mask)
context.setFillColor(CGColor(red: 248 / 255, green: 245 / 255, blue: 241 / 255, alpha: 1))
context.fillPath()
context.restoreGState()
context.addPath(mask)
context.clip()
context.interpolationQuality = .high
context.draw(artwork, in: tile)
try writePNG(context.makeImage()!, to: root.appendingPathComponent("app/Platforms/macOS/Resources/AppIcon.png"))

let fontURL = identity.appendingPathComponent("fonts/Nunito.ttf")
guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as? [CTFontDescriptor],
      let descriptor = descriptors.first else { fatalError("Cannot load the tracked Nunito font") }
let bold = CTFontDescriptorCreateCopyWithVariation(descriptor, NSNumber(value: 0x77676874), 700)
let font = CTFontCreateWithFontDescriptor(bold, 200, nil)
precondition(CTFontCopyFamilyName(font) as String == "Nunito")
let variations = CTFontCopyVariation(font) as? [NSNumber: NSNumber]
precondition(variations?[NSNumber(value: 0x77676874)]?.intValue == 700, "Nunito must be weight 700")
let text = NSAttributedString(string: "ceviche", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
let line = CTLineCreateWithAttributedString(text)
let outline = CGMutablePath()
for run in CTLineGetGlyphRuns(line) as! [CTRun] {
    let count = CTRunGetGlyphCount(run)
    var glyphs = [CGGlyph](repeating: 0, count: count)
    var positions = [CGPoint](repeating: .zero, count: count)
    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
    CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
    for (glyph, position) in zip(glyphs, positions) {
        guard let path = CTFontCreatePathForGlyph(font, glyph, nil) else { fatalError("Missing wordmark glyph") }
        outline.addPath(path, transform: CGAffineTransform(translationX: position.x, y: position.y))
    }
}
let bounds = outline.boundingBoxOfPath
let padding: CGFloat = 4
var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                  tx: padding - bounds.minX, ty: padding + bounds.maxY)
let normalized = outline.copy(using: &transform)!
func number(_ value: CGFloat) -> String { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), Double(value)) }
func point(_ point: CGPoint) -> String { "\(number(point.x)) \(number(point.y))" }
var commands: [String] = []
normalized.applyWithBlock { elementPointer in
    let element = elementPointer.pointee
    switch element.type {
    case .moveToPoint: commands.append("M\(point(element.points[0]))")
    case .addLineToPoint: commands.append("L\(point(element.points[0]))")
    case .addQuadCurveToPoint: commands.append("Q\(point(element.points[0])) \(point(element.points[1]))")
    case .addCurveToPoint: commands.append("C\(point(element.points[0])) \(point(element.points[1])) \(point(element.points[2]))")
    case .closeSubpath: commands.append("Z")
    @unknown default: fatalError("Unsupported outline element")
    }
}
for (name, color) in [("wordmark.svg", "#423D37"), ("wordmark-reversed.svg", "#F8F5F1")] {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(number(bounds.width + 2 * padding)) \(number(bounds.height + 2 * padding))" role="img" aria-labelledby="title">
      <title id="title">ceviche</title>
      <!-- Nunito Bold 700; outlined with Core Text. Source and OFL: see README.md. -->
      <path fill="\(color)" d="\(commands.joined(separator: " "))"/>
    </svg>

    """
    try svg.write(to: identity.appendingPathComponent(name), atomically: true, encoding: .utf8)
}
print("Wrote AppIcon.png and Nunito Bold 700 wordmarks")
