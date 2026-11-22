import SwiftUI
import CevicheCore

/// What a People mask is chosen for: a new mask, or a component added to the selected one.
enum PeopleMaskTarget: Identifiable {
    case newMask, component(MaskOperation)
    var id: String { switch self { case .newMask: return "new"; case .component(let operation): return operation.rawValue } }
}

/// Choose one person, then the whole person or any of their parts; Create makes one mask of them. Shown in the Masks
/// panel itself, under the ways to add a mask, not as a dialog.
struct PeopleMaskChooser: View {
    @ObservedObject var model: EditorModel
    let target: PeopleMaskTarget
    let dismiss: () -> Void
    @State private var people: [PersonCandidate]?
    @State private var failure: String?
    @State private var person = 0
    @State private var parts: Set<PersonPart> = [.entire]
    /// Every part's tint for the chosen person, made in one pass as soon as the person is known, so ticking or
    /// pointing at a part shows it at once.
    @State private var previews: [PersonPart: CGImage] = [:]
    @State private var hovered: PersonPart?
    /// Observed so the model's parts turn on when it is installed in Settings › Models.
    @ObservedObject private var library = ModelLibrary.shared
    /// The parts this Mac can make: the face's always (Vision), skin, hair and clothes with the people model.
    private var pieces: [PersonPart] { _ = library.installed; return PersonPart.allCases.filter { $0 != .entire } }
    private func available(_ part: PersonPart) -> Bool { part.channel == nil || BundledModel.peopleParts.isAvailable }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("People")).font(.system(size: 13, weight: .semibold))
            if let people {
                if people.isEmpty {
                    Text(L10n.tr("No people found")).foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(people) { candidate in
                                Button { person = candidate.id } label: {
                                    VStack(spacing: 5) {
                                        Image(decorative: candidate.thumbnail, scale: 1).resizable().scaledToFill()
                                            .frame(width: 56, height: 56).clipShape(Circle())
                                            .overlay(Circle().strokeBorder(person == candidate.id ? Theme.accent : Color.clear, lineWidth: 2))
                                        Text(L10n.tr("Person \(candidate.id + 1)")).font(.system(size: 11)).foregroundStyle(person == candidate.id ? .primary : .secondary)
                                    }
                                }.buttonStyle(.plain).accessibilityAddTraits(person == candidate.id ? .isSelected : [])
                            }
                        }
                    }
                    Toggle(PersonPart.entire.localizedTitle, isOn: Binding(get: { parts.contains(.entire) }, set: { on in
                        parts = on ? [.entire] : []
                    })).toggleStyle(.formCheckbox).onHover { hover(.entire, $0) }
                    Rule()
                    ForEach(pieces, id: \.self) { part in
                        Toggle(part.localizedTitle, isOn: Binding(get: { parts.contains(part) }, set: { on in
                            parts.remove(.entire)
                            if on { parts.insert(part) } else { parts.remove(part) }
                        })).toggleStyle(.formCheckbox).disabled(!available(part))
                            .onHover { hover(part, $0) }
                    }
                    if !BundledModel.peopleParts.isAvailable { ModelPrompt(model: .peopleParts, compact: true) }
                }
            } else if let failure {
                Text(failure).foregroundStyle(.secondary)
            } else {
                HStack { ProgressView().controlSize(.small); Text(L10n.tr("Finding people…")).foregroundStyle(.secondary) }
            }
            HStack {
                Spacer()
                Button(L10n.tr("Cancel"), action: dismiss).buttonStyle(.secondaryAction).controlSize(.small)
                Button(L10n.tr("Create")) { create() }.buttonStyle(.secondaryAction).controlSize(.small)
                    .disabled(parts.isEmpty || (people?.isEmpty ?? true))
            }
        }
        .font(.system(size: 12)).padding(14).card()
        .onChange(of: parts) { showPreviews() }
        .onChange(of: hovered) { showPreviews() }
        .onDisappear { model.partPreviews = [] }
        // Warm every part of the chosen person at once; the ticked ones and the one under the pointer show as they land.
        .task(id: PreviewKey(person: person, found: people?.count ?? -1, installed: BundledModel.peopleParts.isAvailable)) {
            previews = [:]; showPreviews()
            guard let people, people.indices.contains(person), let renderer = model.renderer else { return }
            // The whole person first, which is quick, then every part in one pass.
            let box = people[person].box, settings = model.adjustments
            for wanted in [[PersonPart.entire], PersonPart.allCases.filter { $0 != .entire && available($0) }] {
                guard let made = try? await renderer.peoplePreviews(box, adjustments: settings, parts: wanted), !Task.isCancelled else { return }
                previews.merge(made) { $1 }; showPreviews()
            }
        }
        .task(id: target.id) {
            guard let renderer = model.renderer else { return }
            do { people = try await renderer.peopleInPhoto() } catch { failure = error.localizedDescription }
        }
    }

    private struct PreviewKey: Equatable { let person: Int, found: Int, installed: Bool }
    /// The ticked parts and the one under the pointer, in the mask overlay's red. Entire Person covers the other ticks
    /// and is fainter, so a part pointed at over it still stands out.
    private func showPreviews() {
        var shown = parts.contains(.entire) ? [.entire] : parts
        if let hovered { shown.insert(hovered) }
        model.partPreviews = PersonPart.allCases.filter(shown.contains).compactMap { part in
            previews[part].map { ($0, part == .entire ? 0.4 : 1) }
        }
    }
    private func hover(_ part: PersonPart, _ inside: Bool) {
        if inside { hovered = part } else if hovered == part { hovered = nil }
    }
    private func create() {
        guard let people, people.indices.contains(person) else { return }
        // In the order the list shows them.
        let chosen = PersonPart.allCases.filter(parts.contains)
        let selection = PeopleSelection(box: people[person].box, parts: chosen)
        dismiss()
        switch target {
        case .newMask: model.addMask(.people, people: selection)
        case .component(let operation): model.addComponent(.people, operation: operation, people: selection)
        }
    }
}
