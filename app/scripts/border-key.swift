import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Turns a border drawn round a chroma-green opening into a PNG with the opening transparent, and reports where the
// opening is. usage: key <in.png> <out.png> [check.png]
let arguments = CommandLine.arguments
guard arguments.count >= 3, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("usage: key in.png out.png [check.png]") }
let width = image.width, height = image.height, space = CGColorSpace(name: CGColorSpace.sRGB)!
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

var minX = width, minY = height, maxX = -1, maxY = -1, clear = 0
var columns = [Int](repeating: 0, count: width), rows = [Int](repeating: 0, count: height)
for y in 0..<height { for x in 0..<width {
    let i = (y * width + x) * 4
    let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
    // How much greener than anything else: the key. A border's own colours, even olive or teal, stay well under it.
    let green = g - max(r, b)
    let t = min(1, max(0, (green - 0.18) / 0.3)), alpha = 1 - t * t * (3 - 2 * t)
    // Spill: what is left of the green on the edge pixels goes back to the border's own colour.
    let kept = alpha < 1 ? min(g, max(r, b)) : g
    pixels[i] = UInt8((r * alpha * 255).rounded()); pixels[i + 1] = UInt8((kept * alpha * 255).rounded()); pixels[i + 2] = UInt8((b * alpha * 255).rounded())
    pixels[i + 3] = UInt8((alpha * 255).rounded())
    if alpha < 0.02 { clear += 1; columns[x] += 1; rows[y] += 1; minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
} }
// The opening a rectangular photo must cover: the columns and rows that are mostly clear.
let left = columns.firstIndex { $0 > (maxY - minY) / 2 } ?? minX, right = columns.lastIndex { $0 > (maxY - minY) / 2 } ?? maxX
let top = rows.firstIndex { $0 > (maxX - minX) / 2 } ?? minY, bottom = rows.lastIndex { $0 > (maxX - minX) / 2 } ?? maxY
func write(_ context: CGContext, _ path: String) {
    let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil); CGImageDestinationFinalize(destination)
}
write(context, arguments[2])
if arguments.count > 3 {
    // The keyed border over a magenta-to-yellow ramp: any green left, or any hole in the border, shows at once.
    var back = [UInt8](repeating: 255, count: width * height * 4)
    let check = CGContext(data: &back, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    check.drawLinearGradient(CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0.9, green: 0.1, blue: 0.7, alpha: 1), CGColor(srgbRed: 1, green: 0.9, blue: 0.3, alpha: 1)] as CFArray, locations: nil)!,
                             start: .zero, end: CGPoint(x: width, y: height), options: [])
    check.draw(context.makeImage()!, in: CGRect(x: 0, y: 0, width: width, height: height))
    write(check, arguments[3])
}
let name = URL(fileURLWithPath: arguments[1]).deletingPathExtension().lastPathComponent
print(String(format: "{\"name\": \"%@\", \"width\": %d, \"height\": %d, \"opening\": [%.4f, %.4f, %.4f, %.4f], \"bounds\": [%.4f, %.4f, %.4f, %.4f], \"clear\": %.3f}", name, width, height,
             Double(left) / Double(width), Double(top) / Double(height), Double(right + 1) / Double(width), Double(bottom + 1) / Double(height),
             Double(minX) / Double(width), Double(minY) / Double(height), Double(maxX + 1) / Double(width), Double(maxY + 1) / Double(height), Double(clear) / Double(width * height)))
