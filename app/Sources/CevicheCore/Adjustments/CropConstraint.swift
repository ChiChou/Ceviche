import Foundation
import CoreGraphics

/// Constrain Crop: the largest crop of a given shape that lies entirely inside the corrected photo.
extension GeometryAdjustments {
    /// True when the crop leaves no empty area from straightening or upright correction.
    public func cropFitsImage(sourceSize: CGSize, quarterTurns: Int) -> Bool {
        guard let outline = CropOutline(self, sourceSize: sourceSize, quarterTurns: quarterTurns) else { return true }
        return outline.contains(crop)
    }
    /// The current crop if it already fits. The whole frame becomes the largest crop of its proportions that fits; any
    /// other crop is shrunk about its own centre, keeping its proportions, so it never moves or grows. Only a crop whose
    /// centre is off the photo is placed anew: the largest of its proportions that fits, no bigger than it was.
    public func constrainedCrop(sourceSize: CGSize, quarterTurns: Int) -> CropRect {
        guard let outline = CropOutline(self, sourceSize: sourceSize, quarterTurns: quarterTurns), !outline.contains(crop) else { return crop }
        let largest = outline.largestCrop(aspect: crop.width * outline.size.width / (crop.height * outline.size.height))
        if crop == .full { return largest ?? crop }
        if let shrunk = outline.shrunk(crop) { return shrunk }
        guard let largest else { return crop }
        let scale = min(1, crop.width / largest.width)
        return CropRect(x: largest.x + largest.width * (1 - scale) / 2, y: largest.y + largest.height * (1 - scale) / 2,
                        width: largest.width * scale, height: largest.height * scale)
    }
    /// The crop after a change from `previous`. A crop that was the whole photo, or the largest that fitted it,
    /// follows the photo: it is fitted again from the full frame, so undoing a correction gives the frame back
    /// instead of leaving it at the size the stronger correction allowed. A crop the change itself set, or one
    /// drawn by hand, is only ever shrunk.
    public func constrainedCrop(after previous: GeometryAdjustments, previousQuarterTurns: Int, sourceSize: CGSize, quarterTurns: Int) -> CropRect {
        guard crop == previous.crop,
              let outline = CropOutline(self, sourceSize: sourceSize, quarterTurns: quarterTurns),
              let old = CropOutline(previous, sourceSize: sourceSize, quarterTurns: previousQuarterTurns), !old.matches(outline),
              let followed = previous.largestCrop(in: old, sourceSize: sourceSize, quarterTurns: previousQuarterTurns),
              crop == .full || crop.isClose(to: followed),
              let fitted = largestCrop(in: outline, sourceSize: sourceSize, quarterTurns: quarterTurns) else {
            return constrainedCrop(sourceSize: sourceSize, quarterTurns: quarterTurns)
        }
        return fitted
    }
    /// The largest crop inside the outline: at the chosen aspect, or the frame's own shape when it is Free.
    private func largestCrop(in outline: CropOutline, sourceSize: CGSize, quarterTurns: Int) -> CropRect? {
        let original = quarterTurns % 2 == 0 ? sourceSize : CGSize(width: sourceSize.height, height: sourceSize.width)
        guard let ratio = aspectRatio(original: original) else {
            return outline.contains(.full) ? .full : outline.largestCrop(aspect: outline.size.width / outline.size.height)
        }
        return outline.largestCrop(aspect: ratio)
    }
}
public extension CropRect {
    /// Within half a percent of the frame on every side: the same crop, give or take the fit's search step.
    func isClose(to other: CropRect) -> Bool {
        abs(x - other.x) < 0.005 && abs(y - other.y) < 0.005 && abs(x + width - other.x - other.width) < 0.005 && abs(y + height - other.y - other.height) < 0.005
    }
}

/// The corrected photo as a convex outline in full-frame pixels: four corners, or with Volume its curved edges as points.
struct CropOutline {
    let size: CGSize
    let corners: [CGPoint]
    /// Rounding the crop to whole pixels must never expose a sliver of empty edge.
    private let margin = 1.0

    /// Each edge from its start point, as a unit direction, and whether it lies along the frame (a border the crop may
    /// touch): worked out once, as Constrain Crop tests points against every edge thousands of times per fit.
    private let edges: [(start: CGPoint, direction: CGPoint, flat: Bool)]
    private let sign: Double

    init?(_ settings: GeometryAdjustments, sourceSize: CGSize, quarterTurns: Int) {
        var full = settings; full.crop = .full
        guard let plan = try? GeometryPlan(size: sourceSize, settings: full, quarterTurns: quarterTurns) else { return nil }
        let points = plan.imageOutline
        size = plan.fullSize; corners = points
        var area = 0.0
        for i in points.indices { let a = points[i], b = points[(i+1)%points.count]; area += a.x*b.y - b.x*a.y }
        sign = area >= 0 ? 1 : -1
        edges = points.indices.map { i in
            let a = points[i], b = points[(i+1)%points.count], length = max(1e-9, hypot(b.x-a.x, b.y-a.y))
            return (a, CGPoint(x: (b.x-a.x)/length, y: (b.y-a.y)/length), abs(a.x - b.x) < 1e-6 || abs(a.y - b.y) < 1e-6)
        }
    }
    func matches(_ other: CropOutline) -> Bool {
        corners.count == other.corners.count && abs(size.width - other.size.width) < 1e-6 && abs(size.height - other.size.height) < 1e-6
            && zip(corners, other.corners).allSatisfy { abs($0.x - $1.x) < 1e-6 && abs($0.y - $1.y) < 1e-6 }
    }
    /// Inside every slanted edge by at least the margin; an axis-aligned edge is the photo's own border, which a
    /// crop may touch (otherwise the default full crop would never fit).
    func contains(_ point: CGPoint) -> Bool {
        // Manual scale and offsets can move the photo beyond the fixed output canvas.
        guard point.x >= -1e-6, point.y >= -1e-6, point.x <= size.width+1e-6, point.y <= size.height+1e-6 else { return false }
        for edge in edges {
            let a = edge.start, d = edge.direction
            if sign * (d.x*(point.y-a.y) - d.y*(point.x-a.x)) < (edge.flat ? -1e-6 : margin) { return false }
        }
        return true
    }
    /// A convex outline contains a rectangle exactly when it contains its four corners.
    func contains(_ crop: CropRect) -> Bool {
        let r = CGRect(x: crop.x*size.width, y: crop.y*size.height, width: crop.width*size.width, height: crop.height*size.height)
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].allSatisfy(contains)
    }
    /// `crop` scaled about its own centre by the largest factor up to 1 that fits; nil when its centre is off the photo
    /// or less than a hundredth of the frame would be left.
    func shrunk(_ crop: CropRect) -> CropRect? {
        let cx = crop.x + crop.width / 2, cy = crop.y + crop.height / 2
        guard contains(CGPoint(x: cx * size.width, y: cy * size.height)) else { return nil }
        func scaled(_ s: Double) -> CropRect { CropRect(x: cx - crop.width * s / 2, y: cy - crop.height * s / 2, width: crop.width * s, height: crop.height * s) }
        // The rectangles that fit, scaled about a point inside a convex outline, run from 0 up to one largest scale.
        var low = 0.0, high = 1.0
        for _ in 0..<30 { let s = (low + high) / 2; if contains(scaled(s)) { low = s } else { high = s } }
        let fitted = scaled(low)
        return fitted.width >= 0.01 && fitted.height >= 0.01 ? fitted : nil
    }
    /// Searches centers coarse-to-fine; for each center the largest fitting height is found by bisection.
    func largestCrop(aspect: Double) -> CropRect? {
        guard aspect.isFinite, aspect > 0 else { return nil }
        func height(at center: CGPoint) -> Double {
            guard contains(center) else { return 0 }
            var low = 0.0, high = min(Double(size.height), Double(size.width)/aspect)
            for _ in 0..<22 {
                let h = (low+high)/2, w = h*aspect
                let corners = [CGPoint(x: center.x-w/2, y: center.y-h/2), CGPoint(x: center.x+w/2, y: center.y-h/2),
                               CGPoint(x: center.x+w/2, y: center.y+h/2), CGPoint(x: center.x-w/2, y: center.y+h/2)]
                if corners.allSatisfy(contains) { low = h } else { high = h }
            }
            return low
        }
        var best = CGPoint(x: size.width/2, y: size.height/2), bestHeight = height(at: best)
        var span = CGSize(width: size.width, height: size.height)
        for _ in 0..<8 {
            let origin = best
            for i in 0...6 { for j in 0...6 {
                let candidate = CGPoint(x: origin.x + (Double(i)/6 - 0.5)*span.width, y: origin.y + (Double(j)/6 - 0.5)*span.height)
                let h = height(at: candidate)
                if h > bestHeight { bestHeight = h; best = candidate }
            } }
            span = CGSize(width: span.width/3, height: span.height/3)
        }
        let w = bestHeight*aspect/size.width, h = bestHeight/size.height
        guard w >= 0.01, h >= 0.01 else { return nil }
        return CropRect(x: max(0, best.x/size.width - w/2), y: max(0, best.y/size.height - h/2), width: min(1, w), height: min(1, h))
    }
}
