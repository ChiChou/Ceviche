#!/usr/bin/env swift
// Rebuild the outlined wordmarks from the tracked Nunito font. The icon is authored in AppIcon.icon.
// Run from any directory: swift app/scripts/identity.swift
import Foundation
import CoreGraphics
import CoreText

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let identity = root.appendingPathComponent("docs/design/identity-system")

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
print("Wrote Nunito Bold 700 wordmarks")
