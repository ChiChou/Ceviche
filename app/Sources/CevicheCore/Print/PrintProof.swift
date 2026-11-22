import ColorSync
import CoreImage
import Foundation

public enum PrintIntent: String, CaseIterable, Sendable, Identifiable {
    case perceptual, relative
    public var id: String { rawValue }
    public var title: String { self == .perceptual ? L10n.tr("Perceptual") : L10n.tr("Relative") }
    var value: CFString {
        (self == .perceptual ? kColorSyncRenderingIntentPerceptual : kColorSyncRenderingIntentRelative).takeUnretainedValue()
    }
}

public struct PrintProofSettings: Hashable, Sendable {
    public var intent = PrintIntent.perceptual
    /// Maps the photo's black onto the print's; relative colorimetric only, where the profile's tables don't do it.
    public var blackPointCompensation = true
    /// Shows the paper's own white and the ink's own black instead of stretching both to the screen's.
    public var simulatePaper = true
    /// Tints what the print can't hold: colours outside its gamut, and shadows below its black.
    public var gamutWarning = false
    public var shadowWarning = false
    /// Red follows destination-gamut warnings; blue follows shadow-clipping warnings.
    public let gamutWarningColor = SIMD3<Double>(1, 0, 0)
    public let shadowWarningColor = SIMD3<Double>(0, 0, 1)
    public init() {}
}

public enum PrintProofError: LocalizedError {
    case unreadable(String), notAPrinter(String), failed
    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): L10n.tr("\(name) can’t be read as an ICC profile.")
        case .notAPrinter(let name): L10n.tr("\(name) isn’t a printer profile.")
        case .failed: L10n.tr("The proof couldn’t be made with this profile.")
        }
    }
}

/// A printer and paper's ICC profile, and the photo as that print would show it.
///
/// The proof is a 65³ colour cube in ProPhoto, built with ColorSync whenever the profile or a setting changes: it
/// matches ColorSync's own conversion to ΔE < 0.8 at the 99th percentile and costs a few milliseconds a frame.
/// Black point compensation is done here rather than by ColorSync, whose own tints ProPhoto greys blue.
/// Paper is simulated by reading the print in absolute L*a*b* and showing that relative to the screen's white. Sent
/// straight to a D65 screen as absolute colour, D50 paper would look warm, which the eye adapted to the print doesn't
/// see.
public final class PrintProfile: @unchecked Sendable {
    public let url: URL
    public let name: String
    private let profile: ColorSyncProfile
    /// Ink channels: 4 for a press or a CMYK proofer, 3 for an inkjet driven as RGB.
    let channels: Int
    /// An inkjet's profile: photos can be exported in it, which a press profile's four inks don't allow.
    public var isRGB: Bool { channels == 3 }
    /// The bare paper and the darkest print, as a spectrophotometer would read them: L*a*b* against D50.
    public let paperWhite: SIMD3<Double>, black: SIMD3<Double>
    /// The darkest print's luminance against the paper's, 0…1: what black point compensation maps the photo's black to.
    let blackLevel: Double

    static let size = 65
    private static let romm = ColorSyncProfileCreateWithName(kColorSyncROMMRGBProfile.takeUnretainedValue())!.takeRetainedValue()
    private static let lab = ColorSyncProfileCreateWithName(kColorSyncGenericLabProfile.takeUnretainedValue())!.takeRetainedValue()
    private let lock = NSLock()
    private var cubes: [PrintProofSettings: Data] = [:]
    private var warnings: (colour: Data, shadow: Data)?

    public init(url: URL) throws {
        let file = url.lastPathComponent
        // The file's own header: class at byte 12, colour space at 16.
        guard let profile = ColorSyncProfileCreateWithURL(url as CFURL, nil)?.takeRetainedValue(),
              let header = try? FileHandle(forReadingFrom: url).read(upToCount: 20), header.count == 20 else { throw PrintProofError.unreadable(file) }
        func tag(_ offset: Int) -> String { String(decoding: header[offset..<offset + 4], as: UTF8.self) }
        // Output profiles only, in an ink space ColorSync can drive.
        guard tag(12) == "prtr", ["CMYK", "RGB "].contains(tag(16)) else { throw PrintProofError.notAPrinter(file) }
        self.url = url; self.profile = profile
        channels = tag(16) == "CMYK" ? 4 : 3
        name = (ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String?) ?? url.deletingPathExtension().lastPathComponent
        let read = try Self.measured(profile)
        let paper: [Float] = channels == 4 ? [0, 0, 0, 0] : [1, 1, 1]
        paperWhite = Self.labValue(try Self.convert(read, paper, count: 1, into: 3), 0)
        let darkest = try Self.convert(try Self.sequence(from: Self.romm, to: profile, intent: .relative, bpc: false), [0, 0, 0], count: 1, into: channels)
        black = Self.labValue(try Self.convert(read, darkest, count: 1, into: 3), 0)
        let relative = Self.labValue(try Self.convert(try Self.sequence(from: profile, to: Self.lab, intent: .relative, bpc: false), darkest, count: 1, into: 3), 0)
        blackLevel = min(0.5, max(0, Self.xyz(relative).y))
    }

    /// How many stops lie between the paper and the darkest print.
    public var contrast: Double {
        func luminance(_ l: Double) -> Double { l > 8 ? pow((l + 16) / 116, 3) : l / 903.3 }
        return log2(luminance(paperWhite.x) / max(1e-6, luminance(black.x)))
    }

    /// Printer profiles in the places macOS and its users keep them.
    public static func installed() -> [URL] {
        let folders = [FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?.appendingPathComponent("ColorSync/Profiles"),
                       URL(fileURLWithPath: "/Library/ColorSync/Profiles"), URL(fileURLWithPath: "/Library/Printers")].compactMap { $0 }
        var found: [URL] = [], budget = 4000
        for folder in folders {
            guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where budget > 0 && ["icc", "icm"].contains(url.pathExtension.lowercased()) {
                budget -= 1
                guard let data = try? FileHandle(forReadingFrom: url).read(upToCount: 20), data.count == 20,
                      String(decoding: data[12..<16], as: UTF8.self) == "prtr", ["CMYK", "RGB "].contains(String(decoding: data[16..<20], as: UTF8.self)) else { continue }
                found.append(url)
            }
        }
        return found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: ColorSync

    private static func step(_ profile: ColorSyncProfile, _ intent: CFString, _ tag: CFString, _ bpc: Bool) -> [String: Any] {
        [kColorSyncProfile.takeUnretainedValue() as String: profile, kColorSyncRenderingIntent.takeUnretainedValue() as String: intent,
         kColorSyncTransformTag.takeUnretainedValue() as String: tag, kColorSyncBlackPointCompensation.takeUnretainedValue() as String: bpc]
    }
    private static func make(_ steps: [[String: Any]]) throws -> ColorSyncTransform {
        guard let transform = ColorSyncTransformCreate(steps as CFArray, nil)?.takeRetainedValue() else { throw PrintProofError.failed }
        return transform
    }
    /// `from` read into the connection space and `to` written from it, both by `intent`.
    private static func sequence(from: ColorSyncProfile, to: ColorSyncProfile, intent: PrintIntent, bpc: Bool) throws -> ColorSyncTransform {
        try make([step(from, intent.value, kColorSyncTransformDeviceToPCS.takeUnretainedValue(), bpc), step(to, intent.value, kColorSyncTransformPCSToDevice.takeUnretainedValue(), bpc)])
    }
    /// Ink to absolute L*a*b*: the print as an instrument reads it, paper tint and all.
    private static func measured(_ printer: ColorSyncProfile) throws -> ColorSyncTransform {
        let absolute = kColorSyncRenderingIntentAbsolute.takeUnretainedValue()
        return try make([step(printer, absolute, kColorSyncTransformDeviceToPCS.takeUnretainedValue(), false), step(lab, absolute, kColorSyncTransformPCSToDevice.takeUnretainedValue(), false)])
    }
    /// Converts `count` pixels of floats, in rows so ColorSync spreads the work over the cores.
    private static func convert(_ transform: ColorSyncTransform, _ source: [Float], count: Int, into channels: Int) throws -> [Float] {
        let from = source.count / max(1, count), width = min(4096, count), height = (count + width - 1) / width
        var padded = source, out = [Float](repeating: 0, count: width * height * channels)
        if width * height > count { padded += [Float](repeating: 0, count: (width * height - count) * from) }
        let layout = ColorSyncDataLayout(UInt32(kColorSyncByteOrderDefault) | kColorSyncAlphaNone.rawValue), depth = ColorSyncDataDepth(kColorSync32BitFloat.rawValue)
        let done = padded.withUnsafeBytes { s in out.withUnsafeMutableBytes { d in
            ColorSyncTransformConvert(transform, width, height, d.baseAddress!, depth, layout, width * channels * 4, s.baseAddress!, depth, layout, width * from * 4, nil)
        } }
        guard done else { throw PrintProofError.failed }
        return Array(out.prefix(count * channels))
    }
    /// ColorSync's float L*a*b*: L / 100, (a + 128) / 255, (b + 128) / 255.
    private static func labValue(_ values: [Float], _ i: Int) -> SIMD3<Double> {
        SIMD3(Double(values[i * 3]) * 100, Double(values[i * 3 + 1]) * 255 - 128, Double(values[i * 3 + 2]) * 255 - 128)
    }

    /// D50, the connection space's white.
    private static let white = SIMD3(0.9642, 1, 0.8249)
    private static func xyz(_ lab: SIMD3<Double>) -> SIMD3<Double> {
        func inverse(_ t: Double) -> Double { t > 6.0 / 29 ? t * t * t : 3 * (6.0 / 29) * (6.0 / 29) * (t - 4.0 / 29) }
        let y = (lab.x + 16) / 116
        return white * SIMD3(inverse(y + lab.y / 500), inverse(y), inverse(y - lab.z / 200))
    }
    /// `count` colours in ColorSync's float L*a*b*, each moved in XYZ by `move`.
    private static func moved(_ lab: [Float], count: Int, _ move: (SIMD3<Double>) -> SIMD3<Double>) -> [Float] {
        func forward(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        var out = lab
        for i in 0..<count {
            let v = move(xyz(labValue(lab, i))) / white
            let x = forward(max(0, v.x)), y = forward(max(0, v.y)), z = forward(max(0, v.z))
            out[i * 3] = Float((116 * y - 16) / 100); out[i * 3 + 1] = Float((500 * (x - y) + 128) / 255); out[i * 3 + 2] = Float((200 * (y - z) + 128) / 255)
        }
        return out
    }

    // MARK: Proof

    /// What the print can't hold, per pixel of ProPhoto-encoded `rgb`: a colour outside its gamut (more than ΔE 3
    /// off after a relative colorimetric trip to the printer and back, lightness aside), or a shadow below its
    /// black. Kept apart: one is fixed with saturation, the other with the tone curve. The profile's own gamut table
    /// flags both together, and too much.
    func limits(_ rgb: [Float], count: Int) throws -> (colour: [Bool], shadow: [Bool]) {
        let toLab = try Self.sequence(from: Self.romm, to: Self.lab, intent: .relative, bpc: false)
        let there = try Self.sequence(from: Self.romm, to: profile, intent: .relative, bpc: false)
        let back = try Self.sequence(from: profile, to: Self.lab, intent: .relative, bpc: false)
        let source = try Self.convert(toLab, rgb, count: count, into: 3)
        let printed = try Self.convert(back, try Self.convert(there, rgb, count: count, into: channels), count: count, into: 3)
        let floor = Self.labValue(try Self.convert(back, try Self.convert(there, [0, 0, 0], count: 1, into: channels), count: 1, into: 3), 0).x
        var colour = [Bool](repeating: false, count: count), shadow = colour
        colour.withUnsafeMutableBufferPointer { colour in shadow.withUnsafeMutableBufferPointer { shadow in
            let colour = colour, shadow = shadow
            DispatchQueue.concurrentPerform(iterations: 64) { k in
                for i in stride(from: k, to: count, by: 64) {
                    let a = Self.labValue(source, i)
                    var b = Self.labValue(printed, i)
                    b.x = a.x
                    shadow[i] = a.x < floor - 1
                    colour[i] = !shadow[i] && ChartColour.deltaE2000(a, b) > 3
                }
            }
        } }
        return (colour, shadow)
    }

    /// The proof as a colour cube over ProPhoto-encoded colour, red fastest, RGBA floats: each colour as the print
    /// shows it, again in ProPhoto.
    public func cube(_ settings: PrintProofSettings) throws -> Data {
        var key = settings
        key.gamutWarning = false; key.shadowWarning = false
        if key.intent != .relative { key.blackPointCompensation = true }
        if let cached = lock.withLock({ cubes[key] }) { return cached }
        let n = Self.size, count = n * n * n
        var grid = [Float](repeating: 0, count: count * 3)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let i = ((b * n + g) * n + r) * 3
            grid[i] = Float(r) / Float(n - 1); grid[i + 1] = Float(g) / Float(n - 1); grid[i + 2] = Float(b) / Float(n - 1)
        } } }
        // Perceptual tables carry their own black mapping; compensation is for relative colorimetric. It is done here,
        // in XYZ, the photo's black onto the print's: ColorSync's own compensation tints ProPhoto greys blue.
        let bpc = settings.intent == .relative && settings.blackPointCompensation
        let k = blackLevel, white = Self.white
        let ink: [Float]
        if bpc {
            let lab = try Self.convert(try Self.sequence(from: Self.romm, to: Self.lab, intent: .relative, bpc: false), grid, count: count, into: 3)
            let lifted = Self.moved(lab, count: count) { $0 * (1 - k) + white * k }
            ink = try Self.convert(try Self.sequence(from: Self.lab, to: profile, intent: .relative, bpc: false), lifted, count: count, into: channels)
        } else {
            ink = try Self.convert(try Self.sequence(from: Self.romm, to: profile, intent: settings.intent, bpc: false), grid, count: count, into: channels)
        }
        let toScreen = try Self.sequence(from: Self.lab, to: Self.romm, intent: .relative, bpc: false)
        let shown: [Float]
        if settings.simulatePaper {
            // The print as measured, then that against the screen's white.
            shown = try Self.convert(toScreen, try Self.convert(try Self.measured(profile), ink, count: count, into: 3), count: count, into: 3)
        } else {
            // The print against its own paper, its black stretched to the screen's.
            let printed = try Self.convert(try Self.sequence(from: profile, to: Self.lab, intent: .relative, bpc: false), ink, count: count, into: 3)
            shown = try Self.convert(toScreen, Self.moved(printed, count: count) { ($0 - white * k) / (1 - k) }, count: count, into: 3)
        }
        var values = [Float](repeating: 1, count: count * 4)
        for i in 0..<count { for c in 0..<3 { values[i * 4 + c] = min(1, max(0, shown[i * 3 + c])) } }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.withLock { cubes[key] = data }
        return data
    }

    /// Two cubes over ProPhoto-encoded colour, white where the print can't hold a colour and where a shadow is below
    /// its black. Grey, so the cube filter's colour management leaves them as they are.
    func warningCubes() throws -> (colour: Data, shadow: Data) {
        if let cached = lock.withLock({ warnings }) { return cached }
        let n = Self.size, count = n * n * n
        var grid = [Float](repeating: 0, count: count * 3)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let i = ((b * n + g) * n + r) * 3
            grid[i] = Float(r) / Float(n - 1); grid[i + 1] = Float(g) / Float(n - 1); grid[i + 2] = Float(b) / Float(n - 1)
        } } }
        let (colour, shadow) = try limits(grid, count: count)
        func cube(_ flags: [Bool]) -> Data {
            var values = [Float](repeating: 1, count: count * 4)
            for i in 0..<count where !flags[i] { values[i * 4] = 0; values[i * 4 + 1] = 0; values[i * 4 + 2] = 0 }
            return values.withUnsafeBufferPointer { Data(buffer: $0) }
        }
        let made = (cube(colour), cube(shadow))
        lock.withLock { warnings = made }
        return made
    }

    /// `image` as the print would show it. With warnings, colours the print can't hold are red and shadows below
    /// its black blue: whole pixels, by the nearer side of the gamut's edge, so the tint covers what `coverage` counts.
    public func proof(_ image: CIImage, settings: PrintProofSettings) throws -> CIImage {
        let space = CGColorSpace(name: CGColorSpace.rommrgb)!
        func through(_ cube: Data) -> CIImage {
            image.applyingFilter("CIColorCubeWithColorSpace", parameters: ["inputCubeDimension": Self.size, "inputCubeData": cube, "inputColorSpace": space])
        }
        var shown = through(try cube(settings))
        guard settings.gamutWarning || settings.shadowWarning else { return shown }
        let cubes = try warningCubes()
        // Half grey in ProPhoto's encoding, as linear light.
        let half = pow(0.5, 1.8)
        for (enabled, flags, colour) in [(settings.shadowWarning, cubes.shadow, settings.shadowWarningColor),
                                         (settings.gamutWarning, cubes.colour, settings.gamutWarningColor)] where enabled {
            let tint = CIColor(red: colour.x, green: colour.y, blue: colour.z)
            let mask = through(flags).applyingFilter("CIColorThreshold", parameters: ["inputThreshold": half])
            shown = CIImage(color: tint).cropped(to: image.extent)
                .composited(over: shown)
                .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: shown, kCIInputMaskImageKey: mask])
        }
        return shown
    }

    /// `image` in the printer's own colour and tagged with its profile, for a print the application manages: converted
    /// by `settings`' intent and black point, as the proof shows it. For RGB printers; a press's inks are not sent
    /// to a desktop printer.
    public func separated(_ image: CGImage, settings: PrintProofSettings) throws -> CGImage {
        guard isRGB, let icc = try? Data(contentsOf: url), let space = CGColorSpace(iccData: icc as CFData), space.model == .rgb else { throw PrintProofError.failed }
        let width = image.width, height = image.height
        let bpc = settings.intent == .relative && settings.blackPointCompensation
        let k = blackLevel, white = Self.white
        let direct = bpc ? nil : try Self.sequence(from: Self.romm, to: profile, intent: settings.intent, bpc: false)
        let toLab = bpc ? try Self.sequence(from: Self.romm, to: Self.lab, intent: .relative, bpc: false) : nil
        let fromLab = bpc ? try Self.sequence(from: Self.lab, to: profile, intent: .relative, bpc: false) : nil
        var out = [UInt16](repeating: 0xFFFF, count: width * height * 4)
        // A band of about a million pixels at a time keeps the float copies small.
        let band = max(1, (1 << 20) / max(1, width))
        var pixels = [Float](repeating: 0, count: width * band * 4), rgb = [Float](repeating: 0, count: width * band * 3)
        let info = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        for top in stride(from: 0, to: height, by: band) {
            try Task.checkCancellation()
            let rows = min(band, height - top), count = width * rows
            guard let context = CGContext(data: &pixels, width: width, height: rows, bitsPerComponent: 32, bytesPerRow: width * 16,
                                          space: CGColorSpace(name: CGColorSpace.rommrgb)!, bitmapInfo: info) else { throw PrintProofError.failed }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: -(height - top - rows), width: width, height: height))
            for i in 0..<count { for c in 0..<3 { rgb[i * 3 + c] = min(1, max(0, pixels[i * 4 + c])) } }
            let source = Array(rgb.prefix(count * 3))
            let ink: [Float]
            if let toLab, let fromLab {
                let lifted = Self.moved(try Self.convert(toLab, source, count: count, into: 3), count: count) { $0 * (1 - k) + white * k }
                ink = try Self.convert(fromLab, lifted, count: count, into: 3)
            } else {
                ink = try Self.convert(direct!, source, count: count, into: 3)
            }
            let start = top * width * 4
            for i in 0..<count { for c in 0..<3 { out[start + i * 4 + c] = UInt16(min(1, max(0, ink[i * 3 + c])) * 65535 + 0.5) } }
        }
        let data = out.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let made = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8, space: space,
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw PrintProofError.failed }
        return made
    }

    /// The share of the picture the print can't hold: colours outside its gamut, and shadows below its black.
    public func coverage(of image: CGImage) throws -> (colour: Double, shadow: Double) {
        let scale = min(1, 1000 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let info = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 32, bytesPerRow: width * 16,
                                      space: CGColorSpace(name: CGColorSpace.rommrgb)!, bitmapInfo: info) else { throw PrintProofError.failed }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let count = width * height
        var rgb = [Float](repeating: 0, count: count * 3)
        for i in 0..<count { for c in 0..<3 { rgb[i * 3 + c] = min(1, max(0, pixels[i * 4 + c])) } }
        let (colour, shadow) = try limits(rgb, count: count)
        return (Double(colour.filter { $0 }.count) / Double(count), Double(shadow.filter { $0 }.count) / Double(count))
    }
}
