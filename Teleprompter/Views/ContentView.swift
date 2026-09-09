import SwiftUI
import TeleprompterCore

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            DetailView()
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            configureWindow()
        }
    }

    private func configureWindow() {
        #if os(macOS)
        NSApp.windows.forEach { window in
            window.titlebarAppearsTransparent = false
            window.toolbar?.isVisible = false
        }
        #endif
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("countdownDuration") private var countdownDuration = 3

    var body: some View {
        @Bindable var state = appState

        List {
            Section("Script") {
                if let script = appState.currentScript {
                    Text(script.title)
                        .font(.headline)

                    if let formatted = appState.formattedScript {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(formatted.wordCount) words")
                            Text("~\(Int(formatted.estimatedDuration / 60)) min read")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No script loaded")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Tracking") {
                HStack {
                    Circle()
                        .fill(statusColor(appState.trackingStatus))
                        .frame(width: 8, height: 8)
                    Text(statusLabel(appState.trackingStatus))
                        .font(.caption)
                }
            }

            Section("Controls") {
                Button("Paste Script") {
                    pasteFromClipboard()
                }

                if appState.currentScript != nil {
                    Button(appState.isRecording ? "Stop Recording" : "Start Recording") {
                        Task {
                            if appState.isRecording {
                                await appState.stopRecording()
                            } else {
                                await appState.beginRecording(withCountdown: countdownDuration)
                            }
                        }
                    }
                    .disabled(appState.countdownRemaining != nil)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Teleprompter")
    }

    private func pasteFromClipboard() {
        #if os(macOS)
        if let string = NSPasteboard.general.string(forType: .string) {
            Task {
                await appState.loadScript(rawText: string)
            }
        }
        #endif
    }

    private func statusColor(_ status: TrackingStatus) -> Color {
        switch status {
        case .tracking: return .green
        case .paused: return .gray
        case .manual: return .blue
        case .uncertain, .recovering: return .yellow
        case .degraded: return .red
        }
    }

    private func statusLabel(_ status: TrackingStatus) -> String {
        switch status {
        case .tracking: return "Tracking"
        case .paused: return "Paused"
        case .manual: return "Manual"
        case .uncertain: return "Uncertain"
        case .recovering: return "Recovering"
        case .degraded: return "Degraded"
        }
    }
}

// MARK: - Detail

struct DetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let formatted = appState.formattedScript {
            TeleprompterView(formattedScript: formatted)
        } else {
            ScriptEditorView()
        }
    }
}
