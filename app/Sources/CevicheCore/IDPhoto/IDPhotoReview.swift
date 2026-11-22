import Foundation
import CoreGraphics
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A second look by the on-device Apple Intelligence model at what Vision can't measure: makeup, hair over the eyes,
/// a smile, glare. Its answers are hints, so they only ever warn.
public enum IDPhotoReview {
    public static var available: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 27, iOS 27, *) {
            let model = SystemLanguageModel.default
            return model.isAvailable && model.capabilities.contains(.vision)
        }
        #endif
        return false
    }

    static let instructions = """
    You inspect a portrait for a passport photo. Answer each question about the person only from what is clearly \
    visible. A neutral, relaxed mouth is not a smile. Answer false when unsure.
    """

    /// The head and shoulders cut from `image` around `face`, sent to the model.
    public static func review(_ image: CGImage, face: IDPhotoAnalysis.Face) async -> [IDPhotoCheck] {
        #if canImport(FoundationModels)
        if #available(macOS 27, iOS 27, *), available {
            let head = face.chin.y - face.crown.y
            let w = Double(image.width), h = Double(image.height)
            let rect = CGRect(x: (face.bounds.midX - head * 0.8 * h / w) * w, y: (face.crown.y - head * 0.15) * h,
                              width: head * 1.6 * h, height: head * 1.5 * h).integral
                .intersection(CGRect(x: 0, y: 0, width: w, height: h))
            guard let crop = image.cropping(to: rect) else { return [] }
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
            let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 120)
            guard let reply = try? await session.respond(generating: PortraitReview.self, options: options, prompt: {
                "Inspect this portrait."
                Attachment(crop)
            }) else { return [] }
            return checks(reply.content)
        }
        #endif
        return []
    }

    /// The hints that matter for `spec` and that the measured checks don't already report.
    public static func applicable(_ hints: [IDPhotoCheck], spec: IDPhotoSpec, measured: [IDPhotoCheck]) -> [IDPhotoCheck] {
        func flagged(_ id: String) -> Bool { measured.contains { $0.id == id && $0.status >= .warning } }
        return hints.filter { hint in
            switch hint.id {
            case "ai-smile": spec.expression == .neutral
            case "ai-glasses": spec.glasses != .allowed && !flagged("glasses")
            case "ai-glare": !measured.contains { $0.id == "glasses" && $0.status == .failure }
            case "ai-headwear": !flagged("headwear")
            default: true
            }
        }
    }

    #if canImport(FoundationModels)
    @available(macOS 27, iOS 27, *)
    static func checks(_ review: PortraitReview) -> [IDPhotoCheck] {
        var checks: [IDPhotoCheck] = []
        func add(_ id: String, _ title: String) {
            checks.append(IDPhotoCheck(id: "ai-" + id, title: title, status: .warning, detail: L10n.tr("Possible"), advisory: true))
        }
        if review.hairOverEyes { add("hair", L10n.tr("Hair over eyes")) }
        if review.heavyMakeup { add("makeup", L10n.tr("Heavy makeup")) }
        if review.smiling { add("smile", L10n.tr("Smiling")) }
        if review.glareOnGlasses { add("glare", L10n.tr("Glare on glasses")) }
        if review.eyeglasses { add("glasses", L10n.tr("Glasses")) }
        if review.headwear { add("headwear", L10n.tr("Headwear")) }
        if review.redEye { add("redeye", L10n.tr("Red eye")) }
        return checks
    }
    #endif
}

#if canImport(FoundationModels)
@available(macOS 27, iOS 27, *)
@Generable struct PortraitReview {
    @Guide(description: "Glasses of any kind are worn")
    var eyeglasses: Bool
    @Guide(description: "Light reflects off glasses lenses")
    var glareOnGlasses: Bool
    @Guide(description: "A hat, cap, hood worn on the head, headscarf or other head covering is worn")
    var headwear: Bool
    @Guide(description: "Hair covers an eye or an eyebrow")
    var hairOverEyes: Bool
    @Guide(description: "Clearly visible makeup such as lipstick, eyeliner or eyeshadow")
    var heavyMakeup: Bool
    // "Teeth show" or "smiling" alone came back true for neutral faces; this wording didn't, tried with `fm`.
    @Guide(description: "A broad smile: lips stretched wide and corners clearly raised")
    var smiling: Bool
    @Guide(description: "The pupils look red")
    var redEye: Bool
}
#endif
