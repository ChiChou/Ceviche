import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import DustRemoval
@testable import CevicheCore

/// Opt-in comparison of the classic dust finder with detection on the Visualize Spots (top-hat) map.
/// CEVICHE_DUST_RAWS: colon-separated RAW paths; CEVICHE_DUST_REVIEW_DIR: output directory (developed frames are cached there).
final class DustMapReviewTests: XCTestCase {
    struct Found: Codable {
        var x: Double; var y: Double; var r: Double; var score: Double = 0; var peak: Double = 0; var level: Int = 0
        init(x: Double, y: Double, r: Double, score: Double = 0, peak: Double = 0, level: Int = 0) { self.x = x; self.y = y; self.r = r; self.score = score; self.peak = peak; self.level = level }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            x = try c.decode(Double.self, forKey: .x); y = try c.decode(Double.self, forKey: .y); r = try c.decode(Double.self, forKey: .r)
            score = try c.decodeIfPresent(Double.self, forKey: .score) ?? 0; peak = try c.decodeIfPresent(Double.self, forKey: .peak) ?? 0
            level = try c.decodeIfPresent(Int.self, forKey: .level) ?? 0
        }
    }
    struct Frame: Codable { var name: String; var width: Int; var height: Int; var methods: [String: [Found]] }

    func testCompareOnSamples() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raws = env["CEVICHE_DUST_RAWS"], let dir = env["CEVICHE_DUST_REVIEW_DIR"] else {
            throw XCTSkip("Set CEVICHE_DUST_RAWS and CEVICHE_DUST_REVIEW_DIR")
        }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAf])
        var frames: [Frame] = []
        var sums: [[Float]] = [], lums: [[Float]] = [], sizes: [(Int, Int)] = [], stackCount = 0
        for path in raws.split(separator: ":").map(String.init) {
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            let cache = out.appendingPathComponent("dev_\(name).png")
            let image: RGBAImage
            if let cached = Self.readPNG(cache) { image = cached } else {
                let renderer = try RawRenderer(sourceURL: URL(fileURLWithPath: path))
                image = try await renderer.dustImage(renderer.info.defaults, maxDimension: DustFinder.classicSize)
                try Self.writePNG(image, to: cache)
            }
            var methods: [String: [Found]] = [:]
            let w = Double(image.width), h = Double(image.height), shorter = min(w, h)
            func px(_ spots: [DustSpot]) -> [Found] { spots.map { Found(x: $0.center.x * w, y: (1 - $0.center.y) * h, r: $0.radius * shorter, score: 0) } }
            var t = Date()
            methods["classic6"] = px(try DustFinder.classicSpots(in: image, options: .init()))
            print("[dust] \(name) classic6 \(Date().timeIntervalSince(t))s"); t = Date()
            methods["classic20"] = px(try DustFinder.classicSpots(in: image, options: .init(spotSize: 20)))
            print("[dust] \(name) classic20 \(Date().timeIntervalSince(t))s"); t = Date()
            let sensitivities = (env["CEVICHE_DUST_SENSITIVITIES"] ?? "0.5").split(separator: ",").compactMap { Double($0) }
            for s in sensitivities {
                methods[sensitivities.count == 1 ? "map" : "map\(s)"] = px(DustFinder.mapSpots(in: image, options: .init(sensitivity: s), context: context))
            }
            print("[dust] \(name) map \(Date().timeIntervalSince(t))s")
            if env["CEVICHE_DUST_MAPS"] != nil, let source = Self.cgImage(image),
               let m = DustFinder.topHatMap(CIImage(cgImage: source), scale: 0.5, context: context) {
                try Self.writeMapPNG(m.values, m.width, m.height, to: out.appendingPathComponent("map_\(name).png"))
            }
            if env["CEVICHE_DUST_STACK"] != nil {
                let source = try XCTUnwrap(Self.cgImage(image))
                for (i, level) in DustFinder.mapLevels.enumerated() {
                    let m = try XCTUnwrap(DustFinder.topHatMap(CIImage(cgImage: source), scale: level.scale, context: context))
                    if sums.count <= i { sums.append([Float](repeating: 0, count: m.values.count)); lums.append(sums[i]); sizes.append((m.width, m.height)) }
                    if sums[i].count == m.values.count { for j in 0..<m.values.count { sums[i][j] += m.values[j]; lums[i][j] += m.luminance[j] } }
                }
                stackCount += 1
            }
            frames.append(Frame(name: name, width: image.width, height: image.height, methods: methods))
            try Self.writeOverlay(image, methods: methods, to: out.appendingPathComponent("overlay_\(name).png"))
            print("[dust] \(name): " + methods.keys.sorted().map { "\($0)=\(methods[$0]!.count)" }.joined(separator: " "))
        }
        if stackCount > 1 {
            // The mean map of a tripod stack: noise falls by sqrt(n), moving clouds and people blur, sensor dust stays.
            var gt: [Found] = []
            for i in DustFinder.mapLevels.indices {
                let mean = sums[i].map { $0 / Float(stackCount) }
                try Self.writeMapPNG(mean, sizes[i].0, sizes[i].1, to: out.appendingPathComponent("meanmap\(i).png"))
                let f = Double(frames[0].width) / Double(sizes[i].0)
                let lum = lums[i].map { $0 / Float(stackCount) }, local = DustFinder.boxBlur(mean, sizes[i].0, sizes[i].1, radius: Int(DustFinder.mapLocalRadius))
                var pixels = [Float](repeating: 0, count: mean.count * 4)
                for j in mean.indices { pixels[j * 4] = mean[j]; pixels[j * 4 + 1] = lum[j]; pixels[j * 4 + 2] = local[j] }
                gt += DustFinder.mapFinds(.init(pixels: pixels, width: sizes[i].0, height: sizes[i].1), minScore: 4, minPeak: 0.012).map {
                    Found(x: $0.x * f, y: $0.y * f, r: $0.radius * f, score: Double($0.score), peak: Double($0.peak), level: i)
                }
            }
            try JSONEncoder().encode(gt).write(to: out.appendingPathComponent("meanspots.json"))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(frames).write(to: out.appendingPathComponent("spots.json"))
    }

    // MARK: Images

    static func cgImage(_ image: RGBAImage) -> CGImage? {
        let data = Data(image.pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
    static func readPNG(_ url: URL) -> RGBAImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let ctx = CGContext(data: &pixels, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return RGBAImage(width: cg.width, height: cg.height, pixels: pixels)
    }
    static func write(_ cg: CGImage, to url: URL) throws {
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
    static func writePNG(_ image: RGBAImage, to url: URL) throws { try write(try XCTUnwrap(cgImage(image)), to: url) }
    /// The map as Visualize Spots shows it at strength 0.5 (gain 20, gamma 2.2), at full size.
    static func writeMapPNG(_ d: [Float], _ w: Int, _ h: Int, to url: URL) throws {
        var image = RGBAImage(width: w, height: h)
        for i in 0..<(w * h) {
            let v = UInt8(min(1, max(0, pow(20 * d[i], 1 / 1.0))) * 255)
            image.pixels[i * 4] = v; image.pixels[i * 4 + 1] = v; image.pixels[i * 4 + 2] = v; image.pixels[i * 4 + 3] = 255
        }
        try writePNG(image, to: url)
    }
    static let colors: [String: CGColor] = ["classic6": CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1), "classic20": CGColor(red: 1, green: 0.8, blue: 0, alpha: 1),
                                            "map": CGColor(red: 0.1, green: 1, blue: 0.3, alpha: 1), "list": CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1)]
    static func writeOverlay(_ image: RGBAImage, methods: [String: [Found]], to url: URL) throws {
        let cg = try XCTUnwrap(cgImage(image))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.setLineWidth(3)
        for (offset, key) in methods.keys.sorted().enumerated() {
            ctx.setStrokeColor(colors[key] ?? CGColor(red: 0, green: 0.6, blue: 1, alpha: 1))
            for s in methods[key]! {
                let r = s.r + 6 + Double(offset) * 5
                ctx.strokeEllipse(in: CGRect(x: s.x - r, y: Double(image.height) - s.y - r, width: 2 * r, height: 2 * r))
            }
        }
        try write(try XCTUnwrap(ctx.makeImage()), to: url)
    }
}

extension DustMapReviewTests {
    /// Circles from a JSON list ([{x, y, r, score?}]) on a PNG; CEVICHE_DUST_DRAW="in.png:list.json:out.png[:scale]".
    func testDrawList() throws {
        guard let spec = ProcessInfo.processInfo.environment["CEVICHE_DUST_DRAW"] else { throw XCTSkip("Set CEVICHE_DUST_DRAW") }
        let parts = spec.split(separator: ":").map(String.init)
        let image = try XCTUnwrap(Self.readPNG(URL(fileURLWithPath: parts[0])))
        let list = try JSONDecoder().decode([Found].self, from: Data(contentsOf: URL(fileURLWithPath: parts[1])))
        let scale = parts.count > 3 ? Double(parts[3])! : 1
        let scaled = list.map { Found(x: $0.x * scale, y: $0.y * scale, r: $0.r * scale, score: $0.score) }
        try Self.writeOverlay(image, methods: ["list": scaled], to: URL(fileURLWithPath: parts[2]))
    }
}
