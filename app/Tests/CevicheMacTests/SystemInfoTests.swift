import XCTest
import SwiftUI
import AppKit
@testable import CevicheMac

final class SystemInfoTests: XCTestCase {
    private func fixture(os: Int = 15, metal: Bool = true, ram: UInt64 = 16, budget: UInt64? = 8, unified: Bool = true) -> SystemInfo {
        SystemInfo(model: "Mac", cpu: "Test CPU", logicalCPUs: 8, architecture: "arm64",
                   osVersion: OperatingSystemVersion(majorVersion: os, minorVersion: 0, patchVersion: 0),
                   ram: ram * 1_073_741_824, gpu: metal ? "Test GPU" : nil, metalReady: metal,
                   unifiedMemory: metal ? unified : nil, gpuBudget: budget.map { $0 * 1_073_741_824 },
                   maxBuffer: metal ? 4 * 1_073_741_824 : nil, modelsFound: 0, appVersion: "1.0")
    }

    func testRequirementsAndCapacityGuidanceAreSeparate() {
        XCTAssertTrue(fixture().meetsRequirements)
        XCTAssertFalse(fixture(os: 14).meetsRequirements)
        XCTAssertFalse(fixture(metal: false).meetsRequirements)
        let limited = fixture(ram: 4, budget: 1)
        XCTAssertTrue(limited.meetsRequirements, "Capacity thresholds are advice, not unsupported-hardware gates")
        XCTAssertTrue(limited.limitedRAM); XCTAssertTrue(limited.limitedGPU)
        XCTAssertEqual(limited.diagnosis.count, 2)
        XCTAssertFalse(fixture(ram: 8, budget: 2).limitedRAM)
        XCTAssertFalse(fixture(ram: 8, budget: 2).limitedGPU)
    }

    func testUnavailableBudgetIsNotZeroOrFreeVRAM() {
        let unknown = fixture(budget: nil)
        XCTAssertTrue(unknown.meetsRequirements)
        XCTAssertFalse(unknown.limitedGPU)
        XCTAssertEqual(unknown.diagnosis.count, 1)
        XCTAssertNotEqual(SystemInfo.memory(nil), SystemInfo.memory(0))
        XCTAssertNotEqual(fixture().memoryType, fixture(unified: false).memoryType)
        XCTAssertTrue(fixture().report.contains("Test GPU"))
        XCTAssertTrue(fixture().report.contains(SystemInfo.memory(8 * 1_073_741_824)))
    }

    @MainActor func testSystemInfoSnapshots() async throws {
        guard ProcessInfo.processInfo.environment["CEVICHE_UI_SNAPSHOTS"] == "1" else { throw XCTSkip("Optional snapshots") }
        for limited in [false, true] {
            let info = limited ? fixture(ram: 4, budget: 1) : SystemInfo.capture()
            XCTAssertGreaterThan(info.ram, 0); XCTAssertGreaterThan(info.logicalCPUs, 0)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 620), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: SystemInfoView(snapshot: info).preferredColorScheme(limited ? .dark : .light))
            window.contentView = host; window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .seconds(1)); host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let suffix = limited ? "limited" : "actual"
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/ceviche-system-info-\(suffix).png"))
            window.close()
        }
    }
}
