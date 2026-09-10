import SwiftUI
import UniformTypeIdentifiers
import TeleprompterCore

struct ScriptEditorView: View {
    @Environment(AppState.self) private var appState
    @State private var scriptText = ""
    @State private var showImportError = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            editorArea
        }
        .alert("Couldn't read file", isPresented: $showImportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("No readable text was found in that file. Try plain text, a text-based PDF, or a DOCX.")
        }
    }

    private var headerBar: some View {
        HStack {
            Text("Your Script")
                .font(.title2.weight(.medium))

            Spacer()

            Button("Import TXT") {
                importFile()
            }

            Button("Import DOCX") {
                importFile()
            }

            Button("Import PDF") {
                importFile()
            }

            Button("Paste from Clipboard") {
                pasteFromClipboard()
            }
            .keyboardShortcut("v", modifiers: .command)

            Divider()
                .frame(height: 20)

            Button("Format & Start") {
                Task {
                    await appState.loadScript(rawText: scriptText)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var editorArea: some View {
        TextEditor(text: $scriptText)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.visible)
            .padding(24)
            .overlay(alignment: .topLeading) {
                if scriptText.isEmpty {
                    Text("Paste your script here...")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 28)
                        .allowsHitTesting(false)
                }
            }
    }

    private func pasteFromClipboard() {
        #if os(macOS)
        if let string = NSPasteboard.general.string(forType: .string) {
            scriptText = string
        }
        #endif
    }

    private func importFile() {
        #if os(macOS)
        let panel = NSOpenPanel()
        var contentTypes: [UTType] = [.plainText, .pdf]
        if let docx = UTType(filenameExtension: "docx") {
            contentTypes.append(docx)
        }
        panel.allowedContentTypes = contentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                await importFile(at: url)
            }
        }
        #endif
    }

    private func importFile(at url: URL) async {
        guard let text = ScriptImporter.text(at: url) else {
            showImportError = true
            return
        }
        scriptText = text
    }
}
