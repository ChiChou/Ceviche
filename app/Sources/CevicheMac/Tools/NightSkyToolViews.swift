import SwiftUI
import AppKit
import CoreMedia
import CevicheCore

/// Star trails: the brightest of every photo in the camera's frame, with the ground averaged.
struct StarTrailsView: View {
    @ObservedObject var catalog: CatalogModel
    @StateObject private var model: NightSkyModel<StarTrailsMerger>
    @StateObject private var objects = NightSkyObjectSelection()
    /// Whether the Objects list and the outlines show; nil shows them when any line was found.
    @State private var showObjects: Bool?
    /// The still or a video, kept across launches; a video's options show beside the preview.
    @AppStorage("starTrailsOutput") private var output = StarTrailsOutput.image
    @State private var video = StarTrailVideoOptions.remembered
    /// Whether drags on the preview edit the video's frame instead of selecting lines or painting.
    @State private var cropping = false
    @State private var restoredPresentation = false
    init(catalog: CatalogModel, request: NightSkyRequest) {
        self.catalog = catalog
        _model = StateObject(wrappedValue: NightSkyModel(request: request, settings: StarTrailsSettings()))
    }

    private var showsObjects: Bool { showObjects ?? (model.analysis.map { !$0.lines.isEmpty } ?? false) }
    /// A line from a photo left out of the trails has nothing to go into.
    private var chooser: NightSkyLineChooser<StarTrailsSettings>? {
        model.analysis.map { analysis in
            NightSkyLineChooser(frames: analysis.frames, lines: analysis.lines, settings: $model.settings,
                                unavailable: { model.settings.excluded.contains($0.frame) ? L10n.tr("Photo left out") : nil })
        }
    }

    var body: some View {
        NightSkyChrome(catalog: catalog, model: model, status: output == .video ? videoStatus : output == .livePhoto ? livePhotoStatus : status,
                       statusIsWarning: model.analysis?.skyModelInstalled == false || videoProblem != nil, image: nil,
                       primaryTitle: primaryTitle, overlayTakesDrags: output.animates && cropping, offersTIFF: output == .image,
                       onMerge: create, toolbar: { toolbar }, sidebar: { sidebar },
                       overlay: {
                           if showsObjects { NightSkyObjectOutlines(preview: model.preview, chooser: chooser, selection: objects, showAll: true) }
                           if output.animates, model.analysis != nil { StarTrailVideoFrame(crop: $video.settings.crop, ratio: video.settings.ratio(photo: photoSize), editing: cropping) }
                       },
                       filmstrip: model.analysis?.frames ?? []) { frame in
            NightSkyFrameCell(frame: frame, included: !model.settings.excluded.contains(frame.index), canToggle: canToggle(frame),
                              badge: model.settings.sky == .onePhoto && frame.index == skyPhoto ? L10n.tr("Base") : nil, onToggle: { toggle(frame.index) },
                              onSelect: model.settings.sky == .onePhoto ? { useSky(frame.index) } : nil,
                              selectHelp: L10n.tr("Draw the trails over this photo’s sky"), lane: output.animates ? lane[frame.index] ?? NightSkyLaneMark.empty : nil)
        }
        .onAppear {
            if model.request.latentURL == nil { restoredPresentation = true; savePresentation() }
            model.start(catalog: catalog) { analysis, settings in settings.excluded = analysis.suggestedExclusions }
        }
        .onChange(of: model.presentation) { _, data in
            guard !restoredPresentation, let data, let saved = try? JSONDecoder().decode(StarTrailLatentOptions.self, from: data) else { return }
            restoredPresentation = true; output = saved.output; video = saved.video
        }
        // A reopened object's options are its own, not the defaults for the next sequence.
        .onChange(of: video) { _, options in if model.request.latentURL == nil { options.remember() }; savePresentation() }
        // Crop and the brushes each own drags on the preview; one puts the other down.
        .onChange(of: model.brush) { _, brush in if brush != nil { cropping = false } }
        .onChange(of: cropping) { _, on in if on { model.brush = nil } }
        .onChange(of: output) { _, output in if !output.animates { cropping = false }; savePresentation() }
    }

    private func savePresentation() {
        guard restoredPresentation else { return }
        model.presentation = try? StarTrailLatentOptions(output: output, video: video).encoded()
    }

    @ViewBuilder private var toolbar: some View {
        FormSegments(title: L10n.tr("Output"), selection: $output, options: StarTrailsOutput.allCases, label: { $0.title }).labelsHidden().fixedSize()
            .help(L10n.tr("Image merges the photos into one still. Video shows the trails building up, one frame per photo, with its options beside the preview. Live Photo fits that build-up into 3 seconds and adds it to Photos."))
        Rule(.vertical).frame(height: 16)
        Text(L10n.tr("Sky")).foregroundStyle(.secondary)
        FormSegments(title: L10n.tr("Sky"), selection: $model.settings.sky, options: StarTrailsSky.allCases, label: { $0.title }).labelsHidden().fixedSize()
            .help(L10n.tr("Brightest keeps every photo’s brightest light, aurora and glow included. One Photo keeps one photo’s sky, chosen in the strip below, and draws the stars’ trails over it."))
        Toggle(L10n.tr("Keep Star Colors"), isOn: $model.settings.keepStarColors)
            .help(L10n.tr("Takes each trail’s color whole from the photo where it was brightest, instead of each color channel’s brightest value"))
        // Smooth trails in a video draw every pause anyway.
        let smoothVideo = output.animates && video.trails == .smooth
        Toggle(L10n.tr("Fill Gaps"), isOn: smoothVideo ? .constant(true) : $model.settings.fillGaps).disabled(smoothVideo)
            .help(smoothVideo ? L10n.tr("Smooth trails in the video draw every pause; choose Dashed to leave them")
                  : L10n.tr("Draws the stars’ motion through the pauses between exposures, so trails don’t break. This is drawn, not captured light."))
        Rule(.vertical).frame(height: 16)
        NightSkyEdgeControls(settings: $model.settings, showSky: $model.showSky)
        Rule(.vertical).frame(height: 16)
        NightSkyPhotoBrushes(brush: $model.brush, settings: $model.settings, diameter: $model.brushDiameter, photo: model.settings.sky == .onePhoto ? L10n.tr("the base photo") : L10n.tr("the middle photo"))
        NightSkyHistoryButtons(history: model.history)
        Rule(.vertical).frame(height: 16)
        Toggle(L10n.tr("Objects"), isOn: Binding(get: { showsObjects }, set: { showObjects = $0 }))
            .help(L10n.tr("Lists the lines found beside the preview and outlines them over it, to choose which stay in the trails. Aircraft and satellites, whose lines continue across photos, are left out unless you include them; meteors stay unless you exclude them."))
        Spacer(minLength: 0)
    }

    /// The Objects list next to the preview, then while making a video its options at the window's edge.
    @ViewBuilder private var sidebar: some View {
        if showsObjects {
            NightSkyObjectsPanel(chooser: chooser, selection: objects) { index in
                if model.settings.sky == .onePhoto {
                    if index == skyPhoto {
                        AccentBadge(text: L10n.tr("Base"))
                    } else {
                        Button(L10n.tr("Use as Base")) { useSky(index) }.buttonStyle(.textLink).font(.system(size: 11))
                            .help(L10n.tr("Draw the trails over this photo’s sky"))
                    }
                }
            }
        }
        if output.animates, model.analysis != nil {
            StarTrailVideoPanel(options: $video, cropping: $cropping, output: output, photoSize: photoSize, frames: included.count)
        }
    }

    private var status: String {
        guard let analysis = model.analysis else { return L10n.tr("\(model.photoCount) photos") }
        if !analysis.skyModelInstalled { return L10n.tr("The Sky model isn’t installed, so the ground is treated as sky. Install it in Settings › Models.") }
        // Pauses show in the strip and lines left out in the Objects list.
        let used = analysis.frames.count - model.settings.excluded.count
        let photos = L10n.tr("\(used) of \(analysis.frames.count) photos")
        guard let timing = analysis.timing else { return photos }
        return L10n.tr("\(photos), \(NightSkyFormat.duration(timing.span))")
    }
    /// The photo whose sky One Photo keeps: the chosen one, or the middle included one.
    private var skyPhoto: Int? {
        guard let analysis = model.analysis else { return nil }
        let included = analysis.frames.map(\.index).filter { !model.settings.excluded.contains($0) }
        return model.settings.skyPhoto.flatMap { included.contains($0) ? $0 : nil } ?? (included.isEmpty ? nil : included[included.count / 2])
    }
    private func canToggle(_ frame: NightSkyFrameInfo) -> Bool {
        !(model.settings.sky == .onePhoto && frame.index == skyPhoto)
            && (model.settings.excluded.contains(frame.index) || (model.analysis?.frames.count ?? 0) - model.settings.excluded.count > 2)
    }
    private func toggle(_ index: Int) {
        if model.settings.excluded.contains(index) { model.settings.excluded.remove(index) } else { model.settings.excluded.insert(index) }
    }
    private func useSky(_ index: Int) {
        model.settings.excluded.remove(index); model.settings.skyPhoto = index
    }
    private var included: [Int] { (model.analysis?.frames ?? []).map(\.index).filter { !model.settings.excluded.contains($0) } }
    private var photoSize: CGSize { CGSize(width: model.analysis?.width ?? 3, height: model.analysis?.height ?? 2) }
    /// Why the video can't be made with these options, such as a size the encoder refuses.
    private var videoProblem: String? {
        guard output == .video, model.analysis != nil else { return nil }
        do { try video.settings.validate(photo: photoSize) } catch { return error.localizedDescription }
        return nil
    }
    /// The video's frames, length and size, as Timelapse sums it up.
    private var videoStatus: String {
        guard model.analysis != nil else { return status }
        if let videoProblem { return videoProblem }
        let size = video.settings.outputSize(photo: photoSize)
        return [L10n.tr("\(included.count) frames"),
                L10n.tr("\(TimelapseDialog.duration(video.settings.duration(frames: included.count))) at \(video.settings.frameRate.title)"),
                "\(Int(size.width)) × \(Int(size.height))"].joined(separator: " - ")
    }
    /// Per included photo, how bright the meteors kept look in its video frame: from a meteor's own photo on, to the
    /// end or holding and fading as the video's options have it.
    private var lane: [Int: NightSkyLaneMark] {
        guard let analysis = model.analysis, let chooser else { return [:] }
        let order = included, position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let starts = analysis.lines.filter { $0.kind == .meteor && chooser.reaches($0) }.compactMap { position[$0.frame] }
        guard !starts.isEmpty else { return [:] }
        let fade = meteorFade
        var marks: [Int: NightSkyLaneMark] = [:]
        for (k, index) in order.enumerated() {
            // As bright as it looks: the frames are linear light, the strength too.
            let strength = starts.map { start in k < start ? 0 : fade.map { pow(Double($0.strength(age: k - start)), 1 / 2.2) } ?? 1 }.max() ?? 0
            if strength > 0 { marks[index] = NightSkyLaneMark(strength: strength, starts: starts.contains(k)) }
        }
        return marks
    }
    /// The photo the result sits beside and takes its name from: the sky photo, or the middle one.
    private var besidePhoto: Int {
        let included = included
        return model.settings.sky == .onePhoto ? skyPhoto ?? included[included.count / 2] : included[included.count / 2]
    }
    private func merge(_ format: ProcessedFormat) { model.merge(catalog: catalog, beside: besidePhoto, count: included.count, format: format) }
    private var primaryTitle: String {
        switch output {
        case .image: L10n.tr("Merge")
        case .video: L10n.tr("Render Video…")
        case .livePhoto: L10n.tr("Add Live Photo to Photos")
        }
    }
    private func create(_ format: ProcessedFormat) {
        switch output {
        case .image: merge(format)
        case .video: createVideo()
        case .livePhoto:
            model.createLivePhoto(catalog: catalog, beside: besidePhoto, included: included, crop: video.settings.crop,
                                  ratio: video.settings.ratio(photo: photoSize), size: video.settings.livePhotoSize, trails: video.trails, glow: video.glow, meteorFade: meteorFade)
        }
    }
    /// The meteors' fade in photos: a video shows one frame per photo, a Live Photo fits them all into 3 seconds.
    private var meteorFade: StarTrailsMeteorFade? {
        video.meteors.fade(rate: output == .livePhoto ? Double(included.count) / LivePhoto.movieSeconds : video.settings.frameRate.rate)
    }
    /// The photos used, the movie's pace and length, and its size.
    private var livePhotoStatus: String {
        guard model.analysis != nil else { return status }
        let frames = LivePhoto.sample(included.count).count, seconds = LivePhoto.sampleDuration(frames).seconds * Double(frames)
        let size = CatalogModel.livePhotoSizes(ratio: video.settings.ratio(photo: photoSize), settings: video.settings, photo: photoSize).movie
        return [L10n.tr("\(included.count) photos - \(Int((Double(frames) / seconds).rounded())) fps - \(String(format: "%.1f", locale: Locale.current, seconds)) s"),
                "\(Int(size.width)) × \(Int(size.height))"].joined(separator: " - ")
    }
    private func createVideo() {
        guard videoProblem == nil else { return }
        model.createVideo(catalog: catalog, beside: besidePhoto, included: included, settings: video.settings, trails: video.trails, glow: video.glow,
                          meteorFade: meteorFade)
    }
}

/// Night sky noise reduction: the sky aligned by its stars and averaged, the ground averaged in place.
struct NightSkyDenoiseView: View {
    @ObservedObject var catalog: CatalogModel
    @StateObject private var model: NightSkyModel<NightSkyDenoiser>
    @State private var showReference = false
    @State private var referenceImage: (Int, CGImage)?
    init(catalog: CatalogModel, request: NightSkyRequest) {
        self.catalog = catalog
        _model = StateObject(wrappedValue: NightSkyModel(request: request, settings: NightSkyDenoiseSettings()))
    }

    private var reference: Int? { model.settings.reference ?? model.analysis?.suggestedReference }

    var body: some View {
        NightSkyChrome(catalog: catalog, model: model, status: status, statusIsWarning: warning,
                       image: showReference && referenceImage?.0 == reference ? referenceImage?.1 : nil,
                       onMerge: merge, toolbar: { toolbar }, sidebar: { EmptyView() }, overlay: { EmptyView() },
                       filmstrip: model.analysis?.frames ?? []) { frame in
            NightSkyFrameCell(frame: frame, included: !model.settings.excluded.contains(frame.index), canToggle: canToggle(frame),
                              badge: frame.index == reference ? L10n.tr("Base") : nil, onToggle: { toggle(frame.index) },
                              onSelect: frame.isAligned ? { makeReference(frame.index) } : nil,
                              selectHelp: L10n.tr("Align the stars to this photo’s moment and framing"))
        }
        .onAppear { model.start(catalog: catalog) { analysis, settings in settings.excluded = analysis.suggestedExclusions } }
        .onChange(of: showReference) { loadReference() }
        .onChange(of: model.settings) { loadReference() }
    }

    @ViewBuilder private var toolbar: some View {
        Text(L10n.tr("Ground")).foregroundStyle(.secondary)
        FormSegments(title: L10n.tr("Ground"), selection: $model.settings.ground, options: NightSkyGround.allCases, label: { $0.title }).labelsHidden().fixedSize()
            .help(L10n.tr("Average the ground of every photo for low noise, or keep the base photo’s ground when something on it moved"))
        Toggle(L10n.tr("Reject Outliers"), isOn: $model.settings.rejectOutliers)
            .help(L10n.tr("Averages the sky again without samples far from the other photos at that spot, such as faint satellites, hot pixels and passing lights. Takes about twice as long to create."))
        Rule(.vertical).frame(height: 16)
        NightSkyEdgeControls(settings: $model.settings, showSky: $model.showSky)
        Rule(.vertical).frame(height: 16)
        NightSkyPhotoBrushes(brush: $model.brush, settings: $model.settings, diameter: $model.brushDiameter, photo: L10n.tr("the base photo"))
        NightSkyHistoryButtons(history: model.history)
        Rule(.vertical).frame(height: 16)
        Toggle(L10n.tr("Show Base"), isOn: $showReference).help(L10n.tr("Shows the base photo alone, to compare"))
        Spacer(minLength: 0)
    }

    private var status: String {
        guard let analysis = model.analysis else { return L10n.tr("\(model.photoCount) photos") }
        if !analysis.skyModelInstalled { return L10n.tr("The Sky model isn’t installed, so the ground is treated as sky. Install it in Settings › Models.") }
        let stacked = analysis.frames.filter { $0.isAligned && !model.settings.excluded.contains($0.index) }.count
        let unaligned = analysis.frames.filter { !$0.isAligned }.count
        var text = L10n.tr("\(stacked) of \(analysis.frames.count) photos stacked")
        if let workflow = model.workflow {
            text += L10n.tr(" - worth \(String(format: "%.1f", locale: Locale.current, workflow.effectivePhotos(model.settings))) equal photos")
        }
        text += NightSkyFormat.timing(analysis.timing) + NightSkyFormat.series(analysis.frames, excluded: model.settings.excluded)
        if unaligned == 1 { text += L10n.tr(" - 1 photo couldn’t be aligned") } else if unaligned > 1 { text += L10n.tr(" - \(unaligned) photos couldn’t be aligned") }
        return text
    }
    private var warning: Bool { model.analysis.map { !$0.skyModelInstalled || $0.frames.contains { !$0.isAligned } } ?? false }

    private func canToggle(_ frame: NightSkyFrameInfo) -> Bool {
        frame.index != reference && (model.settings.excluded.contains(frame.index) || (model.analysis?.frames.count ?? 0) - model.settings.excluded.count > 2)
    }
    private func toggle(_ index: Int) {
        if model.settings.excluded.contains(index) { model.settings.excluded.remove(index) } else { model.settings.excluded.insert(index) }
    }
    private func makeReference(_ index: Int) {
        model.settings.excluded.remove(index)
        model.settings.reference = index == model.analysis?.suggestedReference ? nil : index
    }
    private func loadReference() {
        guard showReference, let workflow = model.workflow, let reference, referenceImage?.0 != reference else { return }
        let settings = model.settings
        Task {
            guard let picture = await Task.detached(priority: .userInitiated, operation: { try? workflow.referencePicture(settings) }).value else { return }
            referenceImage = (reference, await model.developed(picture).image)
        }
    }
    private func merge(_ format: ProcessedFormat) {
        guard let analysis = model.analysis, let reference else { return }
        let stacked = analysis.frames.filter { $0.isAligned && !model.settings.excluded.contains($0.index) }.count
        model.merge(catalog: catalog, beside: reference, count: stacked, format: format)
    }
}

/// Meteor shower: the meteors found in every photo, gathered onto a base photo's ground and sky.
struct MeteorShowerView: View {
    @ObservedObject var catalog: CatalogModel
    @StateObject private var model: NightSkyModel<MeteorShowerMerger>
    @StateObject private var objects = NightSkyObjectSelection()
    @State private var showOutlines = true
    init(catalog: CatalogModel, request: NightSkyRequest) {
        self.catalog = catalog
        _model = StateObject(wrappedValue: NightSkyModel(request: request, settings: MeteorShowerSettings()))
    }

    private var base: Int? { model.settings.base ?? model.analysis?.suggestedBase }
    /// The photos whose sky is averaged, shown included in the strip.
    private var skyFrames: Set<Int> {
        guard let analysis = model.analysis, let base else { return [] }
        return Set(analysis.skyFrames(base: base, model.settings))
    }
    /// Lines from photos that couldn't be aligned can't be moved onto the base sky.
    private var chooser: NightSkyLineChooser<MeteorShowerSettings>? {
        model.analysis.map { analysis in
            NightSkyLineChooser(frames: analysis.frames, lines: analysis.lines, settings: $model.settings,
                                unavailable: { analysis.frames[$0.frame].isAligned ? nil : L10n.tr("Photo couldn’t be aligned") })
        }
    }

    var body: some View {
        NightSkyChrome(catalog: catalog, model: model, status: status, statusIsWarning: model.analysis?.skyModelInstalled == false, image: nil,
                       onMerge: merge, toolbar: { toolbar }, sidebar: { sidebar },
                       overlay: { NightSkyObjectOutlines(preview: model.preview, chooser: chooser, selection: objects, showAll: showOutlines) },
                       filmstrip: model.analysis?.frames ?? []) { frame in
            NightSkyFrameCell(frame: frame, included: model.settings.skyPhotos == 1 ? !model.settings.excluded.contains(frame.index) : skyFrames.contains(frame.index),
                              canToggle: model.settings.skyPhotos > 1 && frame.index != base
                                && (skyFrames.contains(frame.index) || model.settings.excluded.contains(frame.index)),
                              badge: frame.index == base ? L10n.tr("Base") : nil, onToggle: { toggle(frame.index) },
                              onSelect: frame.isAligned ? { makeBase(frame.index) } : nil,
                              selectHelp: L10n.tr("Take the ground and the stars’ positions from this photo"))
        }
        .onAppear { model.start(catalog: catalog) { analysis, settings in settings.excluded = analysis.suggestedExclusions } }
    }

    @ViewBuilder private var toolbar: some View {
        FormSegments(title: L10n.tr("Meteors"), selection: $model.settings.asCaptured, options: [false, true], label: { $0 ? L10n.tr("As Captured") : L10n.tr("On Base Sky") }).labelsHidden().fixedSize()
            .help(L10n.tr("On Base Sky moves each meteor with the stars to where the sky stood in the base photo, so the shower radiates as it would have at that moment. As Captured keeps each meteor where the camera recorded it; over a long night the stars it crossed have moved on, and the radiant smears."))
        Text(L10n.tr("Sky Noise")).foregroundStyle(.secondary)
        FormSelect(L10n.tr("Sky Noise"), selection: $model.settings.skyPhotos, valueLabel: model.settings.skyPhotos == 1 ? L10n.tr("Base Photo Only") : L10n.tr("Average \(model.settings.skyPhotos) Photos")) {
            Text(L10n.tr("Base Photo Only")).tag(1)
            Divider()
            // Only samples that agree with the base photo are averaged in, so a skyline detail the sky finder took for sky,
            // such as a treetop, doesn't ghost beside itself; the nearer in time, the more samples agree.
            ForEach([3, 5, 9], id: \.self) { count in Text(L10n.tr("Average \(count) Photos")).tag(count) }
        }.pickerStyle(.menu).labelsHidden().fixedSize()
            .help(L10n.tr("Averages the sky of the base photo with the photos taken just before and after it, aligned to it, to lower noise. Neighbors in time differ least from the base, so the sky glow and clouds match. A photo unchecked in the strip is replaced by the next nearest. Takes longer to create."))
        Rule(.vertical).frame(height: 16)
        NightSkyEdgeControls(settings: $model.settings, showSky: $model.showSky)
        Rule(.vertical).frame(height: 16)
        NightSkyPhotoBrushes(brush: $model.brush, settings: $model.settings, diameter: $model.brushDiameter, photo: L10n.tr("the base photo"))
        NightSkyHistoryButtons(history: model.history)
        Rule(.vertical).frame(height: 16)
        Toggle(L10n.tr("Outlines"), isOn: $showOutlines)
            .help(L10n.tr("Marks every line found: green lines go into the result, red dashed ones are left out. Click a line or drag a box to select lines."))
        Spacer(minLength: 0)
    }

    private var chosen: [NightSkyLineInfo] {
        guard let analysis = model.analysis else { return [] }
        return analysis.lines.filter { model.settings.includes($0) && analysis.frames[$0.frame].isAligned }
    }

    private var status: String {
        guard let analysis = model.analysis else { return L10n.tr("\(model.photoCount) photos") }
        if !analysis.skyModelInstalled { return L10n.tr("The Sky model isn’t installed, so the ground is treated as sky. Install it in Settings › Models.") }
        let chosen = self.chosen, photos = Set(chosen.map(\.frame)).count
        let base = base.map { analysis.frames[$0].filename } ?? ""
        let lines = chosen.count == 1 ? L10n.tr("1 line chosen") : L10n.tr("\(chosen.count) lines chosen")
        return lines + (photos == 1 ? L10n.tr(" from 1 photo") : L10n.tr(" from \(photos) photos")) + L10n.tr(" - base \(base)") + NightSkyFormat.timing(analysis.timing)
            + NightSkyFormat.series(analysis.frames, excluded: model.settings.excluded)
    }

    private var sidebar: some View {
        NightSkyObjectsPanel(chooser: chooser, selection: objects) { index in
            if index == base {
                AccentBadge(text: L10n.tr("Base"))
            } else if model.analysis?.frames[index].isAligned == true {
                Button(L10n.tr("Use as Base")) { makeBase(index) }.buttonStyle(.textLink).font(.system(size: 11))
                    .help(L10n.tr("Take the ground and the stars’ positions from this photo"))
            }
        }
    }

    private func toggle(_ index: Int) {
        if model.settings.excluded.contains(index) { model.settings.excluded.remove(index) } else { model.settings.excluded.insert(index) }
    }
    private func makeBase(_ index: Int) {
        model.settings.excluded.remove(index)
        model.settings.base = index == model.analysis?.suggestedBase ? nil : index
    }
    private func merge(_ format: ProcessedFormat) {
        guard let base else { return }
        model.merge(catalog: catalog, beside: base, count: chosen.count, format: format)
    }
}
