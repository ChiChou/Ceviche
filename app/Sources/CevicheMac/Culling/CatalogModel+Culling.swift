import AppKit
import CevicheCore

/// What an import does with the two files of a RAW + JPEG (or RAW + HEIF) shot.
enum RawJPEGImport: String, CaseIterable, Identifiable {
    /// Both files; `CatalogModel.groupRawJPEGPairsOnImport` decides whether they become one group under the RAW.
    case both
    case rawOnly
    case processedOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .both: return L10n.tr("Both")
        case .rawOnly: return L10n.tr("RAW Only")
        case .processedOnly: return L10n.tr("JPEG or HEIF Only")
        }
    }
    /// The files to import: one half of each pair is dropped unless both are kept.
    func keep(_ items: [CatalogModel.ImportItem]) -> [CatalogModel.ImportItem] {
        guard self != .both else { return items }
        let pairs = RawJPEGPairs.pairs(items) { $0.pairingPath }
        let dropped = Set(pairs.map { self == .rawOnly ? $0.processed : $0.raw })
        return items.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
    }
}

struct CullingAssistantRequest: Identifiable {
    let id = UUID()
    /// In capture order.
    let assets: [CatalogAsset]
    /// What the photos are: the collection's name, or the selection.
    let title: String
    /// For each RAW + JPEG pair, the JPEG that stands for the shot in `assets` and the RAW behind it: the tools measure
    /// and show the JPEG, and their flags apply to both.
    var partners: [String: String] = [:]
    /// The photos are one group the person made: Pick from Bursts takes them as one burst to pick a photo from, without
    /// looking for bursts.
    var oneGroup = false
    /// The group of every photo in scope that is in one, the RAWs behind `partners` included.
    var stacks: [String: String] = [:]
}

extension CatalogModel {
    func canCull(_ targets: [CatalogAsset]) -> Bool {
        // The tools that take over the window come one at a time.
        // Culling leaves flags and ratings, which a browsed folder does not have.
        !isFolderIndex && store != nil && canStartJob && filter.area == .library && (targets.count > 1 || matchingCount > 0) && cullingAssistant == nil && problemPhotos == nil && tidyPairs == nil && faceCheck == nil
            && cardImport == nil && panoramaMerge == nil && hdrMerge == nil && photoStack == nil && pixelShift == nil && bestFaces == nil && matchSeries == nil && nightSky == nil && focusStack == nil
    }
    /// Opens Pick from Bursts on the shots `cullingScope` gives.
    func requestCullingAssistant(_ targets: [CatalogAsset]) async {
        guard let request = await cullingScope(targets) else { return }
        cullingAssistant = request.shots()
    }
    /// Opens Find Flawed Photos on the shots `cullingScope` gives.
    func requestProblemPhotos(_ targets: [CatalogAsset]) async {
        guard let request = await cullingScope(targets) else { return }
        problemPhotos = request.shots()
    }
    /// Opens Check Faces on the shots `cullingScope` gives.
    func requestFaceCheck(_ targets: [CatalogAsset]) async {
        guard let request = await cullingScope(targets) else { return }
        faceCheck = request.shots()
    }
    /// Opens Tidy RAW + JPEG Pairs on the photos `cullingScope` gives, or says there are no pairs among them.
    func requestTidyPairs(_ targets: [CatalogAsset]) async {
        guard let request = await cullingScope(targets) else { return }
        guard !RawJPEGPairs.pairs(request.assets).isEmpty else { notice = L10n.tr("No RAW + JPEG pairs in \(request.title)"); return }
        tidyPairs = request
    }
    /// Puts each RAW + JPEG pair among `cullingScope`'s photos in a group of its own under the RAW, so the library shows
    /// one tile per shot, in one undoable step. Flags and files stay as they are.
    func groupRawJPEGPairs(_ targets: [CatalogAsset]) async {
        guard let request = await cullingScope(targets), let store else { return }
        let pairs = RawJPEGPairs.pairs(request.assets).filter { $0.raw.stackID == nil || $0.raw.stackID != $0.processed.stackID }
        guard !pairs.isEmpty else {
            notice = RawJPEGPairs.pairs(request.assets).isEmpty ? L10n.tr("No RAW + JPEG pairs in \(request.title)")
                : L10n.tr("Every RAW + JPEG pair in \(request.title) is already grouped")
            return
        }
        let ids = pairs.flatMap { [$0.raw.id, $0.processed.id] }
        do {
            let before = try await store.stackState(ids)
            for pair in pairs { try await store.stack([pair.raw.id, pair.processed.id], cover: pair.raw.id) }
            let after = try await store.stackState(ids)
            registerUndo(L10n.tr("Group Photos"), undo: { try await $0.restoreStacks(before) }, redo: { try await $0.restoreStacks(after) })
            syncSoon()
            notice = pairs.count == 1 ? L10n.tr("1 RAW + JPEG pair grouped") : L10n.tr("\(pairs.count.formatted()) RAW + JPEG pairs grouped")
        } catch { self.error = error.localizedDescription }
        await refresh()
    }
    /// Takes apart the groups among `cullingScope`'s photos that hold just a RAW + JPEG pair, so both files show on
    /// their own, in one undoable step. A pair inside a larger group the person made stays in it.
    func ungroupRawJPEGPairs(_ targets: [CatalogAsset]) async {
        guard let request = await cullingScope(targets), let store else { return }
        do {
            let sizes = try await store.stackSizes()
            let pairs = RawJPEGPairs.pairs(request.assets).filter {
                guard let group = $0.raw.stackID, group == $0.processed.stackID else { return false }
                return sizes[group] == 2
            }
            guard !pairs.isEmpty else { notice = L10n.tr("No grouped RAW + JPEG pairs in \(request.title)"); return }
            let ids = pairs.flatMap { [$0.raw.id, $0.processed.id] }
            let before = try await store.stackState(ids)
            let after = Dictionary(uniqueKeysWithValues: ids.map { ($0, String?.none) })
            try await store.restoreStacks(after)
            registerUndo(L10n.tr("Ungroup"), undo: { try await $0.restoreStacks(before) }, redo: { try await $0.restoreStacks(after) })
            syncSoon()
            notice = pairs.count == 1 ? L10n.tr("1 RAW + JPEG pair ungrouped") : L10n.tr("\(pairs.count.formatted()) RAW + JPEG pairs ungrouped")
        } catch { self.error = error.localizedDescription }
        await refresh()
    }
    /// Asks before moving the rejected photos among `cullingScope`'s to the Trash, both files of a RAW + JPEG shot
    /// included; nothing leaves the disk.
    func requestTrashRejected(_ targets: [CatalogAsset]) async {
        guard let request = await cullingScope(targets) else { return }
        let rejected = request.assets.filter { $0.review == .rejected }
        guard !rejected.isEmpty else { notice = L10n.tr("No rejected photos in \(request.title)"); return }
        pendingTrash = rejected
    }
    /// Asks before moving the photos among `cullingScope`'s whose original is gone to the Trash. Only a file missing
    /// from storage this Mac can reach counts: a disconnected drive or share, or a copy on another Mac, does not.
    func requestTrashMissing(_ targets: [CatalogAsset]) async {
        guard let request = await cullingScope(targets) else { return }
        let root = self.root, photos = request.assets
        let missing = await Task.detached(priority: .userInitiated) { photos.filter { $0.originalIsMissing(catalog: root) } }.value
        guard !missing.isEmpty else { notice = L10n.tr("No missing photos in \(request.title)"); return }
        pendingTrash = missing
    }
    /// Most photos a culling tool takes at once. Measuring reads the camera previews: 4,834 shots of a library on a
    /// network share took about four minutes, with memory set by the largest single file rather than the count; the
    /// burst plan for 10,000 takes 0.2 s.
    static let cullingLimit = 10_000
    private func refuseCulling(_ count: Int, title: String) {
        failure = Failure(L10n.tr("Too Many Photos to Cull"),
                          L10n.tr("\(title) has \(count.formatted()) photos. The culling tools take up to \(Self.cullingLimit.formatted()) at a time: select fewer, or choose a day, a folder or an album first."))
    }
    /// The selected photos, or with one or none selected every photo the library shows, grouped photos included. A
    /// folded group in `targets` already stands for every photo in it (`withGroups`), so a RAW + JPEG shot brings its
    /// JPEG along, and a group alone is the whole scope.
    private func cullingScope(_ targets: [CatalogAsset]) async -> CullingAssistantRequest? {
        guard canCull(targets), let store, await flushMetadata(), self.store === store else { return nil }
        var photos = targets.filter { $0.inLibrary }
        var title = L10n.tr("\(photos.count.formatted()) selected photos")
        let group = photos.first?.stackID
        let oneGroup = photos.count >= 2 && group != nil && photos.allSatisfy { $0.stackID == group }
        if oneGroup, let cover = photos.first(where: { $0.id == group }) ?? photos.first { title = L10n.tr("the \(cover.filename) group") }
        if photos.count < 2 {
            var scope = filter; scope.everyGroupedPhoto = true
            // The view as filtered: search and the rating and flag filters narrow it as they narrow the grid.
            title = filter.isRefined ? L10n.tr("\(collectionTitle), filtered") : collectionTitle
            do {
                let count = try await store.count(filter: scope)
                guard count <= Self.cullingLimit else { refuseCulling(count, title: title); return nil }
                photos = try await store.assets(filter: scope)
            } catch { self.error = error.localizedDescription; return nil }
        }
        guard !photos.isEmpty else { notice = L10n.tr("No photos to cull"); return nil }
        guard photos.count <= Self.cullingLimit else { refuseCulling(photos.count, title: title); return nil }
        var request = CullingAssistantRequest(assets: photos.sorted { ($0.captureTime ?? "", $0.filename) < ($1.captureTime ?? "", $1.filename) }, title: title)
        request.oneGroup = oneGroup
        request.stacks = Dictionary(photos.compactMap { photo in photo.stackID.map { (photo.id, $0) } }, uniquingKeysWith: { first, _ in first })
        return request
    }

    /// Sets the culling tools' flags, on both files of a RAW + JPEG shot (`partners`), and puts each of `groups` in a
    /// group under its cover, in one undoable step. Ratings, edits and files stay as they are.
    func applyCulling(_ flags: [String: ReviewState], partners: [String: String] = [:], groups: [(members: [String], cover: String)] = []) async {
        guard let store, !interactionBusy, await flushMetadata(), self.store === store else { return }
        var flags = flags
        for (shown, state) in flags { if let partner = partners[shown] { flags[partner] = state } }
        var previous: [String: CatalogMetadata] = [:]
        var grouped = 0
        let grouping = groups.flatMap(\.members)
        var stacksBefore: [String: String?] = [:], stacksAfter: [String: String?] = [:]
        // A step that fails is reported; the others still apply, and Undo covers what did.
        for state in [ReviewState.rejected, .accepted, .unreviewed] {
            let ids = flags.filter { $0.value == state }.map(\.key)
            guard !ids.isEmpty else { continue }
            do { previous.merge(try await store.updateQuickMetadata(assetIDs: ids, review: state)) { first, _ in first } }
            catch { self.error = error.localizedDescription }
        }
        if !grouping.isEmpty, let before = try? await store.stackState(grouping) {
            stacksBefore = before
            for group in groups {
                do { if try await store.stack(group.members, cover: group.cover) != nil { grouped += 1 } }
                catch { self.error = error.localizedDescription }
            }
            stacksAfter = (try? await store.stackState(grouping)) ?? [:]
        }
        if !previous.isEmpty || grouped > 0 {
            let applied = flags.filter { previous[$0.key] != nil }
            let (before, after) = (stacksBefore, stacksAfter)
            registerUndo(L10n.tr("Culling Assistant"), undo: { store in
                if !before.isEmpty { try await store.restoreStacks(before) }
                for (id, metadata) in previous { try await store.updateQuickMetadata(assetIDs: [id], review: metadata.review) }
            }, redo: { store in
                for (id, state) in applied { try await store.updateQuickMetadata(assetIDs: [id], review: state) }
                if !after.isEmpty { try await store.restoreStacks(after) }
            })
            syncSoon()
        }
        let rejected = flags.values.filter { $0 == .rejected }.count, picked = flags.values.filter { $0 == .accepted }.count
        let flagged = previous.isEmpty ? nil : L10n.tr("Flags changed on \(previous.count.formatted()) photos: \(rejected.formatted()) rejected, \(picked.formatted()) picked")
        let stacked = grouped == 0 ? nil : grouped == 1 ? L10n.tr("1 burst grouped") : L10n.tr("\(grouped.formatted()) bursts grouped")
        let said = [flagged, stacked].compactMap { $0 }
        notice = said.isEmpty ? L10n.tr("Nothing changed") : said.joined(separator: "; ")
        cullingAssistant = nil; problemPhotos = nil; tidyPairs = nil; faceCheck = nil
        await refresh()
        if selected != nil { await reloadSelection() }
    }
}

extension CullingAssistantRequest {
    /// The same photos with each RAW + JPEG pair as one shot, stood for by its JPEG.
    func shots() -> CullingAssistantRequest {
        let pairs = RawJPEGPairs.pairs(assets)
        guard !pairs.isEmpty else { return self }
        let hidden = Set(pairs.map(\.raw.id))
        var request = CullingAssistantRequest(assets: assets.filter { !hidden.contains($0.id) }, title: title)
        request.oneGroup = oneGroup; request.stacks = stacks
        request.partners = Dictionary(pairs.map { ($0.processed.id, $0.raw.id) }, uniquingKeysWith: { first, _ in first })
        return request
    }
}
