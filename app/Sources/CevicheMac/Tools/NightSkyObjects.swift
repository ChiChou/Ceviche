import SwiftUI
import AppKit
import CevicheCore

/// What the Objects list and the outlines over the preview share: the lines selected and the lines under the pointer.
@MainActor
final class NightSkyObjectSelection: ObservableObject {
    /// The lines clicked or boxed in the preview or clicked in the list, lit in both.
    @Published var lines: Set<Int> = []
    /// The line under the pointer in the preview, or one of the list's rows.
    @Published var hovered: Int?
    /// Every piece of the aircraft whose row is under the pointer, lit together in the preview.
    @Published var hoveredGroup: Set<Int> = []
    /// Whether the selection last changed from the list, which needs no scrolling to.
    var fromList = false
    /// Lines boxed or clicked in the preview: replacing the selection, or flipping them in it.
    func select(_ ids: Set<Int>, adding: Bool) {
        if adding { lines.formSymmetricDifference(ids) } else { lines = ids }
    }
    func isPointed(_ id: Int) -> Bool { hovered == id || hoveredGroup.contains(id) }
    func deselectAll() { lines = [] }
}

/// Deciding which lines go into a tool's result, for the Objects list and the outlines alike.
struct NightSkyLineChooser<Settings: NightSkyLineChoosing> {
    let frames: [NightSkyFrameInfo]
    /// Every line found, its id its place here.
    let lines: [NightSkyLineInfo]
    @Binding var settings: Settings
    /// Why a line can't go into the result, such as its photo couldn't be aligned; nil when it can.
    let unavailable: (NightSkyLineInfo) -> String?

    func includes(_ line: NightSkyLineInfo) -> Bool { settings.includes(line) }
    /// Whether the line is in the result: chosen, and from a photo that goes into it.
    func reaches(_ line: NightSkyLineInfo) -> Bool { settings.includes(line) && unavailable(line) == nil }
    /// Lines from photos in the result that are left out of it.
    var leftOut: Int { lines.filter { unavailable($0) == nil && !settings.includes($0) }.count }
    /// Lines that go into the result.
    var kept: Int { lines.filter(reaches).count }
    /// The lines among `ids` that can be decided.
    func decidable(_ ids: Set<Int>) -> [Int] { ids.sorted().filter { $0 < lines.count && unavailable(lines[$0]) == nil } }
    /// Sets the choice of `ids`; nil leaves them to detection.
    func decide(_ ids: Set<Int>, include: Bool?) {
        for id in decidable(ids) { settings.choices[id] = include }
    }
    func setAll(_ value: Bool) { settings.choices = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, value) }) }

    /// Include, exclude or return to what detection chose, for `ids`: the selection, or the line right-clicked.
    @ViewBuilder func menuItems(_ ids: Set<Int>) -> some View {
        let lines = decidable(ids)
        let many = lines.count > 1
        Button(many ? L10n.tr("Include \(lines.count) Lines in Result") : L10n.tr("Include in Result")) { decide(ids, include: true) }.disabled(lines.isEmpty)
        Button(many ? L10n.tr("Exclude \(lines.count) Lines from Result") : L10n.tr("Exclude from Result")) { decide(ids, include: false) }.disabled(lines.isEmpty)
        Divider()
        Button(L10n.tr("Revert to Detection")) { decide(ids, include: nil) }.disabled(!lines.contains { settings.choices[$0] != nil })
    }

    static func label(_ kind: NightSkyLineKind) -> String {
        switch kind {
        case .meteor: L10n.tr("Likely meteor")
        case .track: L10n.tr("Likely aircraft or satellite")
        case .shake: L10n.tr("Possible camera movement")
        }
    }

    static var includedColor: Color { Color(red: 0.35, green: 0.86, blue: 0.45) }
    static var excludedColor: Color { Color(red: 1, green: 0.42, blue: 0.36) }
    /// A line that can't reach the result whatever its choice, as when its photo is left out.
    static var unavailableColor: Color { Color(white: 0.6) }
    /// Some of an aircraft's pieces kept and some left out.
    static var mixedColor: Color { Color(red: 0.98, green: 0.78, blue: 0.3) }

    /// Where `ids` stand together: all in the result, all out, some of each, or none able to reach it.
    func state(_ ids: [Int]) -> NightSkyObjectState {
        let open = ids.filter { unavailable(lines[$0]) == nil }
        guard !open.isEmpty else { return .unavailable }
        let kept = open.filter { settings.includes(lines[$0]) }.count
        return kept == open.count ? .kept : kept == 0 ? .leftOut : .mixed
    }
    /// The toggle at a row's end: anything kept is left out, otherwise all of it goes in.
    func flip(_ ids: [Int]) { decide(Set(ids), include: state(ids) == .leftOut) }
}

enum NightSkyObjectState { case kept, leftOut, mixed, unavailable }

/// Which lines the Objects list shows.
enum NightSkyObjectFilter: Hashable, CaseIterable {
    case all, aircraft, meteors
    var title: String {
        switch self {
        case .all: L10n.tr("All")
        case .aircraft: L10n.tr("Aircraft")
        case .meteors: L10n.tr("Meteors")
        }
    }
    func shows(_ line: NightSkyLineInfo) -> Bool {
        switch self {
        case .all: true
        case .aircraft: line.kind == .track
        case .meteors: line.kind == .meteor
        }
    }
}

/// One row of the Objects list: a meteor, an aircraft or satellite with its pieces across photos, a piece of one
/// shown under it, or the short lines a camera bump left in one photo.
private struct NightSkyObjectRow: Identifiable {
    enum Kind { case meteor, aircraft, piece, movement }
    let id: String
    let kind: Kind
    /// The lines the row stands for, in capture order.
    let lines: [NightSkyLineInfo]
    var ids: [Int] { lines.map(\.id) }
}

/// The lines found, by kind: meteors, aircraft and satellites (a row each, whatever the photos they cross), and camera
/// movement. Each row shows a close-up, when it was captured and a toggle that keeps it in or leaves it out of the
/// result; ↑ and ↓ move through the rows, K keeps and X leaves out. `accessory` adds a tool's own control to a
/// meteor's row, such as making its photo the base.
struct NightSkyObjectsPanel<Settings: NightSkyLineChoosing, Accessory: View>: View {
    /// Nil until the photos are analyzed.
    let chooser: NightSkyLineChooser<Settings>?
    @ObservedObject var selection: NightSkyObjectSelection
    @ViewBuilder let accessory: (Int) -> Accessory
    @FocusState private var listFocused: Bool
    @State private var filter = NightSkyObjectFilter.all
    /// Aircraft rows opened to show their pieces.
    @State private var expanded: Set<String> = []
    /// Where a ⇧-click range starts.
    @State private var anchor: String?
    /// Shared by Star Trails and Meteor Shower, and kept across launches.
    @AppStorage("nightSkyObjectsWidth") private var width = 320.0

    private typealias Chooser = NightSkyLineChooser<Settings>
    private typealias Row = NightSkyObjectRow
    private static var widths: ClosedRange<Double> { 260...520 }

    var body: some View {
        HStack(spacing: 0) {
            SidebarResizeHandle(width: $width, range: Self.widths, defaultWidth: 320, panelOnRight: true)
            panel.frame(width: min(Self.widths.upperBound, max(Self.widths.lowerBound, width)))
        }
        // Analyzing again can find other lines under the same ids.
        .onChange(of: chooser?.lines.map(\.length)) { selection.lines = []; selection.hovered = nil; expanded = [] }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header
            if let chooser, !chooser.lines.isEmpty {
                FormSegments(title: L10n.tr("Show"), selection: $filter, options: NightSkyObjectFilter.allCases, label: { $0.title }, equalWidths: true).labelsHidden()
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            Rule()
            if let chooser, !selection.lines.isEmpty {
                selectionBar(chooser)
                Rule()
            }
            if let chooser {
                if chooser.lines.isEmpty {
                    Text(L10n.tr("No meteors or other lines were found in these photos.")).font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(20).frame(maxHeight: .infinity)
                } else {
                    list(chooser)
                }
            } else {
                Spacer()
            }
        }
        .frame(maxHeight: .infinity).background(Theme.statusBar)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(L10n.tr("Objects")).font(.headline)
            if let chooser, !chooser.lines.isEmpty {
                Text(L10n.tr("\(chooser.kept) kept") + (chooser.leftOut > 0 ? " · " + L10n.tr("\(chooser.leftOut) left out") : ""))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let chooser {
                Menu {
                    Button(L10n.tr("Choose All")) { chooser.setAll(true) }
                    Button(L10n.tr("Revert to Detection")) { chooser.settings.choices = [:] }
                    Button(L10n.tr("Choose None")) { chooser.setAll(false) }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
        }
        // As tall as the Video panel's header beside it, so the two titles line up.
        .frame(height: 22).padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// The selected lines' count and what can be done with them.
    private func selectionBar(_ chooser: Chooser) -> some View {
        HStack(spacing: 6) {
            Text(selection.lines.count == 1 ? L10n.tr("1 line selected") : L10n.tr("\(selection.lines.count) lines selected")).font(.system(size: 11))
                .foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Button(L10n.tr("Include")) { chooser.decide(selection.lines, include: true) }.help(L10n.tr("Add the selected lines to the result (K)"))
            Button(L10n.tr("Exclude")) { chooser.decide(selection.lines, include: false) }.help(L10n.tr("Leave the selected lines out of the result (X)"))
        }
        .controlSize(.small).disabled(chooser.decidable(selection.lines).isEmpty)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.accent.opacity(0.1))
    }

    // MARK: Rows

    /// The rows by kind, each kind in capture order, as the filter shows them.
    private func sections(_ chooser: Chooser) -> [(title: String, rows: [Row])] {
        let shown = chooser.lines.filter(filter.shows)
        let meteors = shown.filter { $0.kind == .meteor }.map { Row(id: "m\($0.id)", kind: .meteor, lines: [$0]) }
        let tracks = Dictionary(grouping: shown.filter { $0.kind == .track }) { $0.group ?? -1 - $0.id }
            .values.map { $0.sorted { ($0.frame, $0.id) < ($1.frame, $1.id) } }.sorted { $0[0].frame < $1[0].frame }
            .map { Row(id: "t\($0[0].id)", kind: .aircraft, lines: $0) }
        let movement = Dictionary(grouping: shown.filter { $0.kind == .shake }, by: \.frame).sorted { $0.key < $1.key }
            .map { Row(id: "s\($0.key)", kind: .movement, lines: $0.value) }
        return [(L10n.tr("Meteors"), meteors), (L10n.tr("Aircraft"), tracks), (L10n.tr("Camera Movement"), movement)].filter { !$0.rows.isEmpty }
    }

    /// The rows as shown, an open aircraft's pieces under it.
    private func visibleRows(_ chooser: Chooser) -> [Row] {
        sections(chooser).flatMap(\.rows).flatMap { row in
            [row] + (row.kind == .aircraft && expanded.contains(row.id) ? pieces(row) : [])
        }
    }
    private func pieces(_ row: Row) -> [Row] { row.lines.map { Row(id: "p\($0.id)", kind: .piece, lines: [$0]) } }

    private func list(_ chooser: Chooser) -> some View {
        let sections = sections(chooser)
        // Not lazy, so a line selected in the preview can be scrolled to however far down its row is.
        return ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sections, id: \.title) { section in
                        if filter == .all {
                            Text(section.title).textCase(.uppercase).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                                .padding(.horizontal, 6).padding(.top, section.title == sections.first?.title ? 2 : 12).padding(.bottom, 4)
                        }
                        ForEach(section.rows) { row in
                            rowView(chooser, row)
                            if row.kind == .aircraft, expanded.contains(row.id) {
                                ForEach(pieces(row)) { rowView(chooser, $0) }
                            }
                        }
                    }
                    if sections.isEmpty {
                        Text(filter == .meteors ? L10n.tr("No meteors") : L10n.tr("No aircraft")).font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 20)
                    }
                }.padding(.horizontal, 8).padding(.vertical, 8)
            }
            .selectionKeys(focus: $listFocused, hasSelection: !selection.lines.isEmpty,
                           selectAll: { selection.lines = Set(visibleRows(chooser).flatMap(\.ids)) }, deselectAll: selection.deselectAll)
            .onKeyPress(.downArrow) { step(chooser, by: 1, reader: reader) }
            .onKeyPress(.upArrow) { step(chooser, by: -1, reader: reader) }
            .onKeyPress(characters: CharacterSet(charactersIn: "kKxX")) { press in
                guard !selection.lines.isEmpty else { return .ignored }
                chooser.decide(selection.lines, include: press.characters.lowercased() == "k")
                return .handled
            }
            .onChange(of: selection.lines) { _, ids in
                defer { selection.fromList = false }
                guard !selection.fromList, let row = visibleRows(chooser).first(where: { !Set($0.ids).isDisjoint(with: ids) }) else { return }
                withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo(row.id, anchor: .center) }
            }
        }
    }

    /// ↑ or ↓: the row after the last selected one, or before the first.
    private func step(_ chooser: Chooser, by offset: Int, reader: ScrollViewProxy) -> KeyPress.Result {
        let rows = visibleRows(chooser)
        guard !rows.isEmpty else { return .ignored }
        let lit = rows.indices.filter { isLit(rows[$0]) }
        let next = lit.isEmpty ? (offset > 0 ? 0 : rows.count - 1) : max(0, min(rows.count - 1, (offset > 0 ? lit.last! : lit.first!) + offset))
        selection.fromList = true
        selection.lines = Set(rows[next].ids); anchor = rows[next].id
        reader.scrollTo(rows[next].id)
        return .handled
    }

    private func isLit(_ row: Row) -> Bool { !row.lines.isEmpty && row.ids.allSatisfy(selection.lines.contains) }

    private func click(_ chooser: Chooser, _ row: Row) {
        selection.fromList = true; listFocused = true
        if SelectionClick.toggling {
            selection.lines.formSymmetricDifference(row.ids)
        } else if SelectionClick.extending, let anchor, let rows = Optional(visibleRows(chooser)),
                  let from = rows.firstIndex(where: { $0.id == anchor }), let to = rows.firstIndex(where: { $0.id == row.id }) {
            selection.lines = Set(rows[min(from, to)...max(from, to)].flatMap(\.ids))
            return
        } else {
            selection.lines = Set(row.ids)
        }
        anchor = row.id
    }

    private func rowView(_ chooser: Chooser, _ row: Row) -> some View {
        let state = chooser.state(row.ids)
        let lit = isLit(row), pointed = row.ids.contains { selection.isPointed($0) }
        let first = row.lines[0], frame = chooser.frames[first.frame]
        let reason = chooser.unavailable(first)
        let piece = row.kind == .piece
        return HStack(spacing: 10) {
            closeUp(row, state: state, outline: lit || pointed ? Theme.accent : nil)
                .frame(width: piece ? 30 : 44, height: piece ? 30 : 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title(chooser, row)).font(.system(size: piece ? 11 : 12, weight: piece ? .regular : .semibold)).monospacedDigit()
                        .foregroundStyle(state == .kept || state == .mixed ? .primary : .secondary)
                    if row.ids.contains(where: { chooser.settings.choices[$0] != nil }) {
                        Image(systemName: "hand.point.up.left.fill").font(.system(size: 8)).foregroundStyle(.secondary)
                            .help(L10n.tr("Set by you"))
                    }
                }
                if !piece {
                    Text(detail(chooser, row)).font(.system(size: 10)).monospacedDigit().foregroundStyle(reason != nil && state == .unavailable ? Theme.warning : .secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if row.kind == .meteor { accessory(first.frame) }
            if row.kind == .aircraft {
                Button { withAnimation(.easeOut(duration: 0.15)) { if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) } } } label: {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded.contains(row.id) ? 90 : 0)).frame(width: 18, height: 18).contentShape(Rectangle())
                }.buttonStyle(.plain).help(expanded.contains(row.id) ? L10n.tr("Hide the photos") : L10n.tr("Show each photo"))
            }
            toggle(chooser, row, state: state)
        }
        .padding(.horizontal, 6).padding(.vertical, piece ? 2 : 5)
        .padding(.leading, piece ? 24 : 0)
        .background(lit ? Theme.accent.opacity(0.18) : pointed ? Theme.ink.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .contentShape(Rectangle())
        .id(row.id)
        .help(helpText(chooser, row))
        .onTapGesture { click(chooser, row) }
        .onHover { inside in
            if inside { selection.hovered = row.lines.count == 1 ? first.id : nil; selection.hoveredGroup = row.lines.count > 1 ? Set(row.ids) : [] }
            else if selection.hovered == first.id || selection.hoveredGroup == Set(row.ids) { selection.hovered = nil; selection.hoveredGroup = [] }
        }
        .contextMenu { chooser.menuItems(Set(row.ids).isSubset(of: selection.lines) ? selection.lines : Set(row.ids)) }
    }

    /// When: a meteor's or a piece's time, an aircraft's first and last, or the photo's name without capture times.
    private func title(_ chooser: Chooser, _ row: Row) -> String {
        let times = row.lines.map { NightSkyFormat.time(chooser.frames[$0.frame].time) }
        guard let first = times.first, !first.isEmpty else { return chooser.frames[row.lines[0].frame].filename }
        let last = times.last!
        return first == last ? first : "\(first)–\(last)"
    }

    /// What: a line's length, an aircraft's photos, a bump's lines, or why it can't reach the result.
    private func detail(_ chooser: Chooser, _ row: Row) -> String {
        if chooser.state(row.ids) == .unavailable, let reason = chooser.unavailable(row.lines[0]) { return reason }
        switch row.kind {
        case .meteor, .piece: return L10n.tr("\(Int(row.lines[0].length.rounded())) px")
        case .aircraft:
            let photos = Set(row.lines.map(\.frame)).count
            return photos == 1 ? L10n.tr("1 photo") : L10n.tr("\(photos) photos")
        case .movement: return L10n.tr("\(row.lines.count) lines")
        }
    }

    private func helpText(_ chooser: Chooser, _ row: Row) -> String {
        let names = Array(Set(row.lines.map { chooser.frames[$0.frame].filename })).sorted()
        let photos = names.count > 3 ? "\(names.first!) – \(names.last!)" : names.joined(separator: ", ")
        return Chooser.label(row.lines[0].kind) + "\n" + photos
    }

    /// The longest line's close-up, greyed when it doesn't go into the result.
    private func closeUp(_ row: Row, state: NightSkyObjectState, outline: Color?) -> some View {
        let picture = row.lines.filter { $0.thumbnail != nil }.max { $0.length < $1.length }?.thumbnail
        return Group {
            if let picture { Image(decorative: picture, scale: 1).resizable().interpolation(.none).scaledToFill() } else { Color.black }
        }
        .clipped()
        .saturation(state == .kept || state == .mixed ? 1 : 0).opacity(state == .kept || state == .mixed ? 1 : 0.5)
        .overlay(Rectangle().strokeBorder(outline ?? .white.opacity(0.08), lineWidth: outline == nil ? 1 : 2))
    }

    /// The row's keep toggle: ✓ in the result, × left out, − some of an aircraft's pieces, grey when it can't reach it.
    private func toggle(_ chooser: Chooser, _ row: Row, state: NightSkyObjectState) -> some View {
        let (icon, color): (String, Color) = switch state {
        case .kept: ("checkmark", Chooser.includedColor)
        case .leftOut: ("xmark", Chooser.excludedColor)
        case .mixed: ("minus", Chooser.mixedColor)
        case .unavailable: ("minus", Chooser.unavailableColor)
        }
        return Button { chooser.flip(row.ids) } label: {
            Image(systemName: icon).font(.system(size: 9, weight: .heavy)).foregroundStyle(.black.opacity(0.8))
                .frame(width: 20, height: 20).background(color.opacity(state == .unavailable ? 0.5 : 1), in: Circle()).contentShape(Circle())
        }
        .buttonStyle(.plain).disabled(state == .unavailable)
        .help(state == .kept ? L10n.tr("In the result. Click to leave it out.") : state == .unavailable ? "" : L10n.tr("Left out of the result. Click to include it."))
        .accessibilityLabel(Chooser.label(row.lines[0].kind))
        .accessibilityValue(state == .kept ? L10n.tr("Included") : L10n.tr("Excluded"))
    }
}

/// Every line found, beside the line itself: green goes into the result, red dashed is left out, and the selection
/// is lit. A click or a dragged box selects; a right-click includes or excludes. Without `showAll` only the selected
/// line and the one under the pointer are drawn.
struct NightSkyObjectOutlines<Settings: NightSkyLineChoosing>: View {
    let preview: NightSkyPreview?
    let chooser: NightSkyLineChooser<Settings>?
    @ObservedObject var selection: NightSkyObjectSelection
    let showAll: Bool

    private typealias Chooser = NightSkyLineChooser<Settings>

    var body: some View {
        NightSkyOutlines(preview: preview, style: { id in
            guard let chooser, id < chooser.lines.count else { return nil }
            let selected = selection.lines.contains(id), pointed = selection.isPointed(id)
            guard showAll || selected || pointed else { return nil }
            let included = chooser.reaches(chooser.lines[id])
            let color = included ? Chooser.includedColor : Chooser.excludedColor.opacity(0.85)
            if selected { return NightSkyOutlineStyle(color: Theme.accent, width: 2.2, dashed: !included, band: Theme.accent.opacity(pointed ? 0.4 : 0.28)) }
            if pointed { return NightSkyOutlineStyle(color: color, width: 2.2, dashed: !included, band: .white.opacity(0.16)) }
            return NightSkyOutlineStyle(color: color, width: included ? 1.3 : 1.1, dashed: !included)
        }, point: { selection.hovered = $0 }, select: { ids, adding in selection.select(ids, adding: adding) })
        .contextMenu {
            let targets: Set<Int> = if let hovered = selection.hovered, !selection.lines.contains(hovered) { [hovered] } else { selection.lines }
            if let chooser, !targets.isEmpty { chooser.menuItems(targets) }
        }
        .help(selection.hovered.flatMap { id in chooser.flatMap { id < $0.lines.count ? Chooser.label($0.lines[id].kind) : nil } } ?? "")
    }
}
