import Foundation

/// What a Timelapse latent image keeps: the video's settings, framing included, and the photos left out of it.
public struct TimelapseLatent: Codable, Equatable, Sendable {
    public var settings: TimelapseSettings
    /// Asset IDs of sources left out of the video.
    public var removed: [String]
    public init(settings: TimelapseSettings, removed: Set<String>) { self.settings = settings; self.removed = removed.sorted() }
}

extension LatentImage {
    public static let timelapse = "timelapse"
    /// A Timelapse video's photos and settings, `width` × `height` the video's frame.
    public init(id: String = UUID().uuidString, catalogID: String, sources: [Source], timelapse: TimelapseLatent, width: Int, height: Int) throws {
        self.init(type: Self.timelapse, id: id, catalogID: catalogID, sources: sources, settings: try JSONEncoder().encode(timelapse),
                  analysisID: "", width: width, height: height, alignedAllSky: false, alignedStrokes: [])
    }
    public func timelapseSettings() throws -> TimelapseLatent {
        guard type == Self.timelapse else { throw Self.invalid() }
        let saved = try JSONDecoder().decode(TimelapseLatent.self, from: settings)
        guard Set(saved.removed).isSubset(of: sources.map(\.assetID)), saved.removed.count < sources.count - 1 else { throw Self.invalid() }
        return saved
    }
}
