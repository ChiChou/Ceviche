import Foundation

/// What a tool that combines photos makes, for naming its result: the first photo's name and the tool's suffix, as
/// in `DSC_0001-Panorama.dng`. Both apps name results from this one table.
public enum MergeOutput: String, CaseIterable, Sendable {
    case hdr, focusStack, stack, panorama, hdrPanorama, starTrails, nightSky, meteorShower, bestFaces, pixelShift, timelapse

    public var suffix: String {
        switch self {
        case .hdr: "HDR"
        case .focusStack: "Focus"
        case .stack: "Stack"
        case .panorama: "Panorama"
        case .hdrPanorama: "HDR-Panorama"
        case .starTrails: "StarTrails"
        case .nightSky: "NightSky"
        case .meteorShower: "Meteors"
        case .bestFaces: "BestFaces"
        case .pixelShift: "PixelShift"
        case .timelapse: "Timelapse"
        }
    }

    /// The result's file name for a first photo named `stem`.
    public func name(stem: String) -> String { "\(stem)-\(suffix)" }
}
