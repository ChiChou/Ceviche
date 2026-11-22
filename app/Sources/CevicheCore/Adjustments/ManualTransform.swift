import Foundation

/// Display-axis transform values, in the same units as the inspector sliders.
public struct ManualTransform: Codable, Equatable, Sendable {
    public var enabled = true
    public var vertical = 0.0
    public var horizontal = 0.0
    public var rotate = 0.0
    public var aspect = 0.0
    public var scale = 100.0
    public var offsetX = 0.0
    public var offsetY = 0.0
    public init() {}
    /// Keep the correction attached to the photo when Crop rotates or flips the displayed frame.
    public mutating func rotateClockwise(_ clockwise: Bool) {
        let oldHorizontal = horizontal, oldOffsetX = offsetX
        horizontal = clockwise ? -vertical : vertical
        vertical = clockwise ? oldHorizontal : -oldHorizontal
        offsetX = clockwise ? offsetY : -offsetY
        offsetY = clockwise ? -oldOffsetX : oldOffsetX
        aspect = -aspect
    }
    public mutating func flip(horizontal horizontally: Bool) {
        if horizontally { horizontal = -horizontal; offsetX = -offsetX }
        else { vertical = -vertical; offsetY = -offsetY }
        rotate = -rotate
    }
    public var isIdentity: Bool {
        !enabled || vertical == 0 && horizontal == 0 && rotate == 0 && aspect == 0 && scale == 100 && offsetX == 0 && offsetY == 0
    }
    public func validate() throws {
        guard [vertical, horizontal, aspect, offsetX, offsetY].allSatisfy({ $0.isFinite && (-100...100).contains($0) }),
              rotate.isFinite, (-10...10).contains(rotate), scale.isFinite, (50...150).contains(scale) else {
            throw EditorError.invalidDocument(L10n.tr("Invalid manual transform values."))
        }
    }

    /// Rotate → perspective → aspect/scale → offset, about the center of a fixed canvas.
    /// The calibrated perspective curve follows RAWmakase (MIT; see OpenSourceLicenses/credits/rawmakase/RAWmakase-MIT.txt).
    /// Work in centered, long-edge units with y down, then convert back to Core Image's y-up pixels.
    func map(size: CGSize) -> ProjectiveMap {
        guard !isIdentity else { return ProjectiveMap() }
        let w = size.width, h = size.height, edge = max(w, h)
        let qx = horizontal / 100, qy = vertical / 100, length = hypot(qx, qy)
        let e = 0.0391 + 0.9251 * length - 0.2827 * length * length
        let angle = rotate * .pi / 180, c = cos(angle), s = sin(angle)
        let a = pow(2, 0.137 * aspect / 100), zoom = scale / 100
        return ProjectiveMap(m: [1 / edge, 0, -w / (2 * edge), 0, -1 / edge, h / (2 * edge), 0, 0, 1])
            .followed(by: ProjectiveMap(m: [c, -s, 0, s, c, 0, 0, 0, 1]))
            .followed(by: ProjectiveMap(m: [1 + e * qx * qx, e * qx * qy, 0, e * qx * qy, 1 + e * qy * qy, 0, -qx, -qy, 1]))
            .followed(by: ProjectiveMap(m: [zoom / a, 0, 0, 0, zoom * a, 0, 0, 0, 1]))
            .followed(by: ProjectiveMap(m: [edge, 0, w / 2 + offsetX / 100 * 0.811 * w, 0, -edge, h / 2 + offsetY / 100 * 0.811 * h, 0, 0, 1]))
    }
}
