import SwiftUI
import CevicheCore

/// One menu for a photo wherever it appears (grid, filmstrip, map, inspector, the photo in Detail). What is used all
/// day sits at the top level; the tools, merges and culling passes the Tools menu lists in full fold into submenus.
/// Actions apply to the whole selection when the clicked photo is part of it.
struct PhotoContextMenu: View {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var editor: EditorModel
    let asset: CatalogAsset
    var body: some View {
        let targets = catalog.contextAssets(for: asset)
        let single = targets.count == 1
        if asset.isLatent, asset.inLibrary {
            Button(L10n.tr("Open")) { catalog.openLatent(asset) }
            Button(L10n.tr("Move to Trash")) { catalog.requestMoveToTrash([asset], editor: editor) }
        } else if asset.inLibrary {
            // Not for the photo Develop already shows.
            if single, catalog.showingLibrary || catalog.openAsset(editor: editor)?.id != asset.id {
                Button(L10n.tr("Develop")) { catalog.develop(asset, editor: editor) }
                Divider()
            }
            if !catalog.isFolderIndex {
                Menu(L10n.tr("Rating")) {
                    ForEach(0...5, id: \.self) { rating in
                        Button(rating == 0 ? L10n.tr("None") : String(repeating: "★", count: rating)) { Task { await catalog.setQuickMetadata(targets, rating: rating) } }
                    }
                }
                Menu(L10n.tr("Flag")) {
                    Button(L10n.tr("Pick")) { Task { await catalog.setQuickMetadata(targets, review: .accepted) } }
                    Button(L10n.tr("Reject")) { Task { await catalog.setQuickMetadata(targets, review: .rejected) } }
                    Button(L10n.tr("Unflagged")) { Task { await catalog.setQuickMetadata(targets, review: .unreviewed) } }
                }
                Menu(L10n.tr("Label")) { LabelMenuItems(catalog: catalog, targets: targets) }
                Menu(L10n.tr("Add to Album")) {
                    Button(L10n.tr("New Album…")) { catalog.requestAlbum(photos: targets) }
                    if !catalog.albums.isEmpty { Divider() }
                    ForEach(catalog.albums) { summary in
                        Button(summary.album.name) { Task { await catalog.addToAlbum(summary.id, photos: targets) } }
                    }
                }
            }
            if let albumID = catalog.filter.albumID {
                Button(L10n.tr("Remove from Album")) { Task { await catalog.removeFromAlbum(albumID, photos: targets) } }
            }
            groupItems(targets)
            Divider()
            // Copy and paste stay at hand; the rarer ways to move edits fold away.
            if single { Button(L10n.tr("Copy Edits")) { Task { await catalog.copyEdits(from: asset, editor: editor) } } }
            Button(single ? L10n.tr("Paste Edits") : L10n.tr("Paste Edits to \(targets.count) Photos")) { Task { await catalog.pasteEdits(to: targets, editor: editor) } }
                .disabled(editor.copiedEdits == nil)
            Menu(L10n.tr("Edits")) {
                if single {
                    Button(L10n.tr("Copy Changed Edits")) { Task { await catalog.copyEdits(from: asset, editor: editor, .edited) } }
                    Button(L10n.tr("Copy Selected Edits…")) { Task { await catalog.copyEdits(from: asset, editor: editor, .choosing) } }
                } else {
                    Button(L10n.tr("Sync Edits from \(asset.filename)…")) { catalog.requestSyncEdits(from: asset, editor: editor) }
                        .disabled(!catalog.canSyncEdits(editor: editor))
                    Button(L10n.tr("Match Series to \(asset.filename)…")) { catalog.requestMatchSeries(targets, reference: asset) }.disabled(!catalog.canMatchSeries(targets))
                    Button(L10n.tr("Timelapse Deflicker…")) { catalog.requestExposureRamp(targets, reference: asset) }.disabled(!catalog.canBalanceExposure(targets))
                }
                Divider()
                Button(single ? L10n.tr("Reset Edits…") : L10n.tr("Reset Edits on \(targets.count) Photos…")) { catalog.requestResetEdits(targets) }
            }
            Divider()
            // What is reached for most stays at hand; the occasional tools fold away, the least used last.
            Button(L10n.tr("Creative Filters…")) { catalog.requestFilters(targets) }.disabled(!catalog.canApplyFilters(targets))
            Button(L10n.tr("AI Noise Reduction…")) { catalog.requestDenoise(targets) }.disabled(!catalog.canDenoise(targets) || catalog.denoise != nil)
            Button(L10n.tr("ID Photo…")) { catalog.requestIDPhoto(targets, editor: editor) }.disabled(!catalog.canMakeIDPhoto(targets) || catalog.idPhoto != nil)
            Menu(L10n.tr("More Tools")) {
                Button(L10n.tr("Wide-Angle Faces…")) { catalog.requestWideAngle(targets) }.disabled(!catalog.canCorrectWideAngle(targets) || catalog.wideAngle != nil)
                Button(L10n.tr("Convert Negative…")) { catalog.requestNegative(targets) }.disabled(!catalog.canConvertNegative(targets) || catalog.negative != nil)
                Button(L10n.tr("Chart Profile…")) { catalog.requestChartProfile(targets) }.disabled(!catalog.canMakeChartProfile(targets))
                // A set in one file has no selection to reach the Merge menu with.
                if single, let asset = targets.first, CatalogModel.holdsShotSet(asset) {
                    Button(L10n.tr("Merge Pixel Shift…")) { catalog.requestPixelShift(targets) }.disabled(!catalog.canPixelShift(targets))
                }
                if single {
                    Button(catalog.viewMode == .detail && editor.proof.on ? L10n.tr("Hide Print Proof") : L10n.tr("Print Proof")) { catalog.togglePrintProof(targets, editor: editor) }.disabled(!catalog.canPrintProof(targets, editor: editor))
                }
            }
            // Culling passes compare photos: they are for a selection. A folder has no archive or flags for them.
            if !single, !catalog.isFolderIndex {
                Menu(L10n.tr("Culling")) {
                    Button(L10n.tr("Pick from Bursts…")) { Task { await catalog.requestCullingAssistant(targets) } }
                    Button(L10n.tr("Find Flawed Photos…")) { Task { await catalog.requestProblemPhotos(targets) } }
                    Button(L10n.tr("Check Faces…")) { Task { await catalog.requestFaceCheck(targets) } }
                    Button(L10n.tr("Tidy RAW + JPEG Pairs…")) { Task { await catalog.requestTidyPairs(targets) } }
                }.disabled(!catalog.canCull(targets))
            }
            if !single {
                // New photos made from the selection.
                Menu(L10n.tr("Merge")) {
                    Button(L10n.tr("Merge to Panorama…")) { catalog.requestPanoramaMerge(targets) }.disabled(!catalog.canMergePanorama(targets))
                    Button(L10n.tr("Merge to HDR…")) { catalog.requestHDRMerge(targets) }.disabled(!catalog.canMergeHDR(targets))
                    Divider()
                    Button(L10n.tr("Focus Stack…")) { catalog.requestFocusStack(targets) }.disabled(!catalog.canFocusStack(targets))
                    Button(L10n.tr("Merge Pixel Shift…")) { catalog.requestPixelShift(targets) }.disabled(!catalog.canPixelShift(targets))
                    Button(L10n.tr("Merge Best Faces…")) { catalog.requestBestFaces(targets) }.disabled(!catalog.canMergeBestFaces(targets))
                    // The stacks and night-sky merges in line: a submenu here would be a third level.
                    Section(L10n.tr("Stack")) {
                        ForEach(PhotoStackMode.menuItems) { mode in
                            Button(mode.menuTitle!) { catalog.requestStack(targets, mode: mode) }.disabled(!catalog.canStack(targets))
                        }
                    }
                    Section(L10n.tr("Night Sky")) {
                        ForEach([NightSkyTool.starTrails, .denoise, .meteorShower]) { tool in
                            Button(tool.menuTitle) { catalog.requestNightSky(tool, targets) }.disabled(!catalog.canUseNightSky(tool, targets))
                        }
                    }
                    Divider()
                    Button(L10n.tr("Create Timelapse Video…")) { catalog.requestTimelapse(targets) }.disabled(!catalog.canCreateTimelapse(targets))
                    Button(L10n.tr("Create Live Photo…")) { catalog.requestLivePhoto(targets) }.disabled(!catalog.canCreateLivePhoto(targets))
                }
            }
            Divider()
            Button(single ? L10n.tr("Export…") : L10n.tr("Export \(targets.count) Photos…")) { catalog.requestExport(targets) }
            Menu(L10n.tr("Edit In")) { EditInItems { catalog.editIn(targets, app: $0, editor: editor) } }.disabled(!catalog.canStartJob)
            Menu(L10n.tr("XMP")) {
                Button(single ? L10n.tr("Export Original with XMP…") : L10n.tr("Export \(targets.count) Originals with XMP…")) { catalog.exportOriginals(targets) }
                // A folder's photo reads the sidecar beside it by itself; there is no separate XMP to bring in or send out.
                if single && catalog.selected?.id == asset.id && !catalog.isFolderIndex {
                    Divider()
                    Button(L10n.tr("Import XMP…"), action: catalog.chooseXMPImport)
                    Button(L10n.tr("Export XMP…"), action: catalog.chooseXMPExport)
                }
                if catalog.canStripXMP(targets, editor: editor) {
                    Divider()
                    Button(L10n.tr("Strip Unsupported Settings")) { Task { await catalog.stripUnsupportedXMP(targets, editor: editor) } }
                }
            }
        } else if asset.area == .trash {
            Button(single ? L10n.tr("Recover") : L10n.tr("Recover \(targets.count) Photos")) { Task { await catalog.recoverFromTrash(targets) } }
        }
        Divider()
        if !catalog.showingLibrary {
            Picker(L10n.tr("Filmstrip Style"), selection: $editor.filmstripStyle) {
                Text(L10n.tr("Photo")).tag(EditorModel.FilmstripStyle.photo)
                Text(L10n.tr("Square")).tag(EditorModel.FilmstripStyle.square)
            }
            Divider()
        }
        if asset.inLibrary && !catalog.isFolderIndex {
            Button(single ? L10n.tr("Duplicate") : L10n.tr("Duplicate \(targets.count) Photos")) { Task { await catalog.duplicate(targets, editor: editor) } }
                .disabled(!catalog.canDuplicate(targets))
        }
        if asset.area == .archive {
            Button(L10n.tr("Unarchive")) { Task { await catalog.unarchive(targets) } }
            Button(L10n.tr("Move to Folder…")) { catalog.requestMoveToFolder(targets) }
            Button(L10n.tr("Copy to Folder…")) { catalog.exportOriginals(targets) }
            Divider()
        }
        if single, catalog.canShowSimilar(targets) {
            Button(L10n.tr("Show Similar Photos")) { Task { await catalog.showSimilar(to: asset, editor: editor) } }
        }
        if single, catalog.canShowNearby(targets) {
            Button(L10n.tr("Show Nearby Photos")) { Task { await catalog.showNearby(asset, editor: editor) } }
        }
        Button(L10n.tr("Show in Finder")) { catalog.showInFinder(targets) }
        if single && asset.inLibrary && catalog.selected?.id == asset.id && !catalog.isFolderIndex {
            Button(L10n.tr("Locate Original…"), action: catalog.relink)
            if catalog.availability[asset.id]?.isOffline == true { Button(L10n.tr("Replace Original…"), action: catalog.replaceOriginal) }
        }
        if asset.area != .trash {
            Divider()
            Button(single ? L10n.tr("Move to Trash") : L10n.tr("Move \(targets.count) Photos to Trash")) { Task { await catalog.moveToTrash(targets, editor: editor) } }
        }
        // A folder's photos are files: there is no library to remove them from, only the Trash.
        if !catalog.isFolderIndex {
            Divider()
            Button(single ? L10n.tr("Remove from Library…") : L10n.tr("Remove \(targets.count) Photos from Library…"), role: .destructive) {
                Task { await catalog.requestPermanentDeletion(targets, editor: editor) }
            }
        }
    }
}

extension PhotoContextMenu {
    /// Group, expand or fold, and take apart; expanding is where a folded group is opened from.
    @ViewBuilder func groupItems(_ targets: [CatalogAsset]) -> some View {
        if asset.stackID != nil, catalog.groupSize(of: asset) != nil || catalog.groupExpanded(asset) {
            Button(catalog.groupExpanded(asset) ? L10n.tr("Collapse Group") : L10n.tr("Expand Group")) { catalog.toggleGroup(asset) }
        }
        if catalog.canGroup(targets) {
            Button(L10n.tr("Group \(targets.count) Photos")) { Task { await catalog.group(targets) } }
        }
        if catalog.canUngroup(targets) {
            Button(L10n.tr("Ungroup")) { Task { await catalog.ungroup(targets) } }
        }
    }
}

extension View {
    /// The photo menu on the photo open in Detail, so it is reachable where people right-click, even with the filmstrip
    /// hidden.
    func openPhotoContextMenu(catalog: CatalogModel, editor: EditorModel) -> some View {
        contextMenu {
            if let asset = catalog.openAsset(editor: editor) { PhotoContextMenu(catalog: catalog, editor: editor, asset: asset) }
        }
    }
}
