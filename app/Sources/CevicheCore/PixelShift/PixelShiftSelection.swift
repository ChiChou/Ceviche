// Pixel Shift is the Mac app's alone: a sixteen-shot set peaks at 13.8 GB, more than iOS gives an app, so the iPad and
// iPhone build leaves the whole tool out.
#if os(macOS)
import Foundation
import CameraRaw

/// What a selection for Pixel Shift is: one camera's set, read from the files' own headers before any pixels are.
enum PixelShiftSelection {
    case sony([(url: URL, info: SensorFrame)])
    /// One file holding the four exposures.
    case pentax(URL, [SensorFrame])
    case fujifilm([(url: URL, shot: FujifilmShot)])
    /// One file holding the six exposures.
    case hasselblad(URL, HasselbladMultiShot)

    /// Images a camera finishes itself, left out of a selection beside a set's RAW files.
    static let finished: Set<String> = ["jpg", "jpeg", "heic", "heif", "hif", "tif", "tiff", "png"]

    init(_ urls: [URL]) throws {
        let raws = urls.filter { !Self.finished.contains($0.pathExtension.lowercased()) }
        guard let first = raws.first else { throw PanoramaError.message(L10n.tr("Choose the RAW photos of one Pixel Shift set.")) }
        switch first.pathExtension.lowercased() {
        case "raf":
            let shots = try raws.map { url -> (url: URL, shot: FujifilmShot) in
                let shot: FujifilmShot
                do { shot = try FujifilmRAF.shot(url) } catch let error as CameraRawError { throw error.pixelShift(url) }
                guard shot.isPixelShift else { throw PanoramaError.message(L10n.tr("\(url.lastPathComponent) isn’t part of a Pixel Shift set.")) }
                return (url, shot)
            }
            self = .fujifilm(shots)
        case "pef", "dng" where (try? PentaxRAW.frames(first)) != nil:
            guard raws.count == 1 else { throw PanoramaError.message(L10n.tr("Choose one Pentax photo taken with Pixel Shift Resolution.")) }
            let frames: [SensorFrame]
            do { frames = try PentaxRAW.frames(first) } catch let error as CameraRawError { throw error.pixelShift(first) }
            guard PentaxRAW.pixelShiftModels.contains(frames[0].model) else {
                throw PanoramaError.message(L10n.tr("Pixel Shift sets from the \(frames[0].model) aren’t supported yet."))
            }
            guard frames.count == 4 else {
                throw PanoramaError.message(L10n.tr("\(first.lastPathComponent) wasn’t taken with Pixel Shift Resolution."))
            }
            self = .pentax(first, frames)
        case "fff":
            guard raws.count == 1 else { throw PanoramaError.message(L10n.tr("Choose one Hasselblad multi-shot photo.")) }
            do { self = .hasselblad(first, try HasselbladMultiShot.read(first)) }
            catch CameraRawError.unsupportedSensor { throw PanoramaError.message(L10n.tr("\(first.lastPathComponent) isn’t a six-shot photo Pixel Shift supports.")) }
            catch let error as CameraRawError { throw error.pixelShift(first) }
        case "arw":
            guard raws.count == 4 || raws.count == 16 else { throw PanoramaError.message(L10n.tr("Choose the 4 or 16 photos of one Pixel Shift set.")) }
            self = .sony(try raws.map { url in
                do { return (url, try SonyARW.frame(url)) } catch let error as CameraRawError { throw error.pixelShift(url, sony: true) }
            })
        default:
            throw PanoramaError.message(L10n.tr("\(first.lastPathComponent) isn’t from a camera Pixel Shift supports."))
        }
        let kind = first.pathExtension.lowercased() == "dng" ? "pef" : first.pathExtension.lowercased()
        if let other = raws.first(where: { ($0.pathExtension.lowercased() == "dng" ? "pef" : $0.pathExtension.lowercased()) != kind }) {
            throw PanoramaError.message(L10n.tr("\(other.lastPathComponent) is from a different camera or size than \(first.lastPathComponent)."))
        }
    }
}

extension CameraRawError {
    /// The reader's error, worded for the photographer with the file's name.
    func pixelShift(_ url: URL, sony: Bool = false) -> PanoramaError {
        let name = url.lastPathComponent
        switch self {
        case .unreadable: return .message(L10n.tr("\(name) can’t be read."))
        case .notRaw: return .message(sony ? L10n.tr("\(name) isn’t a Sony RAW photo.") : L10n.tr("\(name) isn’t from a camera Pixel Shift supports."))
        case .compressed: return .message(sony ? L10n.tr("\(name) is a compressed RAW. Pixel Shift needs uncompressed RAW files.") : L10n.tr("\(name) can’t be decoded."))
        case .unsupportedSensor: return .message(L10n.tr("\(name) has a sensor Pixel Shift doesn’t support."))
        case .corrupt: return .message(L10n.tr("\(name) can’t be decoded."))
        }
    }
}
#endif
