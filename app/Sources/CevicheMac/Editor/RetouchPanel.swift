import SwiftUI
import AppKit
import CevicheCore

/// Pick a brush and paint over what should go, or find dust. Every stroke sits in one list under the tools, where one or
/// several are picked (as on the photo) and changed together in the card below it, above the tool's own settings.
struct RetouchPanel: View {
    @ObservedObject var model: EditorModel
    @AppStorage("removeOpen.people") private var peopleOpen = true
    /// Observed so the AI fill turns on when its model is installed in Settings › Models.
    @ObservedObject private var library = ModelLibrary.shared
    private var fillAvailable: Bool { _ = library.installed; return BundledModel.inpaint.isAvailable }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // The tools, as in other RAW editors: the hand, Select and the three ways to remove. Tone fixes are not a
            // brush here: dust can be evened instead of healed from its own row.
            HStack(spacing: 4) {
                pointerButton
                selectButton
                objectButton
                Rule(.vertical).frame(height: 20).padding(.horizontal, 4)
                ForEach([RetouchTool.remove, .heal, .clone], id: \.self, content: toolButton)
                Spacer()
            }
            if model.retouchTool != .dust, !model.retouchPointer, !model.retouchSelecting, !model.retouchObject { brush }
            // Objects Shift-click collected, waiting to be removed together.
            if model.retouchObject, !model.objectSelection.isEmpty {
                HStack {
                    Text(L10n.tr("\(model.objectSelection.count) selected")).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button(L10n.tr("Remove")) { model.commitObjects([]) }.buttonStyle(.secondaryAction).controlSize(.small)
                        .help(L10n.tr("Remove the selected objects; Esc clears them"))
                }
            }
            // The strokes stay in one place whichever tool a selected stroke opens.
            if !model.adjustments.retouch.isEmpty || !model.selectedFoundSpots.isEmpty {
                Rule()
                RetouchStrokeList(model: model)
                RetouchSelectionCard(model: model, fillAvailable: fillAvailable)
            }
            if !model.pendingFills.isEmpty { filling }
            Rule()
            distractions
        }.font(.system(size: 12)).padding(20).disabled(!model.hasImage || model.busy)
    }

    /// What the finders take out, each a row that opens in place: found, reviewed as pins, then kept or deleted.
    /// Blemishes are the Portrait tab's.
    @ViewBuilder private var distractions: some View {
        Text(L10n.tr("Distraction Removal")).font(.system(size: 13, weight: .semibold))
        // The cards sit as close as Portrait's. Dust is reviewed on the photo while its row is open.
        VStack(alignment: .leading, spacing: 8) {
            DisclosureRow(title: L10n.tr("Dust"), symbol: "aqi.low", open: Binding(get: { model.retouchTool == .dust }, set: { open in
                model.retouchPointer = false; model.retouchSelecting = false; model.retouchObject = false
                model.retouchTool = open ? .dust : .remove
            })) { DustSection(model: model) }
            DisclosureRow(title: L10n.tr("People"), symbol: "person.2", open: $peopleOpen) { people }
        }
    }
    /// The brush put down: the photo zooms and pans with the hand (Esc does the same).
    private var pointerButton: some View {
        modeButton("hand.raised", help: L10n.tr("Hand (Esc)"), label: L10n.tr("Hand"), active: model.retouchPointer && !model.retouchSelecting && !model.retouchObject) {
            model.retouchSelecting = false; model.retouchObject = false; model.retouchPointer = true
        }
    }
    /// Select: click or box stroke pins to change or delete several at once; nothing is painted or panned.
    private var selectButton: some View {
        modeButton("cursorarrow", help: L10n.tr("Select: click or drag a box over the pins; Delete removes them"), label: L10n.tr("Select"), active: model.retouchSelecting && !model.retouchObject) {
            model.retouchPointer = false; model.retouchObject = false; model.retouchSelecting = true
        }
    }
    /// Object: a click removes the thing under it, outlined by Vision, or the wire under it, followed along its length.
    private var objectButton: some View {
        modeButton("cursorarrow.rays", help: L10n.tr("Object: click something to remove it; a wire is followed along its length. Shift-click collects several, Option-click drops one"), label: L10n.tr("Object"), active: model.retouchObject) {
            model.retouchPointer = false; model.retouchSelecting = false; model.retouchObject = true
        }
    }
    private func modeButton(_ symbol: String, help: String, label: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17)).frame(width: 32, height: 34)
                .foregroundStyle(active ? Theme.onAccent : .primary)
                .background(active ? Theme.accent : Theme.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(help).accessibilityLabel(label).accessibilityAddTraits(active ? .isSelected : [])
    }
    private func toolButton(_ tool: RetouchTool) -> some View {
        let active = model.retouchTool == tool && !model.retouchPointer && !model.retouchSelecting && !model.retouchObject
        return Button { model.editingFaceRegion = false; model.retouchPointer = false; model.retouchSelecting = false; model.retouchObject = false; model.retouchTool = tool } label: {
            Image(systemName: tool.symbol).font(.system(size: 17)).frame(width: 32, height: 34)
                .foregroundStyle(active ? Theme.onAccent : .primary)
                .background(active ? Theme.accent : Theme.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(tool.mode == nil ? tool.localizedTitle : tool.localizedTitle + " — " + brushHelp(tool))
            .accessibilityLabel(tool.localizedTitle).accessibilityAddTraits(active ? .isSelected : [])
    }
    /// The brush for the next stroke; a stroke already painted is changed in the Selected card.
    @ViewBuilder private var brush: some View {
        RetouchSlider(model: model, title: L10n.tr("Size"), value: $model.retouchRadius, range: 0.001...0.15).help(L10n.tr("[ and ] resize the brush"))
        if model.retouchTool != .remove { RetouchSlider(model: model, title: L10n.tr("Feather"), value: $model.retouchSoftness, range: 0...1) }
        if model.retouchTool == .remove {
            Toggle(L10n.tr("AI fill"), isOn: Binding(get: { fillAvailable && model.retouchGenerative }, set: { model.retouchGenerative = $0 })).toggleStyle(.formCheckbox).disabled(!fillAvailable)
                .help(L10n.tr("An inpainting model redraws what is painted over from its surroundings, instead of copying a patch"))
            if !fillAvailable { ModelPrompt(model: .inpaint) }
        }
    }
    private func brushHelp(_ tool: RetouchTool) -> String {
        let how = tool == .remove ? (fillAvailable && model.retouchGenerative ? L10n.tr("Paint over what should go; an inpainting model redraws it from its surroundings.")
                                                                                     : L10n.tr("Paint over what should go; it is filled from a matching area nearby."))
                                          : L10n.tr("Paint over what should go. A source is chosen automatically; drag it on the photo to use another area.")
        return how + " " + L10n.tr("Shift-click continues the selected stroke in a straight line.")
    }
    /// People who are not the subject: found, then removed as strokes listed under People, whose pins are deleted to
    /// keep someone.
    @ViewBuilder private var people: some View {
        Button { model.findPeople() } label: {
            HStack(spacing: 6) {
                if model.findingPeople { ProgressView().controlSize(.mini) }
                Text(L10n.tr("Find People"))
            }.frame(maxWidth: .infinity)
        }
            .buttonStyle(.secondaryAction).disabled(model.busy || model.adjustments.retouch.count >= DustFinder.strokeLimit)
        if let report = model.peopleReport { Text(report).font(.system(size: 11)).foregroundStyle(.secondary) }
        // Without the scene model only the larger, sharper people are found; without AI fill they are patched.
        if !BundledModel.scene.isAvailable { ModelPrompt(model: .scene) }
        if !fillAvailable { ModelPrompt(model: .inpaint) }
    }
    /// Fills being made: the first in a session waits while the model loads onto the Neural Engine, about ten seconds.
    private var filling: some View {
        let count = model.pendingFills.count
        return HStack(spacing: 8) {
            // A long or wide stroke takes several windows: the ring fills as they are done.
            if count == 1, let progress = model.fillProgress {
                ProgressView(value: Double(progress.done), total: Double(progress.total)).progressViewStyle(.circular).controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(count == 1 ? L10n.tr("Making the AI fill…") : L10n.tr("Making \(count) AI fills…")).foregroundStyle(.secondary)
            Spacer()
            Button(L10n.tr("Cancel")) { model.cancelFills() }.buttonStyle(.secondaryAction).controlSize(.small)
                .help(L10n.tr("Stop, and keep a patch fill for these strokes (Esc)"))
        }
    }
}

/// Every stroke of the edit, whichever tool is open: the hand-drawn ones in the order painted, then the dust finder's as
/// one group that opens. A click selects a stroke and opens its tool; ⇧ and ⌘ select several, as does the group's name.
/// The list takes no keyboard focus: Delete and Escape act on the selection from anywhere in Retouch.
struct RetouchStrokeList: View {
    @ObservedObject var model: EditorModel
    @State private var dustExpanded = false
    @State private var faceExpanded = false
    @State private var peopleExpanded = false
    private static let rowHeight = 24.0
    var body: some View {
        // Portrait lists its own strokes; Remove lists the hand-drawn ones, then people, face and dust strokes as groups.
        let inFace = model.toolTab == .face
        let all = model.adjustments.retouch
        // Portrait's spots are the selected people's.
        let drawn = all.filter { $0.group == (inFace ? .face : .drawn) && (!inFace || model.isSelected($0.faceBox)) }
        let face = inFace ? [] : all.filter { $0.group == .face }, dust = inFace ? [] : all.filter { $0.group == .dust }
        let people = inFace ? [] : all.filter { $0.group == .people }
        let order = drawn.map(\.id) + (peopleExpanded ? people.map(\.id) : []) + (faceExpanded ? face.map(\.id) : []) + (dustExpanded ? dust.map(\.id) : [])
        let rows = drawn.count + (people.isEmpty ? 0 : 1 + (peopleExpanded ? people.count : 0)) + (face.isEmpty ? 0 : 1 + (faceExpanded ? face.count : 0)) + (dust.isEmpty ? 0 : 1 + (dustExpanded ? dust.count : 0))
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(inFace ? L10n.tr("SPOTS") : L10n.tr("STROKES")).font(.system(size: 10, weight: .semibold))
                Text(L10n.tr("\(drawn.count + people.count + face.count + dust.count)")).monospacedDigit().foregroundStyle(.secondary)
            }.help(L10n.tr("Shift- or Command-click selects several, here or on the photo; Option-drag on the photo boxes them"))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(zip(drawn, inFace ? drawn.indices.map { L10n.tr("Spot \($0 + 1)") } : Self.titles(drawn))), id: \.0.id) { stroke, title in row(stroke, title: title, order: order).id(stroke.id) }
                        if !people.isEmpty {
                            groupHeader(L10n.tr("People"), people, expanded: $peopleExpanded, enableLabel: L10n.tr("Enable people strokes"), delete: { model.removeStrokes(in: .people) })
                            if peopleExpanded { ForEach(Array(people.enumerated()), id: \.element.id) { index, stroke in row(stroke, title: L10n.tr("Person \(index + 1)"), order: order).id(stroke.id) } }
                        }
                        if !face.isEmpty {
                            groupHeader(L10n.tr("Face spots"), face, expanded: $faceExpanded, enableLabel: L10n.tr("Enable face strokes"), delete: { model.removeStrokes(in: .face) })
                            if faceExpanded { ForEach(Array(zip(face, Self.titles(face))), id: \.0.id) { stroke, title in row(stroke, title: title, order: order).id(stroke.id) } }
                        }
                        if !dust.isEmpty {
                            dustHeader(dust)
                            if dustExpanded { ForEach(Array(dust.enumerated()), id: \.element.id) { index, stroke in row(stroke, title: L10n.tr("Spot \(index+1)"), order: order).id(stroke.id) } }
                        }
                    }
                }.frame(height: min(204, Double(rows) * (Self.rowHeight + 1)))
                // Picking a stroke on the photo brings its row into view, opening its group.
                .onChange(of: model.selectedRetouchID) { _, id in
                    guard let id, let stroke = model.adjustments.retouch.first(where: { $0.id == id }) else { return }
                    if stroke.group == .dust, !dustExpanded { dustExpanded = true }
                    if stroke.group == .face, !inFace, !faceExpanded { faceExpanded = true }
                    if stroke.group == .people, !peopleExpanded { peopleExpanded = true }
                    withAnimation { proxy.scrollTo(id) }
                }
            }
        }
    }
    /// "Remove 1", "Heal 1", "Remove 2": each fill type numbered among its own.
    private static func titles(_ strokes: [RetouchStroke]) -> [String] {
        var counts: [RetouchMode: Int] = [:]
        return strokes.map { stroke in counts[stroke.mode, default: 0] += 1; return "\(stroke.mode.localizedTitle) \(counts[stroke.mode]!)" }
    }
    private func row(_ stroke: RetouchStroke, title: String, order: [UUID]) -> some View {
        let selected = model.selectedRetouchIDs.contains(stroke.id)
        return HStack(spacing: 6) {
            Button {
                model.clickRetouch(stroke.id, in: order, extending: SelectionClick.extending, toggling: SelectionClick.toggling)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: stroke.suggested || model.toolTab == .face ? "circle.dashed" : RetouchTool(stroke.mode).symbol).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                    Text(title).foregroundStyle(stroke.enabled ? .primary : .secondary); Spacer()
                }.frame(height: Self.rowHeight).contentShape(Rectangle())
            }.buttonStyle(.plain).focusable(false)
            if model.pendingFills.contains(stroke.id) {
                ProgressView().controlSize(.mini).help(L10n.tr("Making the AI fill…"))
            } else if stroke.mode == .remove, stroke.generative {
                let missing = stroke.needsFill
                Image(systemName: missing ? "exclamationmark.triangle" : "wand.and.rays").font(.system(size: 11)).foregroundStyle(missing ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.secondary))
                    .help(missing ? L10n.tr("No AI fill yet; a patch fills it") : L10n.tr("AI fill"))
                    .accessibilityLabel(missing ? L10n.tr("No AI fill yet; a patch fills it") : L10n.tr("AI fill"))
            }
            // The box of a selected row switches the whole selection.
            Toggle(L10n.tr("Enable stroke"), isOn: Binding(get: { stroke.enabled }, set: { model.setRetouchEnabled(stroke.id, $0) })).labelsHidden().toggleStyle(.formCheckbox).focusable(false)
        }.padding(.horizontal, 8).frame(height: Self.rowHeight).font(.system(size: stroke.suggested ? 11 : 12))
            .background(selected ? Theme.ink.opacity(0.12) : model.hoveredRetouchID == stroke.id ? Theme.ink.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { model.hoveredRetouchID = stroke.id } else if model.hoveredRetouchID == stroke.id { model.hoveredRetouchID = nil }
            }
            .contextMenu {
                let ids = selected ? model.selectedRetouchIDs : [stroke.id]
                Button(L10n.tr("Refresh")) { model.refreshRetouch(ids) }
                Button(L10n.tr("Delete"), role: .destructive) { model.removeRetouch(ids) }
            }
    }
    /// A found group (Portrait's face spots, Distraction Removal's people) as one row in Retouch: its name selects
    /// them all, its box switches them, and its menu deletes them.
    private func groupHeader(_ title: String, _ strokes: [RetouchStroke], expanded: Binding<Bool>, enableLabel: String, delete: @escaping () -> Void) -> some View {
        let ids = Set(strokes.map(\.id)), selected = ids.isSubset(of: model.selectedRetouchIDs)
        return HStack(spacing: 6) {
            Button { expanded.wrappedValue.toggle() } label: {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0)).frame(width: 14, height: Self.rowHeight).contentShape(Rectangle())
            }.buttonStyle(.plain).focusable(false).accessibilityLabel(title).accessibilityValue(expanded.wrappedValue ? L10n.tr("Expanded") : L10n.tr("Collapsed"))
            Button { model.selectedRetouchIDs = ids; model.selectedRetouchID = strokes.last?.id } label: {
                HStack(spacing: 6) { Text(title); Text(L10n.tr("\(strokes.count)")).monospacedDigit().foregroundStyle(.secondary); Spacer() }
                    .frame(height: Self.rowHeight).contentShape(Rectangle())
            }.buttonStyle(.plain).focusable(false)
            Toggle(enableLabel, isOn: Binding(get: { strokes.allSatisfy(\.enabled) }, set: { v in model.edit { a in for i in a.retouch.indices where ids.contains(a.retouch[i].id) { a.retouch[i].enabled = v } } })).labelsHidden().toggleStyle(.formCheckbox).focusable(false)
        }.padding(.horizontal, 8).frame(height: Self.rowHeight)
            .background(selected ? Theme.ink.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .contentShape(Rectangle())
            .contextMenu { Button(L10n.tr("Delete All"), role: .destructive, action: delete) }
    }
    /// The dust finder's strokes as one row: its name selects them all, to resize, fade or delete together.
    private func dustHeader(_ dust: [RetouchStroke]) -> some View {
        let ids = Set(dust.map(\.id)), selected = ids.isSubset(of: model.selectedRetouchIDs)
        return HStack(spacing: 6) {
            Button { dustExpanded.toggle() } label: {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(dustExpanded ? 90 : 0)).frame(width: 14, height: Self.rowHeight).contentShape(Rectangle())
            }.buttonStyle(.plain).focusable(false).accessibilityLabel(L10n.tr("Dust spots")).accessibilityValue(dustExpanded ? L10n.tr("Expanded") : L10n.tr("Collapsed"))
            Button { model.selectDustStrokes() } label: {
                HStack(spacing: 6) { Text(L10n.tr("Dust spots")); Text(L10n.tr("\(dust.count)")).monospacedDigit().foregroundStyle(.secondary); Spacer() }
                    .frame(height: Self.rowHeight).contentShape(Rectangle())
            }.buttonStyle(.plain).focusable(false)
            Button { model.dustShowHealed.toggle() } label: { Image(systemName: model.dustShowHealed ? "eye" : "eye.slash").font(.system(size: 11)) }.buttonStyle(.plain).focusable(false)
                .help(L10n.tr("Shows healed spots on the photo (dashed), to pick out false ones and remove their healing"))
                .accessibilityLabel(L10n.tr("Show healed spots"))
            Toggle(L10n.tr("Enable dust strokes"), isOn: Binding(get: { dust.allSatisfy(\.enabled) }, set: { v in model.edit { a in for i in a.retouch.indices where a.retouch[i].suggested { a.retouch[i].enabled = v } } })).labelsHidden().toggleStyle(.formCheckbox).focusable(false)
        }.padding(.horizontal, 8).frame(height: Self.rowHeight)
            .background(selected ? Theme.ink.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .contentShape(Rectangle())
            .contextMenu { Button(L10n.tr("Delete All"), role: .destructive) { model.removeRetouch(ids) } }
    }
}

/// What is selected, one stroke or many (found dust spots too), and the settings they share: a change goes to all of
/// them as one undo step.
struct RetouchSelectionCard: View {
    @ObservedObject var model: EditorModel
    let fillAvailable: Bool
    var body: some View {
        let strokes = model.selectedStrokes, spots = model.selectedFoundSpots, count = strokes.count + spots.count
        if count > 0 {
            let face = model.toolTab == .face
            let drawn = spots.isEmpty && strokes.allSatisfy { !$0.suggested } && !face
            let generative = strokes.filter { $0.mode == .remove && $0.generative }
            // People strokes follow a person's outline: no brush type or size to change, only how they are filled.
            let people = !strokes.isEmpty && spots.isEmpty && strokes.allSatisfy { $0.group == .people }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text(count == 1 ? (strokes.isEmpty || face ? L10n.tr("SELECTED SPOT") : L10n.tr("SELECTED STROKE")) : L10n.tr("\(count) SELECTED")).font(.system(size: 10, weight: .semibold)); Spacer()
                    if !strokes.isEmpty {
                        Button { model.refreshRetouch(model.selectedRetouchIDs) } label: { Image(systemName: "arrow.triangle.2.circlepath") }.buttonStyle(.plain)
                            .help(strokes.allSatisfy { $0.mode == .tone } ? L10n.tr("Meter the spot against its surroundings.") : generative.count == strokes.count ? L10n.tr("Make another AI fill (⇧R)") : L10n.tr("Use another source (⇧R)")).accessibilityLabel(L10n.tr("Refresh"))
                            .disabled(generative.count == strokes.count && (!fillAvailable || generative.allSatisfy { model.pendingFills.contains($0.id) }))
                    }
                    Button(action: model.deleteSelectedRetouch) { Image(systemName: "trash") }.buttonStyle(.plain).help(L10n.tr("Delete (Delete)")).accessibilityLabel(L10n.tr("Delete"))
                }
                // The fill type of hand-drawn strokes that share one; changing it keeps each footprint and source.
                if drawn, let mode = strokes.first?.mode, strokes.allSatisfy({ $0.mode == mode }) {
                    if !people { HStack {
                        Text(L10n.tr("Type"))
                        Spacer()
                        PanelPicker(title: L10n.tr("Type"), selection: Binding(get: { mode }, set: { model.setRetouchFill($0) }), options: mode == .tone ? RetouchMode.allCases : [.remove, .heal, .clone], label: \.localizedTitle, icon: { RetouchTool($0).symbol }).controlSize(.small)
                    } }
                    if mode == .remove {
                        // Off is "use patch fill": the stroke keeps its footprint and takes a patch from nearby.
                        Toggle(L10n.tr("AI fill"), isOn: Binding(get: { generative.count == strokes.count }, set: { model.setGenerative(model.selectedRetouchIDs, $0) })).toggleStyle(.formCheckbox)
                            .disabled(!fillAvailable && generative.isEmpty)
                            .help(L10n.tr("Turn off to fill this stroke with a patch from nearby instead"))
                        if strokes.count == 1, let failure = model.fillFailure(strokes[0]) {
                            Label(L10n.tr("\(failure) A patch fills it instead."), systemImage: "exclamationmark.triangle")
                                .font(.system(size: 11)).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                        } else if !fillAvailable, generative.contains(where: \.needsFill) {
                            ModelPrompt(model: .inpaint)
                        }
                    }
                }
                if !people {
                    RetouchSlider(model: model, title: L10n.tr("Size"), value: Binding(get: { strokes.first?.radius ?? spots.first?.radius ?? 0 }, set: model.setSelectedRetouchRadius),
                                  range: 0.001...0.15, gesture: true, ended: model.resizedSelectedRetouch)
                }
                if strokes.contains(where: { $0.mode != .remove }) { RetouchSlider(model: model, title: L10n.tr("Feather"), value: value(strokes, \.softness), range: 0...1, gesture: true) }
                if !strokes.isEmpty, strokes.allSatisfy({ $0.mode == .tone }) {
                    let ev = value(strokes, \.exposure)
                    HStack {
                        Text(L10n.tr("Exposure")); Spacer()
                        EditableValue(label: String(format: "%+.2f EV", ev.wrappedValue), value: ev.wrappedValue, range: -2...2, precision: 2, title: L10n.tr("Exposure"), width: 66, size: 12) { ev.wrappedValue = $0 }
                    }
                    FormSlider(value: ev, in: -2...2) { if $0 { model.beginGesture() } else { model.endGesture() } }
                }
                if !strokes.isEmpty { RetouchSlider(model: model, title: L10n.tr("Opacity"), value: value(strokes, \.opacity), range: 0...1, gesture: true) }
            }.padding(10).background(Theme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
    }
    /// Shows the first selected stroke's value and sets every selected stroke's.
    private func value(_ strokes: [RetouchStroke], _ key: WritableKeyPath<RetouchStroke, Double>) -> Binding<Double> {
        Binding(get: { strokes.first?[keyPath: key] ?? 0 }, set: { v in model.updateSelectedRetouch { $0[keyPath: key] = v } })
    }
}

extension EditorModel {
    var selectedRetouch: RetouchStroke? { adjustments.retouch.first { $0.id == selectedRetouchID } }
    var selectedStrokes: [RetouchStroke] { selectedRetouchIDs.isEmpty ? [] : adjustments.retouch.filter { selectedRetouchIDs.contains($0.id) } }
    /// Selected dust spots still under review, which are not strokes yet.
    var selectedFoundSpots: [DustSpot] { selectedRetouchIDs.isEmpty ? [] : dustSpots.filter { selectedRetouchIDs.contains($0.id) } }
    /// What the active tool shows as handles on the photo, to click or box: a brush the hand-drawn strokes' pins, Dust
    /// Spots the found spots and the healed ones while they show.
    var retouchHandleIDs: [UUID] {
        switch retouchTool {
        case .dust: return shownDustSpots.map(\.id)
        default: return adjustments.retouch.filter(showsRetouchPin).map(\.id)
        }
    }
    /// A stroke whose pin the brushes show: every hand-made stroke in Retouch, only face strokes in Portrait.
    func showsRetouchPin(_ stroke: RetouchStroke) -> Bool { toolTab == .face ? stroke.group == .face : !stroke.suggested }
    /// Selecting one stroke opens its tool, the brush of its fill type or Dust Spots, so the photo shows its handles.
    func selectRetouch(_ id: UUID?) {
        if let stroke = adjustments.retouch.first(where: { $0.id == id }) {
            if stroke.suggested { retouchTool = .dust; dustShowHealed = true } else { retouchTool = RetouchTool(stroke.mode) }
        }
        selectedRetouchID = id
    }
    /// A click in the stroke list, with ⇧ for a range and ⌘ to toggle; `order` is the rows as shown.
    func clickRetouch(_ id: UUID, in order: [UUID], extending: Bool, toggling: Bool) {
        // Picking from the list takes up the stroke's tool, unless several are being selected.
        if !retouchSelecting { retouchPointer = false }
        var picked = MultiSelection(ids: selectedRetouchIDs, anchor: retouchSelectionAnchor)
        picked.click(id, in: order, extending: extending, toggling: toggling)
        if picked.ids == [id] { selectRetouch(id) } else { selectedRetouchIDs = picked.ids }
        retouchSelectionAnchor = picked.anchor
    }
    /// ⇧-click on a handle on the photo: in or out of the selection.
    func toggleRetouchSelection(_ id: UUID) {
        if selectedRetouchIDs.contains(id) { selectedRetouchIDs.remove(id) } else { selectedRetouchIDs.insert(id) }
        retouchSelectionAnchor = id
    }
    /// Every stroke the dust finder made, selected in Dust Spots where the photo shows them.
    func selectDustStrokes() {
        retouchTool = .dust; dustShowHealed = true
        selectedRetouchIDs = Set(adjustments.retouch.lazy.filter(\.suggested).map(\.id))
    }
    /// A face spot where the person clicked: a Heal dab the size of the spots already found (or a small default),
    /// its source chosen at once, one undo step.
    func addFaceSpot(_ target: MaskPoint) {
        guard !busy, adjustments.retouch.count < DustFinder.strokeLimit else { return }
        let sizes = adjustments.retouch.filter { $0.group == .face }.map(\.radius).sorted()
        var stroke = RetouchStroke(mode: .heal, source: target, target: target, radius: sizes.isEmpty ? 0.01 : sizes[sizes.count / 2], softness: 0.4, opacity: 1)
        stroke.face = true
        selectedRetouchIDs = [stroke.id]; selectedRetouchID = stroke.id
        edit { $0.retouch.append(stroke) }
        chooseRetouchSource(stroke.id)
    }
    func startRetouch(_ target: MaskPoint) {
        guard !busy, let mode = retouchTool.mode, let info, adjustments.retouch.count < DustFinder.strokeLimit else { return }
        // Beside the stroke until the chosen source arrives.
        let shift = 2.5 * retouchRadius * Double(min(info.width, info.height)) / Double(info.width)
        let source = MaskPoint(x: target.x < 0.5 ? min(1, target.x + shift) : max(0, target.x - shift), y: target.y)
        beginGesture()
        var stroke = RetouchStroke(mode: mode, source: source, target: target, radius: retouchRadius, softness: mode == .remove ? 0.3 : retouchSoftness, opacity: 1)
        stroke.face = toolTab == .face
        if mode == .tone { stroke.source = target }
        stroke.generative = mode == .remove && retouchGenerative && BundledModel.inpaint.isAvailable
        selectedRetouchID = stroke.id
        edit { $0.retouch.append(stroke) }
    }
    func dragRetouch(_ point: MaskPoint) {
        guard let index = adjustments.retouch.firstIndex(where: { $0.id == selectedRetouchID }), let last = adjustments.retouch[index].points.last,
              hypot(last.x - point.x, last.y - point.y) > 0.001 else { return }
        edit { $0.retouch[index].points.append(point) }
    }
    /// The stroke a Shift-click carries on: the selected hand-drawn stroke of the active brush.
    var extendableRetouch: RetouchStroke? {
        guard let stroke = selectedRetouch, !stroke.suggested, stroke.mode == retouchTool.mode, !stroke.points.isEmpty else { return nil }
        return stroke
    }
    /// Shift-click: a straight line from the selected stroke's last point to `point`, as part of that stroke, so an AI fill
    /// takes all of it as one hole; dragging on paints more of it. False when there is no stroke to carry on.
    @discardableResult func extendRetouch(to point: MaskPoint) -> Bool {
        guard !busy, let stroke = extendableRetouch, let index = adjustments.retouch.firstIndex(where: { $0.id == stroke.id }) else { return false }
        beginGesture()
        edit { $0.retouch[index].points.append(point) }
        return true
    }
    /// Ending the stroke queues its AI fill (`endGesture`); the source is still chosen, for the patch shown until then. A
    /// Heal or Clone stroke that was carried on (`extended`) keeps its source, which may have been placed by hand.
    func endRetouch(extended: Bool = false) {
        endGesture()
        if let stroke = selectedRetouch, !extended || stroke.mode == .remove { chooseRetouchSource(stroke.id) }
    }
    /// Refresh (⇧R): another AI fill for each stroke that has one, another source for the others.
    func refreshRetouch(_ ids: Set<UUID>) {
        let strokes = adjustments.retouch.filter { ids.contains($0.id) }
        let filled = Set(strokes.filter { $0.mode == .remove && $0.generative }.map(\.id))
        if !filled.isEmpty { refreshFills(filled) }
        chooseRetouchSources(Set(strokes.map(\.id)).subtracting(filled), refresh: true)
    }
    func refreshRetouch(_ id: UUID) { refreshRetouch([id]) }
    func chooseRetouchSource(_ id: UUID, refresh: Bool = false) { chooseRetouchSources([id], refresh: refresh) }
    /// Picks sources on the photo as developed, from one look at it. After painting, moving or resizing they replace the
    /// ones in place without an undo step of their own; Refresh is one edit and keeps away from the sources tried before.
    /// A stroke that changed meanwhile keeps what it has.
    func chooseRetouchSources(_ ids: Set<UUID>, refresh: Bool = false) {
        let strokes = adjustments.retouch.filter { ids.contains($0.id) }
        guard let renderer, !strokes.isEmpty else { return }
        for stroke in strokes {
            if refresh { refusedRetouchSources[stroke.id, default: []].append(stroke.source) } else { refusedRetouchSources[stroke.id] = nil }
        }
        let settings = adjustments, refused = refusedRetouchSources.filter { ids.contains($0.key) }
        Task {
            do {
                let tonal = strokes.filter { $0.mode == .tone }
                let patches = strokes.filter { $0.mode != .tone }
                let exposures = try await renderer.spotExposures(for: tonal, settings: settings)
                let sources = patches.isEmpty ? [:] : try await renderer.retouchSources(for: patches, settings: settings, refused: refused)
                guard self.renderer === renderer else { return }
                let update: (inout Adjustments) -> Void = { a in
                    for stroke in strokes {
                        if let ev = exposures[stroke.id], let i = a.retouch.firstIndex(where: { $0 == stroke }) {
                            a.retouch[i].exposure = ev
                        }
                        if let source = sources[stroke.id],
                           let i = a.retouch.firstIndex(where: { $0.id == stroke.id && $0.mode == stroke.mode && $0.source == stroke.source && $0.points == stroke.points && $0.radius == stroke.radius }) {
                            a.retouch[i].source = source
                        }
                    }
                }
                if refresh { edit(update) } else { editSilently(update) }
            } catch is CancellationError {
            } catch { if self.renderer === renderer { self.error = error.localizedDescription } }
        }
    }
    func updateRetouch(_ id: UUID, _ change: (inout RetouchStroke) -> Void) {
        edit { a in if let i = a.retouch.firstIndex(where: { $0.id == id }) { change(&a.retouch[i]) } }
    }
    /// One change to every selected stroke, as one edit.
    func updateSelectedRetouch(_ change: (inout RetouchStroke) -> Void) {
        let ids = selectedRetouchIDs
        edit { a in for i in a.retouch.indices where ids.contains(a.retouch[i].id) { change(&a.retouch[i]) } }
    }
    /// The selected strokes' fill type; one stroke takes its brush along.
    func setRetouchFill(_ mode: RetouchMode) {
        let ids = selectedRetouchIDs
        let remeter = Set(selectedStrokes.filter { $0.mode != mode && ($0.mode == .tone || mode == .tone) }.map(\.id))
        updateSelectedRetouch { if $0.mode != mode { $0.mode = mode; $0.exposure = 0 } }
        chooseRetouchSources(remeter)
        if ids.count == 1 { retouchTool = RetouchTool(mode); selectedRetouchIDs = ids }
    }
    /// The size of everything selected: strokes, and found dust spots.
    func setSelectedRetouchRadius(_ radius: Double) {
        let radius = min(0.15, max(0.001, radius))
        updateSelectedRetouch { $0.radius = radius }
        for i in dustSpots.indices where selectedRetouchIDs.contains(dustSpots[i].id) { dustSpots[i].radius = radius }
    }
    /// After the Size slider: strokes whose source was chosen for them (Remove, and dust) take one that fits the new size;
    /// Heal and Clone keep theirs, which may have been placed by hand.
    func resizedSelectedRetouch() {
        chooseRetouchSources(Set(selectedStrokes.filter { $0.mode == .remove || $0.suggested }.map(\.id)))
    }
    /// A row's checkbox; on a selected row it switches the whole selection.
    func setRetouchEnabled(_ id: UUID, _ on: Bool) {
        let ids = selectedRetouchIDs.contains(id) ? selectedRetouchIDs : [id]
        edit { a in for i in a.retouch.indices where ids.contains(a.retouch[i].id) { a.retouch[i].enabled = on } }
    }
    /// Removes strokes in one undoable edit, and found dust spots, which are not part of the edit yet.
    func removeRetouch(_ ids: Set<UUID>) {
        dustSpots.removeAll { ids.contains($0.id) }
        pendingFills.removeAll { ids.contains($0) }
        if adjustments.retouch.contains(where: { ids.contains($0.id) }) { edit { $0.retouch.removeAll { ids.contains($0.id) } } }
        selectedRetouchIDs.subtract(ids)
    }
    func deleteSelectedRetouch() { removeRetouch(selectedRetouchIDs) }

    // MARK: AI fill

    static func fillKey(_ stroke: RetouchStroke) -> String { "\(stroke.id) \(RetouchFill.footprint(of: stroke))" }
    /// Why the stroke has no AI fill, when one was tried for its current footprint and could not be made.
    func fillFailure(_ stroke: RetouchStroke) -> String? { stroke.needsFill ? fillFailures[Self.fillKey(stroke)] : nil }
    /// Queues every stroke that asks for an AI fill and has none for its footprint: after it is drawn or moved, an undo,
    /// a paste, an agent's edit, or opening a photo whose fills were left out of XMP. Never in the middle of a gesture.
    func scheduleFills() {
        guard renderer != nil, gestureStart == nil, BundledModel.inpaint.isAvailable, adjustments.retouch.contains(where: \.generative) else { return }
        for stroke in adjustments.retouch where stroke.needsFill && !pendingFills.contains(stroke.id) && fillFailures[Self.fillKey(stroke)] == nil {
            pendingFills.append(stroke.id)
        }
        if fillTask == nil, !pendingFills.isEmpty { fillTask = Task { await runFills() } }
    }
    /// Makes the queued fills in stroke order, each from the photo with the strokes before it applied, so a later
    /// stroke's fill sees the earlier ones filled. A fill lands without an undo step of its own, and only on states of the
    /// photo where the stroke still has the footprint it was made for.
    private func runFills() async {
        while !Task.isCancelled, let renderer, let stroke = adjustments.retouch.first(where: { pendingFills.contains($0.id) }) {
            let id = stroke.id
            guard stroke.needsFill else { pendingFills.removeAll { $0 == id }; continue }
            do {
                let job = try await renderer.prepareInpaint(id, settings: adjustments, variant: fillVariants[id] ?? 0)
                fillProgress = job.windows > 1 ? (0, job.windows) : nil
                defer { fillProgress = nil }
                // Off the main actor; cancelling this task stops the job between windows.
                let work = Task.detached(priority: .userInitiated) {
                    try await job.run(on: renderer) { done, total in Task { @MainActor in if self.fillProgress != nil { self.fillProgress = (done, total) } } }
                }
                let fill = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard !Task.isCancelled, self.renderer === renderer else { return }
                editSilently { a in
                    for i in a.retouch.indices where a.retouch[i].id == id && a.retouch[i].needsFill && RetouchFill.footprint(of: a.retouch[i]) == fill.footprint {
                        a.retouch[i].fill = fill
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.renderer === renderer else { return }
                fillFailures[Self.fillKey(stroke)] = error.localizedDescription
            }
            pendingFills.removeAll { $0 == id }
        }
        if !Task.isCancelled { fillTask = nil; pendingFills = [] }
    }
    /// Escape or Cancel: stops making fills. The strokes waiting turn to patch fills, as one undoable edit, so Undo asks
    /// for their fills again.
    @discardableResult func cancelFills() -> Bool {
        guard !pendingFills.isEmpty else { return false }
        let ids = Set(pendingFills)
        fillTask?.cancel(); fillTask = nil; pendingFills = []; fillProgress = nil
        edit { a in for i in a.retouch.indices where ids.contains(a.retouch[i].id) { a.retouch[i].generative = false } }
        return true
    }
    func resetFills() {
        fillTask?.cancel(); fillTask = nil; pendingFills = []; fillProgress = nil; fillFailures = [:]; fillVariants = [:]
    }
    /// The AI fill toggle of Remove strokes; off drops their fills and uses a patch.
    func setGenerative(_ ids: Set<UUID>, _ on: Bool) {
        if on { ids.forEach(forgetFillFailures) }
        // A fill already being made is dropped when it lands, since the stroke no longer asks for one.
        if !on { pendingFills.removeAll { ids.contains($0) } }
        edit { a in
            for i in a.retouch.indices where ids.contains(a.retouch[i].id) && a.retouch[i].mode == .remove {
                a.retouch[i].generative = on; if !on { a.retouch[i].fill = nil }
            }
        }
    }
    func setGenerative(_ id: UUID, _ on: Bool) { setGenerative([id], on) }
    /// Other fills from other windows around the strokes; Undo brings back the ones they replace.
    func refreshFills(_ ids: Set<UUID>) {
        for id in ids { fillVariants[id, default: 0] += 1; forgetFillFailures(id) }
        edit { a in for i in a.retouch.indices where ids.contains(a.retouch[i].id) { a.retouch[i].fill = nil } }
        scheduleFills()
    }
    private func forgetFillFailures(_ id: UUID) {
        let prefix = id.uuidString + " "
        fillFailures = fillFailures.filter { !$0.key.hasPrefix(prefix) }
    }
}

extension EditorModel {
    func resetBlemishSearch() {
        if let faceTask { faceTask.cancel(); self.faceTask = nil; isSelecting = false; selectionStatus = "" }
        faceLookup?.cancel(); faceLookup = nil
        blemishReport = nil; peopleReport = nil
        faceRegion = nil; liquifyBase = nil; editingFaceRegion = false; showingLiquify = false
    }

    /// Runs one Portrait analysis behind the selection progress; a reset cancels it and clears the progress itself.
    func runFaceTask(_ status: String, _ work: @escaping @MainActor (RawRenderer) async throws -> Void) {
        guard !busy, let renderer else { return }
        isSelecting = true; selectionStatus = status; blemishReport = nil
        faceTask = Task {
            defer { if !Task.isCancelled { faceTask = nil; isSelecting = false; selectionStatus = "" } }
            do {
                try await work(renderer)
            } catch is CancellationError {
            } catch { if !Task.isCancelled && self.renderer === renderer { self.error = error.localizedDescription } }
        }
    }

    /// Every person but the subject becomes Remove strokes under People, replacing those found before; deleting one's
    /// pin keeps that person.
    /// While Find People runs, its button shows a spinner.
    var findingPeople: Bool { isSelecting && selectionStatus == Self.findingPeopleStatus }
    private static let findingPeopleStatus = L10n.tr("Finding people…")
    func findPeople() {
        let settings = adjustments
        editingFaceRegion = false; peopleReport = nil
        runFaceTask(Self.findingPeopleStatus) { [self] renderer in
            let (found, made) = try await renderer.distractingPeople(settings)
            try Task.checkCancellation()
            guard self.renderer === renderer else { return }
            let room = DustFinder.strokeLimit - adjustments.retouch.filter { $0.group != .people }.count
            let strokes = Array(made.prefix(max(0, room)))
            peopleReport = found == 0 ? L10n.tr("No people found") : strokes.isEmpty ? L10n.tr("Only the subject found") : nil
            guard !strokes.isEmpty || adjustments.retouch.contains(where: { $0.group == .people }) else { return }
            selectedRetouchIDs.subtract(adjustments.retouch.filter { $0.group == .people }.map(\.id))
            edit { $0.retouch = $0.retouch.filter { $0.group != .people } + strokes }
            let patched = Set(strokes.filter { !$0.generative }.map(\.id))
            if !patched.isEmpty { chooseRetouchSources(patched) }
            retouchPointer = false; retouchObject = false; retouchSelecting = true
            selectedRetouchIDs = Set(strokes.map(\.id)); selectedRetouchID = strokes.last?.id
        }
    }

    /// A click with Object. Plain: what is under it, with every object Shift-click collected, becomes Remove strokes,
    /// and the tool is put down. Shift: what is under it is collected, outlined, to remove with the rest. Option: the
    /// collected object under it is taken out of the collection. `tolerance`: how far off a wire the click may land, a
    /// fraction of the long side.
    func removeObject(at point: MaskPoint, tolerance: Double, modifier: ObjectModifier?) {
        objectHover?.cancel()
        let shown = objectPreview.flatMap { $0.modifier == modifier && hypot($0.point.x - point.x, $0.point.y - point.y) <= tolerance ? $0 : nil }
        objectPreview = nil
        // Option: the collected object under the pointer is taken out of the collection.
        if modifier == .subtract {
            if let target = collectedObject(at: point) { objectSelection.remove(at: target) }
            return
        }
        if let shown { applyObjectClick(shown.pick, modifier: modifier, replacing: shown.replacing); return }
        // A plain click on an object already collected removes the collection as it is.
        if modifier == nil, !objectSelection.isEmpty, collectedObject(at: point) != nil { commitObjects([]); return }
        runFaceTask(L10n.tr("Finding the object…")) { [self] renderer in
            guard let task = currentObjectPicker() else { return }
            do {
                let pick = try await task.value.pick(at: point, tolerance: tolerance)
                try Task.checkCancellation()
                guard self.renderer === renderer else { return }
                applyObjectClick(pick, modifier: modifier, replacing: nil)
            } catch is CancellationError {
            } catch {
                // Nothing here (open sky): a plain click still removes what was collected.
                if modifier == nil, !objectSelection.isEmpty { commitObjects([]); return }
                throw error
            }
        }
    }
    private func applyObjectClick(_ pick: ObjectPick, modifier: ObjectModifier?, replacing: Int?) {
        switch modifier {
        case .add: objectSelection.append(pick)
        case .subtract: break
        case nil: commitObjects([pick])
        }
    }
    /// Which collected object the point lies on.
    func collectedObject(at point: MaskPoint) -> Int? {
        objectSelection.lastIndex { $0.contains(point) }
    }
    /// Every collected object, and `more`, become Remove strokes; the tool is put down, so a second click on the photo
    /// doesn't take out something else.
    func commitObjects(_ more: [ObjectPick]) {
        let picks = objectSelection + more
        objectSelection = []
        let made = picks.flatMap(\.strokes)
        let strokes = Array(made.prefix(max(0, DustFinder.strokeLimit - adjustments.retouch.count)))
        guard !strokes.isEmpty else { return }
        edit { $0.retouch += strokes }
        // Every stroke gets a source nearby: a patch fills from it, and an AI fill shown finer than it was made takes its
        // grain from it.
        chooseRetouchSources(Set(strokes.map(\.id)))
        selectedRetouchIDs = Set(strokes.map(\.id)); selectedRetouchID = strokes.last?.id
        let now = Date()
        for stroke in strokes { removingObjects[stroke.id] = now }
        retouchObject = false; retouchPointer = true
    }

    /// The photo developed for Object, made again when the settings it depends on change (a stroke added or filled).
    func currentObjectPicker() -> Task<ObjectPicker, Error>? {
        guard let renderer else { return nil }
        let basis = ObjectPicker.basis(adjustments)
        let id = ObjectIdentifier(renderer)
        if let picker = objectPicker, picker.renderer == id, picker.basis == basis { return picker.task }
        objectPicker?.task.cancel()
        let settings = adjustments
        let task = Task { try await renderer.objectPicker(settings) }
        objectPicker = (id, basis, task)
        return task
    }

    /// The pointer rests at `point` (nil: it left the photo): once it has stayed a moment, what a click there would
    /// take out is outlined; with Option held over a collected object, that object less the part under the pointer. A
    /// lookup still running when it moves on is dropped.
    func hoverObject(at point: MaskPoint?, tolerance: Double, modifier: ObjectModifier?) {
        objectHover?.cancel()
        guard let point, picksObject, !busy else { if objectPreview != nil { objectPreview = nil }; return }
        if let preview = objectPreview, preview.modifier == modifier, hypot(preview.point.x - point.x, preview.point.y - point.y) <= tolerance { return }
        let target = collectedObject(at: point)
        // Option over a collected object: it is shown without that object, as the click would leave it.
        if modifier == .subtract {
            objectPreview = target.map { ObjectPreview(point: point, modifier: modifier, pick: ObjectPick(strokes: [], seeds: nil, aspect: 1), replacing: $0) }
            return
        }
        // Over what is already collected, a plain or Shift click changes nothing new: nothing more is outlined.
        if target != nil { if objectPreview != nil { objectPreview = nil }; return }
        objectHover = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, let self, let task = self.currentObjectPicker() else { return }
            do {
                let pick = try await task.value.pick(at: point, tolerance: tolerance)
                guard !Task.isCancelled else { return }
                self.objectPreview = ObjectPreview(point: point, modifier: modifier, pick: pick, replacing: nil)
            } catch {
                // Nothing to take out here (open sky, too much of the photo): nothing is outlined.
                if !Task.isCancelled { self.objectPreview = nil }
            }
        }
    }
    func endObjectHover() {
        objectHover?.cancel(); objectHover = nil
        if !objectSelection.isEmpty { objectSelection = [] }
        if objectPreview != nil { objectPreview = nil }
        if maskObjectPreview != nil { maskObjectPreview = nil }
        objectPicker?.task.cancel(); objectPicker = nil
    }

    /// Finds spots on the selected people, or on `only` (one face's Find blemishes on the photo).
    func findBlemishes(_ url: URL, faces only: [CGRect]? = nil) {
        let settings = adjustments, sensitivity = blemishSensitivity, region = faceRegion, faces = only ?? chosenFaces
        editingFaceRegion = false; retouchPointer = false
        runFaceTask(L10n.tr("Finding blemishes…")) { [self] renderer in
            let (faces, found) = try await renderer.blemishStrokes(settings, modelURL: url, sensitivity: sensitivity, region: region, faces: region == nil ? faces : nil)
            try Task.checkCancellation()
            guard self.renderer === renderer else { return }
            let strokes = Array(found.prefix(DustFinder.strokeLimit - adjustments.retouch.count))
            if strokes.isEmpty {
                blemishReport = faces == 0 ? L10n.tr("No face found") : L10n.tr("No new blemishes found")
            } else {
                retouchTool = .heal
                edit { $0.retouch += strokes }
                selectedRetouchIDs = Set(strokes.map(\.id))
            }
        }
    }
}

extension EditorModel {
    /// The person Facial Features reshapes in a group picture: the one selected. Nil with one face, where the photo's
    /// only warp is used, and on Everyone, where nothing is reshaped (`reshapesEveryone`).
    var reshapeFace: PortraitFace? {
        guard isGroupPortrait, let id = selectedFaceID else { return nil }
        return portraitFaces.first { $0.id == id }
    }
    /// A group picture on Everyone: a face's shape is one person's, so there is none to show.
    var reshapesEveryone: Bool { isGroupPortrait && reshapeFace == nil }
    /// The reshaped person's warp on the photo: in a group picture the one placed on their face.
    var reshapeWarp: FaceLiquify? {
        if reshapesEveryone { return nil }
        guard let face = reshapeFace else { return adjustments.faceLiquify }
        let centre = CGPoint(x: face.box.midX, y: face.box.midY)
        return adjustments.faceLiquifies.first { $0.region.contains(centre) }
    }
    /// Where the reshaped person's warp goes while nothing is changed yet.
    var reshapeBase: FaceLiquify? {
        get { reshapesEveryone ? nil : reshapeFace.map { groupPlacements[$0.id] } ?? liquifyBase }
        set { if reshapesEveryone { return }; if let face = reshapeFace { groupPlacements[face.id] = newValue } else { liquifyBase = newValue } }
    }
    /// Puts the reshaped person's warp on the photo (nil takes it out), leaving everyone else's.
    func storeReshapeWarp(_ warp: FaceLiquify?) {
        if reshapesEveryone { return }
        guard let face = reshapeFace else {
            if warp != nil || adjustments.faceLiquify != nil { edit { $0.faceLiquify = warp } }
            return
        }
        let centre = CGPoint(x: face.box.midX, y: face.box.midY)
        let index = adjustments.faceLiquifies.firstIndex { $0.region.contains(centre) }
        guard warp != nil || index != nil else { return }
        edit { a in
            if let index { if let warp { a.faceLiquifies[index] = warp } else { a.faceLiquifies.remove(at: index) } }
            else if let warp, a.faceLiquifies.count < 20 { a.faceLiquifies.append(warp) }
        }
    }

    var currentFaceRegion: CGRect? { reshapesEveryone ? nil : faceRegion ?? reshapeWarp?.region ?? reshapeBase?.region }

    /// The warp the sliders show: the photo's, else the detected face with nothing changed, else the usual
    /// proportions in the region drawn.
    var liquify: FaceLiquify {
        if let warp = reshapeWarp { return faceRegion.map { warp.placed(in: $0) } ?? warp }
        guard let base = reshapeBase else { return FaceLiquify(region: faceRegion ?? CGRect(x: 0, y: 0, width: 1, height: 1)) }
        return faceRegion.map { base.placed(in: $0) } ?? base
    }

    func clearFaceRegion() {
        faceRegion = nil; reshapeBase = nil; editingFaceRegion = false; showingLiquify = false
        storeReshapeWarp(nil)
    }

    /// Sets one Face Liquify control. Back at nothing changed, the warp leaves the photo but its placement stays
    /// for the next control.
    func setLiquify(_ path: WritableKeyPath<FaceLiquify, Double>, _ value: Double) { setLiquify([(path, value)]) }
    /// Several controls at once, as a handle that moves two (a mouth corner: width and smile) sets them.
    func setLiquify(_ values: [(WritableKeyPath<FaceLiquify, Double>, Double)]) {
        guard currentFaceRegion != nil else { return }
        var warp = liquify
        for (path, value) in values { warp[keyPath: path] = min(1, max(-1, value)) }
        faceRegion = nil
        if warp.isIdentity {
            reshapeBase = warp
            storeReshapeWarp(nil)
        } else {
            if reshapeFace == nil { liquifyBase = nil }
            storeReshapeWarp(warp)
        }
    }

    /// The region moved or resized on the photo: the features move with it.
    func finishFaceRegion() {
        guard placingFaceRegion, let faceRegion else { return }
        if let warp = reshapeWarp, warp.region != faceRegion {
            storeReshapeWarp(warp.placed(in: faceRegion))
            self.faceRegion = nil
        } else if let base = reshapeBase {
            reshapeBase = base.placed(in: faceRegion)
            self.faceRegion = nil
        }
    }

    func prepareLiquify() {
        editingFaceRegion = true; showingLiquify = true
        guard currentFaceRegion == nil else { return }
        if isGroupPortrait { Task { await loadGroupPlacements() }; return }
        let settings = adjustments
        runFaceTask(L10n.tr("Face Liquify")) { [self] renderer in
            let face = try await renderer.liquifyFace(settings)
            try Task.checkCancellation()
            // A region drawn by hand meanwhile wins.
            guard self.renderer === renderer, faceRegion == nil else { return }
            liquifyBase = face
            if face == nil { blemishReport = L10n.tr("No face found") }
        }
    }
}

extension EditorModel {
    func setPortraitValue(_ id: UUID, _ key: WritableKeyPath<LocalAdjustments, Double>, _ value: Double) {
        edit { a in
            if let i = a.masks.firstIndex(where: { $0.id == id }) { a.masks[i].adjustments[keyPath: key] = value }
        }
    }

    /// Makes the correction for the ticked faces (or a drawn face region), in place of their earlier masks and keeping
    /// those masks' Amount; other people's masks stay as they are.
    func applyPortraitCorrection(_ kind: PortraitCorrection) {
        let settings = adjustments, region = faceRegion, faces = chosenFaces
        runFaceTask(kind.title) { [self] renderer in
            let made = try await renderer.portraitMask(kind, settings: settings, region: region, faces: faces)
            try Task.checkCancellation()
            guard self.renderer === renderer else { return }
            guard !made.isEmpty else { editingFaceRegion = true; blemishReport = L10n.tr("No face found"); return }
            editingFaceRegion = false; blemishReport = nil
            edit { a in
                let replaced = { (m: PhotoMask) in m.portraitCorrection == kind && (region != nil || PortraitFace.covers(m.face, faces ?? [])) || (m.portraitCorrection == kind && faces == nil) }
                let opacity = a.masks.first(where: replaced)?.opacity
                a.masks.removeAll(where: replaced)
                guard a.masks.count + made.count <= PhotoMask.maxCount else { return }
                a.masks += made.map { var m = $0; if let opacity { m.opacity = opacity }; return m }
            }
        }
    }
}

/// Remove › Object's outline under the pointer: what a click there would take out, or with Option the collected
/// object it would replace.
struct ObjectPreview {
    let point: MaskPoint
    let modifier: ObjectModifier?
    let pick: ObjectPick
    let replacing: Int?
    var strokes: [RetouchStroke] { pick.strokes }
}

/// Shift collects another object, Option takes a collected one out of the collection.
enum ObjectModifier {
    case add, subtract
    init?(_ flags: NSEvent.ModifierFlags) {
        if flags.contains(.option) { self = .subtract } else if flags.contains(.shift) { self = .add } else { return nil }
    }
}

/// Masks › Object's outline under the pointer: the mask a click there makes.
struct MaskObjectPreview {
    let point: MaskPoint
    let mask: PhotoMask
    let outline: [(MaskPoint, MaskPoint)]
}
