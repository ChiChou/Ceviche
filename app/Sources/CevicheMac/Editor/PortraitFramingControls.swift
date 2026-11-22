import SwiftUI
import CevicheCore

/// One crop Portrait › Framing offers: how much of the person shows, at which aspect.
struct FramingCandidate: Identifiable, Equatable {
    let framing: PortraitFraming
    let aspect: CropAspect
    let portrait: Bool
    let crop: CropRect
    var id: String { "\(framing.rawValue)-\(aspect.rawValue)" }
    static func == (a: FramingCandidate, b: FramingCandidate) -> Bool { a.id == b.id && a.crop == b.crop }
}

extension EditorModel {
    /// Every framing at the chosen aspect: around the face, or in a group picture around the ticked people (all of
    /// them when none is ticked); framings that come out the same crop (a tight photo leaves no room to go wider) are
    /// offered once.
    func framingCandidates() async throws -> [FramingCandidate] {
        guard let renderer, let info else { return [] }
        let settings = adjustments
        // Placed on the whole frame, as it shows while framings are picked.
        var whole = settings.geometry; whole.crop = .full
        let plan = try GeometryPlan(size: CGSize(width: info.width, height: info.height), settings: whole, quarterTurns: settings.quarterTurns)
        let found = try await renderer.portraitFramingFaces(settings)
        let chosen = found.filter { PortraitFace.covers($0.box, chosenFaces ?? [$0.box]) }.map(\.face)
        let faces = isGroupPortrait ? (chosen.isEmpty ? found.map(\.face) : chosen) : Array(found.prefix(1).map(\.face))
        guard !faces.isEmpty else { return [] }
        let original = settings.quarterTurns % 2 == 0 ? CGSize(width: info.width, height: info.height) : CGSize(width: info.height, height: info.width)
        let aspect = framingAspect
        let portrait: Bool
        switch aspect {
        case .original: portrait = original.height >= original.width
        case .fourFive: portrait = true
        default: portrait = false
        }
        guard let ratio = aspect.ratio(original: original, portrait: portrait) else { return [] }
        var made: [FramingCandidate] = []
        for framing in PortraitFraming.allCases {
            try Task.checkCancellation()
            var geometry = whole
            geometry.aspect = aspect; geometry.portrait = portrait
            guard let crop = framing.crop(for: faces, plan: plan, aspect: ratio) else { continue }
            geometry.crop = crop
            if geometry.constrainCrop { geometry.crop = geometry.constrainedCrop(sourceSize: CGSize(width: info.width, height: info.height), quarterTurns: settings.quarterTurns) }
            guard !made.contains(where: { $0.crop.isClose(to: geometry.crop) }) else { continue }
            made.append(FramingCandidate(framing: framing, aspect: aspect, portrait: portrait, crop: geometry.crop))
        }
        return made
    }
    /// Crops the photo to a framing, with its aspect, as one undoable edit, and puts the framings away to show it.
    func applyFraming(_ candidate: FramingCandidate) {
        pickedFraming = nil
        edit { $0.geometry.aspect = candidate.aspect; $0.geometry.portrait = candidate.portrait; $0.geometry.crop = candidate.crop }
        showingFramings = false
    }
}
