import Foundation
import CryptoKit

/// Reads top-level RDF properties only. Nested Look and mask recipes are not global edits.
public struct XMPPacket: Sendable {
    public static let crs = "http://ns.adobe.com/camera-raw-settings/1.0/"
    public static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    public static let xmp = "http://ns.adobe.com/xap/1.0/"
    public static let dc = "http://purl.org/dc/elements/1.1/"
    public static let exif = "http://ns.adobe.com/exif/1.0/"
    public static let native = "https://chichou.me/ceviche/ns/edit/1.0/"
    public static let maxBytes = 32 * 1024 * 1024
    public let data: Data
    var scalars: [String: String] = [:]
    var arrays: [String: [String]] = [:]
    var structures = Set<String>()
    var nodes: [String:XMPElement] = [:]
    func node(_ name:String) -> XMPElement? {nodes[Self.key(Self.crs,name)]}
    static func key(_ namespace: String, _ name: String) -> String { namespace + "|" + name }
    /// What a preset says about itself, not what it develops.
    static let descriptors = Set(["Name", "ShortName", "SortName", "Group", "Description"].map { key(crs, $0) })
    public func value(_ name: String, namespace: String = Self.crs) -> String? { scalars[Self.key(namespace, name)] }
    /// A value from our own namespace.
    public func nativeValue(_ name: String) -> String? { value(name, namespace: Self.native) }
    func list(_ name: String, namespace: String = Self.crs) -> [String]? { arrays[Self.key(namespace, name)] }
    var crsNames: Set<String> {
        Set((Array(scalars.keys) + Array(arrays.keys) + Array(structures)).filter { $0.hasPrefix(Self.crs + "|") }.map { String($0.dropFirst(Self.crs.count + 1)) })
    }
    public init(data: Data) throws {
        // Decode UTF-16 before UTF-8: BOM-less UTF-16 ASCII can otherwise look like
        // valid UTF-8 with NULs, hiding declaration tokens from this check.
        let encoding: String.Encoding
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { encoding = .utf16 }
        else if data.starts(with: [0x3C, 0x00]) { encoding = .utf16LittleEndian }
        else if data.starts(with: [0x00, 0x3C]) { encoding = .utf16BigEndian }
        else { encoding = .utf8 }
        guard data.count <= Self.maxBytes, let text = String(data: data, encoding: encoding),
              !text.contains("\0"), !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else {
            throw EditorError.invalidDocument(L10n.tr("XMP must be UTF-8/UTF-16, at most 32 MB, and contain no DTD or entity declarations."))
        }
        self.data = data
        let root = try XMLTreeElement.parse(data)
        let rdf = root.localName == "RDF" && root.uri == Self.rdf ? root : root.elements(localName: "RDF", uri: Self.rdf).first
        guard let rdf else { throw EditorError.invalidDocument(L10n.tr("XMP requires an RDF document.")) }
        let descriptions = rdf.elements(localName: "Description", uri: Self.rdf)
        guard !descriptions.isEmpty else { throw EditorError.invalidDocument(L10n.tr("Missing XMP description.")) }
        for description in descriptions {
            for attribute in description.attributes {
                let uri = attribute.uri
                guard !uri.isEmpty, uri != Self.rdf else { continue }
                let key = Self.key(uri, attribute.localName)
                guard scalars[key] == nil && arrays[key] == nil && !structures.contains(key) else { throw EditorError.invalidDocument(L10n.tr("Duplicate XMP property: \(attribute.name)")) }
                scalars[key] = attribute.value
            }
            for child in description.children {
                let key = Self.key(child.uri, child.localName)
                // Some preset writers give the name both as an attribute and as an element; that is accepted when both say the same.
                let restated = arrays[key] == nil && !structures.contains(key) && scalars[key] != nil && Self.descriptors.contains(key)
                let attributeValue = restated ? scalars.removeValue(forKey: key) : nil
                guard scalars[key] == nil && arrays[key] == nil && !structures.contains(key) else { throw EditorError.invalidDocument(L10n.tr("Duplicate XMP property: \(child.name)")) }
                nodes[key] = try XMPElement(child)
                if let container = child.children.first, container.uri == Self.rdf, ["Seq", "Bag", "Alt"].contains(container.localName) {
                    let items = container.elements(localName: "li", uri: Self.rdf)
                    if items.allSatisfy({ $0.children.isEmpty && $0.attributes.allSatisfy { $0.name == "xml:lang" } }) {
                        arrays[key] = items.map(\.text)
                        if container.localName == "Alt" {
                            scalars[key] = (items.first { $0.attribute("xml:lang") == "x-default" } ?? items.first)?.text ?? ""
                        }
                    } else { structures.insert(key) }
                } else if child.children.isEmpty && child.attributes.isEmpty { scalars[key] = child.text }
                else { structures.insert(key) }
                if restated, scalars[key] != attributeValue || structures.contains(key) { throw EditorError.invalidDocument(L10n.tr("Duplicate XMP property: \(child.name)")) }
            }
        }
    }
    public init(url: URL) throws {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= Self.maxBytes else { throw EditorError.invalidDocument(L10n.tr("XMP exceeds 32 MB.")) }
        try self.init(data: Data(contentsOf: url))
    }
    /// Native recipes are trusted only while the portable fields remain unchanged by another editor.
    var portableDigest: String {
        let names = [Self.crs, Self.xmp, Self.dc, Self.exif, "http://ns.adobe.com/xmp/1.0/DynamicMedia/"]
        let relevant: (String) -> Bool = { key in names.contains { key.hasPrefix($0 + "|") } && !key.hasSuffix("|CreatorTool") && !key.hasSuffix("|ModifyDate") }
        struct Fields: Encodable { let scalars: [String: String]; let arrays: [String: [String]]; let structures: [String]; let structuredContent:[String:XMPElement]? }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try! encoder.encode(Fields(scalars: scalars.filter { relevant($0.key) }, arrays: arrays.filter { relevant($0.key) }, structures: structures.filter(relevant).sorted(), structuredContent: structures.isEmpty ? nil : nodes.filter{structures.contains($0.key) && relevant($0.key)}))
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    /// The two names a sidecar can have beside `image`: `photo.xmp` and `photo.ARW.xmp`.
    public static func sidecarNames(for image: URL) -> [URL] { [image.deletingPathExtension().appendingPathExtension("xmp"), image.appendingPathExtension("xmp")] }
    public static func sidecar(for image: URL) throws -> URL? {
        let names = [image.deletingPathExtension().lastPathComponent + ".xmp", image.lastPathComponent + ".xmp"].map { $0.lowercased() }
        let matches = try FileManager.default.contentsOfDirectory(at: image.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { names.contains($0.lastPathComponent.lowercased()) }
        guard matches.count <= 1 else { throw EditorError.invalidDocument(L10n.tr("Multiple matching XMP sidecars. Import the desired XMP explicitly.")) }
        return matches.first
    }
    public func originalURL(beside sidecar: URL) throws -> URL {
        let directory = sidecar.deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() != "xmp" && CatalogImporter.supported($0) }
        if let name = value("RawFileName"), !name.contains("/"), !name.contains("\\"), name != ".", name != ".." {
            let exact = files.filter { $0.lastPathComponent.lowercased() == name.lowercased() }
            if exact.count == 1 { return exact[0] }
        }
        let stem = sidecar.deletingPathExtension().lastPathComponent.lowercased()
        let matches = files.filter { $0.deletingPathExtension().lastPathComponent.lowercased() == stem || $0.lastPathComponent.lowercased() == stem }
        guard matches.count == 1 else { throw EditorError.invalidDocument(L10n.tr("Cannot uniquely match \(sidecar.lastPathComponent) to an image in the same folder.")) }
        return matches[0]
    }
}

public struct XMPImport: Sendable {
    public let adjustments: Adjustments
    public let metadata: CatalogMetadata
    public let sourceData: Data
    public let warnings: [String]
}

struct XMPNativeRecipe: Codable {
    var version = 5
    let adjustments: Adjustments
    let metadata: CatalogMetadata?
}
