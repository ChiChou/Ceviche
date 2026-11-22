import Foundation

/// A merge preview as the result's file at preview size: its linear pixels and the writer the result uses. Developing
/// that file shows the preview with the edits and tone response the saved result will have.
public struct MergePreviewSource: @unchecked Sendable {
    let raster: PanoramaRaster
    let writer: ToolResultWriter
    /// The photo the result is based on, by its place in the merge's photos: its edits are the result's.
    public let base: Int

    /// The extension the preview's file needs: DNG for RAW photos, TIFF for processed ones.
    public var fileExtension: String { writer.previewExtension }
    /// Writes the preview to `url`, whose extension is `fileExtension`.
    public func write(to url: URL) throws { try writer.write(raster, to: url) }
}
