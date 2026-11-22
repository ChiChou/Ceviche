import SwiftUI
import CevicheCore

/// Portrait: what the photo does under the pointer, then Blemishes, Light and Shape as rows that open in place, laid
/// out like Retouch's. Blemishes are ordinary retouch strokes tagged as the face's, so Retouch lists them as a group of
/// their own; Light's corrections are generated masks; Shape is Face Liquify, with handles on the face.
struct FacePanel: View {
    @ObservedObject var model: EditorModel
    @AppStorage("portraitOpen.blemishes") private var blemishesOpen = true
    @AppStorage("portraitOpen.light") private var lightOpen = true
    @AppStorage("portraitOpen.shape") private var shapeOpen = true
    @AppStorage("portraitOpen.details") private var detailsOpen = true
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.portraitFaces.count > 1 { people }
            // What each group does on the photo is switched in the Portrait toolbar above it (`PortraitToolbar`).
            DisclosureRow(title: L10n.tr("Blemishes"), symbol: "face.dashed", open: $blemishesOpen, reset: model.removeFaceStrokes, isEnabled: section(.faceSpots)) { skin }
            DisclosureRow(title: L10n.tr("Light"), symbol: "sun.max", open: $lightOpen, reset: model.removePortraitCorrections, isEnabled: section(.portraitLight)) { light }
            DisclosureRow(title: L10n.tr("Features"), symbol: "eye", open: $detailsOpen, reset: model.removePortraitDetails, isEnabled: section(.portraitDetails)) { details }
            facialFeatures
        }
        .font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 14)
        .disabled(!model.hasImage || model.busy)
        .task(id: model.documentID) { await model.loadPortraitFaces() }
        // On opening a photo, and again whenever the face is gone (Reset Edits).
        .task(id: "\(model.sourceURL?.path ?? "")|\(model.currentFaceRegion == nil)") { model.locateFace() }
    }

    private func section(_ group: AdjustmentGroup) -> Binding<Bool> {
        // The photo's own, whatever mask is selected elsewhere.
        // Off also puts down what the group does on the photo: its spots or its handles.
        Binding(get: { !model.adjustments.disabledSections.contains(group) }, set: { on in
            if !on, group == .faceSpots, model.editsFaceSpots { model.retouchPointer = true }
            if !on, group == .facialFeatures { model.editingFaceRegion = false }
            model.edit { if on { $0.disabledSections.remove(group) } else { $0.disabledSections.insert(group) } }
        })
    }

    // MARK: People
    /// The photo's faces, ticked for whom Portrait's corrections and sliders are; All ticks or clears everyone.
    /// Whom the cards work on, one choice: Main subjects (the main people, larger faces) or one person. It wraps onto more
    /// rows rather than hide faces past the edge; the face under the pointer is framed on the photo.
    private var people: some View {
        let selected = model.selectedFaceID, main = model.mainFaceIDs
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 34, maximum: 34), spacing: 8)], alignment: .leading, spacing: 8) {
            Button { model.selectedFaceID = nil } label: {
                Image(systemName: "person.2.fill").font(.system(size: 13)).frame(width: 34, height: 34)
                    .foregroundStyle(selected == nil ? Theme.onAccent : .secondary)
                    .background(Circle().fill(selected == nil ? Theme.accent : Theme.ink.opacity(0.1)))
                    .contentShape(Circle())
            }.buttonStyle(.plain).help(L10n.tr("Main subjects")).accessibilityLabel(L10n.tr("Main subjects")).accessibilityAddTraits(selected == nil ? .isSelected : [])
            ForEach(model.portraitFaces) { face in
                let on = selected == face.id, included = selected == nil && main.contains(face.id)
                Button { model.faceRegion = nil; model.selectedFaceID = face.id } label: {
                    Image(decorative: face.thumbnail, scale: 1).resizable().scaledToFill()
                        .frame(width: 34, height: 34).clipShape(Circle())
                        .overlay(Circle().strokeBorder(on ? Theme.accent : included ? Theme.accent.opacity(0.45) : Color.clear, lineWidth: 2))
                        .opacity(on || included ? 1 : 0.45)
                }.buttonStyle(.plain)
                    .onHover { inside in if inside { model.hoveredFaceID = face.id } else if model.hoveredFaceID == face.id { model.hoveredFaceID = nil } }
                    .accessibilityLabel(L10n.tr("Person \(face.id + 1)")).accessibilityAddTraits(on ? .isSelected : [])
            }
        }.padding(.horizontal, 14).padding(.vertical, 10).card()
    }
    // MARK: Skin
    @ViewBuilder private var skin: some View {
        if let url = BlemishDetector.modelURL {
            RetouchSlider(model: model, title: L10n.tr("Sensitivity"), value: $model.blemishSensitivity, range: 0...1)
            Button { model.findBlemishes(url) } label: { Text(L10n.tr("Find blemishes")).frame(maxWidth: .infinity) }
                .buttonStyle(.secondaryAction).disabled(model.adjustments.retouch.count >= DustFinder.strokeLimit)
        }
        if let report = model.blemishReport { Text(report).font(.system(size: 11)).foregroundStyle(.secondary) }
        if model.adjustments.retouch.contains(where: { $0.group == .face }) {
            RetouchStrokeList(model: model)
            RetouchSelectionCard(model: model, fillAvailable: BundledModel.inpaint.isAvailable)
        }
    }
    // MARK: Light
    /// Each correction is one slider named for what it does; Auto measures the face and makes it, and the wand beside a
    /// made one measures again. White balance balances the face alone (Warmth and Tint, in a mask) or the whole photo.
    @ViewBuilder private var light: some View {
        // Even tone: each face's learned blend layer; Auto makes it at 70 %, the wand makes it again from the photo now.
        if BundledModel.skinTone.isAvailable {
            let tones = model.chosenSkinTones
            if let first = tones.first {
                RetouchSlider(model: model, title: L10n.tr("Even tone"), value: Binding(get: { first.amount }, set: { model.setSkinToneAmount($0) }),
                              range: 0...1, gesture: true, resetTo: Self.evenToneAmount, label: Self.percent(tones.map(\.amount)),
                              measure: { model.applySkinTone(amount: first.amount) }, remove: { model.removeSkinTone() })
            } else { CorrectionRow(title: L10n.tr("Even tone"), button: L10n.tr("Auto")) { model.applySkinTone(amount: Self.evenToneAmount) } }
        } else {
            ModelPrompt(model: .skinTone)
        }
        if let made = mask(.shine) {
            RetouchSlider(model: model, title: L10n.tr("Reduce shine"), value: amount(.shine, made), range: 0...1, gesture: true,
                          resetTo: Self.shineAmount, label: Self.percent(opacities(.shine)),
                          measure: { model.applyPortraitCorrection(.shine) }, remove: { model.removePortraitCorrection(.shine) })
        } else { CorrectionRow(title: L10n.tr("Reduce shine"), button: L10n.tr("Auto")) { model.applyPortraitCorrection(.shine) } }
        // White balance from the face: the photo's Temperature and Tint set so the face looks as in daylight.
        CorrectionRow(title: L10n.tr("White balance"), note: wholePhoto, button: L10n.tr("Auto")) { model.applyFaceLightBalance() }
            .help(L10n.tr("Set the photo’s white balance so the face looks as in daylight"))
    }
    // MARK: Details
    /// Teeth, eyes, lips and brows: each a People mask measured on the largest person, its Amount the masks' opacity.
    @ViewBuilder private var details: some View {
        ForEach(PortraitCorrection.details, id: \.self) { kind in
            detailRow(kind)
            // Red eye with the eyes.
            if kind == .eyes { redEyeRow }
        }
    }
    @ViewBuilder private func detailRow(_ kind: PortraitCorrection) -> some View {
        if let first = mask(kind) {
            RetouchSlider(model: model, title: kind.title, value: strength(kind, first), range: 0...2, gesture: true, resetTo: 1,
                          label: Self.percent(strengths(kind)),
                          measure: { model.applyPortraitDetail(kind) }, remove: { model.removePortraitCorrection(kind) })
        } else { CorrectionRow(title: kind.title, button: L10n.tr("Auto")) { model.applyPortraitDetail(kind) } }
    }
    /// The selected people's Strengths of a Details correction.
    private func strengths(_ kind: PortraitCorrection) -> [Double] {
        model.adjustments.masks.filter { $0.portraitCorrection == kind && model.isSelected($0.face) }.map(\.strength)
    }
    /// A Details correction's Strength for the selected people, 0 to 200 % of what Auto measured, set on all of them.
    private func strength(_ kind: PortraitCorrection, _ first: PhotoMask) -> Binding<Double> {
        Binding(get: { first.strength }, set: { value in
            model.edit { a in
                for i in a.masks.indices where a.masks[i].portraitCorrection == kind && model.isSelected(a.masks[i].face) { a.masks[i].strength = value }
            }
        })
    }
    /// The selected people's Amounts of a correction.
    private func opacities(_ kind: PortraitCorrection) -> [Double] {
        let faces = model.chosenFaces
        return model.adjustments.masks.filter { $0.portraitCorrection == kind && (faces == nil || PortraitFace.covers($0.face, faces ?? [])) }.map(\.opacity)
    }
    /// A percentage for the selected people, or a dash when they differ (Everyone, after one person was changed):
    /// moving the slider sets them all alike.
    static func percent(_ values: [Double]) -> String {
        guard let first = values.first else { return "" }
        return values.allSatisfy({ abs($0 - first) < 0.005 }) ? "\(Int((first * 100).rounded()))%" : "–"
    }
    /// A correction's Amount for the selected people: their masks' opacity, set on all of them.
    private func amount(_ kind: PortraitCorrection, _ first: PhotoMask) -> Binding<Double> {
        Binding(get: { first.opacity }, set: { value in
            let faces = model.chosenFaces
            model.edit { a in
                for i in a.masks.indices where a.masks[i].portraitCorrection == kind && (faces == nil || PortraitFace.covers(a.masks[i].face, faces ?? [])) {
                    a.masks[i].opacity = value
                }
            }
        })
    }
    /// Red eye: on or off, no amount. Fix finds red pupils and neutralizes them, Remove takes that out; the report
    /// says how many.
    @ViewBuilder private var redEyeRow: some View {
        let on = model.adjustments.redEyeCorrection
        CorrectionRow(title: L10n.tr("Red eye"), note: wholePhoto, on: on, button: on ? L10n.tr("Remove") : L10n.tr("Fix")) { model.toggleRedEyeCorrection() }
        if let report = model.redEyeReport { Text(report).font(.system(size: 11)).foregroundStyle(.secondary) }
    }
    /// The correction's first mask for the ticked people; nil when none of them has it yet.
    private func mask(_ kind: PortraitCorrection) -> PhotoMask? {
        let faces = model.chosenFaces
        return model.adjustments.masks.first { $0.portraitCorrection == kind && (faces == nil || PortraitFace.covers($0.face, faces ?? [])) }
    }
    /// In a group picture, said of a control that is the photo's, not the selected person's.
    private var wholePhoto: String? { model.isGroupPortrait ? L10n.tr("Whole photo") : nil }
    /// What Auto makes: Even tone at 70 %, Reduce shine's mask at 80 %; a double-click on their sliders puts it back.
    static let evenToneAmount = 0.7, shineAmount = 0.8

    // MARK: Shape
    /// A face's shape is one person's: in a group picture the card works on the person selected above, and on
    /// Main subjects asks for one.
    private var facialFeatures: some View {
        DisclosureRow(title: L10n.tr("Reshape"), symbol: "face.smiling", open: $shapeOpen, reset: { model.resetLiquify() },
                      isEnabled: section(.facialFeatures)) {
            if model.reshapesEveryone {
                Text(L10n.tr("Select a person above to reshape their face")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else { shape }
        }
        .task(id: "\(model.documentID)|\(model.portraitFaces.count)") { if model.isGroupPortrait { await model.loadGroupPlacements() } }
    }

    @ViewBuilder private var shape: some View {
        if model.currentFaceRegion == nil {
            // A picked face the landmarks can't be found on (too small, blurred or turned away) has nothing to show.
            if model.isGroupPortrait, let face = model.reshapeFace, model.loadedPlacements.contains(face.id) {
                Text(L10n.tr("This face is too small or unclear to reshape")).font(.system(size: 11)).foregroundStyle(.secondary)
            } else if let report = model.blemishReport { Text(report).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        if model.currentFaceRegion != nil {
            ForEach(Self.liquifyGroups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(group.controls, id: \.title) { control in
                        RetouchSlider(model: model, title: control.title, value: Binding(
                            get: { model.liquify[keyPath: control.path] },
                            set: { model.setLiquify(control.path, $0) }
                        ), range: -1...1, gesture: true, resetTo: 0)
                    }
                }.padding(.top, 2)
            }
        }
    }
    private struct LiquifyControl { let title: String; let path: WritableKeyPath<FaceLiquify, Double> }
    private struct LiquifyGroup { let title: String; let controls: [LiquifyControl] }
    private static let liquifyGroups = [
        LiquifyGroup(title: L10n.tr("EYES"), controls: [LiquifyControl(title: L10n.tr("Eye size"), path: \.eyeSize), LiquifyControl(title: L10n.tr("Eye distance"), path: \.eyeDistance)]),
        LiquifyGroup(title: L10n.tr("NOSE"), controls: [LiquifyControl(title: L10n.tr("Nose width"), path: \.noseWidth)]),
        LiquifyGroup(title: L10n.tr("MOUTH"), controls: [LiquifyControl(title: L10n.tr("Smile"), path: \.smile), LiquifyControl(title: L10n.tr("Mouth width"), path: \.mouthWidth)]),
        LiquifyGroup(title: L10n.tr("FACE SHAPE"), controls: [LiquifyControl(title: L10n.tr("Forehead"), path: \.forehead), LiquifyControl(title: L10n.tr("Face width"), path: \.width),
                                                        LiquifyControl(title: L10n.tr("Jawline"), path: \.jawline), LiquifyControl(title: L10n.tr("Chin height"), path: \.chinHeight)]),
    ]
}

extension EditorModel {
    /// Finds the face for Shape and Light before anything is asked of them; a region drawn or saved wins. It runs
    /// quietly: unlike the corrections it doesn't mark the editor busy, which would hold up Reset Edits, saving and
    /// the panel itself for its second or two.
    func locateFace() {
        guard currentFaceRegion == nil, let renderer else { return }
        let settings = adjustments
        faceLookup?.cancel()
        faceLookup = Task {
            guard let face = try? await renderer.liquifyFace(settings), !Task.isCancelled,
                  self.renderer === renderer, currentFaceRegion == nil else { return }
            liquifyBase = face; showingLiquify = true
        }
    }
    /// Whether something tagged with a face (nil: everyone's) belongs to the people selected.
    func isSelected(_ face: CGRect?) -> Bool {
        guard let chosen = chosenFaces, let face else { return true }
        return PortraitFace.covers(face, chosen)
    }
    /// A face's spots: tagged with it, or (found before spots were tagged) lying on it.
    private func isSpot(_ s: RetouchStroke, on face: CGRect) -> Bool {
        guard s.group == .face else { return false }
        if let box = s.faceBox { return PortraitFace.covers(box, [face]) }
        let area = face.insetBy(dx: -face.width * 0.2, dy: -face.height * 0.2)
        return s.points.contains { area.contains(CGPoint(x: $0.x, y: $0.y)) }
    }
    func hasFaceSpots(on face: CGRect) -> Bool { adjustments.retouch.contains { isSpot($0, on: face) } }
    /// Clear under a face on the photo: that face's spots, whoever is selected.
    func removeFaceSpots(on face: CGRect) {
        let mine = { (s: RetouchStroke) in self.isSpot(s, on: face) }
        guard adjustments.retouch.contains(where: mine) else { return }
        selectedRetouchIDs.subtract(adjustments.retouch.filter(mine).map(\.id))
        edit { $0.retouch.removeAll(where: mine) }
    }
    /// The Blemishes card's reset: the selected people's spots.
    func removeFaceStrokes() {
        let mine = { (s: RetouchStroke) in s.group == .face && self.isSelected(s.faceBox) }
        guard adjustments.retouch.contains(where: mine) else { return }
        selectedRetouchIDs.subtract(adjustments.retouch.filter(mine).map(\.id))
        edit { $0.retouch.removeAll(where: mine) }
    }
    /// Makes every face's Even tone layer from the photo as it is now, at `amount`, one undoable edit.
    /// The selected people's Even tone layers.
    var chosenSkinTones: [SkinTone.Face] {
        let chosen = chosenFaces
        return (adjustments.skinTone?.faces ?? []).filter { chosen == nil || PortraitFace.covers($0.rect, chosen ?? []) }
    }
    /// Sets the selected people's Even tone Amount; the others keep theirs.
    func setSkinToneAmount(_ amount: Double) {
        let chosen = chosenFaces
        edit { a in
            guard var tone = a.skinTone else { return }
            for i in tone.faces.indices where chosen == nil || PortraitFace.covers(tone.faces[i].rect, chosen ?? []) { tone.faces[i].amount = amount }
            a.skinTone = tone
        }
    }
    /// Takes the selected people's Even tone out; the others keep theirs.
    func removeSkinTone() {
        let chosen = chosenFaces
        edit { a in
            a.skinTone?.faces.removeAll { chosen == nil || PortraitFace.covers($0.rect, chosen ?? []) }
            if a.skinTone?.faces.isEmpty == true { a.skinTone = nil }
        }
    }
    /// Makes Even tone's layer for the selected faces at `amount`, keeping the other faces' layers.
    func applySkinTone(amount: Double) {
        let settings = adjustments, chosen = chosenFaces
        runFaceTask(L10n.tr("Even tone")) { [self] renderer in
            let faces = try await renderer.skinToneFaces(settings, only: chosen)
            try Task.checkCancellation()
            guard self.renderer === renderer else { return }
            guard !faces.isEmpty else { blemishReport = L10n.tr("No face found"); return }
            blemishReport = nil
            edit { a in
                let kept = (chosen == nil ? [] : a.skinTone?.faces ?? []).filter { !PortraitFace.covers($0.rect, chosen ?? []) }
                a.skinTone = SkinTone(faces: kept + faces.map { var f = $0; f.amount = amount; return f })
            }
        }
    }
    /// The photo's faces for the people row, the larger ones ticked: small faces in the background usually aren't the
    /// people being retouched.
    func loadPortraitFaces() async {
        guard let renderer else { return }
        let settings = adjustments
        guard let faces = try? await renderer.portraitFaces(settings), self.renderer === renderer else { return }
        portraitFaces = faces
        selectedFaceID = nil
    }
    func removeStrokes(in group: RetouchStroke.Group) {
        guard adjustments.retouch.contains(where: { $0.group == group }) else { return }
        selectedRetouchIDs.subtract(adjustments.retouch.filter { $0.group == group }.map(\.id))
        edit { $0.retouch.removeAll { $0.group == group } }
    }
    /// Takes the correction out for the ticked people; the others keep theirs.
    func removePortraitCorrection(_ kind: PortraitCorrection, faces only: [CGRect]? = nil) {
        let faces = only ?? chosenFaces
        let mine = { (m: PhotoMask) in m.portraitCorrection == kind && (faces == nil || PortraitFace.covers(m.face, faces ?? [])) }
        guard adjustments.masks.contains(where: mine) else { return }
        edit { $0.masks.removeAll(where: mine) }
    }
    /// The Light card's reset: the selected people's measured masks and Even tone. White balance is the photo's.
    func removePortraitCorrections() {
        let light = { (mask: PhotoMask) in (mask.portraitCorrection.map { !$0.isDetail } ?? false) && self.isSelected(mask.face) }
        guard adjustments.masks.contains(where: light) || !chosenSkinTones.isEmpty else { return }
        let chosen = chosenFaces
        edit { a in
            a.masks.removeAll(where: light)
            a.skinTone?.faces.removeAll { chosen == nil || PortraitFace.covers($0.rect, chosen ?? []) }
            if a.skinTone?.faces.isEmpty == true { a.skinTone = nil }
        }
    }
    /// The Details card's reset: the selected people's masks; on Everyone, Red eye too, which is the photo's.
    func removePortraitDetails() {
        let detail = { (mask: PhotoMask) in (mask.portraitCorrection?.isDetail ?? false) && self.isSelected(mask.face) }
        let redEye = selectedFaceID == nil && adjustments.redEyeCorrection
        guard adjustments.masks.contains(where: detail) || redEye else { return }
        if redEye { redEyeReport = nil }
        edit { a in a.masks.removeAll(where: detail); if redEye { a.redEyeCorrection = false } }
    }
    /// Makes one Details correction on the largest person, in place of an earlier one, as one undoable edit.
    func applyPortraitDetail(_ kind: PortraitCorrection, faces only: [CGRect]? = nil) {
        let settings = adjustments, faces = only ?? chosenFaces
        runFaceTask(kind.title) { [self] renderer in
            let result = try await renderer.portraitDetail(kind, settings: settings, faces: faces)
            try Task.checkCancellation()
            guard self.renderer === renderer else { return }
            guard let result else { blemishReport = L10n.tr("No face found"); return }
            let made = result.masks
            guard !made.isEmpty else {
                blemishReport = result.visible ? L10n.tr("\(kind.title) look fine") : L10n.tr("\(kind.title) not visible"); return
            }
            blemishReport = nil
            edit { a in
                let replaced = { (m: PhotoMask) in m.portraitCorrection == kind && (faces == nil || PortraitFace.covers(m.face, faces ?? [])) }
                let strength = a.masks.first(where: replaced)?.strength ?? 1
                a.masks.removeAll(where: replaced)
                guard a.masks.count + made.count <= PhotoMask.maxCount else { return }
                a.masks += made.map { var m = $0; m.strength = strength; return m }
            }
        }
    }
    /// Every Shape control back to zero; the face stays found.
    /// Where each face's warp would go, measured once for the photo.
    func loadGroupPlacements() async {
        let faces = portraitFaces.filter { groupPlacements[$0.id] == nil }
        guard let renderer, isGroupPortrait, !faces.isEmpty else { return }
        let settings = adjustments
        guard let found = try? await renderer.liquifyFaces(settings, faces: faces.map(\.box)), self.renderer === renderer else { return }
        // Faces the landmarks miss are tried again next time; the card says so meanwhile.
        for (face, warp) in zip(faces, found) { if let warp, portraitFaces.contains(where: { $0.id == face.id && $0.box == face.box }) { groupPlacements[face.id] = warp } }
        loadedPlacements = Set(portraitFaces.map(\.id))
    }
    func resetLiquify() {
        guard let warp = reshapeWarp else { return }
        reshapeBase = FaceLiquify(region: warp.region, features: warp.features)
        storeReshapeWarp(nil)
    }
    /// Sets the whole photo's Temperature and Tint so the face looks as in daylight, one undoable edit.
    func applyFaceLightBalance() {
        let settings = adjustments, region = currentFaceRegion
        runFaceTask(L10n.tr("White balance")) { [self] renderer in
            let result = try await renderer.faceLightBalance(settings, region: region)
            try Task.checkCancellation()
            guard self.renderer === renderer else { return }
            guard let result else { blemishReport = L10n.tr("No face found"); return }
            edit { $0.temperature = result.temperature; $0.tint = result.tint }
        }
    }
}
