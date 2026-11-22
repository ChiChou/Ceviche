import SwiftUI
import UniformTypeIdentifiers
import CevicheCore

/// The open photo's loading, rendering, saving or exporting, as a spinner; leads the header's controls.
struct EditorProgress: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        if model.isLoading || model.isRendering || model.isSaving || model.isExporting {
            ProgressView().controlSize(.mini).help(model.isExporting ? L10n.tr("Exporting…") : model.isSaving ? L10n.tr("Saving…") : L10n.tr("Rendering…"))
        }
    }
}

/// Undo and redo, and Export.
struct EditorHeaderControls: View {
    @ObservedObject var model: EditorModel
    var compact = false
    let editIn: (URL) -> Void
    var body: some View {
        HStack(spacing: 14) {
            Button(action: model.undo) { Image(systemName: "arrow.uturn.backward") }.disabled(model.undoStack.isEmpty || model.busy).help(L10n.tr("Undo (⌘Z)")).accessibilityLabel(L10n.tr("Undo"))
            Button(action: model.redo) { Image(systemName: "arrow.uturn.forward") }.disabled(model.redoStack.isEmpty || model.busy).help(L10n.tr("Redo (⇧⌘Z)")).accessibilityLabel(L10n.tr("Redo"))
        }.buttonStyle(.plain)
        ExportButton(editor: model, compact: compact, editIn: editIn)
    }
}

/// The photo with its tools, or the empty state. Dropped files reach the workspace, which imports them.
struct EditorCanvas: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(spacing: 0) {
            PrintProofStrip(model: model, proof: model.proof)
            canvas
        }.background(DisplayHDRObserver(model: model))
            .onDisappear { model.cancelHeldViewKeys() }
            .onChange(of: model.sourceURL) { _, _ in model.cancelHeldViewKeys() }
            .onChange(of: model.isLoading) { _, loading in if loading { model.cancelHeldViewKeys() } }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in model.cancelHeldViewKeys() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in model.cancelHeldViewKeys() }
    }
    private var canvas: some View {
        GeometryReader { geometry in
            ZStack {
                Theme.imageSurround
                if let image = model.preview {
                    ZoomableImage(model: model, image: image)
                        .clipped()
                        .padding(12)
                } else {
                    ContentUnavailableView {
                        Label(L10n.tr("No Photo Open"), systemImage: "photo")
                    } description: {
                        Text(L10n.tr("Drop photos here to import."))
                    }
                }
                if model.showCaptureOverlay, let image = model.preview {
                    let rect = model.viewport.imageRect(image: CGSize(width: image.width, height: image.height),
                        canvas: CGSize(width: max(1, geometry.size.width - 24), height: max(1, geometry.size.height - 24)))
                        .offsetBy(dx: 12, dy: 12)
                    CaptureInfoOverlay(model: model).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.leading, max(24, rect.minX + 12))
                        .padding(.trailing, max(24, geometry.size.width - rect.maxX + 12))
                        .padding(.top, max(24, rect.minY + 12)).allowsHitTesting(false)
                }
                if model.peekingOriginal {
                    Text(L10n.tr("Original")).font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5).background(.black.opacity(0.65), in: Capsule()).environment(\.colorScheme, .dark)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(24).allowsHitTesting(false)
                }
                if model.printing, !model.peekingOriginal, model.preview != nil { PrintCanvas(model: model) }
                if model.zonesOnCanvas {
                    // At the top: messages and banners take the bottom edge. Below the targeted adjustment's bar while it shows.
                    VStack { ZoneStrip(model: model, pointer: model.zonePointer); Spacer() }.padding(.top, model.targetedMixer != nil ? 62 : 18)
                }
                if let eyedropper = model.eyedropper, !model.peekingOriginal {
                    VStack {
                        HStack(spacing: 8) {
                            Image(systemName: "eyedropper")
                            Text(eyedropper.prompt)
                            Text(L10n.tr("Esc to cancel")).foregroundStyle(.secondary)
                        }.font(.system(size: 11)).padding(.horizontal, 12).padding(.vertical, 6).background(.black.opacity(0.7), in: Capsule()).environment(\.colorScheme, .dark)
                        Spacer()
                    }.padding(.top, 18).allowsHitTesting(false)
                }
                if model.toolTab == .face, model.showInspector, model.preview != nil, !model.peekingOriginal, model.eyedropper == nil {
                    VStack { PortraitToolbar(model: model); Spacer() }.padding(.top, 18)
                }
                if model.targetedMixer != nil, !model.peekingOriginal {
                    VStack { TargetedMixerBar(model: model); Spacer() }.padding(.top, 18)
                }
                if model.awaitingGradient, !model.peekingOriginal, let tool = model.maskTool, model.toolTab == .masks {
                    VStack {
                        HStack(spacing: 8) {
                            Image(systemName: tool == .linear ? "rectangle.lefthalf.filled" : "circle.lefthalf.filled")
                            Text(tool == .linear ? L10n.tr("Drag across the photo from full effect to none") : L10n.tr("Drag outward from the center of the ellipse"))
                            Text(tool == .linear ? L10n.tr("Shift snaps - Esc to cancel") : L10n.tr("Shift keeps a circle - Esc to cancel")).foregroundStyle(.secondary)
                        }.font(.system(size: 11)).padding(.horizontal, 12).padding(.vertical, 6).background(.black.opacity(0.7), in: Capsule()).environment(\.colorScheme, .dark)
                        Spacer()
                    }.padding(.top, 18).allowsHitTesting(false)
                }
                if model.isLoading, let standIn = model.openingImage {
                    // The photo itself, small, in place of the one being left: the full preview replaces it.
                    ZStack {
                        Theme.canvas
                        Image(nsImage: standIn).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(24)
                        VStack { Spacer(); ProgressView().controlSize(.small).padding(8).background(.black.opacity(0.5), in: Circle()).environment(\.colorScheme, .dark).padding(.bottom, 18) }
                    }
                } else if model.isLoading {
                    ZStack { Color.black.opacity(0.5); VStack(spacing: 12) { ProgressView(); Text(L10n.tr("Opening…")).font(.system(size: 12)) }.padding(28).background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel)) }
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

/// The proof's settings above the photo, while it is proofed.
private struct PrintProofStrip: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var proof: PrintProofState
    var body: some View {
        if proof.on, model.hasImage {
            PrintProofBar(proof: proof)
            Rule()
        }
    }
}

struct ToolRailButton: View {
    let icon: String
    let title: String
    /// Shown beside the name on hover, as the key cap of a menu item.
    var shortcut: String? = nil
    let active: Bool
    let action: () -> Void
    @State private var hovering = false
    @State private var labelled = false
    /// When a label last went away: moving straight on to the next tab labels it at once, as menu bars do.
    @MainActor private static var lastLabel = Date.distantPast
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 19)).frame(width: 38, height: 42)
                .background(active ? Theme.accent.opacity(0.2) : hovering ? Theme.ink.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .foregroundStyle(active ? Theme.accent : hovering ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        // The name and key on hover, beside the rail over the panel, without the tooltip's wait or its plain text.
        .overlay(alignment: .trailing) {
            if labelled {
                // Pinned by its trailing edge, the button's width clear of the button, so it ends just left of it.
                HStack(spacing: 6) { ToolRailLabel(title: title, shortcut: shortcut); Color.clear.frame(width: 38) }
                    .fixedSize().transition(.opacity).allowsHitTesting(false)
            }
        }
        .onHover { inside in
            hovering = inside
            if !inside {
                if labelled { Self.lastLabel = .now }
                withAnimation(.easeOut(duration: 0.1)) { labelled = false }
            }
        }
        .task(id: hovering) {
            guard hovering else { return }
            if Date.now.timeIntervalSince(Self.lastLabel) > 0.5 { try? await Task.sleep(for: .milliseconds(200)) }
            guard !Task.isCancelled, hovering else { return }
            withAnimation(.easeOut(duration: 0.1)) { labelled = true }
        }
        .accessibilityLabel(title).accessibilityHint(shortcut.map { L10n.tr("Shortcut: \($0)") } ?? "")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// A rail button's name and its key, on a floating surface that reads over the panel beside the rail.
private struct ToolRailLabel: View {
    let title: String
    let shortcut: String?
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium))
            if let shortcut {
                Text(shortcut).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                    .background(Theme.ink.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.tag))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tag).strokeBorder(Theme.hairline))
            }
        }
        .padding(.leading, 10).padding(.trailing, shortcut == nil ? 10 : 6).frame(height: 28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }
}

/// Compact capture readout; missing EXIF fields simply disappear.
private struct CaptureInfoOverlay: View {
    @ObservedObject var model: EditorModel
    @State private var capture = PhotoMetadataSummary()
    var body: some View {
        let exposure = [capture.focalLength, capture.aperture, capture.shutter, capture.iso].compactMap { $0 }.joined(separator: " · ")
        VStack(alignment: .leading, spacing: 3) {
            if let camera = capture.camera { Text(camera).fontWeight(.medium) }
            if let lens = capture.lens { Text(lens) }
            if !exposure.isEmpty { Text(exposure).monospacedDigit() }
        }.font(.system(size: 11)).foregroundStyle(.white).lineLimit(1).truncationMode(.tail)
            .padding(8).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.Radius.control)).environment(\.colorScheme, .dark)
            .opacity(capture.camera == nil && capture.lens == nil && exposure.isEmpty ? 0 : 1)
            .task(id: model.sourceURL) {
                capture = PhotoMetadataSummary()
                guard let url = model.sourceURL else { return }
                let result = await Task.detached(priority: .utility) { PhotoMetadataSummary(url: url) }.value
                guard !Task.isCancelled else { return }
                capture = result
            }
    }
}

/// Icon and title, or the icon alone when the title bar runs out of room.
struct TitleHiddenLabelStyle: LabelStyle {
    let hidden: Bool
    func makeBody(configuration: Configuration) -> some View {
        if hidden { configuration.icon } else { Label { configuration.title } icon: { configuration.icon } }
    }
}

