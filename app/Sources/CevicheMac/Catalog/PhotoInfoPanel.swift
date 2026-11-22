import AppKit
import SwiftUI
import CevicheCore

/// Develop's Info tab. A catalog photo gets the Library's inspector, or its batch inspector while several photos are
/// selected in the filmstrip, so ratings, labels, albums and tools work the same in both; a file opened on its own
/// gets `PhotoInfoPanel`.
struct DevelopInfoPanel: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var catalog: CatalogModel
    var body: some View {
        if let store = catalog.store, editor.usesCatalog(store), let id = editor.catalogAssetID {
            if catalog.cullingTargets(editor: editor).count > 1 {
                CatalogBatchInspector(model: catalog, editor: editor)
            } else if let asset = catalog.selected, asset.id == id {
                CatalogInspector(model: catalog, editor: editor, asset: asset, inDevelop: true)
            } else {
                ScrollView { PhotoInfoPanel(model: editor) }
            }
        } else {
            ScrollView { PhotoInfoPanel(model: editor) }
        }
    }
}

/// How Develop renders the open photo; `showsOriginal` adds its path where nothing else shows it.
struct ProcessingDetails: View {
    @ObservedObject var model: EditorModel
    var showsOriginal = false
    var body: some View {
        if let info = model.info {
            InfoSection(L10n.tr("Processing")) {
                // What the development does now: a supported RAW's switch in Detail › Optics.
                MetadataRow.optional(L10n.tr("Lens correction"), info.isRAW ? info.lensCorrectionSupported.map { $0 ? (model.adjustments.lensCorrection ? L10n.tr("On") : L10n.tr("Off")) : L10n.tr("Unavailable") } ?? L10n.tr("Unknown") : L10n.tr("Unavailable"))
                MetadataRow.optional(L10n.tr("Source depth"), info.sourceBitDepth.map { L10n.tr("\($0)-bit (reported by the file)") })
                MetadataRow.optional(L10n.tr("Working precision"), L10n.tr("32-bit float linear RGB"))
                MetadataRow.optional(L10n.tr("Renderer"), L10n.tr("Core Image - \(model.gpuName)"))
                if showsOriginal { MetadataRow.optional(L10n.tr("Original"), model.sourceURL?.path, path: true) }
            }
        }
    }
}

/// A file opened on its own: the file at a glance, capture settings as tiles, then progressively more detail. The Library's
/// inspector (`CatalogInspector`) shows the same card, capture details and metadata list around its own actions, so
/// those pieces live here as views both compose.
struct PhotoInfoPanel: View {
    @ObservedObject var model: EditorModel
    @State private var summary = PhotoMetadataSummary()
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let info = model.info {
                PhotoFileCard(filename: info.filename, isRAW: info.isRAW, width: info.width, height: info.height, captured: summary.captured, thumbnail: model.thumbnail)
                CaptureDetails(summary: summary, camera: info.camera, lens: info.lens)
                ProcessingDetails(model: model, showsOriginal: true)
                AllMetadataDisclosure(fields: summary.extended)
            } else {
                Text(L10n.tr("Open a photograph to see its details.")).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(18)
        .loadsPhotoSummary(model.sourceURL, into: $summary)
    }
}

extension View {
    /// Reads the file's metadata off the main thread whenever `url` changes; nil clears the summary.
    func loadsPhotoSummary(_ url: URL?, into summary: Binding<PhotoMetadataSummary>) -> some View {
        task(id: url) {
            guard let url else { summary.wrappedValue = PhotoMetadataSummary(); return }
            summary.wrappedValue = await Task.detached(priority: .utility) { PhotoMetadataSummary(url: url) }.value
        }
    }
}

/// The file at a glance: thumbnail when there is one, name with a format badge, size and capture time, and room for
/// a menu on the trailing side.
struct PhotoFileCard<Accessory: View>: View {
    let filename: String
    let isRAW: Bool
    var width: Int?
    var height: Int?
    var captured: String?
    var thumbnail: NSImage?
    @ViewBuilder var accessory: Accessory
    init(filename: String, isRAW: Bool, width: Int? = nil, height: Int? = nil, captured: String? = nil, thumbnail: NSImage? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.filename = filename; self.isRAW = isRAW; self.width = width; self.height = height; self.captured = captured; self.thumbnail = thumbnail; self.accessory = accessory()
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill).frame(width: 56, height: 56).clipped()
            }
            VStack(alignment: .leading, spacing: 4) {
                // Two lines before truncating: names like screenshots differ only at their end. The format badge sits on
                // the line below so it never squeezes the name.
                Text(filename).font(.system(size: 13, weight: .semibold)).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).help(filename)
                HStack(spacing: 6) {
                    Text(isRAW ? L10n.tr("RAW") : (filename as NSString).pathExtension.uppercased()).font(.system(size: 8, weight: .bold)).tracking(1)
                        .padding(.horizontal, 5).padding(.vertical, 2).background(Theme.ink.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.tag)).fixedSize()
                    if let width, let height {
                        Text(L10n.tr("\(width) × \(height) - \(String(format: "%.1f", locale: Locale.current, Double(width * height) / 1_000_000)) MP"))
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                if let captured { Text(captured).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            accessory
        }
        .padding(10).card()
    }
}

/// A titled group in the info panels: a small tracked heading, an optional accessory on its right, then the rows.
struct InfoSection<Accessory: View, Content: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title; self.accessory = accessory(); self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).textCase(.uppercase).font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                Spacer()
                accessory
            }
            content
        }
    }
}

/// How the photo was taken, from the file's own metadata: the four settings as tiles, then exposure, location and
/// credits as rows. `camera` and `lens` are fallbacks from the decoder when the summary has none.
struct CaptureDetails: View {
    let summary: PhotoMetadataSummary
    var camera = ""
    var lens = ""
    var body: some View {
        let cameraName = summary.camera ?? (camera.isEmpty ? nil : camera), lensName = summary.lens ?? (lens.isEmpty ? nil : lens)
        let settings = [summary.aperture, summary.shutter, summary.iso, summary.focalLength].contains { $0 != nil }
        // A screenshot or a scan says nothing of a camera: no section of empty tiles for it.
        if settings || cameraName != nil || lensName != nil {
            InfoSection(L10n.tr("Camera")) {
                if settings {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        tile("camera.aperture", L10n.tr("Aperture"), summary.aperture)
                        tile("timer", L10n.tr("Shutter"), summary.shutter)
                        tile("dial.low", L10n.tr("Sensitivity"), summary.iso)
                        tile("scope", L10n.tr("Focal length"), summary.focalLength.map { f in summary.focalLength35mm.map { L10n.tr("\(f) - \($0) eq.") } ?? f })
                    }
                }
                MetadataRow.optional(L10n.tr("Body"), cameraName)
                MetadataRow.optional(L10n.tr("Lens"), lensName)
            }
        }
        if [summary.exposureBias, summary.exposureProgram, summary.metering, summary.flash, summary.whiteBalance].contains(where: { $0 != nil }) {
            InfoSection(L10n.tr("Exposure")) {
            MetadataRow.optional(L10n.tr("Compensation"), summary.exposureBias)
            MetadataRow.optional(L10n.tr("Exposure Program"), summary.exposureProgram)
            MetadataRow.optional(L10n.tr("Metering"), summary.metering)
            MetadataRow.optional(L10n.tr("Flash"), summary.flash)
            MetadataRow.optional(L10n.tr("White balance"), summary.whiteBalance)
            }
        }
        if let latitude = summary.latitude, let longitude = summary.longitude {
            InfoSection(L10n.tr("Location")) {
                MetadataRow.optional(L10n.tr("Coordinates"), String(format: "%.6f, %.6f", locale: Locale.current, latitude, longitude))
                if let altitude = summary.altitude { MetadataRow.optional(L10n.tr("Altitude"), String(format: "%.0f m", locale: Locale.current, altitude)) }
            }
        }
        if summary.artist != nil || summary.copyright != nil || summary.software != nil {
            InfoSection(L10n.tr("Credits")) {
                MetadataRow.optional(L10n.tr("Artist"), summary.artist)
                MetadataRow.optional(L10n.tr("Copyright"), summary.copyright)
                MetadataRow.optional(L10n.tr("Software"), summary.software)
            }
        }
    }
    private func tile(_ icon: String, _ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value ?? "—").font(.system(size: 14, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(value == nil ? .tertiary : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .card()
        .accessibilityElement(children: .combine)
    }
}

/// Every remaining metadata field, folded away behind a count.
struct AllMetadataDisclosure: View {
    let fields: [PhotoMetadataSummary.Field]
    @State private var showAll = false
    var body: some View {
        if !fields.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button { withAnimation(.easeInOut(duration: 0.15)) { showAll.toggle() } } label: {
                    HStack {
                        Text(L10n.tr("ALL METADATA")).font(.system(size: 9, weight: .semibold)).tracking(1.3)
                        Text(L10n.tr("\(fields.count)")).font(.system(size: 9)).monospacedDigit()
                        Spacer()
                        Image(systemName: showAll ? "chevron.down" : "chevron.right").font(.system(size: 9))
                    }.foregroundStyle(.tertiary).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if showAll {
                    ForEach(fields) { field in MetadataRow(title: field.title, value: field.value, detail: field.group) }
                }
            }
        }
    }
}

/// Hovering a value offers Copy; clicking copies it, as in RapidRAW's metadata panel.
struct MetadataRow: View {
    let title: String
    let value: String
    var detail: String?
    var path = false
    @State private var hovering = false
    @State private var copied = false
    /// Nothing when there is no value, so sections only list what the file says.
    @ViewBuilder static func optional(_ title: String, _ value: String?, detail: String? = nil, path: Bool = false) -> some View {
        if let value { MetadataRow(title: title, value: value, detail: detail, path: path) }
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(.secondary)
                if let detail { Text(detail).font(.system(size: 9)).foregroundStyle(.secondary) }
            }.frame(width: 92, alignment: .leading)
            Text(value).lineLimit(path ? 2 : 3).truncationMode(path ? .head : .tail).frame(maxWidth: .infinity, alignment: .leading)
                .help(value)
        }
        .overlay(alignment: .trailing) {
            if hovering || copied {
                Text(copied ? L10n.tr("Copied") : L10n.tr("Copy")).font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 5).padding(.vertical, 2).background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.tag))
            }
        }
        .font(.system(size: 11))
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(hovering ? Theme.ink.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: L10n.tr("Copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
    }
}
