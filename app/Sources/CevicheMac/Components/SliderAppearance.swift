import AppKit

/// Color communicates the parameter's endpoints; the native slider retains tracking and accessibility.
enum SliderAppearance: Equatable {
    case neutral, luminance, temperature, tint, hue, saturation(Double), hueShift(Double), brightness(Double), hueRange(Double, Double)
    /// From a hue through gray to its complement, as enlarger filtration moves a print.
    case complement(Double)

    static func parameter(_ title: String) -> Self {
        switch title.lowercased() {
        case "temperature", "warmth": return .temperature
        case "tint", "shadow tint": return .tint
        case "hue": return .hue
        case "saturation", "vibrance", "refine saturation": return .saturation(0.04)
        case "exposure", "contrast", "highlights", "shadows", "whites", "blacks", "luminance", "lights", "darks": return .luminance
        case "red hue": return .hueShift(0)
        case "green hue": return .hueShift(1.0 / 3)
        case "blue hue": return .hueShift(2.0 / 3)
        case "red saturation": return .saturation(0)
        case "green saturation": return .saturation(1.0 / 3)
        case "blue saturation": return .saturation(2.0 / 3)
        default: return .neutral
        }
    }
    private static func color(_ hue: Double, saturation: Double = 0.78, brightness: Double = 0.88) -> NSColor {
        return NSColor(calibratedHue: (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1), saturation: saturation, brightness: brightness, alpha: 1)
    }
    var colors: [NSColor] {
        switch self {
        case .neutral: return [NSColor(white: 0.30, alpha: 1), NSColor(white: 0.52, alpha: 1)]
        case .luminance: return [NSColor(white: 0.20, alpha: 1), NSColor(white: 0.85, alpha: 1)]
        case .temperature: return [.init(srgbRed: 0.25, green: 0.65, blue: 0.94, alpha: 1), .init(white: 0.78, alpha: 1), .init(srgbRed: 1, green: 0.72, blue: 0.27, alpha: 1)]
        case .tint: return [Self.color(0.33), .init(white: 0.65, alpha: 1), Self.color(0.83)]
        case .hue: return (0...12).map { Self.color(Double($0) / 12) }
        case .saturation(let hue): return [.init(white: 0.38, alpha: 1), Self.color(hue)]
        case .hueShift(let hue): return [-1.0, -0.5, 0, 0.5, 1].map { Self.color(hue + $0 / 6) }
        case .brightness(let hue): return [Self.color(hue, brightness: 0.18), Self.color(hue), Self.color(hue, saturation: 0.12, brightness: 0.95)]
        case .hueRange(let from, let to): return stride(from: from, through: to, by: (to - from) / 8).map { Self.color($0) }
        case .complement(let hue): return [Self.color(hue), .init(white: 0.65, alpha: 1), Self.color(hue + 0.5)]
        }
    }
}

class ContextSliderCell: NSSliderCell {
    var appearance: SliderAppearance = .neutral
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 1.5, width: rect.width, height: 3)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).addClip()
        NSGradient(colors: appearance.colors.map { isEnabled ? $0 : $0.withAlphaComponent(0.3) })?.draw(in: track, angle: 0)
        NSGraphicsContext.restoreGraphicsState()
        if minValue < 0 && maxValue > 0 {
            let x = track.minX + (0 - minValue) / (maxValue - minValue) * track.width
            NSColor.white.withAlphaComponent(isEnabled ? 0.25 : 0.1).setFill()
            NSBezierPath(rect: NSRect(x: x - 0.5, y: track.midY - 3, width: 1, height: 6)).fill()
        }
    }
    override func drawKnob(_ knobRect: NSRect) {
        let thumb = NSRect(x: knobRect.midX - 3.5, y: knobRect.midY - 6, width: 7, height: 12)
        NSColor.black.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: thumb.insetBy(dx: -1, dy: -1), xRadius: 4, yRadius: 4).fill()
        NSColor(white: isEnabled ? (isHighlighted ? 1 : 0.85) : 0.45, alpha: 1).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: 3, yRadius: 3).fill()
    }
}
