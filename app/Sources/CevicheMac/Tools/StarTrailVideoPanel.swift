import SwiftUI
import CevicheCore

/// What Star Trails makes: the merged still, a video of the trails building up, or that build-up as a Live Photo.
enum StarTrailsOutput: String, Codable, CaseIterable {
    case image, video, livePhoto
    var title: String {
        switch self {
        case .image: L10n.tr("Image", context: "output")
        case .video: L10n.tr("Video")
        case .livePhoto: L10n.tr("Live Photo")
        }
    }
    /// Video and Live Photo both animate the trails, with the same options.
    var animates: Bool { self != .image }
}

/// Whether the meteors kept stay in Star Trails' video to the end, as in the still, or hold a while and fade out, both
/// counted in seconds of video or in frames. One choice for every meteor.
struct StarTrailMeteorFade: Codable, Equatable {
    enum Unit: String, Codable, CaseIterable { case seconds, frames }
    var fades = false
    var hold = 1.0
    var fadeOut = 0.5
    var unit = Unit.seconds

    /// `amount` in frames at the video's `rate`.
    private func frames(_ amount: Double, rate: Double) -> Int { Int((unit == .frames ? amount : amount * rate).rounded()) }
    func fade(rate: Double) -> StarTrailsMeteorFade? {
        fades ? StarTrailsMeteorFade(hold: frames(hold, rate: rate), fade: frames(fadeOut, rate: rate)) : nil
    }
}

/// Star Trails' video options, remembered apart from the timelapse's.
struct StarTrailVideoOptions: Codable, Equatable {
    var settings: TimelapseSettings
    var trails: StarTrailsVideoTrails
    var glow: StarTrailsVideoGlow
    var meteors: StarTrailMeteorFade

    private static let settingsKey = "starTrailVideoSettings", trailsKey = "starTrailVideoTrails", glowKey = "starTrailVideoGlow",
                       meteorsKey = "starTrailMeteorFade"
    static var remembered: StarTrailVideoOptions {
        let defaults = UserDefaults.standard
        return StarTrailVideoOptions(
            settings: TimelapseSettings.remembered(settingsKey) ?? { var settings = TimelapseSettings(); settings.aspect = .original; return settings }(),
            trails: defaults.string(forKey: trailsKey).flatMap(StarTrailsVideoTrails.init(rawValue:)) ?? .smooth,
            glow: defaults.string(forKey: glowKey).flatMap(StarTrailsVideoGlow.init(rawValue:)) ?? .medium,
            meteors: defaults.data(forKey: meteorsKey).flatMap { try? JSONDecoder().decode(StarTrailMeteorFade.self, from: $0) } ?? StarTrailMeteorFade())
    }
    func remember() {
        let defaults = UserDefaults.standard
        settings.remember(Self.settingsKey)
        defaults.set(trails.rawValue, forKey: Self.trailsKey)
        defaults.set(glow.rawValue, forKey: Self.glowKey)
        defaults.set(try? JSONEncoder().encode(meteors), forKey: Self.meteorsKey)
    }
}

/// The video's options beside the Objects list while Star Trails makes a video, in the same frame: a resizable edge,
/// a header (with Crop, which edits the video's frame on the preview) and the options below, how the trails and meteors
/// are drawn, then the encoding, frame and size as in Timelapse.
struct StarTrailVideoPanel: View {
    @Binding var options: StarTrailVideoOptions
    @Binding var cropping: Bool
    /// A Live Photo is always 3 seconds at an iPhone's sizes, so the encoding options are left out.
    let output: StarTrailsOutput
    let photoSize: CGSize
    let frames: Int
    /// Kept across launches, like the Objects list's.
    @AppStorage("nightSkyVideoWidth") private var width = 380.0
    /// Wide enough for a row's label and its widest control, Hold's amount and unit.
    private static var widths: ClosedRange<Double> { 360...480 }

    var body: some View {
        HStack(spacing: 0) {
            SidebarResizeHandle(width: $width, range: Self.widths, defaultWidth: 380, panelOnRight: true)
            VStack(spacing: 0) {
                HStack {
                    Text(output.title).font(.headline)
                    Spacer()
                    NightSkyIconButton(icon: "crop", label: L10n.tr("Crop"), on: cropping) { cropping.toggle() }
                        .help(L10n.tr("Crop: edit the video’s frame on the preview, drag it to move it, a corner to resize it"))
                }.frame(height: 22).padding(.horizontal, 16).padding(.vertical, 8)
                Rule()
                ScrollView { settings.padding(16).frame(maxWidth: .infinity, alignment: .leading) }
            }
            .frame(width: min(Self.widths.upperBound, max(Self.widths.lowerBound, width)))
            .frame(maxHeight: .infinity).background(Theme.statusBar)
        }
    }

    private var settings: some View {
            VStack(alignment: .leading, spacing: 14) {
                // The frame's proportions first, under Crop, which places that frame on the preview.
                ExportRow(L10n.tr("Frame")) {
                    FormSelect(L10n.tr("Frame"), selection: $options.settings.aspect, valueLabel: options.settings.aspect.title) {
                        ForEach(VideoAspect.allCases) { aspect in
                            Text(aspect.title).tag(aspect)
                            if aspect == .scope { Divider() }
                        }
                    }.labelsHidden()
                }
                if output == .livePhoto {
                    LivePhotoSizeRow(settings: $options.settings, ratio: options.settings.ratio(photo: photoSize), photo: photoSize)
                }
                ExportRow(L10n.tr("Trails")) {
                    FormSegments(title: L10n.tr("Trails"), selection: $options.trails, options: StarTrailsVideoTrails.allCases, label: { $0.title }).fixedSize()
                        .help(L10n.tr("Smooth draws in the pauses between exposures and adds a slight glow; Dashed shows the trails as the photos recorded them"))
                }
                if options.trails == .smooth {
                    ExportRow(L10n.tr("Glow")) {
                        FormSegments(title: L10n.tr("Glow"), selection: $options.glow, options: StarTrailsVideoGlow.allCases, label: { $0.title }).fixedSize()
                    }
                }
                ExportRow(L10n.tr("Meteors")) {
                    FormSegments(title: L10n.tr("Meteors"), selection: $options.meteors.fades, options: [false, true],
                                 label: { $0 ? L10n.tr("Fade", context: "meteors") : L10n.tr("Stay", context: "meteors") }).fixedSize()
                        .help(L10n.tr("Stay keeps each meteor to the end, as the still does; Fade holds it a while from its photo on, then fades it out"))
                }
                if options.meteors.fades {
                    ExportRow(L10n.tr("Hold")) {
                        HStack(spacing: 8) {
                            amount($options.meteors.hold, least: options.meteors.unit == .frames ? 1 : 0.1)
                                .help(L10n.tr("How long a meteor stays at full strength from its photo on"))
                            FormSegments(title: L10n.tr("Unit"), selection: $options.meteors.unit, options: StarTrailMeteorFade.Unit.allCases,
                                         label: { $0 == .seconds ? L10n.tr("Seconds") : L10n.tr("Frames") }).labelsHidden().fixedSize()
                        }
                    }
                    ExportRow(L10n.tr("Fade", context: "meteors")) {
                        amount($options.meteors.fadeOut, least: 0)
                            .help(L10n.tr("How long it then takes to fade out; 0 takes it away at once"))
                    }
                }
                if output == .video {
                    Rule()
                    VideoEncodingOptions(settings: $options.settings, photoSize: photoSize, frames: frames, showsFrame: false)
                    VideoEncodingOptions.metadataToggle($options.settings.includeMetadata)
                }
            }
            .font(.system(size: 12))
    }

    private func amount(_ value: Binding<Double>, least: Double) -> some View {
        TextField("", value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = min(600, max(least, $0)) }),
                  format: .number.precision(.fractionLength(0...1)))
            .textFieldStyle(.formField).labelsHidden().frame(width: 52).multilineTextAlignment(.trailing)
    }
}

/// The video's frame over the preview, the rest dimmed. Only drawn unless `editing`, so clicks and drags reach the
/// lines and brushes underneath; while editing (the toolbar's Crop) it takes every drag on the preview: inside the
/// frame moves it, a corner resizes it in its proportions, and a double-click fills the photo again.
struct StarTrailVideoFrame: View {
    @Binding var crop: TimelapseCrop
    let ratio: Double
    let editing: Bool
    @State private var drag: (corner: Int?, start: CGRect)?
    private static let grip: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let frame = crop.rect(in: size, aspect: ratio)
            ZStack(alignment: .topLeading) {
                Path { path in path.addRect(CGRect(origin: .zero, size: size)); path.addRect(frame) }
                    .fill(Color.black.opacity(editing ? 0.55 : 0.4), style: FillStyle(eoFill: true))
                if editing {
                    Path { path in
                        for third in [1.0 / 3, 2.0 / 3] {
                            path.move(to: CGPoint(x: frame.minX + frame.width * third, y: frame.minY)); path.addLine(to: CGPoint(x: frame.minX + frame.width * third, y: frame.maxY))
                            path.move(to: CGPoint(x: frame.minX, y: frame.minY + frame.height * third)); path.addLine(to: CGPoint(x: frame.maxX, y: frame.minY + frame.height * third))
                        }
                    }.stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                }
                Rectangle().stroke(Color.white.opacity(editing ? 1 : 0.6), lineWidth: 1).frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY)
                if editing {
                    ForEach(0..<4, id: \.self) { corner in
                        Rectangle().fill(Color.white).frame(width: 9, height: 9).position(Self.corner(corner, of: frame))
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                if drag == nil {
                    let corner = (0..<4).first { hypot(Self.corner($0, of: frame).x - value.startLocation.x, Self.corner($0, of: frame).y - value.startLocation.y) < Self.grip }
                    guard corner != nil || frame.contains(value.startLocation) else { return }
                    drag = (corner, frame)
                }
                guard let drag else { return }
                if let corner = drag.corner {
                    // The opposite corner stays put; the frame follows the pointer in its own proportions.
                    let anchor = Self.corner((corner + 2) % 4, of: drag.start)
                    let width = max(abs(value.location.x - anchor.x), abs(value.location.y - anchor.y) * ratio), height = width / ratio
                    let x = value.location.x < anchor.x ? anchor.x - width : anchor.x
                    let y = value.location.y < anchor.y ? anchor.y - height : anchor.y
                    crop = TimelapseCrop.framing(CGRect(x: x, y: y, width: width, height: height), in: size, aspect: ratio)
                } else {
                    crop = TimelapseCrop.framing(drag.start.offsetBy(dx: value.translation.width, dy: value.translation.height), in: size, aspect: ratio)
                }
            }.onEnded { _ in drag = nil })
            .onTapGesture(count: 2) { crop = TimelapseCrop() }
            .allowsHitTesting(editing)
        }
        .help(editing ? L10n.tr("Drag the frame to move it, a corner to resize it. Double-click to fill the photo.") : "")
        .accessibilityLabel(L10n.tr("Video frame"))
    }

    /// Corners clockwise from the top left.
    private static func corner(_ index: Int, of rect: CGRect) -> CGPoint {
        switch index {
        case 0: CGPoint(x: rect.minX, y: rect.minY)
        case 1: CGPoint(x: rect.maxX, y: rect.minY)
        case 2: CGPoint(x: rect.maxX, y: rect.maxY)
        default: CGPoint(x: rect.minX, y: rect.maxY)
        }
    }
}

/// Per-object output choices, separate from the defaults for a new sequence.
struct StarTrailLatentOptions: Codable {
    var output: StarTrailsOutput
    var video: StarTrailVideoOptions
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
