import SwiftUI
import AppKit
import CevicheCore

/// The chart profiles in the library: what Develop's Camera picker offers and Settings › Profiles manages.
@MainActor
final class ChartProfileStore: ObservableObject {
    static let shared = ChartProfileStore()
    @Published private(set) var profiles: [CameraProfileEntry] = []
    private init() { refresh() }

    /// Indexes the profile folders again, as at launch, and keeps the chart profiles.
    func refresh() {
        Task {
            profiles = await Task.detached(priority: .userInitiated) {
                CameraProfileLibrary.shared.reload(folders: LookLibrary.profileFolders).filter { $0.light != nil }
            }.value
        }
    }

    /// The profiles made with this camera, by name.
    func profiles(camera: String) -> [CameraProfileEntry] {
        let key = CameraProfileResolver.normalized(camera)
        return profiles.filter { $0.camera.isEmpty || CameraProfileResolver.normalized($0.camera) == key }
    }

    func delete(_ entry: CameraProfileEntry) throws {
        try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
        refresh()
    }

    /// The name is in the file, so the file is written again under the new name.
    func rename(_ entry: CameraProfileEntry, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != entry.name else { return }
        var profile = try CameraProfile(dcp: entry.url)
        profile.name = name
        let url = Self.file(named: name, in: entry.url.deletingLastPathComponent())
        try profile.calibrationFile().write(to: url, options: .atomic)
        try FileManager.default.removeItem(at: entry.url)
        refresh()
    }

    /// Writes a new profile into the library's Camera Profiles › Chart Profiles, and reads it back as a photo will
    /// carry it.
    @discardableResult
    func save(_ profile: CameraProfile, library: LookLibrary) throws -> CameraProfile {
        let folder = try library.prepare(.profiles).appendingPathComponent("Chart Profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Two profiles of one name can't be told apart in a picker: a second one is numbered.
        var profile = profile
        let taken = Set(profiles.map(\.name)), base = profile.name
        var copy = 2
        while taken.contains(profile.name) { profile.name = "\(base) \(copy)"; copy += 1 }
        let url = Self.file(named: profile.name, in: folder)
        try profile.calibrationFile().write(to: url, options: .atomic)
        refresh()
        return try CameraProfile(dcp: url)
    }

    private static func file(named name: String, in folder: URL) -> URL {
        let base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var url = folder.appendingPathComponent(base + ".dcp"), copy = 2
        while FileManager.default.fileExists(atPath: url.path) { url = folder.appendingPathComponent("\(base) \(copy).dcp"); copy += 1 }
        return url
    }

    static func light(_ entry: CameraProfileEntry) -> String { L10n.tr("\(Int(((entry.light ?? 0) / 50).rounded()) * 50) K") }
}

/// Develop's Camera row: the camera's own colour, or a chart profile made with this camera in light near the photo's
/// white balance. Shown for a RAW photo once there is a chart profile to choose.
struct ChartProfilePicker: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var store = ChartProfileStore.shared
    @Environment(\.openSettings) private var openSettings

    private var applied: CameraProfile? { model.adjustments.cameraProfile.flatMap { $0.hasCalibration ? $0 : nil } }
    /// Profiles for this camera whose light suits the photo, and the one on the photo whatever its light.
    private var options: [CameraProfileEntry] {
        guard let info = model.info else { return [] }
        let temperature = model.adjustments.effective(defaults: info.defaults).temperature
        return store.profiles(camera: info.camera).filter { entry in
            entry.name == applied?.name || abs(1e6 / (entry.light ?? temperature) - 1e6 / temperature) <= CameraProfile.calibrationReach
        }
    }
    private var visible: Bool {
        guard let info = model.info, info.isRAW else { return false }
        // A look profile from a preset is not a calibration: the row would replace it.
        if let profile = model.adjustments.cameraProfile, !profile.hasCalibration { return false }
        return applied != nil || !store.profiles(camera: info.camera).isEmpty
    }

    var body: some View {
        if visible {
            let options = options
            HStack(spacing: 8) {
                Text(L10n.tr("Camera Profile")).foregroundStyle(.secondary)
                PanelPicker(title: L10n.tr("Camera profile"), selection: Binding(get: { options.first { $0.name == applied?.name }?.path ?? "" }, set: choose),
                            options: [""] + options.map(\.path),
                            label: { path in path.isEmpty ? (applied.map(\.name) ?? L10n.tr("Built-in")) : options.first { $0.path == path }.map { $0.name } ?? "" })
                    .controlSize(.small)
                    .help(options.isEmpty ? L10n.tr("No chart profile was made in light near this photo’s white balance") : L10n.tr("The camera’s own colour, or a chart profile made in light near this photo’s white balance"))
                Spacer()
                Menu {
                    if applied != nil { Button(L10n.tr("Remove Chart Profile")) { model.edit { $0.cameraProfile = nil } } }
                    Button(L10n.tr("Manage Chart Profiles…")) {
                        UserDefaults.standard.set(PreferencesTab.profiles.rawValue, forKey: PreferencesTab.key)
                        UserDefaults.standard.set(ProfilePreferences.Kind.camera.rawValue, forKey: ProfilePreferences.kindKey)
                        openSettings()
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 24, height: 22)
                        .background(Theme.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.Radius.control)).contentShape(Rectangle())
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.tr("Chart profile options"))
            }
        }
    }

    private func choose(_ path: String) {
        guard !path.isEmpty else { model.edit { $0.cameraProfile = nil }; return }
        guard let profile = try? CameraProfile(dcp: URL(fileURLWithPath: path)) else { return }
        model.edit { $0.cameraProfile = profile }
    }
}

/// Settings › Profiles: the two kinds Ceviche keeps, each in its own list. Camera profiles are made from a chart and
/// change how a RAW photo is developed; printer profiles are what Print Proof shows the photo through.
struct ProfilePreferences: View {
    enum Kind: String, CaseIterable { case camera, printer }
    static let kindKey = "preferencesProfileKind"
    @AppStorage(ProfilePreferences.kindKey) private var kind = Kind.camera.rawValue
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $kind) {
                Text(L10n.tr("Camera")).tag(Kind.camera.rawValue)
                Text(L10n.tr("Printer")).tag(Kind.printer.rawValue)
            }.pickerStyle(.segmented).labelsHidden().fixedSize().padding(.vertical, 10)
            Rule()
            if kind == Kind.printer.rawValue { PrinterProfilePreferences() } else { ChartProfilePreferences() }
        }
    }
}

/// The printer profiles in Ceviche's own folder, to reveal or delete. The ones installed in ColorSync are macOS's.
struct PrinterProfilePreferences: View {
    @State private var files: [URL] = []
    @State private var selection: URL?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if files.isEmpty {
                ContentUnavailableView(L10n.tr("No Printer Profiles"), systemImage: "printer",
                                       description: Text(L10n.tr("In Print Proof, choose Other… in the profile list to add a printer’s ICC profile.")))
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                List(files, id: \.self, selection: $selection) { url in
                    HStack(spacing: 10) {
                        Text(url.deletingPathExtension().lastPathComponent).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(Self.inks(url)).foregroundStyle(.secondary).frame(width: 62, alignment: .trailing)
                    }
                }.frame(minHeight: 220)
            }
            Rule()
            HStack(spacing: 10) {
                if let error { Text(error).font(.callout).foregroundStyle(Theme.error).lineLimit(2) }
                Spacer()
                Button(L10n.tr("Show in Finder")) { if let selection { NSWorkspace.shared.showInFinder([selection]) } }.disabled(selection == nil)
                Button(L10n.tr("Delete"), role: .destructive) { delete() }.disabled(selection == nil)
            }.padding(12)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: PrintProofState.profilesChanged)) { _ in refresh() }
    }
    private func refresh() { files = PrintProofState.kept(); if let selection, !files.contains(selection) { self.selection = nil } }
    /// RGB for an inkjet's profile, CMYK for a press's: the colour space in the file's header.
    private static func inks(_ url: URL) -> String {
        guard let header = try? FileHandle(forReadingFrom: url).read(upToCount: 20), header.count == 20 else { return "" }
        return String(decoding: header[16..<20], as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
    private func delete() {
        guard let selection else { return }
        do {
            try FileManager.default.trashItem(at: selection, resultingItemURL: nil)
            error = nil
            NotificationCenter.default.post(name: PrintProofState.profilesChanged, object: nil)
        } catch let failure { error = failure.localizedDescription }
    }
}

/// The chart profiles in the library, to rename, reveal or delete.
struct ChartProfilePreferences: View {
    @ObservedObject private var store = ChartProfileStore.shared
    @State private var selection: String?
    @State private var names: [String: String] = [:]
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.profiles.isEmpty {
                ContentUnavailableView(L10n.tr("No Chart Profiles"), systemImage: "square.grid.3x2",
                                       description: Text(L10n.tr("Select a RAW photo of a 24-patch colour chart and choose Tools › Chart Profile…")))
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                List(store.profiles, id: \.path, selection: $selection) { entry in
                    HStack(spacing: 10) {
                        TextField(L10n.tr("Name"), text: Binding(get: { names[entry.path] ?? entry.name }, set: { names[entry.path] = $0 }))
                            .textFieldStyle(.plain)
                            .onSubmit { rename(entry) }
                        Spacer(minLength: 8)
                        Text(entry.camera).foregroundStyle(.secondary).lineLimit(1)
                        Text(ChartProfileStore.light(entry)).foregroundStyle(.secondary).monospacedDigit().frame(width: 62, alignment: .trailing)
                    }
                }
                .frame(minHeight: 220)
            }
            Rule()
            HStack(spacing: 10) {
                if let error { Text(error).font(.callout).foregroundStyle(Theme.error).lineLimit(2) }
                Spacer()
                Button(L10n.tr("Show in Finder")) { if let entry = selected { NSWorkspace.shared.showInFinder([entry.url]) } }.disabled(selected == nil)
                Button(L10n.tr("Delete"), role: .destructive) { delete() }.disabled(selected == nil)
            }.padding(12)
        }
        .onAppear { store.refresh() }
    }

    private var selected: CameraProfileEntry? { store.profiles.first { $0.path == selection } }
    private func rename(_ entry: CameraProfileEntry) {
        do { try store.rename(entry, to: names[entry.path] ?? entry.name); error = nil } catch let failure { error = failure.localizedDescription }
        names[entry.path] = nil
    }
    private func delete() {
        guard let entry = selected else { return }
        do { try store.delete(entry); selection = nil; error = nil } catch let failure { error = failure.localizedDescription }
    }
}
