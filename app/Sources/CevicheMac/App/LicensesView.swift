import SwiftUI
import CevicheCore

struct LicenseCredit: Decodable, Identifiable {
    struct Notice: Decodable {
        let path: String
        let encoding: String?
    }
    let id: String
    let name: String
    let license: String
    let projectURL: URL
    let distribution: String
    let notices: [Notice]
    var texts: [String] = []
    enum CodingKeys: String, CodingKey { case id, name, license, projectURL, distribution, notices }

    var isVisible: Bool { ["application", "bundled", "build-wrapper", "system", "optional-model"].contains(distribution) }
    var isModel: Bool { distribution == "optional-model" }
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || name.localizedStandardContains(query) || license.localizedStandardContains(query)
    }
}

/// `credits.json` and the notices beside it, as shipped in the app: the one manifest `scripts/credits.py` checks and
/// makes `licenses/CREDITS.md` from.
struct LicenseCatalog: Decodable {
    let schemaVersion: Int
    var components: [LicenseCredit]
    static let bundled = Result { try load() }
    enum LoadError: Error { case invalidResources }

    static func load(root: URL? = Bundle.module.url(forResource: "OpenSourceLicenses", withExtension: nil)) throws -> Self {
        guard let root else { throw LoadError.invalidResources }
        var catalog = try JSONDecoder().decode(Self.self, from: Data(contentsOf: root.appendingPathComponent("credits.json")))
        guard catalog.schemaVersion == 2, Set(catalog.components.map(\.id)).count == catalog.components.count else { throw LoadError.invalidResources }
        for i in catalog.components.indices {
            let component = catalog.components[i]
            guard component.projectURL.scheme == "https", !component.notices.isEmpty else { throw LoadError.invalidResources }
            catalog.components[i].texts = try component.notices.map { notice in
                let url = root.appendingPathComponent(notice.path).standardizedFileURL
                guard url.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw LoadError.invalidResources }
                let data = try Data(contentsOf: url)
                guard notice.encoding == nil || notice.encoding == "iso-8859-1" else { throw LoadError.invalidResources }
                let encoding: String.Encoding = notice.encoding == "iso-8859-1" ? .isoLatin1 : .utf8
                guard let text = String(data: data, encoding: encoding), !text.isEmpty else { throw LoadError.invalidResources }
                return text
            }
        }
        catalog.components.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return catalog
    }
}

/// The entry the licenses window should show next: set before opening it, and it expands and scrolls to that entry.
@MainActor final class LicenseFocus: ObservableObject {
    static let shared = LicenseFocus()
    @Published var id: String?
    /// The credit (`credits.json` id) for each optional model.
    static func creditID(_ model: BundledModel) -> String {
        switch model {
        case .depth: return "depth-anything"
        case .scene: return "detr"
        case .denoise: return "nafnet"
        case .sky: return "sky-segmentation"
        case .inpaint: return "lama"
        case .blemishes, .skinTone: return "alibaba-blemish"
        case .peopleParts: return "mediapipe-selfie-multiclass"
        case .faceMesh: return "mediapipe-face-landmarker"
        case .faceIdentity: return "opencv-sface"
        }
    }
}

struct LicensesView: View {
    static let windowID = "licenses"
    @ObservedObject private var focus = LicenseFocus.shared
    @State private var query = ""
    @State private var expanded: Set<String>
    /// The entry a license link asked for, waiting for the list to scroll to it.
    @State private var scrollTarget: String?
    private let catalog: Result<LicenseCatalog, Error>

    init(catalog: Result<LicenseCatalog, Error> = LicenseCatalog.bundled, expanded: Set<String> = []) {
        self.catalog = catalog
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.tr("Search"), text: $query).textFieldStyle(.plain)
                    .accessibilityIdentifier("licenses.search")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help(L10n.tr("Clear"))
                }
            }
            .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.card)).padding(16)
            Rule()
            switch catalog {
            case .success(let catalog):
                let matches = catalog.components.filter { $0.isVisible && $0.matches(query) }
                if matches.isEmpty {
                    ContentUnavailableView.search(text: query).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(matches.filter { !$0.isModel }) { credit in row(credit) }
                                let models = matches.filter(\.isModel)
                                if !models.isEmpty {
                                    Text(L10n.tr("Optional Models")).font(.headline).padding(.top, 12)
                                    ForEach(models) { credit in row(credit) }
                                }
                            }.padding(16)
                        }
                        .onAppear { scroll(proxy) }
                        .onChange(of: scrollTarget) { _, _ in scroll(proxy) }
                    }
                }
            case .failure:
                ContentUnavailableView(L10n.tr("Licenses could not be loaded."), systemImage: "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 420, minHeight: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        // Handled outside the results list, so a link still lands while a search shows no matches.
        .onAppear { reveal(focus.id) }
        .onChange(of: focus.id) { _, id in reveal(id) }
    }

    /// Opens the entry a model's license link asked for: clears the search, expands it and scrolls to it.
    private func reveal(_ id: String?) {
        guard let id else { return }
        query = ""
        expanded.insert(id)
        focus.id = nil
        scrollTarget = id
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let id = scrollTarget else { return }
        scrollTarget = nil
        DispatchQueue.main.async { withAnimation { proxy.scrollTo(id, anchor: .top) } }
    }

    /// A project: its name and licence, and its home page at the right. Clicking anywhere else on the header shows or
    /// hides the licence texts.
    private func row(_ credit: LicenseCredit) -> some View {
        let isExpanded = expanded.contains(credit.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { if isExpanded { expanded.remove(credit.id) } else { expanded.insert(credit.id) } }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0)).frame(width: 10)
                        Text(verbatim: credit.name).font(.headline).foregroundStyle(.primary)
                        Text(verbatim: credit.license).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 12).padding(.leading, 12).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "\(credit.name), \(credit.license)"))
                .accessibilityValue(isExpanded ? L10n.tr("Expanded") : L10n.tr("Collapsed"))
                .accessibilityIdentifier("licenses.\(credit.id)")
                Link(destination: credit.projectURL) {
                    Image(systemName: "link").font(.system(size: 11)).foregroundStyle(.secondary).padding(6).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(credit.projectURL.absoluteString)
                .accessibilityLabel(L10n.tr("Website"))
                .padding(.trailing, 8)
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(credit.notices.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 8) {
                            if credit.notices.count > 1 {
                                Text(verbatim: (credit.notices[index].path as NSString).lastPathComponent)
                                    .font(.caption.bold()).foregroundStyle(.secondary)
                            }
                            Text(verbatim: credit.texts[index])
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .id(credit.id)
    }
}
