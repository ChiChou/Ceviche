import XCTest
@testable import CevicheCore

/// The XML reader and writer XMP uses on every platform, in place of macOS's `XMLDocument`.
final class XMLTreeTests: XCTestCase {
    func testNamespacesResolveThroughScopes() throws {
        let root = try XMLTreeElement.parse(Data("""
        <r xmlns="urn:default" xmlns:p="urn:a" p:x="1" plain="2" xml:lang="en"><p:c xmlns:p="urn:b" p:y="3"/></r>
        """.utf8))
        XCTAssertEqual(root.uri, "urn:default")
        XCTAssertEqual(root.attributes.map(\.name), ["p:x", "plain", "xml:lang"])
        XCTAssertEqual(root.attributes.map(\.uri), ["urn:a", "urn:default", XMLTreeElement.xmlNamespace])
        XCTAssertEqual(root.children[0].uri, "urn:b")
        XCTAssertEqual(root.children[0].attributes.first?.uri, "urn:b")
    }

    func testTextReadsAsXMLDocumentDoes() throws {
        let root = try XMLTreeElement.parse(Data("""
        <r>
            <blank>   </blank>
            <kept> a &amp; b&#10;</kept>
            <cdata><![CDATA[<x>]]></cdata>
            <mixed>text<child/>tail</mixed>
        </r>
        """.utf8))
        XCTAssertEqual(root.text, "")
        XCTAssertEqual(root.children.map(\.text), ["", " a & b\n", "<x>", ""])
    }

    func testWriterRoundTripsEscapes() throws {
        let root = XMLWriter.Element("p:r"); root.attributes = [("xmlns:p", "urn:p"), ("p:v", "a\nb\t\"<&>")]
        root.add(XMLWriter.Element("p:c", text: "1 < 2 & \"3\"\n"))
        let parsed = try XMLTreeElement.parse(XMLWriter.data(root))
        XCTAssertEqual(parsed.attribute("p:v"), "a\nb\t\"<&>")
        XCTAssertEqual(parsed.children[0].text, "1 < 2 & \"3\"\n")
        XCTAssertEqual(parsed.children[0].uri, "urn:p")
    }

    func testDeepDocumentsAreRefused() {
        let depth = XMLTreeElement.maxDepth + 1
        let xml = String(repeating: "<a>", count: depth) + String(repeating: "</a>", count: depth)
        XCTAssertThrowsError(try XMLTreeElement.parse(Data(xml.utf8)))
    }

    func testMalformedDocumentsAreRefused() {
        XCTAssertThrowsError(try XMLTreeElement.parse(Data("<a><b></a>".utf8)))
        XCTAssertThrowsError(try XMLTreeElement.parse(Data()))
    }
}
