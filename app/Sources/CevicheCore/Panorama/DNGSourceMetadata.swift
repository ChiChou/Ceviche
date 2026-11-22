import Foundation
import ImageIO

/// What a DNG made from photos keeps of the one it is based on: its camera and lens, exposure, capture time, author
/// and location, read with ImageIO and written back as TIFF, EXIF and GPS tags.
struct DNGSourceMetadata: Sendable {
    /// What was done, for the file's description and software tags, such as "Denoise".
    var process: String
    /// Made from several photos, which the description says.
    var merged = false
    var make = ""
    var model = ""
    /// TIFF IFD 0 tags other than the camera: artist, copyright.
    var tiff: [(UInt16, TIFFValue)] = []
    var exif: [(UInt16, TIFFValue)] = []
    var gps: [(UInt16, TIFFValue)] = []

    init(process: String) { self.process = process }

    /// A merge's: the reference photo's camera, lens, settings and place. `exposure` false leaves out its shutter time
    /// and exposure bias, which differ across an HDR merge's photos.
    static func merge(_ url: URL, process: String, exposure: Bool = true) -> DNGSourceMetadata {
        var metadata = DNGSourceMetadata(url, process: process)
        metadata.merged = true
        if !exposure { metadata.exif.removeAll { $0.0 == 33434 || $0.0 == 37380 } }
        return metadata
    }

    init(_ url: URL, process: String) {
        let properties = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] }
        self.init(properties: properties ?? [:], process: process)
    }

    init(properties: [String: Any], process: String) {
        self.process = process
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        func text(_ dictionary: [String: Any], _ key: CFString) -> String? {
            (dictionary[key as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        func number(_ dictionary: [String: Any], _ key: CFString) -> Double? {
            let value = dictionary[key as String]
            let found = (value as? NSNumber)?.doubleValue ?? (value as? [NSNumber])?.first?.doubleValue
            return found.flatMap { $0.isFinite ? $0 : nil }
        }
        make = text(tiff, kCGImagePropertyTIFFMake) ?? ""
        model = text(tiff, kCGImagePropertyTIFFModel) ?? ""
        if let artist = text(tiff, kCGImagePropertyTIFFArtist) { self.tiff.append((315, .ascii(artist))) }
        if let copyright = text(tiff, kCGImagePropertyTIFFCopyright) { self.tiff.append((33432, .ascii(copyright))) }

        let rationals: [(UInt16, CFString)] = [(33434, kCGImagePropertyExifExposureTime), (33437, kCGImagePropertyExifFNumber),
                                               (37381, kCGImagePropertyExifMaxApertureValue), (37386, kCGImagePropertyExifFocalLength)]
        for (tag, key) in rationals { if let value = number(exif, key), value > 0 { self.exif.append((tag, .rationals([Self.unsigned(value)]))) } }
        if let bias = number(exif, kCGImagePropertyExifExposureBiasValue) { self.exif.append((37380, .srationals([PanoramaDNGWriter.rational(bias)]))) }
        let shorts: [(UInt16, CFString)] = [(34850, kCGImagePropertyExifExposureProgram), (37383, kCGImagePropertyExifMeteringMode),
                                            (37384, kCGImagePropertyExifLightSource), (37385, kCGImagePropertyExifFlash),
                                            (41986, kCGImagePropertyExifExposureMode), (41987, kCGImagePropertyExifWhiteBalance),
                                            (41989, kCGImagePropertyExifFocalLenIn35mmFilm), (41990, kCGImagePropertyExifSceneCaptureType)]
        for (tag, key) in shorts { if let value = number(exif, key), value >= 0, value <= 65535 { self.exif.append((tag, .shorts([UInt16(value)]))) } }
        // Worked out when the camera records none, so a merge still stitches from the right field of view.
        if !self.exif.contains(where: { $0.0 == 41989 }), let focal = PanoramaDecoder.focalLength35mm(properties), focal >= 1, focal <= 65535 {
            self.exif.append((41989, .shorts([UInt16(focal.rounded())])))
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue, iso > 0 {
            self.exif.append((34855, .shorts([UInt16(min(65535, iso))])))
        }
        let texts: [(UInt16, CFString)] = [(36868, kCGImagePropertyExifDateTimeDigitized), (36880, kCGImagePropertyExifOffsetTime),
                                           (36881, kCGImagePropertyExifOffsetTimeOriginal), (36882, kCGImagePropertyExifOffsetTimeDigitized),
                                           (37521, kCGImagePropertyExifSubsecTimeOriginal), (42032, kCGImagePropertyExifCameraOwnerName),
                                           (42033, kCGImagePropertyExifBodySerialNumber), (42035, kCGImagePropertyExifLensMake),
                                           (42036, kCGImagePropertyExifLensModel), (42037, kCGImagePropertyExifLensSerialNumber)]
        for (tag, key) in texts { if let value = text(exif, key) { self.exif.append((tag, .ascii(value))) } }
        if let lens = exif[kCGImagePropertyExifLensSpecification as String] as? [NSNumber], lens.count == 4 {
            self.exif.append((42034, .rationals(lens.map { Self.unsigned($0.doubleValue) })))
        }

        // ImageIO gives degrees as one number; GPS stores degrees, minutes and seconds.
        if let latitude = number(gps, kCGImagePropertyGPSLatitude), let longitude = number(gps, kCGImagePropertyGPSLongitude),
           abs(latitude) <= 90, abs(longitude) <= 180 {
            self.gps = [(0, .bytes([2, 3, 0, 0])),
                        (1, .ascii(text(gps, kCGImagePropertyGPSLatitudeRef) ?? (latitude < 0 ? "S" : "N"))), (2, .rationals(Self.sexagesimal(abs(latitude)))),
                        (3, .ascii(text(gps, kCGImagePropertyGPSLongitudeRef) ?? (longitude < 0 ? "W" : "E"))), (4, .rationals(Self.sexagesimal(abs(longitude))))]
            if let altitude = number(gps, kCGImagePropertyGPSAltitude) {
                let below = (gps[kCGImagePropertyGPSAltitudeRef as String] as? NSNumber)?.intValue == 1
                self.gps += [(5, .bytes([below ? 1 : 0])), (6, .rationals([Self.unsigned(abs(altitude))]))]
            }
            if let time = text(gps, kCGImagePropertyGPSTimeStamp) {
                let parts = time.split(separator: ":").compactMap { Double($0) }
                if parts.count == 3 { self.gps.append((7, .rationals(parts.map(Self.unsigned)))) }
            }
            if let direction = number(gps, kCGImagePropertyGPSImgDirection) {
                self.gps += [(16, .ascii(text(gps, kCGImagePropertyGPSImgDirectionRef) ?? "T")), (17, .rationals([Self.unsigned(direction)]))]
            }
            if let date = text(gps, kCGImagePropertyGPSDateStamp) { self.gps.append((29, .ascii(date))) }
        }
    }

    /// IFD 0 with the camera, author and description of the source in place of the generic ones. The camera profile
    /// stays the generic linear-sRGB one (UniqueCameraModel), so the decoder applies no camera-specific processing to
    /// pixels that already had it.
    func ifd0(_ entries: [(UInt16, TIFFValue)]) -> [(UInt16, TIFFValue)] {
        let camera = [make, model].filter { !$0.isEmpty }.joined(separator: " ")
        var replaced: [(UInt16, TIFFValue)] = [
            (270, .ascii(merged ? (camera.isEmpty ? "\(process) merged in Ceviche" : "\(process) merged in Ceviche from \(camera) photos")
                                : (camera.isEmpty ? "\(process) in Ceviche" : "\(process) in Ceviche from a \(camera) photo"))),
            (305, .ascii("Ceviche \(process)")), (50708, .ascii("Ceviche \(process) Linear sRGB")),
        ]
        replaced += [(271, .ascii(make.isEmpty ? "Ceviche" : make)), (272, .ascii(model.isEmpty ? process : model))]
        replaced += tiff
        let tags = Set(replaced.map(\.0))
        return entries.filter { !tags.contains($0.0) } + replaced
    }

    /// An unsigned rational: 1/n for exposure times such as 1/250 s, otherwise four decimals.
    static func unsigned(_ value: Double) -> (UInt32, UInt32) {
        guard value.isFinite, value > 0 else { return (0, 1) }
        if value < 1, abs(1 / value - (1 / value).rounded()) < 1e-3 { return (1, UInt32(min(4e9, (1 / value).rounded()))) }
        return (UInt32(min(4.2e9, (value * 10_000).rounded())), 10_000)
    }
    static func sexagesimal(_ degrees: Double) -> [(UInt32, UInt32)] {
        let whole = degrees.rounded(.down), minutes = ((degrees - whole) * 60).rounded(.down)
        let seconds = ((degrees - whole) * 60 - minutes) * 60
        return [(UInt32(whole), 1), (UInt32(minutes), 1), (UInt32(min(4.2e9, (seconds * 10_000).rounded())), 10_000)]
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
