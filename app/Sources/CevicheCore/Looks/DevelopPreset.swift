import Foundation

/// Develop presets: XMP presets/sidecars and legacy `.lrtemplate` files.
/// Presets change only the fields they contain; metadata and source sidecars are untouched.
public enum DevelopPreset {
    public static let maxBytes = 8 * 1024 * 1024

    /// Local brush presets use the same extensions but hold brush settings without
    /// mask geometry; they cannot be applied to a whole photo.
    static func isBrushPreset(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ext == "lrtemplate" || ext == "xmp", let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        if ext == "lrtemplate" { return head.contains("LocalizedAdjustmentPreset") }
        return head.contains("PaintBasedCorrections>") && !head.contains("CorrectionMasks") && !head.contains("crs:Exposure2012")
    }

    /// Parses either preset format into an XMP packet.
    public static func packet(_ url: URL) throws -> XMPPacket {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= maxBytes else { throw EditorError.invalidDocument(L10n.tr("Preset exceeds 8 MB.")) }
        if url.pathExtension.lowercased() == "lrtemplate" {
            guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else { throw EditorError.invalidDocument(L10n.tr("Template must be UTF-8.")) }
            return try LRTemplate.packet(text)
        }
        return try XMPPacket(url: url)
    }

    /// Applies preset fields to the current development. Native Ceviche recipes contribute
    /// only development and white balance, never geometry, masks or retouching.
    public static func apply(_ url: URL, to base: Adjustments, defaults: Adjustments, profiles: CameraProfileResolver? = nil) throws -> (Adjustments, [String]) {
        let packet = try packet(url)
        let imported = try XMPCodec.apply(packet, to: base, defaults: defaults, profiles: profiles)
        if packet.value("Recipe", namespace: XMPPacket.native) != nil, imported.warnings.isEmpty {
            var transfer = EditTransfer(sourceName: url.lastPathComponent, adjustments: imported.adjustments)
            // A saved preset names what it carries; the photo keeps the rest.
            if let saved = packet.nativeValue("PresetItems") {
                transfer.items = Set(saved.split(separator: ",").compactMap { EditTransferItem(rawValue: String($0)) }).intersection(EditTransferItem.defaults)
            }
            return (try transfer.applying(to: base), [])
        }
        return (imported.adjustments, imported.warnings)
    }

    /// The folder of the library's Presets that saved presets go to.
    public static let userFolder = "User Presets"
    /// What a preset saved from a photo carries: the development edited away from `baseline`, its camera defaults;
    /// never composition, masks or retouching.
    public static func savedItems(in adjustments: Adjustments, from baseline: Adjustments) -> Set<EditTransferItem> {
        EditTransferItem.edited(in: adjustments, from: baseline).intersection(EditTransferItem.defaults)
    }
    /// Saves a photo's edits as `User Presets/<name>.xmp` in `library`; a name already there gets a number.
    @discardableResult
    public static func save(_ adjustments: Adjustments, baseline: Adjustments, name: String, in library: LookLibrary) throws -> URL {
        let name = try LookLibrary.validName(name)
        let items = savedItems(in: adjustments, from: baseline)
        guard !items.isEmpty else { throw EditorError.invalidDocument(L10n.tr("This photo has no edits to save.")) }
        var carried = Adjustments()
        for item in EditTransferItem.allCases where items.contains(item) { item.copy(from: adjustments, into: &carried) }
        let data = try XMPCodec.encode(adjustments: carried.validated(), preset: XMPPreset(name: name, items: items))
        // An embedded LUT or camera profile can outgrow what presets are read at.
        guard data.count <= maxBytes else { throw EditorError.invalidDocument(L10n.tr("Preset exceeds 8 MB.")) }
        let folder = try library.prepare(.presets).appendingPathComponent(userFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = LookLibrary.available(name + ".xmp", in: folder)
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// Reads the Lua table syntax of `.lrtemplate` files.
enum LRTemplate {
    indirect enum Value { case string(String), number(String), bool(Bool), table([(String?, Value)]) }

    static func packet(_ text: String) throws -> XMPPacket {
        var parser = Parser(text: Array(text.unicodeScalars))
        let root = try parser.document()
        if case .table(let fields) = root, let type = fields.first(where: { $0.0 == "type" })?.1, case .string("LocalizedAdjustmentPreset") = type {
            throw EditorError.invalidDocument(L10n.tr("This is a local adjustment brush preset; only develop presets can be applied."))
        }
        guard case .table(let fields) = root, let valueField = fields.first(where: { $0.0 == "value" })?.1,
              case .table(let value) = valueField, let settingsField = value.first(where: { $0.0 == "settings" })?.1,
              case .table(let settings) = settingsField else { throw EditorError.invalidDocument(L10n.tr("Template has no develop settings.")) }
        var attributes: [String] = [], elements: [String] = []
        // Some templates repeat a key; as in Lua, the last value wins.
        var latest: [String: Int] = [:]
        for (index, field) in settings.enumerated() { if let key = field.0 { latest[key] = index } }
        for (index, (key, value)) in settings.enumerated() {
            guard let key, isName(key), latest[key] == index else { continue }
            switch value {
            case .string(let s): attributes.append("crs:\(key)=\"\(escape(s))\"")
            case .number(let n): attributes.append("crs:\(key)=\"\(n)\"")
            case .bool(let b): attributes.append("crs:\(key)=\"\(b ? "True" : "False")\"")
            case .table(let items): if let element = try element(key, items) { elements.append(element) }
            }
        }
        if let title = fields.first(where: { $0.0 == "title" })?.1, case .string(let name) = title {
            elements.append("<crs:Name><rdf:Alt><rdf:li xml:lang=\"x-default\">\(escape(name))</rdf:li></rdf:Alt></crs:Name>")
        }
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="\(XMPPacket.rdf)"><rdf:Description rdf:about="" xmlns:crs="\(XMPPacket.crs)" \(attributes.joined(separator: " "))>\(elements.joined())</rdf:Description></rdf:RDF></x:xmpmeta>
        """
        return try XMPPacket(data: Data(xml.utf8))
    }

    private static func element(_ key: String, _ items: [(String?, Value)]) throws -> String? {
        if items.isEmpty { return nil }
        if items.allSatisfy({ $0.0 == nil }) {
            let values = items.map(\.1)
            // Curves are flat x, y number lists in templates; XMP stores "x, y" pairs.
            if key.contains("ToneCurve"), values.allSatisfy({ if case .number = $0 { return true }; return false }) {
                guard values.count % 2 == 0 else { throw EditorError.invalidDocument(L10n.tr("Invalid template tone curve.")) }
                let numbers = values.map { if case .number(let n) = $0 { return n }; return "" }
                let pairs = stride(from: 0, to: numbers.count, by: 2).map { "<rdf:li>\(numbers[$0]), \(numbers[$0 + 1])</rdf:li>" }
                return "<crs:\(key)><rdf:Seq>\(pairs.joined())</rdf:Seq></crs:\(key)>"
            }
            let lis = try values.map { value -> String in
                switch value {
                case .string(let s): return "<rdf:li>\(escape(s))</rdf:li>"
                case .number(let n): return "<rdf:li>\(n)</rdf:li>"
                case .bool(let b): return "<rdf:li>\(b ? "True" : "False")</rdf:li>"
                case .table(let fields): return "<rdf:li rdf:parseType=\"Resource\">\(try resource(fields))</rdf:li>"
                }
            }
            return "<crs:\(key)><rdf:Seq>\(lis.joined())</rdf:Seq></crs:\(key)>"
        }
        return "<crs:\(key) rdf:parseType=\"Resource\">\(try resource(items))</crs:\(key)>"
    }
    private static func resource(_ fields: [(String?, Value)]) throws -> String {
        try fields.compactMap { key, value -> String? in
            guard let key, isName(key) else { return nil }
            switch value {
            case .string(let s): return "<crs:\(key)>\(escape(s))</crs:\(key)>"
            case .number(let n): return "<crs:\(key)>\(n)</crs:\(key)>"
            case .bool(let b): return "<crs:\(key)>\(b ? "True" : "False")</crs:\(key)>"
            case .table(let items): return try element(key, items)
            }
        }.joined()
    }
    static func isName(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, CharacterSet.letters.contains(first) || first == "_" else { return false }
        return key.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "_" }
    }
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").unicodeScalars.filter { $0.value >= 0x20 || $0 == "\n" || $0 == "\t" }.map(String.init).joined()
    }

    struct Parser {
        let text: [Unicode.Scalar]
        var index = 0
        var depth = 0
        init(text: [Unicode.Scalar]) { self.text = text }

        mutating func document() throws -> Value {
            skip()
            // `s = { ... }` or a bare `return { ... }` table.
            if let name = identifier() {
                skip()
                if name == "return" { return try value() }
                guard take("=") else { throw failure() }
            }
            return try value()
        }
        func failure() -> Error { EditorError.invalidDocument(L10n.tr("Invalid template near character \(index).")) }
        mutating func skip() {
            while index < text.count {
                if text[index].properties.isWhitespace { index += 1 }
                else if text[index] == "-", index + 1 < text.count, text[index + 1] == "-" {
                    while index < text.count, text[index] != "\n" { index += 1 }
                } else { break }
            }
        }
        mutating func take(_ c: Unicode.Scalar) -> Bool {
            skip(); guard index < text.count, text[index] == c else { return false }
            index += 1; return true
        }
        mutating func identifier() -> String? {
            skip()
            let start = index
            while index < text.count, text[index] == "_" || (text[index].isASCII && CharacterSet.alphanumerics.contains(text[index])) { index += 1 }
            guard index > start, !CharacterSet.decimalDigits.contains(text[start]) else { index = start; return nil }
            return String(String.UnicodeScalarView(text[start..<index]))
        }
        mutating func value() throws -> Value {
            skip()
            guard index < text.count else { throw failure() }
            let c = text[index]
            if c == "{" { return try table() }
            if c == "\"" || c == "'" { return .string(try string()) }
            if c == "[", index + 1 < text.count, text[index + 1] == "=" || text[index + 1] == "[" { return .string(try longString()) }
            if let word = identifier() {
                switch word {
                case "true": return .bool(true)
                case "false": return .bool(false)
                case "nil": return .string("")
                default: throw failure()
                }
            }
            let start = index
            while index < text.count, "+-.0123456789abcdefABCDEFxX".unicodeScalars.contains(text[index]) { index += 1 }
            let number = String(String.UnicodeScalarView(text[start..<index]))
            guard let parsed = Double(number), parsed.isFinite else { throw failure() }
            return .number(number)
        }
        mutating func table() throws -> Value {
            depth += 1; defer { depth -= 1 }
            guard depth < 32 else { throw EditorError.invalidDocument(L10n.tr("Template is too deeply nested.")) }
            index += 1
            var fields: [(String?, Value)] = []
            while true {
                skip()
                guard fields.count < 100_000 else { throw failure() }
                if take("}") { return .table(fields) }
                let mark = index
                if take("[") {
                    let key = try value(); guard take("]"), take("=") else { throw failure() }
                    switch key { case .string(let s): fields.append((s, try value())); case .number(let n): fields.append((n, try value())); default: throw failure() }
                } else if let name = identifier(), take("=") {
                    fields.append((name, try value()))
                } else {
                    index = mark; fields.append((nil, try value()))
                }
                if !take(",") && !take(";") { guard take("}") else { throw failure() }; return .table(fields) }
            }
        }
        mutating func string() throws -> String {
            let quote = text[index]; index += 1
            var result = String.UnicodeScalarView()
            while index < text.count {
                let c = text[index]; index += 1
                if c == quote { return String(result) }
                if c == "\\", index < text.count {
                    let e = text[index]; index += 1
                    switch e {
                    case "n": result.append("\n"); case "t": result.append("\t"); case "r": result.append("\r")
                    case "\n": result.append("\n")
                    default:
                        if CharacterSet.decimalDigits.contains(e) {
                            var digits = String(e)
                            while digits.count < 3, index < text.count, CharacterSet.decimalDigits.contains(text[index]) { digits.unicodeScalars.append(text[index]); index += 1 }
                            if let code = UInt32(digits), let scalar = Unicode.Scalar(code) { result.append(scalar) }
                        } else { result.append(e) }
                    }
                } else { result.append(c) }
            }
            throw failure()
        }
        mutating func longString() throws -> String {
            index += 1
            var level = 0
            while index < text.count, text[index] == "=" { level += 1; index += 1 }
            guard index < text.count, text[index] == "[" else { throw failure() }
            index += 1
            let close = Array(("]" + String(repeating: "=", count: level) + "]").unicodeScalars)
            let start = index
            while index + close.count <= text.count {
                if Array(text[index..<index + close.count]) == close {
                    let result = String(String.UnicodeScalarView(text[start..<index])); index += close.count; return result
                }
                index += 1
            }
            throw failure()
        }
    }
}
