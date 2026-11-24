import Foundation
import CoreML
import Vision

/// The Core ML models Ceviche can use. A few small ones are built in (models.sh MODEL_BUNDLED, compiled into
/// CevicheKit.framework's Resources/Models by the build); users download the rest into `ModelLibrary` (Settings ›
/// Models) from the model set pinned in this build, or add them from files; developers point builds at the models
/// `models/fetch-models.sh` converted. A missing model disables only the feature that needs it.
public enum BundledModel: String, CaseIterable, Sendable {
    case depth = "DepthAnythingV2SmallF16"
    case scene = "DETRResnet50SemanticSegmentationF16"
    case denoise = "NAFNetSIDD32"
    case sky = "SkySegmentation"
    case inpaint = "BigLaMa"
    case blemishes = "BlemishDetector"
    case skinTone = "SkinTone"
    case peopleParts = "PeopleParts"
    case faceMesh = "FaceMesh"
    case faceIdentity = "SFace"

    /// Searched in order: `CEVICHE_MODELS` (tests and command-line tools, usually `models/build/compiled`), the built-in
    /// models (always the ones this build was made with, whatever the library holds), the user's model library, then the
    /// folder a debug build recorded in its Info.plist (`CevicheDevelopmentModels`, set by the build to
    /// `models/build/compiled`) so `make dev` sees locally converted models without copying.
    public static var searchDirectories: [URL] {
        var directories: [URL] = []
        if let path = ProcessInfo.processInfo.environment["CEVICHE_MODELS"] { directories.append(URL(fileURLWithPath: path)) }
        if let builtIn = builtInDirectory { directories.append(builtIn) }
        directories.append(ModelLibrary.defaultDirectory)
        if let path = Bundle.main.object(forInfoDictionaryKey: "CevicheDevelopmentModels") as? String, !path.isEmpty { directories.append(URL(fileURLWithPath: path)) }
        return directories
    }
    public var url: URL? {
        // The library keeps each model in its own folder; development builds and older libraries keep them flat.
        Self.searchDirectories.flatMap { [$0.appendingPathComponent(rawValue).appendingPathComponent(rawValue + ".mlmodelc"), $0.appendingPathComponent(rawValue + ".mlmodelc")] }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
    public var isAvailable: Bool { url != nil }
    /// The models built into CevicheKit.framework, `<Name>/<Name>.mlmodelc` with its LICENSE. The framework rather
    /// than the app, so the index service and the MCP helper, which load it from the app, find them too.
    public static let builtInDirectory: URL? = Bundle(for: BundledModelCache.self).resourceURL?.appendingPathComponent("Models", isDirectory: true)
    /// Whether this build carries the model itself: it needs no download and can't be removed.
    public var isBuiltIn: Bool {
        guard let directory = Self.builtInDirectory else { return false }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent(rawValue).appendingPathComponent(rawValue + ".mlmodelc").path)
    }
}

/// Loads each bundled model once per process. Models are immutable after loading, so sharing is safe.
final class BundledModelCache: @unchecked Sendable {
    static let shared = BundledModelCache()
    private let lock = NSLock()
    private var models: [BundledModel: MLModel] = [:]
    private var vision: [BundledModel: VNCoreMLModel] = [:]
    private var gpuModels: [BundledModel: MLModel] = [:]
    private var functions: [BundledModel: [String: MLModel]] = [:]
    /// Loaded once per process; the compute units of the first request stay in force for later callers.
    func model(_ kind: BundledModel, computeUnits: MLComputeUnits = .all) throws -> MLModel {
        try lock.withLock {
            if let model = models[kind] { return model }
            guard let url = kind.url else { throw EditorError.invalidDocument(L10n.tr("The \(kind.feature) model is not installed. Install it in Settings › Models.")) }
            let configuration = MLModelConfiguration(); configuration.computeUnits = computeUnits
            let model = try MLModel(contentsOf: url, configuration: configuration)
            models[kind] = model
            return model
        }
    }
    /// A second copy that runs on the GPU, for work split between it and the Neural Engine `model` picks.
    func gpuModel(_ kind: BundledModel) throws -> MLModel {
        try lock.withLock {
            if let model = gpuModels[kind] { return model }
            guard let url = kind.url else { throw EditorError.invalidDocument(L10n.tr("The \(kind.feature) model is not installed. Install it in Settings › Models.")) }
            let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuAndGPU
            let model = try MLModel(contentsOf: url, configuration: configuration)
            gpuModels[kind] = model
            return model
        }
    }
    /// One function of a multifunction model (BigLaMa's window sizes), loaded once per process with every compute unit.
    func model(_ kind: BundledModel, function: String) throws -> MLModel {
        try lock.withLock {
            if let model = functions[kind]?[function] { return model }
            guard let url = kind.url else { throw EditorError.invalidDocument(L10n.tr("The \(kind.feature) model is not installed. Install it in Settings › Models.")) }
            let configuration = MLModelConfiguration(); configuration.functionName = function
            #if os(iOS)
            // With the Neural Engine allowed, iPadOS 26 spends 20 s on the load and then refuses the function name
            // ("must be nil unless the model type is ML Program"); on the GPU a 1024-pixel window takes a few seconds.
            configuration.computeUnits = .cpuAndGPU
            #endif
            let model = try MLModel(contentsOf: url, configuration: configuration)
            functions[kind, default: [:]][function] = model
            return model
        }
    }
    /// Forgets a model that was replaced or removed; the next request loads the file that is there now.
    func evict(_ kind: BundledModel) {
        lock.withLock { models[kind] = nil; vision[kind] = nil; gpuModels[kind] = nil; functions[kind] = nil }
    }
    func visionModel(_ kind: BundledModel) throws -> VNCoreMLModel {
        if let model = lock.withLock({ vision[kind] }) { return model }
        let model = try VNCoreMLModel(for: try self.model(kind))
        lock.withLock { vision[kind] = model }
        return model
    }
}

extension BundledModel {
    var title: String {
        switch self { case .depth: return L10n.tr("Depth"); case .scene: return L10n.tr("Scene"); case .denoise: return L10n.tr("AI noise reduction"); case .sky: return L10n.tr("Sky"); case .inpaint: return L10n.tr("AI fill"); case .blemishes: return L10n.tr("Blemishes"); case .skinTone: return L10n.tr("Even tone"); case .peopleParts: return L10n.tr("People"); case .faceMesh: return L10n.tr("Face"); case .faceIdentity: return L10n.tr("People") }
    }
    /// What the model is for, as Settings › Models and prompts name it.
    public var feature: String {
        switch self {
        case .depth: return L10n.tr("Depth masks")
        case .scene: return L10n.tr("Scene masks")
        case .denoise: return L10n.tr("AI noise reduction")
        case .sky: return L10n.tr("Sky masks")
        case .inpaint: return L10n.tr("Remove brush, AI fill")
        case .blemishes: return L10n.tr("Find blemishes")
        case .skinTone: return L10n.tr("Even tone")
        case .peopleParts: return L10n.tr("People masks")
        case .faceMesh: return L10n.tr("Eyes, lips and teeth in People masks")
        case .faceIdentity: return L10n.tr("People on the Faces wall")
        }
    }
    /// The upstream model, as models/MODELS.md describes it; not translated.
    public var upstream: String {
        switch self {
        case .depth: return "Depth Anything V2 Small, Apple Core ML conversion"
        case .scene: return "DETR ResNet-50 panoptic, Apple Core ML conversion"
        case .denoise: return "NAFNet SIDD width 32"
        case .sky: return "U²-Net sky segmentation, xiongzhu666"
        case .inpaint: return "Big-LaMa inpainting"
        case .blemishes: return "Alibaba skin retouching, blemish detector"
        case .skinTone: return "Alibaba skin retouching, even-tone network"
        case .peopleParts: return "MediaPipe Selfie Multiclass segmentation"
        case .faceMesh: return "MediaPipe Face Landmarker, face mesh"
        case .faceIdentity: return "OpenCV Zoo SFace face recognition"
        }
    }
    /// Where the model comes from, as pinned by models/fetch-models.sh.
    public var sourceURL: URL {
        switch self {
        case .depth: return URL(string: "https://huggingface.co/apple/coreml-depth-anything-v2-small")!
        case .scene: return URL(string: "https://huggingface.co/apple/coreml-detr-semantic-segmentation")!
        case .denoise: return URL(string: "https://github.com/megvii-research/NAFNet")!
        case .sky: return URL(string: "https://github.com/xiongzhu666/Sky-Segmentation-and-Post-processing")!
        case .inpaint: return URL(string: "https://github.com/advimman/lama")!
        case .blemishes, .skinTone: return URL(string: "https://modelscope.cn/models/iic/cv_unet_skin_retouching_torch")!
        case .peopleParts: return URL(string: "https://ai.google.dev/edge/mediapipe/solutions/vision/image_segmenter")!
        case .faceMesh: return URL(string: "https://ai.google.dev/edge/mediapipe/solutions/vision/face_landmarker")!
        case .faceIdentity: return URL(string: "https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface")!
        }
    }
    /// SPDX identifier of the model's own license.
    public var license: String {
        switch self { case .depth, .scene, .inpaint, .blemishes, .skinTone, .peopleParts, .faceMesh, .faceIdentity: return "Apache-2.0"; case .denoise, .sky: return "MIT" }
    }
}
