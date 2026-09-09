import SwiftUI
import TeleprompterCore

struct ScriptEditorView: View {
    @Environment(AppState.self) private var appState
    @State private var scriptText = ""

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            editorArea
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
        panel.allowedContentTypes = [.plainText, .pdf]
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
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }
        scriptText = text
    }
}
