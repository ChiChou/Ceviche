import XCTest
import CoreImage
@testable import CevicheCore

/// Opt-in, full-resolution comparison. Use a local copy of the RAW and a local output directory.
/// Rendering success is not a visual-quality assertion.
final class DefringeParameterSweepTests: XCTestCase {
    func testParameterSweep() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["CEVICHE_DEFRINGE_RAW"],
              let directory = env["CEVICHE_DEFRINGE_REVIEW_DIR"] else {
            throw XCTSkip("Set CEVICHE_DEFRINGE_RAW and CEVICHE_DEFRINGE_REVIEW_DIR")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let renderer = try RawRenderer(sourceURL: URL(fileURLWithPath: input))
        try await renderer.parameterSweep(output: output)
    }
}

private extension RawRenderer {
    // Diagnostic only: compare the legacy hue correction with stronger, wider edge support.
    func hueProbe(_ image: CIImage, mode: String) throws -> CIImage {
        let kernel = try XCTUnwrap(CIKernel.kernels(withMetalString: """
        #include <metal_stdlib>
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        extern "C" [[stitchable]] float4 probe(coreimage::sample_t s, coreimage::sample_t edge, float low) {
            float3 c=s.rgb;
            float hi=max(c.r,max(c.g,c.b)),lo=min(c.r,min(c.g,c.b)),d=hi-lo;
            if(d<0.00001) return s;
            float h=(hi==c.r ? (c.g-c.b)/d : hi==c.g ? 2.0+(c.b-c.r)/d : 4.0+(c.r-c.g)/d)*60.0;
            if(h<0.0) h+=360.0;
            if(h<60.0) h+=360.0;
            float p=(h-240.0)/1.2;
            float weight=smoothstep(low-5.0,low,p)*(1.0-smoothstep(100.0,105.0,p));
            float strength=weight*clamp(max(edge.r,max(edge.g,edge.b))*32.0,0.0,1.0);
            float y=dot(c,float3(0.2126,0.7152,0.0722));
            return float4(mix(c,float3(y),strength),s.a);
        }
        """).first)
        let edges: CIImage
        if mode == "probe-hue-ungated" {
            edges = CIImage(color: CIColor.white).cropped(to: image.extent)
        } else {
            edges = image.clampedToExtent().applyingFilter("CILinearToSRGBToneCurve")
                .applyingFilter("CIEdges", parameters: ["inputIntensity": 2])
                .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": 12])
                .cropped(to: image.extent)
        }
        return try XCTUnwrap(kernel.apply(extent: image.extent, roiCallback: { _, r in r },
            arguments: [image, edges, mode == "probe-hue-broad-narrow" ? 30.0 : 0.0]))
    }

    func parameterSweep(output: URL) throws {
        var variants: [(String, Defringe)] = [("before", Defringe())]
        var p = Defringe()
        p.purpleAmount = 20; p.greenAmount = 20
        variants.append(("hue-default", p))
        p.purpleLow = 0; p.purpleHigh = 100; p.greenLow = 0; p.greenHigh = 100
        variants.append(("hue-wide", p))
        for name in ["probe-hue-ungated", "probe-hue-broad", "probe-hue-broad-narrow"] {
            variants.append((name, Defringe()))
        }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        var recipes: [String: Defringe] = [:]
        for (name, settings) in variants {
            let env = ProcessInfo.processInfo.environment
            if let selected = env["CEVICHE_DEFRINGE_VARIANTS"], !selected.split(separator: ",").contains(Substring(name)) { continue }
            if !name.hasPrefix("probe-") { recipes[name] = settings }
            var a = info.defaults; a.defringe = settings
            var full = try pipeline(a, maxDimension: nil)
            if name.hasPrefix("probe-") {
                full = try hueProbe(full, mode: name)
            }
            if env["CEVICHE_DEFRINGE_FULL"] == name {
                try context.writePNGRepresentation(of: full, to: output.appendingPathComponent("\(name)-full.png"), format: .RGBA16, colorSpace: srgb)
            }
            let w = full.extent.width, h = full.extent.height
            // Normalized crop regions: a tower, a defocused person, and clothing/foliage controls.
            for (label, nx, ny) in [("tip", 0.335, 0.93), ("lattice", 0.30, 0.62), ("person", 0.78, 0.405), ("shirt", 0.78, 0.34), ("trees", 0.50, 0.35)] {
                let rect = CGRect(x: (w * nx - 320).rounded(), y: (h * ny - 400).rounded(), width: 640, height: 800).intersection(full.extent)
                let crop = full.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
                try context.writePNGRepresentation(of: crop, to: output.appendingPathComponent("\(name)-\(label).png"), format: .RGBA16, colorSpace: srgb)
            }
            let preview = full.transformed(by: CGAffineTransform(scaleX: 1400 / h, y: 1400 / h))
            try context.writePNGRepresentation(of: preview, to: output.appendingPathComponent("\(name)-preview.png"), format: .RGBA16, colorSpace: srgb)
            print("DEFRINGE SWEEP \(name): \(Int(w))x\(Int(h))")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(recipes).write(to: output.appendingPathComponent("recipes.json"))
    }
}
