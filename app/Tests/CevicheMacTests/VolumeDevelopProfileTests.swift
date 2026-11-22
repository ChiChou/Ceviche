import XCTest
import CevicheCore
@testable import CevicheMac

/// The Develop view's own path with Volume on and off: the editor model a slider drives, its debounced renders and the
/// 100 % detail tile, minus the drawing. Opt-in: CEVICHE_DEVELOP_PROFILE is a wide-angle RAW, and
/// CEVICHE_DEVELOP_PROFILE_DNG optionally a linear DNG to compare opening against. Run in release:
/// `swift test -c release -Xswiftc -enable-testing --filter VolumeDevelopProfileTests`.
final class VolumeDevelopProfileTests: XCTestCase {
    private func ms(_ since: Date) -> Double { Date().timeIntervalSince(since) * 1000 }

    /// Watches `preview` change while `drag` runs, then until the last render lands.
    @MainActor private func drag(_ model: EditorModel, steps: Int, _ step: (Int) -> Void) async -> (frames: Int, stepCPU: Double, settle: Double) {
        var shown = 0, last = model.preview
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if model.preview !== last { shown += 1; last = model.preview }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        model.beginGesture()
        var cpu: [Double] = []
        for i in 0..<steps {
            let t = Date(); step(i); cpu.append(ms(t))
            try? await Task.sleep(for: .milliseconds(16))   // a 60 Hz drag
        }
        model.endGesture()
        let end = Date()
        while model.isRendering { try? await Task.sleep(for: .milliseconds(2)) }
        let settle = ms(end)
        try? await Task.sleep(for: .milliseconds(20))
        watcher.cancel()
        return (shown, cpu.sorted()[cpu.count / 2], settle)
    }
    @MainActor private func detail(_ model: EditorModel, at region: CGRect = CGRect(x: 0.6, y: 0.35, width: 0.25, height: 0.25)) async -> Double {
        model.detail = nil; model.requestDetail(nil)
        let t = Date()
        model.requestDetail(region, photoWidth: Double(model.info?.width ?? 6000), settle: .zero)
        while model.detail == nil { try? await Task.sleep(for: .milliseconds(5)); if ms(t) > 30_000 { break } }
        return ms(t)
    }

    @MainActor func testDevelopWithVolume() async throws {
        guard let path = ProcessInfo.processInfo.environment["CEVICHE_DEVELOP_PROFILE"] else { throw XCTSkip("set CEVICHE_DEVELOP_PROFILE") }
        let model = EditorModel(preferences: UserDefaults(suiteName: UUID().uuidString)!)
        var t = Date()
        let opened = await model.open(URL(fileURLWithPath: path))
        XCTAssertTrue(opened)
        while model.isRendering || model.preview == nil { try? await Task.sleep(for: .milliseconds(2)) }
        print(String(format: "PROFILE open RAW to first preview %.0f ms (%@, %d × %d)", ms(t), model.info?.filename ?? "", model.info?.width ?? 0, model.info?.height ?? 0))
        model.toolTab = .crop
        while model.isRendering { try? await Task.sleep(for: .milliseconds(2)) }

        for (name, on) in [("off", false), ("spherical 50 %", true)] {
            if on {
                model.setVolume { $0.mode = .spherical; $0.amount = 50 }
                while model.isRendering { try? await Task.sleep(for: .milliseconds(2)) }
            }
            // Exposure dragged for two seconds: every frame re-renders the warp when Volume is on.
            let base = model.adjustments.exposure
            let e = await drag(model, steps: 120) { i in model.edit { $0.exposure = base + Double(i) * 0.01 } }
            print(String(format: "PROFILE volume %@  exposure drag: %d frames in 2 s, step %.2f ms, settle %.0f ms", name, e.frames, e.stepCPU, e.settle))
            model.edit { $0.exposure = base }
            while model.isRendering { try? await Task.sleep(for: .milliseconds(2)) }
            for (place, region) in [("side", CGRect(x: 0.7, y: 0.35, width: 0.25, height: 0.25)), ("centre", CGRect(x: 0.375, y: 0.375, width: 0.25, height: 0.25)),
                                    ("side again", CGRect(x: 0.7, y: 0.35, width: 0.25, height: 0.25)), ("corner", CGRect(x: 0.02, y: 0.02, width: 0.25, height: 0.25))] {
                let tile = await detail(model, at: region)
                print(String(format: "PROFILE volume %@  100 %% detail tile %@ %.0f ms", name, place, tile))
            }
            let s = await drag(model, steps: 60) { i in model.setStraighten(Double(i) * 0.05) }
            print(String(format: "PROFILE volume %@  straighten drag: step %.2f ms, settle %.0f ms", name, s.stepCPU, s.settle))
            model.setStraighten(0)
            while model.isRendering { try? await Task.sleep(for: .milliseconds(2)) }
        }
        // Volume's own slider, from 0 to 100: Constrain Crop refits on every step.
        model.resetVolume()
        while model.isRendering { try? await Task.sleep(for: .milliseconds(2)) }
        model.setVolume { $0.mode = .horizontal }
        let v = await drag(model, steps: 100) { i in model.setVolume { $0.amount = Double(i + 1) } }
        print(String(format: "PROFILE amount drag: %d frames in 1.6 s, step %.2f ms, settle %.0f ms", v.frames, v.stepCPU, v.settle))
        let s = await drag(model, steps: 100) { i in model.setStraighten(Double(i) * 0.05) }
        print(String(format: "PROFILE straighten drag (with Volume): %d frames, step %.2f ms, settle %.0f ms", s.frames, s.stepCPU, s.settle))

        if let dng = ProcessInfo.processInfo.environment["CEVICHE_DEVELOP_PROFILE_DNG"] {
            let copy = EditorModel(preferences: UserDefaults(suiteName: UUID().uuidString)!)
            t = Date()
            _ = await copy.open(URL(fileURLWithPath: dng))
            while copy.isRendering || copy.preview == nil { try? await Task.sleep(for: .milliseconds(2)) }
            print(String(format: "PROFILE open linear DNG to first preview %.0f ms (%d × %d)", ms(t), copy.info?.width ?? 0, copy.info?.height ?? 0))
            let base = copy.adjustments.exposure
            let e = await drag(copy, steps: 120) { i in copy.edit { $0.exposure = base + Double(i) * 0.01 } }
            print(String(format: "PROFILE linear DNG exposure drag: %d frames in 2 s, step %.2f ms, settle %.0f ms", e.frames, e.stepCPU, e.settle))
            let tile = await detail(copy)
            print(String(format: "PROFILE linear DNG 100 %% detail tile %.0f ms", tile))
        }
    }
}
