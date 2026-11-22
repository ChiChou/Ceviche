import Foundation

/// The model set this build was made for: a GitHub release of converted Core ML models (`models-v1`, `models-v2`, ...),
/// pinned by tag and by the SHA-256 of every asset in `Resources/ModelSet.json`. `models/package-models.sh` writes that
/// file when a set is packaged and the Models workflow proposes the pin as a pull request, so a build only ever
/// downloads the bytes it was made with. Each asset is an uncompressed Apple Archive, `<Name>.aar`, holding
/// `<Name>/<Name>.mlpackage` (or `.mlmodel`) and `<Name>/LICENSE`. Most models also come as `<Name>-INT8.aar`, laid
/// out the same with 8-bit weights, half the size; users choose either per model. Until the first set is published
/// the tag is null and nothing can be downloaded; models can still be added from files.
public struct ModelSet: Codable, Equatable, Sendable {
    /// The weights a downloaded model has: the FP16 conversion, or its INT8 copy.
    public enum Variant: String, Codable, CaseIterable, Sendable {
        case fp16, int8
        /// As Settings › Models shows it; not translated.
        public var title: String { self == .fp16 ? "FP16" : "INT8" }
    }
    public struct Asset: Codable, Equatable, Sendable {
        /// The release asset's file name, such as `NAFNetSIDD32.aar`.
        public let file: String
        public let sha256: String
        public let bytes: Int64
    }
    /// `owner/name` on GitHub.
    public let repository: String
    public let tag: String?
    /// Keyed by `BundledModel.rawValue`.
    public let models: [String: Asset]
    /// The INT8 copies, for the models that have one; absent in sets from before them.
    public let int8: [String: Asset]

    public init(repository: String, tag: String?, models: [String: Asset], int8: [String: Asset] = [:]) {
        self.repository = repository; self.tag = tag; self.models = models; self.int8 = int8
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repository = try container.decode(String.self, forKey: .repository)
        tag = try container.decodeIfPresent(String.self, forKey: .tag)
        models = try container.decode([String: Asset].self, forKey: .models)
        int8 = try container.decodeIfPresent([String: Asset].self, forKey: .int8) ?? [:]
    }
    /// The set compiled into this build.
    public static let pinned = try! JSONDecoder().decode(ModelSet.self, from: Data(contentsOf: Bundle.module.url(forResource: "ModelSet", withExtension: "json")!))
    public var isPinned: Bool { tag != nil }
    public func asset(_ model: BundledModel, _ variant: Variant = .fp16) -> Asset? {
        variant == .fp16 ? models[model.rawValue] : int8[model.rawValue]
    }
    /// The variants this set offers for `model`, FP16 first.
    public func variants(_ model: BundledModel) -> [Variant] { Variant.allCases.filter { asset(model, $0) != nil } }
    /// Which of the model's archives has this checksum.
    public func variant(_ model: BundledModel, sha256: String?) -> Variant? {
        Variant.allCases.first { asset(model, $0)?.sha256 == sha256 && sha256 != nil }
    }
    /// The release page, for people.
    public var releaseURL: URL? { tag.flatMap { URL(string: "https://github.com/\(repository)/releases/tag/\($0)") } }
    /// The release on the GitHub REST API, which lists the assets and their download URLs.
    public var apiURL: URL? { tag.flatMap { URL(string: "https://api.github.com/repos/\(repository)/releases/tags/\($0)") } }
    /// Where an asset is served without the API, the same bytes; used when the API is unavailable (rate limits).
    public func directURL(_ asset: Asset) -> URL? { tag.flatMap { URL(string: "https://github.com/\(repository)/releases/download/\($0)/\(asset.file)") } }
}
