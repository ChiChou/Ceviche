import SwiftUI
import CevicheCore

/// The movie's encoder, color, frame and rate, for any dialog that writes a video from photos.
struct VideoEncodingOptions: View {
    @Binding var settings: TimelapseSettings
    /// The developed photo's size, which As Photo follows.
    let photoSize: CGSize
    /// The video's frame count for the size estimate; nil while unknown.
    let frames: Int?
    /// False leaves the frame's proportions to the caller, which shows them elsewhere, as Star Trails does beside Crop.
    var showsFrame = true

    var body: some View {
        ExportRow(L10n.tr("Encoder")) {
            FormSelect(L10n.tr("Encoder"), selection: $settings.codec, valueLabel: settings.codec.title) {
                ForEach(VideoCodec.allCases) { codec in
                    Text(codec.title).tag(codec)
                    if codec == .hevc { Divider() }
                }
            }.labelsHidden()
        }
        ExportRow(L10n.tr("Container")) {
            FormSelect(L10n.tr("Container"), selection: Binding(get: { settings.fileContainer }, set: { settings.container = $0 }), valueLabel: settings.fileContainer.title) {
                ForEach(settings.codec.containers) { Text($0.title).tag($0) }
            }.labelsHidden().disabled(settings.codec.containers.count < 2)
                .help(settings.codec.isProRes ? L10n.tr("ProRes is written as a QuickTime movie")
                      : L10n.tr("MPEG-4 plays on more devices and sites; QuickTime suits Final Cut Pro and other editors"))
        }
        ExportRow(L10n.tr("Color")) {
            FormSelect(L10n.tr("Color"), selection: Binding(get: { settings.fileColor }, set: { settings.color = $0 }), valueLabel: settings.fileColor.title) {
                ForEach(VideoColor.allCases) { color in
                    Text(color.title).tag(color).disabled(color != .sdr && !settings.codec.supportsWideColor)
                    if color == .rec2020 { Divider() }
                }
            }.labelsHidden()
                .help(settings.codec.supportsWideColor ? L10n.tr("Rec. 709 is what HD and UHD players assume. HLG also looks right on SDR screens; PQ is HDR10, what most HDR delivery asks for.")
                      : L10n.tr("H.264 is Rec. 709 only; choose HEVC or ProRes for Rec. 2020 or HDR"))
        }
        if !settings.codec.isProRes {
            ExportRow(L10n.tr("Compression")) {
                FormSelect(L10n.tr("Compression"), selection: $settings.rateControl, valueLabel: settings.rateControl.title) {
                    ForEach(VideoRateControl.allCases) { Text($0.title).tag($0) }
                }.labelsHidden()
                    .help(L10n.tr("Constant Quality keeps the look and lets the size follow; Average Bitrate keeps the size and lets the look follow"))
            }
            if settings.rateControl == .quality {
                ExportRow(L10n.tr("Quality")) {
                    HStack(spacing: 8) {
                        FormSlider(value: $settings.quality, in: 0.3...1).accessibilityLabel(L10n.tr("Video quality")).frame(maxWidth: 180)
                        Text(L10n.tr("\(Int((settings.quality * 100).rounded()))%")).monospacedDigit().frame(width: 35, alignment: .trailing)
                    }
                }
            } else {
                ExportRow(L10n.tr("Bitrate")) {
                    HStack(spacing: 6) {
                        TextField(L10n.tr("Bitrate"), value: $settings.bitrate, format: .number.precision(.fractionLength(0...1))).frame(width: 64)
                            .textFieldStyle(.formField)
                        Text(L10n.tr("Mbps")).foregroundStyle(.secondary)
                        if let frames, let bytes = settings.estimatedBytes(frames: frames) {
                            Text(L10n.tr("≈ \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                ExportRow("") {
                    Toggle(L10n.tr("Two-pass encoding"), isOn: $settings.multiPass).toggleStyle(.formCheckbox)
                        .help(L10n.tr("The encoder reads the whole video before it spends its bits, so motion gets more of them. Every frame is developed twice, so the video takes about twice as long."))
                }
            }
        }
        if showsFrame {
            ExportRow(L10n.tr("Frame")) {
                FormSelect(L10n.tr("Frame"), selection: $settings.aspect, valueLabel: settings.aspect.title) {
                    ForEach(VideoAspect.allCases) { aspect in
                        Text(aspect.title).tag(aspect)
                        if aspect == .scope { Divider() }
                    }
                }.labelsHidden()
            }
        }
        if settings.aspect == .custom {
            ExportRow(L10n.tr("Size")) {
                HStack(spacing: 6) {
                    TextField(L10n.tr("Width"), value: $settings.customWidth, format: .number.grouping(.never)).frame(width: 64)
                    Text("×").foregroundStyle(.secondary)
                    TextField(L10n.tr("Height"), value: $settings.customHeight, format: .number.grouping(.never)).frame(width: 64)
                    Text(L10n.tr("px")).foregroundStyle(.secondary)
                }.textFieldStyle(.formField)
            }
        } else {
            let output = settings.outputSize(photo: photoSize)
            ExportRow(L10n.tr("Size")) {
                FormSelect(L10n.tr("Size"), selection: $settings.resolution, valueLabel: "\(settings.resolution.title) - \(Int(output.width)) × \(Int(output.height))") {
                    ForEach(VideoResolution.allCases) { resolution in
                        var probe = settings
                        let size = { probe.resolution = resolution; return probe.outputSize(photo: photoSize) }()
                        Text("\(resolution.title) - \(Int(size.width)) × \(Int(size.height))").tag(resolution)
                    }
                }.labelsHidden()
            }
        }
        ExportRow(L10n.tr("Frame rate")) {
            FormSelect(L10n.tr("Frame rate"), selection: $settings.frameRate, valueLabel: settings.frameRate.title) {
                ForEach(TimelapseSettings.frameRateChoices, id: \.self) { Text($0.title).tag($0) }
            }.labelsHidden()
                .help(L10n.tr("23.976, 29.97 and 59.94 fps match NTSC broadcast and most editing timelines"))
        }
    }

    static func metadataToggle(_ isOn: Binding<Bool>) -> some View {
        Toggle(L10n.tr("Include capture date, location and camera"), isOn: isOn).toggleStyle(.formCheckbox)
            .help(L10n.tr("The first frame’s capture time, the first GPS position and the camera, so Photos and Finder file the video where it was shot. MPEG-4 keeps the time and position only."))
    }
}

extension TimelapseSettings {
    /// The settings last used under `key`, so each kind of video keeps its own choices.
    static func remembered(_ key: String) -> TimelapseSettings? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(TimelapseSettings.self, from: $0) }
    }
    func remember(_ key: String) {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: key) }
    }
}
