import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CevicheCore

/// Prints sheets at their physical size, `dpi` pixels to the inch, one to a page, on paper of that size when the
/// printer has it.
enum IDPhotoPrinting {
    @MainActor static func print(_ pages: [CGImage], dpi: Double, title: String) {
        guard let first = pages.first else { return }
        let size = NSSize(width: Double(first.width) / dpi * 72, height: Double(first.height) / dpi * 72)
        let view = PrintPagesView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height * Double(pages.count)))
        view.pages = pages; view.pageSize = size
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.paperSize = size
        info.orientation = size.width > size.height ? .landscape : .portrait
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        info.horizontalPagination = .clip; info.verticalPagination = .clip
        info.isHorizontallyCentered = true; info.isVerticallyCentered = true
        info.scalingFactor = 1
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = title
        operation.showsPrintPanel = true; operation.showsProgressPanel = true
        operation.printPanel.options.insert([.showsPaperSize, .showsOrientation, .showsPreview, .showsCopies])
        if let window = NSApp.keyWindow { operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil) }
        else { operation.run() }
    }
}

/// The sheets stacked top to bottom, one per page.
private final class PrintPagesView: NSView {
    var pages: [CGImage] = []
    var pageSize = NSSize.zero
    override var isFlipped: Bool { true }
    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: pages.count)
        return true
    }
    override func rectForPage(_ page: Int) -> NSRect {
        NSRect(x: 0, y: Double(page - 1) * pageSize.height, width: pageSize.width, height: pageSize.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // The printer driver resamples to its own resolution.
        context.interpolationQuality = .high
        for (index, page) in pages.enumerated() {
            let rect = NSRect(x: 0, y: Double(index) * pageSize.height, width: pageSize.width, height: pageSize.height)
            guard rect.intersects(dirtyRect) else { continue }
            // Flipped view: draw the image upright.
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
            context.draw(page, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        }
    }
}
