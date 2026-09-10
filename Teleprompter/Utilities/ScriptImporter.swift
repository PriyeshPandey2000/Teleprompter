import Foundation
import AppKit
import PDFKit

/// Extracts plain text from importable script files.
///
/// Before this existed, `importFile` decoded everything as UTF-8, which only
/// ever worked for `.txt`; binary formats like PDF/DOCX were either garble or
/// a silent no-op (nil decode path), and non-UTF-8 text (Word's UTF-16
/// exports, Latin-1 legacy files) decoded as replacement characters.
enum ScriptImporter {
    /// Returns the script text for a file, or nil when the file has no
    /// readable text (e.g. an image-only PDF).
    static func text(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        switch url.pathExtension.lowercased() {
        case "pdf":
            return pdfText(data: data)
        case "docx":
            return docxText(url: url)
        default:
            return decodeTextData(data)
        }
    }

    /// Decodes a plain-text file, honoring BOMs and common legacy encodings.
    /// UTF-8 is tried first; UTF-16 is attempted only when a BOM is present
    /// (endianness is then known); otherwise Latin-1 as a lossless fallback.
    static func decodeTextData(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8),
           !utf8.contains("\u{FFFD}") {
            return strippingBOM(utf8)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        }
        return String(data: data, encoding: .isoLatin1)
    }

    private static func strippingBOM(_ string: String) -> String {
        string.first == "\u{FEFF}" ? String(string.dropFirst()) : string
    }

    // MARK: - PDF

    /// Text via PDFKit. Native text PDFs extract cleanly; scanned/image-only
    /// PDFs yield nil regardless of what a raw byte decode would produce.
    private static func pdfText(data: Data) -> String? {
        guard let document = PDFDocument(data: data) else { return nil }
        let text = document.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }

    // MARK: - DOCX

    /// A DOCX is a ZIP whose body is `word/document.xml`. macOS ships `unzip`,
    /// so extraction needs no third-party dependency; the XML then yields the
    /// text via XMLParser (`w:t` runs, `w:p` paragraph breaks).
    private static func docxText(url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, "word/document.xml"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Drain the pipe BEFORE waiting for exit. unzip writes into a
            // finite pipe buffer; if a large document.xml fills it, unzip
            // blocks writing until someone reads, and waitUntilExit() would
            // deadlock the import forever (no text, no error alert).
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return textFromDocumentXML(data: data)
        } catch {
            return nil
        }
    }

    /// Extracts the visible text from a DOCX `document.xml` payload.
    static func textFromDocumentXML(data: Data) -> String? {
        let parser = XMLParser(data: data)
        let delegate = DocXMLDelegate()
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        let text = delegate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

private final class DocXMLDelegate: NSObject, XMLParserDelegate {
    private(set) var text = ""
    private var inTextElement = false

    /// Foundation reports namespaced elements as `w:t` rather than local `t`;
    /// strip any prefix so the cases below match on the local name.
    private func localName(_ qName: String) -> String {
        guard let colon = qName.lastIndex(of: ":") else { return qName }
        return String(qName[qName.index(after: colon)...])
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch localName(elementName) {
        case "t", "instrText":
            // `instrText` is field-code markup (e.g. page numbers); skip it so
            // invisible metadata never becomes part of the script.
            inTextElement = localName(elementName) == "t"
        case "p":
            if !text.isEmpty, !text.hasSuffix("\n") {
                text += "\n"
            }
        case "tab":
            text += " "
        case "br":
            text += "\n"
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTextElement {
            text += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if localName(elementName) == "t" || localName(elementName) == "instrText" {
            inTextElement = false
        }
    }
}