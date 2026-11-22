import Foundation

/// A bounded, namespace-aware value tree; nested controls never become top-level edits.
struct XMPElement: Codable, Sendable {
    var name: String
    var namespace: String
    var text: String
    var attributes: [String: String]
    var children: [XMPElement]
    init(_ element: XMLTreeElement, depth: Int = 0) throws {
        guard depth < 64 else { throw EditorError.invalidDocument(L10n.tr("XMP structures are too deeply nested.")) }
        name = element.localName; namespace = element.uri; text = element.text
        attributes = [:]
        for attribute in element.attributes { attributes[XMPPacket.key(attribute.uri, attribute.localName)] = attribute.value }
        children = try element.children.map { try XMPElement($0, depth: depth + 1) }
    }
    var resource: Self { children.first { $0.namespace == XMPPacket.rdf && $0.name == "Description" } ?? self }
    func value(_ name: String) -> String? {
        let node = resource
        return node.attributes[XMPPacket.key(XMPPacket.crs, name)] ?? node.children.first { $0.namespace == XMPPacket.crs && $0.name == name && $0.children.isEmpty }?.text
    }
    func property(_ name: String) -> Self? { resource.children.first { $0.namespace == XMPPacket.crs && $0.name == name } }
    var items: [Self] { children.first { $0.namespace == XMPPacket.rdf && ["Seq", "Bag"].contains($0.name) }?.children.filter { $0.namespace == XMPPacket.rdf && $0.name == "li" } ?? [] }
    func number(_ name: String, default fallback: Double? = nil) throws -> Double? {
        guard let text = value(name) else { return fallback }
        guard let result = Double(text), result.isFinite else { throw EditorError.invalidDocument(L10n.tr("Invalid XMP number: \(name).")) }
        return result
    }
    func bool(_ name: String, default fallback: Bool) throws -> Bool {
        guard let text = value(name) else { return fallback }
        switch text.lowercased() { case "true", "1": return true; case "false", "0": return false; default: throw EditorError.invalidDocument(L10n.tr("Invalid XMP boolean: \(name).")) }
    }
}

extension XMPPacket {
    init(resource: XMPElement) throws {
        data = Data()
        let r = resource.resource
        scalars = r.attributes
        for child in r.children {
            let key = Self.key(child.namespace, child.name)
            guard scalars[key] == nil, nodes[key] == nil else { throw EditorError.invalidDocument(L10n.tr("Duplicate nested XMP property.")) }
            nodes[key] = child
            if !child.items.isEmpty && child.items.allSatisfy({ $0.children.isEmpty && $0.attributes.isEmpty }) { arrays[key] = child.items.map(\.text) }
            else if child.children.isEmpty && child.attributes.isEmpty { scalars[key] = child.text }
            else { structures.insert(key) }
        }
    }
}

extension XMPCodec {
    static func pointColors(_ values: [String], variance: [String]?) throws -> [PointColor] {
        guard values.count <= 16, variance == nil || variance!.count == values.count else { throw EditorError.invalidDocument(L10n.tr("Invalid point color sample count.")) }
        var result: [PointColor] = []
        for (index, row) in values.enumerated() {
            let fields = row.split(separator: ",", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard fields.count == 19, fields.allSatisfy({ $0?.isFinite == true }) else { throw EditorError.invalidDocument(L10n.tr("Expected 19 finite point color values.")) }
            let v = fields.map { $0! }
            let colorVariance = try variance.map { strings -> Double in
                guard let n = Double(strings[index]), n.isFinite, (-100...100).contains(n) else { throw EditorError.invalidDocument(L10n.tr("Invalid color variance.")) }; return n
            } ?? 0
            if v.allSatisfy({ $0 == -1 }) { continue } // The writer's empty sample, including its unused variance sentinel.
            var point = PointColor()
            point.hue = v[0] / 6; point.saturation = v[1]; point.luminance = v[2]
            point.hueShift = v[3]; point.saturationShift = v[4]; point.luminanceShift = v[5]; point.range = v[6]
            point.hueRange = Array(v[7...10]); point.saturationRange = Array(v[11...14]); point.luminanceRange = Array(v[15...18]); point.variance = colorVariance
            try point.validate(); result.append(point)
        }
        return result
    }
    static func importedLook(_ node: XMPElement, notes: inout [String], reportProfile: Bool = true) throws -> ImportedLook? {
        guard let parameters = node.property("Parameters") else { notes.append(L10n.tr("Look has no embedded parameters; its external profile is still required.")); return nil }
        let packet = try XMPPacket(resource: parameters)
        // Profile looks are a separate development stage. Do not merge their curves into the user's curves.
        guard packet.node("Look") == nil, packet.node("MaskGroupBasedCorrections") == nil, packet.node("RetouchAreas") == nil else { notes.append(L10n.tr("Nested Look recipe is not supported.")); return nil }
        // A look that names its tables by digest is a profile installed with the writer; only its curve travels in the
        // sidecar, so it is left out whole, as built-in camera profiles are, rather than shown as a partial look.
        if ["LookTable", "RGBTable"].contains(where: { packet.value($0) != nil }) {
            notes.append(L10n.tr("Look ‘\(node.value("Name") ?? L10n.key("Unnamed"))’ uses profile tables not available here; default camera color is used."))
            return nil
        }
        let imported = try apply(packet, to: Adjustments())
        var look = ImportedLook(name: String((node.value("Name") ?? L10n.tr("Imported look")).prefix(200)))
        let amount = try node.number("Amount", default: 1)!
        look.amount = min(1, max(0, amount))
        if look.amount != amount { notes.append(L10n.tr("Look amount was limited to 0…1.")) }
        look.adjustments = imported.adjustments.pixels
        try look.validate()
        // The look's base profile is reported once, at the photo level when the photo names one; its notes name it.
        let profile = reportProfile ? nil : packet.value("CameraProfile")
        notes.append(contentsOf: imported.warnings.filter { note in profile.map { !note.contains($0) } ?? true }.map { L10n.tr("Look: ") + $0 })
        return look
    }
    static func localAdjustments(_ node: XMPElement, notes: inout [String]) throws -> PixelAdjustments {
        var a = PixelAdjustments()
        let controls: [(String, WritableKeyPath<PixelAdjustments, Double>, Double)] = [
            ("LocalExposure2012", \.exposure, 4), ("LocalContrast2012", \.contrast, 100), ("LocalHighlights2012", \.highlights, 100),
            ("LocalShadows2012", \.shadows, 100), ("LocalWhites2012", \.whites, 100), ("LocalBlacks2012", \.blacks, 100),
            ("LocalClarity2012", \.clarity, 100), ("LocalTexture", \.texture, 100), ("LocalDehaze", \.dehaze, 100), ("LocalSaturation", \.saturation, 100), ("LocalSharpness", \.sharpness, 100),
            ("LocalLuminanceNoise", \.noiseReduction, 100), ("LocalTemperature", \.warmth, 100), ("LocalTint", \.tint, 100),
            ("LocalGrain", \.grain.amount, 100), ("LocalCurveRefineSaturation", \.curveSaturation, 1)]
        for (name, key, scale) in controls { if let value = try node.number(name) { a[keyPath: key] = value * scale } }
        for (name, key) in [("MainCurve", \PixelAdjustments.curve), ("RedCurve", \.redCurve), ("GreenCurve", \.greenCurve), ("BlueCurve", \.blueCurve)] {
            if let curve = node.property(name) { a[keyPath: key] = try parseCurve(curve.items.map(\.text)) }
        }
        if let points = node.property("LocalPointColors") { a.pointColors = try pointColors(points.items.map(\.text), variance: node.property("LocalColorVariance")?.items.map(\.text)) }
        let unsupported = ["LocalMoire", "LocalDefringe", "LocalHue", "LocalBrightness", "LocalToningSaturation", "LocalCorrectedDepth"]
        for name in unsupported where try node.number(name, default: 0) != 0 { notes.append(L10n.tr("Mask adjustment \(name) is preserved but not rendered.")) }
        if node.property("ExtendedMainCurve") != nil { notes.append(L10n.tr("The mask's SDR MainCurve was used; HDR curve anchors remain in the source XMP.")) }
        return try a.validated()
    }
    /// Accepts curves that start after 0 or end before 255: the writer holds the end
    /// values flat outside the first and last points. Nearly coincident points are merged.
    static func parseCurve(_ values: [String]) throws -> ToneCurve {
        guard !values.isEmpty, values.count <= 1001 else { throw EditorError.invalidDocument(L10n.tr("Invalid XMP curve point.")) }
        var points = try values.map { text -> CurvePoint in
            let v = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard v.count == 2, let x = v[0], let y = v[1], x.isFinite, y.isFinite else { throw EditorError.invalidDocument(L10n.tr("Invalid XMP curve point.")) }
            return CurvePoint(x: min(1, max(0, x / 255)), y: min(1, max(0, y / 255)))
        }
        points.sort { $0.x < $1.x }
        if points[0].x > 0 { points.insert(CurvePoint(x: 0, y: points[0].y), at: 0) }
        if points[points.count - 1].x < 1 { points.append(CurvePoint(x: 1, y: points[points.count - 1].y)) }
        var merged: [CurvePoint] = []
        for point in points {
            guard let last = merged.last, point.x - last.x < ToneCurve.minimumSpacing else { merged.append(point); continue }
            if last.x == 0 { merged[merged.count - 1].y = point.y } else { merged[merged.count - 1] = point }
        }
        let curve = ToneCurve(points: merged); try curve.validate(); return curve
    }
    /// Preset descriptors and writer version metadata, not development settings.
    static let presetBookkeeping: Set<String> = ["Name", "ShortName", "SortName", "Group", "Description", "Cluster", "UUID", "PresetType", "Copyright", "ContactInfo",
        "SupportsAmount", "SupportsAmount2", "SupportsColor", "SupportsMonochrome", "SupportsHighDynamicRange", "SupportsNormalDynamicRange",
        "SupportsSceneReferred", "SupportsOutputReferred", "RequiresRGBTables", "RequiresRenditionBehavior", "CameraModelRestriction", "Preset", "LensProfileMatchKeyCameraModelName", "LensProfileMatchKeyExifMake", "LensProfileMatchKeyExifModel", "LensProfileMatchKeyIsRaw", "LensProfileMatchKeyLensID", "LensProfileMatchKeyLensInfo", "LensProfileMatchKeyLensName", "LensProfileMatchKeySensorFormatFactor"]
    static func importLens(_ packet: XMPPacket, into a: inout Adjustments, handled: inout Set<String>, notes: inout [String]) {
        let names = ["LensProfileEnable", "LensProfileSetup", "LensProfileName", "LensProfileFilename", "LensProfileDigest", "LensProfileIsEmbedded",
                   "LensProfileDistortionScale", "LensProfileVignettingScale", "LensProfileChromaticAberrationScale", "EnableLensCorrections"]
        let present = names.filter { packet.value($0) != nil }
        guard !present.isEmpty else { return }
        handled.formUnion(present)
        func on(_ name: String) -> Bool? { packet.value(name).map { ["1", "true"].contains($0.lowercased()) } }
        if let enabled = on("LensProfileEnable") { a.lensCorrection = enabled }
        if on("EnableLensCorrections") == false { a.lensCorrection = false }
        guard a.lensCorrection, on("LensProfileEnable") == true else { return }
        if on("LensProfileIsEmbedded") != true, let name = packet.value("LensProfileName") {
            notes.append(L10n.tr("Lens profile ‘\(name)’ uses the RAW decoder's built-in lens correction where the camera supports it; LCP lens-profile data is not read."))
        }
        for (name, label) in [("LensProfileDistortionScale", L10n.tr("Distortion")), ("LensProfileVignettingScale", L10n.tr("Vignetting"))] {
            if let value = packet.value(name).flatMap(Double.init), value != 100 { notes.append(L10n.tr("Lens \(label) amount \(Int(value)) is not adjustable; full built-in correction is used.")) }
        }
    }
    /// Older sidecar fields whose defaults are inert, or whose effect is covered elsewhere.
    static func importLegacy(_ packet: XMPPacket, handled: inout Set<String>, notes: inout [String]) {
        func number(_ name: String) -> Double? { packet.value(name).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
        // Template image orientation is not a development setting.
        if packet.value("orientation") != nil { handled.insert("orientation") }
        if packet.value("VignetteMidpoint") != nil, (number("VignetteAmount") ?? 0) == 0 { handled.insert("VignetteMidpoint") }
        if let style = number("PostCropVignetteStyle") {
            handled.insert("PostCropVignetteStyle")
            if style != 1, (number("PostCropVignetteAmount") ?? 0) != 0 { notes.append(L10n.tr("Post-crop vignette style \(Int(style)) is approximated by Ceviche's highlight-priority vignette.")) }
        }
        if let ca = packet.value("AutoLateralCA") {
            handled.insert("AutoLateralCA")
            if ca != "0" { notes.append(L10n.tr("AutoLateralCA uses the RAW decoder's lens correction where the camera supports it.")) }
        }
    }
    /// Sidecar panel switches. Off disables the matching Ceviche sections; Auto requests are not recalculated.
    static func importFlags(_ packet: XMPPacket, into a: inout Adjustments, handled: inout Set<String>, notes: inout [String]) {
        let sections: [String: [AdjustmentGroup]] = ["EnableToneCurve": [.curve, .parametricCurve], "EnableColorAdjustments": [.selectiveColor], "EnableSplitToning": [.splitToning],
            "EnableDetail": [.sharpening, .noiseReduction], "EnableEffects": [.vignette, .grain], "EnableCalibration": [.calibration], "EnableGrayscaleMix": [.blackWhite]]
        for name in packet.crsNames.sorted() {
            guard let text = packet.value(name) else { continue }
            let on = ["1", "true"].contains(text.lowercased())
            if let groups = sections[name] {
                handled.insert(name)
                for group in groups { if on { a.disabledSections.remove(group) } else { a.disabledSections.insert(group) } }
            } else if name.hasPrefix("Enable") {
                handled.insert(name)
                if !on { notes.append(L10n.tr("\(name) is off in this XMP; Ceviche's matching local edits were left unchanged.")) }
            } else if name.hasPrefix("Auto"), !["AutoLateralCA", "AutoWhiteVersion", "AutoToneDigest", "AutoToneDigestNoSat"].contains(name) {
                handled.insert(name)
                if on { notes.append(L10n.tr("\(name) is not recalculated; the recorded values are used.")) }
            } else if name.hasPrefix("Upright"), (packet.value("PerspectiveUpright").flatMap(Double.init) ?? 0) == 0 {
                handled.insert(name) // Analysis cache for an inactive Upright mode.
            }
        }
    }
    static func selection(_ node: XMPElement) throws -> MaskSelection? {
        // Opaque image/AI masks and range modifiers cannot be reconstructed from reference IDs.
        if node.property("CorrectionRangeMask") != nil { return nil }
        guard try node.number("MaskValue", default: 1) == 1 else { return nil }
        var s: MaskSelection
        switch node.value("What") {
        case "Mask/Gradient":
            s = MaskSelection(kind: .linear); s.feather = 0
            guard let x = try node.number("FullX"), let y = try node.number("FullY"), let zx = try node.number("ZeroX"), let zy = try node.number("ZeroY") else { throw EditorError.invalidDocument(L10n.tr("Incomplete gradient mask.")) }
            s.start = MaskPoint(x: x, y: 1 - y); s.end = MaskPoint(x: zx, y: 1 - zy)
        case "Mask/CircularGradient":
            s = MaskSelection(kind: .radial)
            guard let left = try node.number("Left"), let right = try node.number("Right"), let top = try node.number("Top"), let bottom = try node.number("Bottom") else { return nil }
            s.start = MaskPoint(x: left, y: 1 - bottom); s.end = MaskPoint(x: right, y: 1 - top)
            // The sidecar's angle turns in its top-down coordinates; ours turn counterclockwise with y up.
            let angle = try node.number("Angle", default: 0)!
            if angle != 0 { s.rotation = max(-360, min(360, -angle)) }
            s.feather = (try node.number("Feather", default: 50)!) / 200
        case "Mask/Paint":
            guard try node.number("Flow", default: 1) == 1, let dabs = node.property("Dabs") else { return nil }
            s = MaskSelection(kind: .brush); s.feather = 0
            let radius = try node.number("Radius", default: 0.02)!, softness = 1 - (try node.number("CenterWeight", default: 0.5)!)
            var points: [MaskPoint] = []
            for item in dabs.items {
                let parts = item.text.split(whereSeparator: { $0.isWhitespace })
                guard let kind = parts.first else { continue }
                if kind == "h", parts.count == 2, let h = Double(parts[1]), abs(h - (1 - softness)) < 0.0001 { continue }
                guard kind == "d", parts.count == 3, let x = Double(parts[1]), let y = Double(parts[2]) else { return nil }
                points.append(MaskPoint(x: x, y: 1 - y))
            }
            guard !points.isEmpty else { return nil }
            s.strokes = [MaskStroke(points: points, radius: radius, softness: softness, erase: false)]
        default: return nil
        }
        s.inverted = try node.bool("MaskInverted", default: false)
        // Coordinates outside the image require a different geometric representation.
        guard s.start.isValid, s.end.isValid else { return nil }
        try s.validate(); return s
    }
    static func importMasks(_ node: XMPElement, notes: inout [String]) throws -> [PhotoMask] {
        guard node.items.count <= 100 else { throw EditorError.invalidDocument(L10n.tr("Too many imported masks.")) }
        var result: [PhotoMask] = []
        for (index, group) in node.items.enumerated() {
            let name = String((group.value("CorrectionName") ?? L10n.tr("Imported mask \(index+1)")).prefix(200))
            let items = group.property("CorrectionMasks")?.items ?? []
            guard !items.isEmpty, items.count <= 33 else { notes.append(L10n.tr("\(name): missing or oversized mask geometry; group was not applied.")); continue }
            var shapes: [MaskSelection] = [], unsupported = false
            for item in items {
                if try !item.bool("MaskActive", default: true) { continue }
                guard try item.number("MaskBlendMode", default: 0) == 0, let shape = try selection(item) else { unsupported = true; break }
                shapes.append(shape)
            }
            // Never apply a partially decoded selection to the wrong pixels.
            guard !unsupported, let first = shapes.first else { notes.append(L10n.tr("\(name): unsupported mask geometry or blend mode (including external AI mask data); group was not applied.")); continue }
            var mask = PhotoMask(kind: first.kind); mask.name = name; mask.selection = first
            mask.components = shapes.dropFirst().map { MaskComponent(operation: .add, selection: $0) }
            mask.enabled = try group.bool("CorrectionActive", default: true)
            mask.opacity = try group.number("CorrectionAmount", default: 1)!
            mask.adjustments = try localAdjustments(group, notes: &notes)
            // Stable IDs make repeated sidecar imports replace the same imported objects.
            if let id = group.value("CorrectionSyncID"), let uuid = syncUUID(id) { mask.id = uuid }
            try mask.validate(); result.append(mask)
        }
        return result
    }
    static func importRetouch(_ node: XMPElement, notes: inout [String]) throws -> [RetouchStroke] {
        guard node.items.count <= 200 else { throw EditorError.invalidDocument(L10n.tr("Too many retouch areas.")) }
        var result: [RetouchStroke] = []
        for area in node.items {
            let type = area.value("SpotType"), masks = area.property("Masks")?.items ?? []
            guard type == "heal" || type == "clone", masks.count == 1, let shape = try selection(masks[0]), shape.kind == .brush, !shape.inverted,
                  let stroke = shape.strokes.first, let target = stroke.points.first,
                  let sx = try area.number("SourceX"), let sy = try area.number("SourceY") ?? area.number("OffsetY") else {
                notes.append(L10n.tr("Retouch area needs a supported paint mask and explicit source coordinates; external removal data was not applied.")); continue
            }
            var retouch = RetouchStroke(mode: type == "heal" ? .heal : .clone, source: MaskPoint(x: sx, y: 1 - sy), target: target, radius: stroke.radius, softness: stroke.softness, opacity: try area.number("Opacity", default: 1)!)
            retouch.points = stroke.points; retouch.enabled = try masks[0].bool("MaskActive", default: true)
            if let id = masks[0].value("MaskSyncID"), let uuid = syncUUID(id) { retouch.id = uuid }
            try retouch.validate(); result.append(retouch)
        }
        return result
    }
    private static func syncUUID(_ text: String) -> UUID? {
        if let id = UUID(uuidString: text) { return id }
        guard text.count == 32 else { return nil }
        let chars = Array(text)
        return UUID(uuidString: [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(chars[$0]) }.joined(separator: "-"))
    }
}
