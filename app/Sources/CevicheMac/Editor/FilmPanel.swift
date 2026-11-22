import SwiftUI
import CevicheCore

/// The Darkroom tab: the camera's own rendering, or the photo on film after every other edit. The switch on top
/// turns the film on; below it, the steps a picture on film goes through: the film, its exposure and development,
/// the print or scan it is finished on, and its texture. The stocks are small prints of the photo, made in the
/// background as it opens; resting on one previews it full size, clicking puts it on the photo, on the medium it is
/// made for. The Print step shows what its medium takes: an enlarger's exposure, filtration and head for a paper,
/// the printer's lights for a print film, the levels and grade of a scan. Stock, paper and print film names are the
/// manufacturers' and stay untranslated. ACES and Glow render but are not shown yet.
struct FilmPanel: View {
    @ObservedObject var model: EditorModel
    @State private var hovered: String?
    private var film: FilmSimulation? { model.adjustments.film }
    private var printing: Bool { model.adjustments.rendering == .film }
    /// The photo's film is switched on but not in the catalog, so the stocks stay live to choose another.
    private var unknown: Bool { catalog.isAvailable && film.map { $0.enabled && $0.film == nil } == true }
    private let catalog = FilmCatalog.shared
    var body: some View {
        VStack(spacing: 0) {
            printSwitch
            if unknown, let film {
                Label(L10n.tr("Film “\(film.stock)” not available"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 8)
            }
            VStack(spacing: 0) { filmSteps(film ?? FilmSimulation()) }
                .disabled(!printing && !unknown).opacity(printing || unknown ? 1 : 0.4)
        }
        .padding(.top, 6)
        .disabled(!model.hasImage || model.busy || !catalog.isAvailable).opacity(model.hasImage ? 1 : 0.4)
        .onAppear { model.prewarmFilmPreviews(after: .zero) }
        .onChange(of: model.adjustments) { _, _ in model.prewarmFilmPreviews(after: .milliseconds(500)) }
        .onDisappear { if hovered != nil { hovered = nil; model.showLookPreview(nil) } }
    }
    /// The film on or off, a panel switch like Apply geometry's rather than a section; the sections below are its
    /// steps. Their settings stay on the photo when it is off.
    private var printSwitch: some View {
        HStack {
            Text(catalog.isAvailable ? L10n.tr("Film rendering") : L10n.tr("Film rendering is not in this build")).foregroundStyle(.secondary)
            Spacer()
            Toggle(L10n.tr("Film rendering"), isOn: Binding(get: { printing }, set: setPrinting))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
        .font(.system(size: 11))
        // Lined up with the sections' contents.
        .padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 8)
    }
    private func setPrinting(_ on: Bool) {
        model.edit { a in
            a.aces = false
            if on { var film = a.film ?? FilmSimulation(); film.enabled = true; a.film = film } else { a.film?.enabled = false }
        }
    }
    @ViewBuilder private func filmSteps(_ film: FilmSimulation) -> some View {
        let stock = film.film, medium = film.output
        EditorSection(key: "Film.Stock", title: L10n.tr("Film"), icon: "film", open: true,
                      reset: { model.edit { a in FilmCatalog.shared.film(FilmSimulation.defaultStock).map { a.film = (a.film ?? FilmSimulation()).with(stock: $0); a.film?.amount = 100 } } }) {
            adjustment("Amount", \.amount, 0...100, unit: "%")
            VStack(alignment: .leading, spacing: 2) {
                group(L10n.tr("Negative"), .negative)
                group(L10n.tr("Slide"), .slide)
                group(L10n.tr("B&W"), .monochrome)
                group(L10n.tr("Cine"), .cine)
                group(L10n.tr("Creative"), .creative)
                group(L10n.tr("Instant"), .instant)
            }
            .padding(.top, 4)
        }
        EditorSection(key: "Film.Develop", title: L10n.tr("Develop", context: "film"), icon: "flask", open: true,
                      reset: { model.editFilm { let d = FilmSimulation(stock: $0.stock); $0.format = d.format; $0.light = d.light; $0.push = 0; $0.bleachBypass = 0; $0.expired = 0 } },
                      isEnabled: part(.develop)) {
            VStack(spacing: 7) {
                row(L10n.tr("Format")) { picker(L10n.tr("Format"), \.format, FilmGauge.allCases, \.localizedTitle) }
                row(L10n.tr("Light")) { picker(L10n.tr("Light"), \.light, SceneLight.allCases, \.localizedTitle) }
                if let stock, stock.pushes.count > 1 {
                    row(L10n.tr("Push")) { picker(L10n.tr("Push"), \.push, stock.pushes, Self.stops) }
                }
                if let stock, !stock.isMonochrome, !stock.isPositive { adjustment("Bleach bypass", \.bleachBypass, 0...100, unit: "%") }
                adjustment("Expired", \.expired, 0...30, unit: "yr")
            }
        }
        EditorSection(key: "Film.Print", title: L10n.tr("Print"), icon: "printer", open: true,
                      reset: { model.editFilm { let d = FilmSimulation(); $0.medium = nil; $0.style = d.style; $0.grade = d.grade; $0.printExposure = 0; $0.yellow = 0; $0.magenta = 0; $0.head = d.head; $0.preflash = 0; $0.dodge = 0; $0.burn = 0 } },
                      isEnabled: part(.print)) {
            VStack(spacing: 7) {
                if let stock, let medium {
                    row(L10n.tr("Output")) { MediumMenu(selection: medium, media: stock.media) { id in model.editFilm { $0.medium = id == stock.own ? nil : id } } }
                    if medium.hasStyle { row(L10n.tr("Levels")) { picker(L10n.tr("Levels"), \.style, FilmScanStyle.allCases, \.localizedTitle) } }
                    if medium.hasGrade, film.style != .fixed { adjustment("Grade", \.grade, 0...5) }
                    if medium.hasExposure { adjustment("Exposure", \.printExposure, -3...3, unit: "EV") }
                    if medium.hasBalance {
                        adjustment("Y", \.yellow, -50...50, appearance: .complement(0.15))
                        adjustment("M", \.magenta, -50...50, appearance: .complement(0.83))
                        row(L10n.tr("Neutral")) { EyedropperButton(model: model, target: .printBalance) }
                    }
                    if medium.hasHead {
                        row(L10n.tr("Head")) { picker(L10n.tr("Head"), \.head, FilmHead.allCases, \.localizedTitle) }
                        adjustment("Preflash", \.preflash, 0...10, unit: "%")
                    }
                    if medium.hasDetail {
                        adjustment("Dodge", \.dodge, 0...100, unit: "%")
                        adjustment("Burn", \.burn, 0...100, unit: "%")
                    }
                }
            }
        }
        EditorSection(key: "Film.Texture", title: L10n.tr("Texture", context: "film"), icon: "aqi.medium", open: true,
                      reset: { model.editFilm { let d = FilmSimulation(); $0.grain = d.grain; $0.halation = d.halation; $0.couplers = d.couplers } },
                      isEnabled: part(.texture)) {
            VStack(spacing: 7) {
                adjustment("Grain", \.grain, 0...200, unit: "%")
                adjustment("Halation", \.halation, 0...200, unit: "%")
                adjustment("Couplers", \.couplers, 0...200, unit: "%")
            }
        }
    }
    /// "+1", "0", "−1": a development in stops.
    static func stops(_ value: Double) -> String {
        value == 0 ? "0" : (value > 0 ? "+" : "−") + abs(value).formatted(.number.precision(.fractionLength(0...1)).locale(L10n.locale))
    }
    private func group(_ title: String, _ kind: FilmProfile.Kind) -> some View {
        let films = catalog.films(kind)
        return VStack(alignment: .leading, spacing: 2) {
            if !films.isEmpty {
                Text(title).textCase(.uppercase).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.tertiary).padding(.top, 8).padding(.bottom, 3)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], alignment: .leading, spacing: 8) {
                    ForEach(films) { stock in stockTile(stock) }
                }
            }
        }
    }
    /// A small print of the photo on the stock, with its name; the maker and medium show in the tooltip.
    private func stockTile(_ stock: FilmProfile) -> some View {
        let settings = (film ?? FilmSimulation()).with(stock: stock)
        let applied = film?.enabled == true && film?.stock == stock.id
        let isHovered = hovered == stock.id
        let preview = model.filmPreviews[stock.id]
        return Button { model.edit { $0.film = settings; $0.aces = false } } label: {
            VStack(alignment: .leading, spacing: 3) {
                Theme.ink.opacity(0.06)
                    .aspectRatio(1.5, contentMode: .fit)
                    .overlay {
                        if let preview {
                            Image(decorative: preview, scale: 2).resizable().scaledToFill()
                        }
                    }
                    .clipped()
                    .selectionRing(applied ? Theme.accent : isHovered ? Theme.ink.opacity(0.35) : nil)
                Text(stock.name).font(.system(size: 10, weight: applied ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(applied ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(([stock.maker.map { "\($0) \(stock.name)" } ?? stock.name] + [settings.output?.name].compactMap { $0 }).joined(separator: " · "))
        .onHover { inside in
            if inside {
                hovered = stock.id
                var preview = model.adjustments; preview.film = settings
                model.showLookPreview(preview)
            } else if hovered == stock.id {
                hovered = nil; model.showLookPreview(nil)
            }
        }
        .accessibilityLabel(stock.name).accessibilityAddTraits(applied ? .isSelected : [])
    }
    /// A section's switch: off renders its settings at their defaults, keeping them for when it is switched back on.
    private func part(_ part: FilmSimulation.Part) -> Binding<Bool> {
        Binding(get: { !(film?.off.contains(part) ?? false) }, set: { on in model.editFilm { if on { $0.off.remove(part) } else { $0.off.insert(part) } } })
    }
    private func row(_ title: String, @ViewBuilder _ control: () -> some View) -> some View {
        HStack { Text(title).foregroundStyle(.secondary).lineLimit(1).fixedSize(); Spacer(minLength: 6); control() }.font(.system(size: 11))
    }
    private func picker<Value: Hashable>(_ title: String, _ key: WritableKeyPath<FilmSimulation, Value>, _ options: [Value], _ label: @escaping (Value) -> String) -> some View {
        PanelPicker(title: title, selection: Binding(get: { (film ?? FilmSimulation())[keyPath: key] }, set: { value in model.editFilm { $0[keyPath: key] = value } }),
                    options: options, label: label).controlSize(.small)
    }
    private func adjustment(_ title: String, _ key: WritableKeyPath<FilmSimulation, Double>, _ range: ClosedRange<Double>, unit: String = "", appearance: SliderAppearance? = nil) -> some View {
        FilmSlider(model: model, title: title, key: key, range: range, unit: unit, appearance: appearance)
    }
}

extension EditorModel {
    /// Edits the film settings, starting from the defaults when the photo has none.
    func editFilm(_ update: (inout FilmSimulation) -> Void) {
        edit { adjustments in
            var film = adjustments.film ?? FilmSimulation()
            update(&film)
            adjustments.film = film
        }
    }
}

/// A slider on one film setting; a drag is one undo step and double-clicking resets it.
struct FilmSlider: View {
    @ObservedObject var model: EditorModel
    let title: String
    let key: WritableKeyPath<FilmSimulation, Double>
    let range: ClosedRange<Double>
    var unit = ""
    var appearance: SliderAppearance?
    var body: some View {
        AdjustmentSlider(title: title, value: Binding(get: { (model.adjustments.film ?? FilmSimulation())[keyPath: key] }, set: { value in model.editFilm { $0[keyPath: key] = value } }),
                         range: range, unit: unit,
                         editing: { active in if active { model.beginGesture() } else { model.endGesture() } },
                         reset: { model.editFilm { $0[keyPath: key] = FilmSimulation()[keyPath: key] } }, appearance: appearance)
    }
}

/// The media a film can be finished on, grouped by kind and styled like the other panel pickers.
struct MediumMenu: View {
    let selection: FilmMedium
    let media: [FilmMedium]
    let choose: (String) -> Void
    private var groups: [(String, [FilmMedium])] {
        [(L10n.tr("Paper"), FilmMedium.Kind.paper), (L10n.tr("Print film"), .printFilm), (L10n.tr("Scan"), .scan), (L10n.tr("View", context: "film medium"), .view)]
            .map { title, kind in (title, media.filter { $0.kind == kind }) }.filter { !$0.1.isEmpty }
    }
    var body: some View {
        Menu {
            ForEach(groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1) { medium in
                        Toggle(medium.name, isOn: Binding(get: { selection.id == medium.id }, set: { if $0 { choose(medium.id) } }))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selection.name).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button).buttonStyle(.secondaryAction).menuIndicator(.hidden).controlSize(.small)
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityLabel(L10n.tr("Print")).accessibilityValue(selection.name)
    }
}
