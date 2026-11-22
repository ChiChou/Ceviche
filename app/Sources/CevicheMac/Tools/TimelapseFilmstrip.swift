import SwiftUI
import ImageIO
import CevicheCore

/// Every frame of the video in order. A frame that may spoil the sequence has an orange border, red when its original
/// is offline; a dashed line stands where frames are missing. The header sums up the problems, and the line below the
/// strip names those of the frame under the pointer, or of the current one. Click a frame to show it, ⌘- or ⇧-click to
/// select several, and ⌘⌫ to leave them out.
struct TimelapseFilmstrip: View {
    @ObservedObject var model: TimelapseModel
    let catalog: CatalogModel
    @FocusState private var focused: Bool
    private static let height: CGFloat = 56
    /// The frame under the pointer.
    @State private var hovered: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    let uses = model.plan?.uses
                    LazyHStack(spacing: 2) {
                        ForEach(Array(model.frames.enumerated()), id: \.element.id) { position, asset in
                            HStack(spacing: 2) {
                                if gap(at: position) != nil { gapMarker.onHover { hover(position, $0) } }
                                cell(position, asset, uses: uses).onHover { hover(position, $0) }
                            }.id(asset.id)
                        }
                    }.padding(6)
                }
                .scrollIndicators(.automatic)
                .frame(height: Self.height + 4 + 12)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .onHover { if !$0 { hovered = nil } }
                .selectionKeys(focus: $focused, hasSelection: model.canRemove(model.targets), selectAll: model.selectAll,
                               deselectAll: { model.selection = [] }, delete: { model.remove(model.targets) })
                .onChange(of: model.index) { _, index in if model.frames.indices.contains(index) { reader.scrollTo(model.frames[index].id) } }
                // Removing or restoring frames moves the current one even when its position stays.
                .onChange(of: model.frames.count) { if model.frames.indices.contains(model.index) { reader.scrollTo(model.frames[model.index].id) } }
            }
            warning
        }
        .font(.system(size: 11))
        .disabled(model.stage != .ready)
    }

    private var header: some View {
        let targets = model.targets, faulty = model.faulty
        return HStack(spacing: 8) {
            Text(L10n.tr("Frames")).font(.system(size: 12, weight: .semibold))
            Text(status).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            // The problems in the timeline, each a click away from its frames.
            ForEach(model.problemFrames, id: \.problem) { entry in
                Button { model.select(entry.problem) } label: {
                    Text(entry.problem.count(entry.positions.count)).monospacedDigit()
                    .foregroundStyle(entry.problem == .offline ? Theme.error : Theme.warning)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background((entry.problem == .offline ? Theme.error : Theme.warning).opacity(0.14), in: Capsule())
                }.buttonStyle(.plain).help(L10n.tr("Select these frames"))
            }
            if model.aligning { ProgressView().controlSize(.mini).help(L10n.tr("Checking for camera movement…")) }
            Spacer(minLength: 8)
            if model.output == .livePhoto {
                Button(L10n.tr("Make Key Photo")) { if model.frames.indices.contains(model.index) { model.keyID = model.frames[model.index].id } }
                    .buttonStyle(.secondaryAction).controlSize(.small).disabled(model.keyPosition == model.index)
            }
            if !model.removed.isEmpty {
                let restore = L10n.tr("Restore \(model.removed.count) Removed")
                Button { model.restoreRemoved() } label: {
                    HStack(spacing: 3) { Image(systemName: "arrow.uturn.backward"); Text("\(model.removed.count)").monospacedDigit() }
                }
                .buttonStyle(.secondaryAction).controlSize(.small).help(restore).accessibilityLabel(restore)
            }
            if !faulty.isEmpty {
                Button(faulty.count == 1 ? L10n.tr("Remove 1 Flagged") : L10n.tr("Remove \(faulty.count) Flagged")) { model.removeFaulty() }
                    .buttonStyle(.secondaryAction).controlSize(.small).disabled(!model.canRemove(faulty))
                    .help(L10n.tr("Leaves out offline photos, photos without a capture time, repeats of the same moment, photos from another camera or of another size, and frames out of line. Gaps, bursts and camera moves stay; Restore brings everything back."))
            }
            let remove = targets.count > 1 ? L10n.tr("Remove \(targets.count) Frames") : L10n.tr("Remove Frame")
            Button { model.remove(targets) } label: { Image(systemName: "trash") }
                .buttonStyle(.secondaryAction).controlSize(.small)
                .keyboardShortcut(.delete, modifiers: .command).disabled(!model.canRemove(targets))
                .help("\(remove) (⌘⌫)").accessibilityLabel(remove)
        }
    }
    private var status: String {
        guard model.stage == .ready else { return " " }
        let photos = model.frames.count, frames = model.plan?.frames.count ?? photos
        var parts = [model.settings.timing == .captureTime ? L10n.tr("\(photos) photos make \(frames) video frames") : L10n.tr("\(photos) frames")]
        if model.selection.count > 1 { parts.append(L10n.tr("\(model.selection.count) selected")) }
        return parts.joined(separator: " - ")
    }

    private func hover(_ position: Int, _ inside: Bool) {
        if inside { hovered = position } else if hovered == position { hovered = nil }
    }
    /// The problems of the frame under the pointer, or of the current one, in a word each. The line keeps its height
    /// when empty, so the dialog doesn't jump.
    private var warning: some View {
        let position = hovered ?? model.index
        let names = model.frames.indices.contains(position) ? model.problems(at: position).map(\.title) : []
        return HStack(spacing: 5) {
            if !names.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(model.isOffline(position) ? Theme.error : Theme.warning)
                Text(model.frames[position].filename).fontWeight(.semibold)
                Text(names.joined(separator: " - ")).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1).truncationMode(.middle)
        .frame(maxWidth: .infinity, minHeight: 14, alignment: .leading)
    }

    private func marks(_ position: Int) -> [TimelapseSeries.Mark] {
        guard let marks = model.series?.marks, marks.indices.contains(position) else { return [] }
        return marks[position]
    }
    /// A gap is between frames, so it is drawn there rather than on the frame after it.
    private func gap(at position: Int) -> (seconds: Double, missing: Int)? {
        for mark in marks(position) { if case .afterGap(let seconds, let missing) = mark { return (seconds, missing) } }
        return nil
    }
    private func flagged(_ position: Int) -> Bool { !model.problems(at: position).isEmpty }
    /// How many video frames show this photo most, when the timing follows capture time; nil one frame per photo.
    private func uses(_ position: Int, in uses: [Int: Int]?) -> Int? {
        guard model.settings.timing == .captureTime, let uses else { return nil }
        return uses[position] ?? 0
    }

    private func cell(_ position: Int, _ asset: CatalogAsset, uses frameUses: [Int: Int]?) -> some View {
        let offline = model.isOffline(position), flagged = flagged(position), shown = uses(position, in: frameUses)
        let current = position == model.index, selected = model.selection.contains(asset.id)
        let aspect = CGFloat(min(2.4, max(0.5, catalog.aspect(of: asset))))
        let warning: Color = offline ? Theme.error : Theme.warning
        return CatalogThumbnail(asset: asset, previews: catalog.previews, fillsFrame: true)
            .frame(width: Self.height * aspect, height: Self.height)
            .background(Theme.ink.opacity(0.04))
            .clipped()
            // A photo no frame shows most, as in a burst that keeps the series' pace, fades.
            .opacity(shown == 0 && !selected && !current ? 0.4 : 1)
            .overlay { if selected { Theme.accent.opacity(0.22) } }
            .overlay(Rectangle().strokeBorder(flagged ? warning : .clear, lineWidth: 2))
            .overlay(alignment: .topTrailing) {
                if flagged {
                    Image(systemName: offline ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(warning)
                        .padding(2).background(Color.black.opacity(0.6), in: Circle()).environment(\.colorScheme, .dark).padding(3)
                }
            }
            .overlay(alignment: .topLeading) {
                if model.output == .livePhoto && position == model.keyPosition { AccentBadge(text: L10n.tr("Key Photo")).padding(3) }
            }
            // The playhead and the selection ring the frame, so they never hide its warning.
            .padding(2)
            .selectionRing(current ? Theme.accent : selected ? Theme.accent.opacity(0.6) : nil)
            .contentShape(Rectangle())
            .onTapGesture {
                focused = true
                model.click(position, toggling: SelectionClick.toggling, extending: SelectionClick.extending)
            }
            .contextMenu {
                let ids = selected ? model.selection : [asset.id]
                Button(ids.count > 1 ? L10n.tr("Remove \(ids.count) Frames") : L10n.tr("Remove Frame")) { model.remove(ids) }.disabled(!model.canRemove(ids))
                if !model.removed.isEmpty { Button(L10n.tr("Restore \(model.removed.count) Removed")) { model.restoreRemoved() } }
                if model.output == .livePhoto {
                    Divider()
                    Button(L10n.tr("Make Key Photo")) { model.keyID = asset.id }.disabled(position == model.keyPosition)
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(([asset.filename] + model.problems(at: position).map(\.title)).joined(separator: ", "))
            .accessibilityAddTraits(current || selected ? .isSelected : [])
    }
    /// Hovering it names the frame after the pause.
    private var gapMarker: some View {
        Path { path in path.move(to: CGPoint(x: 4, y: 4)); path.addLine(to: CGPoint(x: 4, y: Self.height)) }
            .stroke(Theme.warning, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            .frame(width: 8, height: Self.height + 4)
            .contentShape(Rectangle())
    }
}
