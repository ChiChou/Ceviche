import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CevicheCore

/// Print Proof in Develop: the open photo as a printer and paper would show it, while it is edited. The proof is a
/// view of the photo, not an edit: nothing of it is saved with the photo, and exports are unchanged unless they are
/// asked for the printer's profile.
@MainActor
final class PrintProofState: ObservableObject {
    /// What a render needs, taken on the main actor and used off it.
    struct Active: @unchecked Sendable {
        let profile: PrintProfile
        let settings: PrintProofSettings
    }

    @Published var on = false { didSet { if on != oldValue { if on { start() } else { previewWarning = nil }; changed() } } }
    /// Printer profiles installed on this Mac and the ones kept in Ceviche's own folder, by path.
    @Published private(set) var profiles: [URL] = []
    @Published var selected = "" { didSet { if selected != oldValue { preferences.set(selected, forKey: "printProofProfile"); load() } } }
    @Published var settings = PrintProofSettings() { didSet { if settings != oldValue { remember(); if on { changed() } } } }
    @Published private(set) var profile: PrintProfile?
    /// The share of the photo the print can't hold, as last rendered.
    @Published var coverage: (colour: Double, shadow: Double)?
    @Published private(set) var message: String?
    /// Renders the photo again: the editor sets it.
    var changed: () -> Void = {}
    private var started = false
    private var observer: NSObjectProtocol?
    private let preferences = UserDefaults.standard
    private nonisolated static let context = CIContext(options: [.cacheIntermediates: false])

    init() {
        if let intent = preferences.string(forKey: "printProofIntent").flatMap(PrintIntent.init) { settings.intent = intent }
        if let compensation = preferences.object(forKey: "printProofBlackPoint") as? Bool { settings.blackPointCompensation = compensation }
        if let paper = preferences.object(forKey: "printProofPaper") as? Bool { settings.simulatePaper = paper }
        observer = NotificationCenter.default.addObserver(forName: Self.profilesChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    enum Warning { case gamut, shadow }
    /// Hover is transient; clicking pins/unpins the overlay and ends the hover preview until the next entry.
    @Published var previewWarning: Warning? { didSet { if previewWarning != oldValue, on { changed() } } }
    var displaySettings: PrintProofSettings {
        var result = settings
        if previewWarning == .gamut { result.gamutWarning = true }
        if previewWarning == .shadow { result.shadowWarning = true }
        return result
    }
    func toggle(_ warning: Warning) {
        previewWarning = nil
        if warning == .gamut { settings.gamutWarning.toggle() } else { settings.shadowWarning.toggle() }
    }
    var active: Active? { on ? profile.map { Active(profile: $0, settings: displaySettings) } : nil }
    /// Where profiles chosen from files are kept: copies, so moving or deleting the file they came from changes
    /// nothing here. On this Mac only, like the printers they describe.
    nonisolated static var folder: URL { LookLibrary.localRoot.appendingPathComponent("Printer Profiles", isDirectory: true) }
    /// Posted when the folder's profiles change, here or in Settings.
    static let profilesChanged = Notification.Name("CevichePrinterProfilesChanged")
    nonisolated static func kept() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files.filter { ["icc", "icm"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    /// Copies a profile into the folder and answers the copy; a file already there with the same contents is used as it is.
    private nonisolated static func keep(_ url: URL) throws -> URL {
        let folder = folder.standardizedFileURL
        if url.standardizedFileURL.deletingLastPathComponent() == folder { return url }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try Data(contentsOf: url), base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var target = folder.appendingPathComponent(url.lastPathComponent), copy = 2
        while FileManager.default.fileExists(atPath: target.path) {
            if (try? Data(contentsOf: target)) == data { return target }
            target = folder.appendingPathComponent("\(base) \(copy).\(ext)"); copy += 1
        }
        try data.write(to: target, options: .atomic)
        return target
    }
    /// The lists again, after a profile was added or deleted elsewhere; a selected profile that is gone gives way
    /// to the first one.
    private func reload() {
        guard started else { return }
        Task {
            let (installed, kept) = await Task.detached(priority: .userInitiated) { (PrintProfile.installed(), Self.kept()) }.value
            profiles = installed + kept
            if !profiles.contains(where: { $0.path == selected }) { selected = profiles.first?.path ?? "" }
        }
    }
    /// The proof's printer profile as a colour space to export in, when it is an RGB one (an inkjet's): what was
    /// proofed is then what the file holds. A press profile's four inks only proof.
    static func exportProfile(_ preferences: UserDefaults = .standard) -> ColorProfile? {
        guard let path = preferences.string(forKey: "printProofProfile"), !path.isEmpty else { return nil }
        if let cached = exportCache, cached.path == path { return cached.profile }
        let url = URL(fileURLWithPath: path)
        var result: ColorProfile?
        if let data = try? Data(contentsOf: url), data.count >= 20, String(decoding: data[12..<16], as: UTF8.self) == "prtr", String(decoding: data[16..<20], as: UTF8.self) == "RGB " {
            var profile = ColorProfile(); profile.preset = .custom; profile.iccData = data; profile.name = url.deletingPathExtension().lastPathComponent
            if (try? profile.colorSpace()) != nil { result = profile }
        }
        exportCache = (path, result)
        return result
    }
    private static var exportCache: (path: String, profile: ColorProfile?)?

    func name(_ path: String) -> String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }

    private func remember() {
        preferences.set(settings.intent.rawValue, forKey: "printProofIntent")
        preferences.set(settings.blackPointCompensation, forKey: "printProofBlackPoint")
        preferences.set(settings.simulatePaper, forKey: "printProofPaper")
    }

    private func start() {
        guard !started else { return }
        started = true
        let remembered = preferences.string(forKey: "printProofProfile") ?? ""
        Task {
            let (installed, kept) = await Task.detached(priority: .userInitiated) { (PrintProfile.installed(), Self.kept()) }.value
            profiles = installed + kept
            selected = profiles.contains { $0.path == remembered } ? remembered : profiles.first?.path ?? ""
        }
    }

    /// Copies a profile from a file into the folder and selects it; a file that isn't a printer profile is refused
    /// and left out.
    func choose() {
        Task {
            guard let url = await FileChooser.openOne(FileOpenRequest(types: UTType.iccProfiles, message: L10n.tr("Printer ICC profile"))) else { return }
            let read = await Task.detached(priority: .userInitiated) { Result { () -> URL in _ = try PrintProfile(url: url); return try Self.keep(url) } }.value
            switch read {
            case .failure(let error): refuse(url, error)
            case .success(let copy):
                if !profiles.contains(copy) { profiles.append(copy) }
                selected = copy.path
                NotificationCenter.default.post(name: Self.profilesChanged, object: nil)
            }
        }
    }

    /// Says why a chosen file was left out, for a while: the proof itself carries on with the profile it had.
    private func refuse(_ url: URL, _ error: Error) {
        // A profile ColorSync can't drive is named, as the other refusals are.
        let shown: Error = if case PrintProofError.failed = error { PrintProofError.unreadable(url.lastPathComponent) } else { error }
        let text = shown.localizedDescription
        message = text
        Task { try? await Task.sleep(for: .seconds(8)); if message == text { message = nil } }
    }

    private func load() {
        profile = nil; coverage = nil; message = nil
        guard !selected.isEmpty else { changed(); return }
        let url = URL(fileURLWithPath: selected)
        Task {
            let read = await Task.detached(priority: .userInitiated) { Result { try PrintProfile(url: url) } }.value
            guard selected == url.path else { return }
            switch read {
            case .success(let loaded): profile = loaded
            case .failure(let error): message = error.localizedDescription
            }
            changed()
        }
    }

    /// `image`, developed in ProPhoto, as the print would show it, and how much of it the print can't hold.
    nonisolated static func render(_ image: CGImage, _ proof: Active, measuring: Bool) -> (image: CGImage?, coverage: (colour: Double, shadow: Double)?) {
        let proofed = try? proof.profile.proof(CIImage(cgImage: image), settings: proof.settings)
        let shown = proofed.flatMap { context.createCGImage($0, from: $0.extent, format: .RGBA16, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!) }
        return (shown, measuring ? try? proof.profile.coverage(of: image) : nil)
    }
}

/// The strip above the photo while it is proofed: the printer profile, how colours are brought into the print, and
/// what the print can't hold.
struct PrintProofBar: View {
    @ObservedObject var proof: PrintProofState
    private static let other = "\u{0}other", manage = "\u{0}manage"
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                ToolOptionsBar { profilePicker; renderingControls; Spacer(minLength: 0); warningControls }
                VStack(spacing: 0) {
                    ToolOptionsBar { profilePicker; renderingControls; Spacer(minLength: 0) }
                    ToolOptionsBar { warningControls; Spacer(minLength: 0) }
                }
                VStack(spacing: 0) {
                    ToolOptionsBar { profilePicker; Spacer(minLength: 0) }
                    ToolOptionsBar { renderingControls; Spacer(minLength: 0) }
                    ToolOptionsBar { warningControls; Spacer(minLength: 0) }
                }
            }
            if let message = proof.message {
                Text(message).font(.caption).foregroundStyle(Theme.warning).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 4)
            }
        }
        .background(Theme.statusBar).tint(Theme.controlAccent)
        .onDisappear { proof.previewWarning = nil }
    }

    private var profilePicker: some View {
        HStack(spacing: 8) {
            Text(L10n.tr("Proof")).foregroundStyle(.secondary)
            FormSelect(L10n.tr("Printer profile"), selection: Binding(get: { proof.selected }, set: { choice in
                if choice == Self.other { proof.choose() } else if choice == Self.manage { manageProfiles() } else { proof.selected = choice }
            }), valueLabel: proof.selected.isEmpty ? L10n.tr("Choose Profile…") : proof.name(proof.selected)) {
                ForEach(proof.profiles.map(\.path), id: \.self) { Text(proof.name($0)).tag($0) }
                if !proof.profiles.isEmpty { Divider() }
                Text(L10n.tr("Other…", context: "printer profile")).tag(Self.other)
                Text(L10n.tr("Manage Printer Profiles…")).tag(Self.manage)
            }
            .frame(minWidth: 120, maxWidth: 220)
            .help(L10n.tr("The ICC profile for the printer and paper. Profiles installed in ColorSync are listed; Other… copies one into Ceviche’s Printer Profiles folder."))
        }
    }
    private var renderingControls: some View {
        HStack(spacing: 12) {
            FormSegments(title: L10n.tr("Intent"), selection: $proof.settings.intent, options: PrintIntent.allCases, label: { $0.title }).labelsHidden().fixedSize()
                .help(L10n.tr("Perceptual brings the whole range into the print, keeping how colours relate. Relative keeps printable colours as they are and clips the rest."))
            Toggle(L10n.tr("Black Point"), isOn: $proof.settings.blackPointCompensation).toggleStyle(.formCheckbox).fixedSize()
                .disabled(proof.settings.intent != .relative)
                .help(L10n.tr("Black point compensation: maps the photo’s black onto the print’s, keeping shadow detail"))
            Toggle(L10n.tr("Paper"), isOn: $proof.settings.simulatePaper).toggleStyle(.formCheckbox).fixedSize()
                .help(L10n.tr("Shows the paper’s white and the ink’s black. The proof looks dimmer than the screen: paper isn’t as white."))
        }.disabled(proof.profile == nil)
    }
    private var warningControls: some View {
        HStack(spacing: 6) {
            warning(.gamut, title: L10n.tr("Gamut"), share: proof.coverage?.colour,
                    colour: proof.settings.gamutWarningColor, selected: proof.settings.gamutWarning,
                    help: L10n.tr("Show out-of-gamut colors"))
            warning(.shadow, title: L10n.tr("Below black"), share: proof.coverage?.shadow,
                    colour: proof.settings.shadowWarningColor, selected: proof.settings.shadowWarning,
                    help: L10n.tr("Show shadows below print black"))
        }
    }
    /// Settings › Profiles, on the printer profiles.
    private func manageProfiles() {
        UserDefaults.standard.set(PreferencesTab.profiles.rawValue, forKey: PreferencesTab.key)
        UserDefaults.standard.set(ProfilePreferences.Kind.printer.rawValue, forKey: ProfilePreferences.kindKey)
        openSettings()
    }

    private func warning(_ kind: PrintProofState.Warning, title: String, share: Double?, colour: SIMD3<Double>, selected: Bool, help: String) -> some View {
        let active = selected || proof.previewWarning == kind
        let value = share.map { String(format: "%.1f %%", locale: L10n.locale, $0 * 100) } ?? "—"
        return Button { proof.toggle(kind) } label: {
            HStack(spacing: 5) {
                Circle().fill(color(colour)).frame(width: 7, height: 7)
                Text(title)
                Text(value).monospacedDigit()
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Theme.ink.opacity(active ? 0.16 : 0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay { RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.ink.opacity(active ? 0.55 : 0.15), lineWidth: 1) }
        }
        .buttonStyle(.plain).fixedSize().disabled(proof.profile == nil)
        .help(proof.profile == nil ? L10n.tr("Choose a printer profile") : help)
        .accessibilityLabel(help).accessibilityValue(value)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .onHover { inside in
            if inside, proof.profile != nil { proof.previewWarning = kind }
            else if proof.previewWarning == kind { proof.previewWarning = nil }
        }
    }

    private func color(_ value: SIMD3<Double>) -> Color {
        Color(.sRGBLinear, red: value.x, green: value.y, blue: value.z)
    }
}
