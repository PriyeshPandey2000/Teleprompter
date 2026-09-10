import Testing
import Foundation
@testable import Teleprompter

@Suite("Script Importer")
struct ScriptImporterTests {
    private func encoded(_ string: String, _ encoding: String.Encoding) -> Data {
        string.data(using: encoding) ?? Data()
    }

    // MARK: - Plain text decoding

    @Test("Decodes UTF-8 and strips its BOM")
    func utf8WithBOM() {
        var data = Data([0xEF, 0xBB, 0xBF]) // UTF-8 BOM
        data.append(encoded("Hello script", .utf8))
        #expect(ScriptImporter.decodeTextData(data) == "Hello script")
    }

    @Test("Decodes UTF-16 little-endian with BOM")
    func utf16LEWithBOM() {
        var data = Data([0xFF, 0xFE]) // UTF-16 LE BOM
        data.append(encoded("Hello script", .utf16LittleEndian))
        #expect(ScriptImporter.decodeTextData(data) == "Hello script")
    }

    @Test("Falls back to Latin-1 when bytes are not valid UTF-8")
    func latin1Fallback() {
        #expect(ScriptImporter.decodeTextData(encoded("Résumé", .isoLatin1)) == "Résumé")
    }

    @Test("Never returns mojibake for unreadable bytes")
    func rejectsGarbage() {
        // "Go" followed by an orphan continuation byte: the lenient UTF-8
        // decoder would emit U+FFFD. Any decoding path that yields it is
        // rejected rather than silently surfaced as script text.
        let data = Data([0x47, 0x6F, 0xC3, 0x28])
        let result = ScriptImporter.decodeTextData(data)
        #expect(result != nil)
        #expect(result?.contains("\u{FFFD}") != true)
    }

    // MARK: - DOCX XML extraction

    @Test("Extracts w:t text runs joined by paragraph breaks")
    func docxTextRuns() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p><w:r><w:t>We need to make sales now.</w:t></w:r></w:p>
            <w:p><w:r><w:t>This is the second line.</w:t></w:r></w:p>
          </w:body>
        </w:document>
        """
        let text = try #require(ScriptImporter.textFromDocumentXML(data: Data(xml.utf8)))
        #expect(text == "We need to make sales now.\nThis is the second line.")
    }

    @Test("Skips field-code markup like page numbers")
    func docxSkipsFieldCodes() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p><w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText> PAGE </w:instrText></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>
            <w:p><w:r><w:t>Body line</w:t></w:r></w:p>
          </w:body>
        </w:document>
        """
        let text = try #require(ScriptImporter.textFromDocumentXML(data: Data(xml.utf8)))
        #expect(text == "Body line")
    }

    @Test("Treats whitespace-only documents as unreadable")
    func docxEmptyReturnsNil() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body></w:body></w:document>
        """
        #expect(ScriptImporter.textFromDocumentXML(data: Data(xml.utf8)) == nil)
    }
}