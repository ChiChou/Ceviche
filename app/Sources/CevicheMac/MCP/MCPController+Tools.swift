import Foundation
import ImageIO
import CryptoKit
import CevicheCore

extension MCPController {
    func call(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
        if name == "photo_docs" { return try MCPTools.result(documentation(args)) }
        if name == "photo_looks" { return try MCPTools.result(looks(args)) }
        if name == "job_status" || name == "job_cancel" { return try MCPTools.result(job(name, args)) }
        guard let catalog, let editor, let store = catalog.store else { throw MCPFailure("not_ready", "Open a catalog in Ceviche first.") }
        // Reads observe a snapshot and leave the UI usable; only writes suspend UI mutation.
        let dryRun = (name == "photo_apply" || name == "catalog_update") && args["dryRun"] as? Bool == true
        let writes = (MCPTools.all.first { $0.name == name }?.writes ?? true) && !dryRun
        guard !isWorking, !catalog.catalogBusy, !editor.busy, !(writes && editor.automationGestureActive) else { throw MCPFailure("busy", "Ceviche is processing another operation or an active editing gesture. Retry after it finishes.") }
        isWorking = true; activity = MCPActivity(tool: name, writes: writes)
        if writes { editor.automationBusy = true; catalog.automationBusy = true }
        defer { isWorking = false; activity = nil; editor.automationBusy = false; catalog.automationBusy = false }
        let catalogID = Self.digest(Data(store.root.resolvingSymlinksInPath().path.utf8))
        if let requested = args["catalogId"] as? String, requested != catalogID { throw MCPFailure("catalog_changed", "The active catalog changed; call catalog_query again.") }
        if writes {
            guard await catalog.flushMetadata() else { throw MCPFailure("save_failed", catalog.error ?? "Pending metadata could not be saved.") }
            if editor.catalogAssetID != nil, editor.dirty, !(await editor.save()) { throw MCPFailure("save_failed", editor.error ?? "Pending editor changes could not be saved.") }
        }
        try Task.checkCancellation()

        switch name {
        case "catalog_query": return try await query(args, store: store, catalogID: catalogID)
        case "catalog_context":
            let library = catalog.showingLibrary
            let targets = catalog.cullingTargets(editor: editor).map(\.id)
            let offset = min(args["offset"] as? Int ?? 0, targets.count), end = min(targets.count, offset + (args["limit"] as? Int ?? 100))
            let active = library ? catalog.selected?.id : catalog.shownAssetID(editor: editor)
            var result: [String: Any] = ["catalogId": catalogID, "view": library ? "library" : "develop", "activeAssetId": active ?? NSNull(),
                                         "selectedCount": targets.count, "selectedIds": Array(targets[offset..<end])]
            if end < targets.count { result["nextOffset"] = end }
            return try MCPTools.result(result)
        case "catalog_thumbnails": return try await thumbnails(args, store: store, catalogID: catalogID)
        case "catalog_update": return try await update(args, store: store, catalog: catalog, catalogID: catalogID)
        case "catalog_import":
            let paths = args["paths"] as! [String]
            let roots = try paths.map(Self.absoluteURL)
            let recursive = args["recursive"] as? Bool ?? true
            let files = try await Task.detached {
                if recursive { return try CatalogImporter.files(in: roots) }
                var inputs: [URL] = []
                for url in roots {
                    if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                        inputs += try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]).filter {
                            CatalogImporter.supported($0) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                        }
                    } else { inputs.append(url) }
                }
                return try CatalogImporter.files(in: inputs)
            }.value
            guard files.count <= 10000 else { throw MCPFailure("limit", "Import at most 10,000 files per request; split this import into smaller folders.") }
            var outcomes: [[String: Any]] = []
            let batchID = UUID().uuidString
            for file in files {
                if Task.isCancelled { break }
                do {
                    if let existing = try await store.existingImport(file.resolvingSymlinksInPath().path) {
                        outcomes.append(["path": file.path, "assetId": existing.id, "status": existing.trashedAt == nil ? "existing" : "trashed"])
                    } else {
                        let prepared = try await Task.detached(priority: .utility) { try CatalogImporter.prepare(file) }.value
                        if Task.isCancelled { break }
                        let existing = try await store.existingImport(prepared.0.importPath)
                        let asset: CatalogAsset
                        if let existing { asset = existing } else {
                            var imported = prepared.0; imported.importBatchID = batchID
                            asset = try await store.insert(imported, thumbnail: prepared.1)
                        }
                        outcomes.append(["path": file.path, "assetId": asset.id, "status": existing == nil ? "imported" : asset.trashedAt == nil ? "existing" : "trashed"])
                    }
                } catch { outcomes.append(["path": file.path, "status": "failed", "error": error.localizedDescription]) }
            }
            await catalog.refresh()
            return try MCPTools.result(["catalogId": catalogID, "items": outcomes, "cancelled": Task.isCancelled, "remaining": files.count - outcomes.count])
        case "catalog_trash", "catalog_restore":
            let ids = args["assetIds"] as! [String]
            for id in ids { _ = try await store.asset(id) }
            try Task.checkCancellation()
            if name == "catalog_trash" {
                try await store.moveToTrash(ids)
                if let id = editor.catalogAssetID, ids.contains(id), editor.usesCatalog(store) { editor.closeDocument(); catalog.showingLibrary = true }
            } else { try await store.recoverFromTrash(ids) }
            await catalog.refresh()
            return try MCPTools.result(["catalogId": catalogID, "assetIds": ids, "trashed": name == "catalog_trash"])
        default: break
        }

        let asset = try await store.asset(args["assetId"] as! String)
        if name == "catalog_inspect" {
            let fields = args["fields"] as? [String] ?? []
            let original = CatalogImporter.sourceURL(for: asset, root: store.root)
            var result = Self.summary(asset)
            result["catalogId"] = catalogID; result["revision"] = try Self.metadataRevision(asset)
            result["metadata"] = try MCPSchema.encoded(asset.metadata)
            result["sourcePath"] = asset.sourcePath; result["importPath"] = asset.importPath; result["origin"] = asset.locator.string
            result["physicalPath"] = original.resolvingSymlinksInPath().path
            result["missingOriginal"] = !FileManager.default.fileExists(atPath: original.path)
            let info = asset.info; result["image"] = ["width": info.width, "height": info.height, "camera": info.camera, "lens": info.lens, "isRAW": info.isRAW]
            let photo = try await store.photo(asset.id)
            if let properties = (try? PropertyListSerialization.propertyList(from: photo.extractedMetadata, options: [], format: nil)) as? [String: Any] {
                result["capture"] = Self.capture(properties)
            }
            if fields.contains("sourceProperties") {
                result["sourceProperties"] = Self.jsonProperties(try PropertyListSerialization.propertyList(from: photo.extractedMetadata, options: [], format: nil))
            }
            if fields.contains("sourceXMP") {
                if let source = photo.xmpData {
                    result["sourceXMP"] = String(data: source, encoding: .utf8) ?? String(data: source, encoding: .utf16) ?? ""
                } else { result["sourceXMP"] = NSNull() }
                result["xmpCompatibilityReport"] = asset.xmpWarnings
            }
            if fields.contains("currentXMP") {
                let defaults = await Task.detached {
                    CatalogImporter.developmentDefaults(for: original, info: asset.info)
                }.value
                let settings = try await store.savedAdjustments(of: asset) ?? defaults
                let xmp = try XMPCodec.encode(adjustments: settings, metadata: asset.metadata, defaults: defaults, sourceData: photo.xmpData, filename: asset.filename)
                result["currentXMP"] = String(decoding: xmp, as: UTF8.self)
            }
            if fields.contains("history") {
                result["history"] = try await store.history(assetID: asset.id).map { ["id": $0.id, "kind": $0.kind.rawValue, "summary": $0.summary, "createdAt": ISO8601DateFormatter().string(from: $0.createdAt)] }
            }
            return try MCPTools.result(result)
        }
        guard asset.trashedAt == nil else { throw MCPFailure("trashed", "Restore this photo from Trash before editing, previewing or exporting.") }
        let snapshot: (renderer: RawRenderer, settings: Adjustments)
        do { snapshot = try await photo(asset, store: store, editor: editor) }
        catch where name == "photo_restore" && !(error is CancellationError) {
            // Going back in History is the way out of edits that can't be read or an original that changed. The
            // current revision can't be worked out then, so expectedRevision proves nothing: only an explicit
            // recover: true restores without it.
            guard args["recover"] as? Bool == true else {
                throw MCPFailure("revision_unavailable", "The photo can't be read (\(error.localizedDescription)), so its revision can't be checked. Call photo_restore with recover: true to restore this history entry anyway.")
            }
            let item = try await historyItem(args, asset: asset, store: store)
            try Task.checkCancellation()
            try await store.restore(item)
            let updated = try await store.asset(asset.id)
            if item.kind == .edit { await store.thumbnails.want([asset.id], kind: .developed, priority: .visible) }
            else { catalog.acceptAutomationMetadata(updated.metadata, assetID: asset.id) }
            await catalog.refresh()
            var state: [String: Any] = ["catalogId": catalogID, "assetId": asset.id]
            if let restored = try? await photo(updated, store: store, editor: editor) {
                if item.kind == .edit, editor.catalogAssetID == asset.id, editor.usesCatalog(store) { editor.acceptAutomationEdits(restored.settings) }
                state["revision"] = try MCPEditSchema.revision(restored.settings, metadata: updated.metadata)
                state["editing"] = try MCPEditSchema.state(restored.settings, defaults: restored.renderer.info.defaults)
            } else {
                state["note"] = "Restored. The photo still can't be read for editing: \(error.localizedDescription)"
            }
            return try MCPTools.result(state)
        }
        var settings = snapshot.settings
        let renderer = snapshot.renderer
        let revision = try MCPEditSchema.revision(settings, metadata: asset.metadata)
        if let expected = args["expectedRevision"] as? String ?? args["revision"] as? String, expected != revision {
            throw MCPFailure("revision_conflict", "Photo changed; call photo_read and reconsider the edit against its current state.")
        }
        try Task.checkCancellation()
        var state: [String: Any] = ["catalogId": catalogID, "assetId": asset.id, "revision": revision]
        switch name {
        case "photo_read":
            state["editing"] = try MCPEditSchema.state(settings, defaults: renderer.info.defaults)
            state["uncroppedSize"] = MCPEditSchema.uncroppedSize(settings, sourceSize: CGSize(width: renderer.info.width, height: renderer.info.height))
            if args["includePreview"] as? Bool == false { return try MCPTools.result(state) }
            let preview = try await renderer.mcpPreview(settings, maxEdge: min(args["maxEdge"] as? Int ?? activePreviewMaxEdge, activePreviewMaxEdge))
            state["preview"] = Self.previewInfo(preview); state["statistics"] = preview.statistics.json
            return try MCPTools.result(state, images: [preview.png])
        case "photo_apply":
            try MCPSchema.validate(args, against: MCPEditSchema.document)
            let changes = args["changes"] as! [String: Any]
            try MCPSchema.validate(changes, against: MCPEditSchema.changes, path: "changes")
            var lookWarnings: [String] = []
            for file in changes["applyFiles"] as? [[String: Any]] ?? [] {
                let url = try Self.absoluteURL(file["path"] as! String).standardizedFileURL
                let base = settings, info = renderer.info, resources = store.resources
                let applied = try await Task.detached(priority: .userInitiated) { try MCPEditSchema.applyLookFile(url, to: base, info: info, resources: resources) }.value
                settings = applied.0; lookWarnings += applied.1.map { url.lastPathComponent + ": " + $0 }
                try Task.checkCancellation()
            }
            if !lookWarnings.isEmpty { state["lookWarnings"] = lookWarnings }
            var generated: [String: PhotoMask] = [:]
            for addition in MCPEditSchema.generatedAdditions(changes, existing: settings) {
                if addition.kind == .object, addition.point == nil { throw MCPFailure("point_required", "Object masks need a point inside the object, in mask coordinates.", path: "changes.addMasks") }
                if addition.kind == .scene, addition.scene == nil { throw MCPFailure("scene_required", "Scene masks need scene: one of \(SceneCategory.allCases.map(\.rawValue).joined(separator: ", ")).", path: "changes.addMasks") }
                do { generated[addition.id.lowercased()] = try await renderer.selection(addition.kind, point: addition.point, scene: addition.scene) }
                catch let error as MCPFailure { throw error }
                catch { throw MCPFailure("selection_failed", error.localizedDescription, path: "changes.addMasks") }
                try Task.checkCancellation()
            }
            settings = try MCPEditSchema.apply(changes, to: settings, isRAW: renderer.info.isRAW, generated: generated)
            settings = try MCPEditSchema.applyCropPixels(changes, to: settings, sourceSize: CGSize(width: renderer.info.width, height: renderer.info.height))
            // Validate image-dependent geometry before any write.
            _ = try GeometryPlan(size: CGSize(width: renderer.info.width, height: renderer.info.height), settings: settings.geometry, quarterTurns: settings.quarterTurns)
            let editing = try MCPEditSchema.state(settings, defaults: renderer.info.defaults)
            state["uncroppedSize"] = MCPEditSchema.uncroppedSize(settings, sourceSize: CGSize(width: renderer.info.width, height: renderer.info.height))
            let nextRevision = try MCPEditSchema.revision(settings, metadata: asset.metadata)
            try Task.checkCancellation()
            if dryRun {
                // Render the candidate without committing, so an agent can iterate without filling history.
                let preview = try await renderer.mcpPreview(settings, maxEdge: min(args["maxEdge"] as? Int ?? activePreviewMaxEdge, activePreviewMaxEdge), scope: args["scope"] as? [Double] ?? [0, 0, 1, 1])
                state["editing"] = editing; state["committed"] = false; state["candidateRevision"] = nextRevision
                state["preview"] = Self.previewInfo(preview); state["statistics"] = preview.statistics.json
                return try MCPTools.result(state, images: [preview.png])
            }
            _ = try await store.saveEdits(settings, assetID: asset.id, baseline: renderer.info.defaults)
            if editor.catalogAssetID == asset.id, editor.usesCatalog(store) { editor.acceptAutomationEdits(settings) }
            state["revision"] = nextRevision; state["editing"] = editing; state["committed"] = true
            // The thumbnail follows through the catalog's queue, so the edit returns without waiting for a render.
            await store.thumbnails.want([asset.id], kind: .developed, priority: .visible)
            await catalog.refresh()
            return try MCPTools.result(state)
        case "photo_preview":
            var content = MCPPreviewContent.image
            if let maskID = args["mask"] as? String {
                guard let mask = settings.masks.first(where: { $0.id.uuidString.lowercased() == maskID.lowercased() }) else { throw MCPFailure("missing_mask", "Mask does not exist.", path: "mask") }
                content = args["maskStyle"] as? String == "overlay" ? .overlay(mask) : .matte(mask)
                state["mask"] = ["id": mask.id.uuidString, "name": mask.name, "kind": mask.kind.rawValue, "enabled": mask.enabled, "style": args["maskStyle"] as? String ?? "matte"]
            }
            if args["rendition"] as? String == "asShot" {
                var original = renderer.info.defaults
                original.geometry = settings.geometry; original.quarterTurns = settings.quarterTurns
                settings = original
            }
            let preview = try await renderer.mcpPreview(settings, scale: args["scale"] as? Double ?? 1,
                maxEdge: min(args["maxEdge"] as? Int ?? activePreviewMaxEdge, activePreviewMaxEdge), scope: args["scope"] as? [Double] ?? [0, 0, 1, 1], content: content)
            state["preview"] = Self.previewInfo(preview); state["rendition"] = args["rendition"] ?? "edited"
            state["statistics"] = preview.statistics.json
            if case .matte = content, var mask = state["mask"] as? [String: Any] {
                // Mean matte luminance is the fraction of the rendered region the mask affects at full strength.
                mask["coverage"] = MCPStatistics.round(preview.statistics.luminance.mean); state["mask"] = mask
            }
            return try MCPTools.result(state, images: args["includeImage"] as? Bool == false ? [] : [preview.png])
        case "photo_convert":
            let plan = try GeometryPlan(size: CGSize(width: renderer.info.width, height: renderer.info.height), settings: settings.geometry, quarterTurns: settings.quarterTurns)
            let fromPreview = args["from"] as! String == "preview"
            let converted = (args["points"] as! [[Double]]).map { point -> [Double] in
                if fromPreview {
                    let source = plan.sourcePoint(MaskPoint(x: point[0], y: 1 - point[1]))
                    return [MCPStatistics.round(source.x), MCPStatistics.round(source.y)]
                }
                let display = plan.displayPoint(MaskPoint(x: point[0], y: point[1]))
                return [MCPStatistics.round(display.x), MCPStatistics.round(1 - display.y)]
            }
            state["from"] = fromPreview ? "preview" : "mask"; state["to"] = fromPreview ? "mask" : "preview"; state["points"] = converted
            state["note"] = "Values outside 0…1 lie outside the " + (fromPreview ? "source image" : "cropped preview") + "."
            return try MCPTools.result(state)
        case "photo_restore":
            let item = try await historyItem(args, asset: asset, store: store)
            try Task.checkCancellation()
            try await store.restore(item)
            let updated = try await store.asset(asset.id)
            if item.kind == .edit {
                settings = try await store.savedAdjustments(of: updated) ?? renderer.info.defaults
                if editor.catalogAssetID == asset.id, editor.usesCatalog(store) { editor.acceptAutomationEdits(settings) }
                await store.thumbnails.want([asset.id], kind: .developed, priority: .visible)
            } else { catalog.acceptAutomationMetadata(updated.metadata, assetID: asset.id) }
            await catalog.refresh()
            state["revision"] = try MCPEditSchema.revision(settings, metadata: updated.metadata)
            state["editing"] = try MCPEditSchema.state(settings, defaults: renderer.info.defaults)
            state["restored"] = ["id": item.id, "kind": item.kind.rawValue, "summary": item.summary, "createdAt": ISO8601DateFormatter().string(from: item.createdAt)]
            return try MCPTools.result(state)
        case "photo_export":
            if args["rendition"] as? String == "asShot" {
                var original = renderer.info.defaults
                original.geometry = settings.geometry; original.quarterTurns = settings.quarterTurns
                settings = original
            }
            let destination = try Self.absoluteURL(args["path"] as! String).standardizedFileURL
            // APFS is usually case-insensitive, so compare path components case-insensitively.
            let resolved = destination.resolvingSymlinksInPath().pathComponents.map { $0.lowercased() }
            let root = store.root.resolvingSymlinksInPath().pathComponents.map { $0.lowercased() }
            guard !FileManager.default.fileExists(atPath: destination.path), !resolved.starts(with: root) else { throw MCPFailure("protected_path", "Choose a new file outside the catalog directory. Existing files cannot be overwritten.") }
            var output = ExportSettings()
            output.select(ExportFormat(rawValue: args["format"] as! String)!)
            output.depth = args["bitsPerChannel"] as? Int ?? output.depth; output.hdr = args["hdr"] as? Bool ?? false
            if let encoding = args["hdrEncoding"] as? String { output.hdrEncoding = HDREncoding(rawValue: encoding)! }
            output.quality = args["quality"] as? Double ?? 0.95
            output.lossless = args["lossless"] as? Bool ?? true
            output.preserveAlpha = args["preserveAlpha"] as? Bool ?? true
            output.includeMetadata = args["includeMetadata"] as? Bool ?? true
            output.includeLocation = args["includeLocation"] as? Bool ?? false
            output.location = ExportGPS(latitude: asset.latitude, longitude: asset.longitude)
            output.aiDenoise = args["aiDenoise"] as? Double ?? 0
            output.profile = settings.colorProfile
            if let profile = args["profile"] as? String { output.profile.preset = RGBProfile(rawValue: profile)! }
            let plan = try GeometryPlan(size: CGSize(width: renderer.info.width, height: renderer.info.height), settings: settings.geometry, quarterTurns: settings.quarterTurns)
            if let size = args["size"] as? [String: Any] {
                let scale = min(Double(size["width"] as! Int) / plan.outputSize.width, Double(size["height"] as! Int) / plan.outputSize.height,
                                size["allowUpscale"] as? Bool == true ? Double.greatestFiniteMagnitude : 1)
                output.sizing.setWidth(max(1, Int(floor(plan.outputSize.width * scale))), source: plan.outputSize)
            }
            try output.validate()
            let dimensions = try output.dimensions(for: plan.outputSize)
            if let size = args["size"] as? [String: Any], dimensions.width > size["width"] as! Int || dimensions.height > size["height"] as! Int {
                throw MCPFailure("invalid_size", "This fit box is too small to preserve the image proportions with whole pixels. Increase its dimensions.", path: "size")
            }
            try await renderer.export(to: destination, adjustments: settings, settings: output, overwriteExisting: false)
            state["path"] = destination.path; state["width"] = dimensions.width; state["height"] = dimensions.height
            state["bitsPerChannel"] = output.depth; state["profile"] = output.profileLabel; state["hdr"] = output.hdr
            if output.hdr { state["hdrEncoding"] = output.hdrEncoding.rawValue }
            state["rendition"] = args["rendition"] ?? "edited"; state["includeLocation"] = output.includeMetadata && output.includeLocation
            return try MCPTools.result(state)
        default: throw MCPFailure("unknown_tool", "Unknown tool.")
        }
    }

    private func historyItem(_ args: [String: Any], asset: CatalogAsset, store: CatalogStore) async throws -> CatalogRevision {
        let historyID = args["historyId"] as! String
        guard let item = try await store.history(assetID: asset.id).first(where: { $0.id == historyID }) else {
            throw MCPFailure("missing_history", "No history entry has this id; call catalog_inspect with fields: [\"history\"].", path: "historyId")
        }
        return item
    }
    private func photo(_ asset: CatalogAsset, store: CatalogStore, editor: EditorModel) async throws -> (renderer: RawRenderer, settings: Adjustments) {
        if editor.catalogAssetID == asset.id, editor.usesCatalog(store), let renderer = editor.renderer { return (renderer, editor.adjustments) }
        let saved = try await store.savedAdjustments(of: asset)
        return try await Task.detached(priority: .userInitiated) {
            let url = CatalogImporter.sourceURL(for: asset, root: store.root)
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            if try !CatalogImporter.matches(url, asset) { throw MCPFailure("source_changed", "The original changed since import.") }
            let renderer = try RawRenderer(sourceURL: url)
            let settings = saved ?? renderer.info.defaults
            return (renderer, settings)
        }.value
    }

    private func query(_ args: [String: Any], store: CatalogStore, catalogID: String) async throws -> [String: Any] {
        queryPages = queryPages.filter { $0.value.expires > Date() }
        var criteria = args; criteria.removeValue(forKey: "cursor"); criteria.removeValue(forKey: "limit"); criteria.removeValue(forKey: "catalogId")
        let signature = try MCPSchema.data(criteria), limit = args["limit"] as? Int ?? 50
        let items: [[String: Any]], offset: Int
        if let cursor = args["cursor"] as? String {
            guard let page = queryPages[cursor], page.catalog == catalogID, page.signature == signature else { throw MCPFailure("invalid_cursor", "Cursor expired or query changed. Start a new query.") }
            items = page.items; offset = page.offset
        } else {
            var filter = CatalogFilter()
            filter.search = args["search"] as? String ?? ""; filter.area = args["trash"] as? Bool ?? false ? .trash : .library
            filter.minimumRating = args["minimumRating"] as? Int ?? 0
            filter.review = (args["review"] as? String).flatMap(ReviewState.init(rawValue:))
            filter.kind = args["kind"] as? String; filter.captureDay = args["captureDay"] as? String
            filter.hasLocation = args["hasLocation"] as? Bool
            if let tags = args["tags"] as? [String: Any] {
                let sources: [CatalogTagSource] = switch tags["source"] as? String {
                case "keywords": [.keyword]
                case "suggested": [.automatic]
                default: [.keyword, .automatic]
                }
                filter.tags = CatalogTagFilter(all: tags["all"] as? [String] ?? [], any: tags["any"] as? [String] ?? [], none: tags["none"] as? [String] ?? [], sources: sources)
            }
            // Every condition is in the filter, so the cap counts only the photos that match.
            let assets = try await store.assets(filter: filter, limit: 100000)
            guard assets.count < 100000 else { throw MCPFailure("query_limit", "Narrow the query to fewer than 100,000 photos.") }
            items = assets.map(Self.summary); offset = 0
        }
        let end = min(items.count, offset + limit)
        var result: [String: Any] = ["catalogId": catalogID, "items": Array(items[offset..<end]), "remaining": items.count - end, "snapshot": true]
        if end < items.count {
            if queryPages.count >= 16, let oldest = queryPages.min(by: { $0.value.expires < $1.value.expires })?.key { queryPages.removeValue(forKey: oldest) }
            let cursor = UUID().uuidString
            // Pages share the one list of results and differ only in where they start.
            queryPages[cursor] = (catalogID, signature, items, end, Date().addingTimeInterval(300))
            result["nextCursor"] = cursor
        }
        return try MCPTools.result(result)
    }

    private func looks(_ args: [String: Any]) throws -> [String: Any] {
        let library = LookLibrary.current(editor: editor, catalog: catalog)
        let kinds = (args["kind"] as? String).flatMap(LookKind.init(rawValue:)).map { [$0] } ?? LookKind.allCases
        func node(_ item: LookNode) -> [String: Any] {
            var result: [String: Any] = ["name": item.name, "path": item.url.path]
            if let children = item.children { result["items"] = children.map(node) }
            return result
        }
        var result: [String: Any] = ["root": library.root.path, "apply": "photo_apply changes.applyFiles: [{\"path\": \"<absolute path>\"}]"]
        for kind in kinds {
            result[kind.rawValue] = ["folder": library.folder(kind).path, "extensions": Array(kind.extensions).sorted(), "items": (try? library.tree(kind))?.map(node) ?? []]
        }
        return result
    }
    private func documentation(_ args: [String: Any]) throws -> [String: Any] {
        let section = args["section"] as? String ?? "index"
        var schema: [String: Any]
        switch section {
        case "global": schema = MCPEditSchema.global
        case "masks": schema = MCPEditSchema.mask
        case "changes": schema = MCPEditSchema.changes
        case "d.json": schema = MCPEditSchema.document
        case "export": return ["formats": ExportFormat.allCases.filter(\.isAvailable).map { format in ["format": format.rawValue, "sdrBits": format.depths, "hdrBits": format.hdrDepths, "hdrEncodings": format.hdrEncodings.map { ["encoding": $0.rawValue, "bits": $0.depths(for: format)] as [String: Any] }, "lossy": format.isLossy, "losslessChoice": format.supportsLosslessChoice, "alpha": format.supportsAlpha] as [String: Any] }]
        default: return ["schemaVersion": MCPEditSchema.version, "sections": ["global", "masks", "changes", "d.json", "export"],
                         "globalControls": Array((MCPEditSchema.global["properties"] as! [String: Any]).keys).sorted(),
                         "semantics": "Objects merge, arrays replace, omitted fields stay unchanged. Null is allowed only where declared. Remove masks with removeMasks. Reset controls by assigning their defaults. Curves are arrays of {x,y} points in 0…1. Exposure is EV; temperature is Kelvin. Global and local tint are -150…150; local warmth is -100…100. Mask and crop coordinates use a bottom-left origin; preview scope uses a top-left origin after geometry. changes.cropPixels {x,y,width,height} crops in pixels instead, top-left origin, counted in uncroppedSize (the photo after turns, straightening and upright, as photo_read reports it); it sets aspect Free. AI mask rasters and embedded ICC bytes stay server-side. Changing existing masks and creating Brush/Linear gradient/Radial gradient/Color range masks is supported; Subject/Background/Sky/Object masks are generated in the app when added (Object needs a point). Mask components (Add/Subtract/Intersect) are edited through masks.<id>.components. Request photo_docs section masks for how each mask kind is evaluated.",
                         "advice": MCPEditSchema.editingAdvice]
        }
        if let control = args["control"] as? String {
            for part in control.split(separator: ".") {
                guard let next = (schema["properties"] as? [String: Any])?[String(part)] as? [String: Any] else { throw MCPFailure("unknown_control", "Control not found in this section.") }
                schema = next
            }
            return ["schemaVersion": MCPEditSchema.version, "schema": schema]
        }
        var result: [String: Any] = ["schemaVersion": MCPEditSchema.version, "schema": schema]
        if section == "masks" || section == "changes" { result["semantics"] = MCPEditSchema.maskSemantics }
        return result
    }
    /// Exposure facts an agent needs before deciding how far a development can be pushed.
    static func capture(_ properties: [String: Any]) -> [String: Any] {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let aux = properties[kCGImagePropertyExifAuxDictionary as String] as? [String: Any] ?? [:]
        var result: [String: Any] = [:]
        func put(_ key: String, _ value: Any?) { if let value { result[key] = value } }
        put("iso", (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Any])?.first)
        put("exposureTime", exif[kCGImagePropertyExifExposureTime as String])
        put("fNumber", exif[kCGImagePropertyExifFNumber as String])
        put("exposureBias", exif[kCGImagePropertyExifExposureBiasValue as String])
        put("focalLength", exif[kCGImagePropertyExifFocalLength as String])
        put("focalLength35mm", exif[kCGImagePropertyExifFocalLenIn35mmFilm as String])
        put("dateTimeOriginal", exif[kCGImagePropertyExifDateTimeOriginal as String])
        put("whiteBalance", exif[kCGImagePropertyExifWhiteBalance as String])
        put("exposureProgram", exif[kCGImagePropertyExifExposureProgram as String])
        put("meteringMode", exif[kCGImagePropertyExifMeteringMode as String])
        put("flash", exif[kCGImagePropertyExifFlash as String])
        put("make", tiff[kCGImagePropertyTIFFMake as String])
        put("model", tiff[kCGImagePropertyTIFFModel as String])
        put("lens", exif[kCGImagePropertyExifLensModel as String] ?? aux[kCGImagePropertyExifAuxLensModel as String])
        put("orientation", properties[kCGImagePropertyOrientation as String])
        if let shutter = exif[kCGImagePropertyExifExposureTime as String] as? Double, shutter > 0 {
            result["shutter"] = shutter < 1 ? "1/\(Int((1 / shutter).rounded())) s" : String(format: "%.1f s", shutter)
        }
        return result
    }
    static func summary(_ asset: CatalogAsset) -> [String: Any] {
        var result: [String: Any] = ["assetId": asset.id, "filename": asset.filename, "kind": asset.kind, "title": asset.title, "rating": asset.rating,
                                     "review": asset.review.rawValue, "captureDay": asset.captureDay, "keywords": tags(asset.keywords), "suggestedTags": tags(asset.suggestedTags), "trashed": asset.trashedAt != nil]
        if let country = asset.placeCountry {
            var place: [String: Any] = ["country": country, "approximate": asset.placeSource == CatalogPlace.Source.nearby.rawValue]
            place["region"] = asset.placeRegion; place["city"] = asset.placeCity
            result["place"] = place
        }
        if let latitude = asset.latitude, let longitude = asset.longitude { result["location"] = MCPMetadataPatch.location(latitude, longitude, asset.locationSource) }
        return result
    }
    static func tags(_ value: String) -> [String] { value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
    static func metadataRevision(_ asset: CatalogAsset) throws -> String { try revision(of: asset.metadata) }
    static func revision(of metadata: CatalogMetadata) throws -> String { digest(try MCPSchema.data(MCPSchema.encoded(metadata))) }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func absoluteURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw MCPFailure("invalid_path", "Use an absolute filesystem path.") }
        return URL(fileURLWithPath: path)
    }
    private static func previewInfo(_ preview: MCPPreview) -> [String: Any] {
        ["width": preview.width, "height": preview.height, "fullWidth": preview.fullWidth, "fullHeight": preview.fullHeight,
         "regionPixels": preview.region, "scale": preview.scale, "scaleX": Double(preview.width) / preview.region[2], "scaleY": Double(preview.height) / preview.region[3],
         "origin": "top-left", "space": "developed", "profile": "sRGB", "dynamicRange": "SDR"]
    }
    private static func jsonProperties(_ value: Any) -> Any {
        if let object = value as? [String: Any] { return object.mapValues(jsonProperties) }
        if let array = value as? [Any] { return array.map(jsonProperties) }
        if let bytes = value as? Data { return ["encoding": "base64", "data": bytes.base64EncodedString()] }
        if let date = value as? Date { return ISO8601DateFormatter().string(from: date) }
        return value
    }
}
