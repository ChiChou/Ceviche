import Foundation
import SwiftUI
import CevicheCore

struct PreferencesView: View {
    @ObservedObject var mcp: MCPController
    @AppStorage(LanguageChoice.key) private var language = LanguageChoice.system.rawValue
    /// The export dialog's Manage Watermarks… opens Settings on the Watermarks tab.
    @AppStorage(PreferencesTab.key) private var tab = PreferencesTab.general.rawValue
    var body: some View {
        TabView(selection: $tab) {
            Tab(L10n.tr("General"), systemImage: "gearshape", value: PreferencesTab.general.rawValue) { GeneralPreferences() }
            Tab(L10n.tr("Watermarks"), systemImage: "signature", value: PreferencesTab.watermarks.rawValue) { WatermarkPreferences() }
            Tab(L10n.tr("ID Photo"), systemImage: "person.text.rectangle", value: PreferencesTab.idPhoto.rawValue) { IDPhotoTemplatePreferences() }
            Tab(L10n.tr("Profiles"), systemImage: "square.grid.3x2", value: PreferencesTab.profiles.rawValue) { ProfilePreferences() }
            Tab(L10n.tr("Models"), systemImage: "cpu", value: PreferencesTab.models.rawValue) { ModelManagerView() }
            Tab(L10n.tr("MCP"), systemImage: "point.3.connected.trianglepath.dotted", value: PreferencesTab.mcp.rawValue) { MCPPreferences(mcp: mcp) }
        }
        // The model list needs the room for its names, licenses and buttons.
        .frame(width: tab == PreferencesTab.models.rawValue ? 620 : 480)
        .id(language)
    }
}

private struct GeneralPreferences: View {
    @AppStorage("thumbnailBudgetMB") private var thumbnailBudgetMB = 0
    @AppStorage(CatalogPlaceNamer.enabledKey) private var lookUpPlaces = true
    @AppStorage(AppearanceChoice.key) private var appearance = AppearanceChoice.dark.rawValue
    @AppStorage(AccentChoice.key) private var accent = AccentChoice.neutral.rawValue
    @AppStorage(LanguageChoice.key) private var language = LanguageChoice.system.rawValue
    /// The decoded RAWs kept on disk; nil while measuring.
    @State private var cache: Int64?
    var body: some View {
        Form {
            Section(L10n.tr("Appearance")) {
                LabeledContent(L10n.tr("Appearance")) {
                    FormSegments(title: L10n.tr("Appearance"), selection: $appearance,
                                 options: AppearanceChoice.allCases.map(\.rawValue),
                                 label: { AppearanceChoice(rawValue: $0)?.name ?? $0 }).fixedSize()
                }
                LabeledContent(L10n.tr("Accent color")) {
                    HStack(spacing: 8) {
                        ForEach(AccentChoice.allCases) { AccentSwatch(choice: $0, selected: accent == $0.rawValue) { accent = $0.rawValue } }
                    }
                }
            }
            Section(L10n.tr("Language")) {
                Picker(L10n.tr("Language"), selection: Binding(
                    get: { language },
                    set: { LanguageChoice.current = LanguageChoice(rawValue: $0) ?? .system }
                )) {
                    ForEach(LanguageChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice.rawValue)
                    }
                }
            }
            Section {
                LabeledContent(L10n.tr("Cache")) {
                    HStack {
                        Text(cache.map { let f = ByteCountFormatter(); f.countStyle = .file; f.allowsNonnumericFormatting = false; return f.string(fromByteCount: $0) } ?? "…").monospacedDigit().foregroundStyle(.secondary)
                        Button(L10n.tr("Clear Cache")) { Task { cache = await StorageUsage.clearCache() } }.disabled((cache ?? 0) == 0)
                    }
                }
                .task { cache = await StorageUsage.measure(catalog: nil).cache }
                Picker(L10n.tr("Keep thumbnails up to"), selection: $thumbnailBudgetMB) {
                    Text(L10n.tr("No limit")).tag(0)
                    ForEach([512, 1024, 2048, 5120, 10240], id: \.self) { Text($0 < 1024 ? "\($0) MB" : "\($0 / 1024) GB").tag($0) }
                }
            } header: {
                Text(L10n.tr("Library"))
            } footer: {
                Text(L10n.tr("The cache keeps decoded RAWs so recent photos open faster. Over the thumbnail limit, the thumbnails of photos you have not looked at for the longest are discarded and re-rendered when they next scroll into view.")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $lookUpPlaces) {
                    Text(L10n.tr("Name the places of photos with a location"))
                    Text(L10n.tr("Sends locations to Apple to find the city, region and country, so you can search and browse by place. Photos without a location taken around the same time get the same place."))
                }
            }
        }.formStyle(.grouped)
    }
}

private struct AccentSwatch: View {
    let choice: AccentChoice
    let selected: Bool
    let pick: (AccentChoice) -> Void
    var body: some View {
        Button { pick(choice) } label: {
            Circle().fill(choice.color).frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(Theme.ink.opacity(0.2)))
                .overlay { if selected { Circle().fill(Color(nsColor: choice.nsOnColor)).frame(width: 6, height: 6) } }
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? choice.color : .clear, lineWidth: 2))
                .contentShape(Circle())
        }.buttonStyle(.plain).help(choice.name).accessibilityLabel(choice.name).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct MCPPreferences: View {
    @ObservedObject var mcp: MCPController
    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { mcp.enabled }, set: mcp.setEnabled)) {
                    Text(L10n.tr("Allow AI clients to use Ceviche"))
                    Text(L10n.tr("Browse, tag and edit photos in the open catalog over MCP. Originals can never be deleted."))
                }
                LabeledContent(L10n.tr("Status")) { status }
            }
            Section(L10n.tr("Access")) {
                Picker(L10n.tr("Permissions"), selection: $mcp.readOnly) {
                    Text(L10n.tr("Read and edit")).tag(false)
                    Text(L10n.tr("Read only")).tag(true)
                }
                .onChange(of: mcp.readOnly) { _, _ in mcp.commitReadOnly() }
                TextField(L10n.tr("Largest preview"), value: $mcp.previewMaxEdge, format: .number.grouping(.never))
                    .onSubmit(mcp.commitPreviewMaxEdge)
                    .help(L10n.tr("Longest edge, in pixels, of previews sent to the client (64–4096)."))
            }.disabled(!mcp.enabled)
            Section {
                TextField(L10n.tr("Port"), value: $mcp.port, format: .number.grouping(.never))
                    .onSubmit(mcp.commitPort)
                LabeledContent(L10n.tr("Endpoint")) {
                    HStack {
                        Text(verbatim: mcp.endpoint).font(.callout.monospaced()).textSelection(.enabled)
                        Button { copy(mcp.endpoint) } label: { Label(L10n.tr("Copy URL"), systemImage: "doc.on.doc").labelStyle(.iconOnly) }
                            .buttonStyle(.borderless).help(L10n.tr("Copy URL"))
                    }
                }
                LabeledContent(L10n.tr("Token")) {
                    HStack {
                        Text(verbatim: mcp.token.map { String($0.prefix(8)) + "…" } ?? "-").font(.callout.monospaced())
                        Button { if let token = mcp.token { copy(token) } } label: { Label(L10n.tr("Copy Token"), systemImage: "doc.on.doc").labelStyle(.iconOnly) }
                            .buttonStyle(.borderless).help(L10n.tr("Copy Token")).disabled(mcp.token == nil)
                        Button(L10n.tr("Regenerate"), action: mcp.regenerateToken).controlSize(.small)
                            .help(L10n.tr("Clients using the old token are refused until they get the new one."))
                    }
                }
                LabeledContent(L10n.tr("stdio clients")) {
                    Button(L10n.tr("Copy Configuration")) { copy(stdioConfiguration) }
                        .help(L10n.tr("JSON for clients that launch the bundled ceviche-mcp helper"))
                }
                if let error = mcp.settingsError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.error).font(.callout)
                }
            } header: {
                Text(L10n.tr("Connection"))
            } footer: {
                Text(L10n.tr("Listens on this Mac only (127.0.0.1). HTTP clients send the token as a Bearer header. Press Return after changing a value.")).font(.caption).foregroundStyle(.secondary)
            }.disabled(!mcp.enabled)
        }.formStyle(.grouped)
    }
    @ViewBuilder private var status: some View {
        switch mcp.serverState {
        case .off: indicator(.secondary, L10n.tr("Off"))
        case .starting: HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(L10n.tr("Starting…")) }
        case .listening: indicator(.green, mcp.isWorking ? L10n.tr("Connected - working") : L10n.tr("Listening"))
        case .failed(let message): indicator(.red, message)
        }
    }
    private func indicator(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).lineLimit(2).textSelection(.enabled)
        }
    }
    private var stdioConfiguration: String {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ceviche-mcp").path
        return """
        {
          "mcpServers": {
            "ceviche": {
              "command": "\(helper)",
              "env": { "CEVICHE_MCP_PORT": "\(mcp.port)" }
            }
          }
        }
        """
    }
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}
