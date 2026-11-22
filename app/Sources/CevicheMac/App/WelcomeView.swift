import SwiftUI
import AVFoundation
import CevicheCore

/// The screen without an open catalog: one column with every way to start (import, a new catalog here or in iCloud,
/// open one, browse folders), the catalogs this Mac has opened, then iCloud catalogs it has not, and the models. A
/// photo bundled in `Welcome` fills the rest of a wide window; a narrow one, or a build without photos, shows the
/// column alone. Return opens the most recent catalog, or starts an import when there is none.
struct WelcomeView: View {
    @ObservedObject var model: CatalogModel
    @State private var namingCloudCatalog = false
    @State private var openingCloudCatalog = false
    @Environment(\.openSettings) private var openSettings
    private var recent: [CatalogReference] { model.recentCatalogs() }
    private var inCloud: [CloudCatalogListing] {
        BuildFeatures.iCloud ? model.cloudCatalogs.filter { listing in !model.knownCatalogs.contains { $0.id == listing.id } } : []
    }
    /// The bundle's `Welcome` photos; none in builds that ship without them.
    private static let photos = WelcomePhoto.all()
    /// A random one at launch, decoded once; the faint arrows at the photo's edges step through the rest.
    private static let firstIndex = Int.random(in: 0..<max(photos.count, 1))
    private static let firstPhoto = photos.indices.contains(firstIndex) ? photos[firstIndex].loaded() : nil
    @State private var photoIndex = Self.firstIndex
    @State private var photo = Self.firstPhoto
    /// Below this width the photo would be a sliver, so the column stands alone.
    private static let photoMinWidth: CGFloat = 820
    private var version: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
    var body: some View {
        GeometryReader { proxy in
            if let photo, proxy.size.width >= Self.photoMinWidth {
                HStack(spacing: 0) {
                    column.frame(width: min(max(proxy.size.width * 0.28, 320), 380)).background(Theme.panel)
                    Rectangle().fill(Theme.ink.opacity(0.08)).frame(width: 1)
                    ZStack {
                        Group {
                            if photo.isVideo { WelcomeVideo(url: photo.url) }
                            else { Color.clear.overlay(Image(nsImage: photo.image).resizable().scaledToFill()).clipped() }
                        }
                        .id(photo.file).transition(.opacity)
                    }
                    .overlay(alignment: .bottomTrailing) { credit(photo) }
                    .overlay { if Self.photos.count > 1 { HStack { step(-1); Spacer(); step(1) } } }
                }
            } else {
                column.frame(width: 340).frame(maxHeight: min(proxy.size.height - 48, 640))
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(Theme.hairline))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.canvas)
        .sheet(isPresented: $namingCloudCatalog) { NewCloudCatalogSheet(model: model) }
        .sheet(isPresented: $openingCloudCatalog) { CloudCatalogsSheet(model: model) }
        // A new Mac lists the catalogs its others made without being asked.
        .onAppear { model.lookForCloudCatalogs() }
    }

    /// A faint arrow at the photo's edge; it brightens only under the pointer.
    private func step(_ offset: Int) -> some View {
        WelcomeStepButton(systemImage: offset < 0 ? "chevron.left" : "chevron.right",
                          label: offset < 0 ? L10n.tr("Previous Photo") : L10n.tr("Next Photo")) { showPhoto(offset) }
    }
    private func showPhoto(_ offset: Int) {
        let count = Self.photos.count
        guard count > 1 else { return }
        photoIndex = (photoIndex + offset + count) % count
        let next = Self.photos[photoIndex].loaded()
        withAnimation(.easeInOut(duration: 0.35)) { photo = next }
    }

    /// The photo's title and, when the manifest names one, its author, who links to their page when it gives one. The
    /// line is translated whole and split around the name, so each language puts it where it belongs and only the name
    /// is a link.
    private func credit(_ photo: WelcomePhoto) -> some View {
        let marker = "\u{FFFC}"
        let parts = photo.author == nil ? [photo.title] : L10n.tr("\(photo.title) by \(marker)").components(separatedBy: marker)
        return HStack(spacing: 0) {
            Text(parts.first ?? "")
            if let author = photo.author {
                if let link = photo.link {
                    Link(destination: link) { Text(author).underline() }
                        .foregroundStyle(.white).pointerStyle(.link).help(link.absoluteString)
                } else {
                    Text(author)
                }
            }
            if parts.count > 1 { Text(parts[1]) }
        }
        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.9))
        .shadow(color: .black.opacity(0.6), radius: 3)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.black.opacity(0.25), in: Capsule())
        .padding(14)
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A centered title card above the left-aligned actions and catalogs, with room around it.
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 80, height: 80)
                VStack(spacing: 2) {
                    Text(L10n.tr("Ceviche RAW Studio")).font(.system(size: 20, weight: .semibold))
                    if let version { Text(L10n.tr("Version \(version)")).font(.system(size: 11)).foregroundStyle(.tertiary) }
                }
            }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.top, 44).padding(.bottom, 8)
            Button(action: model.importIntoNewLocalCatalog) {
                Label(L10n.tr("Import Photos…"), systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
            }
            .buttonStyle(.primaryAction).keyboardShortcut(recent.isEmpty && inCloud.isEmpty ? .defaultAction : nil)
            .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 12)
            VStack(spacing: 1) {
                ActionRow(icon: "folder.badge.plus", title: L10n.tr("New Catalog…"), shortcut: "⌥⌘N") { model.chooseCatalog(create: true) }
                if BuildFeatures.iCloud {
                    ActionRow(icon: "icloud.and.arrow.up", title: L10n.tr("New iCloud Catalog…")) { namingCloudCatalog = true }
                }
                Rule().padding(.horizontal, 10).padding(.vertical, 6)
                ActionRow(icon: "folder", title: L10n.tr("Open Catalog…"), shortcut: "⌥⌘O") { model.chooseCatalog(create: false) }
                if BuildFeatures.iCloud {
                    ActionRow(icon: "icloud", title: L10n.tr("iCloud Catalogs…"), shortcut: "⇧⌘O") { openingCloudCatalog = true }
                }
                ActionRow(icon: "rectangle.stack", title: L10n.tr("Browse Folders"), action: model.browseFolders)
            }.padding(.horizontal, 12)
            catalogs
            // The Core ML models are downloaded on demand; the welcome screen says so before a tool has to.
            ActionRow(icon: "cpu", title: L10n.tr("Models…")) { ModelPrompt.open(nil, openSettings) }
                .help(L10n.tr("Masks, AI noise reduction and AI fill")).fixedSize()
                .padding(.horizontal, 12).padding(.bottom, 14)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .disabled(model.catalogWideBusy)
    }

    /// Fills the column between the actions and the models, scrolling when the list is long.
    private var catalogs: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(L10n.tr("Recent Catalogs")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if BuildFeatures.iCloud, model.lookingForCloudCatalogs {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14).help(L10n.tr("Looking in iCloud…"))
                }
            }.padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 6)
            if recent.isEmpty && inCloud.isEmpty {
                Text(L10n.tr("No Catalogs")).font(.system(size: 12)).foregroundStyle(.tertiary).padding(.horizontal, 22).padding(.top, 4)
                Spacer(minLength: 12)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(recent.enumerated()), id: \.element.id) { index, reference in
                            CatalogRow(name: reference.name, detail: (reference.path as NSString).abbreviatingWithTildeInPath,
                                       icon: reference.kind == .cloud ? "icloud" : "folder", isDefault: index == 0) {
                                Task { await model.openCatalog(reference.url) }
                            }
                            .contextMenu {
                                Button(L10n.tr("Show in Finder")) { NSWorkspace.shared.showInFinder([reference.url]) }
                                Button(L10n.tr("Remove from List")) { model.forgetCatalog(reference) }
                            }
                        }
                        if !inCloud.isEmpty {
                            Text(L10n.tr("In iCloud")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.top, recent.isEmpty ? 0 : 12).padding(.bottom, 4)
                            ForEach(inCloud) { listing in
                                CatalogRow(name: listing.name, detail: nil, icon: "icloud", isDefault: recent.isEmpty && listing.id == inCloud.first?.id) {
                                    model.openCloudCatalog(listing)
                                }
                            }
                        }
                    }.padding(.horizontal, 12).padding(.bottom, 8)
                }.scrollIndicators(.automatic)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// A start action in the welcome panel: a glyph, its name, and the menu shortcut that does the same.
private struct ActionRow: View {
    let icon: String
    let title: String
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Theme.accent).frame(width: 20)
                Text(title).font(.system(size: 13))
                Spacer(minLength: 8)
                if let shortcut { Text(shortcut).font(.system(size: 11)).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 10).frame(height: 30).contentShape(Rectangle())
            .background(hovering && isEnabled ? Theme.ink.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .opacity(isEnabled ? 1 : 0.4)
        }.buttonStyle(.plain).onHover { hovering = $0 }
    }
}

/// One catalog in the welcome list: its name and where it lives; the whole row opens it. The most recent one shows an
/// Open button and answers Return.
private struct CatalogRow: View {
    let name: String
    let detail: String?
    let icon: String
    var isDefault = false
    let open: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 16)).foregroundStyle(isDefault || hovering ? Theme.accent : .secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle) }
                }
                Spacer(minLength: 12)
                if isDefault {
                    Text(L10n.tr("Open")).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 10).padding(.vertical, 3).background(Theme.accent, in: Capsule())
                } else {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary).opacity(hovering ? 1 : 0)
                }
            }
            .padding(.horizontal, 10).frame(height: 46).contentShape(Rectangle())
            .background(hovering ? Theme.ink.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        }.buttonStyle(.plain).onHover { hovering = $0 }.help(isDefault ? L10n.tr("Open \(name) (Return)") : L10n.tr("Open \(name)"))
            .keyboardShortcut(isDefault ? .defaultAction : nil)
    }
}

/// Name a new iCloud catalog, or open one this Apple ID already has.
struct NewCloudCatalogSheet: View {
    @ObservedObject var model: CatalogModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = L10n.tr("iCloud Library")
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: L10n.tr("New iCloud Catalog"))
            Text(L10n.tr("Your edits, ratings and imported originals sync to every device signed in to your Apple ID. Photos you only link to stay where they are."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(L10n.tr("Name"), text: $name).textFieldStyle(.formField).onSubmit(create)
            CloudCatalogList(model: model, title: L10n.tr("Or open a catalog you already have")) { dismiss() }
            HStack {
                Spacer()
                Button(L10n.tr("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.secondaryAction)
                Button(L10n.tr("Create"), action: create).keyboardShortcut(.defaultAction).buttonStyle(.primaryAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(24).frame(width: 440)
        .onAppear { model.lookForCloudCatalogs() }
    }
    private func create() { model.createCloudCatalog(named: name); dismiss() }
}

/// File ▸ Manage iCloud Catalogs: every iCloud catalog this Apple ID has, to open by name on any Mac, add, rename or
/// delete.
struct CloudCatalogsSheet: View {
    @ObservedObject var model: CatalogModel
    /// Lets the open catalog close before it is deleted; nil where no catalog can be open.
    var editor: EditorModel?
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var editing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "icloud").font(.system(size: 22)).foregroundStyle(Theme.accent).frame(width: 30, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("iCloud Catalogs")).font(.title3.weight(.semibold))
                    Text(L10n.tr("Catalogs that sync between devices signed in to your Apple ID.")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if model.lookingForCloudCatalogs { ProgressView().controlSize(.small).help(L10n.tr("Looking in iCloud…")) }
            }
            CloudCatalogList(model: model, title: nil, manageable: true, editor: editor, creating: $creating, editing: $editing) { dismiss() }
            Spacer(minLength: 0)
            HStack {
                Button { creating = true } label: { Label(L10n.tr("New Catalog"), systemImage: "plus") }
                    .buttonStyle(ActionButtonStyle(role: .tinted)).disabled(creating || model.catalogWideBusy || model.cloudCatalogsReachable == nil)
                Spacer()
                // Escape cancels a name being edited before it closes the sheet.
                Button(L10n.tr("Close")) { dismiss() }.keyboardShortcut(editing ? nil : .cancelAction).buttonStyle(.secondaryAction)
            }
        }.padding(22).frame(width: 460).frame(minHeight: 320, alignment: .top)
        .onAppear { model.lookForCloudCatalogs() }
    }
}

/// The iCloud catalogs found so far, with the open one marked, and what is happening while the list fills in.
/// `manageable` adds Rename, Delete and the rest to each row, and a row for naming a new catalog while `creating`.
struct CloudCatalogList: View {
    @ObservedObject var model: CatalogModel
    let title: String?
    var manageable = false
    var editor: EditorModel?
    var creating: Binding<Bool> = .constant(false)
    /// True while a name is being typed, so the sheet leaves Escape to it.
    var editing: Binding<Bool> = .constant(false)
    let opened: () -> Void
    @State private var renaming: String?
    @State private var draftName = ""
    @State private var deleting: CloudCatalogListing?
    @FocusState private var nameFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title, !model.cloudCatalogs.isEmpty { Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary) }
            if manageable {
                VStack(spacing: 2) {
                    if creating.wrappedValue { newRow }
                    else if model.cloudCatalogs.isEmpty { emptyState }
                    ForEach(model.cloudCatalogs) { row($0) }
                }
                .padding(6)
                .background(Theme.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(Theme.hairline))
            } else {
                ForEach(model.cloudCatalogs) { listing in
                    HStack {
                        Label(listing.name, systemImage: "icloud")
                        Spacer()
                        openControl(listing)
                    }
                }
            }
            if manageable, model.cloudCatalogsReachable != false {
                // The panel's empty state and the header's spinner say the rest.
            } else if model.cloudCatalogsReachable == false {
                Text(L10n.tr("This copy of Ceviche is not signed for iCloud, so it cannot see catalogs from your other Macs."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if model.lookingForCloudCatalogs {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L10n.tr("Looking in iCloud…")) }.font(.caption).foregroundStyle(.secondary)
            } else if model.cloudCatalogs.isEmpty, model.cloudCatalogsReachable == true {
                Text(L10n.tr("No iCloud catalogs were found for this Apple ID.")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: creating.wrappedValue) { _, now in
            guard now else { return }
            renaming = nil; draftName = L10n.tr("iCloud Library")
            DispatchQueue.main.async { nameFocused = true }
        }
        .onChange(of: renaming != nil || creating.wrappedValue) { _, now in editing.wrappedValue = now }
        .alert(deleting.map { L10n.tr("Delete “\($0.name)” and Its Photos?") } ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { listing in
            Button(L10n.tr("Delete Catalog"), role: .destructive) {
                Task { await model.deleteCloudCatalog(listing, editor: editor) }
                deleting = nil
            }
            Button(L10n.tr("Cancel"), role: .cancel) { deleting = nil }
        } message: { listing in
            Text(deletionMessage(listing))
        }
    }
    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(model.lookingForCloudCatalogs ? L10n.tr("Looking in iCloud…") : L10n.tr("No iCloud catalogs yet")).font(.system(size: 12, weight: .medium))
            if !model.lookingForCloudCatalogs {
                Text(L10n.tr("Create one to sync your edits and originals between devices.")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 22)
    }
    /// A new catalog being named, at the top of the list: Return or clicking away adds it, Escape or an empty name
    /// cancels.
    private var newRow: some View {
        CloudCatalogRow {
            Image(systemName: "icloud").font(.system(size: 13)).foregroundStyle(Theme.accent).frame(width: 20)
            nameField(commit: commitNew, cancel: { creating.wrappedValue = false })
                .onChange(of: nameFocused) { _, focused in if !focused, creating.wrappedValue { commitNew() } }
        }
    }
    /// Edited in place, like a name in Finder.
    private func nameField(commit: @escaping () -> Void, cancel: @escaping () -> Void) -> some View {
        TextField(L10n.tr("Name"), text: $draftName).textFieldStyle(.plain).font(.system(size: 12, weight: .medium))
            .focused($nameFocused)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.accent.opacity(0.7)))
            .onSubmit(commit)
            .onExitCommand(perform: cancel)
    }
    private func row(_ listing: CloudCatalogListing) -> some View {
        CloudCatalogRow(isCurrent: model.manifest?.id == listing.id) {
            Image(systemName: "icloud").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 20)
            if renaming == listing.id {
                nameField(commit: { commitRename(listing) }, cancel: { renaming = nil })
                    .onChange(of: nameFocused) { _, focused in if !focused, renaming == listing.id { commitRename(listing) } }
            } else {
                Text(listing.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    .onTapGesture(count: 2) { startRenaming(listing) }
                    .help(L10n.tr("Double-click to rename"))
                Spacer(minLength: 8)
                openControl(listing)
                Menu { actions(listing) } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .disabled(model.catalogWideBusy)
                .accessibilityLabel(L10n.tr("Manage \(listing.name)"))
            }
        }
        .contextMenu { if manageable, renaming != listing.id { actions(listing) } }
    }
    @ViewBuilder private func actions(_ listing: CloudCatalogListing) -> some View {
        if model.manifest?.id != listing.id { Button(L10n.tr("Open")) { model.openCloudCatalog(listing); opened() } }
        Button(L10n.tr("Rename")) { startRenaming(listing) }
        if let folder = CatalogModel.cloudOriginalsFolder(id: listing.id), FileManager.default.fileExists(atPath: folder.path) {
            Button(L10n.tr("Show Originals in Finder")) { NSWorkspace.shared.showInFinder([folder]) }
        }
        Divider()
        Button(L10n.tr("Delete…"), role: .destructive) { deleting = listing }
    }
    @ViewBuilder private func openControl(_ listing: CloudCatalogListing) -> some View {
        if model.manifest?.id == listing.id {
            Text(L10n.tr("In Use")).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent)
                .padding(.horizontal, 8).padding(.vertical, 3).background(Theme.accent.opacity(0.16), in: Capsule())
                .help(L10n.tr("This catalog is open"))
        }
        else { Button(L10n.tr("Open")) { model.openCloudCatalog(listing); opened() }.buttonStyle(.secondaryAction).controlSize(.small).disabled(model.catalogWideBusy) }
    }
    private func startRenaming(_ listing: CloudCatalogListing) {
        guard !model.catalogWideBusy else { return }
        creating.wrappedValue = false
        draftName = listing.name; renaming = listing.id
        DispatchQueue.main.async { nameFocused = true }
    }
    private func commitRename(_ listing: CloudCatalogListing) {
        guard renaming == listing.id else { return }
        renaming = nil
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != listing.name { model.renameCloudCatalog(listing, to: name) }
    }
    private func commitNew() {
        guard creating.wrappedValue else { return }
        creating.wrappedValue = false
        model.addCloudCatalog(named: draftName)
    }
    private func deletionMessage(_ listing: CloudCatalogListing) -> String {
        var message = L10n.tr("“\(listing.name)” is deleted on every device signed in to your Apple ID. Photos imported into it are deleted from iCloud and moved to the Trash on this Mac. Edits, albums and ratings cannot be recovered.\n\nLinked photos stay where they are.")
        if model.manifest?.id == listing.id { message += L10n.tr("\n\n“\(listing.name)” is open and will close first.") }
        return message
    }
}

/// A row in the iCloud Catalogs list, highlighted under the pointer like the welcome list.
private struct CloudCatalogRow<Content: View>: View {
    var isCurrent = false
    @ViewBuilder let content: Content
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 10) { content }
            .padding(.leading, 10).padding(.trailing, 6).frame(minHeight: 40)
            .background(hovering ? Theme.ink.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .onHover { hovering = $0 }
    }
}

/// A photo for the welcome screen and its credit, from `Welcome/photos.json` in the bundle, which scripts/welcome-photos.py
/// writes from welcome/photos.csv. The list is read once; each image is decoded only when it is shown.
struct WelcomePhoto {
    let file: String
    let title: String
    let author: String?
    let link: URL?
    let url: URL
    var image = NSImage()
    /// A short clip, played muted on a loop in place of a still.
    var isVideo: Bool { ["mp4", "mov"].contains(url.pathExtension.lowercased()) }
    private struct Entry: Decodable { let file, title: String; let author, link: String? }
    static func all(in bundle: Bundle = .main) -> [WelcomePhoto] {
        guard let folder = bundle.resourceURL?.appendingPathComponent("Welcome"),
              let data = try? Data(contentsOf: folder.appendingPathComponent("photos.json")),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.map { WelcomePhoto(file: $0.file, title: $0.title, author: $0.author, link: $0.link.flatMap(URL.init(string:)),
                                          url: folder.appendingPathComponent($0.file)) }
    }
    /// This photo with its image decoded; nil when the file can't be read.
    func loaded() -> WelcomePhoto? {
        if isVideo { return FileManager.default.isReadableFile(atPath: url.path) ? self : nil }
        guard let image = NSImage(contentsOf: url) else { return nil }
        var photo = self; photo.image = image; return photo
    }
}

/// A welcome clip filling its frame, muted and looping. AVPlayerLooper keeps the next pass queued, so the seam has no gap.
private struct WelcomeVideo: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PlayerView { PlayerView(url: url) }
    func updateNSView(_ view: PlayerView, context: Context) {}
    static func dismantleNSView(_ view: PlayerView, coordinator: ()) { view.player.pause() }

    final class PlayerView: NSView {
        let player = AVQueuePlayer()
        private let looper: AVPlayerLooper
        init(url: URL) {
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            super.init(frame: .zero)
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            self.layer = layer; wantsLayer = true
            player.play()
        }
        required init?(coder: NSCoder) { fatalError() }
    }
}

/// Prev and next on the welcome photo: barely there until the pointer is over them.
private struct WelcomeStepButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 22, weight: .light))
                .frame(width: 44, height: 88).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.white.opacity(hovering ? 0.75 : 0.12))
        .shadow(color: .black.opacity(hovering ? 0.4 : 0), radius: 3)
        .onHover { hovering = $0 }.animation(.easeOut(duration: 0.15), value: hovering)
        .padding(.horizontal, 6).help(label).accessibilityLabel(label)
    }
}
