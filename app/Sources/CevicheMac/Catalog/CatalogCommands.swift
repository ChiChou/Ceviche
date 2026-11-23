import SwiftUI
import Combine
import CevicheCore

/// The menu bar. Every Library action lives here with its shortcut; buttons and context menus mirror it.
struct CatalogCommands: Commands {
    /// Not observed: an import or background analysis changes it several times a second. The menus follow `catalogMenu`.
    let catalog: CatalogModel
    @ObservedObject var catalogMenu: CatalogMenuState
    /// Not observed: the editor changes many times a second while a slider moves. The menus follow `editorMenu`.
    let editor: EditorModel
    @ObservedObject var editorMenu: EditorMenuState
    @ObservedObject var textEditing: TextEditingObserver
    @ObservedObject var keyWindow: KeyWindowObserver
    @AppStorage(LanguageChoice.key) private var language = LanguageChoice.system.rawValue
    @AppStorage(AppearanceChoice.key) private var appearance = AppearanceChoice.dark.rawValue
    @Environment(\.openWindow) private var openWindow

    private var targets: [CatalogAsset] { catalog.cullingTargets(editor: editor) }
    private var inLibrary: Bool { catalog.showingLibrary }
    private var single: CatalogAsset? { targets.count == 1 ? targets[0] : nil }
    /// The welcome screen: the Library's views, sorting and collections have nothing to act on.
    private var noCatalog: Bool { catalog.store == nil }
    private var canPrint: Bool {
        guard keyWindow.mainWindowIsKey, !editor.showExport, catalog.exportSession == nil,
              !catalog.activity.contains(.exporting) else { return false }
        if catalog.toolOpen { return catalog.filters != nil && catalog.filtersCanPrint }
        if inLibrary { return !targets.isEmpty && targets.allSatisfy(\.inLibrary) && catalog.canStartJob }
        return editor.hasImage && !editor.busy
    }
    private func printPhotos() {
        guard canPrint else { return }
        if catalog.toolOpen { catalog.filtersPrint &+= 1 }
        else if inLibrary { catalog.printPhotos(targets) }
        else { editor.printPhoto() }
    }

    var body: some Commands {
        CommandGroup(replacing: .help) { // No user guide, so no standard Help item.
            Button(L10n.tr("System Info…")) { openWindow(id: SystemInfoView.windowID) }
            Button(L10n.tr("Open Source Licenses…")) { openWindow(id: LicensesView.windowID) }
        }
        CommandGroup(after: .appSettings) {
            ProMenuItems(openWindow: openWindow)
            Menu(L10n.tr("Appearance")) {
                ForEach(AppearanceChoice.allCases) { choice in
                    Toggle(choice.name, isOn: Binding(
                        get: { appearance == choice.rawValue },
                        set: { _ in appearance = choice.rawValue }
                    ))
                }
            }
            Menu(L10n.tr("Language")) {
                ForEach(LanguageChoice.allCases) { choice in
                    Toggle(choice.displayName, isOn: Binding(
                        get: { language == choice.rawValue },
                        set: { _ in LanguageChoice.current = choice }
                    ))
                }
            }
        }
        CommandGroup(replacing: .newItem) {
            Button(L10n.tr("New Catalog…")) { catalog.chooseCatalog(create: true) }.keyboardShortcut("n", modifiers: [.command, .option]).disabled(catalog.catalogWideBusy)
            if BuildFeatures.iCloud { Button(L10n.tr("New iCloud Catalog…")) { catalog.showingNewCloudCatalog = true }.disabled(catalog.catalogWideBusy) }
            Button(L10n.tr("Open Catalog…")) { catalog.chooseCatalog(create: false) }.keyboardShortcut("o", modifiers: [.command, .option]).disabled(catalog.catalogWideBusy)
            Menu(L10n.tr("Catalogs")) {
                ForEach(catalog.recentCatalogs()) { reference in
                    Toggle(isOn: Binding(get: { catalog.manifest?.id == reference.id }, set: { _ in
                        guard catalog.manifest?.id != reference.id else { return }
                        Task { await catalog.openCatalog(reference.url) }
                    })) {
                        Label(reference.name, systemImage: reference.kind == .cloud ? "icloud" : "folder")
                    }
                }
            }.disabled(catalog.catalogWideBusy || catalog.recentCatalogs().isEmpty)
            if BuildFeatures.iCloud {
                Button(L10n.tr("Manage iCloud Catalogs…")) { catalog.showingCloudCatalogs = true }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(catalog.catalogWideBusy)
                Menu(L10n.tr("iCloud Catalogs")) {
                    ForEach(catalog.cloudCatalogs) { listing in
                        Toggle(isOn: Binding(get: { catalog.manifest?.id == listing.id }, set: { _ in
                            guard catalog.manifest?.id != listing.id else { return }
                            catalog.openCloudCatalog(listing)
                        })) {
                            Label(listing.name, systemImage: "icloud")
                        }
                    }
                    if catalog.cloudCatalogs.isEmpty, catalog.lookingForCloudCatalogs { Button(L10n.tr("Looking in iCloud…")) {}.disabled(true) }
                }.disabled(catalog.catalogWideBusy)
            }
            Divider()
            Button(L10n.tr("Import Photos…"), action: catalog.chooseImport).keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(catalog.store == nil || !catalog.canStartJob)
            CardImportItems(catalog: catalog).disabled(catalog.store == nil || !catalog.canStartJob)
            if catalog.importing { Button(L10n.tr("Stop Import"), action: catalog.cancelImport).keyboardShortcut(".", modifiers: .command) }
            if catalog.activity.contains(.exporting) { Button(L10n.tr("Stop Export")) { catalog.activity.cancelAll(.exporting) } }
        }
        CommandGroup(replacing: .saveItem) {
            Button(L10n.tr("Save")) { Task { await editor.save() } }.keyboardShortcut("s").disabled(!editor.hasImage || editor.busy)
            if inLibrary {
                Button(targets.count > 1 ? L10n.tr("Export \(targets.count) Photos…") : L10n.tr("Export…")) { catalog.requestExport(targets) }.keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(targets.isEmpty || catalog.filter.area != .library || !catalog.canStartJob)
                Menu(L10n.tr("Export Using Preset")) { ExportPresetItems(export: { catalog.export(targets, preset: $0) }, share: { catalog.share(targets) }) }
                    .disabled(targets.isEmpty || catalog.filter.area != .library || !catalog.canStartJob)
                Button(targets.count > 1 ? L10n.tr("Export \(targets.count) Originals with XMP…") : L10n.tr("Export Original with XMP…")) { catalog.exportOriginals(targets) }
                    .disabled(targets.isEmpty || catalog.filter.area != .library || !catalog.canStartJob)
                EditInMenu { catalog.editIn(targets, app: $0, editor: editor) }
                    .disabled(targets.isEmpty || catalog.filter.area != .library || !catalog.canStartJob)
            } else {
                Button(L10n.tr("Export…")) { editor.prepareExport() }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!editor.hasImage || editor.busy)
                Menu(L10n.tr("Export Using Preset")) { ExportPresetItems(export: { editor.export(preset: $0) }, share: editor.share) }.disabled(!editor.hasImage || editor.busy)
                EditInMenu { catalog.editInOpenPhoto(app: $0, editor: editor) }.disabled(!editor.hasImage || editor.busy)
            }
            Divider()
            // Closing the main window would leave the app running with nothing on screen, so the item is for the second
            // window and Settings; Close Catalog and Quit cover the main one.
            if !keyWindow.mainWindowIsKey { Button(L10n.tr("Close Window")) { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w") }
            Button(catalog.hasLibrary ? L10n.tr("Close Catalog") : L10n.tr("Close Folders")) { Task { await catalog.closeCatalog(editor: editor) } }
                .disabled(catalog.store == nil || catalog.catalogWideBusy || editor.busy)
            if !catalog.isFolderIndex {
                Divider()
                Button(L10n.tr("Catalog Info")) { catalog.showCatalogOverview(editor: editor) }.disabled(catalog.store == nil || catalog.isFolderIndex)
                Button(L10n.tr("Back Up Catalog…"), action: catalog.backup).disabled(catalog.store == nil || catalog.catalogWideBusy || catalog.isFolderIndex)
                Button(L10n.tr("Back Up Catalog with Originals…"), action: catalog.backupWithOriginals).disabled(catalog.store == nil || catalog.catalogWideBusy || catalog.isFolderIndex)
                if BuildFeatures.iCloud, catalog.manifest?.kind == .cloud { Button(L10n.tr("Sync with iCloud Now"), action: catalog.syncNow).disabled(catalog.store == nil) }
                Button(L10n.tr("Show Catalog in Finder")) { if let root = catalog.root { NSWorkspace.shared.showInFinder([root]) } }.disabled(catalog.root == nil || catalog.isFolderIndex)
            }
        }
        CommandGroup(replacing: .printItem) {
            Button(L10n.tr("Print…"), action: printPhotos).keyboardShortcut("p").disabled(!canPrint)
        }
        CommandGroup(replacing: .undoRedo) {
            // Text fields keep their own typing undo; otherwise Library and Develop have separate histories.
            if textEditing.editing {
                Button(L10n.tr("Undo")) { TextEditingObserver.send(undo: true) }.keyboardShortcut("z")
                Button(L10n.tr("Redo")) { TextEditingObserver.send(undo: false) }.keyboardShortcut("z", modifiers: [.command, .shift])
            } else if catalog.nightSky != nil {
                // A night-sky tool fills the window: its retouching, not the hidden Library's history.
                if let history = catalog.nightSkyHistory { NightSkyUndoCommands(history: history) } else {
                    Button(L10n.tr("Undo")) {}.keyboardShortcut("z").disabled(true)
                    Button(L10n.tr("Redo")) {}.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(true)
                }
            } else if catalog.hdrMerge != nil {
                if let history = catalog.hdrMergeHistory { BrushUndoCommands(history: history) } else {
                    Button(L10n.tr("Undo")) {}.keyboardShortcut("z").disabled(true)
                    Button(L10n.tr("Redo")) {}.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(true)
                }
            } else if catalog.photoStack != nil {
                if let history = catalog.photoStackHistory { BrushUndoCommands(history: history) } else {
                    Button(L10n.tr("Undo")) {}.keyboardShortcut("z").disabled(true)
                    Button(L10n.tr("Redo")) {}.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(true)
                }
            } else if catalog.focusStack != nil {
                if let history = catalog.focusStackHistory { BrushUndoCommands(history: history) } else {
                    Button(L10n.tr("Undo")) {}.keyboardShortcut("z").disabled(true)
                    Button(L10n.tr("Redo")) {}.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(true)
                }
            } else if let model = catalog.negativeHistory {
                NegativeUndoCommands(model: model)
            } else if inLibrary {
                Button(catalog.undoTitle, action: catalog.undo).keyboardShortcut("z").disabled(!catalog.canUndo)
                Button(catalog.redoTitle, action: catalog.redo).keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!catalog.canRedo)
            } else {
                Button(L10n.tr("Undo"), action: editor.undo).keyboardShortcut("z").disabled(editor.undoStack.isEmpty || editor.busy)
                Button(L10n.tr("Redo"), action: editor.redo).keyboardShortcut("z", modifiers: [.command, .shift]).disabled(editor.redoStack.isEmpty || editor.busy)
            }
        }
        CommandGroup(after: .pasteboard) {
            // In Develop it leaves the open photo selected, undoing ⌘A or ⌘-clicks in the filmstrip.
            Button(L10n.tr("Deselect All")) { if inLibrary { catalog.deselectAll() } else { catalog.deselectFilmstrip(editor: editor) } }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled((inLibrary ? catalog.selectedIDs.isEmpty : catalog.selectedIDs.count <= 1) || textEditing.editing)
        }
        CommandGroup(after: .textEditing) {
            Button(L10n.tr("Find Photos")) { catalog.focusSearch() }.keyboardShortcut("f").disabled(catalog.store == nil)
            Button(L10n.tr("Clear Filters"), action: catalog.clearFilters).keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(!catalog.filter.isRefined)
        }
        CommandGroup(before: .toolbar) {
            // Match the bottom bar from left to right: the overview, Wall, Grid, Compare, Detail.
            if let overview = catalog.collectionOverview {
                Toggle(overview.title, isOn: Binding(get: { catalog.shownOverview != nil }, set: { _ in catalog.showOverview(editor: editor) }))
                    .keyboardShortcut(.upArrow).disabled(catalog.interactionBusy || textEditing.editing)
                Divider()
            }
            photosToggle(.wall, key: "1")
            photosToggle(.tiles, key: "2")
            viewToggle(.compare, key: "3")
            viewToggle(.detail, key: "4")
            if catalog.viewMode == .compare {
                Divider()
                Picker(L10n.tr("Compare"), selection: Binding(get: { catalog.compareSource }, set: { catalog.compareSource = $0 })) { ForEach(CatalogModel.CompareSource.allCases) { Text($0.title).tag($0) } }
                Picker(L10n.tr("Orientation"), selection: Binding(get: { catalog.compareOrientation }, set: { catalog.compareOrientation = $0 })) { ForEach(CatalogModel.CompareOrientation.allCases) { Text($0.title).tag($0) } }
                Button(L10n.tr("Swap Sides")) { catalog.compareSwapped.toggle() }
            }
            Divider()
            if catalog.hasSecondaryDisplay {
                Menu(L10n.tr("Secondary Window")) { SecondaryWindowItems(catalog: catalog, editor: editor) }
            }
            Toggle(L10n.tr("Scopes"), isOn: Binding(get: { editor.scope != nil }, set: { _ in editor.toggleScope() }))
                .keyboardShortcut("k", modifiers: [.command, .option]).disabled(!editor.hasImage || inLibrary)
            Toggle(L10n.tr("Zones"), isOn: Binding(get: { editor.zonesShown }, set: { _ in editor.toggleZones() }))
                .keyboardShortcut("z", modifiers: [.command, .option]).disabled(!editor.hasImage || inLibrary)
            Divider()
        }
        CommandGroup(after: .toolbar) {
            if inLibrary { Menu(L10n.tr("Sort By")) { CatalogSortItems(model: catalog) }.disabled(noCatalog); Divider() }
            Button(catalog.showSidebar ? L10n.tr("Hide Sidebar") : L10n.tr("Show Sidebar")) { catalog.showSidebar.toggle() }.disabled(noCatalog)
                .keyboardShortcut("s", modifiers: [.command, .control])
            if !inLibrary {
                Button(editor.showFilmstrip ? L10n.tr("Hide Filmstrip") : L10n.tr("Show Filmstrip")) { editor.showFilmstrip.toggle() }
                    .keyboardShortcut("b", modifiers: [.command, .control]).disabled(catalog.shownAssetID(editor: editor) == nil)
                Button(editor.showCullingBar ? L10n.tr("Hide Culling Bar") : L10n.tr("Show Culling Bar")) { editor.showCullingBar.toggle() }.disabled(catalog.isFolderIndex)
                    .disabled(catalog.shownAssetID(editor: editor) == nil || !editor.showFilmstrip)
                Picker(L10n.tr("Filmstrip Style"), selection: Binding(get: { editor.filmstripStyle }, set: { editor.filmstripStyle = $0 })) {
                    Text(L10n.tr("Photo")).tag(EditorModel.FilmstripStyle.photo)
                    Text(L10n.tr("Square")).tag(EditorModel.FilmstripStyle.square)
                }.disabled(catalog.shownAssetID(editor: editor) == nil)
            }
            if inLibrary {
                Button(catalog.showInspector ? L10n.tr("Hide Inspector") : L10n.tr("Show Inspector")) { catalog.showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .control]).disabled(noCatalog)
            } else {
                Button(editor.showInspector ? L10n.tr("Hide Inspector") : L10n.tr("Show Inspector")) { editor.showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .control])
            }
            Divider()
            if inLibrary {
                Button(L10n.tr("Larger Thumbnails")) { catalog.stepTileSize(larger: true) }.keyboardShortcut("=", modifiers: .command)
                    .disabled(noCatalog || catalog.tileSize >= CatalogModel.tileSizes.upperBound)
                Button(L10n.tr("Smaller Thumbnails")) { catalog.stepTileSize(larger: false) }.keyboardShortcut("-", modifiers: .command)
                    .disabled(noCatalog || catalog.tileSize <= CatalogModel.tileSizes.lowerBound)
            } else {
                Button(L10n.tr("Zoom In"), action: editor.zoomImageIn).keyboardShortcut("=", modifiers: .command).disabled(!editor.hasImage)
                Button(L10n.tr("Zoom Out"), action: editor.zoomImageOut).keyboardShortcut("-", modifiers: .command).disabled(!editor.hasImage)
                Button(L10n.tr("Zoom to Fit")) { editor.viewport.fit() }.keyboardShortcut("0", modifiers: .command)
                    .disabled(!editor.hasImage || editor.viewport.isFitted)
            }
            Divider()
        }
        CommandMenu(L10n.tr("Photo")) {
            // A browsed folder is files: nothing of ratings, flags, groups, the catalog or its Trash is offered there.
            if !catalog.isFolderIndex {
                Menu(L10n.tr("Rating")) {
                    ForEach(0...5, id: \.self) { rating in
                        Toggle(rating == 0 ? L10n.tr("None") : String(repeating: "★", count: rating), isOn: Binding(
                            get: { !targets.isEmpty && targets.allSatisfy { $0.rating == rating } },
                            set: { _ in let targets = targets; Task { await catalog.setQuickMetadata(targets, rating: rating) } }))
                    }
                }.disabled(targets.isEmpty || catalog.interactionBusy || catalog.filter.area != .library && inLibrary || catalog.isFolderIndex)
                Menu(L10n.tr("Flag")) {
                    ForEach([(ReviewState.accepted, L10n.tr("Pick")), (.rejected, L10n.tr("Reject")), (.unreviewed, L10n.tr("Unflagged"))], id: \.0) { state, title in
                        Toggle(title, isOn: Binding(
                            get: { !targets.isEmpty && targets.allSatisfy { $0.review == state } },
                            set: { _ in let targets = targets; Task { await catalog.setQuickMetadata(targets, review: state) } }))
                    }
                }.disabled(targets.isEmpty || catalog.interactionBusy || catalog.filter.area != .library && inLibrary || catalog.isFolderIndex)
                Menu(L10n.tr("Label")) { LabelMenuItems(catalog: catalog, targets: targets) }
                    .disabled(targets.isEmpty || catalog.interactionBusy || catalog.filter.area != .library && inLibrary || catalog.isFolderIndex)
                Menu(L10n.tr("Add to Album")) {
                    Button(L10n.tr("New Album…")) { catalog.requestAlbum(photos: targets) }
                    if !catalog.albums.isEmpty { Divider() }
                    ForEach(catalog.albums) { summary in
                        Button(summary.album.name) { let targets = targets; Task { await catalog.addToAlbum(summary.id, photos: targets) } }
                    }
                }.disabled(targets.isEmpty || catalog.catalogBusy || !targets.allSatisfy(\.inLibrary))
                Divider()
            }
            // ⌘C and ⌘V are Edit › Copy and Paste, which reach the edits through AppDelegate when no text field takes them.
            Button(L10n.tr("Copy Edits")) { catalog.copyCurrentEdits(editor: editor) }
                .disabled(!catalog.canCopyEdits(editor: editor))
            Button(L10n.tr("Copy Changed Edits")) { catalog.copyCurrentEdits(editor: editor, .edited) }
                .keyboardShortcut("c", modifiers: [.command, .option]).disabled(!catalog.canCopyEdits(editor: editor))
            Button(L10n.tr("Copy Selected Edits…")) { catalog.copyCurrentEdits(editor: editor, .choosing) }
                .keyboardShortcut("c", modifiers: [.command, .shift]).disabled(!catalog.canCopyEdits(editor: editor))
            Button(inLibrary && targets.count > 1 ? L10n.tr("Paste Edits to \(targets.count) Photos") : L10n.tr("Paste Edits")) { catalog.pasteCopiedEdits(editor: editor) }
                .disabled(!catalog.canPasteEdits(editor: editor))
            Button(L10n.tr("Sync Edits…")) { catalog.requestSyncEdits(editor: editor) }
                .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!catalog.canSyncEdits(editor: editor))
            Divider()
            Button(L10n.tr("Rotate Left")) { editor.edit { $0.quarterTurns = ($0.quarterTurns + 3) % 4 } }.keyboardShortcut("[").disabled(inLibrary || !editor.hasImage || editor.busy)
            Button(L10n.tr("Rotate Right")) { editor.edit { $0.quarterTurns = ($0.quarterTurns + 1) % 4 } }.keyboardShortcut("]").disabled(inLibrary || !editor.hasImage || editor.busy)
            Button(editor.comparing ? L10n.tr("Hide Comparison") : L10n.tr("Compare with Original")) { editor.comparing.toggle() }.disabled(inLibrary || !editor.hasImage)
            Button(L10n.tr("Reset Adjustments"), action: editor.reset).keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(inLibrary || !editor.hasImage || editor.busy)
            Button(L10n.tr("New Snapshot…")) { editor.toolTab = .history; editor.showInspector = true; editor.snapshotNameRequested = true }
                .keyboardShortcut("n", modifiers: [.command, .shift]).disabled(inLibrary || !editor.keepsHistory || !editor.hasImage || editor.busy)
            Button(targets.count > 1 ? L10n.tr("Reset Edits on \(targets.count) Photos…") : L10n.tr("Reset Edits…")) { catalog.requestResetEdits(targets) }
                .disabled(targets.isEmpty || catalog.filter.area != .library && inLibrary || catalog.catalogBusy || editor.busy)
            Button(L10n.tr("Strip Unsupported XMP Settings")) { let targets = targets; Task { await catalog.stripUnsupportedXMP(targets, editor: editor) } }
                .disabled(!catalog.canStripXMP(targets, editor: editor) || editor.busy)
            if !catalog.isFolderIndex {
                Divider()
                Button(L10n.tr("Import XMP…")) { if inLibrary { catalog.chooseXMPImport() } else { editor.chooseXMPImport() } }
                    .disabled(catalog.isFolderIndex || (inLibrary ? single == nil || catalog.filter.area != .library || catalog.catalogBusy : !editor.hasImage || editor.busy))
                Button(L10n.tr("Export XMP…")) { if inLibrary { catalog.chooseXMPExport() } else { editor.chooseXMPExport() } }
                    .disabled(catalog.isFolderIndex || (inLibrary ? single == nil || catalog.filter.area != .library || catalog.catalogBusy : !editor.hasImage || editor.busy))
            }
            Button(L10n.tr("Apply Look File…"), action: editor.chooseLookFile).disabled(inLibrary || !editor.hasImage || editor.busy)
            Button(L10n.tr("Save Preset…"), action: editor.requestPresetSave).disabled(inLibrary || !editor.hasImage || editor.busy)
            Divider()
            if !catalog.isFolderIndex {
                Button(targets.count > 1 ? L10n.tr("Group \(targets.count) Photos") : L10n.tr("Group Photos")) { let targets = targets; Task { await catalog.group(targets) } }
                    .keyboardShortcut("g").disabled(!catalog.canGroup(targets) || catalog.catalogBusy)
                Button(L10n.tr("Ungroup")) { let targets = targets; Task { await catalog.ungroup(targets) } }
                    .keyboardShortcut("g", modifiers: [.command, .shift]).disabled(!catalog.canUngroup(targets) || catalog.catalogBusy)
                // A folded group's cover alone stands for all its photos, so the group to open is the one cell selected.
                let cell = inLibrary ? catalog.selectedCell : single
                Button(cell.map { catalog.groupExpanded($0) } == true ? L10n.tr("Collapse Group") : L10n.tr("Expand Group")) { if let cell { catalog.toggleGroup(cell) } }
                    .disabled(cell.map { catalog.groupSize(of: $0) != nil || catalog.groupExpanded($0) } != true)
                Divider()
            }
            if !catalog.isFolderIndex {
                Button(targets.count > 1 ? L10n.tr("Duplicate \(targets.count) Photos") : L10n.tr("Duplicate")) { let targets = targets; Task { await catalog.duplicate(targets, editor: editor) } }
                    .keyboardShortcut("d").disabled(!inLibrary && !editor.hasImage || !catalog.canDuplicate(targets) || editor.busy || catalog.isFolderIndex)
            }
            Button(L10n.tr("Show in Finder")) { catalog.showInFinder(targets) }.keyboardShortcut("r").disabled(targets.allSatisfy(\.isLatent))
            if !catalog.isFolderIndex {
                Button(L10n.tr("Show Similar Photos")) { if let photo = single { Task { await catalog.showSimilar(to: photo, editor: editor) } } }
                    .disabled(single.map { !catalog.canShowSimilar([$0]) } ?? true)
                Button(L10n.tr("Show Nearby Photos")) { if let photo = single { Task { await catalog.showNearby(photo, editor: editor) } } }
                    .disabled(single.map { !catalog.canShowNearby([$0]) } ?? true)
                Button(L10n.tr("Locate Original…"), action: catalog.relink).disabled(!inLibrary || single == nil || single?.isLatent == true || catalog.filter.area != .library || catalog.catalogBusy || catalog.isFolderIndex)
                Button(L10n.tr("Replace Original…"), action: catalog.replaceOriginal).disabled(!inLibrary || single == nil || catalog.filter.area != .library || catalog.catalogBusy || catalog.isFolderIndex)
            }
            Divider()
            // The Archived view's own buttons, for the keyboard and the menu bar.
            if inLibrary && catalog.filter.area == .archive {
                Button(L10n.tr("Unarchive")) { let targets = targets; Task { await catalog.unarchive(targets) } }.disabled(targets.isEmpty || catalog.catalogBusy)
                Button(L10n.tr("Move to Folder…")) { catalog.requestMoveToFolder(targets) }.disabled(targets.isEmpty || catalog.catalogBusy)
                Button(L10n.tr("Copy to Folder…")) { catalog.exportOriginals(targets) }.disabled(targets.isEmpty || !catalog.canStartJob)
                Divider()
            }
            if inLibrary && catalog.filter.area == .trash {
                Button(L10n.tr("Recover")) { guard !TextEditingKey.forwardedToText() else { return }; let targets = targets; Task { await catalog.recoverFromTrash(targets) } }
                    .keyboardShortcut(.delete, modifiers: .command).disabled(targets.isEmpty || catalog.catalogBusy)
            } else {
                Button(L10n.tr("Move to Trash")) { guard !TextEditingKey.forwardedToText() else { return }; catalog.requestMoveToTrash(targets, editor: editor) }
                    .keyboardShortcut(.delete, modifiers: .command).disabled(targets.isEmpty || catalog.catalogBusy || editor.busy)
            }
            if inLibrary, let albumID = catalog.filter.albumID {
                Button(L10n.tr("Remove from Album")) { let targets = targets; Task { await catalog.removeFromAlbum(albumID, photos: targets) } }
                    .disabled(targets.isEmpty || catalog.catalogBusy)
            }
            if !catalog.isFolderIndex {
                Button(targets.count > 1 ? L10n.tr("Remove \(targets.count) Photos from Library…") : L10n.tr("Remove from Library…")) { guard !TextEditingKey.forwardedToText() else { return }; let targets = targets; Task { await catalog.requestPermanentDeletion(targets, editor: editor) } }
                    .keyboardShortcut(.delete, modifiers: [.command, .option]).disabled(targets.isEmpty || catalog.catalogBusy || editor.busy || catalog.isFolderIndex)
                Button(L10n.tr("Empty Trash…")) { guard !TextEditingKey.forwardedToText() else { return }; Task { await catalog.requestEmptyTrash(editor: editor) } }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift]).disabled(catalog.trashCount == 0 || catalog.catalogBusy || editor.busy || catalog.isFolderIndex)
            }
        }
        // What is made from photos or run over them; the Photo menu keeps what is done to a photo.
        CommandMenu(L10n.tr("Tools")) {
            Button(L10n.tr("Creative Filters…")) { catalog.requestFilters(targets) }.disabled(!catalog.canApplyFilters(targets))
            Button(L10n.tr("AI Noise Reduction…")) { catalog.requestDenoise(targets) }.disabled(!catalog.canDenoise(targets) || catalog.denoise != nil)
            Button(L10n.tr("Wide-Angle Faces…")) { catalog.requestWideAngle(targets) }.disabled(!catalog.canCorrectWideAngle(targets) || catalog.wideAngle != nil)
            Button(L10n.tr("ID Photo…")) { catalog.requestIDPhoto(targets, editor: editor) }.disabled(!catalog.canMakeIDPhoto(targets) || catalog.idPhoto != nil)
            Button(L10n.tr("Convert Negative…")) { catalog.requestNegative(targets) }.disabled(!catalog.canConvertNegative(targets) || catalog.negative != nil)
            Button(L10n.tr("Chart Profile…")) { catalog.requestChartProfile(targets) }.disabled(!catalog.canMakeChartProfile(targets))
            Button(!inLibrary && editor.proof.on ? L10n.tr("Hide Print Proof") : L10n.tr("Print Proof")) { catalog.togglePrintProof(targets, editor: editor) }
                .keyboardShortcut("y").disabled(!catalog.canPrintProof(targets, editor: editor))
            Divider()
            Button(L10n.tr("Timelapse Deflicker…")) { catalog.requestExposureRamp(targets) }
                .disabled(!catalog.canBalanceExposure(targets) || catalog.exposureRamp != nil || catalog.timelapse != nil)
            Button(L10n.tr("Match Series…")) { catalog.requestMatchSeries(targets) }.disabled(!catalog.canMatchSeries(targets))
            Divider()
            Button(L10n.tr("Merge to Panorama…")) { catalog.requestPanoramaMerge(targets) }
                .keyboardShortcut("m", modifiers: .control).disabled(!catalog.canMergePanorama(targets) || catalog.panoramaMerge != nil || catalog.hdrMerge != nil || catalog.nightSky != nil)
            Button(L10n.tr("Merge to HDR…")) { catalog.requestHDRMerge(targets) }
                .keyboardShortcut("h", modifiers: .control).disabled(!catalog.canMergeHDR(targets) || catalog.hdrMerge != nil || catalog.panoramaMerge != nil || catalog.nightSky != nil || catalog.focusStack != nil)
            Menu(L10n.tr("Stack")) {
                ForEach(PhotoStackMode.menuItems) { mode in
                    Button(mode.menuTitle!) { catalog.requestStack(targets, mode: mode) }
                }
            }
            .disabled(!catalog.canStack(targets) || catalog.photoStack != nil || catalog.hdrMerge != nil || catalog.panoramaMerge != nil || catalog.nightSky != nil || catalog.focusStack != nil)
            Button(L10n.tr("Focus Stack…")) { catalog.requestFocusStack(targets) }
                .disabled(!catalog.canFocusStack(targets) || catalog.focusStack != nil || catalog.hdrMerge != nil || catalog.panoramaMerge != nil || catalog.nightSky != nil)
            Button(L10n.tr("Merge Pixel Shift…")) { catalog.requestPixelShift(targets) }.disabled(!catalog.canPixelShift(targets))
            Button(L10n.tr("Merge Best Faces…")) { catalog.requestBestFaces(targets) }.disabled(!catalog.canMergeBestFaces(targets))
            Menu(L10n.tr("Night Sky")) {
                ForEach([NightSkyTool.starTrails, .denoise, .meteorShower]) { tool in
                    Button(tool.menuTitle) { catalog.requestNightSky(tool, targets) }
                        .disabled(!catalog.canUseNightSky(tool, targets) || catalog.hdrMerge != nil || catalog.panoramaMerge != nil || catalog.focusStack != nil)
                }
            }
            Button(L10n.tr("Create Timelapse Video…")) { catalog.requestTimelapse(targets) }
                .disabled(!catalog.canCreateTimelapse(targets) || catalog.timelapse != nil || catalog.panoramaMerge != nil || catalog.hdrMerge != nil || catalog.nightSky != nil)
            Button(L10n.tr("Create Live Photo…")) { catalog.requestLivePhoto(targets) }.disabled(!catalog.canCreateLivePhoto(targets))
            if !catalog.isFolderIndex {
                Divider()
                Button(L10n.tr("Pick from Bursts…")) { let scope = inLibrary ? targets : []; Task { await catalog.requestCullingAssistant(scope) } }
                    .keyboardShortcut("b", modifiers: [.command, .option]).disabled(noCatalog || !catalog.canCull(inLibrary ? targets : []))
                Button(L10n.tr("Find Flawed Photos…")) { let scope = inLibrary ? targets : []; Task { await catalog.requestProblemPhotos(scope) } }
                    .keyboardShortcut("p", modifiers: [.command, .option]).disabled(noCatalog || !catalog.canCull(inLibrary ? targets : []))
                Button(L10n.tr("Check Faces…")) { let scope = inLibrary ? targets : []; Task { await catalog.requestFaceCheck(scope) } }
                    .disabled(noCatalog || !catalog.canCull(inLibrary ? targets : []))
                Button(L10n.tr("Tidy RAW + JPEG Pairs…")) { let scope = inLibrary ? targets : []; Task { await catalog.requestTidyPairs(scope) } }
                    .disabled(noCatalog || !catalog.canCull(inLibrary ? targets : []))
            }
        }
        CommandMenu(L10n.tr("Go")) {
            Button(L10n.tr("Previous Photo")) { Task { await catalog.navigate(-1, editor: editor) } }
                .keyboardShortcut(.leftArrow, modifiers: .option).disabled(inLibrary || !catalog.canNavigate(-1, editor: editor))
            Button(L10n.tr("Next Photo")) { Task { await catalog.navigate(1, editor: editor) } }
                .keyboardShortcut(.rightArrow, modifiers: .option).disabled(inLibrary || !catalog.canNavigate(1, editor: editor))
            if !catalog.isFolderIndex {
                Divider()
                Button(L10n.tr("All Photos")) { Task { await catalog.showCollection(trash: false) } }.disabled(noCatalog || !inLibrary || catalog.interactionBusy || catalog.isFolderIndex)
                Button(L10n.tr("Map")) { Task { await catalog.showCollection(trash: false, geotagged: true) } }.disabled(noCatalog || !inLibrary || catalog.interactionBusy || catalog.isFolderIndex)
                Button(L10n.tr("People")) { Task { await catalog.showCollection(area: .library, faces: true) } }.disabled(noCatalog || !inLibrary || catalog.interactionBusy || catalog.isFolderIndex)
                Button(L10n.tr("Archived")) { Task { await catalog.showCollection(area: .archive) } }.disabled(noCatalog || !inLibrary || catalog.interactionBusy || catalog.isFolderIndex)
                Button(L10n.tr("Trash")) { Task { await catalog.showCollection(trash: true) } }.disabled(noCatalog || !inLibrary || catalog.interactionBusy || catalog.isFolderIndex)
            }
        }
    }
    private func viewToggle(_ mode: CatalogModel.ViewMode, key: KeyEquivalent) -> some View {
        Toggle(mode.title, isOn: Binding(get: { catalog.viewMode == mode }, set: { _ in catalog.show(mode, editor: editor) }))
            .keyboardShortcut(key).disabled(noCatalog || !catalog.canShow(mode, editor: editor) && catalog.viewMode != mode)
    }
    private func photosToggle(_ style: CatalogModel.GridStyle, key: KeyEquivalent) -> some View {
        Toggle(style.title, isOn: Binding(get: { catalog.showingPhotos && catalog.gridStyle == style }, set: { _ in catalog.showPhotos(style, editor: editor) }))
            .keyboardShortcut(key).disabled(noCatalog || !catalog.canShow(.grid, editor: editor) && !catalog.showingLibrary)
    }
}

/// What the menu bar and the filmstrip show of the editor. They observe this rather than the editor, which changes many
/// times a second while a slider moves, so they are rebuilt only when one of these values changes.
/// Tells the menu bar and the photo menu when the catalog changed, except while a menu is open: rebuilding a menu
/// then closes the submenu being browsed (an import refreshes the library every few photos). What changed meanwhile
/// is shown once the menu closes; the actions themselves check the catalog as it is when chosen.
@MainActor final class CatalogMenuState: ObservableObject {
    private var subscriptions: Set<AnyCancellable> = []
    private var tracking = 0
    private var held = false
    init(catalog: CatalogModel) {
        catalog.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            if self.tracking > 0 { self.held = true } else { self.objectWillChange.send() }
        }.store(in: &subscriptions)
        // Any menu: the menu bar and the context menus on photos.
        let center = NotificationCenter.default
        center.publisher(for: NSMenu.didBeginTrackingNotification).sink { [weak self] _ in
            self?.tracking += 1
        }.store(in: &subscriptions)
        center.publisher(for: NSMenu.didEndTrackingNotification).sink { [weak self] _ in
            guard let self else { return }
            self.tracking = max(0, self.tracking - 1)
            if self.tracking == 0, self.held { self.held = false; self.objectWillChange.send() }
        }.store(in: &subscriptions)
    }
}

@MainActor final class EditorMenuState: ObservableObject {
    struct Values: Equatable {
        var busy = false, hasImage = false, showInspector = false, showFilmstrip = false, showCullingBar = false
        var comparing = false, canUndo = false, canRedo = false, showExport = false, keepsHistory = false
        var fitted = false, proof = false, canStripXMP = false, sidecar = false
        var filmstripStyle: EditorModel.FilmstripStyle?
        var filmstripHeight = 0.0, inFolder = false
        var assetID: String?
    }
    @Published private(set) var values = Values()
    private var pending = false
    private var subscription: AnyCancellable?
    init(editor: EditorModel) {
        values = Self.read(editor)
        subscription = editor.objectWillChange.merge(with: editor.proof.objectWillChange).sink { [weak self, weak editor] _ in
            // objectWillChange comes before the change: read once the burst has landed.
            guard let self, !self.pending else { return }
            self.pending = true
            DispatchQueue.main.async {
                self.pending = false
                guard let editor else { return }
                let read = Self.read(editor)
                if read != self.values { self.values = read }
            }
        }
    }
    private static func read(_ editor: EditorModel) -> Values {
        Values(busy: editor.busy, hasImage: editor.hasImage, showInspector: editor.showInspector, showFilmstrip: editor.showFilmstrip,
               showCullingBar: editor.showCullingBar, comparing: editor.comparing, canUndo: !editor.undoStack.isEmpty,
               canRedo: !editor.redoStack.isEmpty, showExport: editor.showExport, keepsHistory: editor.keepsHistory,
               fitted: editor.viewport.isFitted, proof: editor.proof.on, canStripXMP: editor.canStripXMP,
               sidecar: editor.developmentStore is SidecarDevelopmentStore, filmstripStyle: editor.filmstripStyle,
               filmstripHeight: editor.filmstripHeight, inFolder: editor.inFolder, assetID: editor.catalogAssetID)
    }
}

/// ⌘⌫ deletes to the start of the line while typing, but the menu sees the key before the text field does, so
/// clearing a field (the search, a title, Set Location's search) would ask to move the selected photos to the Trash,
/// or show that question once a sheet closes. The menu items that take ⌘⌫ with modifiers give the key back to
/// the text being edited instead.
@MainActor
enum TextEditingKey {
    /// True when the current key press belongs to an editable text view, which then deletes as it would have.
    static func forwardedToText() -> Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown,
              let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.isEditable else { return false }
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command { text.deleteToBeginningOfLine(nil) }
        return true
    }
}
