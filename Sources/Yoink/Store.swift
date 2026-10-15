import AppKit
import Observation

@MainActor
@Observable
final class Job: Identifiable {
    enum State: Equatable {
        case waiting
        case finding
        case downloading
        case saved(URL)
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let pageURL: URL
    var title: String
    var state: State = .waiting
    var fraction: Double?
    var secondsLeft: Double?
    @ObservationIgnored var process: Process?
    @ObservationIgnored var task: Task<Void, Never>?

    init(pageURL: URL) {
        self.pageURL = pageURL
        title = pageURL.host ?? pageURL.absoluteString
    }

    var isActive: Bool {
        switch state {
        case .waiting, .finding, .downloading: true
        default: false
        }
    }
}

@MainActor
@Observable
final class Store {
    var jobs: [Job] = []
    var folder: URL? {
        didSet { UserDefaults.standard.set(folder?.path, forKey: "folder") }
    }
    @ObservationIgnored let sniffer = Sniffer()
    @ObservationIgnored private var isFinding = false

    init() {
        folder = UserDefaults.standard.string(forKey: "folder").map { URL(fileURLWithPath: $0) }
    }

    @discardableResult
    func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.directoryURL = folder
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        folder = url
        return url
    }

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)"), url.host != nil else { return }
        if folder == nil, pickFolder() == nil { return }
        jobs.insert(Job(pageURL: url), at: 0)
        startNext()
    }

    func cancel(_ job: Job) {
        job.state = .cancelled
        job.task?.cancel()
        job.process?.terminate()
    }

    func retry(_ job: Job) {
        job.state = .waiting
        job.fraction = nil
        job.secondsLeft = nil
        startNext()
    }

    func remove(_ job: Job) {
        jobs.removeAll { $0.id == job.id }
    }

    private func startNext() {
        guard !isFinding, let job = jobs.last(where: { $0.state == .waiting }), let folder else { return }
        isFinding = true
        job.state = .finding
        job.task = Task {
            let media: FoundMedia
            do {
                media = try await sniffer.find(job.pageURL)
            } catch {
                isFinding = false
                if job.state == .finding { job.state = .failed(error.localizedDescription) }
                startNext()
                return
            }
            isFinding = false
            startNext()
            guard job.state == .finding else { return }
            job.title = media.title
            job.state = .downloading
            await download(job, media: media, folder: folder)
        }
    }

    private func download(_ job: Job, media: FoundMedia, folder: URL) async {
        let output = Self.freeURL(in: folder, name: media.title)
        let process = Process()
        job.process = process
        let started = Date()
        do {
            try await Downloader.save(media, to: output, process: process) { seconds, duration in
                guard let duration, duration > 0 else { return }
                let fraction = min(seconds / duration, 1)
                job.fraction = fraction
                let elapsed = Date().timeIntervalSince(started)
                job.secondsLeft = fraction > 0.01 ? elapsed / fraction - elapsed : nil
            }
            job.state = .saved(output)
        } catch {
            if job.state != .cancelled { job.state = .failed(error.localizedDescription) }
        }
        job.process = nil
    }

    private static func freeURL(in folder: URL, name: String) -> URL {
        var candidate = folder.appendingPathComponent("\(name).mp4")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name) (\(counter)).mp4")
            counter += 1
        }
        return candidate
    }
}
