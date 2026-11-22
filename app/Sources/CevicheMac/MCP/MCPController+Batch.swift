import Foundation
import CoreText
import ImageIO
import UniformTypeIdentifiers
import CevicheCore

/// The batch tools: look at many photos from their stored thumbnails, then write metadata to many at once.
extension MCPController {
    func thumbnails(_ args: [String: Any], store: CatalogStore, catalogID: String) async throws -> [String: Any] {
        let ids = args["assetIds"] as! [String]
        guard Set(ids).count == ids.count else { throw MCPFailure("invalid_value", "List each photo once.", path: "assetIds") }
        let maxEdge = max(64, min(args["maxEdge"] as? Int ?? 512, activePreviewMaxEdge, CatalogImporter.thumbnailPixelSize))
        let sheet = args["sheet"] as? Bool == true
        var assets: [String: CatalogAsset] = [:]
        for id in ids { if let asset = try? await store.asset(id) { assets[id] = asset } }
        // Photos without a stored thumbnail (new, or evicted) get one through the Library's own queue.
        let wanted = ids.filter { assets[$0].map { $0.trashedAt == nil } ?? false }
        if !wanted.isEmpty {
            let ticket = await store.thumbnails.want(wanted, kind: .preview, priority: .visible)
            _ = await withTaskCancellationHandler { await store.thumbnails.wait(ticket) } onCancel: { Task { await store.thumbnails.cancel(ticket) } }
        }
        try Task.checkCancellation()
        var items: [[String: Any]] = [], images: [CGImage] = []
        for id in ids {
            guard let asset = assets[id] else { items.append(["assetId": id, "status": "missing"]); continue }
            var item = Self.summary(asset)
            item["revision"] = try Self.metadataRevision(asset)
            item["metadata"] = MCPMetadataPatch.json(asset.metadata)
            item["captureTime"] = asset.captureTime ?? NSNull()
            let info = asset.info
            item["camera"] = info.camera; item["lens"] = info.lens
            if asset.trashedAt != nil { item["status"] = "trashed" }
            else if let data = try await store.previewData(id), let image = Self.downscaled(data, maxEdge: maxEdge) {
                images.append(image)
                item["status"] = "ok"; item["width"] = image.width; item["height"] = image.height
                item[sheet ? "sheetIndex" : "image"] = images.count
            } else { item["status"] = "unavailable" }
            items.append(item)
        }
        var result: [String: Any] = ["catalogId": catalogID, "items": items]
        var encoded: [Data] = []
        if sheet, !images.isEmpty, let contact = Self.contactSheet(images, maxEdge: maxEdge), let data = Self.jpeg(contact) {
            encoded = [data]; result["sheet"] = ["width": contact.width, "height": contact.height]
        } else if !sheet { encoded = images.compactMap(Self.jpeg) }
        return try MCPTools.result(result, images: encoded, mimeType: "image/jpeg")
    }

    func update(_ args: [String: Any], store: CatalogStore, catalog: CatalogModel, catalogID: String) async throws -> [String: Any] {
        let requests = args["items"] as! [[String: Any]]
        let ids = requests.map { $0["assetId"] as! String }
        guard Set(ids).count == ids.count else { throw MCPFailure("invalid_value", "List each photo once.", path: "items") }
        let dryRun = args["dryRun"] as? Bool == true
        var outcomes: [[String: Any]] = []
        var planned: [(id: String, old: CatalogMetadata, new: CatalogMetadata)] = []
        for (index, request) in requests.enumerated() {
            let id = ids[index]
            var outcome: [String: Any] = ["assetId": id]
            do {
                guard let asset = try? await store.asset(id) else { throw MCPFailure("missing", "No photo has this id.") }
                guard asset.trashedAt == nil else { throw MCPFailure("trashed", "Restore this photo from Trash first.") }
                let revision = try Self.metadataRevision(asset)
                if let expected = request["expectedRevision"] as? String, expected != revision {
                    throw MCPFailure("revision_conflict", "Metadata changed since it was read; read it again.")
                }
                let value = try MCPMetadataPatch.apply(request, to: asset.metadata)
                if value == asset.metadata { outcome["status"] = "unchanged"; outcome["revision"] = revision }
                else {
                    planned.append((id, asset.metadata, value))
                    outcome["status"] = dryRun ? "wouldUpdate" : "updated"
                    outcome["changes"] = MCPMetadataPatch.changes(from: asset.metadata, to: value)
                    outcome["revision"] = dryRun ? revision : try Self.revision(of: value)
                }
            } catch let failure as MCPFailure {
                outcome["status"] = failure.code == "revision_conflict" ? "revision_conflict" : "failed"
                outcome["error"] = failure.json
            }
            outcomes.append(outcome)
        }
        try Task.checkCancellation()
        if !dryRun, !planned.isEmpty {
            try await store.updateMetadata(Dictionary(uniqueKeysWithValues: planned.map { ($0.id, $0.new) }))
            catalog.registerBatchMetadataUndo(planned)
            for change in planned { catalog.acceptAutomationMetadata(change.new, assetID: change.id) }
            if planned.contains(where: { $0.old.latitude != $0.new.latitude || $0.old.longitude != $0.new.longitude }) { catalog.placeNamer.workAvailable() }
            await catalog.refresh()
        }
        func count(_ status: String) -> Int { outcomes.filter { $0["status"] as? String == status }.count }
        return try MCPTools.result(["catalogId": catalogID, "dryRun": dryRun, "items": outcomes,
                                    "updated": dryRun ? 0 : planned.count, "unchanged": count("unchanged"),
                                    "conflicts": count("revision_conflict"), "failed": count("failed")])
    }

    static func downscaled(_ data: Data, maxEdge: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return ImageDecode.thumbnail(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                 kCGImageSourceThumbnailMaxPixelSize: maxEdge] as CFDictionary)
    }
    static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
    /// The photos in a grid, numbered from 1 in reading order; at most 2048 pixels wide.
    static func contactSheet(_ images: [CGImage], maxEdge: Int) -> CGImage? {
        let columns = Int(Double(images.count).squareRoot().rounded(.up)), rows = (images.count + columns - 1) / columns
        let gap = 4, cell = min(maxEdge, (2048 - gap * (columns + 1)) / columns)
        let width = columns * cell + gap * (columns + 1), height = rows * cell + gap * (rows + 1)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(gray: 0.12, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, CGFloat(max(12, cell / 9)), nil)
        for (index, image) in images.enumerated() {
            let column = index % columns, row = index / columns
            let x = gap + column * (cell + gap), top = gap + row * (cell + gap)
            let frame = CGRect(x: x, y: height - top - cell, width: cell, height: cell)
            let scale = min(Double(cell) / Double(image.width), Double(cell) / Double(image.height))
            let size = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
            let fitted = CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
            context.draw(image, in: fitted)
            let text = NSAttributedString(string: "\(index + 1)", attributes: [kCTFontAttributeName as NSAttributedString.Key: font,
                                                                                kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 1)])
            let line = CTLineCreateWithAttributedString(text)
            let bounds = CTLineGetImageBounds(line, context), pad = CTFontGetSize(font) * 0.35
            let badge = CGRect(x: fitted.minX, y: fitted.maxY - bounds.height - pad * 2, width: bounds.width + pad * 2, height: bounds.height + pad * 2)
            context.setFillColor(gray: 0, alpha: 0.7); context.fill(badge)
            context.textPosition = CGPoint(x: badge.minX + pad - bounds.minX, y: badge.minY + pad - bounds.minY)
            CTLineDraw(line, context)
        }
        return context.makeImage()
    }
}
