import SwiftUI
import Sparkle

final class AppUpdater: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    @Published private(set) var isCheckForUpdatesEnabled = false
    @Published private(set) var isUpdateAvailable = false
    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .combineLatest(controller.updater.publisher(for: \.sessionInProgress))
            .map { isCheckAllowed, isSessionInProgress in isCheckAllowed && !isSessionInProgress }
            .assign(to: &$isCheckForUpdatesEnabled)
        controller.startUpdater()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus isInImmediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ isHandledByDriver: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        isUpdateAvailable = !isHandledByDriver
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        isUpdateAvailable = false
    }

    func standardUserDriverWillFinishUpdateSession() {
        isUpdateAvailable = false
    }
}

@main
struct YoinkApp: App {
    @State private var store = Store()
    @StateObject private var updater = AppUpdater()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Yoink", id: "main") {
            VStack(spacing: 0) {
                if updater.isUpdateAvailable {
                    HStack {
                        Text("A newer build is available")
                        Spacer()
                        Button("View Update…", action: updater.checkForUpdates)
                    }
                    .padding(12)
                    Divider()
                }
                ContentView()
            }
                .environment(store)
                .frame(minWidth: 520, minHeight: 360)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…", action: updater.checkForUpdates)
                    .disabled(!updater.isCheckForUpdatesEnabled)
            }
        }
    }
}

struct ContentView: View {
    @Environment(Store.self) private var store
    @State private var link = ""
    @State private var subtitleChoice = SubtitleChoice.default
    @State private var isShowingSubtitleOptions = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    TextField("Paste a video link", text: $link)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .onSubmit(submit)
                    Button {
                        isShowingSubtitleOptions.toggle()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .controlSize(.large)
                    .accessibilityLabel("Subtitle options")
                    .help("Subtitle options")
                    .popover(isPresented: $isShowingSubtitleOptions) {
                        subtitleOptions
                    }
                    Button("Download", action: submit)
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack {
                    Button {
                        store.pickFolder()
                    } label: {
                        Label(store.folder?.lastPathComponent ?? "Choose Folder", systemImage: "folder")
                    }
                    .buttonStyle(.link)
                    Spacer()
                }
            }
            .padding(16)

            Divider()

            if store.jobs.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle")
                    .frame(maxHeight: .infinity)
            } else {
                List(store.jobs) { job in
                    JobRow(job: job)
                }
                .listStyle(.inset)
            }

            SnifferHost(sniffer: store.sniffer)
                .frame(width: 1, height: 1)
                .clipped()
        }
        .onAppear(perform: pasteFromClipboard)
    }

    private var subtitleOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Original subtitles", isOn: $subtitleChoice.languages[isSelected: .original])
                .toggleStyle(.checkbox)
            Toggle("English subtitles", isOn: $subtitleChoice.languages[isSelected: .english])
                .toggleStyle(.checkbox)
            Toggle("Generate missing subtitles", isOn: $subtitleChoice.isGenerationEnabled)
                .toggleStyle(.switch)
                .disabled(subtitleChoice.languages.isEmpty)
        }
        .padding(16)
    }

    private func submit() {
        store.add(link, subtitleChoice: subtitleChoice)
        link = ""
    }

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              text.hasPrefix("http"), !text.contains(" ") else { return }
        link = text
    }
}

struct JobRow: View {
    @Environment(Store.self) private var store
    let job: Job

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(job.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if job.isActive, job.state != .waiting {
                    if let fraction = job.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                Text(status)
                    .font(.callout)
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
                    .help(status)
                if job.subtitles.contains(where: \.isReady) {
                    Text(job.subtitles.filter(\.isReady).map(\.title).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Choose a subtitle track or Off in your video player")
                }
            }
            Spacer()
            actions
        }
        .padding(.vertical, 6)
    }

    private var statusColor: Color {
        switch job.state {
        case .failed: .red
        case .saved(_, .some): .orange
        default: .secondary
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch job.state {
        case .saved(let file, _):
            Button("Play") { NSWorkspace.shared.open(file) }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("Show in Finder")
        case .failed, .cancelled:
            Button("Try Again") { store.retry(job) }
            Button {
                store.remove(job)
            } label: {
                Image(systemName: "xmark")
            }
            .help("Remove")
        case .stopping:
            EmptyView()
        case .finding:
            Button("Show Page") { store.sniffer.showPage() }
            Button {
                store.cancel(job)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Stop")
        default:
            Button {
                store.cancel(job)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Stop")
        }
    }

    private var status: String {
        switch job.state {
        case .waiting: return "Waiting"
        case .finding: return "Finding the video…"
        case .downloading:
            guard let fraction = job.fraction else { return "Starting download…" }
            let percent = "\(Int(fraction * 100))%"
            guard let left = job.secondsLeft else { return percent }
            return "\(percent) · \(Self.format(left)) left"
        case .subtitling(let phase):
            switch phase {
            case .inspecting: return "Preparing subtitle tracks…"
            case .transcribing(let fraction): return "Generating subtitles… \(Int(fraction * 100))%"
            case .translating(let fraction): return "Translating subtitles to English… \(Int(fraction * 100))%"
            case .muxing: return job.subtitles.contains(where: \.isReady) ? "Saving selectable subtitle tracks…" : "Saving video…"
            }
        case .saved(_, let warning):
            if let warning { return "Saved with subtitle warning. \(warning)" }
            return job.subtitles.contains(where: \.isReady) ? "Saved · Subtitles selectable in player" : "Saved"
        case .failed(let reason): return reason
        case .cancelled: return "Stopped"
        case .stopping: return "Stopping…"
        }
    }

    private static func format(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? ""
    }
}

struct SnifferHost: NSViewRepresentable {
    let sniffer: Sniffer

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        sniffer.attach(to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
