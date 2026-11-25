import CoreGraphics

/// Whom Portrait works on: the main people of a photo, or the person picked.
extension PortraitFace {
    /// The main people: faces at least 0.4 the width of the largest. Smaller ones are usually passers-by.
    public static func mainIDs(_ faces: [PortraitFace]) -> Set<Int> {
        let largest = faces.map(\.box.width).max() ?? 0
        return Set(faces.filter { $0.box.width >= largest * 0.4 }.map(\.id))
    }
    /// The boxes of the faces `ids`; nil before any face is known, so a correction then covers everyone.
    public static func boxes(_ faces: [PortraitFace], ids: Set<Int>) -> [CGRect]? {
        faces.isEmpty ? nil : faces.filter { ids.contains($0.id) }.map(\.box)
    }
    /// Whether something tagged with `tag` (nil: everyone's) belongs to the chosen `faces` (nil: everyone).
    public static func isChosen(_ tag: CGRect?, _ faces: [CGRect]?) -> Bool {
        guard let faces else { return true }
        return covers(tag, faces)
    }
}

/// Portrait's edits, as both apps write them. `faces` are the chosen people's boxes (`PortraitFace.boxes`); nil is
/// everyone. A correction made again replaces the chosen people's earlier one and keeps its Amount or Strength; the
/// other people keep theirs.
extension Adjustments {
    /// The chosen people's masks of a correction.
    public func portraitMasks(_ kind: PortraitCorrection, faces: [CGRect]?) -> [PhotoMask] {
        masks.filter { $0.portraitCorrection == kind && PortraitFace.isChosen($0.face, faces) }
    }
    /// Sets a value on the chosen people's masks of a correction alike.
    public mutating func setPortraitMasks(_ kind: PortraitCorrection, _ key: WritableKeyPath<PhotoMask, Double>, _ value: Double, faces: [CGRect]?) {
        for i in masks.indices where masks[i].portraitCorrection == kind && PortraitFace.isChosen(masks[i].face, faces) { masks[i][keyPath: key] = value }
    }
    /// Takes a correction out for the chosen people.
    public mutating func removePortraitCorrection(_ kind: PortraitCorrection, faces: [CGRect]?) {
        masks.removeAll { $0.portraitCorrection == kind && PortraitFace.isChosen($0.face, faces) }
    }
    /// A Light correction's new masks, in place of the chosen people's earlier ones and at their Amount (opacity). A
    /// face `region` drawn by hand replaces the correction for everyone. Over the mask limit the earlier ones still go.
    public mutating func placePortraitCorrection(_ kind: PortraitCorrection, _ made: [PhotoMask], faces: [CGRect]?, region: CGRect? = nil) {
        let replaced = { (m: PhotoMask) in m.portraitCorrection == kind && (region != nil || PortraitFace.isChosen(m.face, faces)) }
        let opacity = masks.first(where: replaced)?.opacity
        masks.removeAll(where: replaced)
        guard masks.count + made.count <= PhotoMask.maxCount else { return }
        masks += made.map { var m = $0; if let opacity { m.opacity = opacity }; return m }
    }
    /// A Features correction's new masks, in place of the chosen people's earlier ones and at their Strength.
    public mutating func placePortraitDetail(_ kind: PortraitCorrection, _ made: [PhotoMask], faces: [CGRect]?) {
        let replaced = { (m: PhotoMask) in m.portraitCorrection == kind && PortraitFace.isChosen(m.face, faces) }
        let strength = masks.first(where: replaced)?.strength ?? 1
        masks.removeAll(where: replaced)
        guard masks.count + made.count <= PhotoMask.maxCount else { return }
        masks += made.map { var m = $0; m.strength = strength; return m }
    }
    /// The Temperature and Tint `faceLightBalance` found, for the whole photo.
    public mutating func takeWhiteBalance(of balanced: Adjustments) {
        temperature = balanced.temperature; tint = balanced.tint
    }

    // MARK: Even tone

    /// The chosen people's Even tone layers.
    public func skinTones(faces: [CGRect]?) -> [SkinTone.Face] {
        (skinTone?.faces ?? []).filter { PortraitFace.isChosen($0.rect, faces) }
    }
    public mutating func setSkinToneAmount(_ amount: Double, faces: [CGRect]?) {
        guard var tone = skinTone else { return }
        for i in tone.faces.indices where PortraitFace.isChosen(tone.faces[i].rect, faces) { tone.faces[i].amount = amount }
        skinTone = tone
    }
    /// Takes the chosen people's Even tone out; with nobody's left, there is none.
    public mutating func removeSkinTone(faces: [CGRect]?) {
        skinTone?.faces.removeAll { PortraitFace.isChosen($0.rect, faces) }
        if skinTone?.faces.isEmpty == true { skinTone = nil }
    }
    /// Even tone's new layers at `amount`, in place of the chosen people's; on everyone they replace them all.
    public mutating func placeSkinTone(_ made: [SkinTone.Face], amount: Double, faces: [CGRect]?) {
        let kept = (faces == nil ? [] : skinTone?.faces ?? []).filter { !PortraitFace.covers($0.rect, faces ?? []) }
        skinTone = SkinTone(faces: kept + made.map { var f = $0; f.amount = amount; return f })
    }

    // MARK: Reshape

    /// Face warps a group picture holds, one per person.
    public static let maxFaceWarps = 20
    /// The warp of the person whose face is `face` in a group picture (the one placed over its centre); nil `face` is
    /// a single portrait's warp.
    public func faceWarp(on face: CGRect?) -> FaceLiquify? {
        guard let face else { return faceLiquify }
        let centre = CGPoint(x: face.midX, y: face.midY)
        return faceLiquifies.first { $0.region.contains(centre) }
    }
    /// The edit that puts `warp` on the person `face` (nil: a single portrait), nil taking theirs out and leaving
    /// everyone else's; nil when there is nothing to change. A new warp past `maxFaceWarps` is not added.
    public func faceWarpEdit(_ warp: FaceLiquify?, on face: CGRect?) -> ((inout Adjustments) -> Void)? {
        guard let face else {
            guard warp != nil || faceLiquify != nil else { return nil }
            return { $0.faceLiquify = warp }
        }
        let centre = CGPoint(x: face.midX, y: face.midY)
        let index = faceLiquifies.firstIndex { $0.region.contains(centre) }
        guard warp != nil || index != nil else { return nil }
        return { a in
            if let index { if let warp { a.faceLiquifies[index] = warp } else { a.faceLiquifies.remove(at: index) } }
            else if let warp, a.faceLiquifies.count < Self.maxFaceWarps { a.faceLiquifies.append(warp) }
        }
    }
}

extension FaceLiquify {
    /// The warp with controls set, each kept within −1…1.
    public func setting(_ values: [(WritableKeyPath<FaceLiquify, Double>, Double)]) -> FaceLiquify {
        var warp = self
        for (path, value) in values { warp[keyPath: path] = min(1, max(-1, value)) }
        return warp
    }
    /// Of a group picture's `faces`, those whose placement is still to be measured.
    public static func unplaced(_ faces: [PortraitFace], in placements: [Int: FaceLiquify]) -> [PortraitFace] {
        faces.filter { placements[$0.id] == nil }
    }
    /// Adds the placements measured for `measured` (in order; nil where the landmarks were missed, tried again next
    /// time) to `placements`, for faces still among `current` with the same box: the faces may be found again meanwhile.
    public static func place(_ found: [FaceLiquify?], on measured: [PortraitFace], current: [PortraitFace], into placements: inout [Int: FaceLiquify]) {
        for (face, warp) in zip(measured, found) {
            if let warp, current.contains(where: { $0.id == face.id && $0.box == face.box }) { placements[face.id] = warp }
        }
    }
}
