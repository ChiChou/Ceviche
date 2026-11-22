import SwiftUI
import AppKit
import CevicheCore
import UniformTypeIdentifiers

/// Settings › Models: every Core ML model Ceviche can use, installed or not, with downloads from the model set this
/// build pins, removal, and adding from a file. Tools that find their model missing open it (`ModelPrompt`).
struct ModelManagerView: View {
    @ObservedObject private var library = ModelLibrary.shared
    @State private var importError: String?
    private var set: ModelSet { library.set }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("Depth, scene and sky masks, AI noise reduction and AI fill. Each keeps its own license."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !library.allowsDownloads {
                    HStack(spacing: 4) {
                        Text(L10n.tr("Download them from the release page and unpack them into the Models folder."))
                        if let url = set.releaseURL { Link(L10n.tr("Release page"), destination: url) }
                    }.font(.caption).foregroundStyle(.secondary)
                } else if !set.isPinned {
                    Label(L10n.tr("This build names no model set to download from. Models can still be added from files."), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
            }
            if let requested = library.requested, !library.isInstalled(requested) {
                Label(library.allowsDownloads ? L10n.tr("\(requested.feature) needs its model. Download it below, or add it from a file.") : L10n.tr("\(requested.feature) needs its model."), systemImage: "arrow.down.circle")
                    .font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            }
            VStack(spacing: 0) {
                ForEach(Array(BundledModel.allCases.enumerated()), id: \.element) { index, model in
                    ModelRow(model: model, library: library, highlighted: library.requested == model, remove: { remove(model) }, addFromFile: { addFromFile(model) })
                    if index < BundledModel.allCases.count - 1 { Rule() }
                }
            }
            .card()
            if let error = importError {
                Text(error).font(.caption).foregroundStyle(Theme.error).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                // The library folder, shown in Finder when clicked.
                Button((library.directory.path as NSString).abbreviatingWithTildeInPath) {
                    try? FileManager.default.createDirectory(at: library.directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.showInFinder([library.directory])
                }
                .buttonStyle(.link).font(.caption).lineLimit(1).truncationMode(.middle)
                .help(L10n.tr("Show in Finder"))
                Spacer(minLength: 12)
                if library.allowsDownloads {
                    Button(downloadAllTitle) { library.downloadAll() }
                        .buttonStyle(.secondaryAction)
                        .disabled(!set.isPinned || library.missing.isEmpty)
                }
            }
        }
        .padding(20).tint(Theme.controlAccent)
        .onAppear { library.rescan() }
        .onDisappear { library.requested = nil }
    }
    private func remove(_ model: BundledModel) {
        do { try library.remove(model) } catch { importError = error.localizedDescription }
    }
    private var downloadAllTitle: String {
        let bytes = library.missingBytes
        return bytes > 0 ? L10n.tr("Download All (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))") : L10n.tr("Download All")
    }
    /// The file for one model, chosen from its row, so nothing is read into the file's name.
    private func addFromFile(_ model: BundledModel) {
        let panel = NSOpenPanel()
        panel.message = L10n.tr("Choose the \(model.feature) model: a release .aar, an .mlpackage, an .mlmodel or a compiled .mlmodelc.")
        panel.prompt = L10n.tr("Install")
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.package, .directory, UTType(filenameExtension: "aar") ?? .data, UTType(filenameExtension: "mlmodel") ?? .data, UTType(filenameExtension: "mlpackage") ?? .package, UTType(filenameExtension: "mlmodelc") ?? .directory]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importError = nil
        Task {
            do { try await library.install(model, from: url) }
            catch { importError = error.localizedDescription }
        }
    }
}

private struct ModelRow: View {
    let model: BundledModel
    @ObservedObject var library: ModelLibrary
    let highlighted: Bool
    let remove: () -> Void
    let addFromFile: () -> Void
    @Environment(\.openWindow) private var openWindow
    private var asset: ModelSet.Asset? { library.set.asset(model) }
    /// The weights this set offers the model with, FP16 first; two when users can choose.
    private var variants: [ModelSet.Variant] { library.set.variants(model) }
    private func size(_ variant: ModelSet.Variant) -> String {
        library.set.asset(model, variant).map { ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file) } ?? ""
    }

    var body: some View {
        // A plain list: the feature, then where the model comes from; the button beside it says whether it is installed.
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.feature).font(.system(size: 13, weight: .medium)).foregroundStyle(highlighted ? Theme.accent : .primary)
                HStack(spacing: 4) {
                    Link(model.upstream, destination: model.sourceURL)
                        .buttonStyle(.plain).foregroundStyle(.secondary).underline(false).help(model.sourceURL.absoluteString)
                    Text(verbatim: "-").foregroundStyle(.secondary)
                    Button(model.license) {
                        LicenseFocus.shared.id = LicenseFocus.creditID(model)
                        openWindow(id: LicensesView.windowID)
                    }
                    .buttonStyle(.link).help(L10n.tr("Open Source Licenses"))
                    if let shown = library.set.asset(model, library.variant(model) ?? .fp16) ?? asset, !(model.isBuiltIn && !library.isInstalled(model)) {
                        Text(verbatim: "- " + ByteCountFormatter.string(fromByteCount: shown.bytes, countStyle: .file)).foregroundStyle(.secondary)
                    }
                }.font(.caption).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                status
            }
            Spacer(minLength: 12)
            actions.buttonStyle(.secondaryAction)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(highlighted ? Theme.accent.opacity(0.08) : .clear)
    }
    @ViewBuilder private var status: some View {
        switch library.status(model) {
        case .notInstalled:
            if model.isBuiltIn { Text(L10n.tr("Built in")).font(.caption).foregroundStyle(.secondary) }
        case .installed(let record):
            switch (record.source, library.matchesPin(model)) {
            // The button beside it already says whether it is installed; only the model set it came from, and which
            // weights when there is a choice, are worth a line.
            case (.download, _), (.file, true):
                if let tag = record.tag {
                    Text(verbatim: [tag, variants.count > 1 ? library.variant(model)?.title : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            case (.file, false):
                Label(L10n.tr("Installed from a file; not the copy this build was made with"), systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(Theme.warning)
            case (.file, nil):
                EmptyView()
            }
        case .transferring(let transfer):
            // The ring beside it shows the progress; this line gives the numbers.
            Text(transferText(transfer)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        case .failed(let message):
            Label(message, systemImage: "xmark.circle").font(.caption).foregroundStyle(Theme.error).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func transferText(_ transfer: ModelLibrary.Transfer) -> String {
        switch transfer {
        case .connecting: return L10n.tr("Connecting…")
        case .downloading(let received, let expected):
            let got = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
            guard let expected, expected > 0 else { return got }
            return L10n.tr("\(got) of \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))")
        case .installing: return L10n.tr("Installing…")
        }
    }
    @ViewBuilder private var actions: some View {
        switch library.status(model) {
        case .transferring(let transfer):
            DownloadRing(fraction: transfer.fraction, installing: transfer == .installing) { library.cancel(model) }
                .accessibilityLabel(L10n.tr("Stop downloading \(model.feature)"))
        case .installed:
            HStack(spacing: 6) {
                // The other weights, downloaded in place of these: how users try FP16 and INT8 on their own photos.
                if library.allowsDownloads, variants.count > 1, let current = library.variant(model), let other = variants.first(where: { $0 != current }) {
                    RowIcon(symbol: "arrow.triangle.2.circlepath", tint: .secondary) { library.download(model, variant: other) }
                        .help(L10n.tr("Switch to \(other.title) (\(size(other)))"))
                        .accessibilityLabel(L10n.tr("Switch \(model.feature) to \(other.title)"))
                }
                Button(L10n.tr("Remove"), action: remove).accessibilityLabel(L10n.tr("Remove \(model.feature)"))
            }
        case .notInstalled where model.isBuiltIn:
            EmptyView()
        case .notInstalled, .failed:
            // Icons, with Download outermost: the ring takes its place while the model downloads.
            HStack(spacing: 2) {
                RowIcon(symbol: "folder", tint: .secondary, action: addFromFile)
                    .help(library.allowsDownloads ? L10n.tr("Install this model from a file on this Mac instead of downloading it.") : L10n.tr("From File…"))
                    .accessibilityLabel(L10n.tr("From File…"))
                if library.allowsDownloads, variants.count > 1 {
                    // FP16 or INT8, the user's choice; the size of each says what INT8 saves.
                    Menu {
                        ForEach(variants, id: \.self) { variant in
                            Button { library.download(model, variant: variant) } label: { Text(verbatim: "\(variant.title) - \(size(variant))") }
                        }
                    } label: {
                        Image(systemName: "arrow.down.circle").font(.system(size: 17, weight: .regular)).foregroundStyle(Theme.controlAccent)
                            .frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().nativeMenuItems()
                    .help(L10n.tr("Download"))
                    .accessibilityLabel(L10n.tr("Download \(model.feature)"))
                } else if library.allowsDownloads {
                    RowIcon(symbol: "arrow.down.circle", tint: Theme.controlAccent) { library.download(model) }
                        .disabled(asset == nil)
                        .help(asset == nil ? L10n.tr("This build names no model set to download from. Models can still be added from files.") : L10n.tr("Download"))
                        .accessibilityLabel(L10n.tr("Download \(model.feature)"))
                }
            }
        }
    }
}

/// An icon-only row action, the size of `DownloadRing` so one can replace the other in place.
private struct RowIcon: View {
    let symbol: String
    let tint: Color
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .regular))
                .foregroundStyle(isEnabled ? tint : Color.secondary.opacity(0.4))
                .frame(width: 28, height: 28)
                .background(hovering && isEnabled ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A download's progress as a ring around a stop button, as in the App Store: clicking it aborts the download. Before
/// the size is known the ring spins; while the model is compiled it only spins, since that step can't be stopped.
private struct DownloadRing: View {
    let fraction: Double?
    let installing: Bool
    let stop: () -> Void
    @State private var spin = false
    private let size: CGFloat = 22
    private let line: CGFloat = 2.5

    var body: some View {
        if installing {
            ProgressView().controlSize(.small).frame(width: size, height: size).help(L10n.tr("Installing…"))
        } else {
            Button(action: stop) {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.25), lineWidth: line)
                    Circle().trim(from: 0, to: fraction.map { max(0.02, $0) } ?? 0.25)
                        .stroke(Theme.controlAccent, style: StrokeStyle(lineWidth: line, lineCap: .round))
                        .rotationEffect(.degrees(-90 + (fraction == nil && spin ? 360 : 0)))
                        .animation(fraction == nil ? .linear(duration: 1).repeatForever(autoreverses: false) : .easeOut(duration: 0.2), value: spin)
                        .animation(.easeOut(duration: 0.2), value: fraction)
                    RoundedRectangle(cornerRadius: 1.5).fill(Theme.controlAccent).frame(width: 7, height: 7)
                }
                .frame(width: size, height: size).padding(3).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.tr("Stop Download"))
            .onAppear { spin = true }
        }
    }
}

/// What a tool shows in place of a control whose model is not installed: the reason and a button to Settings › Models.
struct ModelPrompt: View {
    let model: BundledModel
    var compact = false
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        if compact {
            Button(L10n.tr("Get Model…")) { ModelPrompt.open(model, openSettings) }.buttonStyle(.secondaryAction).controlSize(.small)
                .help(L10n.tr("\(model.feature) needs a model that is not installed. Install it in Settings › Models."))
        } else {
            HStack(spacing: 8) {
                Label(L10n.tr("\(model.feature) needs a model that is not installed."), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(L10n.tr("Get Model…")) { ModelPrompt.open(model, openSettings) }.buttonStyle(.secondaryAction).controlSize(.small)
            }
        }
    }
    /// Opens Settings on the Models tab with `model` highlighted.
    @MainActor static func open(_ model: BundledModel?, _ openSettings: OpenSettingsAction) {
        ModelLibrary.shared.requested = model
        UserDefaults.standard.set(PreferencesTab.models.rawValue, forKey: PreferencesTab.key)
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }
}
