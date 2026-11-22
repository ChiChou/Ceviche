import SwiftUI
import CevicheCore

/// Groups: photos folded into one cell of the grid, the wall and the filmstrip until expanded.
extension CatalogModel {
    /// How many photos the group `asset` is the cover of holds, or nil when it covers no group.
    func groupSize(of asset: CatalogAsset) -> Int? {
        guard asset.stackID == asset.id, let size = stackSizes[asset.id], size > 1 else { return nil }
        return size
    }
    func groupExpanded(_ asset: CatalogAsset) -> Bool { asset.stackID.map(filter.expandedStacks.contains) ?? false }
    /// Every photo of the group `id` covers while it is folded, cover first; nil for any other photo.
    func foldedMembers(of id: String) -> [CatalogAsset]? {
        guard filter.area == .library, !filter.everyGroupedPhoto, !filter.expandedStacks.contains(id), let members = groupMembers[id], members.count > 1 else { return nil }
        return members
    }
    /// The photos with each folded group's cover followed by the group's other photos: what selecting or right-clicking
    /// a folded group applies to.
    func withGroups(_ photos: [CatalogAsset]) -> [CatalogAsset] {
        var seen: Set<String> = []
        return photos.flatMap { foldedMembers(of: $0.id) ?? [$0] }.filter { seen.insert($0.id).inserted }
    }
    func canGroup(_ targets: [CatalogAsset]) -> Bool {
        // Groups are kept by the catalog alone; a folder has nowhere to keep them.
        !isFolderIndex && targets.count > 1 && targets.allSatisfy { $0.inLibrary } && Set(targets.map { $0.stackID ?? $0.id }).count > 1
    }
    func canUngroup(_ targets: [CatalogAsset]) -> Bool { targets.contains { $0.stackID != nil && $0.inLibrary } }
    /// Folds the photos into one group shown as its earliest photo, which stays selected.
    func group(_ targets: [CatalogAsset]) async {
        guard canGroup(targets), let store, !catalogBusy, await flushMetadata(), self.store === store else { return }
        let ids = targets.map(\.id)
        do {
            let before = try await store.stackState(ids)
            guard let cover = try await store.stack(ids) else { return }
            let after = try await store.stackState([cover])
            registerUndo(L10n.tr("Group Photos"), undo: { try await $0.restoreStacks(before) }, redo: { try await $0.restoreStacks(after) })
            filter.expandedStacks.subtract(Set(before.values.compactMap { $0 }))
            await refresh()
            if let asset = assets.first(where: { $0.id == cover }) { select(asset) }
            syncSoon(); notice = L10n.tr("Grouped \(after.count) photos")
        } catch { self.error = error.localizedDescription }
    }
    /// Takes apart the groups the photos are in; their photos show one by one again.
    func ungroup(_ targets: [CatalogAsset]) async {
        guard canUngroup(targets), let store, !catalogBusy, await flushMetadata(), self.store === store else { return }
        let ids = targets.map(\.id)
        do {
            let before = try await store.stackState(ids)
            try await store.unstack(ids)
            registerUndo(L10n.tr("Ungroup Photos"), undo: { try await $0.restoreStacks(before) }, redo: { try await $0.unstack(ids) })
            filter.expandedStacks.subtract(Set(before.values.compactMap { $0 }))
            await refresh(); syncSoon()
        } catch { self.error = error.localizedDescription }
    }
    /// Shows the group's photos one by one, all of them selected, or folds them back into the cover, which is then
    /// selected.
    func toggleGroup(_ asset: CatalogAsset) {
        guard let stackID = asset.stackID else { return }
        if filter.expandedStacks.contains(stackID) {
            filter.expandedStacks.remove(stackID)
            if let cover = assets.first(where: { $0.id == stackID }) { select(cover) }
        } else {
            let members = groupMembers[stackID] ?? []
            filter.expandedStacks.insert(stackID)
            if showingLibrary, let cover = members.first(where: { $0.id == stackID }) { selectExpandedGroup(members, cover: cover) }
        }
    }
}

/// The count and toggle on the first displayed group photo; other expanded members carry a plain mark.
struct GroupBadge: View {
    let count: Int?
    let expanded: Bool
    var toggle: (() -> Void)? = nil
    var body: some View {
        let label = HStack(spacing: 3) {
            Image(systemName: expanded ? "square.stack.3d.down.right" : "square.stack.3d.down.right.fill")
            if let count { Text(count.formatted()).monospacedDigit() }
        }
        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(.black.opacity(0.55), in: Capsule()).environment(\.colorScheme, .dark)
        .padding(5)
        if let toggle {
            Button(action: toggle) { label }.buttonStyle(.plain)
                .help(expanded ? L10n.tr("Collapse Group") : L10n.tr("Expand Group"))
                .accessibilityLabel(expanded ? L10n.tr("Collapse Group") : L10n.tr("Expand Group"))
        } else {
            label.accessibilityHidden(true)
        }
    }
}

extension CatalogModel {
    /// Keep the toggle on the first displayed member when expanded, even when the cover sorts last.
    /// The collapsed cover and the expanded group's leading cell then share the same toggle position.
    func groupBadge(for asset: CatalogAsset) -> GroupBadge? {
        if groupExpanded(asset) {
            guard let stackID = asset.stackID else { return nil }
            let displayed = showingLibrary || browsingAssets.isEmpty ? assets : browsingAssets
            let first = displayed.first { $0.stackID == stackID }
            if first?.id == asset.id {
                return GroupBadge(count: stackSizes[stackID], expanded: true) { [weak self] in self?.toggleGroup(asset) }
            }
            return GroupBadge(count: nil, expanded: true)
        }
        if let count = groupSize(of: asset) {
            return GroupBadge(count: count, expanded: false) { [weak self] in self?.toggleGroup(asset) }
        }
        return nil
    }
}

extension View {
    func groupBadge(_ badge: GroupBadge?) -> some View {
        overlay(alignment: .bottomTrailing) { if let badge { badge } }
    }
}
