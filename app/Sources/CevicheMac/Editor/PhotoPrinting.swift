import SwiftUI
import AppKit
import CevicheCore

extension CatalogModel {
    @discardableResult
    func printPhotos(_ assets: [CatalogAsset], filters: CreativeFilterStack? = nil) -> UUID? {
        guard canStartJob, !assets.isEmpty else { return nil }
        let name = assets.count == 1 ? assets[0].filename : L10n.tr("\(assets.count) photos")
        return ActivityCenter.shared.start(.exporting, title: L10n.tr("Preparing \(name) to print")) { [weak self] job in
            guard let self else { return }
            do {
                let document = try await PhotoPrintDocument.make(assets: assets, catalog: self, filters: filters)
                try Task.checkCancellation()
                ActivityCenter.shared.finish(job, outcome: .done(""))
                PhotoPrinting.run(document: document, title: name)
            } catch is CancellationError {
            } catch {
                self.failure = Failure(L10n.tr("Couldn’t Print"), error)
                ActivityCenter.shared.finish(job, outcome: .failed(error.localizedDescription))
            }
        }
    }
}

/// Prints the open photo: one sheet, the photo fitted to the paper or filling it, with the printer or the proof's
/// profile managing colour. Paper, printer and copies are the system print panel's; what is the photo's own sits in
/// the panel's Ceviche pane.
@MainActor
enum PhotoPrinting {
    static func run(document: PhotoPrintDocument, title: String) {
        guard let first = document.pages.first else { return }
        let options = PhotoPrintOptions(profile: document.profile)
        let view = PhotoPrintView(document: document, options: options)
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.orientation = first.size.width > first.size.height ? .landscape : .portrait
        info.horizontalPagination = .clip; info.verticalPagination = .clip
        info.isHorizontallyCentered = false; info.isVerticallyCentered = false
        info.scalingFactor = 1
        view.fit(info)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = title
        operation.showsPrintPanel = true; operation.showsProgressPanel = true
        operation.printPanel.options.insert([.showsPaperSize, .showsOrientation, .showsPreview, .showsCopies, .showsPageRange])
        operation.printPanel.addAccessoryController(options)
        if let window = NSApp.keyWindow { operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil) }
        else { operation.run() }
    }
}

/// The photo's own print choices, shown as a pane of the print panel and remembered between prints.
final class PhotoPrintOptions: NSViewController, NSPrintPanelAccessorizing {
    @objc dynamic var fill: Bool { didSet { defaults.set(fill, forKey: "printFill") } }
    /// Millimetres kept clear on every side, on top of what the printer can't reach.
    @objc dynamic var margin: Double { didSet { defaults.set(margin, forKey: "printMargin") } }
    /// The proof's profile converts the colours, rather than the printer.
    @objc dynamic var managed: Bool { didSet { defaults.set(managed, forKey: "printManaged") } }
    private let profile: String?
    private let defaults = UserDefaults.standard

    init(profile: String?) {
        self.profile = profile
        fill = defaults.bool(forKey: "printFill")
        margin = defaults.double(forKey: "printMargin")
        managed = profile != nil && (defaults.object(forKey: "printManaged") as? Bool ?? true)
        super.init(nibName: nil, bundle: nil)
        title = "Ceviche"
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let mode = NSSegmentedControl(labels: [L10n.tr("Fit"), L10n.tr("Fill")], trackingMode: .selectOne, target: self, action: #selector(sizeChanged))
        mode.selectedSegment = fill ? 1 : 0
        let field = NSTextField(string: Self.number.string(from: margin as NSNumber) ?? "0")
        field.formatter = Self.number; field.alignment = .right; field.target = self; field.action = #selector(marginChanged)
        // Leaving the field sets the margin too, not only Return.
        field.cell?.sendsActionOnEndEditing = true
        field.widthAnchor.constraint(equalToConstant: 52).isActive = true
        let stepper = NSStepper()
        stepper.minValue = 0; stepper.maxValue = 100; stepper.increment = 1; stepper.doubleValue = margin
        stepper.target = self; stepper.action = #selector(marginStepped)
        marginField = field; marginStepper = stepper
        let colour = NSPopUpButton(frame: .zero, pullsDown: false)
        colour.addItem(withTitle: L10n.tr("Printer"))
        if let profile { colour.addItem(withTitle: profile) }
        colour.selectItem(at: managed ? 1 : 0); colour.isEnabled = profile != nil
        colour.target = self; colour.action = #selector(colourChanged)
        colour.toolTip = L10n.tr("With a profile, turn colour management off in the printer’s own settings, or the colours are converted twice.")
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: L10n.tr("Size")), mode],
            [NSTextField(labelWithString: L10n.tr("Margin")), NSStackView(views: [field, stepper, NSTextField(labelWithString: L10n.tr("mm"))])],
            [NSTextField(labelWithString: L10n.tr("Color")), colour],
        ])
        grid.column(at: 0).xPlacement = .trailing; grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10; grid.columnSpacing = 8
        // The print panel sizes a pane by its view's frame, not by its constraints.
        let fitting = grid.fittingSize, size = NSSize(width: max(320, fitting.width + 40), height: fitting.height + 28)
        grid.frame = NSRect(x: ((size.width - fitting.width) / 2).rounded(), y: 14, width: fitting.width, height: fitting.height)
        grid.autoresizingMask = [.minXMargin, .maxXMargin]
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.addSubview(grid)
        view = container
        preferredContentSize = size
    }
    private static let number: NumberFormatter = {
        let formatter = NumberFormatter(); formatter.numberStyle = .decimal; formatter.minimum = 0; formatter.maximum = 100; formatter.maximumFractionDigits = 1
        return formatter
    }()
    @objc private func sizeChanged(_ sender: NSSegmentedControl) { fill = sender.selectedSegment == 1 }
    private weak var marginField: NSTextField?, marginStepper: NSStepper?
    @objc private func marginChanged(_ sender: NSTextField) { margin = min(100, max(0, sender.doubleValue)); marginStepper?.doubleValue = margin }
    @objc private func marginStepped(_ sender: NSStepper) { margin = sender.doubleValue; marginField?.doubleValue = margin }
    @objc private func colourChanged(_ sender: NSPopUpButton) { managed = sender.indexOfSelectedItem == 1 }

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] { [] }
    func keyPathsForValuesAffectingPreview() -> Set<String> { ["fill", "margin", "managed"] }
}

/// Full-resolution pages live in a local temporary directory for the print operation's lifetime. A selection
/// doesn't retain every decoded photo in memory; only the page being drawn is loaded.
@MainActor
final class PhotoPrintDocument {
    struct Page {
        let photo: URL
        let managed: URL?
        let size: CGSize
    }
    let directory: URL
    private(set) var pages: [Page] = []
    private(set) var profile: String?

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ceviche-Print-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    static func make(assets: [CatalogAsset], catalog: CatalogModel,
                     filters: CreativeFilterStack? = nil) async throws -> PhotoPrintDocument {
        guard let store = catalog.store, !assets.isEmpty else { throw EditorError.render }
        let document = try PhotoPrintDocument()
        for asset in assets {
            try Task.checkCancellation()
            let url = try await catalog.resolveOriginal(asset)
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let current = try await store.asset(asset.id)
            let saved = try await store.savedAdjustments(of: current)
            let (renderer, defaults) = try await Task.detached(priority: .userInitiated) { try RawRenderer.open(url) }.value
            try await document.append(renderer: renderer, adjustments: saved ?? defaults, filters: filters)
        }
        return document
    }

    /// Printing starts from the full developed image, independent of all export preferences.
    static var settings: ExportSettings {
        var settings = ExportSettings()
        settings.setHDR(false); settings.select(.tiff); settings.depth = 16
        settings.profile = ColorProfile(); settings.profile.preset = .proPhoto
        settings.includeMetadata = false; settings.preserveAlpha = false
        return settings
    }

    func append(renderer: RawRenderer, adjustments: Adjustments,
                filters: CreativeFilterStack? = nil, proof: PrintProofState.Active? = nil) async throws {
        try Task.checkCancellation()
        let url = directory.appendingPathComponent("\(pages.count).tiff")
        try await renderer.export(to: url, adjustments: adjustments, settings: Self.settings, filters: filters)
        try Task.checkCancellation()
        let proof = proof.flatMap { $0.profile.isRGB ? $0 : nil }
        let managedURL = proof.map { _ in directory.appendingPathComponent("\(pages.count)-managed.tiff") }
        let size = try await Task.detached(priority: .userInitiated) { () -> CGSize in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let photo = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw EditorError.render }
            if let proof, let managedURL {
                let image = try proof.profile.separated(photo, settings: proof.settings)
                guard let destination = CGImageDestinationCreateWithURL(managedURL as CFURL, "public.tiff" as CFString, 1, nil) else { throw EditorError.render }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw EditorError.render }
            }
            return CGSize(width: photo.width, height: photo.height)
        }.value
        try Task.checkCancellation()
        pages.append(Page(photo: url, managed: managedURL, size: size))
        profile = proof?.profile.name
    }
}

/// One photo per page, fitted or filled within the printer's reachable area.
private final class PhotoPrintView: NSView {
    private let document: PhotoPrintDocument, options: PhotoPrintOptions
    private var pageSize = CGSize.zero
    private var paperRect = NSRect.zero
    init(document: PhotoPrintDocument, options: PhotoPrintOptions) {
        self.document = document; self.options = options
        super.init(frame: .zero)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func fit(_ info: NSPrintInfo) {
        let paper = info.paperSize, reach = info.imageablePageBounds
        info.leftMargin = reach.minX; info.bottomMargin = reach.minY
        info.rightMargin = max(0, paper.width - reach.maxX); info.topMargin = max(0, paper.height - reach.maxY)
        pageSize = reach.size
        setFrameSize(CGSize(width: reach.width, height: reach.height * Double(document.pages.count)))
        paperRect = NSRect(x: -reach.minX, y: -reach.minY, width: paper.width, height: paper.height)
    }
    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        if let info = NSPrintOperation.current?.printInfo { fit(info) }
        range.pointee = NSRange(location: 1, length: document.pages.count)
        return true
    }
    override func rectForPage(_ page: Int) -> NSRect {
        NSRect(x: 0, y: Double(page - 1) * pageSize.height, width: pageSize.width, height: pageSize.height)
    }
    private var cached: (url: URL, pixels: Int, image: CGImage)?
    private func image(at url: URL, pixels: Int) -> CGImage? {
        if let cached, cached.url == url, cached.pixels == pixels { return cached.image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var image = full
        let long = max(full.width, full.height)
        if pixels > 0, pixels < long, let space = full.colorSpace {
            let scale = Double(pixels) / Double(long)
            let width = max(1, Int((Double(full.width) * scale).rounded()))
            let height = max(1, Int((Double(full.height) * scale).rounded()))
            if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0, space: space,
                                       bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue) {
                context.interpolationQuality = .high
                context.draw(full, in: CGRect(x: 0, y: 0, width: width, height: height))
                image = context.makeImage() ?? full
            }
        }
        cached = (url, pixels, image)
        return image
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        var area = NSRect(origin: .zero, size: pageSize)
        let margin = options.margin / 25.4 * 72
        if margin > 0 { area = area.intersection(paperRect.insetBy(dx: margin, dy: margin)) }
        guard area.width > 1, area.height > 1 else { return }
        for (index, page) in document.pages.enumerated() {
            let rect = rectForPage(index + 1)
            guard rect.intersects(dirtyRect) else { continue }
            let scale = options.fill ? max(area.width / page.size.width, area.height / page.size.height)
                                     : min(area.width / page.size.width, area.height / page.size.height)
            let size = CGSize(width: page.size.width * scale, height: page.size.height * scale)
            let pixels = NSGraphicsContext.currentContextDrawingToScreen() ? 1600 : Int(ceil(max(size.width, size.height) / 72 * 360))
            guard let photo = image(at: options.managed ? page.managed ?? page.photo : page.photo, pixels: pixels) else { continue }
            context.saveGState()
            context.translateBy(x: 0, y: rect.minY)
            context.clip(to: area)
            context.interpolationQuality = .high
            context.draw(photo, in: CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height))
            context.restoreGState()
        }
    }
}
