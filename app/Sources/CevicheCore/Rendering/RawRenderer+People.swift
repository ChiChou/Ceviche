import CoreGraphics
import CoreImage
import CoreML
import Vision

/// A person Vision found, for the People mask's choice: where they are and a face to recognize them by.
public struct PersonCandidate: Sendable, Identifiable {
    public let id: Int
    /// Normalized, bottom-left origin.
    public let box: CGRect
    public let thumbnail: CGImage
}

extension RawRenderer {
    /// Vision's person masks (at most four people) on the as-shot development, with each one's box.
    private func personInstances(_ source: CIImage) throws -> [(mask: CIImage, box: CGRect)] {
        let handler = VNImageRequestHandler(ciImage: source, options: [:])
        let request = VNGeneratePersonInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first else { return [] }
        let extent = source.extent
        return try observation.allInstances.compactMap { index in
            let buffer = try observation.generateScaledMaskForImage(forInstances: IndexSet(integer: index), from: handler)
            let mask = CIImage(cvPixelBuffer: buffer)
            let scaled = mask.transformed(by: CGAffineTransform(scaleX: extent.width / mask.extent.width, y: extent.height / mask.extent.height))
            guard let box = Self.coverage(buffer) else { return nil }
            return (scaled, box)
        }.sorted { $0.box.midX < $1.box.midX }
    }
    /// The normalized box (bottom-left origin) of a mask's pixels above one half.
    private static func coverage(_ buffer: CVPixelBuffer) -> CGRect? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        let half = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent16Half
        var x0 = w, y0 = h, x1 = -1, y1 = -1
        for y in 0..<h {
            let line = base + y * row
            for x in 0..<w {
                let v = half ? Float(line.assumingMemoryBound(to: Float16.self)[x]) : line.assumingMemoryBound(to: Float.self)[x]
                if v > 0.5 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) }
            }
        }
        guard x1 >= 0 else { return nil }
        // Rows run top down in the buffer.
        return CGRect(x: Double(x0) / Double(w), y: 1 - Double(y1 + 1) / Double(h), width: Double(x1 - x0 + 1) / Double(w), height: Double(y1 - y0 + 1) / Double(h))
    }

    /// The people in the photo, left to right, each with a thumbnail of their face (or the top of their box).
    public func peopleInPhoto() throws -> [PersonCandidate] {
        let source = try pipeline(info.defaults, maxDimension: 3000)
        let instances = try personInstances(source)
        guard !instances.isEmpty else { return [] }
        let faces = try FaceDetection.faces(ciImage: source)
        let extent = source.extent
        return instances.enumerated().compactMap { index, instance in
            let face = faces.map(\.boundingBox).filter { instance.box.contains(CGPoint(x: $0.midX, y: $0.midY)) }.max { $0.width < $1.width }
            // A square around the face, or the top of the person when no face shows.
            let b = instance.box
            let around = face.map { f in
                let side = max(f.width * extent.width, f.height * extent.height) * 1.6
                return CGRect(x: f.midX * extent.width - side / 2, y: f.midY * extent.height - side / 2, width: side, height: side)
            } ?? {
                let side = min(b.width * extent.width, b.height * extent.height)
                return CGRect(x: b.midX * extent.width - side / 2, y: b.maxY * extent.height - side, width: side, height: side)
            }()
            let crop = around.intersection(extent)
            guard !crop.isEmpty else { return nil }
            let scale = 160 / max(crop.width, crop.height)
            let thumb = source.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY).scaledBy(x: scale, y: scale), highQualityDownsample: true)
            guard let image = context.createCGImage(thumb, from: thumb.extent.integral, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
            return PersonCandidate(id: index, box: b, thumbnail: image)
        }
    }

    /// One person's parts as a full-resolution matte of the photo: the whole person from Vision; skin, hair and clothes
    /// from the people-parts model on a crop around them, cut to their person mask so nobody else's comes along and
    /// snapped to the photo's edges; the face's features drawn from Vision's landmarks and checked against its pixels.
    /// The person Vision finds again at `box`, where the mask was chosen.
    private func person(at box: CGRect, source: CIImage) throws -> (mask: CIImage, box: CGRect) {
        func overlap(_ a: CGRect, _ b: CGRect) -> Double {
            let i = a.intersection(b)
            return i.isNull ? 0 : i.width * i.height / (a.width * a.height + b.width * b.height - i.width * i.height)
        }
        guard let person = try personInstances(source).max(by: { overlap($0.box, box) < overlap($1.box, box) }), overlap(person.box, box) > 0.3 else {
            throw EditorError.invalidDocument(L10n.tr("That person was not found in this photo."))
        }
        return person
    }

    /// Every part of one person tinted over the framed photo, for the chooser to show on hover at once: the photo is
    /// developed, the person found and the face traced once for all of them.
    public func peoplePreviews(_ box: CGRect, adjustments: Adjustments, parts: [PersonPart]) throws -> [PersonPart: CGImage] {
        let source = try pipeline(info.defaults, maxDimension: 3000)
        let person = try person(at: box, source: source)
        var mattes: [PersonPart: CIImage] = [:]
        if parts.contains(.entire) { mattes[.entire] = person.mask }
        let modelled = parts.filter { $0.channel != nil }
        if !modelled.isEmpty, BundledModel.peopleParts.isAvailable {
            try Task.checkCancellation()
            for (part, matte) in zip(modelled, try modelParts(groups: modelled.map { [$0.channel!] }, person: person, source: source)) {
                mattes[part] = MaskRefinement.edgeAware.apply(matte, guide: source)
            }
        }
        let facial = parts.filter(\.isFacial)
        if !facial.isEmpty, let face = try? faceFeatureMattes(facial, person: person.box, source: source) { mattes.merge(face) { $1 } }
        let framed = adjustments.geometry != GeometryAdjustments() || adjustments.quarterTurns != 0
        let tint = CIImage(color: CIColor(red: 1, green: 0.15, blue: 0.1, alpha: 0.45))
        let scale = min(1, 1600 / max(source.extent.width, source.extent.height))
        var out: [PersonPart: CGImage] = [:]
        for (part, matte) in mattes {
            try Task.checkCancellation()
            var m = matte.transformed(by: CGAffineTransform(scaleX: scale, y: scale), highQualityDownsample: true)
            if framed { m = try GeometryPlan(size: m.extent.size, settings: adjustments.geometry, quarterTurns: adjustments.quarterTurns).apply(to: m) }
            let overlay = tint.cropped(to: m.extent).applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: m.extent), kCIInputMaskImageKey: m])
            if let image = context.createCGImage(overlay, from: overlay.extent, format: .RGBA8, colorSpace: RGBProfile.sRGB.space) { out[part] = image }
        }
        return out
    }

    func peopleMatte(_ people: PeopleSelection, source: CIImage) throws -> (matte: CIImage, refined: Bool) {
        let person = try person(at: people.box, source: source)
        if people.parts.contains(.entire) { return (person.mask, false) }
        let extent = source.extent
        var matte = CIImage(color: .black).cropped(to: extent)
        let channels = people.parts.compactMap(\.channel)
        if !channels.isEmpty {
            // The model's parts at 1024, snapped to the photo's edges here, so they join the face's full-resolution parts.
            let coarse = try modelParts(channels, person: person, source: source)
            matte = MaskRefinement.edgeAware.apply(coarse, guide: source)
        }
        let facial = people.parts.filter(\.isFacial)
        if !facial.isEmpty {
            matte = try faceFeatures(facial, person: person.box, source: source)
                .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: matte]).cropped(to: extent)
        }
        guard !channels.isEmpty || !facial.isEmpty else { throw EditorError.invalidDocument(L10n.tr("Choose what to select.")) }
        return (matte, false)
    }

    /// The people-parts model's chosen classes for one person, cut to them, at 1024 on the long side.
    private func modelParts(_ channels: [Int], person: (mask: CIImage, box: CGRect), source: CIImage) throws -> CIImage {
        try modelParts(groups: [channels], person: person, source: source)[0]
    }
    /// One matte per group of channels, from a single run of the model.
    private func modelParts(groups: [[Int]], person: (mask: CIImage, box: CGRect), source: CIImage) throws -> [CIImage] {
        let extent = source.extent
        // The person's box with some room (hair and hands reach past the mask's box less often than not), as a square.
        let b = person.box
        let side = max(b.width * extent.width, b.height * extent.height) * 1.15
        let crop = CGRect(x: b.midX * extent.width - side / 2, y: b.midY * extent.height - side / 2, width: side, height: side).integral.intersection(extent)
        let request = VNCoreMLRequest(model: try BundledModelCache.shared.visionModel(.peopleParts))
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(ciImage: source.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY)), options: [:]).perform([request])
        guard let array = (request.results?.first as? VNCoreMLFeatureValueObservation)?.featureValue.multiArrayValue,
              array.shape.count == 4, array.shape[1].intValue == 6 else { throw EditorError.invalidDocument(L10n.tr("People segmentation returned no result.")) }
        let rows = array.shape[2].intValue, columns = array.shape[3].intValue, s = array.strides.map(\.intValue)
        let pointer = array.dataPointer
        let black = CIImage(color: .black).cropped(to: extent)
        // Cut to this person: the person mask, grown a few pixels so hair edges the two disagree on stay.
        let personMask = person.mask.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: max(2, extent.width / 600)]).cropped(to: extent)
        return groups.map { channels in
            var values = [Float](repeating: 0, count: rows * columns)
            // The chosen parts against the strongest other class: a pixel they win is in, whatever its share, since the
            // model often splits a face between face and body skin; within ±0.2 of a tie it fades.
            let chosen = Set(channels)
            for y in 0..<rows { for x in 0..<columns {
                var mine: Float = 0, other: Float = 0
                for c in 0..<6 {
                    let i = c * s[1] + y * s[2] + x * s[3]
                    let p = array.dataType == .float16 ? Float(pointer.assumingMemoryBound(to: Float16.self)[i]) : pointer.assumingMemoryBound(to: Float.self)[i]
                    if chosen.contains(c) { mine += p } else { other = max(other, p) }
                }
                let t = max(0, min(1, (mine - other + 0.2) / 0.4))
                values[y * columns + x] = t * t * (3 - 2 * t)
            } }
            // Rows top down; CIImage from a bitmap puts row 0 at the top.
            // A one-channel bitmap is red alone; the matte is grey, read as luminance when stored.
            let parts = CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: columns * 4, size: CGSize(width: columns, height: rows), format: .Rf, colorSpace: nil)
                .applyingFilter("CIColorMatrix", parameters: ["inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0)])
                .transformed(by: CGAffineTransform(translationX: crop.minX, y: crop.minY).scaledBy(x: crop.width / Double(columns), y: crop.height / Double(rows)))
            let placed = parts.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: black]).cropped(to: extent)
            var matte = placed.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: personMask]).cropped(to: extent)
            let scale = 1024 / max(extent.width, extent.height)
            if scale < 1 { matte = matte.transformed(by: CGAffineTransform(scaleX: scale, y: scale), highQualityDownsample: true) }
            return matte.transformed(by: CGAffineTransform(translationX: -matte.extent.minX, y: -matte.extent.minY))
        }
    }

    /// The chosen features of the face that belongs to `person`, from Vision's landmarks on a crop around it at the
    /// photo's resolution, each checked against the pixels: brows darker than the cheek, teeth paler and lighter than
    /// the lips around them. Soft at the edge by a fraction of the eye's width.
    private func faceFeatures(_ parts: [PersonPart], person: CGRect, source: CIImage) throws -> CIImage {
        let black = CIImage(color: .black).cropped(to: source.extent)
        return try faceFeatureMattes(parts, person: person, source: source).values.reduce(black) {
            $1.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: $0]).cropped(to: source.extent)
        }
    }
    /// Each chosen feature of the face that belongs to `person`, as its own matte.
    private func faceFeatureMattes(_ parts: [PersonPart], person: CGRect, source: CIImage) throws -> [PersonPart: CIImage] {
        let extent = source.extent, W = extent.width, H = extent.height
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(ciImage: source, options: [:]).perform([request])
        guard let face = (request.results ?? []).filter({ person.contains(CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY)) })
                .max(by: { $0.boundingBox.width < $1.boundingBox.width }), let marks = face.landmarks else {
            throw EditorError.invalidDocument(L10n.tr("No face was found for that person."))
        }
        let size = CGSize(width: W, height: H)
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] { region?.pointsInImage(imageSize: size) ?? [] }
        let b = face.boundingBox
        let crop = CGRect(x: (b.midX - b.width * 0.9) * W, y: (b.midY - b.height * 0.9) * H, width: b.width * 1.8 * W, height: b.height * 1.8 * H)
            .integral.intersection(extent)
        let cw = Int(crop.width), ch = Int(crop.height)
        guard cw > 8, ch > 8 else { throw EditorError.invalidDocument(L10n.tr("No face was found for that person.")) }
        // The crop's pixels, encoded sRGB, rows bottom up to match the drawing context below.
        var rgba = [UInt8](repeating: 0, count: cw * ch * 4)
        rgba.withUnsafeMutableBytes { buffer in
            context.render(source, toBitmap: buffer.baseAddress!, rowBytes: cw * 4, bounds: crop, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        func pixel(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
            // Core Image writes rows top down.
            let i = ((ch - 1 - y) * cw + x) * 4
            return (Double(rgba[i]) / 255, Double(rgba[i + 1]) / 255, Double(rgba[i + 2]) / 255)
        }
        func luma(_ p: (r: Double, g: Double, b: Double)) -> Double { 0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b }
        func saturation(_ p: (r: Double, g: Double, b: Double)) -> Double { let m = max(p.r, p.g, p.b); return m > 0 ? (m - min(p.r, p.g, p.b)) / m : 0 }
        // Each feature drawn on its own grey layer, in the crop's coordinates (origin bottom left).
        func layer(_ draw: (CGContext) -> Void) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: cw * ch)
            bytes.withUnsafeMutableBytes { buffer in
                guard let c = CGContext(data: buffer.baseAddress, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw,
                                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
                c.translateBy(x: -crop.minX, y: -crop.minY)
                c.setFillColor(gray: 1, alpha: 1); c.setStrokeColor(gray: 1, alpha: 1)
                draw(c)
            }
            // CGContext's rows run top down in memory; flip to bottom up like `pixel`.
            var flipped = bytes
            for y in 0..<ch { flipped.replaceSubrange(y * cw..<(y + 1) * cw, with: bytes[(ch - 1 - y) * cw..<(ch - y) * cw]) }
            return flipped
        }
        func polygon(_ c: CGContext, _ p: [CGPoint]) { guard p.count > 2 else { return }; c.addLines(between: p); c.closePath() }
        // The face's outline: the face mesh's 478 points when that model is installed (lips, eyes and irises traced
        // closely), else Vision's landmarks, coarser and prone to drift on a wide-open mouth.
        var outline = FaceOutline(eyes: [points(marks.leftEye), points(marks.rightEye)].filter { $0.count > 2 },
                                  irises: [], brows: [points(marks.leftEyebrow), points(marks.rightEyebrow)].filter { $0.count > 1 },
                                  browsAreShapes: false, outerLips: points(marks.outerLips), innerLips: points(marks.innerLips), precise: false)
        let visionPupils = [points(marks.leftPupil).first, points(marks.rightPupil).first]
        outline.irises = zip(outline.eyes, visionPupils).compactMap { eye, pupil in
            pupil.map { ($0, 0.19 * (eye.map(\.x).max()! - eye.map(\.x).min()!)) }
        }
        if let mesh = try? faceMesh(face: b, source: source) { outline = mesh }
        let eyes = outline.eyes
        let eyeWidth = eyes.map { e in (e.map(\.x).max()! - e.map(\.x).min()!) }.max() ?? b.width * W * 0.2
        // Cheek skin, for the brows' gate: the band below the eyes, across the middle of the face.
        var cheek: [Double] = []
        let cheekBand = CGRect(x: (b.minX + b.width * 0.2) * W - crop.minX, y: (b.minY + b.height * 0.3) * H - crop.minY, width: b.width * 0.6 * W, height: b.height * 0.12 * H)
        for y in stride(from: max(0, Int(cheekBand.minY)), to: min(ch, Int(cheekBand.maxY)), by: 2) {
            for x in stride(from: max(0, Int(cheekBand.minX)), to: min(cw, Int(cheekBand.maxX)), by: 2) { cheek.append(luma(pixel(x, y))) }
        }
        cheek.sort()
        let skin = cheek.isEmpty ? 0.5 : cheek[cheek.count / 2]

        // Each part on its own layer, so one pass over the face serves every part (the chooser's previews).
        var outs: [PersonPart: [UInt8]] = [:]
        func add(_ part: PersonPart, _ values: [UInt8], gate: ((Int, Int) -> Double)? = nil) {
            var out = outs[part] ?? [UInt8](repeating: 0, count: cw * ch)
            for y in 0..<ch { for x in 0..<cw {
                let i = y * cw + x
                guard values[i] > 0 else { continue }
                let v = Double(values[i]) * (gate?(x, y) ?? 1)
                out[i] = max(out[i], UInt8(min(255, v)))
            } }
            outs[part] = out
        }
        func iris(_ c: CGContext, grow: Double) {
            for (center, radius) in outline.irises {
                let r = radius * grow
                c.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
            }
        }
        if parts.contains(.iris) {
            add(.iris, layer { c in
                for eye in eyes { polygon(c, eye) }
                c.clip()
                iris(c, grow: 1); c.fillPath()
            })
        }
        if parts.contains(.sclera) {
            add(.sclera, layer { c in
                for eye in eyes { polygon(c, eye) }
                c.clip()
                c.addRect(crop); iris(c, grow: 1.1)
                c.fillPath(using: .evenOdd)
            })
        }
        if parts.contains(.eyebrows) {
            let brows = layer { c in
                for brow in outline.brows {
                    if outline.browsAreShapes { polygon(c, brow); c.fillPath() } else {
                        c.setLineWidth(eyeWidth * 0.3); c.setLineCap(.round); c.setLineJoin(.round)
                        c.addLines(between: brow); c.strokePath()
                    }
                }
            }
            // Hair of the brow, not the skin around it: darker than the cheek by a few percent, fully by a quarter.
            // With the mesh's outline the brow's place is sure, so skin within it only fades to half: light brows stay.
            let floor = outline.browsAreShapes ? 0.5 : 0.0
            add(.eyebrows, brows) { x, y in max(floor, min(1, max(0, (skin * 0.95 - luma(pixel(x, y))) / (skin * 0.2)))) }
        }
        // Vision's mouth: its inner lip line often falls well inside a smile's opening, so the teeth are told from the lips
        // by their pixels across the whole mouth, clearly paler than the lips and lighter than the mouth's middle tones.
        let outer = outline.outerLips, inner = outline.innerLips
        if outline.precise, (parts.contains(.lips) || parts.contains(.teeth)), outer.count > 2, inner.count > 2 {
            // The mesh traces both lip lines: lips are the ring between them, teeth what is pale and lit inside.
            if parts.contains(.lips) { add(.lips, layer { c in polygon(c, outer); polygon(c, inner); c.fillPath(using: .evenOdd) }) }
            if parts.contains(.teeth) {
                let opening = layer { c in polygon(c, inner); c.fillPath() }
                var reds: [Double] = [], lumas: [Double] = []
                func redness(_ p: (r: Double, g: Double, b: Double)) -> Double { (p.r - p.g) / max(0.02, p.r + p.g) }
                for y in 0..<ch { for x in 0..<cw where opening[y * cw + x] > 127 { let p = pixel(x, y); reds.append(redness(p)); lumas.append(luma(p)) } }
                if reds.count > 16 {
                    reds.sort(); lumas.sort()
                    // Teeth are the less red half of the opening (gums and tongue are red) and lighter than its shadow.
                    let threshold = reds[reds.count / 2] + (reds[reds.count * 9 / 10] - reds[reds.count / 10]) * 0.1
                    let shadow = lumas[lumas.count / 4]
                    add(.teeth, opening) { x, y in
                        let p = pixel(x, y)
                        return min(1, max(0, (threshold - redness(p)) / 0.03 + 0.5)) * min(1, max(0, (luma(p) - shadow) / 0.05))
                    }
                }
            }
        } else if (parts.contains(.lips) || parts.contains(.teeth)), outer.count > 2 {
            let mouth = layer { c in polygon(c, outer); c.fillPath() }
            // Lips and gums are red, teeth are not: the mouth's pixels split in two by redness (Otsu's threshold), the
            // less red group being teeth where it is also lighter than the mouth's darker tones (not shadow or tongue).
            func redness(_ p: (r: Double, g: Double, b: Double)) -> Double { (p.r - p.g) / max(0.02, p.r + p.g) }
            var reds: [Double] = [], lumas: [Double] = []
            for y in 0..<ch { for x in 0..<cw where mouth[y * cw + x] > 127 {
                let p = pixel(x, y); reds.append(redness(p)); lumas.append(luma(p))
            } }
            lumas.sort()
            if reds.count > 16 {
                let low = reds.min()!, high = reds.max()!, bins = 64
                var histogram = [Double](repeating: 0, count: bins)
                for r in reds { histogram[min(bins - 1, Int((r - low) / max(1e-6, high - low) * Double(bins)))] += 1 }
                let total = Double(reds.count), sum = histogram.enumerated().reduce(0.0) { $0 + Double($1.offset) * $1.element }
                var weight = 0.0, partial = 0.0, best = 0.0, split = bins / 2
                for i in 0..<bins {
                    weight += histogram[i]; partial += Double(i) * histogram[i]
                    guard weight > 0, weight < total else { continue }
                    let m0 = partial / weight, m1 = (sum - partial) / (total - weight)
                    let between = weight * (total - weight) * (m0 - m1) * (m0 - m1)
                    if between > best { best = between; split = i }
                }
                let threshold = low + (Double(split) + 0.5) / Double(bins) * (high - low), shadow = lumas[lumas.count * 2 / 5]
                func tooth(_ x: Int, _ y: Int) -> Double {
                    let p = pixel(x, y)
                    let pale = min(1, max(0, (threshold - redness(p)) / 0.03 + 0.5))
                    let lit = min(1, max(0, (luma(p) - shadow) / 0.05))
                    return pale * lit
                }
                if parts.contains(.teeth) { add(.teeth, mouth, gate: tooth) }
                // Lips: not teeth, and not the dark inside of an open mouth.
                let cavity = lumas[lumas.count / 6]
                if parts.contains(.lips) { add(.lips, mouth) { x, y in (1 - tooth(x, y)) * min(1, max(0, (luma(pixel(x, y)) - cavity) / 0.04)) } }
            }
        }
        let black = CIImage(color: .black).cropped(to: extent)
        return outs.mapValues { out in
            CIImage(bitmapData: Data(out.reversedRows(width: cw, height: ch)), bytesPerRow: cw, size: CGSize(width: cw, height: ch), format: .L8, colorSpace: nil)
                .applyingFilter("CIColorMatrix", parameters: ["inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0)])
                .clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(0.7, eyeWidth * 0.025)]).cropped(to: CGRect(x: 0, y: 0, width: cw, height: ch))
                .transformed(by: CGAffineTransform(translationX: crop.minX, y: crop.minY))
                .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: black]).cropped(to: extent)
        }
    }
}

/// The parts of a face the People mask draws, in the photo's pixels (origin bottom left).
struct FaceOutline {
    var eyes: [[CGPoint]]
    var irises: [(center: CGPoint, radius: Double)]
    /// Lines along each brow (Vision) or each brow's outline (the mesh).
    var brows: [[CGPoint]]
    var browsAreShapes: Bool
    var outerLips: [CGPoint], innerLips: [CGPoint]
    /// From the face mesh: the inner lip line can be trusted.
    var precise: Bool
}

extension RawRenderer {
    /// MediaPipe's face mesh points, as loops: each eye, each brow (lower edge then upper back), the lips' outer and
    /// inner lines, and each iris (centre, then four points on its edge).
    private static let mesh = (
        eyes: [[33, 7, 163, 144, 145, 153, 154, 155, 133, 173, 157, 158, 159, 160, 161, 246],
               [263, 249, 390, 373, 374, 380, 381, 382, 362, 398, 384, 385, 386, 387, 388, 466]],
        brows: [[46, 53, 52, 65, 55, 107, 66, 105, 63, 70], [276, 283, 282, 295, 285, 336, 296, 334, 293, 300]],
        outerLips: [61, 146, 91, 181, 84, 17, 314, 405, 321, 375, 291, 409, 270, 269, 267, 0, 37, 39, 40, 185],
        innerLips: [78, 95, 88, 178, 87, 14, 317, 402, 318, 324, 308, 415, 310, 311, 312, 13, 82, 81, 80, 191],
        irises: [[468, 469, 470, 471, 472], [473, 474, 475, 476, 477]])

    /// The face mesh on the face Vision found (`face`, normalized), from a square crop with a quarter of the face's
    /// size around it, as the model was trained. Nil without the model or when it does not see a face.
    func faceMesh(face: CGRect, source: CIImage) throws -> FaceOutline? {
        guard let all = try faceMeshPoints(face: face, source: source) else { return nil }
        let point = { (i: Int) in all[i] }
        let irises = Self.mesh.irises.map { ids -> (CGPoint, Double) in
            let center = point(ids[0])
            var radius = 0.0
            for id in ids[1...] { let p = point(id); radius += hypot(p.x - center.x, p.y - center.y) / 4 }
            return (center, radius)
        }
        return FaceOutline(eyes: Self.mesh.eyes.map { $0.map(point) }, irises: irises, brows: Self.mesh.brows.map { $0.map(point) }, browsAreShapes: true,
                           outerLips: Self.mesh.outerLips.map(point), innerLips: Self.mesh.innerLips.map(point), precise: true)
    }
    /// The Face model's 478 points for the face Vision boxed at `face` (normalized, y up), in `source`'s coordinates;
    /// nil without the model or when it doesn't see a face there.
    func faceMeshPoints(face: CGRect, source: CIImage) throws -> [CGPoint]? {
        guard BundledModel.faceMesh.isAvailable else { return nil }
        let extent = source.extent, W = extent.width, H = extent.height
        let side = max(face.width * W, face.height * H) * 1.5
        let crop = CGRect(x: face.midX * W - side / 2, y: face.midY * H - side / 2, width: side, height: side)
        // Outside the photo the crop is black, so the face keeps its place and scale in the model's input.
        let piece = source.cropped(to: crop.intersection(extent)).composited(over: CIImage(color: .black).cropped(to: crop))
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        guard let image = context.createCGImage(piece, from: CGRect(x: 0, y: 0, width: side, height: side), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        let request = VNCoreMLRequest(model: try BundledModelCache.shared.visionModel(.faceMesh))
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let outputs = (request.results as? [VNCoreMLFeatureValueObservation]) ?? []
        guard let points = outputs.first(where: { $0.featureName == "landmarks" })?.featureValue.multiArrayValue, points.count == 478 * 3 else { return nil }
        if let score = outputs.first(where: { $0.featureName == "score" })?.featureValue.multiArrayValue, score.count > 0, score[0].doubleValue < 0 { return nil }
        let s = points.strides.map(\.intValue)
        func point(_ i: Int) -> CGPoint {
            // x, y in the 256 crop with rows top down.
            let x = points[i * s[0]].doubleValue, y = points[i * s[0] + s[1]].doubleValue
            return CGPoint(x: crop.minX + x / 256 * side, y: crop.maxY - y / 256 * side)
        }
        return (0..<478).map(point)
    }
}

private extension Array where Element == UInt8 {
    /// Rows bottom up turned top down (or back), for a one-byte-per-pixel image.
    func reversedRows(width: Int, height: Int) -> [UInt8] {
        var out = self
        for y in 0..<height { out.replaceSubrange(y * width..<(y + 1) * width, with: self[(height - 1 - y) * width..<(height - y) * width]) }
        return out
    }
}

/// A face's parts on the photo, for picking them there: outlines from the face mesh, normalized with the origin at the
/// bottom left, in the frame retouch strokes use (before crop and geometry).
public struct PortraitPartOutline: Sendable {
    public enum Part: Sendable, CaseIterable { case teeth, lips, eyes, brows }
    /// Vision's box for the face, as `PortraitFace` has it.
    public let face: CGRect
    public let eyes: [[MaskPoint]], brows: [[MaskPoint]], lips: [MaskPoint], mouth: [MaskPoint]
    /// Teeth show: the mouth's opening is a good part of the lips' outline.
    public let mouthOpen: Bool
    /// The loops a part is drawn and picked by; lips are the outer line, picked outside the opening.
    public func loops(_ part: Part) -> [[MaskPoint]] {
        switch part {
        case .teeth: return mouthOpen ? [mouth] : []
        case .lips: return [lips]
        case .eyes: return eyes
        case .brows: return brows
        }
    }
}

extension RawRenderer {
    /// Each of `faces`' parts from the face mesh; a face the mesh doesn't see is left out. Empty without the model.
    public func portraitPartOutlines(_ settings: Adjustments, faces: [CGRect]) throws -> [PortraitPartOutline] {
        guard BundledModel.faceMesh.isAvailable, !faces.isEmpty else { return [] }
        var base = settings
        base.geometry = GeometryAdjustments(); base.quarterTurns = 0; base.masks = []; base.postCropVignette = PostCropVignette()
        let source = try pipeline(base, maxDimension: 1600)
        let e = source.extent
        func normalized(_ p: CGPoint) -> MaskPoint { MaskPoint(x: (p.x - e.minX) / e.width, y: (p.y - e.minY) / e.height) }
        func area(_ loop: [CGPoint]) -> Double {
            abs(zip(loop, loop.dropFirst() + loop.prefix(1)).reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }) / 2
        }
        return try faces.compactMap { box in
            guard let mesh = try faceMesh(face: box, source: source) else { return nil }
            let open = area(mesh.innerLips) > area(mesh.outerLips) * 0.25
            return PortraitPartOutline(face: box, eyes: mesh.eyes.map { $0.map(normalized) }, brows: mesh.brows.map { $0.map(normalized) },
                                       lips: mesh.outerLips.map(normalized), mouth: mesh.innerLips.map(normalized), mouthOpen: open)
        }
    }
}
