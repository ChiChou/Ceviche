import SwiftUI
import AppKit
import CevicheCore

/// The user's ID photo templates, shared by the ID Photo tool and Settings › ID Photo.
@MainActor
final class IDPhotoTemplateStore: ObservableObject {
    static let shared = IDPhotoTemplateStore()
    let library: IDPhotoTemplateLibrary
    @Published private(set) var templates: [IDPhotoSpec]
    init(library: IDPhotoTemplateLibrary = .standard) { self.library = library; templates = library.templates() }

    func save(_ template: IDPhotoSpec) throws { try library.save(template); templates = library.templates() }
    func delete(_ id: String) throws { try library.delete(id); templates = library.templates() }

    /// A template by id, else a bundled spec.
    func spec(_ id: String) -> IDPhotoSpec? { templates.first { $0.id == id } ?? IDPhotoSpecs.spec(id) }

    /// A template to start from: a copy of `base`, or of ICAO's.
    func newTemplate(from base: IDPhotoSpec? = nil) -> IDPhotoSpec {
        let base = base ?? IDPhotoSpecs.fallback
        var name = base.isCustom ? L10n.tr("\(base.document) Copy") : base.title
        if templates.contains(where: { $0.document == name }) { name = L10n.tr("Template \(templates.count + 1)") }
        return base.template(named: name)
    }

    /// The templates, then the bundled specs by country, each group in order; `filter` keeps a country's documents when
    /// it matches the country (all of them) or the document (that one), under the country's header either way.
    func groups(matching filter: String = "") -> [(name: String, specs: [IDPhotoSpec])] {
        func matches(_ spec: IDPhotoSpec) -> Bool { spec.matches(filter) }
        var groups: [(name: String, specs: [IDPhotoSpec])] = []
        let custom = templates.filter(matches)
        if !custom.isEmpty { groups.append((L10n.tr("Custom"), custom)) }
        groups += Dictionary(grouping: IDPhotoSpecs.all.filter(matches), by: \.country)
            .map { (name: $0.value[0].countryName, specs: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return groups
    }
}

/// A template open in the editor.
struct IDPhotoTemplateEditing: Identifiable {
    let template: IDPhotoSpec
    let isNew: Bool
    var id: String { template.id }
}

// MARK: - List

/// Every document at once, grouped by country with the user's templates first: the first choice in ID Photo.
struct IDPhotoSpecList: View {
    typealias Group = (name: String, specs: [IDPhotoSpec])
    let choose: (IDPhotoSpec) -> Void
    let newTemplate: () -> Void
    /// Groups run down one column and on into the next, as in a newspaper, so the order still reads alphabetically.
    var columns = 1
    /// The most it grows to before it scrolls.
    var maxHeight = Double.infinity
    @ObservedObject private var store = IDPhotoTemplateStore.shared
    @State private var filter = ""
    @State private var hovered: String?
    @FocusState private var searching: Bool
    /// From the panel's edge to the flags and the search icon.
    private static let inset = 14.0
    /// The flags' column: country names, documents and the search text all start after it.
    private static let gutter = 22.0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    .frame(width: Self.gutter - 6, alignment: .leading)
                TextField(L10n.tr("Search"), text: $filter).textFieldStyle(.plain).focused($searching)
                    .onSubmit { if let first = store.groups(matching: filter).first?.specs.first { choose(first) } }
                if !filter.isEmpty {
                    Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help(L10n.tr("Clear"))
                }
                Button(L10n.tr("New Template…"), action: newTemplate).buttonStyle(.textLink)
            }
            .padding(.horizontal, Self.inset).padding(.vertical, 7)
            Rule()
            // As tall as every document needs, matches or not, so the search field stays put while typing; it scrolls
            // only when the space it is given runs out.
            let matches = store.groups(matching: filter)
            ViewThatFits(in: .vertical) {
                ZStack(alignment: .top) {
                    documents(store.groups()).hidden().accessibilityHidden(true)
                    documents(matches)
                }
                // A ScrollView takes all the height it is offered, so it is the one capped: a cap on the whole list
                // would hold that height even when the documents need less.
                ScrollView { documents(matches) }.frame(maxHeight: maxHeight)
            }
        }
        .font(.system(size: 12))
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline))
        .onAppear { searching = true }
    }

    @ViewBuilder private func documents(_ groups: [Group]) -> some View {
        SwiftUI.Group {
                if groups.isEmpty {
                    Text(L10n.tr("No matches")).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                } else if columns <= 1 {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(groups, id: \.name) { group in
                            Section { ForEach(group.specs) { row($0) } } header: { header(group) }
                        }
                    }.padding(.bottom, 6)
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(Self.split(groups, into: columns).enumerated()), id: \.offset) { index, column in
                            if index > 0 { Rule(.vertical) }
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(column, id: \.name) { group in
                                    header(group)
                                    ForEach(group.specs) { row($0) }
                                }
                            }.frame(maxWidth: .infinity, alignment: .top)
                        }
                    }
                    // The dividers between columns would stretch to any height; the columns set it instead.
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 6)
                }
        }
    }

    private func header(_ group: Group) -> some View {
        HStack(spacing: 0) {
            Text(group.specs.first?.flag ?? "").font(.system(size: 12)).frame(width: Self.gutter, alignment: .leading)
            Text(group.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        }
            .padding(.horizontal, Self.inset).padding(.top, 8).padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel)
    }
    /// Consecutive runs of groups, about the same number of rows each (a header counts as one); a group is never split.
    static func split(_ groups: [Group], into columns: Int) -> [[Group]] {
        guard columns > 1, !groups.isEmpty else { return [groups] }
        let total = groups.reduce(0) { $0 + $1.specs.count + 1 }
        let target = Double(total) / Double(columns)
        var result: [[Group]] = [[]], rows = 0
        for group in groups {
            let size = group.specs.count + 1
            // Start the next column once this one is full, or would end further past the target than short of it.
            if !result[result.count - 1].isEmpty, result.count < columns,
               Double(rows + size) - target > target - Double(rows) || Double(rows) >= target {
                result.append([]); rows = 0
            }
            result[result.count - 1].append(group); rows += size
        }
        return result
    }
    private func row(_ spec: IDPhotoSpec) -> some View {
        Button { choose(spec) } label: {
            HStack {
                Text(spec.isCustom ? spec.document : spec.documentTitle).lineLimit(1)
                Spacer(minLength: 8)
                Text(spec.sizeTitle).foregroundStyle(.secondary).monospacedDigit()
            }
            // Inside the hover highlight, which reaches 4 pt past the text into the margins.
            .padding(.leading, Self.inset - 4 + Self.gutter).padding(.trailing, Self.inset - 4).padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(hovered == spec.id ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? spec.id : (hovered == spec.id ? nil : hovered) }
    }
}

// MARK: - Editor

/// Creates or changes a template: the print size, where the head goes, and what the checks hold the photo to.
struct IDPhotoTemplateEditor: View {
    let original: IDPhotoSpec
    let isNew: Bool
    let saved: (IDPhotoSpec) -> Void
    @ObservedObject private var store = IDPhotoTemplateStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draft: IDPhotoSpec
    @State private var error: String?
    @State private var confirmingDelete = false

    init(original: IDPhotoSpec, isNew: Bool, saved: @escaping (IDPhotoSpec) -> Void = { _ in }) {
        self.original = original; self.isNew = isNew; self.saved = saved
        _draft = State(initialValue: original)
    }

    private var problem: String? {
        if draft.document.trimmingCharacters(in: .whitespaces).isEmpty { return L10n.tr("Name it") }
        if draft.widthMM <= 0 || draft.heightMM <= 0 { return L10n.tr("Size must be above zero") }
        if draft.headHeightMM[0] <= 0 || draft.headHeightMM[0] > draft.headHeightMM[1] { return L10n.tr("Head: minimum above maximum") }
        if draft.headHeightMM[1] >= draft.heightMM { return L10n.tr("Head taller than the photo") }
        if let crown = draft.crownToTopMM, crown[0] > crown[1] { return L10n.tr("Crown: minimum above maximum") }
        if let eyes = draft.eyeLineFromBottomMM, eyes[0] > eyes[1] { return L10n.tr("Eyes: minimum above maximum") }
        if draft.printDPI < 72 { return L10n.tr("At least 72 ppi") }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: isNew ? L10n.tr("New Template") : L10n.tr("Edit Template"))
            row(L10n.tr("Name")) { TextField(L10n.tr("Template name"), text: $draft.document).textFieldStyle(.formField) }
            row(L10n.tr("Size")) {
                number($draft.widthMM); Text("×").foregroundStyle(.secondary); number($draft.heightMM); unit("mm")
            }
            row(L10n.tr("Print")) { number($draft.printDPI, digits: 0); unit("ppi") }
            Rule()
            row(L10n.tr("Head")) { range($draft.headHeightMM) }
            optionalRange(L10n.tr("Crown"), help: L10n.tr("Crown to the top edge"), $draft.crownToTopMM, start: [3, 6])
            optionalRange(L10n.tr("Eyes"), help: L10n.tr("Eye line from the bottom edge"), $draft.eyeLineFromBottomMM,
                          start: [draft.heightMM * 0.56, draft.heightMM * 0.69].map { ($0 * 10).rounded() / 10 })
            Rule()
            row(L10n.tr("Background")) {
                FormSelect(L10n.tr("Background"), selection: $draft.background, valueLabel: title(draft.background)) {
                    ForEach([IDPhotoSpec.Background.white, .offWhite, .lightGrey, .lightBlue, .whiteOrLight], id: \.self) { Text(title($0)).tag($0) }
                }
            }
            row(L10n.tr("Glasses")) {
                FormSegments(title: L10n.tr("Glasses"), selection: $draft.glasses, options: [.never, .discouraged, .allowed], label: title)
            }
            row(L10n.tr("Expression")) {
                FormSegments(title: L10n.tr("Expression"), selection: $draft.expression, options: [.neutral, .slightSmile], label: title)
            }
            row("") { Toggle(L10n.tr("Mouth closed"), isOn: $draft.mouthClosed) }
            row(L10n.tr("Upload")) {
                TextField(L10n.tr("No limit"), text: Binding(
                    get: { draft.digital?.maxKB.map(String.init) ?? "" },
                    set: { text in
                        let kb = Int(text.filter(\.isNumber)).flatMap { $0 > 0 ? $0 : nil }
                        var digital = draft.digital ?? IDPhotoSpec.Digital()
                        digital.maxKB = kb
                        draft.digital = digital.minPx == nil && digital.maxPx == nil && kb == nil ? nil : digital
                    })).textFieldStyle(.formField).frame(width: 80)
                unit("KB")
            }
            row(L10n.tr("Notes")) { TextField("", text: Binding(get: { draft.notes ?? "" }, set: { draft.notes = $0.isEmpty ? nil : $0 }), axis: .vertical).textFieldStyle(.formField).lineLimit(1...3) }
            if let message = error ?? problem {
                Text(message).foregroundStyle(error != nil ? Theme.error : .secondary).font(.system(size: 11))
            }
            HStack(spacing: 8) {
                if !isNew { Button(L10n.tr("Delete…")) { confirmingDelete = true }.buttonStyle(.destructiveAction) }
                Spacer()
                Button(L10n.tr("Cancel")) { dismiss() }.buttonStyle(.secondaryAction).keyboardShortcut(.cancelAction)
                Button(L10n.tr("Save"), action: save).buttonStyle(.primaryAction).keyboardShortcut(.defaultAction).disabled(problem != nil)
            }
        }
        .font(.system(size: 12))
        .frame(width: 420)
        .padding(20)
        .background(Theme.panel)
        .tint(Theme.controlAccent)
        .confirmationDialog(L10n.tr("Delete the template “\(original.document)”?"), isPresented: $confirmingDelete) {
            Button(L10n.tr("Delete"), role: .destructive) {
                do { try store.delete(original.id); dismiss() } catch { self.error = error.localizedDescription }
            }
        }
    }

    private func save() {
        var template = draft
        template.document = template.document.trimmingCharacters(in: .whitespaces)
        do { try store.save(template); saved(template); dismiss() } catch { self.error = error.localizedDescription }
    }

    private func row<Content: View>(_ label: String, help: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).foregroundStyle(.secondary).frame(width: 78, alignment: .leading).help(help ?? "")
            content()
            Spacer(minLength: 0)
        }.frame(minHeight: 22)
    }
    private func number(_ value: Binding<Double>, digits: Int = 1) -> some View {
        TextField("", value: value, format: .number.precision(.fractionLength(0...digits)).locale(L10n.locale))
            .textFieldStyle(.formField).multilineTextAlignment(.trailing).frame(width: 58)
    }
    private func unit(_ text: String) -> some View { Text(text).foregroundStyle(.secondary) }
    private func range(_ values: Binding<[Double]>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            number(Binding(get: { values.wrappedValue[0] }, set: { values.wrappedValue[0] = $0 }))
            Text("–").foregroundStyle(.secondary)
            number(Binding(get: { values.wrappedValue[1] }, set: { values.wrappedValue[1] = $0 }))
            unit("mm")
        }
    }
    /// A range the document may leave open: unticked, the framing just centres the head.
    private func optionalRange(_ label: String, help: String, _ values: Binding<[Double]?>, start: [Double]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Toggle(label, isOn: Binding(get: { values.wrappedValue != nil }, set: { values.wrappedValue = $0 ? start : nil }))
                .toggleStyle(.formCheckbox).foregroundStyle(.secondary).frame(width: 78, alignment: .leading).help(help)
            if values.wrappedValue != nil {
                range(Binding(get: { values.wrappedValue ?? start }, set: { values.wrappedValue = $0 }))
            }
            Spacer(minLength: 0)
        }.frame(minHeight: 22)
    }

    private func title(_ background: IDPhotoSpec.Background) -> String {
        switch background {
        case .white: L10n.tr("White")
        case .offWhite: L10n.tr("Off-White")
        case .lightGrey: L10n.tr("Light Grey")
        case .lightBlue: L10n.tr("Light Blue")
        case .whiteOrLight: L10n.tr("White or Light")
        }
    }
    private func title(_ glasses: IDPhotoSpec.Glasses) -> String {
        switch glasses {
        case .never: L10n.tr("Not Allowed", context: "glasses")
        case .discouraged: L10n.tr("Discouraged")
        case .allowed: L10n.tr("Allowed", context: "glasses")
        }
    }
    private func title(_ expression: IDPhotoSpec.Expression) -> String {
        switch expression {
        case .neutral: L10n.tr("Neutral", context: "expression")
        case .slightSmile: L10n.tr("Slight Smile")
        }
    }
}

// MARK: - Settings

/// Settings › ID Photo: the user's templates, to create, change or delete outside the tool.
struct IDPhotoTemplatePreferences: View {
    @ObservedObject private var store = IDPhotoTemplateStore.shared
    @State private var editing: IDPhotoTemplateEditing?
    @State private var deleting: IDPhotoSpec?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                if store.templates.isEmpty {
                    Text(L10n.tr("No templates yet. Start one from a built-in document and change what differs.")).foregroundStyle(.secondary)
                }
                ForEach(store.templates) { template in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.document)
                            Text(L10n.tr("\(template.sizeTitle) · head \(template.headRange.lowerBound.formatted())–\(template.headRange.upperBound.formatted()) mm · \(Int(template.printDPI)) ppi"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L10n.tr("Edit…")) { editing = IDPhotoTemplateEditing(template: template, isNew: false) }
                        Button(L10n.tr("Duplicate")) { editing = IDPhotoTemplateEditing(template: store.newTemplate(from: template), isNew: true) }
                        Button { deleting = template } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help(L10n.tr("Delete")).accessibilityLabel(L10n.tr("Delete \(template.document)"))
                    }
                }
            } header: {
                Text(L10n.tr("Templates"))
            } footer: {
                Text(L10n.tr("Kept on this Mac and shared by every catalog."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Menu(L10n.tr("New Template")) {
                        Button(L10n.tr("Blank (ICAO)")) { editing = IDPhotoTemplateEditing(template: store.newTemplate(), isNew: true) }
                        Divider()
                        ForEach(store.groups(), id: \.name) { group in
                            if group.name != L10n.tr("Custom") {
                                Menu(group.name) {
                                    ForEach(group.specs) { spec in
                                        Button("\(spec.documentTitle) – \(spec.sizeTitle)") { editing = IDPhotoTemplateEditing(template: store.newTemplate(from: spec), isNew: true) }
                                    }
                                }
                            }
                        }
                    }.fixedSize()
                    Spacer()
                }
                if let error { Text(error).font(.caption).foregroundStyle(Theme.error) }
            }
        }
        .formStyle(.grouped)
        // Settings is shorter than the editor; it grows to hold it while it's open.
        .frame(minHeight: editing == nil ? nil : 640)
        .sheet(item: $editing) { IDPhotoTemplateEditor(original: $0.template, isNew: $0.isNew) }
        .confirmationDialog(deleting.map { L10n.tr("Delete the template “\($0.document)”?") } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L10n.tr("Delete"), role: .destructive) {
                if let template = deleting { do { try store.delete(template.id); error = nil } catch { self.error = error.localizedDescription } }
                deleting = nil
            }
        }
    }
}
