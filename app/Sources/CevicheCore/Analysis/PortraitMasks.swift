import CoreImage
import Vision

public enum PortraitCorrection: String, Codable, Sendable, CaseIterable {
    case shine
    /// Portrait › Details: small corrections on one feature, each measured from that feature's own pixels.
    case teeth, eyes, lips, brows
    public var title: String {
        switch self {
        case .shine: return L10n.tr("Reduce shine")
        case .teeth: return PersonPart.teeth.localizedTitle
        // Named for what it mostly changes, apart from Facial Features' eye shape.
        case .eyes: return L10n.tr("Eye whites")
        case .lips: return PersonPart.lips.localizedTitle
        case .brows: return PersonPart.eyebrows.localizedTitle
        }
    }
    /// In Portrait › Details rather than Light.
    public var isDetail: Bool { self != .shine }
    public static let details: [PortraitCorrection] = [.teeth, .eyes, .lips, .brows]
}

extension RawRenderer {
    /// Analyze the recorded light (`sceneLight`) in retouch coordinates. Preserve the matte as an ordinary editable local mask.
    /// Shine is white light reflected on top of the skin's colour, so it is taken out with Dehaze (which removes a white
    /// veil and gives the colour back) and lower Highlights, not darkened: darkening a near-white highlight only turns
    /// it grey. With the People model the matte keeps to facial skin, so eyes, brows, lips and teeth are never touched.
    /// One mask for each of `faces` (Vision face boxes; every face when nil), each measured on its own and tagged with
    /// its face, or one untagged mask for `region` when a face region was drawn.
    public func portraitMask(_ kind: PortraitCorrection, settings: Adjustments, region: CGRect?, faces: [CGRect]? = nil) async throws -> [PhotoMask] {
        var base = settings
        base.masks.removeAll { $0.portraitCorrection == kind }
        let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        let targets: [(box: CGRect, face: CGRect?)] = try region.map { [($0, nil)] }
            ?? (faces ?? portraitFaceBoxes(base)).map { ($0.insetBy(dx: -$0.width * 0.15, dy: -$0.height * 0.08), $0) }
        let (light, w, h) = try sceneLight(base, maxDimension: 1600)
        let people = BundledModel.peopleParts.isAvailable ? try peopleInPhoto() : []
        var masks: [PhotoMask] = []
        for target in targets {
            try Task.checkCancellation()
            let box = target.box.intersection(bounds)
            guard !box.isEmpty else { continue }
            var matte = [UInt16](repeating: 0, count: w*h)
            // Facial skin of the person whose face this is, at the image's pixels (rows top down), when the model is there.
            var skin: [Float]?
            if let person = people.first(where: { $0.box.contains(CGPoint(x: box.midX, y: box.midY)) }) {
                let face = try await selection(.people, people: PeopleSelection(box: person.box, parts: [.faceSkin]))
                if let raster = face.raster, let skinMatte = MaskRaster.image(from: raster) {
                    let placed = skinMatte.transformed(by: CGAffineTransform(scaleX: Double(w) / skinMatte.extent.width, y: Double(h) / skinMatte.extent.height))
                    var values = [Float](repeating: 0, count: w * h)
                    values.withUnsafeMutableBytes { context.render(placed, toBitmap: $0.baseAddress!, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .Rf, colorSpace: nil) }
                    skin = values
                }
            }
            // With facial skin known, all of it counts (lips, teeth, eyes and brows lie outside it), reaching up over the
            // forehead past Vision's box; without it, ovals on forehead, nose and cheeks.
            let area = skin == nil ? box : CGRect(x: box.minX, y: box.minY, width: box.width, height: box.height * 1.35).intersection(bounds)
            var samples: [(index: Int, luma: Double, white: Double, weight: Double)] = []
            for y in max(0, Int((1-area.maxY)*Double(h)))..<min(h, Int(ceil((1-area.minY)*Double(h)))) {
                for x in max(0, Int(area.minX*Double(w)))..<min(w, Int(ceil(area.maxX*Double(w)))) {
                    let i = y*w+x, j = i*4
                    var weight: Double
                    let u = ((Double(x)+0.5)/Double(w)-box.minX)/box.width
                    let v = ((Double(y)+0.5)/Double(h)-1+box.maxY)/box.height
                    func oval(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> Double {
                        let distance = hypot((u-cx)/rx, (v-cy)/ry)
                        return min(1, max(0, (1-distance)*4))
                    }
                    if let skin {
                        // Facial skin can take in an open mouth: teeth are never shine.
                        weight = Double(min(1, max(0, skin[i]))) * (1 - oval(0.5, 0.8, 0.28, 0.14))
                    } else {
                        // The nose's oval stops above the mouth, so teeth never count as shine.
                        weight = max(oval(0.5,0.17,0.29,0.17), oval(0.5,0.45,0.09,0.15), oval(0.28,0.58,0.16,0.13), oval(0.72,0.58,0.16,0.13))
                    }
                    guard weight > 0.05 else { continue }
                    let r = Double(max(0, light[j])), g = Double(max(0, light[j+1])), b = Double(max(0, light[j+2]))
                    let luma = 0.2126*r + 0.7152*g + 0.0722*b
                    // Reflected light is white: it lifts the skin's weakest channel toward its strongest.
                    let white = min(r, g, b) / max(1e-4, max(r, g, b))
                    samples.append((i, luma, white, weight))
                }
            }
            guard samples.count > 16 else { continue }
            // Each face against its own skin: brighter and whiter than its typical skin is shine, so oil spread over
            // most of a face is found as well as a single highlight, and a face in shade isn't judged by a lit one.
            let lumas = samples.map(\.luma).sorted(), whites = samples.map(\.white).sorted()
            let lumaMid = lumas[lumas.count*6/10], lumaPeak = lumas[lumas.count*98/100]
            let whiteMid = whites[whites.count*6/10], whitePeak = whites[whites.count*98/100]
            for pixel in samples {
                let bright = min(1, max(0, (pixel.luma-lumaMid)/max(0.05,lumaPeak-lumaMid)))
                let pale = min(1, max(0, (pixel.white-whiteMid)/max(0.04,whitePeak-whiteMid)))
                let t = (bright * pale).squareRoot()
                matte[pixel.index] = UInt16(65535 * pixel.weight * t*t*(3-2*t))
            }
            var mask = PhotoMask(kind: .object)
            mask.name = kind.title; mask.portraitCorrection = kind; mask.feather = 0.001; mask.face = target.face
            mask.raster = try MaskRaster.encode(matte, width: w, height: h)
            mask.adjustments.dehaze = 70
            mask.adjustments.highlights = -40
            mask.opacity = 0.8
            masks.append(mask)
        }
        return masks
    }
}

extension RawRenderer {
    /// The light the camera recorded, in the retouch frame: linear sRGB floats (RGBA, row 0 at the top), unclipped,
    /// with the photo's white balance and lens correction but none of its tone or colour edits. Shine is measured here:
    /// on the developed photo, raised exposure or highlights would show oil where the camera saw none.
    func sceneLight(_ settings: Adjustments, maxDimension: Double) throws -> (pixels: [Float], width: Int, height: Int) {
        var neutral = Adjustments()
        neutral.temperature = settings.temperature; neutral.tint = settings.tint
        neutral.lensCorrection = settings.lensCorrection; neutral.faceLiquify = settings.faceLiquify
        // The decoder's linear light without its tone curve, as for ACES.
        neutral.aces = true
        let image = try beforeRetouch(neutral, maxDimension: maxDimension).image
        let extent = image.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        guard w > 0, h > 0 else { throw EditorError.render }
        var pixels = [Float](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: extent, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        }
        return (pixels, w, h)
    }
    /// Under daylight, cheeks measure about this red over blue (sRGB): ID Photo's centre for compliant photos.
    static let daylightSkinRedOverBlue = 1.7

    /// The whole photo's white balance from its face: the light's cast measured on the cheeks and taken out of every
    /// pixel, as ID Photo balances its subject. Only warm–cool is solved; green–magenta stays as shot, since skin alone
    /// can't tell a tint from a complexion. Temperature moves in mireds, which respond evenly across the range. The
    /// low-level steps repeat ID Photo's on purpose: the two flows may part ways. Nil without a face or when the
    /// balance doesn't respond.
    public func faceLightBalance(_ settings: Adjustments, region: CGRect?) throws -> Adjustments? {
        var base = settings
        guard let found = try region ?? detectedPortraitRegion(base, fitCheeks: false) else { return nil }
        let box = found.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !box.isEmpty else { return nil }
        // Both cheeks, below the eyes and beside the nose (y up, in Vision's face box).
        let cheeks = [0.22, 0.60].map { CGRect(x: box.minX + box.width * $0, y: box.minY + box.height * 0.32, width: box.width * 0.18, height: box.height * 0.16) }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func cast(_ a: Adjustments) throws -> SIMD2<Double>? {
            var plain = a; plain.geometry = GeometryAdjustments(); plain.quarterTurns = 0
            let image = try pipeline(plain, maxDimension: 800), e = image.extent
            var sum = SIMD3<Double>.zero
            for cheek in cheeks {
                let rect = CGRect(x: e.minX + cheek.minX * e.width, y: e.minY + cheek.minY * e.height, width: cheek.width * e.width, height: cheek.height * e.height).integral.intersection(e)
                guard rect.width >= 1, rect.height >= 1 else { return nil }
                var pixel = [Float](repeating: 0, count: 4)
                let mean = image.cropped(to: rect).applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
                pixel.withUnsafeMutableBytes { context.render(mean, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: space) }
                sum += SIMD3(Double(pixel[0]), Double(pixel[1]), Double(pixel[2]))
            }
            let r = max(1e-3, sum.x), g = max(1e-3, sum.y), b = max(1e-3, sum.z)
            return SIMD2(log(r / b), log(g / (r * b).squareRoot()))
        }
        guard let asShot = try cast(base) else { return nil }
        let target = SIMD2(log(Self.daylightSkinRedOverBlue), asShot.y)
        func get(_ a: Adjustments) -> SIMD2<Double> { SIMD2(1e6 / max(1, a.temperature), a.tint) }
        func set(_ a: inout Adjustments, _ value: SIMD2<Double>) {
            a.temperature = (1e6 / min(500, max(20, value.x))).rounded()
            a.tint = min(150, max(-150, value.y)).rounded()
        }
        func error(_ a: Adjustments) throws -> SIMD2<Double>? { try cast(a).map { $0 - target } }
        var current = base
        guard var e = try error(current) else { return nil }
        let start = get(current), step = SIMD2<Double>(15, 10)
        var nudged = current; set(&nudged, start + SIMD2(step.x, 0)); guard let ex = try error(nudged) else { return nil }
        nudged = current; set(&nudged, start + SIMD2(0, step.y)); guard let ey = try error(nudged) else { return nil }
        let a = (ex - e) / step.x, b = (ey - e) / step.y
        let determinant = a.x * b.y - b.x * a.y
        guard abs(determinant) > 1e-9 else { return nil }
        // Settled enough that pressing it again barely moves it.
        for _ in 0..<8 {
            guard abs(e.x) > 0.002 || abs(e.y) > 0.002 else { break }
            let delta = SIMD2((-e.x * b.y + b.x * e.y) / determinant, (-a.x * e.y + a.y * e.x) / determinant)
            set(&current, get(current) + delta)
            guard let next = try error(current) else { break }
            e = next
        }
        var result = settings
        result.temperature = current.temperature; result.tint = current.tint
        return result
    }
}

extension RawRenderer {
    /// Portrait › Details: the feature's People mask on the largest person, with a correction measured from the
    /// feature's own pixels, kept small so it reads as the same person on a good day:
    /// - Teeth: their colour taken part of the way toward a slight natural warmth (never neutral white), and a little
    ///   lighter when they are dark.
    /// - Eyes: redness taken out of the whites and a little light added; the iris gets a touch of clarity (two masks).
    /// - Lips: vibrance, less the more colourful they already are.
    /// - Brows: darker, more when they barely stand out from the skin around them.
    /// Nil when nobody is found; empty when the feature isn't visible (teeth behind closed lips).
    /// `visible` says whether the feature showed on anyone, so no masks can mean "nothing to correct" or "not seen".
    public func portraitDetail(_ kind: PortraitCorrection, settings: Adjustments, faces: [CGRect]? = nil) async throws -> (masks: [PhotoMask], visible: Bool)? {
        guard kind.isDetail else { return nil }
        let people = try peopleInPhoto()
        guard !people.isEmpty else { return nil }
        var base = settings
        base.geometry = GeometryAdjustments(); base.quarterTurns = 0; base.masks = []; base.postCropVignette = PostCropVignette()
        let photo = try pipeline(base, maxDimension: 1600)
        let groups: [[PersonPart]] = kind == .eyes ? [[.sclera], [.iris]] : [[kind == .teeth ? .teeth : kind == .lips ? .lips : .eyebrows]]
        // Each face with the person it belongs to; without faces given, the largest person, untagged.
        let targets: [(person: PersonCandidate, face: CGRect?)] = faces.map { faces in
            faces.compactMap { face in people.first { $0.box.contains(CGPoint(x: face.midX, y: face.midY)) }.map { ($0, face) } }
        } ?? [(people.max { $0.box.width * $0.box.height < $1.box.width * $1.box.height }!, nil)]
        var masks: [PhotoMask] = [], visible = false
        for (person, face) in targets { for parts in groups {
            try Task.checkCancellation()
            var mask = try await selection(.people, people: PeopleSelection(box: person.box, parts: parts))
            guard let raster = mask.raster, let matte = MaskRaster.image(from: raster),
                  let stats = Self.featureStats(matte, on: photo, context: context) else { continue }
            visible = true
            var a = LocalAdjustments()
            switch parts[0] {
            case .teeth:
                // Saturation scales colourfulness: keep a chroma of about 10, a little warm, as real teeth are.
                if stats.chroma > 10 { a.saturation = -min(60, (1 - 10 / stats.chroma) * 100) }
                // Only when they show as teeth: a dark mouth's shadow is not lifted.
                if stats.lightness > 35 { a.exposure = Self.lift(from: stats.lightness, toward: 75, by: 8, cap: 0.35) }
            case .sclera:
                if stats.chroma > 6 { a.saturation = -min(50, (1 - 6 / stats.chroma) * 100) }
                // Only where the whites show: squinting eyes are mostly lashes and shadow.
                if stats.lightness > 45 { a.exposure = Self.lift(from: stats.lightness, toward: 85, by: 6, cap: 0.25) }
            case .iris:
                a.clarity = 15; a.exposure = 0.1
            case .lips:
                // Lips already this colourful are left as they are.
                a.vibrance = min(20, max(0, (45 - stats.chroma) * 0.6))
                if a.vibrance < 3 { a.vibrance = 0 }
            default:
                // Brows against the skin just around them.
                let ring = matte.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: max(3, matte.extent.width / 120)])
                    .applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: matte])
                let skin = Self.featureStats(ring, on: photo, context: context)?.lightness ?? stats.lightness
                let contrast = max(0, (skin - stats.lightness) / max(1, skin))
                a.exposure = -min(0.35, max(0.1, 0.1 + (0.4 - contrast) * 0.6))
            }
            // Nothing measured to correct: no mask, so Auto can say the feature looks fine.
            if a == LocalAdjustments() { continue }
            mask.name = parts == [.iris] ? PersonPart.iris.localizedTitle : kind.title
            mask.portraitCorrection = kind
            mask.face = face
            mask.adjustments = a
            masks.append(mask)
        } }
        return (masks, visible)
    }

    /// Exposure that brings `lightness` (CIE L*) `by` toward `target`, never past it, at most `cap` stops.
    static func lift(from lightness: Double, toward target: Double, by step: Double, cap: Double) -> Double {
        guard lightness < target else { return 0 }
        func luminance(_ l: Double) -> Double { l > 8 ? pow((l + 16) / 116, 3) : l / 903.3 }
        let goal = min(target, lightness + step)
        return min(cap, max(0, log2(luminance(goal) / max(1e-4, luminance(lightness)))))
    }

    /// The mean colour of the pixels a matte covers (weights over 0.3), in CIE L*, and its chroma. Nil for fewer than
    /// 30 pixels.
    static func featureStats(_ matte: CIImage, on photo: CIImage, context: CIContext) -> (lightness: Double, chroma: Double)? {
        let e = photo.extent, w = Int(e.width), h = Int(e.height)
        let placed = matte.transformed(by: CGAffineTransform(scaleX: e.width / matte.extent.width, y: e.height / matte.extent.height))
            .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY)).cropped(to: e)
        var weight = [Float](repeating: 0, count: w * h), rgb = [UInt8](repeating: 0, count: w * h * 4)
        weight.withUnsafeMutableBytes { context.render(placed, toBitmap: $0.baseAddress!, rowBytes: w * 4, bounds: e, format: .Rf, colorSpace: nil) }
        rgb.withUnsafeMutableBytes { context.render(photo, toBitmap: $0.baseAddress!, rowBytes: w * 4, bounds: e, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) }
        var sum = 0.0, l = 0.0, a = 0.0, b = 0.0, count = 0
        for i in 0..<(w * h) where weight[i] > 0.3 {
            let lab = Self.lab(Double(rgb[i * 4]) / 255, Double(rgb[i * 4 + 1]) / 255, Double(rgb[i * 4 + 2]) / 255)
            let v = Double(weight[i]); sum += v; l += lab.0 * v; a += lab.1 * v; b += lab.2 * v; count += 1
        }
        guard count >= 30, sum > 0 else { return nil }
        return (l / sum, hypot(a / sum, b / sum))
    }

    /// CIE L*a*b* (D65) of encoded sRGB.
    static func lab(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let R = linear(r), G = linear(g), B = linear(b)
        let x = (0.4124 * R + 0.3576 * G + 0.1805 * B) / 0.95047, y = 0.2126 * R + 0.7152 * G + 0.0722 * B, z = (0.0193 * R + 0.1192 * G + 0.9505 * B) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }
}

/// A face Portrait can work on: its box (normalized to the retouch frame, origin bottom left) and a picture of it.
public struct PortraitFace: Identifiable, Sendable {
    public let id: Int
    public let box: CGRect
    public let thumbnail: CGImage
    /// Whether a correction tagged with `tag` belongs to one of `faces`: untagged ones belong to everyone.
    public static func covers(_ tag: CGRect?, _ faces: [CGRect]) -> Bool {
        guard let tag else { return true }
        return faces.contains { $0.contains(CGPoint(x: tag.midX, y: tag.midY)) || tag.contains(CGPoint(x: $0.midX, y: $0.midY)) }
    }
}

extension RawRenderer {
    /// Every face Vision finds, left to right.
    func portraitFaceBoxes(_ settings: Adjustments) throws -> [CGRect] {
        var base = settings
        base.geometry = GeometryAdjustments(); base.quarterTurns = 0; base.faceLiquify = nil; base.masks = []
        let image = try pipeline(base, maxDimension: 1600)
        return try FaceDetection.faces(ciImage: image).map(\.boundingBox).sorted { $0.minX < $1.minX }
    }
    /// Every face with a small square picture of it, for Portrait's people row.
    public func portraitFaces(_ settings: Adjustments) throws -> [PortraitFace] {
        var base = settings
        base.geometry = GeometryAdjustments(); base.quarterTurns = 0; base.faceLiquify = nil; base.masks = []
        let image = try pipeline(base, maxDimension: 1600)
        let e = image.extent
        let boxes = try FaceDetection.faces(ciImage: image).map(\.boundingBox).sorted { $0.minX < $1.minX }
        return boxes.enumerated().compactMap { index, box in
            let side = max(box.width * e.width, box.height * e.height) * 1.5
            let crop = CGRect(x: e.minX + box.midX * e.width - side / 2, y: e.minY + box.midY * e.height - side / 2, width: side, height: side).integral.intersection(e)
            let scale = 96 / max(1, crop.width)
            let piece = image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY).scaledBy(x: scale, y: scale), highQualityDownsample: true)
            guard let thumbnail = context.createCGImage(piece, from: piece.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
            return PortraitFace(id: index, box: box, thumbnail: thumbnail)
        }
    }
}
