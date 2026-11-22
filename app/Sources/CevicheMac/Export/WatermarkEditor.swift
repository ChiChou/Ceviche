import SwiftUI
import AppKit
import CoreImage
import CevicheCore

/// Creates or changes a watermark: from text or from an image with transparency, tiled or in a corner. The preview
/// stamps it on the export's photo, or on a neutral sample when there is none (in Settings), with the same code export
/// uses, at the same proportions.
struct WatermarkEditorDialog: View {
    let original: Watermark
    let isNew: Bool
    let backdrop: CGImage?
    let saved: (Watermark) -> Void
    let deleted: (UUID) -> Void
    @ObservedObject private var store = WatermarkStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Watermark
    /// Both sources are kept while the dialog is open, so switching between them loses neither.
    @State private var usesText: Bool
    @State private var text: WatermarkText
    @State private var image: URL?
    /// Images picked during this edit, removed again unless the saved watermark uses them.
    @State private var picked: [URL] = []
    @State private var thumbnail: NSImage?
    @State private var preview: CGImage?
    @State private var error: String?
    @State private var confirmingDelete = false
    /// A file is being dragged over the preview.
    @State private var dropTargeted = false

    init(original: Watermark, isNew: Bool, backdrop: CGImage?, saved: @escaping (Watermark) -> Void, deleted: @escaping (UUID) -> Void) {
        self.original = original; self.isNew = isNew; self.backdrop = backdrop; self.saved = saved; self.deleted = deleted
        _draft = State(initialValue: original)
        _usesText = State(initialValue: original.text != nil)
        _text = State(initialValue: original.text ?? WatermarkStore.copyright())
        _image = State(initialValue: original.image)
        _thumbnail = State(initialValue: original.image.flatMap { NSImage(contentsOf: $0) })
    }

    /// The watermark as it would be saved now.
    private var current: Watermark {
        var watermark = draft
        watermark.text = usesText ? text : nil
        watermark.image = usesText ? nil : image
        return watermark
    }
    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && (usesText ? !text.string.trimmingCharacters(in: .whitespaces).isEmpty : image != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: isNew ? L10n.tr("New Watermark") : L10n.tr("Edit Watermark"))
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 6) {
                    previewPane.frame(width: 300, height: 300)
                    Text(L10n.tr("Drop an image here to use it as the watermark."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 300)
                }
                VStack(alignment: .leading, spacing: 12) {
                    row(L10n.tr("Name")) { TextField(L10n.tr("Watermark name"), text: $draft.name).textFieldStyle(.formField) }
                    row(L10n.tr("Source")) {
                        FormSegments(title: L10n.tr("Watermark source"), selection: $usesText, options: [true, false], label: { $0 ? L10n.tr("Text") : L10n.tr("Image") })
                    }
                    if usesText { textControls } else { imageControls }
                    Rule()
                    row(L10n.tr("Layout")) {
                        FormSegments(title: L10n.tr("Watermark layout"), selection: Binding(get: { draft.layout }, set: { draft.setLayout($0) }), options: Watermark.Layout.allCases, label: { $0.title })
                    }
                    if draft.layout == .tiled {
                        HStack(spacing: 10) {
                            Text(L10n.tr("Angle")).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                            AngleDial(angle: $draft.angle)
                            Text("\(Int(draft.angle.rounded()))°").monospacedDigit()
                            Spacer(minLength: 0)
                        }
                    }
                    if draft.layout == .corner {
                        // Top-aligned: the two-row picker has no text baseline to line the label up with.
                        HStack(alignment: .top, spacing: 10) {
                            Text(L10n.tr("Corner")).foregroundStyle(.secondary).frame(width: 70, alignment: .leading).padding(.top, 7)
                            CornerPicker(corner: $draft.corner)
                            Spacer(minLength: 0)
                        }
                    }
                    slider(L10n.tr("Size"), value: $draft.scale, in: Watermark.scaleRange, help: L10n.tr("The watermark's long edge, as a share of the photo's short edge"))
                    slider(L10n.tr("Opacity"), value: $draft.opacity, in: Watermark.opacityRange, help: nil)
                    slider(draft.layout == .corner ? L10n.tr("Margin") : L10n.tr("Spacing"), value: $draft.spacing,
                           in: draft.layout == .corner ? 0...0.2 : Watermark.spacingRange,
                           help: draft.layout == .corner ? L10n.tr("Distance from the edges, as a share of the photo's short edge") : L10n.tr("Gap between watermarks, as a share of the photo's short edge"))
                }.frame(width: 330)
            }
            if let error {
                Text(error).foregroundStyle(Theme.error).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if !isNew {
                    Button(L10n.tr("Delete…")) { confirmingDelete = true }.buttonStyle(.destructiveAction)
                }
                Spacer()
                Button(L10n.tr("Cancel"), action: cancel).buttonStyle(.secondaryAction).keyboardShortcut(.cancelAction)
                Button(L10n.tr("Save"), action: save).buttonStyle(.primaryAction).keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .font(.system(size: 12))
        .padding(20)
        .background(Theme.panel)
        .tint(Theme.controlAccent)
        .confirmationDialog(L10n.tr("Delete the watermark “\(original.name)”?"), isPresented: $confirmingDelete) {
            Button(L10n.tr("Delete"), role: .destructive, action: delete)
        } message: { Text(L10n.tr("It is removed from every catalog on this Mac.")) }
        // Re-rendered after each change settles; the preview is small, so this is quick.
        .task(id: current) {
            do {
                try await Task.sleep(for: .milliseconds(80))
                let watermark = current, backdrop = backdrop
                let image = try await Task.detached(priority: .userInitiated) { try WatermarkPreview.render(watermark, over: backdrop) }.value
                try Task.checkCancellation()
                preview = image; error = nil
            } catch is CancellationError {
            } catch { preview = nil; if canSave { self.error = error.localizedDescription } }
        }
    }

    private var previewPane: some View {
        ZStack {
            Theme.ink.opacity(0.08)
            if let preview {
                Image(decorative: preview, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo").font(.system(size: 28)).foregroundStyle(.tertiary)
            }
        }
        .clipped()
        .overlay {
            if dropTargeted { Rectangle().strokeBorder(Theme.accent, lineWidth: 3) }
        }
        .accessibilityLabel(L10n.tr("Watermark preview"))
        // A dropped image becomes the watermark's image, as if picked with Choose….
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL) else { return false }
            useImage(from: url)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    /// Copies the image into the library and switches the watermark to it; files that are not images with transparency
    /// are refused with the reason.
    private func useImage(from source: URL) {
        do {
            let access = source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }
            let url = try store.library.importImage(source)
            picked.append(url); image = url; thumbnail = NSImage(contentsOf: url); usesText = false; error = nil
        } catch { self.error = error.localizedDescription }
    }

    @ViewBuilder private var textControls: some View {
        row(L10n.tr("Text")) { TextField(L10n.tr("Watermark text"), text: $text.string).textFieldStyle(.formField) }
        row(L10n.tr("Font")) {
            let family = FontChoice.family(of: text.fontName), bold = FontChoice.isBold(text.fontName), italic = FontChoice.isItalic(text.fontName)
            HStack(spacing: 8) {
                FormSelect(L10n.tr("Font"), selection: Binding(get: { family }, set: { text.fontName = FontChoice.closest(family: $0, bold: bold, italic: italic) }), valueLabel: family) {
                    ForEach(FontChoice.families, id: \.self) { Text($0).tag($0) }
                }.labelsHidden()
                // Bold and Italic as in a word processor; dimmed when the family has no such face.
                HStack(spacing: 2) {
                    StyleToggle(symbol: "bold", title: L10n.tr("Bold"), isOn: bold,
                                available: FontChoice.name(family: family, bold: !bold, italic: italic) != nil) {
                        if let name = FontChoice.name(family: family, bold: !bold, italic: italic) { text.fontName = name }
                    }
                    StyleToggle(symbol: "italic", title: L10n.tr("Italic"), isOn: italic,
                                available: FontChoice.name(family: family, bold: bold, italic: !italic) != nil) {
                        if let name = FontChoice.name(family: family, bold: bold, italic: !italic) { text.fontName = name }
                    }
                }
            }
        }
        row("") {
            Toggle(L10n.tr("Shadow"), isOn: $text.shadow).toggleStyle(.formCheckbox)
                .help(L10n.tr("A soft dark shadow keeps the white text readable over bright areas"))
        }
    }

    private var imageControls: some View {
        row(L10n.tr("Image")) {
            HStack(spacing: 10) {
                Group {
                    if let thumbnail { Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit) }
                    else { Image(systemName: "photo").foregroundStyle(.secondary) }
                }
                .frame(width: 56, height: 40)
                .background(Theme.ink.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                Button(L10n.tr("Choose…")) {
                    Task {
                        do {
                            guard let url = try await store.chooseImage(for: NSApp.keyWindow) else { return }
                            picked.append(url); image = url; thumbnail = NSImage(contentsOf: url); error = nil
                        } catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.secondaryAction).controlSize(.small)
            }
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: 24)
    }

    private func slider(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>, help: String?) -> some View {
        row(label) {
            HStack(spacing: 8) {
                FormSlider(value: value, in: range).accessibilityLabel(L10n.tr("Watermark \(label.lowercased())"))
                Text(L10n.tr("\(Int((value.wrappedValue * 100).rounded()))%")).monospacedDigit().frame(width: 38, alignment: .trailing)
            }.help(help ?? "")
        }
    }

    private func save() {
        var watermark = current
        watermark.name = watermark.name.trimmingCharacters(in: .whitespaces)
        do {
            try store.save(watermark)
            for url in picked where url != watermark.image { store.library.discardImage(url) }
            saved(store.watermarks.first { $0.id == watermark.id } ?? watermark)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func cancel() {
        for url in picked { store.library.discardImage(url) }
        dismiss()
    }

    private func delete() {
        do {
            try store.delete(original.id)
            for url in picked { store.library.discardImage(url) }
            deleted(original.id)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// A small picture of the photo in two rows of two: each quarter is one click and shows a mark in its corner, filled
/// for the chosen one, so the control reads like where the watermark lands.
private struct CornerPicker: View {
    @Binding var corner: Watermark.Corner
    var body: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow { cell(.topLeft); cell(.topRight) }
            GridRow { cell(.bottomLeft); cell(.bottomRight) }
        }
        .padding(2)
        .background(Theme.ink.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .accessibilityElement(children: .contain).accessibilityLabel(L10n.tr("Watermark corner"))
    }
    private func cell(_ value: Watermark.Corner) -> some View {
        let selected = corner == value
        return Button { corner = value } label: {
            RoundedRectangle(cornerRadius: Theme.Radius.tag).fill(selected ? Theme.accent : Theme.ink.opacity(0.3))
                .frame(width: 14, height: 6)
                .padding(5)
                .frame(width: 40, height: 26, alignment: Alignment(horizontal: value.isLeft ? .leading : .trailing, vertical: value.isTop ? .top : .bottom))
                .background(selected ? Theme.accent.opacity(0.18) : Theme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(value.title)
        .accessibilityLabel(value.title).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The tiled pattern's angle: a circle with a dot at its center and a line toward the angle. Drag to turn it (Shift
/// snaps to 15°); double-click for 45° again.
private struct AngleDial: View {
    @Binding var angle: Double
    private let size: CGFloat = 44
    var body: some View {
        let radians = angle * .pi / 180, radius = size / 2
        ZStack {
            Circle().fill(Theme.ink.opacity(0.08))
            Circle().strokeBorder(Theme.ink.opacity(0.25), lineWidth: 1)
            Path { path in
                path.move(to: CGPoint(x: radius, y: radius))
                path.addLine(to: CGPoint(x: radius + cos(radians) * (radius - 5), y: radius - sin(radians) * (radius - 5)))
            }.stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            Circle().fill(Theme.accent).frame(width: 6, height: 6)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            let dx = value.location.x - radius, dy = radius - value.location.y
            guard hypot(dx, dy) > 3 else { return }
            let degrees = atan2(dy, dx) * 180 / .pi
            angle = NSEvent.modifierFlags.contains(.shift) ? (degrees / 15).rounded() * 15 : degrees.rounded()
        })
        .simultaneousGesture(TapGesture(count: 2).onEnded { angle = 45 })
        .help(L10n.tr("Drag to turn the pattern. Shift snaps to 15°; double-click for 45°."))
        .accessibilityElement()
        .accessibilityLabel(L10n.tr("Tile angle"))
        .accessibilityValue(L10n.tr("\(Int(angle.rounded())) degrees"))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 5.0 : -5.0
            angle = min(Watermark.angleRange.upperBound, max(Watermark.angleRange.lowerBound, angle + step))
        }
    }
}

/// Renders the editor's preview and the thumbnails in Settings.
enum WatermarkPreview {
    private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
    /// A neutral 3:2 photo stand-in, light at the top left and dark at the bottom right, to judge a watermark on both.
    private static let sample: CIImage = {
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 400), "inputPoint1": CIVector(x: 600, y: 0),
            "inputColor0": CIColor(red: 0.78, green: 0.8, blue: 0.82), "inputColor1": CIColor(red: 0.12, green: 0.13, blue: 0.15)])!
        return gradient.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 600, height: 400))
    }()

    /// `watermark` on the photo (or the sample), at most 640 pixels on the long edge.
    nonisolated static func render(_ watermark: Watermark, over backdrop: CGImage?) throws -> CGImage {
        var photo = backdrop.map { CIImage(cgImage: $0) } ?? sample
        let factor = min(1, 640 / max(photo.extent.width, photo.extent.height))
        photo = photo.transformed(by: CGAffineTransform(translationX: -photo.extent.minX, y: -photo.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: factor, y: factor), highQualityDownsample: true)
        photo = photo.cropped(to: CGRect(x: 0, y: 0, width: photo.extent.width.rounded(.down), height: photo.extent.height.rounded(.down)))
        let stamped = try watermark.composited(over: photo)
        guard let image = context.createCGImage(stamped, from: stamped.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { throw EditorError.render }
        return image
    }

    /// The watermark alone, for lists: the image, or the text drawn small.
    nonisolated static func thumbnail(_ watermark: Watermark) -> NSImage? {
        if let text = watermark.text, let image = try? text.rendered(longEdge: 160) { return NSImage(cgImage: image, size: .zero) }
        return watermark.image.flatMap { NSImage(contentsOf: $0) }
    }
}

/// The installed font families, and the PostScript names a text watermark stores.
enum FontChoice {
    static let families = NSFontManager.shared.availableFontFamilies
    static func family(of name: String) -> String { NSFont(name: name, size: 12)?.familyName ?? "Helvetica Neue" }
    static func isBold(_ name: String) -> Bool { traits(name).contains(.boldFontMask) }
    static func isItalic(_ name: String) -> Bool { traits(name).contains(.italicFontMask) }
    private static func traits(_ name: String) -> NSFontTraitMask {
        NSFont(name: name, size: 12).map { NSFontManager.shared.traits(of: $0) } ?? []
    }
    /// The family's face with exactly this weight and slant, or nil when it has none.
    static func name(family: String, bold: Bool, italic: Bool) -> String? {
        let traits: NSFontTraitMask = [bold ? .boldFontMask : .unboldFontMask, italic ? .italicFontMask : .unitalicFontMask]
        guard let font = NSFontManager.shared.font(withFamily: family, traits: traits, weight: bold ? 9 : 5, size: 12) else { return nil }
        let found = NSFontManager.shared.traits(of: font)
        return found.contains(.boldFontMask) == bold && found.contains(.italicFontMask) == italic ? font.fontName : nil
    }
    /// For a new family: the same style if it has it, else the nearest it does, else its first face.
    static func closest(family: String, bold: Bool, italic: Bool) -> String {
        name(family: family, bold: bold, italic: italic) ?? name(family: family, bold: bold, italic: false)
            ?? name(family: family, bold: false, italic: false)
            ?? NSFontManager.shared.availableMembers(ofFontFamily: family)?.first?.first as? String ?? family
    }
}

/// A word processor's style button: an icon that stays highlighted while the style is on.
private struct StyleToggle: View {
    let symbol: String
    let title: String
    let isOn: Bool
    let available: Bool
    let toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? Theme.accent : .primary)
                .frame(width: 26, height: 22)
                .background(isOn ? Theme.accent.opacity(0.2) : Theme.ink.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.4)
        .help(available ? title : L10n.tr("This font has no other face for \(title.lowercased())"))
        .accessibilityLabel(title).accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
