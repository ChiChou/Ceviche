import Foundation
import CoreGraphics
import UniformTypeIdentifiers

extension IDPhotoMatte {
    /// Whether the matte is to be made now: the layout replaces the background and no matte is made, being made or
    /// failed. A failure stays until Replace is turned on afresh.
    public static func needed(for layout: IDPhotoLayout?, made: Bool, making: Bool, failed: Bool) -> Bool {
        layout?.background != nil && !made && !making && !failed
    }

    /// The matte a render of `layout` takes: only while it replaces the background.
    public static func used(_ matte: CGImage?, by layout: IDPhotoLayout) -> CGImage? {
        layout.background == nil ? nil : matte
    }

    /// Makes the matte for `preview` off the caller's actor: the matte, or why it couldn't be made.
    public static func making(_ preview: CGImage) async -> Result<CGImage, Error> {
        await Task.detached(priority: .userInitiated) { Result { try make(preview) } }.value
    }
}

extension IDPhotoLayout {
    /// The layout the checks measure: a background that couldn't be replaced is checked as it is.
    public func checked(matteFailed: Bool) -> IDPhotoLayout {
        var checked = self
        if matteFailed { checked.background = nil }
        return checked
    }
}

extension IDPhotoRenderer {
    /// The digital file's name for a photo named `stem`.
    public static func digitalName(stem: String, spec: IDPhotoSpec) -> String { "\(stem)-\(spec.id).jpg" }

    /// The resolution that puts `width` pixels across the document's width.
    public static func digitalDPI(width: Int, spec: IDPhotoSpec) -> Double { Double(width) / spec.widthMM * 25.4 }

    /// Writes the digital print as a JPEG at the document's resolution, within its file-size limit.
    public static func writeDigital(_ image: CGImage, spec: IDPhotoSpec, to url: URL) throws {
        try write(image, to: url, type: .jpeg, dpi: digitalDPI(width: image.width, spec: spec), maxKB: spec.digital?.maxKB)
    }
}
