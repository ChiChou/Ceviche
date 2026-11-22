import SwiftUI
import CevicheCore

struct MaskPanel: View {
    @ObservedObject var model: EditorModel
    /// Observed so the tiles follow installs and removals in Settings › Models.
    @ObservedObject private var library = ModelLibrary.shared
    @Environment(\.openSettings) private var openSettings
    @State private var renamingMask: UUID?
    @State private var peopleTarget: PeopleMaskTarget?
    @State private var sceneTarget: PeopleMaskTarget?
    /// Each mask's and component's picture in the list, made from a small development whenever the masks change.
    @State private var thumbnails: [UUID: CGImage] = [:]
    private struct ThumbnailKey: Equatable { let masks: [PhotoMask]; let geometry: GeometryAdjustments; let quarterTurns: Int; let source: URL? }
    private var gold: Color { Theme.accent }
    /// The masks, each with its own controls under it while it is selected, and the ways to add one. Adding is a grid
    /// of small tiles: the selections a model makes, then the ones drawn by hand.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The ways to make a mask stay in view: another is added as often as one is adjusted.
            addGrid
            if let target = peopleTarget { PeopleMaskChooser(model: model, target: target) { peopleTarget = nil } }
            if let target = sceneTarget { SceneMaskChooser(model: model, target: target) { sceneTarget = nil } }
            HStack(spacing: 10) {
                Text(L10n.tr("Masks")).textCase(.uppercase).font(.system(size: 10, weight: .semibold)).tracking(1.2)
                Text(L10n.tr("\(model.adjustments.masks.count)")).font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
                Spacer()
            }.font(.system(size: 12)).padding(.top, 4)
            if model.isSelecting {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.selectionStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(action: model.cancelSelection) { Image(systemName: "xmark") }.buttonStyle(.plain).help(L10n.tr("Cancel")).accessibilityLabel(L10n.tr("Cancel"))
                }
            }
            ForEach(Array(model.adjustments.masks.enumerated()), id: \.element.id) { index, mask in
                let selected = model.selectedMaskID == mask.id
                VStack(alignment: .leading, spacing: 10) {
                    maskRow(mask, index: index)
                    if selected { selectedControls(mask) }
                }
                .padding(9)
                .background(selected ? gold.opacity(0.1) : Theme.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(selected ? gold.opacity(0.35) : Theme.hairline))
                .disabled(model.busy)
            }
            // The overlay of the selected mask on the photo, as a switch under the list (O).
            if !model.adjustments.masks.isEmpty {
                Toggle(isOn: $model.showMaskOverlay) { Text(L10n.tr("Show Overlay")) }.toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: 11)).help(L10n.tr("Show Mask Overlay (O)"))
            }
        }.padding(18)
        .task(id: ThumbnailKey(masks: model.adjustments.masks, geometry: model.adjustments.geometry, quarterTurns: model.adjustments.quarterTurns, source: model.sourceURL)) {
            guard let renderer = model.renderer, !model.adjustments.masks.isEmpty else { thumbnails = [:]; return }
            // After a pause, so a brush stroke or a slider drag makes one set, not one per step.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let made = try? await renderer.maskThumbnails(model.adjustments.masks, adjustments: model.adjustments) else { return }
            thumbnails = made
        }
    }

    private static let symbols: [MaskKind: String] = [.subject: "person.crop.rectangle", .sky: "cloud", .background: "rectangle.dashed", .depth: "square.3.layers.3d.down.right",
                                                      .scene: "mountain.2", .object: "viewfinder", .brush: "paintbrush.pointed", .linear: "rectangle.lefthalf.filled",
                                                      .radial: "circle.lefthalf.filled", .color: "eyedropper", .people: "figure.stand"]
    /// The ways to make a mask as one grid of like tiles, three across. Scene and People open a card under the grid to
    /// choose from, with Cancel and Create.
    private var addGrid: some View {
        VStack(spacing: 6) {
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow { selectionButton(.subject); selectionButton(.sky); selectionButton(.background) }
                GridRow { toolButton(.brush); toolButton(.linear); toolButton(.radial) }
                GridRow { selectionButton(.depth); toolButton(.object); toolButton(.color) }
                // Scene opens a list of what to select: the same tile, with the arrow that says so.
                GridRow {
                    Button { if let missing = missingModel(.scene) { ModelPrompt.open(missing, openSettings) } else { peopleTarget = nil; sceneTarget = .newMask } } label: {
                        tile(MaskKind.scene.localizedTitle, Self.symbols[.scene]!)
                            .overlay(alignment: .topTrailing) { if missingModel(.scene) != nil { Image(systemName: "arrow.down.circle").font(.system(size: 8)).foregroundStyle(.secondary).padding(3) } }
                    }
                        .buttonStyle(.plain).disabled(!model.hasImage || model.busy)
                        .help(MaskKind.scene.modelAvailable ? L10n.tr("Select vegetation, water, mountains, buildings, ground, people or sky") : L10n.tr("The scene model is not installed. Click to install it."))
                    // People: one person, whole or in parts, chosen in a sheet.
                    // Finding people needs no download (Vision); only some parts do, and the sheet says which.
                    Button { sceneTarget = nil; peopleTarget = .newMask } label: { tile(MaskKind.people.localizedTitle, Self.symbols[.people]!) }
                        .buttonStyle(.plain).disabled(!model.hasImage || model.busy)
                        .help(L10n.tr("Select a person, or parts of them"))
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                }
            }
        }
    }

    private func maskRow(_ mask: PhotoMask, index: Int) -> some View {
        HStack(spacing: 8) {
            Button { model.selectMask(mask.id) } label: { thumbnail(mask.id, symbol: Self.symbols[mask.kind] ?? "circle.dashed", large: true) }
                .buttonStyle(.plain).accessibilityLabel(L10n.tr("\(index + 1)"))
            InlineRenameLabel(name: mask.name,
                editing: Binding(get: { renamingMask == mask.id }, set: { renamingMask = $0 ? mask.id : nil }),
                select: { model.selectMask(mask.id) }) { name in
                    model.edit { adjustments in
                        if let i = adjustments.masks.firstIndex(where: { $0.id == mask.id }) { adjustments.masks[i].name = String(name.prefix(200)) }
                    }
                }
            Button { model.edit { a in if let i = a.masks.firstIndex(where: { $0.id == mask.id }) { a.masks[i].enabled.toggle() } } } label: { Image(systemName: mask.enabled ? "eye" : "eye.slash") }
                .buttonStyle(.plain).foregroundStyle(mask.enabled ? .secondary : .tertiary).help(L10n.tr("Toggle mask")).accessibilityLabel(L10n.tr("Toggle mask"))
            Menu {
                Button(L10n.tr("Rename…")) { renamingMask = mask.id }
                Button(L10n.tr("Duplicate")) { model.duplicateMask(mask.id) }
                Button(L10n.tr("Copy adjustments")) { model.selectMask(mask.id); model.copyMaskAdjustments() }
                Button(L10n.tr("Paste adjustments")) { model.selectMask(mask.id); model.pasteMaskAdjustments() }.disabled(model.copiedMaskAdjustments == nil)
                Divider()
                Button(L10n.tr("Move earlier")) { model.moveMask(mask.id, by: -1) }.disabled(index == 0)
                Button(L10n.tr("Move later")) { model.moveMask(mask.id, by: 1) }.disabled(index == model.adjustments.masks.count - 1)
                Divider()
                Button(L10n.tr("Delete"), role: .destructive) { model.deleteMask(mask.id) }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L10n.tr("Mask actions")).accessibilityLabel(L10n.tr("Mask actions"))
        }.font(.system(size: 12))
    }

    private static let operationSymbols: [MaskOperation: String] = [.add: "plus", .subtract: "minus", .intersect: "circle.circle"]
    /// The selected mask's own controls, under its row: what it changes, what it is made of, and the tool for the
    /// part picked.
    @ViewBuilder private func selectedControls(_ mask: PhotoMask) -> some View {
        // What the mask does to the photo is set in the adjustment panels, aimed at this mask.
        HStack(spacing: 6) {
            ForEach([ToolTab.light, .detail], id: \.self) { tab in
                Button { model.editSelectedMask(in: tab) } label: { Label(tab.localizedTitle, systemImage: tab.icon).frame(maxWidth: .infinity) }
            }
        }.buttonStyle(.secondaryAction).controlSize(.small)
        maskSlider(L10n.tr("Amount"), \.opacity, 0...1)
        HStack(spacing: 14) {
            Toggle(L10n.tr("Invert"), isOn: maskBool(\.inverted))
            Toggle(L10n.tr("Keep only selection"), isOn: maskBool(\.cutsOutBackground))
        }.toggleStyle(.formCheckbox).font(.system(size: 11))
        // What it is made of: the base, then what was added to it, taken from it or crossed with it.
        VStack(spacing: 1) {
            part(Self.symbols[mask.kind] ?? "circle.dashed", mask.kind.localizedTitle, selected: model.selectedComponentID == nil, thumbnailID: mask.id) { model.endMask(); model.selectedComponentID = nil; model.maskTool = nil }
            ForEach(mask.components) { component in
                part(Self.operationSymbols[component.operation] ?? "plus", component.selection.kind.localizedTitle, selected: model.selectedComponentID == component.id,
                     help: component.operation.localizedTitle, thumbnailID: component.id) { model.endMask(); model.selectedComponentID = component.id; model.maskTool = nil } trailing: {
                    Button { model.updateMask { mask in if let i = mask.components.firstIndex(where: { $0.id == component.id }) { mask.components[i].enabled.toggle() } } } label: { Image(systemName: component.enabled ? "eye" : "eye.slash") }
                        .buttonStyle(.plain).help(L10n.tr("Toggle component")).accessibilityLabel(L10n.tr("Toggle component"))
                    Button { model.endMask(); model.updateMask { $0.components.removeAll { $0.id == component.id } }; if model.selectedComponentID == component.id { model.selectedComponentID = nil } } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).help(L10n.tr("Delete component")).accessibilityLabel(L10n.tr("Delete component"))
                }
            }
        }
        HStack(spacing: 6) {
            ForEach(MaskOperation.allCases, id: \.self) { operation in
                Menu {
                    ForEach(MaskKind.allCases.filter { $0 != .scene && $0 != .people }, id: \.self) { kind in
                        Button(kind.localizedTitle) { model.addComponent(kind, operation: operation) }.disabled(!kind.modelAvailable)
                    }
                    Button(L10n.tr("Scene…")) { peopleTarget = nil; sceneTarget = .component(operation) }.disabled(!MaskKind.scene.modelAvailable)
                    Button(L10n.tr("People…")) { sceneTarget = nil; peopleTarget = .component(operation) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: Self.operationSymbols[operation] ?? "plus").font(.system(size: 9, weight: .semibold))
                        Text(operation.localizedTitle).lineLimit(1).minimumScaleFactor(0.75)
                    }.frame(maxWidth: .infinity)
                }.menuStyle(.button).buttonStyle(.secondaryAction).menuIndicator(.hidden).disabled(mask.components.count >= PhotoMask.maxComponents)
            }
        }.controlSize(.small)
        if let selection = model.editableSelection {
            HStack(spacing: 2) {
                toolChoice(L10n.tr("Brush"), selected: model.maskTool == .brush) { model.maskTool = .brush; model.comparing = false }
                toolChoice(L10n.tr("Navigate"), selected: model.maskTool == nil) { model.endMask(); model.maskTool = nil }
                if [.linear, .radial, .color].contains(selection.kind) {
                    toolChoice(selection.kind == .color ? L10n.tr("Pick color") : L10n.tr("Redraw"), selected: model.maskTool == selection.kind) { model.maskTool = selection.kind; model.redrawGradient = selection.kind != .color; model.comparing = false }
                        .help(selection.kind == .color ? L10n.tr("Click the photo to sample a new color") : L10n.tr("The next drag on the photo replaces this gradient"))
                }
            }
            .padding(2).background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.ink.opacity(0.06)))
            if model.maskTool == .brush {
                simpleSlider(L10n.tr("Size"), $model.brushRadius, 0.003...0.25).help(L10n.tr("[ and ] resize the brush - Option paints as eraser"))
                simpleSlider(L10n.tr("Softness"), $model.brushSoftness, 0...1)
                Toggle(L10n.tr("Erase"), isOn: $model.brushErase).toggleStyle(.formCheckbox).font(.system(size: 11))
            }
            if selection.kind == .depth {
                depthSlider(L10n.tr("Near limit"), 1, lower: false)
                depthSlider(L10n.tr("Far limit"), 0, lower: true)
                selectionSlider(L10n.tr("Transition"), \.tolerance, 0.001...1)
            }
            selectionSlider(L10n.tr("Feather"), \.feather, 0...0.25)
            if selection.kind == .color { selectionSlider(L10n.tr("Tolerance"), \.tolerance, 0.005...1) }
            if model.selectedComponentID != nil {
                Toggle(L10n.tr("Invert component"), isOn: Binding(get: { model.editableSelection?.inverted ?? false }, set: { v in model.updateSelection { $0.inverted = v } })).toggleStyle(.formCheckbox).font(.system(size: 11))
            }
        }
    }
    /// One part of the mask in its list: the base or a component, by the symbol of how it joins.
    private func part(_ symbol: String, _ title: String, selected: Bool, help: String = "", thumbnailID: UUID? = nil, action: @escaping () -> Void, @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 8) {
                    // How it joins (+, −, ∩), then its own picture.
                    Image(systemName: symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).frame(width: 14)
                    if let thumbnailID { thumbnail(thumbnailID, symbol: symbol, large: false) }
                    Text(title).lineLimit(1)
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help(help)
            trailing()
        }
        .font(.system(size: 11)).foregroundStyle(selected ? .primary : .secondary).padding(.horizontal, 7).padding(.vertical, 5)
        .background(selected ? Theme.ink.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
    }
    /// One of the tools that work on the selected component, drawn like the Upright mode row: the active one is filled.
    private func toolChoice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: selected ? .semibold : .regular)).lineLimit(1).frame(maxWidth: .infinity).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(selected ? Theme.ink.opacity(0.18) : .clear))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    /// A mask's or component's picture, white where it selects; its kind's symbol until the picture is made.
    private func thumbnail(_ id: UUID, symbol: String, large: Bool) -> some View {
        let size = large ? CGSize(width: 40, height: 28) : CGSize(width: 28, height: 20)
        return ZStack {
            Rectangle().fill(.black)
            if let image = thumbnails[id] { Image(decorative: image, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fill) }
            else { Image(systemName: symbol).font(.system(size: large ? 11 : 9)).foregroundStyle(.secondary) }
        }
        .frame(width: size.width, height: size.height).clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.hairline))
    }
    private func tile(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 17)).frame(height: 20)
            // Two words take two lines, so "Linear gradient" is whole at any panel width.
            Text(title).font(.system(size: 11)).multilineTextAlignment(.center).lineLimit(2).fixedSize(horizontal: false, vertical: true).frame(height: 30, alignment: .top)
        }
        .padding(.horizontal, 4).padding(.top, 5).frame(maxWidth: .infinity).frame(height: 74)
        .background(Theme.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.control)).contentShape(Rectangle())
    }
    /// A kind whose model is missing opens Settings › Models instead of adding a mask; Sky only when the RAW has no
    /// embedded matte either.
    private func missingModel(_ kind: MaskKind) -> BundledModel? {
        guard let needed = kind.model, !needed.isAvailable else { return nil }
        if kind == .sky && model.embeddedSkyAvailable { return nil }
        return needed
    }
    private func selectionButton(_ kind: MaskKind) -> some View {
        let missing = missingModel(kind)
        return Button { if let missing { ModelPrompt.open(missing, openSettings) } else { model.addMask(kind) } } label: {
            tile(kind.localizedTitle, Self.symbols[kind] ?? "circle.dashed").overlay(alignment: .topTrailing) { if missing != nil { Image(systemName: "arrow.down.circle").font(.system(size: 8)).foregroundStyle(.secondary).padding(3) } }
        }
            .buttonStyle(.plain).disabled(!model.hasImage || model.busy)
            .help(missing != nil ? L10n.tr("The \(kind.localizedTitle.lowercased()) model is not installed. Click to install it.") : kind == .depth ? L10n.tr("Select by distance from the camera") : L10n.tr("Create \(kind.localizedTitle.lowercased()) mask"))
    }
    private func toolButton(_ kind: MaskKind) -> some View {
        Button { model.addMask(kind) } label: { tile(kind.localizedTitle, Self.symbols[kind] ?? "circle.dashed") }
            .buttonStyle(.plain).disabled(!model.hasImage || model.busy || !kind.modelAvailable)
            .help(kind == .object && !kind.modelAvailable ? L10n.tr("Object selection needs macOS 27 or later") : kind.localizedTitle)
    }
    private func maskBool(_ key: WritableKeyPath<PhotoMask, Bool>) -> Binding<Bool> { Binding(get: { model.selectedMask?[keyPath: key] ?? false }, set: { v in model.updateMask { $0[keyPath: key] = v } }) }
    private func maskSlider(_ title: String, _ key: WritableKeyPath<PhotoMask, Double>, _ range: ClosedRange<Double>) -> some View {
        AdjustmentSlider(title: title, value: Binding(get: { model.selectedMask?[keyPath: key] ?? 0 }, set: { v in model.updateMask { $0[keyPath: key] = v } }), range: range, unit: "fraction", editing: gesture, reset: { model.updateMask { $0[keyPath: key] = PhotoMask(kind: $0.kind)[keyPath: key] } })
    }
    private func selectionSlider(_ title: String, _ key: WritableKeyPath<MaskSelection, Double>, _ range: ClosedRange<Double>) -> some View {
        AdjustmentSlider(title: title, value: Binding(get: { model.editableSelection?[keyPath: key] ?? 0 }, set: { v in model.updateSelection { $0[keyPath: key] = v } }), range: range, unit: "fraction", editing: gesture, reset: { model.updateSelection { $0[keyPath: key] = MaskSelection(kind: $0.kind)[keyPath: key] } })
    }
    /// Depth runs from 0 (farthest) to 1 (nearest); the limits cannot cross.
    private func depthSlider(_ title: String, _ index: Int, lower: Bool) -> some View {
        let range = model.editableSelection?.depthRange ?? [0.5, 1]
        let bounds: ClosedRange<Double> = lower ? 0...range[1] : range[0]...1
        return AdjustmentSlider(title: title, value: Binding(get: { range[index] }, set: { v in model.updateSelection { s in var r = s.depthRange ?? [0.5, 1]; r[index] = min(bounds.upperBound, max(bounds.lowerBound, v)); s.depthRange = r } }), range: bounds, unit: "fraction", editing: gesture, reset: { model.updateSelection { s in var r = s.depthRange ?? [0.5, 1]; r[index] = lower ? 0.5 : 1; s.depthRange = r } }, appearance: .luminance)
    }
    private func simpleSlider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) { Text(title).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading); FormSlider(value: value, in: range) }
    }
    private func gesture(_ active: Bool) { if active { model.beginGesture() } else { model.endGesture() } }
}
