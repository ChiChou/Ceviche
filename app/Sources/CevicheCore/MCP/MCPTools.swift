import Foundation

public struct MCPTool {
    public let name: String
    public let description: String
    public let input: [String: Any]
    public let writes: Bool
    /// Takes `background: true` to return a job id at once instead of waiting; see job_status.
    public var background = false
    /// Only tools that remove something from the user's view are destructive; imports, restores,
    /// exports (which never overwrite) and edits (kept in history) are additive.
    public var destructive: Bool { name == "catalog_trash" }
    /// Writes, but with `dryRun: true` only reports what it would do, so read-only access still offers that.
    public var proposes: Bool { name == "photo_apply" || name == "catalog_update" }
    /// The tool as read-only access lists it: `dryRun` required and fixed to true.
    public var proposalOnly: MCPTool {
        var input = input
        if var properties = input["properties"] as? [String: Any] {
            properties["dryRun"] = ["type": "boolean", "const": true]; input["properties"] = properties
            input["required"] = (input["required"] as? [String] ?? []) + ["dryRun"]
        }
        return MCPTool(name: name, description: "Read-only access: dryRun: true only, nothing is written. " + description, input: input, writes: false, background: background)
    }
    public var json: [String: Any] {
        ["name": name, "description": description, "inputSchema": input,
         "annotations": ["readOnlyHint": !writes, "destructiveHint": destructive, "openWorldHint": false]]
    }
}

public enum MCPTools {
    public static let protocolVersion = "2025-11-25"
    /// The tools a client is offered: with read-only access, those that only read, and proposals of the ones that write.
    public static func listed(readOnly: Bool) -> [MCPTool] {
        all.compactMap { !readOnly || !$0.writes ? $0 : $0.proposes ? $0.proposalOnly : nil }
    }
    public static var all: [MCPTool] {
        let string = MCPSchema.string(), bool = MCPSchema.bool
        let ref: [String: Any] = ["catalogId": string, "assetId": string]
        func args(_ extra: [String: Any] = [:], required: [String] = []) -> [String: Any] {
            MCPSchema.object(ref.merging(extra) { _, b in b }, required: ["assetId"] + required)
        }
        func tool(_ name: String, _ description: String, _ input: [String: Any], writes: Bool = false, background: Bool = false) -> MCPTool {
            var input = input
            if background, var properties = input["properties"] as? [String: Any] {
                properties["background"] = bool; input["properties"] = properties
            }
            return MCPTool(name: name, description: description, input: input, writes: writes, background: background)
        }
        return [
            tool("catalog_query", "List/search the open catalog. Returns catalogId and paginated summaries. Every tool takes an optional catalogId: when given, the call fails with catalog_changed if another catalog is open. Search also matches place, camera, lens and photographer names; camera:, lens:, keyword:, tag:, place: and artist: followed by a name (quoted if it has spaces) match it exactly; exposure terms filter settings: f/1.4, f<2.8, 35mm, 70-200mm, 1/250s, <1/1000, 2s, iso3200, iso>=6400, +0.7ev. Tags match whole labels, case-insensitively. hasLocation false finds photos without GPS coordinates; location:set, location:file and location:none match where a location came from. Trash defaults to false.", MCPSchema.object([
                "catalogId": string, "search": string, "trash": bool, "minimumRating": MCPSchema.number(0, 5, integer: true),
                "review": MCPSchema.string(ReviewState.allCases.map(\.rawValue)), "kind": string, "captureDay": string,
                "tags": MCPSchema.object(["all": MCPSchema.array(string, max: 50), "any": MCPSchema.array(string, max: 50), "none": MCPSchema.array(string, max: 50), "source": MCPSchema.string(["keywords", "suggested", "both"])]),
                "hasLocation": bool, "cursor": string, "limit": MCPSchema.number(1, 100, integer: true)
            ])),
            tool("catalog_context", "What the user is looking at in the open catalog: view (library or develop), activeAssetId (the photo open in Develop, else the Library's focused photo; null when none) and the selected photos in display order, as Photo menu commands see them (a collapsed group counts all its photos). With nothing selected, selectedCount is 0 and selectedIds is empty. Page with offset and limit (default 100); nextOffset is present while more remain. Use it to resolve requests such as \"the photos I selected\".", MCPSchema.object([
                "catalogId": string, "offset": MCPSchema.number(0, 1_000_000, integer: true), "limit": MCPSchema.number(1, 500, integer: true)
            ])),
            tool("catalog_import", "Import absolute image/document paths or folders, referencing originals. Returns per-file outcomes; recursion defaults to true. Existing entries are retained, including Trash. Requests time out after 10 minutes: for large imports pass background: true and follow the returned jobId with job_status.", MCPSchema.object([
                "catalogId": string, "paths": MCPSchema.array(string, min: 1, max: 100), "recursive": bool
            ], required: ["paths"]), writes: true, background: true),
            tool("catalog_inspect", "Read metadata, physical paths and capture settings (ISO, shutter, aperture, focal length, exposure bias). Optional fields: sourceProperties, sourceXMP, currentXMP, history. XMP is returned in full only when requested.", args([
                "fields": MCPSchema.array(MCPSchema.string(["sourceProperties", "sourceXMP", "currentXMP", "history"]), max: 4)
            ])),
            tool("catalog_thumbnails", "Look at up to 50 photos at once from the catalog's stored thumbnails (JPEG, at most 640 px), without developing the originals. A thumbnail shows the photo's edits once the Library has rendered them, else the camera's own preview. Each item carries what is needed to decide and write back: capture time, camera, lens, metadata (rating, review, label, keywords, location), place, suggested tags and the metadata revision for catalog_update. sheet: true returns one contact sheet instead, each cell numbered with the item's sheetIndex, for comparing photos side by side (bursts, similar frames).", MCPSchema.object([
                "catalogId": string, "assetIds": MCPSchema.array(string, min: 1, max: 50),
                "maxEdge": MCPSchema.number(128, 640, integer: true), "sheet": bool
            ], required: ["assetIds"])),
            tool("catalog_update", "Change the metadata of up to 500 photos in one call: title, caption, keywords, rating, review (accepted/rejected), color label, capture day and GPS location (marked as set in Ceviche, as when placed on the map by hand; reads report it as source set rather than file). Each item is checked on its own and reported as updated, unchanged, revision_conflict or failed; the valid ones are written together and become one Undo step in the app. expectedRevision (from catalog_thumbnails or catalog_inspect) is optional; when given, a photo changed since is left alone. set replaces the fields it names (null clears label or location) and takes the metadata object catalog_thumbnails returns as is: keywords as an array (a comma-separated string also works), and location.source, which is output-only and ignored; addKeywords and removeKeywords change single keywords, case-insensitively, keeping the rest. Changes other than rating, review and label are also kept in each photo's History. dryRun: true reports what would change without writing. Does not modify originals or sidecars.", MCPSchema.object([
                "catalogId": string, "dryRun": bool,
                "items": MCPSchema.array(MCPSchema.object([
                    "assetId": string, "expectedRevision": string, "set": metadata,
                    "addKeywords": MCPSchema.array(string, max: 50), "removeKeywords": MCPSchema.array(string, max: 50)
                ], required: ["assetId"]), min: 1, max: 500)
            ], required: ["items"]), writes: true),
            tool("catalog_trash", "Move explicit asset IDs into catalog Trash. Original files, edits and history remain intact. No permanent deletion exists in this interface.", MCPSchema.object([
                "catalogId": string, "assetIds": MCPSchema.array(string, min: 1, max: 100)
            ], required: ["assetIds"]), writes: true),
            tool("catalog_restore", "Recover explicit asset IDs from catalog Trash.", MCPSchema.object([
                "catalogId": string, "assetIds": MCPSchema.array(string, min: 1, max: 100)
            ], required: ["assetIds"]), writes: true),
            tool("photo_read", "Observe numeric editing state and an SDR image of the same revision with its statistics (histogram, percentiles, clipping, saturation). includePreview defaults to true. Embedded mask/ICC bytes remain server-side.", args(["includePreview": bool, "maxEdge": MCPSchema.number(64, 4096, integer: true)])),
            tool("photo_apply", "Atomically apply sparse typed edits. Objects merge; arrays replace; omitted fields stay unchanged. schemaVersion is 1. changes.applyFiles applies preset, camera profile or LUT files by absolute path before the patch. addMasks kinds Subject, Background, Sky and Object generate their selection in the app (Object needs point). changes.cropPixels crops in pixels (top-left origin) of the photo as photo_read's uncroppedSize gives it. Validate locally with d.json or retrieve photo_docs. Returns committed state and revision. dryRun: true validates and renders the candidate (preview, statistics, candidateRevision) without committing; maxEdge and scope shape that preview. No filesystem operations.", args([
                "expectedRevision": string, "schemaVersion": ["type": "string", "const": MCPEditSchema.version], "changes": ["type": "object"],
                "dryRun": bool, "maxEdge": MCPSchema.number(64, 4096, integer: true), "scope": MCPSchema.array(MCPSchema.number(0, 1), min: 4, max: 4)
            ], required: ["expectedRevision", "schemaVersion", "changes"]), writes: true),
            tool("photo_preview", "Render from source at scale <= 1, then fit maxEdge; never enlarge. scope is normalized [x,y,width,height], top-left, after crop/rotation. Returns inline SDR image, actual pixel mapping and statistics (per-channel histogram, percentiles, clipping, saturation) of the rendered region. includeImage: false returns statistics only. mask (a mask UUID) renders that mask's selection instead: maskStyle matte (default; white = full effect, coverage reported) or overlay (photo with the selection tinted red).", args([
                "revision": string, "scale": MCPSchema.number(0.000001, 1), "maxEdge": MCPSchema.number(64, 4096, integer: true),
                "scope": MCPSchema.array(MCPSchema.number(0, 1), min: 4, max: 4), "rendition": MCPSchema.string(["edited", "asShot"]), "includeImage": bool,
                "mask": MCPSchema.uuid, "maskStyle": MCPSchema.string(["matte", "overlay"])
            ])),
            tool("photo_convert", "Convert points between preview coordinates (normalized, top-left origin, after crop/rotation, as used by photo_preview scope and statistics) and mask coordinates (normalized source, bottom-left origin, before geometry, as used by masks, brush strokes, retouch and Object points), using the photo's current geometry.", args([
                "points": MCPSchema.array(MCPSchema.array(MCPSchema.number(-10, 10), min: 2, max: 2), min: 1, max: 1000), "from": MCPSchema.string(["preview", "mask"])
            ], required: ["points", "from"])),
            tool("photo_restore", "Restore an earlier development or metadata entry from this photo's history (ids from catalog_inspect fields: history) as a new revision. Nothing is deleted; the current state stays in history. When the photo can't be read (its edits are damaged or the original changed), its revision can't be checked and the call fails with revision_unavailable; recover: true then restores the entry without that check.", args([
                "expectedRevision": string, "historyId": string, "recover": bool
            ], required: ["expectedRevision", "historyId"]), writes: true),
            tool("photo_export", "Export a pinned revision to a NEW absolute path. Existing files and catalog contents cannot be overwritten. Size is original or an aspect-preserving fit box; upscaling defaults to false. bitsPerChannel is per developed RGB channel (defaults to the format’s highest depth). WebP and JPEG XL default to lossless; set lossless false to use quality. rendition asShot exports the as-shot development with the current crop/rotation for comparisons. aiDenoise (0–100) runs NAFNet denoise on the finished image at the export size, as the last step before encoding. includeMetadata (default true) keeps capture metadata; GPS coordinates are left out unless includeLocation is true, as in the app's Export. background: true returns a jobId at once; follow it with job_status.", args([
                "revision": string, "path": string, "format": MCPSchema.string(ExportFormat.allCases.map(\.rawValue)), "rendition": MCPSchema.string(["edited", "asShot"]),
                "bitsPerChannel": MCPSchema.number(8, 32, integer: true), "hdr": bool, "hdrEncoding": MCPSchema.string(HDREncoding.allCases.map(\.rawValue)), "quality": MCPSchema.number(0, 1),
                "lossless": bool,
                "profile": MCPSchema.string(RGBProfile.allCases.filter { $0 != .custom }.map(\.rawValue)), "preserveAlpha": bool, "includeMetadata": bool, "includeLocation": bool, "aiDenoise": MCPSchema.number(0, 100),
                "size": MCPSchema.object(["width": MCPSchema.number(1, 32768, integer: true), "height": MCPSchema.number(1, 32768, integer: true), "allowUpscale": bool], required: ["width", "height"])
            ], required: ["revision", "path", "format"]), writes: true, background: true),
            tool("job_status", "Status of a job started with background: true: running, done, failed or cancelled, with the tool's result once it ends. Finished jobs are kept for an hour.", MCPSchema.object([
                "jobId": string
            ], required: ["jobId"])),
            tool("job_cancel", "Cancel a running job. An import keeps the photos imported so far.", MCPSchema.object([
                "jobId": string
            ], required: ["jobId"]), writes: true),
            tool("photo_looks", "List the user's look library: develop presets (.xmp, .lrtemplate), camera profiles (.dcp) and LUTs (.cube or Hald .png) with absolute paths, as folders. Apply any of them, or any other readable file of those kinds, through photo_apply changes.applyFiles.", MCPSchema.object([
                "kind": MCPSchema.string(LookKind.allCases.map(\.rawValue))
            ])),
            tool("photo_docs", "Retrieve only the requested control schema, the complete d.json, or installed export capabilities. Numeric names match photo_read. Harness validation is optional; the handler always validates.", MCPSchema.object([
                "section": MCPSchema.string(["index", "global", "masks", "changes", "d.json", "export"]), "control": string
            ]))
        ]
    }
    public static var metadata: [String: Any] {
        MCPSchema.object(["title": MCPSchema.string(), "caption": ["type": "string", "maxLength": 65536],
                          "keywords": ["anyOf": [MCPSchema.array(MCPSchema.string(), max: 1000), MCPSchema.string()]],
                          "rating": MCPSchema.number(0, 5, integer: true), "review": MCPSchema.string(ReviewState.allCases.map(\.rawValue)),
                          "label": MCPSchema.nullable(MCPSchema.string(CatalogLabel.allCases.map(\.rawValue))), "captureDay": MCPSchema.string(),
                          // source is output-only and ignored, so metadata read from another photo can be written back as is.
                          "location": MCPSchema.nullable(MCPSchema.object(["latitude": MCPSchema.number(-90, 90), "longitude": MCPSchema.number(-180, 180),
                                                                            "source": MCPSchema.string(["file", "set"])], required: ["latitude", "longitude"]))])
    }
    public static func result(_ object: [String: Any], images: [Data] = [], mimeType: String = "image/png") throws -> [String: Any] {
        var content: [[String: Any]] = [["type": "text", "text": String(decoding: try MCPSchema.data(object), as: UTF8.self)]]
        content += images.map { ["type": "image", "mimeType": mimeType, "data": $0.base64EncodedString()] }
        return ["content": content, "structuredContent": object, "isError": false]
    }
    public static func failure(_ error: Error) -> [String: Any] {
        let failure = error as? MCPFailure
            ?? (error is CancellationError ? MCPFailure("cancelled", "The request was cancelled.") : MCPFailure("operation_failed", error.localizedDescription))
        return ["isError": true, "structuredContent": ["error": failure.json], "content": [["type": "text", "text": failure.errorDescription ?? failure.message]]]
    }
}

/// One catalog_update item applied to a photo's metadata, apart from the store so it can be checked on its own.
public enum MCPMetadataPatch {
    /// The metadata as the client sees it: location as one object, label and location null when unset.
    public static func json(_ metadata: CatalogMetadata) -> [String: Any] {
        var result: [String: Any] = ["title": metadata.title, "caption": metadata.caption, "keywords": keywords(metadata.keywords),
                                     "rating": metadata.rating, "review": metadata.review.rawValue, "captureDay": metadata.captureDay,
                                     "label": metadata.label?.rawValue ?? NSNull(), "location": NSNull()]
        if let latitude = metadata.latitude, let longitude = metadata.longitude { result["location"] = location(latitude, longitude, metadata.locationSource) }
        return result
    }
    /// A location with where it came from: `file` (the camera's GPS or a sidecar) or `set` (in Ceviche, by hand or by a client).
    public static func location(_ latitude: Double, _ longitude: Double, _ source: CatalogLocationSource?) -> [String: Any] {
        ["latitude": latitude, "longitude": longitude, "source": source == nil ? "file" : "set"]
    }
    public static func apply(_ item: [String: Any], to metadata: CatalogMetadata) throws -> CatalogMetadata {
        var value = metadata
        let set = item["set"] as? [String: Any] ?? [:]
        if let title = set["title"] as? String { value.title = title }
        if let caption = set["caption"] as? String { value.caption = caption }
        if let words = set["keywords"] as? String { value.keywords = keywords(words).joined(separator: ", ") }
        if let words = set["keywords"] as? [String] {
            let words = words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if words.contains(where: { $0.contains(",") }) { throw MCPFailure("invalid_value", "A keyword can't contain a comma.", path: "set.keywords") }
            value.keywords = words.joined(separator: ", ")
        }
        if let rating = set["rating"] as? Int { value.rating = rating }
        if let review = set["review"] as? String { value.review = ReviewState(rawValue: review)! }
        if let label = set["label"] { value.label = (label as? String).flatMap(CatalogLabel.init(rawValue:)) }
        if let day = set["captureDay"] as? String { value.captureDay = day }
        if let location = set["location"] {
            let point = location as? [String: Any]
            value.latitude = (point?["latitude"] as? NSNumber)?.doubleValue; value.longitude = (point?["longitude"] as? NSNumber)?.doubleValue
            // A location written here is marked as set in Ceviche, like one placed on the map by hand.
            value.locationSource = point == nil ? nil : .assigned
        }
        let removed = Set((item["removeKeywords"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        var words = keywords(value.keywords).filter { !removed.contains($0.lowercased()) }
        for word in item["addKeywords"] as? [String] ?? [] {
            let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
            if word.contains(",") { throw MCPFailure("invalid_value", "A keyword can't contain a comma.", path: "addKeywords") }
            guard !word.isEmpty, !words.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) else { continue }
            words.append(word)
        }
        if !removed.isEmpty || item["addKeywords"] != nil { value.keywords = words.joined(separator: ", ") }
        do { return try value.validated() } catch { throw MCPFailure("invalid_value", error.localizedDescription, path: "set") }
    }
    /// The fields whose values differ, each with its old and new value.
    public static func changes(from old: CatalogMetadata, to new: CatalogMetadata) -> [String: Any] {
        let before = json(old), after = json(new)
        var result: [String: Any] = [:]
        for (key, value) in after where !NSDictionary(dictionary: ["v": value]).isEqual(to: ["v": before[key] ?? NSNull()]) {
            result[key] = ["from": before[key] ?? NSNull(), "to": value]
        }
        return result
    }
    static func keywords(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
