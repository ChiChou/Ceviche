import AppKit

/// Buttons drawn over the photo (Reframe's Dismiss and Apply, Remove Spots' Find blemishes), in the look of the bars
/// over the photo: a dark plate with the app's control radius, lit under the pointer; the prominent one takes the
/// chosen accent.
extension ImageCanvas {
    static let canvasButtonFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let canvasButtonHeight = 24.0
    static func canvasButtonWidth(_ title: String) -> Double {
        (title as NSString).size(withAttributes: [.font: canvasButtonFont]).width + 22
    }
    func drawCanvasButton(_ title: String, in rect: CGRect, prominent: Bool = false) {
        let lit = pointerPosition.map { rect.contains($0) } ?? false
        let shape = NSBezierPath(roundedRect: rect, xRadius: Theme.Radius.control, yRadius: Theme.Radius.control)
        let text: NSColor
        if prominent {
            (lit ? Theme.nsAccent.blended(withFraction: 0.15, of: .white) ?? Theme.nsAccent : Theme.nsAccent).setFill(); shape.fill()
            text = AccentChoice.current.nsOnColor
        } else {
            NSColor.black.withAlphaComponent(0.75).setFill(); shape.fill()
            if lit { NSColor.white.withAlphaComponent(0.16).setFill(); shape.fill() }
            text = NSColor.white.withAlphaComponent(lit ? 1 : 0.85)
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.canvasButtonFont, .foregroundColor: text]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }
}
