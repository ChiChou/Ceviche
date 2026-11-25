import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import Vision

/// Finds the people in a photo, decides which are its subject, and turns every other one into Remove strokes over
/// them, for Distraction Removal's People row. Shadows are left to the brush: dark ground, railings and walls next to
/// the feet cannot be told from a cast shadow reliably.
///
/// People come from Vision's person instance masks (the whole photo, then a crop around each person box nothing covers
/// yet) and from the scene model's "person" class on tiles, which finds the small and defocused people Vision misses.
/// Each person is scored on size, distance from the centre, sharpness and facing the camera; the best and anyone
/// close to it are the subject, the rest are distractions.
enum PeopleFinder {
    /// A soft mask over a rectangle of the photo (pixels, top-left origin), values 0…255; "in" means above 127.
    struct Mask {
        var x = 0, y = 0, w = 0, h = 0
        var v: [UInt8] = []
        var isEmpty: Bool { w == 0 || h == 0 }
        var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
        @inline(__always) func value(_ gx: Int, _ gy: Int) -> UInt8 {
            let lx = gx - x, ly = gy - y
            guard lx >= 0, ly >= 0, lx < w, ly < h else { return 0 }
            return v[ly * w + lx]
        }
        @inline(__always) func contains(_ gx: Int, _ gy: Int) -> Bool { value(gx, gy) > 127 }
        var area: Int { v.reduce(0) { $0 + ($1 > 127 ? 1 : 0) } }
        /// The rectangle around the pixels that are in.
        var tightRect: CGRect {
            var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
            for ly in 0..<h { for lx in 0..<w where v[ly * w + lx] > 127 {
                x0 = min(x0, lx); x1 = max(x1, lx); y0 = min(y0, ly); y1 = max(y1, ly)
            } }
            guard x1 >= 0 else { return .null }
            return CGRect(x: x + x0, y: y + y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
        }
        var centroid: CGPoint {
            var sx = 0.0, sy = 0.0, n = 0.0
            for ly in 0..<h { for lx in 0..<w where v[ly * w + lx] > 127 { sx += Double(lx); sy += Double(ly); n += 1 } }
            return n > 0 ? CGPoint(x: Double(x) + sx / n, y: Double(y) + sy / n) : CGPoint(x: x, y: y)
        }
        /// Vision's mask, placed at the offset in the photo, only inside `clip` (buffer pixels).
        static func from(buffer: CVPixelBuffer, offsetX: Int, offsetY: Int, clip: CGRect? = nil) -> Mask {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let bw = CVPixelBufferGetWidth(buffer), bh = CVPixelBufferGetHeight(buffer), rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return Mask() }
            let format = CVPixelBufferGetPixelFormatType(buffer)
            let area = (clip ?? CGRect(x: 0, y: 0, width: bw, height: bh)).integral.intersection(CGRect(x: 0, y: 0, width: bw, height: bh))
            guard !area.isEmpty else { return Mask() }
            let cx0 = Int(area.minX), cy0 = Int(area.minY), cx1 = Int(area.maxX), cy1 = Int(area.maxY)
            func read(_ px: Int, _ py: Int) -> UInt8 {
                let row = base + py * rowBytes
                let f: Float
                switch format {
                case kCVPixelFormatType_OneComponent32Float: f = row.assumingMemoryBound(to: Float.self)[px]
                case kCVPixelFormatType_OneComponent16Half: f = Float(row.assumingMemoryBound(to: Float16.self)[px])
                default: f = Float(row.assumingMemoryBound(to: UInt8.self)[px]) / 255
                }
                return UInt8(max(0, min(255, (f * 255).rounded())))
            }
            var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
            for py in cy0..<cy1 { for px in cx0..<cx1 where read(px, py) > 127 {
                x0 = min(x0, px); x1 = max(x1, px); y0 = min(y0, py); y1 = max(y1, py)
            } }
            guard x1 >= 0 else { return Mask() }
            x0 = max(cx0, x0 - 1); y0 = max(cy0, y0 - 1); x1 = min(cx1 - 1, x1 + 1); y1 = min(cy1 - 1, y1 + 1)
            var mask = Mask(x: offsetX + x0, y: offsetY + y0, w: x1 - x0 + 1, h: y1 - y0 + 1)
            mask.v = [UInt8](repeating: 0, count: mask.w * mask.h)
            for py in y0...y1 { for px in x0...x1 { mask.v[(py - y0) * mask.w + px - x0] = read(px, py) } }
            return mask
        }
        /// An ellipse filling `r`: a person box no mask matches.
        static func ellipse(_ r: CGRect) -> Mask {
            var m = Mask(x: Int(r.minX), y: Int(r.minY), w: max(1, Int(r.width)), h: max(1, Int(r.height)))
            m.v = [UInt8](repeating: 0, count: m.w * m.h)
            let a = Double(m.w) / 2, b = Double(m.h) / 2
            for ly in 0..<m.h { for lx in 0..<m.w {
                let dx = (Double(lx) + 0.5 - a) / a, dy = (Double(ly) + 0.5 - b) / b
                if dx * dx + dy * dy <= 1 { m.v[ly * m.w + lx] = 255 }
            } }
            return m
        }
        /// Binary dilation by a square of radius `r`, kept inside the photo.
        func dilated(_ r: Int, width W: Int, height H: Int) -> Mask {
            guard !isEmpty else { return self }
            let nx = max(0, x - r), ny = max(0, y - r), nx1 = min(W, x + w + r), ny1 = min(H, y + h + r)
            let nw = nx1 - nx, nh = ny1 - ny
            var across = [UInt8](repeating: 0, count: nw * nh)
            var prefix = [Int](repeating: 0, count: w + 1)
            for ly in 0..<h {
                for lx in 0..<w { prefix[lx + 1] = prefix[lx] + (v[ly * w + lx] > 127 ? 1 : 0) }
                guard prefix[w] > 0 else { continue }
                let row = (y + ly - ny) * nw
                for gx in nx..<nx1 {
                    let a = max(0, gx - r - x), b = min(w, gx + r + 1 - x)
                    if b > a, prefix[b] - prefix[a] > 0 { across[row + gx - nx] = 255 }
                }
            }
            var out = Mask(x: nx, y: ny, w: nw, h: nh)
            out.v = [UInt8](repeating: 0, count: nw * nh)
            var column = [Int](repeating: 0, count: nh + 1)
            for cx in 0..<nw {
                for cy in 0..<nh { column[cy + 1] = column[cy] + (across[cy * nw + cx] > 0 ? 1 : 0) }
                guard column[nh] > 0 else { continue }
                for cy in 0..<nh {
                    let a = max(0, cy - r), b = min(nh, cy + r + 1)
                    if column[b] - column[a] > 0 { out.v[cy * nw + cx] = 255 }
                }
            }
            return out
        }
        func union(_ o: Mask) -> Mask {
            if o.isEmpty { return self }
            if isEmpty { return o }
            let r = rect.union(o.rect)
            var out = Mask(x: Int(r.minX), y: Int(r.minY), w: Int(r.width), h: Int(r.height))
            out.v = [UInt8](repeating: 0, count: out.w * out.h)
            for ly in 0..<out.h { for lx in 0..<out.w { out.v[ly * out.w + lx] = max(value(out.x + lx, out.y + ly), o.value(out.x + lx, out.y + ly)) } }
            return out
        }
        /// Clears every pixel any of `others` has in.
        func subtracting(_ others: [Mask]) -> Mask {
            var out = self
            for o in others where o.rect.intersects(rect) {
                let r = o.rect.intersection(rect)
                for gy in Int(r.minY)..<Int(r.maxY) { for gx in Int(r.minX)..<Int(r.maxX) where o.contains(gx, gy) { out.v[(gy - y) * w + gx - x] = 0 } }
            }
            return out
        }
        func overlap(_ o: Mask) -> Int {
            guard o.rect.intersects(rect) else { return 0 }
            let r = o.rect.intersection(rect)
            var n = 0
            for gy in Int(r.minY)..<Int(r.maxY) { for gx in Int(r.minX)..<Int(r.maxX) where contains(gx, gy) && o.contains(gx, gy) { n += 1 } }
            return n
        }
    }

    /// RGBA8, encoded sRGB, rows top down.
    struct Pixels {
        let width: Int, height: Int, data: [UInt8]
        @inline(__always) func luma(_ x: Int, _ y: Int) -> Float {
            let i = (y * width + x) * 4
            return (0.2126 * Float(data[i]) + 0.7152 * Float(data[i + 1]) + 0.0722 * Float(data[i + 2])) / 255
        }
    }

    struct Person {
        var mask: Mask
        var box: CGRect
        var face: (rect: CGRect, yaw: Double?)?
        var score = 0.0, size = 0.0, sharp = 0.0, facing = 0.0
        var subject = false
    }

    /// Vision's normalized, bottom-left rectangle in pixels of a `w`×`h` image, top-left origin.
    static func pixelRect(_ r: CGRect, _ w: Int, _ h: Int) -> CGRect {
        CGRect(x: r.minX * Double(w), y: (1 - r.maxY) * Double(h), width: r.width * Double(w), height: r.height * Double(h))
    }
    static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let ia = i.width * i.height
        return ia / (a.width * a.height + b.width * b.height - ia)
    }

    /// Every person in the photo, with masks; `scene` adds those only the scene model sees.
    static func people(in image: CGImage, scene: MLModel?) throws -> [Person] {
        let W = image.width, H = image.height
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        // Instance masks on the whole photo: at most four people, the large and sharp ones.
        let instances = VNGeneratePersonInstanceMaskRequest()
        try handler.perform([instances])
        var people: [Person] = []
        if let observation = instances.results?.first {
            for index in observation.allInstances {
                let m = Mask.from(buffer: try observation.generateScaledMaskForImage(forInstances: IndexSet(integer: index), from: handler), offsetX: 0, offsetY: 0)
                if m.area > 50 { people.append(Person(mask: m, box: m.tightRect)) }
            }
        }
        try Task.checkCancellation()
        // Person boxes on the whole photo and on overlapping tiles, so distant people are big enough for Vision.
        var boxes: [(CGRect, Float)] = []
        func humans(_ crop: CGRect) throws {
            guard let tile = image.cropping(to: crop) else { return }
            let request = VNDetectHumanRectanglesRequest()
            request.upperBodyOnly = false
            try VNImageRequestHandler(cgImage: tile, options: [:]).perform([request])
            for o in request.results ?? [] {
                var r = pixelRect(o.boundingBox, tile.width, tile.height)
                r.origin.x += crop.minX; r.origin.y += crop.minY
                boxes.append((r, o.confidence))
            }
        }
        try humans(CGRect(x: 0, y: 0, width: W, height: H))
        var sides = [min(W, H) / 2]
        if 1024 < sides[0] * 3 / 4 { sides.append(1024) }
        for side in sides { for crop in tiles(W, H, side: Double(side), shift: false) { try humans(crop) } }
        boxes.sort { $0.0.width * $0.0.height > $1.0.width * $1.0.height }
        var merged: [CGRect] = []
        for (box, confidence) in boxes where confidence > 0.25 && box.height >= 12 {
            let duplicate = merged.contains { kept in
                let i = kept.intersection(box)
                return !i.isNull && (iou(kept, box) > 0.45 || i.width * i.height > 0.7 * box.width * box.height)
            }
            if !duplicate { merged.append(box) }
        }
        try Task.checkCancellation()
        // Faces, for the facing score.
        let faceRequest = VNDetectFaceRectanglesRequest()
        faceRequest.revision = VNDetectFaceRectanglesRequestRevision3
        try handler.perform([faceRequest])
        var faces = (faceRequest.results ?? []).map { (rect: pixelRect($0.boundingBox, W, H), yaw: $0.yaw?.doubleValue) }
        // Boxes no mask covers yet: an instance pass on a crop around each.
        func covered(_ box: CGRect) -> Double {
            let r = box.integral.intersection(CGRect(x: 0, y: 0, width: W, height: H))
            guard !r.isEmpty else { return 1 }
            let step = max(1, Int(min(r.width, r.height) / 60))
            var inside = 0, total = 0
            for gy in stride(from: Int(r.minY), to: Int(r.maxY), by: step) { for gx in stride(from: Int(r.minX), to: Int(r.maxX), by: step) {
                total += 1
                if people.contains(where: { $0.mask.contains(gx, gy) }) { inside += 1 }
            } }
            return Double(inside) / Double(max(1, total))
        }
        for box in merged where covered(box) < 0.2 {
            try Task.checkCancellation()
            let pad = max(box.width, box.height) * 0.6
            let crop = box.insetBy(dx: -pad, dy: -pad).integral.intersection(CGRect(x: 0, y: 0, width: W, height: H))
            guard let tile = image.cropping(to: crop) else { continue }
            let cropHandler = VNImageRequestHandler(cgImage: tile, options: [:])
            let request = VNGeneratePersonInstanceMaskRequest(), faceInCrop = VNDetectFaceRectanglesRequest()
            faceInCrop.revision = VNDetectFaceRectanglesRequestRevision3
            try cropHandler.perform([request, faceInCrop])
            for f in faceInCrop.results ?? [] {
                var r = pixelRect(f.boundingBox, tile.width, tile.height)
                r.origin.x += crop.minX; r.origin.y += crop.minY
                if !faces.contains(where: { iou($0.rect, r) > 0.3 }) { faces.append((r, f.yaw?.doubleValue)) }
            }
            // The instance with most new pixels inside the box (grown a little: arms, bags).
            let local = box.offsetBy(dx: -crop.minX, dy: -crop.minY).insetBy(dx: -box.width * 0.15, dy: -box.height * 0.1)
            var best: Mask?, bestNew = 0
            if let observation = request.results?.first {
                for index in observation.allInstances {
                    let m = Mask.from(buffer: try observation.generateScaledMaskForImage(forInstances: IndexSet(integer: index), from: cropHandler),
                                      offsetX: Int(crop.minX), offsetY: Int(crop.minY), clip: local)
                    guard !m.isEmpty else { continue }
                    var fresh = 0
                    for ly in 0..<m.h { for lx in 0..<m.w where m.v[ly * m.w + lx] > 127 {
                        if !people.contains(where: { $0.mask.contains(m.x + lx, m.y + ly) }) { fresh += 1 }
                    } }
                    if fresh > bestNew { bestNew = fresh; best = m }
                }
            }
            if let best, Double(bestNew) > 0.12 * box.width * box.height {
                people.append(Person(mask: best.subtracting(people.map(\.mask)), box: box))
            } else {
                people.append(Person(mask: Mask.ellipse(box.insetBy(dx: box.width * 0.05, dy: 0)), box: box))
            }
        }
        // The scene model's person pixels on tiles: defocused and partly hidden people. Each region gets an instance pass
        // on a crop around it; what no instance covers stays a person on the scene mask alone.
        if let scene {
            for region in try personRegions(image, model: scene) {
                try Task.checkCancellation()
                let regionArea = region.area
                guard regionArea > 0 else { continue }
                var fresh = region.subtracting(people.map(\.mask))
                guard Double(fresh.area) > 0.3 * Double(regionArea) else { continue }
                // Pixels at the edge of someone already found (hair, hands, a bag) are that person's.
                if let j = people.indices.first(where: { j in
                    let b = people[j].box
                    return b.insetBy(dx: -0.05 * b.height, dy: -0.05 * b.height).intersects(fresh.rect)
                        && fresh.overlap(people[j].mask.dilated(max(3, Int(0.015 * b.height)), width: W, height: H)) > 0
                        && fresh.area < people[j].mask.area / 5
                }) {
                    people[j].mask = people[j].mask.union(fresh)
                    continue
                }
                let box = region.tightRect
                let pad = max(box.width, box.height) * 0.6
                let crop = box.insetBy(dx: -pad, dy: -pad).integral.intersection(CGRect(x: 0, y: 0, width: W, height: H))
                guard let tile = image.cropping(to: crop) else { continue }
                let cropHandler = VNImageRequestHandler(cgImage: tile, options: [:])
                let request = VNGeneratePersonInstanceMaskRequest()
                try cropHandler.perform([request])
                let near = region.dilated(max(4, Int(box.height * 0.08)), width: W, height: H)
                if let observation = request.results?.first {
                    for index in observation.allInstances {
                        let m = Mask.from(buffer: try observation.generateScaledMaskForImage(forInstances: IndexSet(integer: index), from: cropHandler),
                                          offsetX: Int(crop.minX), offsetY: Int(crop.minY)).subtracting(people.map(\.mask))
                        let a = m.area
                        guard a > 50, Double(m.overlap(near)) > 0.6 * Double(a), Double(m.overlap(region)) > 0.3 * Double(a) else { continue }
                        people.append(Person(mask: m, box: m.tightRect))
                        fresh = fresh.subtracting([m.dilated(3, width: W, height: H)])
                    }
                }
                let left = fresh.tightRect
                if !left.isNull && (left.height < 24 || fresh.area < 300) { continue }
                // Close-ups: the scene model calls most of the frame "person" around a big subject.
                if Double(fresh.area) > 0.1 * Double(W * H) { continue }
                // A big region only the scene model saw is looked at again, centred: on bokeh and dim backgrounds its
                // person pixels move with the tile, a person stays.
                if Double(fresh.area) > 0.005 * Double(W * H), try !confirms(image, model: scene, region: fresh) { continue }
                if Double(fresh.area) > 0.3 * Double(regionArea) { people.append(Person(mask: fresh, box: fresh.tightRect)) }
            }
        }
        // Boxes and faces to people.
        for i in people.indices {
            let tight = people[i].mask.tightRect
            if !tight.isNull { people[i].box = tight }
            people[i].face = faces.filter { f in
                let c = CGPoint(x: f.rect.midX, y: f.rect.midY)
                return people[i].mask.contains(Int(c.x), Int(c.y))
            }.max { $0.rect.width < $1.rect.width }
        }
        people.removeAll { $0.box.isNull }
        // One person split in two (hair and shoes apart from the body): a faceless piece under a fifth of a person's
        // size, mostly inside their box and touching their mask, is part of them.
        var joined = true
        while joined {
            joined = false
            outer: for a in people.indices where people[a].face == nil {
                let ab = people[a].box
                for b in people.indices where b != a && people[a].mask.area * 5 < people[b].mask.area {
                    let i = ab.intersection(people[b].box)
                    guard !i.isNull, i.width * i.height > 0.6 * ab.width * ab.height else { continue }
                    let reach = max(3, Int(0.01 * people[b].box.height))
                    guard people[a].mask.overlap(people[b].mask.dilated(reach, width: W, height: H)) > 0 else { continue }
                    people[b].mask = people[b].mask.union(people[a].mask)
                    people[b].box = people[b].mask.tightRect
                    people.remove(at: a)
                    joined = true
                    break outer
                }
            }
        }
        return people
    }

    /// Square tiles of `side` over the photo, overlapping by a quarter; `shift` moves the grid by half a step.
    static func tiles(_ W: Int, _ H: Int, side: Double, shift: Bool) -> [CGRect] {
        let t = min(side, Double(min(W, H)))
        let columns = max(1, Int(ceil((Double(W) - t) / (0.75 * t))) + 1), rows = max(1, Int(ceil((Double(H) - t) / (0.75 * t))) + 1)
        let sx = shift && columns > 1 ? (Double(W) - t) / Double(columns - 1) / 2 : 0
        let sy = shift && rows > 1 ? (Double(H) - t) / Double(rows - 1) / 2 : 0
        var out: [CGRect] = []
        for row in 0..<(rows + (shift ? 1 : 0)) { for column in 0..<(columns + (shift ? 1 : 0)) {
            var x = columns == 1 ? 0 : (Double(W) - t) * Double(column) / Double(columns - 1) - sx
            var y = rows == 1 ? 0 : (Double(H) - t) * Double(row) / Double(rows - 1) - sy
            x = min(max(0, x), Double(W) - t); y = min(max(0, y), Double(H) - t)
            out.append(CGRect(x: x, y: y, width: t, height: t).integral)
        } }
        return out
    }

    /// Connected regions of the scene model's "person" class over 1024 px tiles. One grid: a second, moved by half a
    /// tile, agrees on a region entirely or not at all, and drops about half of the small defocused people with the
    /// false ones. False ones (lights, rocks, bokeh) are pins to delete; big ones are checked again in `people`.
    static func personRegions(_ image: CGImage, model: MLModel) throws -> [Mask] {
        let W = image.width, H = image.height
        let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
        guard let json = metadata?["com.apple.coreml.model.preview.params"]?.data(using: .utf8),
              let labels = (try JSONSerialization.jsonObject(with: json) as? [String: Any])?["labels"] as? [String],
              let person = labels.firstIndex(of: "person") else { return [] }
        let vision = try VNCoreMLModel(for: model)
        let t = Double(min(1024, min(W, H)))
        var cell = 0.0, gw = 0, gh = 0
        var grid: [UInt8] = []
        for crop in tiles(W, H, side: t, shift: false) {
            try Task.checkCancellation()
            guard let piece = image.cropping(to: crop) else { continue }
            let request = VNCoreMLRequest(model: vision)
            request.imageCropAndScaleOption = .scaleFill
            try VNImageRequestHandler(cgImage: piece, options: [:]).perform([request])
            guard let observation = request.results?.first as? VNCoreMLFeatureValueObservation, let array = observation.featureValue.multiArrayValue,
                  array.shape.count == 2 else { continue }
            let lr = array.shape[0].intValue, lc = array.shape[1].intValue
            if grid.isEmpty {
                cell = t / Double(lc)
                gw = Int(ceil(Double(W) / cell)); gh = Int(ceil(Double(H) / cell))
                grid = [UInt8](repeating: 0, count: gw * gh)
            }
            let pointer = array.dataPointer.bindMemory(to: Int32.self, capacity: lr * lc)
            for r in 0..<lr { for c in 0..<lc where Int(pointer[r * lc + c]) == person {
                let gx = Int((crop.minX + (Double(c) + 0.5) * crop.width / Double(lc)) / cell), gy = Int((crop.minY + (Double(r) + 0.5) * crop.height / Double(lr)) / cell)
                if gx < gw && gy < gh { grid[gy * gw + gx] = 1 }
            } }
        }
        guard !grid.isEmpty else { return [] }
        // Components, 8-connected across a one-cell gap: tile seams and thin occluders split a person otherwise.
        var bridged = grid
        for y in 0..<gh { for x in 0..<gw where grid[y * gw + x] != 0 {
            for yy in max(0, y - 1)...min(gh - 1, y + 1) { for xx in max(0, x - 1)...min(gw - 1, x + 1) { bridged[yy * gw + xx] = 1 } }
        } }
        var label = [Int32](repeating: 0, count: gw * gh), next: Int32 = 0
        var regions: [Mask] = []
        for start in 0..<(gw * gh) where bridged[start] != 0 && label[start] == 0 {
            next += 1
            var queue = [start], head = 0
            label[start] = next
            var x0 = Int.max, y0 = Int.max, x1 = 0, y1 = 0
            while head < queue.count {
                let i = queue[head]; head += 1
                let x = i % gw, y = i / gw
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                for dy in -1...1 { for dx in -1...1 {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, yy >= 0, xx < gw, yy < gh else { continue }
                    let j = yy * gw + xx
                    if bridged[j] != 0 && label[j] == 0 { label[j] = next; queue.append(j) }
                } }
            }
            guard queue.count >= 12 else { continue }
            let fx0 = Int(Double(x0) * cell), fy0 = Int(Double(y0) * cell)
            let fx1 = min(W, Int(Double(x1 + 1) * cell)), fy1 = min(H, Int(Double(y1 + 1) * cell))
            var m = Mask(x: fx0, y: fy0, w: fx1 - fx0, h: fy1 - fy0)
            m.v = [UInt8](repeating: 0, count: m.w * m.h)
            for ly in 0..<m.h { for lx in 0..<m.w {
                let gx = min(gw - 1, Int(Double(fx0 + lx) / cell)), gy = min(gh - 1, Int(Double(fy0 + ly) / cell))
                if label[gy * gw + gx] == next && grid[gy * gw + gx] != 0 { m.v[ly * m.w + lx] = 255 }
            } }
            regions.append(m)
        }
        return regions
    }

    /// The scene model on one tile centred on `region`: does it still call at least a third of it "person"?
    static func confirms(_ image: CGImage, model: MLModel, region: Mask) throws -> Bool {
        let W = image.width, H = image.height, r = region.tightRect
        guard !r.isNull else { return false }
        let t = Double(min(min(W, H), max(1024, Int(max(r.width, r.height) * 1.5))))
        let crop = CGRect(x: min(max(0, r.midX - t / 2), Double(W) - t), y: min(max(0, r.midY - t / 2), Double(H) - t), width: t, height: t).integral
        let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
        guard let piece = image.cropping(to: crop), let json = metadata?["com.apple.coreml.model.preview.params"]?.data(using: .utf8),
              let labels = (try JSONSerialization.jsonObject(with: json) as? [String: Any])?["labels"] as? [String],
              let person = labels.firstIndex(of: "person") else { return true }
        let request = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cgImage: piece, options: [:]).perform([request])
        guard let observation = request.results?.first as? VNCoreMLFeatureValueObservation, let array = observation.featureValue.multiArrayValue,
              array.shape.count == 2 else { return true }
        let lr = array.shape[0].intValue, lc = array.shape[1].intValue
        let pointer = array.dataPointer.bindMemory(to: Int32.self, capacity: lr * lc)
        var inside = 0, agree = 0
        for row in 0..<lr { for c in 0..<lc {
            let gx = Int(crop.minX + (Double(c) + 0.5) * crop.width / Double(lc)), gy = Int(crop.minY + (Double(row) + 0.5) * crop.height / Double(lr))
            guard region.contains(gx, gy) else { continue }
            inside += 1
            if Int(pointer[row * lc + c]) == person { agree += 1 }
        } }
        return inside == 0 || 3 * agree >= inside
    }

    /// RMS of the luminance Laplacian inside the mask, away from its edge: defocus lowers it.
    static func sharpness(of m: Mask, in p: Pixels) -> Double {
        let area = m.area
        guard area > 0 else { return 0 }
        let step = max(1, Int(sqrt(Double(area) / 150_000))), e = 3
        var sum = 0.0, n = 0
        for gy in stride(from: max(1, m.y + e), to: min(p.height - 1, m.y + m.h - e), by: step) {
            for gx in stride(from: max(1, m.x + e), to: min(p.width - 1, m.x + m.w - e), by: step) {
                guard m.contains(gx, gy), m.contains(gx - e, gy), m.contains(gx + e, gy), m.contains(gx, gy - e), m.contains(gx, gy + e) else { continue }
                let lap = 4 * p.luma(gx, gy) - p.luma(gx - 1, gy) - p.luma(gx + 1, gy) - p.luma(gx, gy - 1) - p.luma(gx, gy + 1)
                sum += Double(lap * lap); n += 1
            }
        }
        return n > 0 ? sqrt(sum / Double(n)) : 0
    }

    /// Scores every person and marks the subject and the people with it; the rest are distractions.
    static func decide(_ people: inout [Person], pixels: Pixels) {
        guard !people.isEmpty else { return }
        let W = Double(pixels.width), H = Double(pixels.height)
        let areas = people.map { Double(max(1, $0.mask.area)) }, maxArea = areas.max()!
        let raw = people.map { sharpness(of: $0.mask, in: pixels) }, maxSharp = max(1e-6, raw.max()!)
        let halfDiagonal = hypot(W, H) / 2
        for i in people.indices {
            let c = people[i].mask.centroid
            people[i].size = sqrt(areas[i] / maxArea)
            let centre = max(0, 1 - hypot(c.x - W / 2, c.y - H / 2) / halfDiagonal)
            people[i].sharp = raw[i] / maxSharp
            if let face = people[i].face {
                let yaw = abs(face.yaw ?? 0)
                people[i].facing = yaw < 0.35 ? 1 : yaw < 0.8 ? 0.6 : 0.3
            }
            people[i].score = 0.40 * people[i].size + 0.20 * centre + 0.25 * people[i].sharp + 0.15 * people[i].facing
        }
        let best = people.indices.max { people[$0].score < people[$1].score }!
        people[best].subject = true
        let s = people[best]
        for i in people.indices where i != best {
            let p = people[i]
            // A group shot keeps everyone in it: about as good as the subject, or as big and as sharp.
            people[i].subject = (p.score >= 0.9 * s.score && p.facing >= 0.6)
                || (p.size >= 0.6 * s.size && p.sharp >= 0.6 * s.sharp && (p.facing >= 0.6 || s.facing < 0.6))
        }
        // Posed groups: anyone touching a subject, at least 40 % of their height and half as sharp, stands with them.
        // Vision masks at most four people and one mask can span several, so a front row would be pinned otherwise.
        // Strangers standing right behind the subject are kept too: faces alone cannot tell them apart (they are often
        // not found in a group, or are turned away), and a stranger left in costs one stroke, a friend removed more.
        var grown = true
        while grown {
            grown = false
            for i in people.indices where !people[i].subject {
                let p = people[i]
                let joins = people.contains { q in
                    guard q.subject, p.box.height >= 0.4 * q.box.height, p.sharp >= 0.5 * q.sharp,
                          p.box.insetBy(dx: -0.05 * q.box.height, dy: -0.05 * q.box.height).intersects(q.box) else { return false }
                    return p.mask.dilated(max(3, Int(0.03 * q.box.height)), width: pixels.width, height: pixels.height).overlap(q.mask) > 0
                }
                if joins { people[i].subject = true; grown = true }
            }
        }
    }

    /// Remove strokes covering `area`, kept off `protect`: a brush path that walks a grid of dabs over the area, so
    /// every step stays inside it. A part apart from the rest gets a stroke of its own.
    static func strokes(covering area: Mask, radius: Double, protect: Mask, width W: Int, height H: Int) -> [RetouchStroke] {
        guard !area.isEmpty else { return [] }
        // Dabs 0.7 radius apart cover every pixel of their cell within half a radius, inside the soft edge's full part.
        let spacing = max(1, radius * 0.7)
        let x0 = Double(area.x), y0 = Double(area.y)
        let cols = Int(ceil(Double(area.w) / spacing)), rows = Int(ceil(Double(area.h) / spacing))
        guard cols > 0, rows > 0 else { return [] }
        var cells = [Bool](repeating: false, count: cols * rows)
        for ly in 0..<area.h { for lx in 0..<area.w where area.v[ly * area.w + lx] > 127 {
            cells[min(rows - 1, Int(Double(ly) / spacing)) * cols + min(cols - 1, Int(Double(lx) / spacing))] = true
        } }
        func centre(_ i: Int) -> CGPoint { CGPoint(x: x0 + (Double(i % cols) + 0.5) * spacing, y: y0 + (Double(i / cols) + 0.5) * spacing) }
        // A dab whose disc would reach the subject is left out.
        let guarded = protect.isEmpty ? protect : protect.dilated(Int(ceil(radius)), width: W, height: H)
        for i in cells.indices where cells[i] {
            let c = centre(i)
            if guarded.contains(Int(c.x), Int(c.y)) { cells[i] = false }
        }
        let side = Double(min(W, H))
        let normalized = min(0.25, max(0.001, radius / side))
        var visited = [Bool](repeating: false, count: cells.count)
        var parts: [[Int]] = []
        for start in cells.indices where cells[start] && !visited[start] {
            // Each part walked from the cell nearest its middle, so the stroke's pin sits on the person.
            var part: [Int] = [], queue = [start], head = 0
            visited[start] = true
            while head < queue.count {
                let i = queue[head]; head += 1; part.append(i)
                let x = i % cols, y = i / cols
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, yy >= 0, xx < cols, yy < rows else { continue }
                    let j = yy * cols + xx
                    if cells[j] && !visited[j] { visited[j] = true; queue.append(j) }
                } }
            }
            parts.append(part)
        }
        guard let largest = parts.map(\.count).max() else { return [] }
        return parts.filter { $0.count * 10 >= largest || $0.count >= 4 }.sorted { $0.count > $1.count }.prefix(4).map { part in
            let members = Set(part)
            let mx = part.reduce(0.0) { $0 + centre($1).x } / Double(part.count), my = part.reduce(0.0) { $0 + centre($1).y } / Double(part.count)
            let root = part.min { hypot(centre($0).x - mx, centre($0).y - my) < hypot(centre($1).x - mx, centre($1).y - my) }!
            // Depth-first walk out and back along a spanning tree: consecutive dabs are always neighbouring cells.
            var path: [Int] = [root], seen: Set<Int> = [root]
            var stack: [(cell: Int, next: Int)] = [(root, 0)]
            let offsets = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]
            while let top = stack.last {
                if top.next == offsets.count {
                    stack.removeLast()
                    if let parent = stack.last { path.append(parent.cell) }
                    continue
                }
                stack[stack.count - 1].next += 1
                let (dx, dy) = offsets[top.next]
                let x = top.cell % cols + dx, y = top.cell / cols + dy
                guard x >= 0, y >= 0, x < cols, y < rows else { continue }
                let j = y * cols + x
                guard members.contains(j), !seen.contains(j) else { continue }
                seen.insert(j); path.append(j); stack.append((j, 0))
            }
            let points = path.map { i -> MaskPoint in
                let c = centre(i)
                return MaskPoint(x: min(1, max(0, c.x / Double(W))), y: min(1, max(0, 1 - c.y / Double(H))))
            }
            var stroke = RetouchStroke(mode: .remove, source: points[0], target: points[0], radius: normalized, softness: 0.5, opacity: 1)
            stroke.points = points
            stroke.person = true
            return stroke
        }
    }
}

extension RawRenderer {
    /// Remove strokes over every person who is not the photo's subject, in the retouch frame;
    /// `people` counts everyone found, the subject included. Strokes already made for people are left out first.
    public func distractingPeople(_ settings: Adjustments) throws -> (people: Int, strokes: [RetouchStroke]) {
        let (people, distractions) = try distractions(settings)
        return (people, distractions.flatMap { $0 })
    }

    /// As `distractingPeople`, the strokes kept apart by person, left to right, so each can be kept or removed alone.
    public func distractions(_ settings: Adjustments) throws -> (people: Int, distractions: [[RetouchStroke]]) {
        var base = settings
        base.geometry = GeometryAdjustments(); base.quarterTurns = 0; base.masks = []; base.postCropVignette = PostCropVignette()
        base.retouch.removeAll { $0.group == .people }
        // Full resolution: the scene model's tiles see distant people at the size they have in the photo.
        let input = try pipeline(base, maxDimension: nil)
        guard let image = context.createCGImage(input, from: input.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { throw EditorError.render }
        let W = image.width, H = image.height
        var data = [UInt8](repeating: 0, count: W * H * 4)
        data.withUnsafeMutableBytes { buffer in
            let bitmap = CGContext(data: buffer.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            bitmap?.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
        }
        let pixels = PeopleFinder.Pixels(width: W, height: H, data: data)
        let scene = try? BundledModelCache.shared.model(.scene)
        var people = try PeopleFinder.people(in: image, scene: scene)
        PeopleFinder.decide(&people, pixels: pixels)
        let protect = people.filter(\.subject).map(\.mask).reduce(PeopleFinder.Mask()) { $0.union($1) }
        let others = people.filter { !$0.subject }.sorted { $0.box.midX < $1.box.midX }
        let generative = BundledModel.inpaint.isAvailable
        var distractions: [[RetouchStroke]] = []
        for person in others {
            try Task.checkCancellation()
            let radius = 3 + 0.02 * person.box.height + 0.002 * Double(min(W, H))
            let strokes = PeopleFinder.strokes(covering: person.mask, radius: radius, protect: protect, width: W, height: H)
            if !strokes.isEmpty { distractions.append(strokes.map { var s = $0; s.generative = generative; return s }) }
        }
        return (people.count, distractions)
    }
}
