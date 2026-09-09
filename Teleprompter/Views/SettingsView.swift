import SwiftUI
import TeleprompterCore

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("fontSize") private var fontSize: Double = 36
    @AppStorage("lineSpacing") private var lineSpacing: Double = 12
    @AppStorage("mirrorMode") private var mirrorMode = false
    @AppStorage("flipVertical") private var flipVertical = false
    @AppStorage("backgroundColor") private var backgroundColor = "black"
    @AppStorage("textColor") private var textColor = "white"
    @AppStorage("countdownDuration") private var countdownDuration = 3
    @AppStorage("scrollSpeed") private var scrollSpeed: Double = 1.0

    var body: some View {
        TabView {
            AppearanceSettings(
                fontSize: $fontSize,
                lineSpacing: $lineSpacing,
                mirrorMode: $mirrorMode,
                flipVertical: $flipVertical,
                backgroundColor: $backgroundColor,
                textColor: $textColor
            )
            .tabItem { Label("Appearance", systemImage: "paintbrush") }

            RecordingSettings(
                countdownDuration: $countdownDuration,
                scrollSpeed: $scrollSpeed
            )
            .tabItem { Label("Recording", systemImage: "record.circle") }

            KeyboardShortcutsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 500, height: 350)
    }
}

// MARK: - Appearance

struct AppearanceSettings: View {
    @Binding var fontSize: Double
    @Binding var lineSpacing: Double
    @Binding var mirrorMode: Bool
    @Binding var flipVertical: Bool
    @Binding var backgroundColor: String
    @Binding var textColor: String

    var body: some View {
        Form {
            Section("Typography") {
                HStack {
                    Text("Font Size")
                    Slider(value: $fontSize, in: 20...72, step: 2)
                    Text("\(Int(fontSize))pt")
                        .monospacedDigit()
                        .frame(width: 40)
                }

                HStack {
                    Text("Line Spacing")
                    Slider(value: $lineSpacing, in: 4...24, step: 2)
                    Text("\(Int(lineSpacing))pt")
                        .monospacedDigit()
                        .frame(width: 40)
                }
            }

            Section("Display") {
                Toggle("Mirror Mode (for beam-splitter)", isOn: $mirrorMode)
                Toggle("Flip Vertical", isOn: $flipVertical)
            }

            Section("Colors") {
                Picker("Background", selection: $backgroundColor) {
                    Text("Black").tag("black")
                    Text("Dark Gray").tag("darkGray")
                    Text("Navy").tag("navy")
                }

                Picker("Text Color", selection: $textColor) {
                    Text("White").tag("white")
                    Text("Light Gray").tag("lightGray")
                    Text("Cream").tag("cream")
                }
            }
        }
        .padding(20)
    }
}

// MARK: - Recording

struct RecordingSettings: View {
    @Binding var countdownDuration: Int
    @Binding var scrollSpeed: Double

    var body: some View {
        Form {
            Section("Countdown") {
                Picker("Duration", selection: $countdownDuration) {
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                    Text("Disabled").tag(0)
                }
            }

            Section("Scrolling") {
                HStack {
                    Text("Manual Scroll Speed")
                    Slider(value: $scrollSpeed, in: 0.5...3.0, step: 0.1)
                    Text("\(scrollSpeed, specifier: "%.1f")x")
                        .monospacedDigit()
                        .frame(width: 40)
                }
            }
        }
        .padding(20)
    }
}

// MARK: - Keyboard Shortcuts

struct KeyboardShortcutsView: View {
    var body: some View {
        Form {
            Section("Playback") {
                shortcutRow("Space", "Play / Pause")
                shortcutRow("R", "Recenter Tracking")
            }

            Section("Position") {
                shortcutRow("↑ / ↓", "Small adjustment")
                shortcutRow("Shift + ↑ / ↓", "Large adjustment")
            }

            Section("Recording") {
                shortcutRow("Cmd + Enter", "Start Recording")
                shortcutRow("Esc", "Stop Recording")
            }
        }
        .padding(20)
    }

    private func shortcutRow(_ key: String, _ action: String) -> some View {
        HStack {
            Text(action)
                .foregroundStyle(.primary)
            Spacer()
            Text(key)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        }
    }
}
