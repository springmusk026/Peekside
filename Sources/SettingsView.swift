import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject private var recorder: Recorder
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var copied = false

    private var linkCommand: String {
        let binary = Bundle.main.executableURL?.path ?? "/Applications/Peekside.app/Contents/MacOS/Peekside"
        let bin = FileManager.default.isWritableFile(atPath: "/opt/homebrew/bin") ? "/opt/homebrew/bin" : "/usr/local/bin"
        return "ln -sf '\(binary)' \(bin)/peekside"
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $launchAtLogin) {
                    Text("Launch at login")
                    Text("Peekside only records while it's running.")
                }
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
                Toggle(isOn: $recorder.alerts) {
                    Text("Notify me about red flags")
                    Text("An app using the mic or camera while your Mac is locked, for the first time, or with no window; or a new app reading your keystrokes.")
                }
                .onChange(of: recorder.alerts) { _, on in if on { Recorder.requestNotifications() } }
            }

            Section {
                LabeledContent("History", value: "30 days, on this Mac only")
                LabeledContent("Watching since", value: "\(fmtDay(recorder.since)) \(fmtTime(recorder.since))")
                Button("Show History File in Finder") {
                    NSWorkspace.shared.selectFile(Recorder.folder.appendingPathComponent("history.json").path, inFileViewerRootedAtPath: "")
                }
            } footer: {
                Text("macOS doesn't report which app uses the camera, so Peekside names the likeliest one and marks it “Likely”. It can't see screen recording.")
                    .foregroundStyle(.secondary)
            }

            Section("Command line") {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Add `peekside` to your PATH to read your history from Terminal:")
                    HStack {
                        Text(linkCommand)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer()
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(linkCommand, forType: .string)
                            copied = true
                            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                        }
                    }
                    Text("Then try `peekside`, `peekside now` or `peekside --days 7`.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Version", value: CLI.version)
                LabeledContent("Source") {
                    Link("github.com/springmusk026/Peekside", destination: URL(string: "https://github.com/springmusk026/Peekside")!)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
