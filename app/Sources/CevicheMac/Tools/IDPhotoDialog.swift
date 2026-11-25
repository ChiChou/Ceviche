import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CevicheCore

/// The ID Photo tool. The sheets are what the tool makes, so they fill the canvas: every copy as it will print, each
/// marked when its photo needs a fix or a retake. The side panel is the selected photo: what's wrong with it and what
/// can be done (fixed here, in Develop, or the photo left out), then its framing, colour and copies. Adjust swaps
/// the sheets for the photo itself to move its markers. A batch's photos run along the bottom.
struct IDPhotoDialog: View {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var editor: EditorModel
    @StateObject private var session: IDPhotoSession
    @State private var showingRules = false
    @State private var editingTemplate: IDPhotoTemplateEditing?
    @ObservedObject private var templates = IDPhotoTemplateStore.shared
    init(catalog: CatalogModel, editor: EditorModel, request: IDPhotoRequest) {
        self.catalog = catalog; self.editor = editor
        _session = StateObject(wrappedValue: IDPhotoSession(request: request))
    }

    /// Nothing goes out while a photo is being developed again or its matte made, or it would be the old one, nor while
    /// its markers are being moved.
    private var ready: Bool { session.settled && session.sheetCount > 0 && !session.adjusting }
    private var working: Bool { session.photos.contains(where: \.working) }
    /// Before any document is set (developing, then asking which one) there is nothing for the toolbar, inspector or
    /// filmstrip to act on, so only the canvas shows; a photo that failed keeps the inspector, which says why.
    private var bare: Bool { session.layout == nil && session.photos.allSatisfy { $0.stage == .loading || $0.needsDocument } }

    var body: some View {
        // Nothing to save or throw away: the layout lives only while the tool is open, and leaving by Close, Print or
        // Export writes a white balance set here to the photo's development, as a History step.
        ToolWorkspace(title: L10n.tr("ID Photo"), status: status, statusIsWarning: session.problems > 0,
                      primary: L10n.tr("Print…"), primaryDisabled: !ready, cancel: close, action: printSheets, escape: escape,
                      cancelTitle: L10n.tr("Close"), showsToolbar: !bare) {
            toolbar
        } content: {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Group {
                        if session.needsDocument { IDPhotoDocumentPrompt(session: session) { newTemplate() } }
                        else if session.adjusting { IDPhotoAdjustPane(model: session.shown) { session.adjusting = false }.id(session.shown.id) }
                        else { IDPhotoSheetCanvas(session: session) { exportPhotos([$0]) } }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Until a document is chosen the prompt stands alone: the toolbar, inspector and filmstrip have
                    // nothing to act on yet.
                    if !bare {
                        ToolSidePanel(width: 290) {
                            IDPhotoInspector(model: session.shown, session: session).id(session.shown.id)
                        }
                        // Nothing changes under an export or print while it renders.
                        .disabled(working)
                    }
                }
                if session.isBatch, !bare {
                    Rule()
                    IDPhotoFilmstrip(session: session) { exportPhotos([$0]) }
                }
            }
        } actions: {
            if working { ProgressView().controlSize(.small) }
            Button(session.isBatch ? L10n.tr("Export Photos…") : L10n.tr("Export Photo…")) { exportPhotos(session.photos.filter { session.copies(of: $0) > 0 }) }
                .buttonStyle(.secondaryAction).disabled(!ready)
                .help(L10n.tr("Each photo as a JPEG at the document's size, within its upload limits, to print or send"))
            if session.layout?.sheet.paper != .single {
                Button(session.isBatch || session.sheetCount > 1 ? L10n.tr("Export Sheets…") : L10n.tr("Export Sheet…")) { exportSheets() }
                    .buttonStyle(.secondaryAction).disabled(!ready)
                    .help(L10n.tr("The sheets as JPEGs at the paper's size, for a print shop"))
            }
        }
        .onAppear { session.start(catalog: catalog) }
        .onDisappear { session.stop() }
        .sheet(item: $editingTemplate) { item in
            IDPhotoTemplateEditor(original: item.template, isNew: item.isNew) { session.select($0) }
        }
        // A template changed in Settings while it's in use applies straight away.
        .onReceive(templates.$templates) { all in
            guard let spec = session.layout?.spec, spec.isCustom, let current = all.first(where: { $0.id == spec.id }), current != spec else { return }
            session.select(current)
        }
    }

    /// A new template from the document in use, or from ICAO's.
    private func newTemplate() {
        editingTemplate = IDPhotoTemplateEditing(template: templates.newTemplate(from: session.layout?.spec), isNew: true)
    }

    /// The photos, how they stand, and the sheets they make.
    private var status: String {
        let loading = session.photos.filter { $0.stage == .loading }.count
        var parts: [String] = [session.isBatch ? L10n.tr("\(session.photos.count) photos") : session.shown.asset.filename]
        if loading > 0 { parts.append(L10n.tr("\(loading) developing")); return parts.joined(separator: " · ") }
        if session.needsDocument { parts.append(L10n.tr("Choose the document")); return parts.joined(separator: " · ") }
        if session.isBatch {
            let ready = session.count(.ready), fix = session.count(.needsFix), retake = session.count(.retake)
            parts.append(L10n.tr("\(ready) ready"))
            if fix > 0 { parts.append(L10n.tr("\(fix) to fix")) }
            if retake > 0 { parts.append(fix == 0 && retake == 1 ? L10n.tr("1 retake") : L10n.tr("\(retake) retakes")) }
        } else if session.shown.stage == .ready {
            parts.append(session.shown.readinessTitle)
        }
        let sheets = session.sheetCount
        if session.layout?.sheet.paper != .single { parts.append(sheets == 1 ? L10n.tr("1 sheet") : L10n.tr("\(sheets) sheets")) }
        return parts.joined(separator: " · ")
    }

    /// What every photo shares: the document, the background and the paper.
    @ViewBuilder private var toolbar: some View {
        let layout = session.layout
        SpecMenu(selection: layout?.spec, newTemplate: newTemplate) { session.select($0) }.frame(width: 230)
            .disabled(session.ready.isEmpty || working)
        if let spec = layout?.spec, spec.isCustom {
            Button { editingTemplate = IDPhotoTemplateEditing(template: templates.spec(spec.id) ?? spec, isNew: false) } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).help(L10n.tr("Edit this template")).disabled(working)
        }
        Button { showingRules.toggle() } label: { Image(systemName: "info.circle") }.buttonStyle(.borderless)
            .help(L10n.tr("Size, head height and rules of this document"))
            .popover(isPresented: $showingRules, arrowEdge: .bottom) {
                if let spec = layout?.spec { IDPhotoSpecSummary(spec: spec).padding(14).frame(width: 300) }
            }.disabled(layout == nil)
        Toggle(L10n.tr("Use next time"), isOn: Binding(get: { session.rememberChoice }, set: { session.rememberChoice = $0 }))
            .toggleStyle(.formCheckbox).fixedSize().disabled(layout == nil)
            .help(L10n.tr("Open with this document and paper next time"))
        Rule(.vertical).frame(height: 16)
        Group {
            Toggle(L10n.tr("Replace Background"), isOn: Binding(get: { layout?.background != nil }, set: { session.replaceBackground($0) }))
                .toggleStyle(.formCheckbox).fixedSize()
            if let background = layout?.background {
                ColorPicker(L10n.tr("Background colour"), selection: Binding(
                    get: { Color(.sRGB, red: background.red, green: background.green, blue: background.blue) },
                    set: { color in
                        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
                        session.setShared { $0.background = IDPhotoBackground(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent) }
                    }), supportsOpacity: false).labelsHidden().fixedSize()
            }
            if session.photos.contains(where: \.matting) { ProgressView().controlSize(.mini) }
            Rule(.vertical).frame(height: 16)
            if let layout {
                PanelPicker(title: L10n.tr("Paper"), selection: Binding(get: { layout.sheet.paper }, set: { paper in session.setShared { $0.sheet.paper = paper } }),
                            options: IDPhotoSheet.Paper.allCases, label: { paperTitle($0, layout: layout) }).fixedSize()
                if layout.sheet.paper != .single {
                    FormSegments(title: L10n.tr("Spacing"), selection: Binding(get: { layout.sheet.spacing }, set: { spacing in session.setShared { $0.sheet.spacing = spacing } }),
                                 options: IDPhotoSheet.Spacing.allCases, label: { $0.title }).fixedSize()
                        .help(L10n.tr("Lab leaves margins a shop can trim and room to cut; edge to edge fits the most photos"))
                    if layout.sheet.spacing == .lab {
                        Toggle(L10n.tr("Cut guides"), isOn: Binding(get: { layout.sheet.cutGuides }, set: { on in session.setShared { $0.sheet.cutGuides = on } }))
                            .toggleStyle(.formCheckbox).fixedSize()
                    }
                }
            }
        }
        .disabled(layout == nil || working)
    }

    private func paperTitle(_ paper: IDPhotoSheet.Paper, layout: IDPhotoLayout) -> String {
        guard paper != .single else { return paper.title }
        var sheet = layout.sheet; sheet.paper = paper; sheet.copies = nil
        let count = sheet.arrangement(for: layout.spec)?.origins.count ?? 0
        return L10n.tr("\(paper.title) · \(count) photos")
    }

    // MARK: Actions

    private func escape() {
        if session.shown.pickingNeutral { session.shown.pickingNeutral = false }
        else if session.adjusting { session.adjusting = false }
        else { close() }
    }
    private func close() { save(); session.stop(); catalog.idPhoto = nil }

    /// Writes a white balance set in the tool to its photo's development; nothing when none changed.
    private func save() {
        let saves = session.takeSaves()
        guard !saves.isEmpty else { return }
        Task { await catalog.saveIDPhotoWhiteBalance(saves, editor: editor) }
    }

    /// Each photo at the document's size and print resolution, kept within its upload limits (pixel size, file size)
    /// when it has them, so one file serves a print shop and an online application alike.
    private func exportPhotos(_ chosen: [IDPhotoModel]) {
        guard let layout = session.layout else { return }
        let spec = layout.spec
        let photos = chosen.filter { $0.stage == .ready }
        guard !photos.isEmpty else { return }
        // One photo is saved under a name; several go into a folder, each named after its original.
        Task {
            let chosen = photos.count == 1
                ? await FileChooser.save(FileSaveRequest(name: IDPhotoRenderer.digitalName(stem: photos[0].stem, spec: spec), types: [.jpeg]))
                : await FileChooser.openOne(FileOpenRequest(files: false, folders: true, createFolders: true, prompt: L10n.tr("Export")))
            guard let destination = chosen else { return }
            save()
            do {
                for photo in photos {
                    guard let own = photo.layout else { continue }
                    let image = try await photo.render(.digital)
                    let url = photos.count == 1 ? destination : Self.free(destination.appendingPathComponent(IDPhotoRenderer.digitalName(stem: photo.stem, spec: spec)))
                    try IDPhotoRenderer.writeDigital(image, spec: own.spec, to: url)
                }
                catalog.notice = photos.count == 1 ? L10n.tr("Exported \(destination.lastPathComponent)") : L10n.tr("Exported \(photos.count) photos")
            } catch { catalog.failure = Failure(L10n.tr("Couldn’t Export"), error) }
        }
    }

    /// The sheets as JPEGs at the spec's resolution, numbered when there are several.
    private func exportSheets() {
        guard let layout = session.layout, let first = session.ready.first else { return }
        Task {
            guard let url = await FileChooser.save(FileSaveRequest(name: "\(first.stem)-\(layout.spec.id)-\(layout.sheet.paper.rawValue).jpg", types: [.jpeg]))
            else { return }
            save()
            do {
                let sheets = try await session.renderSheets()
                guard !sheets.isEmpty else { catalog.error = L10n.tr("No photos to put on the sheets: every copy count is 0."); return }
                let folder = url.deletingLastPathComponent(), base = url.deletingPathExtension().lastPathComponent
                for (index, sheet) in sheets.enumerated() {
                    // The save panel only asked about the name it showed; numbered sheets never replace a file.
                    let target = sheets.count == 1 ? url : Self.free(folder.appendingPathComponent("\(base)-\(index + 1).jpg"))
                    try IDPhotoRenderer.write(sheet, to: target, type: .jpeg, dpi: layout.spec.printDPI)
                }
                catalog.notice = sheets.count == 1 ? L10n.tr("Exported \(url.lastPathComponent)") : L10n.tr("Exported \(sheets.count) sheets")
            } catch { catalog.failure = Failure(L10n.tr("Couldn’t Export"), error) }
        }
    }

    /// Every sheet (or the single photo) at its physical size, one page each.
    private func printSheets() {
        guard let layout = session.layout else { return }
        save()
        Task {
            do {
                let pages = try await session.renderSheets()
                guard !pages.isEmpty else { catalog.error = L10n.tr("No photos to put on the sheets: every copy count is 0."); return }
                let name = session.isBatch ? L10n.tr("\(session.photos.count) photos") : session.photos[0].stem
                IDPhotoPrinting.print(pages, dpi: layout.spec.printDPI, title: "\(name) – \(layout.spec.title)")
            } catch { catalog.failure = Failure(L10n.tr("Couldn’t Print"), error) }
        }
    }

    /// `url`, or the first `name-2.jpg`, `name-3.jpg` beside it that is free.
    static func free(_ url: URL) -> URL {
        var candidate = url, number = 2
        let stem = url.deletingPathExtension().lastPathComponent, folder = url.deletingLastPathComponent()
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem)-\(number).jpg"); number += 1
        }
        return candidate
    }
}

/// Nothing is assumed about what the photos are for: until a document is chosen (or one was kept with "Use next time"),
/// the canvas asks.
private struct IDPhotoDocumentPrompt: View {
    @ObservedObject var session: IDPhotoSession
    let newTemplate: () -> Void
    /// Narrowest a column of documents gets; the list takes as many (up to three) as the canvas has room for.
    static let columnWidth = 330.0
    /// Widest a column gets while the list fills the canvas, so sizes stay near their documents on a big screen.
    static let maxColumnWidth = 400.0
    var body: some View {
        GeometryReader { geometry in
            let room = geometry.size.width - 80
            let columns = max(1, min(3, Int(room / Self.columnWidth)))
            let width = min(max(room, Double(columns) * Self.columnWidth), Double(columns) * Self.maxColumnWidth)
            VStack(spacing: 14) {
                Image(systemName: "person.text.rectangle").font(.system(size: 34)).foregroundStyle(.secondary)
                Text(L10n.tr("Which document are these photos for?")).font(.title3)
                    .padding(.bottom, 14)
                IDPhotoSpecList(choose: { session.select($0) }, newTemplate: newTemplate, columns: columns, maxHeight: 720)
                    .frame(width: width).disabled(session.ready.isEmpty)
                Toggle(L10n.tr("Use next time"), isOn: $session.remembering)
                    .toggleStyle(.formCheckbox).fixedSize()
                    .help(L10n.tr("Open with this document and paper next time"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.imageSurround)
    }
}

/// The selected photo on its own, to move its crown, chin and eye markers; Done (or Esc) goes back to the sheets.
private struct IDPhotoAdjustPane: View {
    @ObservedObject var model: IDPhotoModel
    let done: () -> Void
    var body: some View {
        ZStack(alignment: .topTrailing) {
            switch model.stage {
            case .ready: IDPhotoCanvas(model: model).padding(16)
            case .loading: ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message): Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 10) {
                Text(L10n.tr("Drag the crown, chin and eye markers")).font(.callout).foregroundStyle(.secondary)
                // Return finishes moving the markers; Print… is off meanwhile, so it doesn't take Return.
                Button(L10n.tr("Done"), action: done).buttonStyle(.primaryAction).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .padding(26)
        }
        .background(Theme.imageSurround)
    }
}

/// The selected photo: how it stands and what can be done about it, then its framing, white balance and copies.
private struct IDPhotoInspector: View {
    @ObservedObject var model: IDPhotoModel
    @ObservedObject var session: IDPhotoSession
    @State private var showingPassed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(model.asset.filename).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if model.stage == .ready, model.layout != nil { IDPhotoReadinessTag(model: model) }
            }
            switch model.stage {
            case .loading:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L10n.tr("Developing…")).foregroundStyle(.secondary) }
            case .failed(let message):
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if session.isBatch { Button(L10n.tr("Remove from ID Photo")) { session.remove(model) }.buttonStyle(.secondaryAction) }
            case .ready where model.layout == nil:
                Text(L10n.tr("Choose the document to frame and check this photo.")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .ready:
                issues
                Rule()
                framing
                Rule()
                whiteBalance
                if session.layout?.sheet.paper != .single {
                    Rule()
                    ExportRow(L10n.tr("Copies")) {
                        Stepper(value: Binding(get: { session.copies(of: model) }, set: { session.setCopies($0, of: model) }), in: 0...max(1, session.capacity * 4)) {
                            Text(session.copies(of: model) == 0 ? L10n.tr("Left out") : "\(session.copies(of: model))").monospacedDigit()
                        }.controlSize(.small)
                    }
                }
            }
        }.font(.system(size: 12))
    }

    // MARK: Issues

    @ViewBuilder private var issues: some View {
        let open = model.issues
        if open.isEmpty {
            Label(L10n.tr("Meets every check"), systemImage: "checkmark.seal.fill").foregroundStyle(Theme.pick)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(open) { issue($0) }
            }
            if model.readiness == .retake { rejection }
        }
        let passed = model.passed
        if !passed.isEmpty {
            DisclosureGroup(isExpanded: $showingPassed) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(passed) { check in
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark").foregroundStyle(.secondary).frame(width: 14)
                            Text(check.title)
                            Spacer(minLength: 6)
                            Text(check.detail).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }.padding(.top, 4)
            } label: {
                Text(passed.count == 1 ? L10n.tr("1 check passed") : L10n.tr("\(passed.count) checks passed")).foregroundStyle(.secondary)
            }
        }
        if model.reviewing {
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(L10n.tr("Apple Intelligence is looking…")).foregroundStyle(.secondary) }.font(.system(size: 11))
        }
    }

    private func issue(_ check: IDPhotoCheck) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: check.status == .failure ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(check.status == .failure ? Theme.error : Theme.warning).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(check.advisory ? L10n.tr("\(check.title) (Apple Intelligence)") : check.title)
                Text(check.detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if let fix = check.fix {
                if fix == .retake || fix == .develop {
                    let tint = fix == .retake ? Theme.reject : Theme.warning
                    Text(fix.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tag).strokeBorder(tint.opacity(0.6)))
                        .help(fix.help)
                } else {
                    Button(fix.title) { apply(fix) }.buttonStyle(.secondaryAction).controlSize(.small).help(fix.help)
                        .disabled(fix == .autoWhiteBalance && !model.canAutoBalance)
                }
            }
        }
    }

    private func apply(_ fix: IDPhotoFix) {
        switch fix {
        case .fitToSpec: model.fitToSpec()
        case .adjustFraming: session.adjusting = true
        case .autoWhiteBalance: model.autoWhiteBalance()
        case .replaceBackground: session.replaceBackground(true)
        case .develop, .retake: break
        }
    }

    /// What's left when the photo itself is wrong: leave it out of the sheets, or take it out of the list.
    private var rejection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.isBatch ? L10n.tr("This photo needs to be taken again. Leave it out of the sheets, or remove it.")
                                 : L10n.tr("This photo needs to be taken again. Cancel to choose another, or fix the light in Develop."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if session.isBatch {
                    if session.isLeftOut(model) {
                        Button(L10n.tr("Put Back")) { session.resetCopies(of: model) }.buttonStyle(.secondaryAction)
                    } else {
                        Button(L10n.tr("Leave Out")) { session.leaveOut(model) }.buttonStyle(.secondaryAction)
                    }
                    Button(L10n.tr("Remove")) { session.remove(model) }.buttonStyle(.secondaryAction)
                }
            }.controlSize(.small)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.reject.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
    }

    // MARK: Framing

    @ViewBuilder private var framing: some View {
        if let layout = model.layout {
            ExportRow(L10n.tr("Head")) {
                HStack(spacing: 8) {
                    FormSlider(value: Binding(get: { layout.headSize }, set: { model.layout?.headSize = $0 }), in: 0...1)
                        .accessibilityLabel(L10n.tr("Head height"))
                    Text(millimetres(layout.frame(in: photoSize).headMM)).monospacedDigit().frame(width: 52, alignment: .trailing)
                }
            }
            ExportRow(L10n.tr("Position")) {
                HStack(spacing: 8) {
                    FormSlider(value: Binding(get: { layout.offsetMM }, set: { model.layout?.offsetMM = $0 }), in: -4...4)
                        .accessibilityLabel(L10n.tr("Vertical position"))
                    Text(millimetres(layout.offsetMM, signed: true)).monospacedDigit().frame(width: 52, alignment: .trailing)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button(L10n.tr("Find Face")) { model.placeMarkers(); model.frameRegion() }.buttonStyle(.secondaryAction).controlSize(.small)
                    .help(L10n.tr("Place the crown, chin and eye markers from the face again"))
                Button(L10n.tr("Adjust…")) { session.adjusting = true }.buttonStyle(.secondaryAction).controlSize(.small)
                    .help(IDPhotoFix.adjustFraming.help)
            }
        }
    }

    /// Temperature and Tint, as in Develop, with Auto from the wall and a picker for any neutral spot.
    @ViewBuilder private var whiteBalance: some View {
        if let development = model.development, model.renderer != nil {
            ExportRow(L10n.tr("White balance")) {
                HStack(spacing: 8) {
                    Button { model.pickingNeutral.toggle() } label: {
                        Image(systemName: "eyedropper").font(.system(size: 11)).frame(width: 22, height: 20)
                            .background(model.pickingNeutral ? Theme.accent.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                            .foregroundStyle(model.pickingNeutral ? Theme.accent : .secondary).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .help(L10n.tr("Click something white or grey in the photo")).accessibilityLabel(L10n.tr("Pick a neutral spot"))
                    Button(L10n.tr("Auto")) { model.autoWhiteBalance() }.buttonStyle(.secondaryAction).controlSize(.small)
                        .disabled(!model.canAutoBalance).help(L10n.tr("Balance from the skin and the wall behind the head"))
                    if model.balancing { ProgressView().controlSize(.mini) }
                }
            }
            // Temperature for every photo, as in Develop: a JPEG's is applied to the decoded image, 6500 K being neutral.
            ExportRow(L10n.tr("Temperature")) {
                HStack(spacing: 8) {
                    FormSlider(value: Binding(get: { development.temperature }, set: { model.setBalance(\.temperature, $0) }), in: 2000...12000)
                    Text("\(Int(development.temperature)) K").monospacedDigit().frame(width: 52, alignment: .trailing)
                }
            }
            ExportRow(L10n.tr("Tint")) {
                HStack(spacing: 8) {
                    FormSlider(value: Binding(get: { development.tint }, set: { model.setBalance(\.tint, $0) }), in: -150...150)
                    Text("\(Int(development.tint))").monospacedDigit().frame(width: 52, alignment: .trailing)
                }
            }
        }
    }

    private var photoSize: CGSize { model.renderer?.size ?? .init(width: 1, height: 1) }
}

/// Ready, how many issues, or Retake, in the photo's colour.
struct IDPhotoReadinessTag: View {
    @ObservedObject var model: IDPhotoModel
    var body: some View {
        let colour = IDPhotoReadinessTag.colour(model.readiness)
        Text(model.readinessTitle).font(.system(size: 10, weight: .semibold)).foregroundStyle(colour)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(colour.opacity(0.14), in: Capsule())
    }
    static let selection = Color(nsColor: .selectedContentBackgroundColor)
    static func colour(_ readiness: IDPhotoReadiness) -> Color {
        switch readiness { case .ready: Theme.pick; case .needsFix: Theme.warning; case .retake: Theme.reject }
    }
    static func symbol(_ readiness: IDPhotoReadiness) -> String {
        switch readiness { case .ready: "checkmark.circle.fill"; case .needsFix: "exclamationmark.circle.fill"; case .retake: "xmark.circle.fill" }
    }
}

/// The document's size and rules, and where they come from.
struct IDPhotoSpecSummary: View {
    let spec: IDPhotoSpec
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(spec.title).font(.system(size: 12, weight: .semibold))
            Text(L10n.tr("\(spec.sizeTitle) · head \(millimetres(spec.headRange.lowerBound, unit: false))–\(millimetres(spec.headRange.upperBound)) · \(Int(spec.printDPI)) ppi"))
                .foregroundStyle(.secondary)
            if let notes = spec.notes, !notes.isEmpty { Text(notes).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let source = spec.source.flatMap(URL.init(string:)) {
                Link(L10n.tr("Official requirements"), destination: source)
            }
        }.font(.system(size: 11))
    }
}

private func millimetres(_ value: Double, signed: Bool = false, unit: Bool = true) -> String {
    let number = value.formatted(.number.precision(.fractionLength(1)).sign(strategy: signed ? .always(includingZero: false) : .automatic).locale(L10n.locale))
    return unit ? L10n.tr("\(number) mm") : number
}

/// The spec picker: the user's templates, then countries with one document as items and the others as submenus.
private struct SpecMenu: View {
    /// Nil until a document is chosen.
    let selection: IDPhotoSpec?
    let newTemplate: () -> Void
    let choose: (IDPhotoSpec) -> Void
    @ObservedObject private var store = IDPhotoTemplateStore.shared
    @Environment(\.openSettings) private var openSettings
    @AppStorage(PreferencesTab.key) private var preferencesTab = PreferencesTab.general.rawValue
    var body: some View {
        Menu {
            ForEach(store.groups(), id: \.name) { group in
                if group.specs.first?.isCustom == true {
                    Section(group.name) { ForEach(group.specs) { item($0, title: $0.document) } }
                    Divider()
                } else if group.specs.count == 1 {
                    item(group.specs[0], title: group.specs[0].title)
                } else {
                    Menu(group.name) { ForEach(group.specs) { item($0, title: $0.documentTitle) } }
                }
            }
            Divider()
            Button(L10n.tr("New Template…"), action: newTemplate)
            Button(L10n.tr("Manage Templates…")) { preferencesTab = PreferencesTab.idPhoto.rawValue; openSettings() }
        } label: {
            HStack(spacing: 6) {
                Text(selection?.title ?? L10n.tr("Choose Document")).lineLimit(1).foregroundStyle(selection == nil ? .secondary : .primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity)
        }
        .menuStyle(.button).buttonStyle(FormSelectStyle()).menuIndicator(.hidden).nativeMenuItems()
        .accessibilityLabel(L10n.tr("Document")).accessibilityValue(selection?.title ?? "")
    }
    private func item(_ spec: IDPhotoSpec, title: String) -> some View {
        Toggle("\(title) – \(spec.sizeTitle)", isOn: Binding(get: { spec.id == selection?.id }, set: { if $0 { choose(spec) } }))
    }
}

/// A batch's photos along the bottom, as in the other photo tools: each as its finished print, how it stands, and its
/// copies. Click to select; right-click to adjust, leave out or remove.
private struct IDPhotoFilmstrip: View {
    @ObservedObject var session: IDPhotoSession
    let export: (IDPhotoModel) -> Void
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(Array(session.photos.enumerated()), id: \.element.id) { index, photo in
                    IDPhotoFilmstripItem(photo: photo, session: session, selected: index == session.current, export: { export(photo) }) { session.current = index }
                }
            }.padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(height: 148).background(Theme.statusBar)
    }
}

private struct IDPhotoFilmstripItem: View {
    @ObservedObject var photo: IDPhotoModel
    @ObservedObject var session: IDPhotoSession
    let selected: Bool
    let export: () -> Void
    let select: () -> Void
    var body: some View {
        let aspect = photo.layout.map { $0.spec.widthMM / $0.spec.heightMM } ?? 35.0 / 45
        let leftOut = session.isLeftOut(photo)
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let image = photo.printPreview {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high)
                } else if photo.needsDocument, let preview = photo.preview {
                    Image(decorative: preview, scale: 1).resizable().interpolation(.high).scaledToFill().clipped()
                } else if case .failed = photo.stage {
                    Color.black.overlay { Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary) }
                } else {
                    Color.black.overlay { ProgressView().controlSize(.small) }
                }
            }
            .aspectRatio(aspect, contentMode: .fit).frame(height: 88)
            .clipped()
            .opacity(leftOut ? 0.35 : 1)
            .selectionRing(selected ? IDPhotoReadinessTag.selection : nil, width: 2.5)
            .overlay(alignment: .topTrailing) {
                if photo.stage == .ready, photo.readiness != .ready {
                    Image(systemName: IDPhotoReadinessTag.symbol(photo.readiness)).font(.system(size: 13))
                        .symbolRenderingMode(.palette).foregroundStyle(.white, IDPhotoReadinessTag.colour(photo.readiness)).padding(3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
            Text(photo.asset.filename).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Text(leftOut ? L10n.tr("Left out") : photo.stage == .ready ? L10n.tr("×\(session.copies(of: photo)) · \(photo.readinessTitle)") : " ")
                .font(.system(size: 10)).foregroundStyle(photo.stage == .ready && !leftOut ? IDPhotoReadinessTag.colour(photo.readiness) : .secondary).lineLimit(1)
        }
        .frame(width: max(68, 88 * aspect), alignment: .leading)
        .contextMenu {
            Button(L10n.tr("Adjust Framing…")) { select(); session.adjusting = true }.disabled(photo.stage != .ready)
            Button(L10n.tr("Export This Photo…"), action: export).disabled(photo.stage != .ready)
            Divider()
            if leftOut { Button(L10n.tr("Put Back")) { session.resetCopies(of: photo) } }
            else { Button(L10n.tr("Leave Out")) { session.leaveOut(photo) }.disabled(photo.stage != .ready) }
            Button(L10n.tr("Remove from ID Photo")) { session.remove(photo) }
        }
    }
}
