import SwiftUI
import CevicheCore

extension EditorModel {
    /// What a click on the photo does in Portrait, picked in the bar over it.
    enum PortraitTool: CaseIterable {
        case photo, spots, touchUp, reshape, reframe
        var title: String {
            switch self {
            case .photo: return L10n.tr("Photo")
            case .spots: return L10n.tr("Remove Spots")
            case .touchUp: return L10n.tr("Touch Up")
            case .reshape: return L10n.tr("Reshape")
            case .reframe: return L10n.tr("Reframe")
            }
        }
    }
    /// Two or more faces: Reframe frames the ticked people, and Reshape Face works on the person picked in Facial
    /// Features.
    var isGroupPortrait: Bool { portraitFaces.count > 1 }
    var portraitTool: PortraitTool {
        get {
            if showingFramings { return .reframe }
            if editingFaceRegion { return .reshape }
            if touchingUp { return .touchUp }
            return editsFaceSpots ? .spots : .photo
        }
        set {
            editingFaceRegion = newValue == .reshape
            retouchPointer = newValue != .spots
            showingFramings = newValue == .reframe
            touchingUp = newValue == .touchUp
            // The face's handles show at once: its placement found, or measured now.
            if newValue == .reshape {
                // A face's shape is one person's: on Everyone, the largest of the main people.
                if reshapesEveryone { selectedFaceID = portraitFaces.filter { mainFaceIDs.contains($0.id) }.max { $0.box.width < $1.box.width }?.id }
                prepareLiquify()
            }
        }
    }
}

/// Over the photo in Portrait, as Darkroom's view bar: what clicks on the photo do (spots, the face's handles, the
/// framings), and for the framings their aspect. The framings are measured while Reframe is on.
struct PortraitToolbar: View {
    @ObservedObject var model: EditorModel
    private struct Key: Equatable { let on: Bool; let aspect: CropAspect; let source: URL?; let straighten: Double; let turns: Int; let flips: [Bool]; let people: Set<Int> }

    var body: some View {
        PhotoBar {
            ForEach(EditorModel.PortraitTool.allCases, id: \.self) { tool in
                PhotoBarChoice(title: tool.title, selected: model.portraitTool == tool) { model.portraitTool = tool }
            }
            if model.showingFramings {
                PhotoBarDivider()
                ForEach(model.framingAspects, id: \.self) { aspect in
                    PhotoBarChoice(title: aspect.localizedTitle, selected: model.framingAspect == aspect) { model.framingAspectChoice = aspect }
                }
            }
        }
        .disabled(!model.hasImage || model.busy)
        // The parts of every face, while Touch Up is on.
        .task(id: "\(model.touchingUp)|\(model.documentID)|\(model.portraitFaces.count)") {
            guard model.touchingUp, let renderer = model.renderer else { return }
            let settings = model.adjustments, faces = model.portraitFaces.map(\.box)
            if let parts = try? await renderer.portraitPartOutlines(settings, faces: faces), !Task.isCancelled, model.renderer === renderer {
                model.portraitParts = parts
                if parts.isEmpty { model.blemishReport = BundledModel.faceMesh.isAvailable ? L10n.tr("No face found") : L10n.tr("\(BundledModel.faceMesh.feature) needs a model that is not installed.") }
            }
        }
        .task(id: Key(on: model.showingFramings, aspect: model.framingAspect, source: model.sourceURL, straighten: model.adjustments.geometry.straighten,
                      turns: model.adjustments.quarterTurns, flips: [model.adjustments.geometry.flipHorizontal, model.adjustments.geometry.flipVertical],
                      people: model.chosenFaceIDs)) {
            guard model.showingFramings else { return }
            do {
                let made = try await model.framingCandidates()
                guard !Task.isCancelled else { return }
                model.framingFrames = made; model.pickedFraming = nil
                if made.isEmpty { model.blemishReport = L10n.tr("No face found") }
            } catch is CancellationError {
            } catch { model.blemishReport = error.localizedDescription }
        }
    }
}
