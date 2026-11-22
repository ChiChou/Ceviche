import SwiftUI
import AppKit
import CevicheCore

/// The library and the stack down the left, and the photo with the stack applied. Export… opens the
/// Export dialog on the filtered photo.
struct FiltersDialog: View {
    @ObservedObject var catalog: CatalogModel
    @StateObject private var model: FiltersModel
    @State private var showingBefore = false
    @State private var namingRecipe = false
    @State private var recipeName = ""
    @State private var split = 0.5
    @State private var link = ZoomLink()

    init(catalog: CatalogModel, request: FiltersRequest) {
        self.catalog = catalog
        _model = StateObject(wrappedValue: FiltersModel(request: request))
    }

    var body: some View {
        ToolWorkspace(title: L10n.tr("Creative Filters"), status: status, statusIsWarning: model.renderError != nil, primary: model.request.assets.count > 1 ? L10n.tr("Export \(model.request.assets.count) Photos…") : L10n.tr("Export…"),
                      primaryDisabled: !model.canApply,
                      cancel: { model.close(catalog: catalog) }, action: { model.showingExport = true },
                      showsToolbar: false) {
            EmptyView()
        } content: {
            HStack(spacing: 0) {
                FiltersLibrary(model: model) { recipeName = ""; namingRecipe = true }
                // The picked filter's settings, beside the list it was picked from.
                panel.frame(width: 300).frame(maxHeight: .infinity, alignment: .top).background(Theme.panel)
                Rule(.vertical)
                VStack(spacing: 0) {
                    ZStack {
                        canvas.overlay(alignment: .bottomLeading) { if model.before != nil { compareBar } }
                        switch model.stage {
                        case .reading: ToolProgressCard(message: L10n.tr("Developing \(model.request.assets[model.selected].filename)"))
                        case .failed(let message): ContentUnavailableView(L10n.tr("Can’t Filter This Photo"), systemImage: "camera.filters", description: Text(message))
                        case .ready: EmptyView()
                        }
                    }
                    if model.request.assets.count > 1 { Rule(); photoStrip }
                }
            }
        } actions: {
            Button(action: model.printPhotos) {
                HStack(spacing: 6) {
                    if model.preparingPrint { ProgressView().controlSize(.mini) }
                    Text(L10n.tr("Print…"))
                }
            }.buttonStyle(.secondaryAction).disabled(!model.canPrint)
        }
        .background(WindowBackgroundDragOff())
        .onAppear { model.start(catalog: catalog) }
        .onDisappear { catalog.filtersCanPrint = false; model.stop() }
        .onChange(of: model.canPrint && !model.showingExport, initial: true) { _, ready in catalog.filtersCanPrint = ready }
        .onChange(of: catalog.filtersPrint) { model.printPhotos() }
        .onChange(of: catalog.filtersExport) { if model.canApply { model.showingExport = true } }
        .sheet(isPresented: $model.showingExport) { ExportDialog(model: model, showsDenoise: false) }
        .alert(L10n.tr("Save Recipe"), isPresented: $namingRecipe) {
            TextField(L10n.tr("Name"), text: $recipeName)
            Button(L10n.tr("Save")) { model.saveRecipe(named: recipeName) }
            Button(L10n.tr("Cancel"), role: .cancel) {}
        }
    }

    /// The photos the chain applies to, as tabs: one is shown at a time, and Export writes them all.
    private var photoStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(Array(model.request.assets.enumerated()), id: \.element.id) { index, asset in
                        Button { model.selected = index } label: {
                            CatalogThumbnail(asset: asset, previews: catalog.store?.previews, fillsFrame: true).frame(width: 72, height: 48)
                                .clipped()
                                .selectionRing(model.selected == index ? Theme.accent : nil)
                                .opacity(model.selected == index ? 1 : 0.65)
                        }
                        .buttonStyle(.plain).help(asset.filename).accessibilityLabel(asset.filename)
                        .accessibilityAddTraits(model.selected == index ? .isSelected : []).id(index)
                    }
                }.padding(.horizontal, 12)
            }
            .scrollIndicators(.never).frame(height: 64).background(Theme.statusBar)
            .onChange(of: model.selected) { _, index in withAnimation { proxy.scrollTo(index) } }
        }
    }

    private var status: String {
        if case .failed(let message) = model.stage { return message }
        if let error = model.renderError { return error }
        let photos = model.request.assets
        return photos.count == 1 ? photos[0].filename : L10n.tr("\(photos.count) photos")
    }

    @ViewBuilder private var canvas: some View {
        let shown = model.after ?? model.before
        switch model.after == nil ? .single : model.compare {
        case .single:
            ZoomCanvas(image: showingBefore ? model.before : shown) { size in CenterHandle(model: model, size: size) }
        case .split:
            ZoomCanvas(image: shown) { size in
                ZStack { SplitDivider(before: model.before, size: size, border: model.stack.border, position: $split); CenterHandle(model: model, size: size) }
            }
        case .sideBySide:
            HStack(spacing: 1) {
                ZoomCanvas(image: model.before, showsControls: false, link: $link).overlay(alignment: .topLeading) { tag(L10n.tr("Before")).padding(12) }
                ZoomCanvas(image: shown, link: $link) { size in CenterHandle(model: model, size: size) }.overlay(alignment: .topLeading) { tag(L10n.tr("After")).padding(12) }
            }
        }
    }
    private func tag(_ title: String, strong: Bool = false) -> some View {
        Text(title).font(.callout).foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5).background(.black.opacity(strong ? 0.85 : 0.6), in: Capsule())
    }
    /// The compare modes over the canvas's corner, with Before beside them while one picture is shown.
    private var compareBar: some View {
        HStack(spacing: 8) {
            FormSegments(title: L10n.tr("Compare"), selection: $model.compare, options: FiltersModel.Compare.allCases, label: \.title, icon: \.symbol).fixedSize()
                .padding(3).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.control)).environment(\.colorScheme, .dark)
                .disabled(model.after == nil)
            if model.after != nil, model.compare == .single {
                tag(L10n.tr("Before"), strong: showingBefore)
                    .onLongPressGesture(minimumDuration: 60, pressing: { showingBefore = $0 }, perform: {})
                    .help(L10n.tr("Hold to see the photo without the filters"))
            }
            if model.rendering { ProgressView().controlSize(.small) }
        }.padding(12)
    }

    @ViewBuilder private var panel: some View {
        if model.applied.isEmpty {
            Text(L10n.tr("No Filters")).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 34)
        } else {
            FilterChain(model: model)
        }
    }
}

/// While it is in a window, dragging the window's background doesn't move the window: a drag that starts on a card
/// is the card's. The title bar still moves the window. Put back when the tool closes.
private struct WindowBackgroundDragOff: NSViewRepresentable {
    func makeNSView(context: Context) -> Holder { Holder() }
    func updateNSView(_ view: Holder, context: Context) {}

    final class Holder: NSView {
        private weak var held: NSWindow?
        private var was = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let held, held !== window { held.isMovableByWindowBackground = was; self.held = nil }
            if let window, held == nil { was = window.isMovableByWindowBackground; window.isMovableByWindowBackground = false; held = window }
        }
    }
}

/// The recipes as small pictures of the photo, and the filters by what they work on.
private struct FiltersLibrary: View {
    @ObservedObject var model: FiltersModel
    let saveRecipe: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        heading(L10n.tr("Recipes"))
                        Spacer()
                        Button(action: saveRecipe) { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 20, height: 20).contentShape(Rectangle()) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.stack.isEmpty)
                            .help(L10n.tr("Save Recipe…")).accessibilityLabel(L10n.tr("Save Recipe…"))
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 10) {
                        ForEach(model.library) { recipe in
                            RecipeTile(recipe: recipe, image: model.thumbnails[recipe.id], selected: model.matches(recipe)) { model.apply(recipe) }
                                .contextMenu { if !model.isBuiltIn(recipe) { Button(L10n.tr("Delete Recipe"), role: .destructive) { model.delete(recipe) } } }
                        }
                    }
                    ForEach(CreativeFilterKind.groups, id: \.title) { group in
                        heading(group.title).padding(.top, 10)
                        ForEach(group.kinds) { kind in
                            let chosen = model.selection == kind
                            HStack(spacing: 8) {
                                Toggle(isOn: Binding(get: { model.isOn(kind) }, set: { model.setOn(kind, $0) })) { EmptyView() }
                                    .labelsHidden().toggleStyle(.formCheckbox).controlSize(.small).accessibilityLabel(kind.title)
                                Button { model.select(kind) } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: kind.symbol).frame(width: 18).foregroundStyle(chosen ? Theme.accent : .secondary)
                                        Text(kind.title).lineLimit(1)
                                        Spacer(minLength: 0)
                                    }.frame(maxHeight: .infinity).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                            .font(.system(size: 12)).padding(.horizontal, 8).frame(height: 28)
                            .background(Theme.ink.opacity(chosen ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                        }
                    }
                }
                .padding(12)
            }
            .frame(width: 236).background(Theme.panel)
            Rule(.vertical)
        }
    }
    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
    }
}

private struct RecipeTile: View {
    let recipe: CreativeFilterRecipe
    let image: CGImage?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Color.black.opacity(0.25).aspectRatio(1.5, contentMode: .fit)
                    .overlay {
                        if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
                        else { Image(systemName: recipe.stack.filters.first?.kind.symbol ?? "camera.filters").foregroundStyle(.tertiary) }
                    }
                    .clipped()
                    .selectionRing(selected ? Theme.accent : nil)
                Text(recipe.name).font(.system(size: 11)).lineLimit(1).truncationMode(.tail).foregroundStyle(selected ? .primary : .secondary)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(recipe.stack.filters.map(\.kind.title).joined(separator: ", "))
    }
}

/// A filter's choice picked from small pictures of the choices themselves: the one chosen with its name, and all of
/// them in a panel. The pictures are of the border or texture alone, not the photo, so nothing is rendered for them.
private struct PicturedChoice: View {
    let title: String
    let choices: [String]
    let picture: (Int) -> CGImage?
    @Binding var selection: Int
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                tile(selection, width: 42)
                Text(choices.indices.contains(selection) ? choices[selection] : "").lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6).padding(.vertical, 4).frame(maxWidth: .infinity)
            .background(Theme.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.Radius.control)).contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
        .buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(choices.indices.contains(selection) ? choices[selection] : "")
        .popover(isPresented: $open, arrowEdge: .trailing) {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(104), spacing: 10), count: 4), spacing: 12) {
                    ForEach(choices.indices, id: \.self) { index in
                        Button { selection = index } label: {
                            VStack(spacing: 4) {
                                tile(index, width: 104)
                                    .overlay { Rectangle().strokeBorder(index == selection ? Theme.accent : .clear, lineWidth: 2) }
                                Text(choices[index]).font(.system(size: 10)).foregroundStyle(index == selection ? .primary : .secondary).lineLimit(1)
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityLabel(choices[index]).accessibilityAddTraits(index == selection ? .isSelected : [])
                    }
                }.padding(14)
            }
            .frame(width: 4 * 104 + 3 * 10 + 28).frame(maxHeight: 420)
        }
    }
    private func tile(_ index: Int, width: CGFloat) -> some View {
        Group {
            if let image = picture(index) { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit) }
            else { Rectangle().fill(Theme.ink.opacity(0.1)) }
        }
        .frame(width: width, height: width * 2 / 3).background(.black.opacity(0.25)).clipped()
    }
}

/// The selected filter drawn on the picture where it acts and edited there, as a mask is (Darken / Lighten Center,
/// Bokeh, Fog, Reflector, Light Leak, Glow's Motion and Streak): the point is dragged where it goes, a handle on the zone's edge sets its size, one on the dashed line
/// where the effect is full sets the falloff, and a band is turned by its own handle.
private struct CenterHandle: View {
    @ObservedObject var model: FiltersModel
    let size: CGSize
    /// The photo inside a border as shown: the filters work on the photo, not the border round it.
    private var picture: CGRect { model.stack.border.pictureRect(in: size, upright: model.before.map { $0.height > $0.width } ?? false) }

    var body: some View {
        ZStack {
            if size.width > 0, size.height > 0 {
                // Only the selected card's filter is drawn: several at once would cover the photo in lines.
                ForEach(model.stack.filters.filter { $0.enabled && $0.kind == model.selection }, id: \.kind) { filter in
                    switch filter.kind {
                    case .bokeh, .center:
                        let centre = CGPoint(x: picture.minX + picture.width * filter["x"] / 100, y: picture.minY + picture.height * filter["y"] / 100)
                        if filter.kind == .bokeh { bokeh(filter, centre) } else { light(filter, centre) }
                        badge(filter.kind, at: centre) { model.place(filter.kind, at: CGPoint(x: ($0.x - picture.minX) / picture.width * 100, y: ($0.y - picture.minY) / picture.height * 100)) }
                    case .fog: fog(filter)
                    case .reflector: reflector(filter)
                    case .lightLeak: leak(filter)
                    case .glow: glow(filter)
                    default: EmptyView()
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height).coordinateSpace(name: "filtersCenter")
    }

    /// The filter's own handle: its symbol in a ring, dragged.
    /// Without `moved` it only marks the filter: a filter with no place of its own.
    private func badge(_ kind: CreativeFilterKind, at point: CGPoint, _ moved: ((CGPoint) -> Void)? = nil) -> some View {
        Image(systemName: kind.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 24, height: 24).background(.black.opacity(0.45), in: Circle())
            .overlay { Circle().strokeBorder(.white, lineWidth: 1.5) }.shadow(color: .black.opacity(0.6), radius: 1.5)
            .contentShape(Circle().inset(by: -6))
            .position(point).gesture(drag(moved ?? { _ in }), isEnabled: moved != nil).allowsHitTesting(moved != nil)
            .help(kind.title).accessibilityLabel(kind.title)
    }
    private func across(_ y: Double) -> Path {
        Path { $0.move(to: CGPoint(x: picture.minX, y: y)); $0.addLine(to: CGPoint(x: picture.maxX, y: y)) }
    }

    /// Fog over the top or the bottom: the horizon it thins out across, dragged up and down. The dashed lines are
    /// where it is all there and all gone. Fog over everything has no horizon to show.
    @ViewBuilder private func fog(_ filter: CreativeFilter) -> some View {
        if filter["cover"] >= 0.5 {
            let y = picture.minY + picture.height * filter["level"] / 100, fade = picture.height * 0.25
            Group { line(across(y)); line(across(y - fade), dashed: true); line(across(y + fade), dashed: true) }.clipShape(Rectangle().path(in: picture))
            badge(.fog, at: CGPoint(x: picture.midX, y: y)) { model.set(.fog, "level", ($0.y - picture.minY) / picture.height * 100) }
        }
    }

    /// Reflector: the line where its light has fallen to half, the dashed ones where it is full and gone, and the
    /// reflector itself on the side it is held, dragged round the photo to turn it.
    @ViewBuilder private func reflector(_ filter: CreativeFilter) -> some View {
        let angle = filter["direction"] * .pi / 180
        // Toward the reflector, per point of the picture as seen: the light is the same along lines across it.
        let g = CGVector(dx: sin(angle) / picture.width, dy: cos(angle) / picture.height), length2 = g.dx * g.dx + g.dy * g.dy
        let centre = CGPoint(x: picture.midX, y: picture.midY)
        let level = filter["position"] / 100 - 0.5, fade = 0.08 + 0.5 * filter["falloff"] / 100
        let at: (Double) -> CGPoint = { c in CGPoint(x: centre.x + g.dx * c / length2, y: centre.y + g.dy * c / length2) }
        let reach = hypot(picture.width, picture.height), norm = length2.squareRoot()
        let rule: (Double) -> Path = { c in
            Path { p in
                let o = at(c), along = CGVector(dx: -g.dy / norm, dy: g.dx / norm)
                p.move(to: CGPoint(x: o.x - along.dx * reach, y: o.y - along.dy * reach)); p.addLine(to: CGPoint(x: o.x + along.dx * reach, y: o.y + along.dy * reach))
            }
        }
        let value: (CGPoint) -> Double = { ($0.x - centre.x) * g.dx + ($0.y - centre.y) * g.dy }
        Group { line(rule(level)); line(rule(level + fade), dashed: true); line(rule(level - fade), dashed: true) }.clipShape(Rectangle().path(in: picture))
        knob(at(level), L10n.tr("Position")) { model.set(.reflector, "position", (value($0) + 0.5) * 100) }
        knob(at(level - fade), L10n.tr("Falloff")) { model.set(.reflector, "falloff", (abs(value($0) - level) - 0.08) / 0.5 * 100) }
        // Just inside the picture's edge on the reflector's side.
        badge(.reflector, at: at(0.5 - 14 * norm)) { location in
            model.set(.reflector, "direction", atan2((location.x - centre.x) * picture.width, (location.y - centre.y) * picture.height) * 180 / .pi)
        }
    }

    /// Light Leak: where on the frame's edge the light gets in, dragged along the edge or onto another side, and
    /// how far it reaches into the picture.
    @ViewBuilder private func leak(_ filter: CreativeFilter) -> some View {
        let edge = min(3, max(0, Int(filter["edge"].rounded()))), place = filter["position"] / 100, depth = 0.1 + 0.5 * filter["size"] / 100
        let sideways = edge == 0 || edge == 2
        // Into the picture from the edge, and along the edge.
        let inward = [CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)][edge]
        let origin = sideways ? CGPoint(x: edge == 0 ? picture.minX : picture.maxX, y: picture.minY + picture.height * place)
                              : CGPoint(x: picture.minX + picture.width * place, y: edge == 1 ? picture.minY : picture.maxY)
        let deep = depth * (sideways ? picture.width : picture.height), wide = (0.2 + 0.5 * depth) * (sideways ? picture.height : picture.width)
        let glow = Path(ellipseIn: CGRect(x: origin.x - (sideways ? deep : wide), y: origin.y - (sideways ? wide : deep), width: 2 * (sideways ? deep : wide), height: 2 * (sideways ? wide : deep)))
        line(glow, dashed: true).clipShape(Rectangle().path(in: picture))
        knob(CGPoint(x: origin.x + inward.dx * deep, y: origin.y + inward.dy * deep), L10n.tr("Size")) { location in
            let reached = sideways ? abs(location.x - origin.x) / picture.width : abs(location.y - origin.y) / picture.height
            model.set(.lightLeak, "size", (reached - 0.1) / 0.5 * 100)
        }
        badge(.lightLeak, at: CGPoint(x: origin.x + inward.dx * 14, y: origin.y + inward.dy * 14)) { location in
            // The nearest side is the one it is on.
            let gaps = [location.x - picture.minX, location.y - picture.minY, picture.maxX - location.x, picture.maxY - location.y]
            let nearest = gaps.indices.min { gaps[$0] < gaps[$1] } ?? edge
            model.set(.lightLeak, "edge", Double(nearest))
            model.set(.lightLeak, "position", (nearest == 0 || nearest == 2 ? (location.y - picture.minY) / picture.height : (location.x - picture.minX) / picture.width) * 100)
        }
    }

    /// Glow's Motion and Streak: the line light spreads along from each point, drawn through the middle of the photo
    /// as long as it reaches. Either end turns it and sets how far it goes. The halo styles have nothing to place.
    @ViewBuilder private func glow(_ filter: CreativeFilter) -> some View {
        let style = filter.glowStyle
        if style.hasAngle {
            let angle = filter["angle"] * .pi / 180, long = max(picture.width, picture.height)
            let centre = CGPoint(x: picture.midX, y: picture.midY), reach = Glow.reach(style, size: filter["size"]) * long
            // Rows count from the top, so the angle turns the other way on screen.
            let along = CGVector(dx: cos(angle), dy: -sin(angle))
            let end: (Double) -> CGPoint = { CGPoint(x: centre.x + along.dx * reach * $0, y: centre.y + along.dy * reach * $0) }
            // Bold: it crosses the whole photo, often over bright lights, and has to read there.
            line(Path { $0.move(to: end(-1)); $0.addLine(to: end(1)) }, dashed: true, bold: true).clipShape(Rectangle().path(in: picture))
            badge(.glow, at: centre)
            ForEach([-1.0, 1], id: \.self) { side in
                knob(end(side), L10n.tr("Angle"), round: true, large: true) { location in
                    var degrees = atan2(-(location.y - centre.y), location.x - centre.x) * 180 / .pi
                    if degrees > 90 { degrees -= 180 } else if degrees < -90 { degrees += 180 }
                    model.set(.glow, "angle", degrees)
                    model.set(.glow, "size", Glow.size(style, reaching: distance(location, centre) / max(1, long)))
                }
            }
        }
    }

    private func drag(_ moved: @escaping (CGPoint) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("filtersCenter")).onChanged { moved($0.location) }
    }
    /// A line of the overlay: white on a dark edge, so it reads on any photo.
    private func line(_ path: Path, dashed: Bool = false, bold: Bool = false) -> some View {
        let dash: [CGFloat] = dashed ? (bold ? [10, 6] : [6, 5]) : []
        return ZStack {
            path.stroke(.black.opacity(bold ? 0.6 : 0.45), style: StrokeStyle(lineWidth: bold ? 5 : 3, lineCap: bold ? .round : .butt, dash: dash))
            path.stroke(.white.opacity(bold ? 1 : dashed ? 0.8 : 0.95), style: StrokeStyle(lineWidth: bold ? 2.4 : 1.2, lineCap: bold ? .round : .butt, dash: dash))
        }.allowsHitTesting(false)
    }
    private func knob(_ at: CGPoint, _ label: String, round: Bool = false, large: Bool = false, _ moved: @escaping (CGPoint) -> Void) -> some View {
        Group {
            if round { Circle().fill(.white).overlay { Circle().strokeBorder(.black.opacity(0.55), lineWidth: 1) } }
            else { RoundedRectangle(cornerRadius: Theme.Radius.tag).fill(.white).overlay { RoundedRectangle(cornerRadius: Theme.Radius.tag).strokeBorder(.black.opacity(0.55), lineWidth: 1) } }
        }
        .frame(width: large ? 13 : 10, height: large ? 13 : 10).shadow(color: .black.opacity(0.5), radius: 1)
        .contentShape(Rectangle().inset(by: -8)).position(at).gesture(drag(moved)).help(label).accessibilityLabel(label)
    }
    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

    /// Bokeh: sharp inside the solid line, fully out of focus from the dashed one.
    @ViewBuilder private func bokeh(_ filter: CreativeFilter, _ centre: CGPoint) -> some View {
        let half = min(picture.width, picture.height) / 2, band = filter["shape"] >= 0.5
        let zone = half * (band ? 0.08 + 0.8 * filter["size"] / 100 : 0.15 + 1.1 * filter["size"] / 100)
        let outer = zone * (1 + 0.15 + 1.6 * filter["falloff"] / 100)
        let setSize: (Double) -> Void = { model.set(.bokeh, "size", ($0 / half - (band ? 0.08 : 0.15)) / (band ? 0.8 : 1.1) * 100) }
        let setFalloff: (Double) -> Void = { model.set(.bokeh, "falloff", ($0 / max(zone, 1) - 1.15) / 1.6 * 100) }
        if band {
            let angle = filter["angle"] * .pi / 180
            // Along the band and across it, as the picture is seen (rows counted from the top).
            let along = CGVector(dx: cos(angle), dy: -sin(angle)), across = CGVector(dx: -sin(angle), dy: -cos(angle))
            let reach = hypot(picture.width, picture.height)
            let offset: (Double) -> CGPoint = { CGPoint(x: centre.x + across.dx * $0, y: centre.y + across.dy * $0) }
            let rule: (Double) -> Path = { d in
                Path { p in
                    let o = offset(d)
                    p.move(to: CGPoint(x: o.x - along.dx * reach, y: o.y - along.dy * reach)); p.addLine(to: CGPoint(x: o.x + along.dx * reach, y: o.y + along.dy * reach))
                }
            }
            let depth: (CGPoint) -> Double = { abs(($0.x - centre.x) * across.dx + ($0.y - centre.y) * across.dy) }
            let turn = min(half * 0.7, max(60, zone * 1.2))
            Group {
                line(rule(zone)); line(rule(-zone)); line(rule(outer), dashed: true); line(rule(-outer), dashed: true)
            }.clipShape(Rectangle().path(in: picture))
            knob(offset(zone), L10n.tr("Size")) { setSize(depth($0)) }
            // On the far side from the size handle, unless that line has left the picture.
            knob(picture.contains(offset(-outer)) || !picture.contains(offset(outer)) ? offset(-outer) : offset(outer), L10n.tr("Falloff")) { setFalloff(depth($0)) }
            knob(CGPoint(x: centre.x + along.dx * turn, y: centre.y + along.dy * turn), L10n.tr("Angle"), round: true) { location in
                var degrees = atan2(-(location.y - centre.y), location.x - centre.x) * 180 / .pi
                if degrees > 90 { degrees -= 180 } else if degrees < -90 { degrees += 180 }
                model.set(.bokeh, "angle", degrees)
            }
        } else {
            let ring: (Double) -> Path = { r in Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r)) }
            Group { line(ring(zone)); line(ring(outer), dashed: true) }.clipShape(Rectangle().path(in: picture))
            knob(CGPoint(x: centre.x + zone, y: centre.y), L10n.tr("Size")) { setSize(distance($0, centre)) }
            knob(CGPoint(x: centre.x, y: centre.y - outer), L10n.tr("Falloff")) { setFalloff(distance($0, centre)) }
        }
    }

    /// Darken / Lighten Center: the shape the light changes across, with its size on the edge.
    @ViewBuilder private func light(_ filter: CreativeFilter, _ centre: CGPoint) -> some View {
        let half = min(picture.width, picture.height) / 2, oval = filter["shape"] >= 0.5
        let scale = 0.3 + 1.2 * filter["size"] / 100
        let rx = (oval ? picture.width / 2 : half) * scale, ry = (oval ? picture.height / 2 : half) * scale
        line(Path(ellipseIn: CGRect(x: centre.x - rx, y: centre.y - ry, width: 2 * rx, height: 2 * ry)), dashed: true).clipShape(Rectangle().path(in: picture))
        knob(CGPoint(x: centre.x + rx, y: centre.y), L10n.tr("Size")) { location in
            model.set(filter.kind, "size", (abs(location.x - centre.x) / max(1, oval ? picture.width / 2 : half) - 0.3) / 1.2 * 100)
        }
    }
}

/// The photo without the filters left of a line that drags across the picture.
private struct SplitDivider: View {
    let before: CGImage?
    let size: CGSize
    /// The filtered picture's border: the photo sits inside it.
    var border = BorderLayout.none
    @Binding var position: Double

    var body: some View {
        let x = size.width * position
        ZStack(alignment: .topLeading) {
            if let before {
                let picture = border.pictureRect(in: size, upright: before.height > before.width)
                Image(decorative: before, scale: 1).resizable().interpolation(.high).frame(width: picture.width, height: picture.height).offset(x: picture.minX, y: picture.minY)
                    .frame(width: size.width, height: size.height, alignment: .topLeading).frame(width: size.width, height: size.height)
                    .mask(alignment: .leading) { Rectangle().frame(width: x) }.allowsHitTesting(false)
            }
            Rectangle().fill(.white).frame(width: 1, height: size.height).shadow(color: .black.opacity(0.6), radius: 1).offset(x: x - 0.5).allowsHitTesting(false)
            Image(systemName: "arrow.left.and.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
                .frame(width: 24, height: 24).background(.white, in: Circle()).shadow(color: .black.opacity(0.5), radius: 2)
                .offset(x: x - 12, y: size.height / 2 - 12).allowsHitTesting(false)
            // The whole line takes the drag, so it can be caught wherever the zoomed picture shows it.
            Color.clear.frame(width: 24, height: size.height).contentShape(Rectangle()).offset(x: x - 12)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("filtersSplit")).onChanged { position = min(1, max(0, $0.location.x / max(1, size.width))) })
                .help(L10n.tr("Before")).accessibilityLabel(L10n.tr("Compare"))
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading).coordinateSpace(name: "filtersSplit")
    }
}

/// The filters switched on, as cards in the order they apply, each open on its controls unless folded. It is
/// SwiftUI's own reorderable list, in two runs: a card is dragged within its run to change what it works on, and Delete
/// or its button takes it out.
private struct FilterChain: View {
    @ObservedObject var model: FiltersModel
    /// Where each card is in the window, to tell which one a click lands on.
    @State private var frames: [CreativeFilterKind: CGRect] = [:]
    @State private var clicks: Any?

    var body: some View {
        let groups = model.appliedGroups
        List {
            run(L10n.tr("Lens"), groups.lens) { model.moveApplied(lens: true, from: $0, to: $1) }
            run(L10n.tr("Picture"), groups.picture) { model.moveApplied(lens: false, from: $0, to: $1) }
            run(L10n.tr("Border", context: "frame"), groups.border, move: nil)
            if !model.stack.setAside.isEmpty {
                Text(L10n.tr("Developed without \(model.stack.setAside.map(\.title).joined(separator: ", ")): the filters do that."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .listRowSeparator(.hidden).listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 4, trailing: 8))
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).environment(\.defaultMinListRowHeight, 1)
        .padding(.top, 8)
        .onPreferenceChange(CardFrames.self) { frames = $0 }
        .onAppear { watchClicks() }
        .onDisappear { if let clicks { NSEvent.removeMonitor(clicks) }; clicks = nil }
        .background {
            // Delete and Forward Delete take the picked filter out.
            Group {
                Button("") { model.removeSelection() }.keyboardShortcut(.delete, modifiers: [])
                Button("") { model.removeSelection() }.keyboardShortcut(.deleteForward, modifiers: [])
            }.opacity(0).accessibilityHidden(true)
        }
    }

    /// One run of the chain under its name. The moves are the run's own, so the list only offers places inside it.
    /// The name is a plain row, not a section header: a plain list pins its top header on a bar of its own.
    @ViewBuilder private func run(_ title: String, _ filters: [CreativeFilter], move: ((IndexSet, Int) -> Void)?) -> some View {
        if !filters.isEmpty {
            Section {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    .listRowSeparator(.hidden).listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 10, leading: 8, bottom: 2, trailing: 8))
                ForEach(filters, id: \.kind) { filter in
                    card(filter)
                        .listRowSeparator(.hidden).listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))
                }
                .onMove(perform: move)
            }
        }
    }

    /// Picks the card a click lands on, watching the click go by: a gesture of ours on the card would take the mouse
    /// before the list could start a drag.
    private func watchClicks() {
        guard clicks == nil else { return }
        clicks = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window, window.sheetParent == nil, window.attachedSheet == nil, let height = window.contentView?.bounds.height else { return event }
            let point = CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
            if let hit = frames.first(where: { $0.value.contains(point) })?.key, model.selection != hit { model.selection = hit }
            return event
        }
    }

    private func card(_ filter: CreativeFilter) -> some View {
        let kind = filter.kind, chosen = model.selection == kind, folded = model.folded.contains(kind)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: kind.symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(chosen ? Theme.onAccent : .primary)
                    .frame(width: 22, height: 22).background(chosen ? Theme.accent : Theme.ink.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                Text(kind.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if !folded, let place = model.stack.filters.firstIndex(where: { $0.kind == kind }) {
                    Button { model.stack.filters[place].reset() } label: {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 18).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(filter.isDefault).help(L10n.tr("Reset")).accessibilityLabel(L10n.tr("Reset"))
                }
                Button { if folded { model.folded.remove(kind) } else { model.folded.insert(kind) } } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).rotationEffect(.degrees(folded ? -90 : 0))
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary).help(folded ? L10n.tr("Expand") : L10n.tr("Collapse")).accessibilityLabel(folded ? L10n.tr("Expand") : L10n.tr("Collapse"))
                Button { model.remove(kind) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).frame(width: 18, height: 18).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.tertiary).help(L10n.tr("Remove")).accessibilityLabel(L10n.tr("Remove"))
            }
            .frame(height: 38)
            if !folded, let place = model.stack.filters.firstIndex(where: { $0.kind == kind }) {
                Rectangle().fill(Theme.ink.opacity(0.12)).frame(height: 1).padding(.top, -8)
                FilterSettings(filter: $model.stack.filters[place], model: model).padding(.top, 2).padding(.bottom, 12)
            }
        }
        .font(.system(size: 11)).padding(.horizontal, 10)
        .background(Theme.ink.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay { RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(chosen ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1.5) }
        .background { GeometryReader { geometry in Color.clear.preference(key: CardFrames.self, value: [kind: geometry.frame(in: .global)]) } }
        .accessibilityElement(children: .contain).accessibilityLabel(kind.title)
    }
}

private struct CardFrames: PreferenceKey {
    static let defaultValue: [CreativeFilterKind: CGRect] = [:]
    static func reduce(value: inout [CreativeFilterKind: CGRect], nextValue: () -> [CreativeFilterKind: CGRect]) { value.merge(nextValue()) { $1 } }
}

/// A filter's controls, inside its box in the chain.
private struct FilterSettings: View {
    @Binding var filter: CreativeFilter
    @ObservedObject var model: FiltersModel
    private var pictured: Bool { if filter.kind == .border, case .asset = filter.borderChoice { true } else { false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                // A pictured border has its own width and paper.
                if !pictured { slider(filter.kind.amountTitle, value: $filter.amount, range: filter.kind.amountRange, unit: "%") }
                ForEach(filter.kind.parameters) { parameter in
                    if let choices = parameter.choices, let picture = Self.picture(filter.kind, parameter.key) {
                        HStack(spacing: 8) {
                            Text(parameter.title).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
                            PicturedChoice(title: parameter.title, choices: choices, picture: picture,
                                           selection: Binding(get: { Int(filter[parameter.key].rounded()) }, set: { filter[parameter.key] = Double($0) }))
                        }
                    } else if let choices = parameter.choices, choices.count > 4 {
                        HStack(spacing: 8) {
                            Text(parameter.title).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
                            PanelPicker(title: parameter.title, selection: Binding(get: { Int(filter[parameter.key].rounded()) }, set: { filter[parameter.key] = Double($0) }),
                                        options: Array(choices.indices), label: { choices[$0] }, expands: true).controlSize(.small)
                        }
                    } else if let choices = parameter.choices, !(pictured && parameter.key == "tone") {
                        HStack(spacing: 8) {
                            Text(parameter.title).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
                            // Segments while they fit the card; longer names (Gold / Soft Gold / Silver, the four edges) drop
                            // into a menu rather than run past its edge.
                            let choice = Binding(get: { Int(filter[parameter.key].rounded()) }, set: { filter[parameter.key] = Double($0) })
                            ViewThatFits(in: .horizontal) {
                                FormSegments(title: parameter.title, selection: choice, options: Array(choices.indices), label: { choices[$0] }).labelsHidden().fixedSize()
                                PanelPicker(title: parameter.title, selection: choice, options: Array(choices.indices), label: { choices[$0] }, expands: true).controlSize(.small)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if parameter.choices == nil, !(filter.kind == .fog && parameter.key == "level" && filter["cover"] < 0.5), !(filter.kind == .polarizer && parameter.key == "angle" && filter["rotation"] < 0.5), !(filter.kind.isPlaced && (parameter.key == "x" || parameter.key == "y")),
                              !(filter.kind == .bokeh && parameter.key == "angle" && filter["shape"] < 0.5),
                              !(filter.kind == .glow && parameter.key == "angle" && !filter.glowStyle.hasAngle),
                              !(filter.kind == .diffusion && parameter.key == "size" && DiffusionShape.of(filter) != nil) {
                        // A placed filter's point is dragged on the picture; a round zone has no angle.
                        slider(parameter.title, value: Binding(get: { filter[parameter.key] }, set: { filter[parameter.key] = $0 }), range: parameter.range, unit: parameter.unit)
                    }
                }
                if let note { Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            .disabled(!filter.enabled).opacity(filter.enabled ? 1 : 0.5)
        }
        .font(.system(size: 11))
    }

    /// Choices that are pictures of something (a border, a texture) are picked from pictures.
    private static func picture(_ kind: CreativeFilterKind, _ key: String) -> ((Int) -> CGImage?)? {
        switch (kind, key) {
        case (.border, "style"): { FilterThumbnails.border($0) }
        case (.dust, "texture"): { FilterThumbnails.texture($0) }
        default: nil
        }
    }

    private var note: String? {
        switch filter.kind {
        case .outputSharpen: L10n.tr("Applied to the file at its own size; this preview doesn’t show it.")
        case .denoise: model.denoiseMissing ? L10n.tr("The AI noise reduction model is not installed. Install it in Settings › Models.") : nil
        case .polarizer: L10n.tr("Sun Direction is from straight ahead: 90° is to the right, −90° to the left, 180° behind.")
        default: nil
        }
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary).frame(width: 84, alignment: .leading).lineLimit(1)
            FormSlider(value: value, in: range)
            Text("\(Int(value.wrappedValue.rounded()))\(unit.isEmpty ? "" : unit == "%" ? " %" : unit)").monospacedDigit().frame(width: 44, alignment: .trailing)
        }
    }
}
