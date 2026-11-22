import Foundation
import CevicheCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Suggests a name for a new album with Apple Intelligence's on-device model, from the photos' dates, places,
/// classifier tags and the photographer's own keywords (`AlbumNameContext`). Nil when Apple Intelligence is off or
/// unsupported, when the photos have not been tagged yet, or when the model gives nothing usable.
enum AlbumNamer {
    /// The instructions a name starts from. The model gives the album's title in English, where it follows them
    /// best; the app translates it and adds the time itself (`AlbumNameContext.timePhrase`), so dates come out right
    /// in every language. Tuned with `fm respond` against the on-device model.
    static let instructions = """
        You title albums in a photographer's catalog. Given facts about the photos in a new album, give the \
        album's title.
        
        Rules:
        - 1 to 4 words, in English, in title case. No dates, months, years, quotes, emoji or final punctuation.
        - If the photographer's keywords or titles name an occasion (a wedding, a birthday, a trip) or people, \
        the title is that occasion. Other keywords count like detected subjects, but more.
        - Otherwise name the most specific subject that most photos share, with the place in front when one \
        place dominates.
        - Use only the facts given. Never invent places, people, names, events, time of day, weather or mood.
        - Detected subjects are machine labels with photo counts; they can be wrong or generic. Skip generic \
        ones such as building, street, tree, grass, water or vegetation when a more specific one is frequent. \
        Phrase them as a photographer would, as a natural noun phrase, never a list.
        
        Examples:
        Places: Lisbon, Portugal (212); Detected subjects: building (150), street (120), tram (90) → Lisbon Trams
        Places: Lisbon, Portugal (212); Detected subjects: building (150), street (120) → Lisbon
        Detected subjects: mountain (40), hiking (31), snow (12) → Snowy Mountain Hike
        Places: Florence, Italy (80); Detected subjects: bouquet (60); Photographer's keywords: wedding, anna, \
        marco → Anna and Marco's Wedding
        Detected subjects: boat (50), harbour (40), water (45) → Harbour Boats
        Detected subjects: cat (88) → Cats
        Places: Tromsø, Norway (40); Detected subjects: aurora (30), night sky (30); Photographer's keywords: \
        astro → Tromsø Auroras
        Detected subjects: statue (14), garden (10), bench (6) → Statue Garden
        """

    /// The instructions for putting an English album title into `language` ("Italian"); without examples in the
    /// language the model often hands the English back.
    static func translation(into language: String, code: String) -> String {
        """
        You translate photo album titles from English into \(language). Always answer in \(language), even for a \
        single word; never repeat the English.
        - Translate every word; use the usual \(language) name of places. Keep people's names as they are.
        - A short, natural noun phrase as a \(language)-speaking photographer would title an album: no article at \
        the start, no quotes or final punctuation.

        Examples:
        \(translationExamples[code] ?? "")
        """
    }
    static let translationExamples = [
        "zh-Hans": "Harbour Boats → 港口船只\nDogs → 狗\nTromsø Auroras → 特罗姆瑟极光\nEmma's Birthday → Emma 的生日\nSnowy Mountain Hike → 雪山徒步",
        "zh-Hant": "Harbour Boats → 港口船隻\nDogs → 狗\nTromsø Auroras → 特羅姆瑟極光\nEmma's Birthday → Emma 的生日\nSnowy Mountain Hike → 雪山健行",
        "it": "Harbour Boats → Barche nel porto\nDogs → Cani\nTromsø Auroras → Aurore a Tromsø\nEmma's Birthday → Compleanno di Emma\nSnowy Mountain Hike → Escursione sulla neve",
        "es": "Harbour Boats → Barcos en el puerto\nDogs → Perros\nTromsø Auroras → Auroras en Tromsø\nEmma's Birthday → Cumpleaños de Emma\nSnowy Mountain Hike → Excursión por la nieve",
    ]

    static var available: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    static func name(for context: AlbumNameContext) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
            let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 40)
            guard let reply = try? await session.respond(to: context.prompt, generating: SuggestedAlbumTitle.self, options: options),
                  var title = clean(reply.content.title) else { return nil }
            let code = languageCode
            if !code.hasPrefix("en") {
                let translator = LanguageModelSession(model: SystemLanguageModel.default, instructions: translation(into: language, code: code))
                if let translated = try? await translator.respond(to: title, generating: TranslatedAlbumTitle.self, options: options),
                   let text = clean(translated.content.title) { title = text }
            }
            // A set within one year carries its month or year; one spanning years is named by what it is of.
            guard let time = context.timePhrase(locale: Locale(identifier: code)), !time.contains("–") else { return title }
            return code.hasPrefix("zh") ? "\(title) \(time)" : "\(title), \(time)"
        }
        #endif
        return nil
    }

    /// The language the app's menus are in, named in English: the system's only when the app is translated into it.
    static var language: String {
        switch languageCode {
        case "zh-Hans": return "Simplified Chinese"
        case "zh-Hant": return "Traditional Chinese"
        case let code: return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
        }
    }
    static var languageCode: String {
        let choice = LanguageChoice.current
        return choice == .system ? (L10n.bundle.preferredLocalizations.first ?? "en") : choice.rawValue
    }

    /// Strips what the model adds despite the rules: quotes, a trailing full stop, a label, extra lines.
    static func clean(_ raw: String) -> String? {
        var name = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if let colon = name.range(of: "name:", options: [.caseInsensitive, .anchored]) { name.removeSubrange(colon) }
        name = name.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'“”‘’「」『』.。#")))
        guard !name.isEmpty, name.count <= 60 else { return nil }
        return name
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable struct SuggestedAlbumTitle {
    @Guide(description: "The album's title in English, 1 to 4 words, without dates")
    var title: String
}

@available(macOS 26, *)
@Generable struct TranslatedAlbumTitle {
    @Guide(description: "The translated title")
    var title: String
}
#endif
