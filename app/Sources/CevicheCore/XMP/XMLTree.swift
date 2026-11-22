import Foundation

/// A namespace-aware XML element tree read with `XMLParser`, which every Apple platform has; `XMLDocument` is
/// macOS-only. It keeps what XMP reading needs and reads text as `XMLDocument` does with its default options:
/// whitespace-only text between elements is dropped, other text is kept as written.
final class XMLTreeElement {
    struct Attribute {
        /// As written, `crs:Exposure2012`.
        let name: String
        let localName: String
        /// Resolved through the declarations in scope; an unprefixed name takes the default namespace, as
        /// `XMLElement.resolveNamespace(forName:)` gives it.
        let uri: String
        let value: String
    }
    let name: String
    let localName: String
    let uri: String
    /// In name order: the parser reports them unordered.
    fileprivate(set) var attributes: [Attribute] = []
    fileprivate(set) var children: [XMLTreeElement] = []
    fileprivate var textParts: [String] = []
    init(name: String, localName: String, uri: String) { self.name = name; self.localName = localName; self.uri = uri }
    /// The element's own text: empty when it has child elements, as XMP reads it.
    var text: String { children.isEmpty ? textParts.joined() : "" }
    func attribute(_ name: String) -> String? { attributes.first { $0.name == name }?.value }
    func elements(localName: String, uri: String) -> [XMLTreeElement] { children.filter { $0.localName == localName && $0.uri == uri } }

    static let xmlNamespace = "http://www.w3.org/XML/1998/namespace"
    /// Deeper documents are refused while reading, so the tree is never deep enough to exhaust the stack.
    static let maxDepth = 256

    /// The root element. External entities are never loaded.
    static func parse(_ data: Data) throws -> XMLTreeElement {
        let parser = XMLParser(data: data)
        let builder = Builder()
        parser.delegate = builder
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = builder.root else {
            if builder.tooDeep { throw EditorError.invalidDocument(L10n.tr("XMP structures are too deeply nested.")) }
            throw EditorError.invalidDocument(L10n.tr("Empty XMP packet."))
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLTreeElement?
        var tooDeep = false
        private var stack: [XMLTreeElement] = []
        /// Prefix → URI declarations, one frame per open element; the parser reports them before the element they sit on.
        private var scopes: [[String: String]] = []
        private var pending: [String: String] = [:]
        private var text = ""

        func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) { pending[prefix] = namespaceURI }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            flushText()
            guard stack.count < XMLTreeElement.maxDepth else { tooDeep = true; parser.abortParsing(); return }
            scopes.append(pending); pending = [:]
            let element = XMLTreeElement(name: qualifiedName ?? elementName, localName: elementName, uri: namespaceURI ?? "")
            element.attributes = attributes.compactMap { name, value in
                guard name != "xmlns", !name.hasPrefix("xmlns:") else { return nil }
                let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
                let prefix = parts.count == 2 ? parts[0] : "", local = parts.last ?? name
                return Attribute(name: name, localName: local, uri: resolve(prefix) ?? "", value: value)
            }.sorted { $0.name < $1.name }
            if let parent = stack.last { parent.children.append(element) } else if root == nil { root = element }
            stack.append(element)
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            flushText()
            stack.removeLast(); scopes.removeLast()
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespaceString: String) { text += whitespaceString }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            flushText()
            stack.last?.textParts.append(String(decoding: CDATABlock, as: UTF8.self))
        }
        func parser(_ parser: XMLParser, foundComment comment: String) { flushText() }
        func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) { flushText() }
        /// One text node ends where markup begins; a node of only whitespace is dropped.
        private func flushText() {
            defer { text = "" }
            guard !text.isEmpty, text.contains(where: { !$0.isWhitespace }) else { return }
            stack.last?.textParts.append(text)
        }
        private func resolve(_ prefix: String) -> String? {
            if prefix == "xml" { return XMLTreeElement.xmlNamespace }
            return scopes.reversed().lazy.compactMap { $0[prefix] }.first
        }
    }
}

/// Writes an element tree as indented UTF-8 XML. Namespace declarations are attributes like any other here.
struct XMLWriter {
    final class Element {
        let name: String
        var attributes: [(String, String)] = []
        var text: String?
        var children: [Element] = []
        init(_ name: String, text: String? = nil) { self.name = name; self.text = text }
        func add(_ child: Element) { children.append(child) }
    }
    static func data(_ root: Element) -> Data {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        write(root, indent: 0, into: &out)
        return Data(out.utf8)
    }
    private static func write(_ element: Element, indent: Int, into out: inout String) {
        let pad = String(repeating: " ", count: indent * 4)
        out += pad + "<" + element.name
        for (name, value) in element.attributes { out += " " + name + "=\"" + escape(value, attribute: true) + "\"" }
        if element.children.isEmpty {
            if let text = element.text, !text.isEmpty { out += ">" + escape(text, attribute: false) + "</" + element.name + ">\n" }
            else { out += "></" + element.name + ">\n" }
            return
        }
        out += ">\n"
        for child in element.children { write(child, indent: indent + 1, into: &out) }
        out += pad + "</" + element.name + ">\n"
    }
    /// Line breaks and tabs in attributes are written as references so a reader's whitespace normalization keeps them.
    static func escape(_ text: String, attribute: Bool) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for character in text.unicodeScalars {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"" where attribute: out += "&quot;"
            case "\n" where attribute: out += "&#10;"
            case "\r": out += "&#13;"
            case "\t" where attribute: out += "&#9;"
            default: out.unicodeScalars.append(character)
            }
        }
        return out
    }
}
