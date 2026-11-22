import XCTest
import ImageIO
@testable import CevicheCore

/// Export each portrait's actual Heal result and its handle coordinates for visual review.
final class BlemishPortraitTests: XCTestCase {
    func testPortraits() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let inputs = env["CEVICHE_BLEMISH_PORTRAITS"], let destination = env["CEVICHE_BLEMISH_REVIEW"],
              let model = BlemishDetector.modelURL else { throw XCTSkip("Set portrait, output and model directories") }
        let folder = URL(fileURLWithPath: inputs), output = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let images = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "jpg" }
        XCTAssertFalse(images.isEmpty)
        // Manual Face regions, normalized y-up: CEVICHE_FACE_REGIONS="name=x,y,w,h;name=x,y,w,h", names without extension.
        let regions = Dictionary((env["CEVICHE_FACE_REGIONS"] ?? "").split(separator: ";").compactMap { entry -> (String, CGRect)? in
            let parts = entry.split(separator: "=")
            let v = parts.count == 2 ? parts[1].split(separator: ",").compactMap { Double($0) } : []
            return v.count == 4 ? (String(parts[0]), CGRect(x: v[0], y: v[1], width: v[2], height: v[3])) : nil
        }, uniquingKeysWith: { $1 })
        for image in images {
            let renderer = try RawRenderer(sourceURL: image)
            var settings = Adjustments()
            let name = image.deletingPathExtension().lastPathComponent
            let region = regions[name]
            let (faces, strokes) = try await renderer.blemishStrokes(settings, modelURL: model, sensitivity: 0.5, region: region)
            if let region {
                let (_, faint) = try await renderer.blemishStrokes(settings, modelURL: model, sensitivity: 1, region: region)
                try JSONEncoder().encode(faint).write(to: output.appendingPathComponent(name + "-sensitive.json"))
                print("Manual sensitivity 100%: \(name) strokes=\(faint.count)")
            }
            settings.retouch = strokes
            let after = try await renderer.displayImage(settings, maxDimension: 2400, sdr: true)
            try write(after, to: output.appendingPathComponent(name + ".jpg"))
            try JSONEncoder().encode(strokes).write(to: output.appendingPathComponent(name + ".json"))
            var reshape = Adjustments()
            let autoRegion = try await renderer.liquifyRegion(reshape)
            if let box = region ?? autoRegion {
                reshape.faceLiquify = FaceLiquify(region: box, width: -0.75)
                let warped = try await renderer.displayImage(reshape, maxDimension: 2400, sdr: true)
                let original = try await renderer.displayImage(Adjustments(), maxDimension: 2400, sdr: true)
                XCTAssertNotEqual(warped.dataProvider?.data as Data?, original.dataProvider?.data as Data?)
                for (suffix, result) in [("-liquify", warped), ("-original", original)] {
                    let file = output.appendingPathComponent(name + suffix + ".jpg")
                    try write(result, to: file)
                }
            }
            print("Blemish review \(name) faces=\(faces) strokes=\(strokes.count)")
        }
    }

    private func write(_ image: CGImage, to url: URL) throws {
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
    }
}
