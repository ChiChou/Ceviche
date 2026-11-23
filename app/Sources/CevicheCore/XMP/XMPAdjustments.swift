import Foundation

public enum XMPCodec {
    /// The notes worth showing, one per paragraph, or nil when there are none.
    public static func compatibilityReport(_ text: String) -> String? {
        let notes = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return notes.isEmpty ? nil : notes.joined(separator: "\n\n")
    }
    struct Control {
        let name: String
        let key: WritableKeyPath<Adjustments, Double>
        let range: ClosedRange<Double>
    }
    static let controls: [Control] = [
        .init(name: "ColorGradeBlending", key: \.splitToning.blending, range: 0...100),
        .init(name: "ColorGradeGlobalHue", key: \.splitToning.globalHue, range: 0...360),
        .init(name: "ColorGradeGlobalLum", key: \.splitToning.globalLuminance, range: -100...100),
        .init(name: "ColorGradeGlobalSat", key: \.splitToning.globalSaturation, range: 0...100),
        .init(name: "ColorGradeHighlightLum", key: \.splitToning.highlightLuminance, range: -100...100),
        .init(name: "ColorGradeMidtoneHue", key: \.splitToning.midtoneHue, range: 0...360),
        .init(name: "ColorGradeMidtoneLum", key: \.splitToning.midtoneLuminance, range: -100...100),
        .init(name: "ColorGradeMidtoneSat", key: \.splitToning.midtoneSaturation, range: 0...100),
        .init(name: "ColorGradeShadowLum", key: \.splitToning.shadowLuminance, range: -100...100),
        .init(name: "ColorNoiseReductionDetail", key: \.colorNoiseDetail, range: 0...100),
        .init(name: "ColorNoiseReductionSmoothness", key: \.colorNoiseSmoothness, range: 0...100),
        .init(name: "CurveRefineSaturation", key: \.curveSaturation, range: 0...100),
        .init(name: "DefringePurpleAmount", key: \.defringe.purpleAmount, range: 0...20),
        .init(name: "DefringePurpleHueLo", key: \.defringe.purpleLow, range: 0...100),
        .init(name: "DefringePurpleHueHi", key: \.defringe.purpleHigh, range: 0...100),
        .init(name: "DefringeGreenAmount", key: \.defringe.greenAmount, range: 0...20),
        .init(name: "DefringeGreenHueLo", key: \.defringe.greenLow, range: 0...100),
        .init(name: "DefringeGreenHueHi", key: \.defringe.greenHigh, range: 0...100),
        .init(name: "PostCropVignetteMidpoint", key: \.postCropVignette.midpoint, range: 0...100),
        .init(name: "PostCropVignetteFeather", key: \.postCropVignette.feather, range: 0...100),
        .init(name: "PostCropVignetteHighlightContrast", key: \.postCropVignette.highlights, range: 0...100),
        .init(name: "PostCropVignetteRoundness", key: \.postCropVignette.roundness, range: -100...100),
        .init(name: "Exposure2012", key: \.exposure, range: -5...5),
        .init(name: "Contrast2012", key: \.contrast, range: -100...100),
        .init(name: "Highlights2012", key: \.highlights, range: -100...100),
        .init(name: "Shadows2012", key: \.shadows, range: -100...100),
        .init(name: "Whites2012", key: \.whites, range: -100...100),
        .init(name: "Blacks2012", key: \.blacks, range: -100...100),
        .init(name: "Temperature", key: \.temperature, range: 2000...50000),
        .init(name: "Tint", key: \.tint, range: -150...150),
        .init(name: "Vibrance", key: \.vibrance, range: -100...100),
        .init(name: "Saturation", key: \.saturation, range: -100...100),
        .init(name: "Clarity2012", key: \.clarity, range: -100...100),
        .init(name: "Texture", key: \.texture, range: -100...100),
        .init(name: "Dehaze", key: \.dehaze, range: -100...100),
        .init(name: "Sharpness", key: \.sharpness, range: 0...100),
        .init(name: "SharpenRadius", key: \.sharpenRadius, range: 0.5...3),
        .init(name: "SharpenDetail", key: \.sharpenDetail, range: 0...100),
        .init(name: "SharpenEdgeMasking", key: \.sharpenMasking, range: 0...100),
        .init(name: "LuminanceSmoothing", key: \.noiseReduction, range: 0...100),
        .init(name: "LuminanceNoiseReductionDetail", key: \.luminanceNoiseDetail, range: 0...100),
        .init(name: "LuminanceNoiseReductionContrast", key: \.luminanceNoiseContrast, range: 0...100),
        .init(name: "ParametricShadows", key: \.parametricCurve.shadows, range: -100...100),
        .init(name: "ParametricDarks", key: \.parametricCurve.darks, range: -100...100),
        .init(name: "ParametricLights", key: \.parametricCurve.lights, range: -100...100),
        .init(name: "ParametricHighlights", key: \.parametricCurve.highlights, range: -100...100),
        .init(name: "ParametricShadowSplit", key: \.parametricCurve.shadowSplit, range: 1...99),
        .init(name: "ParametricMidtoneSplit", key: \.parametricCurve.midtoneSplit, range: 1...99),
        .init(name: "ParametricHighlightSplit", key: \.parametricCurve.highlightSplit, range: 1...99),
        .init(name: "SplitToningShadowHue", key: \.splitToning.shadowHue, range: 0...360),
        .init(name: "SplitToningShadowSaturation", key: \.splitToning.shadowSaturation, range: 0...100),
        .init(name: "SplitToningHighlightHue", key: \.splitToning.highlightHue, range: 0...360),
        .init(name: "SplitToningHighlightSaturation", key: \.splitToning.highlightSaturation, range: 0...100),
        .init(name: "SplitToningBalance", key: \.splitToning.balance, range: -100...100),
        .init(name: "RedHue", key: \.calibration.redHue, range: -100...100),
        .init(name: "RedSaturation", key: \.calibration.redSaturation, range: -100...100),
        .init(name: "GreenHue", key: \.calibration.greenHue, range: -100...100),
        .init(name: "GreenSaturation", key: \.calibration.greenSaturation, range: -100...100),
        .init(name: "BlueHue", key: \.calibration.blueHue, range: -100...100),
        .init(name: "BlueSaturation", key: \.calibration.blueSaturation, range: -100...100),
        .init(name: "ShadowTint", key: \.calibration.shadowTint, range: -100...100),
        .init(name: "GrainAmount", key: \.grain.amount, range: 0...100),
        .init(name: "GrainSize", key: \.grain.size, range: 0...100),
        .init(name: "GrainFrequency", key: \.grain.roughness, range: 0...100)
    ]
    static let curves: [(String, WritableKeyPath<Adjustments, ToneCurve>)] = [
        ("ToneCurvePV2012", \.curve), ("ToneCurvePV2012Red", \.redCurve), ("ToneCurvePV2012Green", \.greenCurve), ("ToneCurvePV2012Blue", \.blueCurve)]

    public static func apply(_ packet: XMPPacket, to base: Adjustments, metadata: CatalogMetadata = CatalogMetadata(), defaults: Adjustments? = nil, profiles: CameraProfileResolver? = nil) throws -> XMPImport {
        assert((try? base.validated()) != nil, "The base development is validated where it entered the app")
        var a = base, m = metadata, notes: [String] = []
        if let encoded = packet.nativeValue("Recipe") {
            if packet.nativeValue("PortableDigest") == packet.portableDigest {
                guard let data = Data(base64Encoded: encoded) else { throw EditorError.invalidDocument(L10n.tr("Invalid Ceviche XMP recipe.")) }
                let native = try JSONDecoder().decode(XMPNativeRecipe.self, from: data)
                guard (1...5).contains(native.version) else { throw EditorError.invalidDocument(L10n.tr("This Ceviche XMP recipe needs a newer app.")) }
                let preserved = packet.nativeValue("SourcePacket").flatMap { Data(base64Encoded: $0) }
                return XMPImport(adjustments: native.adjustments, metadata: try (native.metadata ?? metadata).validated(), sourceData: preserved ?? packet.data, warnings: [])
            }
            notes.append(L10n.tr("Portable XMP fields changed outside Ceviche; importing those fields instead of the embedded Ceviche recipe."))
        }
        var handled = Set<String>()
        func number(_ name: String, namespace: String = XMPPacket.crs) throws -> Double? {
            guard let string = packet.value(name, namespace: namespace) else { return nil }
            if namespace == XMPPacket.crs { handled.insert(name) }
            guard let value = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else { throw EditorError.invalidDocument(L10n.tr("Invalid XMP number: \(name).")) }
            return value
        }
        func boolean(_ name: String) throws -> Bool? {
            guard let string = packet.value(name) else { return nil }
            handled.insert(name)
            switch string.lowercased() { case "true", "1": return true; case "false", "0": return false; default: throw EditorError.invalidDocument(L10n.tr("Invalid XMP boolean: \(name).")) }
        }
        func bounded(_ value: Double, _ range: ClosedRange<Double>, _ name: String) -> Double {
            let clamped = min(range.upperBound, max(range.lowerBound, value))
            if clamped != value { notes.append(L10n.tr("\(name) was limited to Ceviche's \(range.lowerBound)…\(range.upperBound) range.")) }
            return clamped
        }
        for control in controls {
            if let value = try number(control.name) { a[keyPath: control.key] = bounded(value, control.range, control.name) }
        }
        // Split toning from before color grading renders as grading at Blending 100.
        if packet.crsNames.contains(where: { $0.hasPrefix("SplitToning") }), !packet.crsNames.contains(where: { $0.hasPrefix("ColorGrade") }) {
            a.splitToning.blending = 100
        }
        if packet.value("Exposure2012") == nil, let exposure = try number("Exposure") { a.exposure = bounded(exposure, -5...5, "Exposure"); notes.append(L10n.tr("Legacy Exposure was approximated as exposure EV.")) }
        if let wb = packet.value("WhiteBalance") {
            handled.insert("WhiteBalance")
            if wb == "As Shot", packet.value("Temperature") == nil, let defaults { a.temperature = defaults.temperature; a.tint = defaults.tint }
            else if packet.value("Temperature") == nil { notes.append(L10n.tr("WhiteBalance \(wb) has no resolved temperature; current white balance was retained.")) }
            if wb == "Auto" { notes.append(L10n.tr("Auto white balance uses recorded numeric values; the writer's auto calculation is not rerun.")) }
        }
        if let chroma = try number("ColorNoiseReduction") { a.colorNoiseReduction = bounded(chroma, 0...100, "ColorNoiseReduction") }
        if let gray = try boolean("ConvertToGrayscale") { a.monochrome = gray }
        // The color or B&W choice as newer writers name it; ConvertToGrayscale wins when a preset has both.
        if let treatment = packet.value("Treatment"), let gray = ["color": false, "black & white": true, "monochrome": true][treatment.lowercased()] {
            handled.insert("Treatment")
            if packet.value("ConvertToGrayscale") == nil { a.monochrome = gray }
        }
        if let seed = try number("GrainSeed") {
            guard seed >= 0, seed <= Double(UInt32.max), seed.rounded() == seed else { throw EditorError.invalidDocument(L10n.tr("Invalid grain seed.")) }
            a.grain.seed = UInt32(seed)
        }
        for (name, key) in curves {
            let legacy = name.replacingOccurrences(of: "PV2012", with: "")
            if let values = packet.list(name) ?? packet.list(legacy) {
                handled.formUnion([name, legacy])
                a[keyPath: key] = try parseCurve(values)
            } else if name == "ToneCurvePV2012", packet.value("ToneCurveName2012") == "Linear" { a[keyPath: key] = ToneCurve() }
        }
        for (index, color) in SelectiveColor.names.enumerated() {
            if let v = try number("HueAdjustment" + color) { a.selectiveColors[index].hue = bounded(v, -100...100, "HueAdjustment" + color) * 0.6 }
            if let v = try number("SaturationAdjustment" + color) { a.selectiveColors[index].saturation = bounded(v, -100...100, "SaturationAdjustment" + color) }
            if let v = try number("LuminanceAdjustment" + color) { a.selectiveColors[index].luminance = bounded(v, -100...100, "LuminanceAdjustment" + color) }
            if let v = try number("GrayMixer" + color) { a.blackWhiteMixer.values[index] = bounded(v, -100...100, "GrayMixer" + color) }
        }
        if let amount = try number("PostCropVignetteAmount") {
            a.postCropVignette.amount = bounded(amount, -100...100, "PostCropVignetteAmount")
            a.vignette = 0 // Replace the earlier approximation, avoiding a double vignette.

        }
        if let values = packet.list("PointColors") {
            a.pointColors = try pointColors(values, variance: packet.list("ColorVariance")); handled.formUnion(["PointColors", "ColorVariance"])
        } else if let values = packet.list("ColorVariance"), !a.pointColors.isEmpty, values.count == a.pointColors.count {
            for i in values.indices {
                guard let variance = Double(values[i]), variance.isFinite else { throw EditorError.invalidDocument(L10n.tr("Invalid color variance.")) }
                a.pointColors[i].variance = bounded(variance, -100...100, "ColorVariance")
            }
            handled.insert("ColorVariance")
        }
        if let name = packet.value("CameraProfile") {
            handled.formUnion(["CameraProfile", "CameraProfileDigest"])
            // The converter's own profiles are the base that Apple's camera color stands in for, so they are never loaded as looks.
            if CameraProfileResolver.isBuiltIn(name) {
                a.cameraProfile = nil
                notes.append(L10n.tr("Camera profile ‘\(name)’ is approximated with default camera color."))
            } else if let profiles, let profile = profiles.load(name, notes: &notes) {
                var loaded = profile
                if let existing = a.cameraProfile, CameraProfileResolver.normalized(existing.name) == CameraProfileResolver.normalized(name) { loaded.amount = existing.amount }
                a.cameraProfile = loaded
            } else {
                a.cameraProfile = nil
                if profiles?.match(name) == nil {
                    notes.append(L10n.tr("Camera profile ‘\(name)’ not found; default camera color is used."))
                }
            }
        }
        importLens(packet, into: &a, handled: &handled, notes: &notes)
        importFlags(packet, into: &a, handled: &handled, notes: &notes)
        importLegacy(packet, handled: &handled, notes: &notes)
        if let look = packet.node("Look") {
            handled.insert("Look")
            // A look naming one of the converter's own profiles chooses that profile; Apple's camera color stands in for it.
            if let name = look.value("Name"), look.property("Parameters") == nil, CameraProfileResolver.isBuiltIn(name) {
                a.look = nil
                if CameraProfileResolver.normalized(name).hasPrefix("adobe monochrome"), packet.value("ConvertToGrayscale") == nil, packet.value("Treatment") == nil { a.monochrome = true }
                let note = L10n.tr("Camera profile ‘\(name)’ is approximated with default camera color.")
                if !notes.contains(note) { notes.append(note) }
            } else {
                a.look = try importedLook(look, notes: &notes, reportProfile: packet.value("CameraProfile") == nil)
            }
        }
        for name in ["LookTable", "RGBTable", "RGBTableAmount"] where packet.value(name) != nil {
            handled.insert(name)
            if name != "RGBTableAmount" { notes.append(L10n.tr("\(name) is stored in the writer's installed profile files, not in this XMP; it was not applied.")) }
        }
        if let blur = packet.node("LensBlur") {
            handled.insert("LensBlur")
            if try blur.bool("Active", default: false) { notes.append(L10n.tr("Lens Blur needs the writer's depth data and was not applied.")) }
        }
        // Process 2012+ mask groups, and the per-tool lists of older sidecars and templates.
        for name in ["MaskGroupBasedCorrections", "GradientBasedCorrections", "CircularGradientBasedCorrections", "PaintBasedCorrections"] {
            guard let groups = packet.node(name) else { continue }
            let imported = try importMasks(groups, notes: &notes)
            for mask in imported {
                if let index = a.masks.firstIndex(where: { $0.id == mask.id }) { a.masks[index] = mask } else { a.masks.append(mask) }
            }
            handled.insert(name)
        }
        if let areas = packet.node("RetouchAreas") {
            for stroke in try importRetouch(areas, notes: &notes) {
                if let index = a.retouch.firstIndex(where: { $0.id == stroke.id }) { a.retouch[index] = stroke } else { a.retouch.append(stroke) }
            }
            handled.insert("RetouchAreas")
        }
        if let mode = try boolean("HDREditMode") { a.hdr.enabled = mode }
        if let maxHDR = try number("HDRMaxValue") { a.hdr.headroom = bounded(maxHDR, 0...10, "HDRMaxValue") }
        if a.hdr.enabled {
            notes.append(L10n.tr("HDR development uses Ceviche's processing and SDR tone mapping; extended curves and SDR rendition controls remain in the source XMP."))
        }
        // Geometry conversion is only reliable for an unrotated rectangle, in normalized coordinates.
        let cropNames = ["CropTop", "CropLeft", "CropBottom", "CropRight"]
        let hasCrop = try boolean("HasCrop")
        let angle = try number("CropAngle") ?? 0
        let upright = try number("PerspectiveUpright") ?? 0
        let coordinates = try cropNames.map { try number($0) }
        if hasCrop == false { a.geometry.crop = .full }
        else if coordinates.contains(where: { $0 != nil }) {
            if angle != 0 || a.quarterTurns != 0 || a.geometry.straighten != 0 || a.geometry.flipHorizontal || a.geometry.flipVertical || a.geometry.uprightActive || upright != 0 {
                notes.append(L10n.tr("Crop with rotation, flips or perspective was not applied; it needs manual alignment."))
            } else {
                guard coordinates.allSatisfy({ $0 != nil }) else { throw EditorError.invalidDocument(L10n.tr("Incomplete XMP crop rectangle.")) }
                let top = coordinates[0]!, left = coordinates[1]!, bottom = coordinates[2]!, right = coordinates[3]!
                a.geometry.crop = CropRect(x: left, y: 1 - bottom, width: right - left, height: bottom - top)
            }
        }
        if angle != 0 { notes.append(L10n.tr("CropAngle is preserved in source XMP but not rendered.")) }
        if let rating = try number("Rating", namespace: XMPPacket.xmp) {
            guard (-1...5).contains(rating), rating.rounded() == rating else { throw EditorError.invalidDocument(L10n.tr("XMP rating must be -1 through 5.")) }
            if rating == -1 { m.review = .rejected } else { m.rating = Int(rating) }
        }
        if let pick = try number("pick", namespace: "http://ns.adobe.com/xmp/1.0/DynamicMedia/") {
            guard [-1.0, 0, 1].contains(pick) else { throw EditorError.invalidDocument(L10n.tr("Invalid XMP pick flag.")) }
            if pick != 0 || packet.value("Rating", namespace: XMPPacket.xmp) != "-1" { m.review = pick == 1 ? .accepted : pick == -1 ? .rejected : .unreviewed }
        }
        // The usual XMP color names; an app's own label names have no color here and are left out.
        if let label = packet.value("Label", namespace: XMPPacket.xmp) { m.label = CatalogLabel(xmpName: label) }
        if let title = packet.value("title", namespace: XMPPacket.dc) { m.title = title }
        if let caption = packet.value("description", namespace: XMPPacket.dc) { m.caption = caption }
        if let tags = packet.list("subject", namespace: XMPPacket.dc) { m.keywords = tags.joined(separator: ", ") }
        if let date = packet.value("DateTimeOriginal", namespace: XMPPacket.exif) { m.captureDay = String(date.prefix(10)).replacingOccurrences(of: ":", with: "-") }
        let latitude = packet.value("GPSLatitude", namespace: XMPPacket.exif), longitude = packet.value("GPSLongitude", namespace: XMPPacket.exif)
        if latitude != nil || longitude != nil {
            guard let latitude, let longitude else { throw EditorError.invalidDocument(L10n.tr("Incomplete XMP GPS coordinates.")) }
            m.latitude = try coordinate(latitude, latitude: true); m.longitude = try coordinate(longitude, latitude: false)
            m.locationSource = nil
        }
        let bookkeeping: Set<String> = presetBookkeeping.union(["Version", "CompatibleVersion", "ProcessVersion", "RawFileName", "HasSettings", "AlreadyApplied", "ToneCurveName2012", "ToneCurveName", "CameraProfileDigest", "AutoToneDigest", "AutoToneDigestNoSat", "AutoWhiteVersion", "CropConstrainToUnitSquare", "CropConstrainToWarp"])
        // Do not advertise unsupported controls as supported just because a sample uses their defaults.
        let neutral: [String: String] = ["Amount": "1", "HDREditMode": "0", "LensProfileEnable": "0", "AutoLateralCA": "0", "VignetteAmount": "0", "LensManualDistortionAmount": "0", "PerspectiveUpright": "0", "PerspectiveVertical": "0", "PerspectiveHorizontal": "0", "PerspectiveRotate": "0.0", "PerspectiveAspect": "0", "PerspectiveScale": "100", "PerspectiveX": "0.00", "PerspectiveY": "0.00", "DefringePurpleAmount": "0", "DefringeGreenAmount": "0", "OverrideLookVignette": "False", "Defringe": "0", "ChromaticAberrationR": "0", "ChromaticAberrationB": "0"]
        let unsupported = packet.crsNames.subtracting(handled).subtracting(bookkeeping).filter { name in
            if let expected = neutral[name], let actual = packet.value(name) { return Double(expected).map { $0 != Double(actual) } ?? (expected.lowercased() != actual.lowercased()) }
            return true
        }.sorted()
        if !unsupported.isEmpty { notes.append(L10n.tr("Unsupported: ") + unsupported.joined(separator: ", ") + ".") }
        return XMPImport(adjustments: try a.validated(), metadata: try m.validated(), sourceData: packet.data, warnings: notes)
    }
    static func coordinate(_ text: String, latitude: Bool) throws -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let direction = trimmed.last, (latitude ? ["N", "S"] : ["E", "W"]).contains(String(direction)) else { throw EditorError.invalidDocument(L10n.tr("Invalid GPS direction.")) }
        let parts = trimmed.dropLast().split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ $0 != nil && $0!.isFinite && $0! >= 0 }),
              parts.count < 2 || parts[1]! < 60, parts.count < 3 || parts[2]! < 60 else { throw EditorError.invalidDocument(L10n.tr("Invalid GPS coordinate.")) }
        let degrees = parts[0]! + (parts.count > 1 ? parts[1]! / 60 : 0) + (parts.count > 2 ? parts[2]! / 3600 : 0)
        return degrees * (["S", "W"].contains(String(direction)) ? -1 : 1)
    }
}
