import Foundation

/// What makes an XMP a develop preset rather than a photo's sidecar: its name, and the settings it carries.
public struct XMPPreset: Sendable {
    public let name: String
    public let items: Set<EditTransferItem>
    public init(name: String, items: Set<EditTransferItem>) { self.name = name; self.items = items }
}

extension XMPCodec {
    /// The portable controls `items` carry, so a preset leaves every other setting alone in other editors too.
    static func controlNames(in items: Set<EditTransferItem>) -> Set<String> {
        let blank = Adjustments()
        var probe = blank, copied = blank
        for control in controls { probe[keyPath: control.key] += 1 }
        for item in items { item.copy(from: probe, into: &copied) }
        return Set(controls.filter { copied[keyPath: $0.key] != blank[keyPath: $0.key] }.map(\.name))
    }

    /// Written as `xmp:CreatorTool`; a sidecar that still says so was last written by Ceviche.
    public static let creatorTool = "Ceviche RAW Studio"
    public static let exportNotice = L10n.tr("Other editors read the portable settings only; camera profiles, masks, retouch, HDR, defringing and transformed crops stay in Ceviche's recipe.")

    public static func encode(adjustments: Adjustments, metadata: CatalogMetadata? = nil, defaults: Adjustments = Adjustments(), sourceData: Data? = nil, filename: String? = nil, preset: XMPPreset? = nil) throws -> Data {
        assert((try? adjustments.validated()) != nil, "Adjustments are validated where they enter the app")
        _ = try metadata?.validated()
        let a = adjustments.effective(defaults: defaults)
        // A preset writes only what it carries; a sidecar writes everything.
        func has(_ item: EditTransferItem) -> Bool { preset?.items.contains(item) ?? true }
        let carried = preset.map { controlNames(in: $0.items) }
        let root = XMLWriter.Element("x:xmpmeta"); root.attributes = [("xmlns:x", "adobe:ns:meta/")]
        let rdf = XMLWriter.Element("rdf:RDF"); rdf.attributes = [("xmlns:rdf", XMPPacket.rdf)]; root.add(rdf)
        let description = XMLWriter.Element("rdf:Description"); rdf.add(description)
        let namespaces = [("crs", XMPPacket.crs), ("xmp", XMPPacket.xmp), ("dc", XMPPacket.dc), ("exif", XMPPacket.exif), ("xmpDM", "http://ns.adobe.com/xmp/1.0/DynamicMedia/"), ("ceviche", XMPPacket.native)]
            .map { ("xmlns:" + $0.0, $0.1) }
        var attributes: [String: String] = [:]
        func attribute(_ name: String, _ value: String) { attributes[name] = value }
        func installAttributes() {
            description.attributes = namespaces + attributes.keys.sorted(by: { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }).map { ($0, attributes[$0]!) }
        }
        func scalar(_ name: String, _ value: Double) { attribute("crs:" + name, String(value)) }
        func array(_ name: String, _ values: [String], type: String = "Seq") {
            let property = XMLWriter.Element(name), container = XMLWriter.Element("rdf:" + type)
            for value in values {
                let item = XMLWriter.Element("rdf:li", text: value)
                if type == "Alt" { item.attributes = [("xml:lang", "x-default")] }
                container.add(item)
            }
            property.add(container); description.add(property)
        }
        attribute("rdf:about", ""); attribute("xmp:CreatorTool", creatorTool)
        attribute("crs:ProcessVersion", "6.7"); attribute("crs:HasSettings", "True"); attribute("crs:AlreadyApplied", "False")
        if has(.whiteBalance) { attribute("crs:WhiteBalance", "Custom") }
        if has(.color) { attribute("crs:ConvertToGrayscale", a.monochrome ? "True" : "False") }
        if has(.toneCurve) { attribute("crs:ToneCurveName2012", "Custom") }
        if has(.hdr) {
            attribute("crs:HDREditMode", a.hdr.enabled ? "1" : "0")
            scalar("HDRMaxValue", a.hdr.headroom)
        }
        if has(.lensCorrection) { attribute("crs:LensProfileEnable", a.lensCorrection ? "1" : "0") }
        // Other editors resolve the profile by name; Ceviche's recipe also embeds its tables.
        if has(.cameraProfile), let profile = a.cameraProfile, profile.enabled { attribute("crs:CameraProfile", profile.name) }
        if let filename { attribute("crs:RawFileName", URL(fileURLWithPath: filename).lastPathComponent) }
        for control in controls where carried?.contains(control.name) ?? true { scalar(control.name, a[keyPath: control.key]) }
        if has(.noiseReduction), let chroma = a.colorNoiseReduction { scalar("ColorNoiseReduction", chroma) }
        if has(.grain) { scalar("GrainSeed", Double(a.grain.seed)) }
        if has(.vignette) { scalar("PostCropVignetteAmount", a.postCropVignette.amount != 0 ? a.postCropVignette.amount : -a.vignette) }
        if has(.pointColor) {
            array("crs:PointColors", a.pointColors.map { p in ([p.hue * 6, p.saturation, p.luminance, p.hueShift, p.saturationShift, p.luminanceShift, p.range] + p.hueRange + p.saturationRange + p.luminanceRange).map { String($0) }.joined(separator: ", ") })
            array("crs:ColorVariance", a.pointColors.map { String($0.variance) })
        }
        for (name, key) in curves where has(.toneCurve) {
            // PV2012 curves are SDR-only; points beyond SDR white stay in Ceviche's own recipe.
            array("crs:" + name, a[keyPath: key].sdrPoints.map { "\($0.x * 255), \($0.y * 255)" })
        }
        for (index, color) in SelectiveColor.names.enumerated() {
            if a.selectiveColors.count == 8, has(.selectiveColor) {
                scalar("HueAdjustment" + color, a.selectiveColors[index].hue / 0.6)
                scalar("SaturationAdjustment" + color, a.selectiveColors[index].saturation)
                scalar("LuminanceAdjustment" + color, a.selectiveColors[index].luminance)
            }
            if has(.blackWhite) { scalar("GrayMixer" + color, a.blackWhiteMixer.values[index]) }
        }
        if let preset {
            // As other editors list presets: by name, in a group, under an id of their own.
            attribute("crs:PresetType", "Normal"); attribute("crs:UUID", UUID().uuidString.replacingOccurrences(of: "-", with: ""))
            array("crs:Name", [preset.name], type: "Alt"); array("crs:Group", [DevelopPreset.userFolder], type: "Alt")
            attribute("ceviche:PresetItems", preset.items.map(\.rawValue).sorted().joined(separator: ","))
        } else if a.quarterTurns == 0 && a.geometry.straighten == 0 && !a.geometry.flipHorizontal && !a.geometry.flipVertical && !a.geometry.uprightActive && a.geometry.transform.isIdentity {
            attribute("crs:HasCrop", a.geometry.crop == .full ? "False" : "True")
            scalar("CropTop", 1 - a.geometry.crop.y - a.geometry.crop.height); scalar("CropBottom", 1 - a.geometry.crop.y)
            scalar("CropLeft", a.geometry.crop.x); scalar("CropRight", a.geometry.crop.x + a.geometry.crop.width); scalar("CropAngle", 0)
        }
        if let metadata {
            attribute("xmp:Rating", String(metadata.rating))
            if let label = metadata.label { attribute("xmp:Label", label.xmpName) }
            attribute("xmpDM:pick", metadata.review == .accepted ? "1" : metadata.review == .rejected ? "-1" : "0")
            array("dc:title", [metadata.title], type: "Alt"); array("dc:description", [metadata.caption], type: "Alt")
            array("dc:subject", metadata.keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }, type: "Bag")
            if !metadata.captureDay.isEmpty { attribute("exif:DateTimeOriginal", metadata.captureDay) }
            func gps(_ value: Double, latitude: Bool) -> String {
                let direction = latitude ? (value < 0 ? "S" : "N") : (value < 0 ? "W" : "E")
                let magnitude = abs(value), degrees = floor(magnitude)
                return "\(Int(degrees)),\((magnitude - degrees) * 60)\(direction)"
            }
            if let latitude = metadata.latitude, let longitude = metadata.longitude {
                attribute("exif:GPSLatitude", gps(latitude, latitude: true)); attribute("exif:GPSLongitude", gps(longitude, latitude: false))
            }
        }
        installAttributes()
        let digest = try XMPPacket(data: XMLWriter.data(root)).portableDigest
        // AI fills are pixels of this photo, megabytes each; a stroke restored from XMP falls back to patch Remove.
        let recipe = try JSONEncoder().encode(XMPNativeRecipe(adjustments: adjustments.removingRetouchFills, metadata: metadata))
        attribute("ceviche:Recipe", recipe.base64EncodedString()); attribute("ceviche:PortableDigest", digest)
        attribute("ceviche:Compatibility", exportNotice)
        if let sourceData {
            let packet = try XMPPacket(data: sourceData)
            let original = packet.nativeValue("SourcePacket").flatMap { Data(base64Encoded: $0) } ?? sourceData
            attribute("ceviche:SourcePacket", original.base64EncodedString())
        }
        installAttributes()
        let result = XMLWriter.data(root)
        guard result.count <= XMPPacket.maxBytes else { throw EditorError.invalidDocument(L10n.tr("XMP exceeds 32 MB; save a Ceviche document instead.")) }
        return result
    }
    public static func write(_ data: Data, to destination: URL, protecting original: URL) throws {
        guard destination.resolvingSymlinksInPath().standardizedFileURL != original.resolvingSymlinksInPath().standardizedFileURL else {
            throw EditorError.invalidDocument(L10n.tr("XMP export cannot overwrite the original image."))
        }
        _ = try XMPPacket(data: data)
        try data.write(to: destination, options: .atomic)
    }
}
