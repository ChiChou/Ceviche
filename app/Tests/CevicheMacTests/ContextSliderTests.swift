import XCTest
import AppKit
@testable import CevicheMac

final class ContextSliderTests: XCTestCase {
    @MainActor func testColoredSliderRetainsAccessibilityActionsAndReset() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let slider = DoubleClickSlider(frame: NSRect(x: 0, y: 0, width: 240, height: 20))
        let cell = ContextSliderCell(); cell.appearance = .tint; slider.cell = cell
        slider.minValue = -150; slider.maxValue = 150; slider.doubleValue = 0
        slider.target = slider; slider.action = #selector(DoubleClickSlider.changed)
        var values: [Double] = []
        slider.onChange = { values.append($0) }
        slider.onReset = { slider.doubleValue = -3 }
        window.contentView?.addSubview(slider); window.makeKeyAndOrderFront(nil)
        XCTAssertEqual(cell.accessibilityRole(), .slider)
        _ = cell.accessibilityPerformIncrement()
        XCTAssertGreaterThan(slider.doubleValue, 0)
        XCTAssertEqual(values.last, slider.doubleValue)
        _ = cell.accessibilityPerformDecrement()
        XCTAssertEqual(slider.doubleValue, 0, accuracy: 0.01)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        slider.mouseDown(with: event); XCTAssertEqual(slider.doubleValue, -3)
        slider.isEnabled = false; slider.doubleValue = 10
        slider.mouseDown(with: event); XCTAssertEqual(slider.doubleValue, 10)
    }
    @MainActor func testFormSliderDiscreteAccessibilityHonorsStepBoundsAndDisabledState() {
        let slider = FormSliderView(frame: NSRect(x: 0, y: 0, width: 240, height: 20))
        let cell = FormSliderCell(); slider.cell = cell
        slider.minValue = -40; slider.maxValue = 40; slider.doubleValue = 0; slider.step = 4
        var values: [Double] = []
        slider.onChange = { values.append($0) }
        XCTAssertTrue(cell.accessibilityPerformIncrement())
        XCTAssertEqual(values.last, 4)
        XCTAssertTrue(cell.accessibilityPerformDecrement())
        XCTAssertEqual(values.last, 0)
        slider.doubleValue = 40
        XCTAssertTrue(cell.accessibilityPerformIncrement())
        XCTAssertEqual(values.last, 40)
        slider.isEnabled = false
        XCTAssertFalse(cell.accessibilityPerformDecrement())
        XCTAssertEqual(slider.doubleValue, 40)
    }

}
