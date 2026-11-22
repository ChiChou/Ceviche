import SwiftUI
import CevicheCore

/// Shared by Grid, Map, Compare and Detail. Always visible, like the bottom bars of Photos and
/// other RAW editors: the view switch leads, and Detail also carries zoom, Compare and the panel toggles.
struct CatalogStatusBar: View {
    @ObservedObject var model: CatalogModel
    @ObservedObject var editor: EditorModel
    var body: some View {
        VStack(spacing: 0) {
            Rule()
            // The controls must not impose their combined minimum width on the photo and side panels. The widest
            // arrangement that fits wins: everything with the copy button named, then with it as an icon, then without the
            // thumbnail slider and status, then without the photo count, then with the view switch as a menu and the edit
            // clipboard and zoom slider in More, then with the view controls in More as well. Narrower still, that last bar
            // scrolls. Flags, rating and labels live in the inspector's Info panel and the culling bar.
            GeometryReader { geometry in
                ViewThatFits(in: .horizontal) {
                    controls(level: 0, titled: true)
                    controls(level: 0)
                    controls(level: 1)
                    controls(level: 2)
                    controls(level: 3)
                    controls(level: 4)
                    ScrollView(.horizontal) { controls(level: 4).frame(minWidth: geometry.size.width) }.scrollIndicators(.hidden)
                }
            }.frame(height: 36)
        }.background(Theme.statusBar)
    }
    /// The view switch, sort and edit clipboard lead; the view controls trail. `level` 0 is everything; 1 drops the
    /// slider and status; 2 drops the photo count; 3 folds the view switch and moves the edit clipboard and zoom slider
    /// to More; 4 moves the view controls to More too.
    private func controls(level: Int, titled: Bool = false) -> some View {
        HStack(spacing: 0) {
            leading(showsCount: level < 2, foldsViewSwitch: level >= 3, clipboard: level < 3, titled: titled).fixedSize()
            Spacer(minLength: 12)
            trailing(level: level).fixedSize()
        }.font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 36)
    }
    private func leading(showsCount: Bool, foldsViewSwitch: Bool, clipboard: Bool, titled: Bool) -> some View {
        HStack(spacing: 12) {
                if foldsViewSwitch { ViewModeMenu(catalog: model, editor: editor) } else { ViewModePicker(catalog: model, editor: editor) }
                if model.hasSecondaryDisplay { SecondaryWindowMenu(catalog: model, editor: editor) }
                Rule(.vertical).frame(height: 16)
                // The sort menu sits beside the view switch in every view, as in other RAW editors; it also orders the filmstrip.
                Menu {
                    CatalogSortItems(model: model)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "line.3.horizontal.decrease").font(.system(size: 15))
                        Image(systemName: model.filter.ascending ? "arrow.up" : "arrow.down").font(.system(size: 10, weight: .bold))
                    }.frame(height: 28).contentShape(Rectangle())
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().focusable(false)
                    .help(L10n.tr("Sort by \(model.filter.sort.title.lowercased()), \(model.filter.ascending ? model.filter.sort.ascendingTitle.lowercased() : model.filter.sort.descendingTitle.lowercased())"))
                    .accessibilityLabel(L10n.tr("Sort")).disabled(model.interactionBusy)
                if model.showsDates, model.filter.sort == .captureDate { DateJumpButton(model: model) }
                Rule(.vertical).frame(height: 16)
                // The filter bar shows the photo count and the header shows the open photo's name.
                let count = model.showingLibrary && showsCount
                if count {
                    Text(model.selectionCount > 1 ? L10n.tr("\(model.selectionCount.formatted()) selected - \(model.countLabel)") : model.countLabel).monospacedDigit().lineLimit(1)
                }
                if clipboard, model.shownOverview != .map {
                    if count { Rule(.vertical).frame(height: 16) }
                    EditClipboardControls(catalog: model, editor: editor, showsTitle: titled)
                }
        }
    }
    private func trailing(level: Int) -> some View {
        HStack(spacing: 12) {
                // Background work shows in the title bar's activity center; this is the catalog's own state.
                if level < 1 { Text(model.metadataPending ? L10n.tr("Saving…") : model.status).lineLimit(1).truncationMode(.middle) }
                if model.mutatingCatalog { ProgressView().controlSize(.mini) }
                if level < 4 {
                    if model.showingLibrary, model.shownOverview != .map { Rule(.vertical).frame(height: 16); LibraryViewControls(model: model, compact: level >= 1) }
                    else if model.viewMode == .compare { Rule(.vertical).frame(height: 16); CompareViewControls(editor: editor) }
                    else { Rule(.vertical).frame(height: 16); EditorViewControls(model: editor, showsZoomSlider: level < 3) }
                } else {
                    Rule(.vertical).frame(height: 16)
                }
                if level >= 3 { StatusBarMoreMenu(catalog: model, editor: editor, viewControls: level >= 4) }
        }
    }
    static func icon(for state: CloudSyncState) -> String {
        switch state {
        case .idle, .syncing, .upToDate: return "checkmark.icloud"
        case .waiting: return "icloud.and.arrow.up"
        case .unavailable, .removed: return "icloud.slash"
        case .failed: return "exclamationmark.icloud"
        }
    }
    static func text(for state: CloudSyncState) -> String {
        switch state {
        case .idle: return "iCloud"
        case .syncing: return L10n.tr("Syncing…")
        case .waiting: return L10n.tr("Waiting for iCloud")
        case .upToDate: return "iCloud"
        case .unavailable, .failed: return L10n.tr("Saved on This Mac")
        case .removed: return L10n.tr("Deleted from iCloud")
        }
    }
    /// The state, what it means, and what a click does.
    static func tooltip(for state: CloudSyncState) -> String {
        var detail = Self.detail(for: state)
        if !detail.hasSuffix(".") { detail += "." }
        switch state {
        case .upToDate, .removed: return "\(text(for: state)): \(detail)"
        default: return L10n.tr("\(text(for: state)): \(detail) Click to sync now.")
        }
    }
    static func detail(for state: CloudSyncState) -> String {
        switch state {
        case .idle: return L10n.tr("This catalog syncs through iCloud.")
        case .syncing: return L10n.tr("Exchanging changes with iCloud.")
        case .waiting: return L10n.tr("Your changes are saved on this Mac. iCloud will upload them when the service is ready.")
        case .upToDate(let date): return L10n.tr("Last uploaded to iCloud at \(date.localized(date: .omitted, time: .shortened)). Click to check for changes.")
        case .unavailable(let reason): return reason
        case .failed(let reason): return L10n.tr("Your catalog is saved on this Mac. Sync will retry automatically. \(reason)")
        case .removed: return L10n.tr("This catalog was deleted from iCloud on another Mac and no longer syncs.")
        }
    }

}

/// Thumbnail size and panel visibility for the Library.
struct LibraryViewControls: View {
    @ObservedObject var model: CatalogModel
    var compact = false
    var body: some View {
        HStack(spacing: 10) {
            if model.shownOverview != .map { ThumbnailSizeControls(model: model, showsSlider: !compact) }
        }.buttonStyle(.plain)
    }
}

/// The thumbnail size slider with a step button at each end.
struct ThumbnailSizeControls: View {
    @ObservedObject var model: CatalogModel
    var showsSlider = true
    var body: some View {
        HStack(spacing: 6) {
            Button { model.stepTileSize(larger: false) } label: { Image(systemName: "square.grid.3x3").font(.system(size: 11)).frame(width: 22, height: 28).contentShape(Rectangle()) }
                .help(L10n.tr("Smaller Thumbnails (⌘−)")).accessibilityLabel(L10n.tr("Smaller thumbnails"))
            if showsSlider {
                FormSlider(value: $model.tileSize, in: CatalogModel.tileSizes).frame(width: 110)
                    .accessibilityLabel(L10n.tr("Thumbnail size")).help(L10n.tr("Thumbnail size"))
            }
            Button { model.stepTileSize(larger: true) } label: { Image(systemName: "square.grid.2x2").font(.system(size: 13)).frame(width: 22, height: 28).contentShape(Rectangle()) }
                .help(L10n.tr("Larger Thumbnails (⌘=)")).accessibilityLabel(L10n.tr("Larger thumbnails"))
        }.buttonStyle(.plain)
    }
}

/// Reject, pick and 1–5 stars in the culling bar and the secondary window's bar, for the Library selection or the photo open in Develop. Clicking the current
/// flag or rating clears it, as on library tiles; P, X, U and 0–5 do the same from the keyboard.
struct PhotoRatingControls: View {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var editor: EditorModel
    private var targets: [CatalogAsset] { catalog.cullingTargets(editor: editor) }
    var body: some View {
        let targets = targets
        // A single photo shows the catalog's metadata, including pending changes; several show what they share.
        let rating = targets.count == 1 ? catalog.metadata.rating : Set(targets.map(\.rating)).count == 1 ? targets[0].rating : 0
        let review = targets.count == 1 ? catalog.metadata.review
            : Set(targets.map(\.review)).count == 1 ? targets[0].review : .unreviewed
        HStack(spacing: 2) {
            flag(.rejected, current: review)
            flag(.accepted, current: review)
            Rule(.vertical).frame(height: 16).padding(.horizontal, 6)
            stars(rating)
        }.buttonStyle(.plain).disabled(targets.isEmpty || catalog.interactionBusy || (catalog.showingLibrary && catalog.filter.area != .library))
    }
    @ViewBuilder private func stars(_ rating: Int) -> some View {
            ForEach(1...5, id: \.self) { value in
                Button { update(rating: value, current: rating) } label: {
                    Image(systemName: rating >= value ? "star.fill" : "star").font(.system(size: 13))
                        .frame(width: 24, height: 28).contentShape(Rectangle())
                        .foregroundStyle(rating >= value ? Theme.accent : Color.secondary.opacity(0.7))
                }.help(rating == value ? L10n.tr("Clear Rating (0)") : (value == 1 ? L10n.tr("\(value) Star (\(value))") : L10n.tr("\(value) Stars (\(value))")))
                    .accessibilityLabel((value == 1 ? L10n.tr("Rate \(value) star") : L10n.tr("Rate \(value) stars")))
                    .accessibilityAddTraits(rating == value ? .isSelected : [])
            }
    }
    private func flag(_ state: ReviewState, current: ReviewState) -> some View {
        Button { update(review: state, current: current) } label: {
            ReviewFlag(state: state, active: current == state, size: 13).frame(width: 28, height: 28).contentShape(Rectangle())
        }.help(current == state ? L10n.tr("Unflag (U)") : state == .accepted ? L10n.tr("Pick (P)") : L10n.tr("Reject (X)"))
            .accessibilityLabel(state == .accepted ? L10n.tr("Pick") : L10n.tr("Reject"))
            .accessibilityAddTraits(current == state ? .isSelected : [])
    }
    /// One photo toggles against its stored value; several are set together, or cleared when they all share the value.
    private func update(rating: Int, current: Int) { set(rating: rating, review: nil, sharedRating: current, sharedReview: nil) }
    private func update(review: ReviewState, current: ReviewState) { set(rating: nil, review: review, sharedRating: nil, sharedReview: current) }
    private func set(rating: Int?, review: ReviewState?, sharedRating: Int?, sharedReview: ReviewState?) {
        let targets = targets
        if targets.count == 1 { Task { await catalog.updateQuickMetadata(targets[0], rating: rating, review: review) }; return }
        Task {
            await catalog.setQuickMetadata(targets, rating: rating.map { sharedRating == $0 ? 0 : $0 },
                                           review: review.map { sharedReview == $0 ? .unreviewed : $0 })
        }
    }
}

/// The open catalog's iCloud state in the title bar, after its name: an icon and a short label, with the explanation in
/// the tooltip. Clicking syncs now.
struct SyncStatusIndicator: View {
    @ObservedObject var model: CatalogModel
    var body: some View {
        if let state = model.syncState {
            HStack(spacing: 5) {
                if case .syncing = state { ProgressView().controlSize(.mini) } else { Image(systemName: CatalogStatusBar.icon(for: state)) }
                Text(CatalogStatusBar.text(for: state)).lineLimit(1)
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.ink.opacity(0.06), in: Capsule())
            .contentShape(Capsule())
            .help(CatalogStatusBar.tooltip(for: state))
            .accessibilityElement(children: .ignore).accessibilityLabel(L10n.tr("iCloud: \(CatalogStatusBar.text(for: state))"))
            .accessibilityHint(CatalogStatusBar.detail(for: state)).accessibilityAddTraits(.isButton)
            .onTapGesture(perform: model.syncNow)
        }
    }
}
