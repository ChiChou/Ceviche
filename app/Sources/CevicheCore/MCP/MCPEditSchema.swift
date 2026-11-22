import Foundation
import CoreFoundation
import CryptoKit

public struct MCPFailure: Error, LocalizedError {
    public let code: String
    public let path: String
    public let message: String
    public init(_ code: String, _ message: String, path: String = "") {
        self.code = code; self.path = path; self.message = message
    }
    public var errorDescription: String? { path.isEmpty ? message : "\(path): \(message)" }
    public var json: [String: Any] { ["code": code, "path": path, "message": message] }
}

/// The same schema definitions power harness documentation and authoritative MCP validation.
/// This validator intentionally implements only the JSON Schema keywords emitted here.
public enum MCPSchema {
    public static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "additionalProperties": false, "required": required.sorted()]
    }
    public static func number(_ min: Double, _ max: Double, integer: Bool = false) -> [String: Any] {
        ["type": integer ? "integer" : "number", "minimum": min, "maximum": max]
    }
    public static func string(_ values: [String]? = nil) -> [String: Any] {
        var result: [String: Any] = ["type": "string", "maxLength": 4096]
        if let values { result["enum"] = values }; return result
    }
    public static let bool: [String: Any] = ["type": "boolean"]
    public static let uuid: [String: Any] = ["type": "string", "format": "uuid"]
    public static func array(_ items: [String: Any], min: Int = 0, max: Int = 1000) -> [String: Any] {
        ["type": "array", "items": items, "minItems": min, "maxItems": max]
    }
    public static func nullable(_ schema: [String: Any]) -> [String: Any] {
        ["anyOf": [schema, ["type": "null"]]]
    }
    public static func validate(_ value: Any, against schema: [String: Any], path: String = "$", depth: Int = 0) throws {
        guard depth < 64 else { throw MCPFailure("invalid_value", "Nesting limit exceeded.", path: path) }
        if let alternatives = schema["anyOf"] as? [[String: Any]] {
            if alternatives.contains(where: { (try? validate(value, against: $0, path: path, depth: depth + 1)) != nil }) { return }
            throw MCPFailure("invalid_value", "Value does not match an allowed type or range.", path: path)
        }
        func fail(_ message: String) -> MCPFailure { MCPFailure("invalid_value", message, path: path) }
        switch schema["type"] as? String {
        case "object":
            guard let object = value as? [String: Any] else { throw fail("Expected an object.") }
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for key in schema["required"] as? [String] ?? [] where object[key] == nil { throw fail("Missing required field \(key).") }
            for (key, child) in object {
                if let names = schema["propertyNames"] as? [String: Any] { try validate(key, against: names, path: path + "." + key, depth: depth + 1) }
                if let childSchema = properties[key] as? [String: Any] ?? schema["additionalProperties"] as? [String: Any] {
                    try validate(child, against: childSchema, path: path + "." + key, depth: depth + 1)
                } else if schema["additionalProperties"] as? Bool == false {
                    throw MCPFailure("unknown_field", "Unknown field.", path: path + "." + key)
                }
            }
            if let max = schema["maxProperties"] as? Int, object.count > max { throw fail("Too many fields (maximum \(max)).") }
        case "array":
            guard let array = value as? [Any] else { throw fail("Expected an array.") }
            let min = schema["minItems"] as? Int ?? 0, max = schema["maxItems"] as? Int ?? Int.max
            guard (min...max).contains(array.count) else { throw fail("Expected \(min)…\(max) items; received \(array.count).") }
            if let child = schema["items"] as? [String: Any] {
                for (index, value) in array.enumerated() { try validate(value, against: child, path: "\(path)[\(index)]", depth: depth + 1) }
            }
        case "number", "integer":
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { throw fail("Expected a finite number.") }
            let n = number.doubleValue
            if schema["type"] as? String == "integer", n.rounded() != n { throw fail("Expected an integer; received \(n).") }
            let min = (schema["minimum"] as? NSNumber)?.doubleValue ?? -.greatestFiniteMagnitude
            let max = (schema["maximum"] as? NSNumber)?.doubleValue ?? .greatestFiniteMagnitude
            guard (min...max).contains(n) else { throw fail("Expected \(min)…\(max); received \(n).") }
        case "boolean":
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw fail("Expected a boolean.") }
        case "string":
            guard let string = value as? String else { throw fail("Expected a string.") }
            if let max = schema["maxLength"] as? Int, string.count > max { throw fail("String exceeds \(max) characters.") }
            if let options = schema["enum"] as? [String], !options.contains(string) { throw fail("Expected one of: " + options.joined(separator: ", ")) }
            if schema["format"] as? String == "uuid", UUID(uuidString: string) == nil { throw fail("Expected a UUID.") }
        case "null": if !(value is NSNull) { throw fail("Expected null.") }
        default: break
        }
        if let constant = schema["const"], !equal(value, constant) { throw fail("Unexpected schema version or constant.") }
    }
    public static func data(_ value: Any, pretty: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: pretty ? [.sortedKeys, .prettyPrinted, .fragmentsAllowed] : [.sortedKeys, .fragmentsAllowed])
    }
    public static func encoded<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }
    public static func equal(_ a: Any, _ b: Any) -> Bool { (try? data(a)) == (try? data(b)) }
    public static func merge(_ base: [String: Any], _ patch: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in patch {
            if let object = value as? [String: Any], let existing = base[key] as? [String: Any] { result[key] = merge(existing, object) }
            else { result[key] = value }
        }
        return result
    }
}

public enum MCPEditSchema {
    public static let version = "1"
    private static let point = MCPSchema.object(["x": MCPSchema.number(0, 1), "y": MCPSchema.number(0, 1)], required: ["x", "y"])
    public static var pixels: [String: Any] {
        var p: [String: Any] = [:]
        for key in ["contrast", "highlights", "shadows", "whites", "blacks", "vibrance", "saturation", "clarity", "texture", "dehaze", "sharpness", "warmth"] { p[key] = MCPSchema.number(-100, 100) }
        for key in ["noiseReduction", "sharpenDetail", "sharpenMasking", "vignette", "blur", "curveSaturation", "colorNoiseDetail", "colorNoiseSmoothness"] { p[key] = MCPSchema.number(0, 100) }
        p["exposure"] = MCPSchema.number(-5, 5); p["tint"] = MCPSchema.number(-150, 150)
        p["sharpenRadius"] = MCPSchema.number(0.5, 3)
        p["vignetteRadius"] = MCPSchema.number(0, 1); p["vignetteSoftness"] = MCPSchema.number(0, 1)
        p["colorNoiseReduction"] = MCPSchema.nullable(MCPSchema.number(0, 100))
        p["monochrome"] = MCPSchema.bool
        p["disabledSections"] = MCPSchema.array(MCPSchema.string(AdjustmentGroup.allCases.map(\.rawValue)), max: 32)
        // Curve x and y are sRGB-encoded to 1 (SDR white), then 1 + stops above white for HDR (up to 11).
        let curvePoint = MCPSchema.object(["x": MCPSchema.number(0, ToneCurve.maximumInput), "y": MCPSchema.number(0, ToneCurve.maximumInput)], required: ["x", "y"])
        for key in ["curve", "redCurve", "greenCurve", "blueCurve"] { p[key] = MCPSchema.array(curvePoint, min: 2, max: 1001) }
        p["selectiveColors"] = MCPSchema.array(MCPSchema.object([
            "hue": MCPSchema.number(-60, 60), "saturation": MCPSchema.number(-100, 100),
            "luminance": MCPSchema.number(-100, 100), "range": MCPSchema.number(0.2, 2)
        ], required: ["hue", "saturation", "luminance", "range"]), min: 8, max: 8)
        p["parametricCurve"] = MCPSchema.object(Dictionary(uniqueKeysWithValues:
            ["shadows", "darks", "lights", "highlights"].map { ($0, MCPSchema.number(-100, 100) as Any) } +
            ["shadowSplit", "midtoneSplit", "highlightSplit"].map { ($0, MCPSchema.number(1, 99) as Any) }))
        var toning: [String: Any] = ["balance": MCPSchema.number(-100, 100), "blending": MCPSchema.number(0, 100)]
        for area in ["shadow", "midtone", "highlight", "global"] {
            toning[area + "Hue"] = MCPSchema.number(0, 360); toning[area + "Saturation"] = MCPSchema.number(0, 100)
            toning[area + "Luminance"] = MCPSchema.number(-100, 100)
        }
        p["splitToning"] = MCPSchema.object(toning)
        p["calibration"] = MCPSchema.object(Dictionary(uniqueKeysWithValues: ["shadowTint", "redHue", "redSaturation", "greenHue", "greenSaturation", "blueHue", "blueSaturation"].map { ($0, MCPSchema.number(-100, 100) as Any) }))
        p["blackWhiteMixer"] = MCPSchema.object(["values": MCPSchema.array(MCPSchema.number(-100, 100), min: 8, max: 8)])
        p["grain"] = MCPSchema.object(["amount": MCPSchema.number(0, 100), "size": MCPSchema.number(0, 100), "roughness": MCPSchema.number(0, 100), "seed": MCPSchema.number(0, Double(UInt32.max), integer: true)])
        let defringe = Dictionary(uniqueKeysWithValues: ["purpleAmount", "greenAmount", "purpleLow", "purpleHigh", "greenLow", "greenHigh"].map { ($0, MCPSchema.number(0, $0.hasSuffix("Amount") ? 20 : 100) as Any) })
        p["defringe"] = MCPSchema.object(defringe)
        p["postCropVignette"] = MCPSchema.object(Dictionary(uniqueKeysWithValues: ["amount", "roundness", "midpoint", "feather", "highlights"].map { ($0, MCPSchema.number(["amount", "roundness"].contains($0) ? -100 : 0, 100) as Any) }))
        var color: [String: Any] = ["id": MCPSchema.uuid, "variance": MCPSchema.number(-100, 100)]
        for key in ["hue", "saturation", "luminance", "range"] { color[key] = MCPSchema.number(0, 1) }
        for key in ["hueShift", "saturationShift", "luminanceShift"] { color[key] = MCPSchema.number(-1, 1) }
        for key in ["hueRange", "saturationRange", "luminanceRange"] { color[key] = MCPSchema.array(MCPSchema.number(0, 1), min: 4, max: 4) }
        p["pointColors"] = MCPSchema.array(MCPSchema.object(color, required: Array(color.keys)), max: 16)
        return MCPSchema.object(p)
    }
    public static var global: [String: Any] {
        var p = pixels["properties"] as! [String: Any]
        p["sharpness"] = MCPSchema.number(0, 100)
        p["temperature"] = MCPSchema.number(2000, 50000); p["quarterTurns"] = MCPSchema.number(0, 3, integer: true)
        p["neutralRAW"] = MCPSchema.bool
        p["lensCorrection"] = MCPSchema.bool
        p["luminanceNoiseDetail"] = MCPSchema.number(0, 100); p["luminanceNoiseContrast"] = MCPSchema.number(0, 100)
        // Profile and LUT tables are imported in the app; clients may adjust or remove them.
        p["cameraProfile"] = MCPSchema.nullable(MCPSchema.object(["amount": MCPSchema.number(0, 1), "enabled": MCPSchema.bool]))
        p["lut"] = MCPSchema.nullable(MCPSchema.object(["amount": MCPSchema.number(0, 1), "enabled": MCPSchema.bool, "space": MCPSchema.string(LUTColorSpace.allCases.map(\.rawValue))]))
        p["hdr"] = MCPSchema.object(["enabled": MCPSchema.bool, "headroom": MCPSchema.number(0, 10), "sdrExposure": MCPSchema.number(-5, 5)])
        p["geometry"] = MCPSchema.object([
            "transform": MCPSchema.object(["enabled": MCPSchema.bool, "vertical": MCPSchema.number(-100, 100), "horizontal": MCPSchema.number(-100, 100),
                "rotate": MCPSchema.number(-10, 10), "aspect": MCPSchema.number(-100, 100), "scale": MCPSchema.number(50, 150),
                "offsetX": MCPSchema.number(-100, 100), "offsetY": MCPSchema.number(-100, 100)]),
            "crop": MCPSchema.object(["x": MCPSchema.number(0, 1), "y": MCPSchema.number(0, 1), "width": MCPSchema.number(0.01, 1), "height": MCPSchema.number(0.01, 1)]),
            "aspect": MCPSchema.string(CropAspect.allCases.map(\.rawValue)), "portrait": MCPSchema.bool,
            "straighten": MCPSchema.number(-45, 45), "flipHorizontal": MCPSchema.bool, "flipVertical": MCPSchema.bool, "uprightMode": MCPSchema.string(UprightMode.allCases.map(\.rawValue)), "uprightEnabled": MCPSchema.bool, "constrainCrop": MCPSchema.bool,
            "guides": MCPSchema.array(MCPSchema.object(["id": MCPSchema.uuid, "axis": MCPSchema.string(GuideAxis.allCases.map(\.rawValue)), "start": point, "end": point], required: ["id", "axis", "start", "end"]), max: 4),
            "perspective": MCPSchema.nullable(["type": "object", "properties": ["corners": MCPSchema.array(point, max: 4), "proportion": ["type": "object"]], "required": ["corners"]])
        ])
        // Embedded ICC bytes and native selection rasters remain server-owned.
        p["colorProfile"] = MCPSchema.object(["preset": MCPSchema.string(RGBProfile.allCases.filter { $0 != .custom }.map(\.rawValue))], required: ["preset"])
        p["look"] = MCPSchema.nullable(MCPSchema.object(["name": ["type": "string", "maxLength": 200], "amount": MCPSchema.number(0, 2), "enabled": MCPSchema.bool, "adjustments": pixels]))
        p["retouch"] = MCPSchema.array(MCPSchema.object([
            "id": MCPSchema.uuid, "mode": MCPSchema.string(RetouchMode.allCases.map(\.rawValue)), "source": point,
            "points": MCPSchema.array(point, min: 1, max: 100000), "radius": MCPSchema.number(0.001, 0.25),
            "softness": MCPSchema.number(0, 1), "opacity": MCPSchema.number(0, 1), "exposure": MCPSchema.number(-2, 2), "enabled": MCPSchema.bool
        ], required: ["id", "mode", "source", "points", "radius", "softness", "opacity", "enabled"]), max: 200)
        return MCPSchema.object(p)
    }
    /// A component shape; generated kinds (Subject, Background, Sky, Object) are computed when added.
    public static var component: [String: Any] {
        MCPSchema.object([
            "id": MCPSchema.uuid, "operation": MCPSchema.string(MaskOperation.allCases.map(\.rawValue)), "enabled": MCPSchema.bool, "point": point,
            "selection": MCPSchema.object([
                "kind": MCPSchema.string(MaskKind.allCases.map(\.rawValue)), "inverted": MCPSchema.bool, "feather": MCPSchema.number(0, 0.5),
                "depthRange": MCPSchema.array(MCPSchema.number(0, 1), min: 2, max: 2), "scene": MCPSchema.string(SceneCategory.allCases.map(\.rawValue)),
                "start": point, "end": point, "rotation": MCPSchema.number(-360, 360), "color": MCPSchema.array(MCPSchema.number(0, 1), min: 3, max: 3), "tolerance": MCPSchema.number(0.001, 1),
                "strokes": MCPSchema.array(MCPSchema.object(["points": MCPSchema.array(point, max: 100000), "radius": MCPSchema.number(0.001, 0.5), "softness": MCPSchema.number(0, 1), "erase": MCPSchema.bool], required: ["points", "radius", "softness", "erase"]), max: 10000)
            ])
        ], required: ["id", "operation"])
    }
    public static var mask: [String: Any] {
        MCPSchema.object([
            "name": ["type": "string", "maxLength": 200], "enabled": MCPSchema.bool, "components": MCPSchema.array(component, max: 32),
            "opacity": MCPSchema.number(0, 1), "inverted": MCPSchema.bool, "baseInverted": MCPSchema.bool,
            "cutsOutBackground": MCPSchema.bool, "feather": MCPSchema.number(0, 0.5),
            "start": point, "end": point, "color": MCPSchema.array(MCPSchema.number(0, 1), min: 3, max: 3),
            "tolerance": MCPSchema.number(0.001, 1), "adjustments": pixels, "depthRange": MCPSchema.array(MCPSchema.number(0, 1), min: 2, max: 2),
            "strokes": MCPSchema.array(MCPSchema.object(["points": MCPSchema.array(point, max: 100000), "radius": MCPSchema.number(0.001, 0.5), "softness": MCPSchema.number(0, 1), "erase": MCPSchema.bool], required: ["points", "radius", "softness", "erase"]), max: 10000)
        ])
    }
    /// How the renderer evaluates each mask kind, in the words an agent needs to place one.
    public static let maskSemantics: [String: Any] = [
        "coordinates": "start, end and brush points are normalized to the oriented source image before crop/rotation, origin bottom-left, x as a fraction of width and y as a fraction of height. Preview scope and preview pixels use a top-left origin after geometry; without crop, rotation or upright, maskY = 1 - previewY.",
        "Linear gradient": "Full strength (white) at start, fading linearly to zero (black) at end, constant along the perpendicular. Pixels before start stay full strength and pixels past end stay zero. A top-of-frame sky gradient is start y=1.0, end at the horizon. feather blurs the ramp by feather × shorter side.",
        "Radial gradient": "An ellipse inscribed in the box spanned by start and end, full strength at the centre. feather works inward: strength is 1 inside (1 - 2 × feather) of the radius and falls to zero at the ellipse edge, so feather 0.5 is a cone from the centre and feather 0 is a hard ellipse. The box is clamped to the frame, so an ellipse cannot extend past the edges.",
        "Brush": "strokes are painted onto an empty (black) mask. Each stroke stamps circles of radius × shorter side along its points; softness is the fraction of the radius that fades (0 = hard edge, 1 = fades from the centre). erase: true subtracts. Use several points for a path; one point paints a dot. feather blurs the result.",
        "Color range": "Selects pixels whose 8-bit sRGB colour, measured on the globally developed image before any mask, lies near color (an [r,g,b] array in 0…1). The distance is Euclidean RGB distance divided by √3; strength is 1 up to tolerance / 2 and smooth-steps to zero at tolerance. Sample color from an photo_preview statistics meanColor of a scope over the target, after global edits are in place. Very dark regions are hard to separate by colour.",
        "Subject, Background, Sky, Object": "Generated selections. addMasks with one of these kinds computes the selection in the app: Subject and Background use Vision foreground segmentation (Background is the inverse), Sky uses the camera's embedded sky matte or the installed sky model, Object grows from the required point (mask coordinates) with iterative segmentation. The raster stays server-side (rasterPresent) and local adjustments, opacity, inversion and feather apply as usual. Preview the result with photo_preview mask=<id>.",
        "Depth": "Generated selection from Depth Anything V2 Small (relative depth, not metres). The stored raster is depth normalized so 0 is the farthest and 1 the nearest 1% of the frame; depthRange [far, near] keeps that band, with tolerance as the width of the soft shoulders. The default [0.5, 1] selects the nearer half; [0, 0.3] selects the background.",
        "Scene": "Generated selection from a DETR panoptic model; addMasks needs scene (Vegetation, Water, Mountains, Buildings, Ground, People, Sky). The coarse class map is upsampled along the photo's edges. Sky here is an Apache-licensed alternative to the Sky kind.",
        "applyFiles": "changes.applyFiles lists absolute paths of preset (.xmp, .lrtemplate), camera profile (.dcp) or LUT (.cube or Hald .png) files, applied in order before the sparse global and mask patches, exactly as Photo → Apply Look File… does. photo_looks lists the files in the user's look library; any readable path works.",
        "components": "A mask's components refine its base selection in order: Add unions, Subtract removes, Intersect keeps only the overlap. Each has an id, operation, enabled flag and a selection (any kind, geometric fields as for masks; generated kinds use point and are computed when added). The components array replaces the list but merges by id, so a listed existing component keeps its stored raster. Example: a Sky mask with a Subtract Linear gradient keeps the sky treatment off the horizon band.",
        "stacking": "Masks are applied in maskOrder, each on the output of the previous one, so two masks over the same pixels add their exposure in EV. inverted flips the selection; opacity scales it. Preview a mask with photo_preview mask=<id> before relying on it."
    ]
    /// Lessons that keep automated edits natural; returned with the docs index.
    public static let editingAdvice: [String] = [
        "Read statistics before and after each apply. Mean luminance 0.18–0.35 for a normally exposed frame; black clipping above 0.05 or white clipping above 0.01 usually means an overdone lift or cut.",
        "Keep meanSaturation below roughly 0.35 for landscapes and raise colour with vibrance (protects already saturated colours) before saturation.",
        "clarity and sharpness amplify noise and produce blotchy posterization in regions lifted by several EV; keep them at 0 there and apply clarity through a mask on well-exposed areas only.",
        "Exposure is multiplicative: a pixel that is near black stays near black after +3 EV. Lift deep shadows with shadows and a tone curve first, then exposure masks.",
        "Prefer long, gentle gradients: a short ramp across a uniformly dark region reads as a visible band."
    ]
    public static var changes: [String: Any] {
        var newMask = mask["properties"] as! [String: Any]
        newMask["id"] = MCPSchema.uuid
        newMask["kind"] = MCPSchema.string(MaskKind.allCases.map(\.rawValue))
        // Object selections grow from a seed point in mask coordinates; other kinds ignore it.
        newMask["point"] = point
        newMask["scene"] = MCPSchema.string(SceneCategory.allCases.map(\.rawValue))
        return MCPSchema.object([
            "applyFiles": MCPSchema.array(MCPSchema.object(["path": MCPSchema.string()], required: ["path"]), max: 10),
            "global": global,
            "masks": ["type": "object", "propertyNames": MCPSchema.uuid, "additionalProperties": mask, "maxProperties": 100],
            "addMasks": MCPSchema.array(MCPSchema.object(newMask, required: ["id", "kind"]), max: 100),
            "removeMasks": MCPSchema.array(MCPSchema.uuid, max: 100),
            "maskOrder": MCPSchema.array(MCPSchema.uuid, max: 100)
        ])
    }
    public static var document: [String: Any] {
        var result = MCPSchema.object([
            "catalogId": MCPSchema.string(), "assetId": MCPSchema.string(), "expectedRevision": MCPSchema.string(),
            "schemaVersion": ["type": "string", "const": version], "changes": changes,
            "dryRun": MCPSchema.bool, "maxEdge": MCPSchema.number(64, 4096, integer: true), "scope": MCPSchema.array(MCPSchema.number(0, 1), min: 4, max: 4)
        ], required: ["catalogId", "assetId", "expectedRevision", "schemaVersion", "changes"])
        result["$schema"] = "https://json-schema.org/draft/2020-12/schema"
        result["title"] = "Ceviche photo_apply v1"
        result["description"] = "Sparse edits. Objects merge, arrays replace, omitted fields remain unchanged. Masks use normalized source coordinates before geometry; crop uses normalized coordinates after rotation/upright. Both have a bottom-left origin. Cross-field and image capability checks run in the app."
        return result
    }
    /// Kinds whose selection is computed by the app (Vision or a sky model) rather than described geometrically.
    public static let generatedKinds: [MaskKind] = [.subject, .background, .sky, .object, .depth, .scene]
    /// New masks in `changes` whose rasters must be generated before `apply`, with their seed points.
    public static func generatedAdditions(_ changes: [String: Any], existing: Adjustments = Adjustments()) -> [(id: String, kind: MaskKind, point: MaskPoint?, scene: SceneCategory?)] {
        func point(_ object: [String: Any]) -> MaskPoint? {
            (object["point"] as? [String: Any]).flatMap { p in (p["x"] as? Double).flatMap { x in (p["y"] as? Double).map { MaskPoint(x: x, y: $0) } } }
        }
        func scene(_ object: [String: Any]) -> SceneCategory? { (object["scene"] as? String).flatMap(SceneCategory.init(rawValue:)) }
        let known = Set(existing.masks.flatMap { $0.components.map { $0.id.uuidString.lowercased() } })
        func components(_ object: [String: Any]) -> [(id: String, kind: MaskKind, point: MaskPoint?, scene: SceneCategory?)] {
            (object["components"] as? [[String: Any]] ?? []).compactMap { component in
                guard let id = component["id"] as? String, !known.contains(id.lowercased()),
                      let kind = ((component["selection"] as? [String: Any])?["kind"] as? String).flatMap(MaskKind.init(rawValue:)), generatedKinds.contains(kind) else { return nil }
                return (id, kind, point(component), scene((component["selection"] as? [String: Any]) ?? [:]))
            }
        }
        var result: [(id: String, kind: MaskKind, point: MaskPoint?, scene: SceneCategory?)] = []
        for addition in changes["addMasks"] as? [[String: Any]] ?? [] {
            if let id = addition["id"] as? String, let kind = (addition["kind"] as? String).flatMap(MaskKind.init(rawValue:)), generatedKinds.contains(kind) { result.append((id, kind, point(addition), scene(addition))) }
            result += components(addition)
        }
        for (_, update) in changes["masks"] as? [String: [String: Any]] ?? [:] { result += components(update) }
        return result
    }
    /// Components merge by ID: a listed component keeps its stored raster and takes the patch; an unlisted one is removed.
    private static func mergedComponents(_ patch: [[String: Any]], into existing: [[String: Any]], generated: [String: PhotoMask]) throws -> [[String: Any]] {
        try patch.map { var component = $0
            let id = (component["id"] as! String).lowercased()
            component.removeValue(forKey: "point")
            if let current = existing.first(where: { ($0["id"] as? String)?.lowercased() == id }) { return MCPSchema.merge(current, component) }
            guard let kind = ((component["selection"] as? [String: Any])?["kind"] as? String).flatMap(MaskKind.init(rawValue:)) else {
                throw MCPFailure("invalid_value", "New components need selection.kind.", path: "changes.masks.components." + id)
            }
            var selection = MaskSelection(kind: kind)
            if generatedKinds.contains(kind) {
                guard let mask = generated[id] else { throw MCPFailure("selection_required", "\(kind.rawValue) components need a generated selection.", path: "changes.masks.components." + id) }
                selection = mask.selection
            }
            let template = MaskComponent(operation: MaskOperation(rawValue: component["operation"] as! String)!, selection: selection)
            var encoded = try MCPSchema.encoded(template); encoded["id"] = id
            return MCPSchema.merge(encoded, component)
        }
    }
    /// `generated` supplies the selection raster for each AI mask in `addMasks`, keyed by lowercase ID.
    /// `applyFiles` entries are resolved by the caller (see `applyLookFile`) before the sparse patch merges.
    public static func apply(_ changes: [String: Any], to base: Adjustments, isRAW: Bool, generated: [String: PhotoMask] = [:]) throws -> Adjustments {
        try MCPSchema.validate(changes, against: Self.changes, path: "changes")
        let patch = changes["global"] as? [String: Any] ?? [:]
        if !isRAW, patch["temperature"] != nil || patch["neutralRAW"] != nil {
            throw MCPFailure("unsupported_control", "temperature and neutralRAW require a RAW image; use warmth for bitmap images.", path: "changes.global")
        }
        var object = MCPSchema.merge(try MCPSchema.encoded(base), patch)
        var masks = try base.masks.map { try MCPSchema.encoded($0) }
        let updates = changes["masks"] as? [String: [String: Any]] ?? [:]
        guard Set(updates.keys.map { $0.lowercased() }).count == updates.count else {
            throw MCPFailure("invalid_value", "Specify each mask ID only once, regardless of letter case.", path: "changes.masks")
        }
        for (id, var update) in updates {
            guard let index = masks.firstIndex(where: { ($0["id"] as? String)?.lowercased() == id.lowercased() }) else { throw MCPFailure("missing_mask", "Mask does not exist.", path: "changes.masks." + id) }
            if let components = update["components"] as? [[String: Any]] {
                update["components"] = try mergedComponents(components, into: masks[index]["components"] as? [[String: Any]] ?? [], generated: generated)
            }
            masks[index] = MCPSchema.merge(masks[index], update)
        }
        for var addition in changes["addMasks"] as? [[String: Any]] ?? [] {
            let kind = MaskKind(rawValue: addition["kind"] as! String)!
            let id = (addition["id"] as! String).lowercased()
            addition.removeValue(forKey: "point")
            if let components = addition["components"] as? [[String: Any]] { addition["components"] = try mergedComponents(components, into: [], generated: generated) }
            var template = PhotoMask(kind: kind)
            if generatedKinds.contains(kind) {
                guard let selection = generated[id] else { throw MCPFailure("selection_required", "\(kind.rawValue) masks need a generated selection.", path: "changes.addMasks") }
                template = selection; template.id = UUID(uuidString: id)!
                addition.removeValue(forKey: "kind")
            }
            masks.append(MCPSchema.merge(try MCPSchema.encoded(template), addition))
        }
        for id in changes["removeMasks"] as? [String] ?? [] {
            guard let index = masks.firstIndex(where: { ($0["id"] as? String)?.lowercased() == id.lowercased() }) else { throw MCPFailure("missing_mask", "Mask does not exist.", path: "changes.removeMasks") }
            masks.remove(at: index)
        }
        if let order = changes["maskOrder"] as? [String] {
            let ids = masks.map { ($0["id"] as! String).lowercased() }
            guard order.count == ids.count, Set(order.map { $0.lowercased() }) == Set(ids) else { throw MCPFailure("invalid_value", "maskOrder must contain each mask exactly once.", path: "changes.maskOrder") }
            masks = order.map { id in masks.first { ($0["id"] as! String).lowercased() == id.lowercased() }! }
        }
        object["masks"] = masks
        do { return try JSONDecoder().decode(Adjustments.self, from: MCPSchema.data(object)) }
        catch { throw MCPFailure("invalid_recipe", error.localizedDescription, path: "changes") }
    }
    /// Stable revision includes hidden payloads and metadata, never just the visible summary.
    public static func revision(_ settings: Adjustments, metadata: CatalogMetadata) throws -> String {
        let object: [String: Any] = ["settings": normalized(try MCPSchema.encoded(settings)), "metadata": try MCPSchema.encoded(metadata)]
        return SHA256.hash(data: try MCPSchema.data(object)).map { String(format: "%02x", $0) }.joined()
    }
    private static func normalized(_ value: Any) -> Any {
        if var object = value as? [String: Any] {
            for (key, child) in object { object[key] = key == "disabledSections" ? (child as? [String] ?? []).sorted() : normalized(child) }
            return object
        }
        if let array = value as? [Any] { return array.map(normalized) }; return value
    }
    /// Applies a preset (.xmp/.lrtemplate), camera profile (.dcp) or LUT (.cube or Hald .png) file to a recipe the way
    /// the Photo menu does, keeping an existing profile or LUT amount. Returns compatibility warnings.
    public static func applyLookFile(_ url: URL, to base: Adjustments, info: ImageInfo, resources: ResourceStorage = .shared) throws -> (Adjustments, [String]) {
        guard FileManager.default.fileExists(atPath: url.path) else { throw MCPFailure("missing_file", "No file at this path.", path: "changes.applyFiles") }
        guard let kind = LookKind(file: url) else { throw MCPFailure("unsupported_look", "Use a .xmp or .lrtemplate preset, a .dcp camera profile or a .cube or Hald .png LUT.", path: "changes.applyFiles") }
        do {
            switch kind {
            case .presets:
                return try DevelopPreset.apply(url, to: base, defaults: info.defaults, profiles: info.profileResolver)
            case .profiles:
                var profile = try CameraProfile(dcp: url)
                if let current = base.cameraProfile { profile.amount = current.amount }
                var next = base; next.cameraProfile = profile
                return (next, info.isRAW ? [] : ["Camera profiles apply only to RAW photos."])
            case .luts:
                var lut = try CreativeLUT(contentsOf: url)
                lut.source = resources.folder?.reference(for: url)
                if let current = base.lut { lut.amount = current.amount; lut.space = current.space }
                var next = base; next.lut = lut
                return (next, [])
            }
        } catch let failure as MCPFailure { throw failure }
        catch { throw MCPFailure("invalid_look", error.localizedDescription, path: "changes.applyFiles") }
    }
    public static func state(_ settings: Adjustments, defaults: Adjustments) throws -> [String: Any] {
        // Full numeric state is explicit, so clients need not cache a baseline to interpret omissions.
        func visible(_ value: Any) -> Any {
            if var object = value as? [String: Any] {
                for key in ["raster", "iccData", "samples", "hueSatMap1", "hueSatMap2", "lookTable", "calibrationMap"] where object[key] != nil {
                    object[key + "Present"] = !(object[key] is NSNull); object.removeValue(forKey: key)
                }
                return object.mapValues(visible)
            }
            if let array = value as? [Any] { return array.map(visible) }; return value
        }
        var object = visible(normalized(try MCPSchema.encoded(settings))) as! [String: Any]
        let masks = object.removeValue(forKey: "masks") ?? []
        return ["schemaVersion": version, "global": object, "masks": masks,
                "asShot": ["temperature": defaults.temperature, "tint": defaults.tint],
                "coordinates": "Masks: normalized source coordinates, bottom-left origin, before geometry. Crop: normalized bottom-left coordinates after rotation/upright. Preview scope: normalized, top-left origin, after geometry."]
    }
}
