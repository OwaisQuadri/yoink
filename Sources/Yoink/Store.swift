import AppKit
import Observation

@MainActor
@Observable
final class Job: Identifiable {
    enum State: Equatable {
        case waiting
        case finding
        case downloading
        case subtitling(SubtitlePhase)
        case saved(URL, warning: String?)
        case failed(String)
        case stopping
        case cancelled
    }

    let id = UUID()
    let pageURL: URL
    let subtitleChoice: SubtitleChoice
    var title: String
    var state: State = .waiting
    var fraction: Double?
    var secondsLeft: Double?
    var subtitles: [SubtitleTrack] = []
    @ObservationIgnored var task: Task<Void, Never>?

    init(pageURL: URL, subtitleChoice: SubtitleChoice = .default) {
        self.subtitleChoice = subtitleChoice
        self.pageURL = pageURL
        title = pageURL.host ?? pageURL.absoluteString
    }

    var isActive: Bool {
        switch state {
        case .waiting, .finding, .downloading, .subtitling, .stopping: true
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
        sniffer.onPageClosed = { [weak self] in
            guard let self, let job = jobs.first(where: { $0.state == .finding }) else { return }
            cancel(job)
        }
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

    func add(_ text: String, subtitleChoice: SubtitleChoice = .default) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)"), url.host != nil else { return }
        if folder == nil, pickFolder() == nil { return }
        jobs.insert(Job(pageURL: url, subtitleChoice: subtitleChoice), at: 0)
        startNext()
    }

    func cancel(_ job: Job) {
        guard job.isActive else { return }
        job.state = job.task == nil ? .cancelled : .stopping
        job.task?.cancel()
    }

    func retry(_ job: Job) {
        job.state = .waiting
        job.fraction = nil
        job.secondsLeft = nil
        job.subtitles = []
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
            defer {
                job.task = nil
                if job.state == .stopping { job.state = .cancelled }
            }
            let media: FoundMedia
            do {
                media = try await sniffer.find(job.pageURL)
            } catch {
                if job.state == .finding { job.state = .failed(error.localizedDescription) }
                releaseSniffer()
                return
            }
            if media.fetcher == nil { releaseSniffer() }
            if job.state == .finding {
                job.title = media.title
                job.state = .downloading
                await download(job, media: media, folder: folder)
            } else if media.fetcher != nil {
                releaseSniffer()
            }
        }
    }

    private func releaseSniffer() {
        sniffer.reset()
        isFinding = false
        startNext()
    }

    private func download(_ job: Job, media: FoundMedia, folder: URL) async {
        let output = Self.freeURL(in: folder, name: media.title)
        let started = Date()
        do {
            let warning = try await Downloader.save(media, to: output, subtitleChoice: job.subtitleChoice, onAcquired: {
                if media.fetcher != nil { self.releaseSniffer() }
            }, onSubtitles: { phase, tracks in
                if job.state != .cancelled, job.state != .stopping {
                    job.state = .subtitling(phase)
                    job.subtitles = tracks
                    job.fraction = nil
                    job.secondsLeft = nil
                }
            }) { fraction in
                job.fraction = fraction
                let elapsed = Date().timeIntervalSince(started)
                job.secondsLeft = fraction > 0.01 ? elapsed / fraction - elapsed : nil
            }
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: output)
                throw CancellationError()
            }
            job.state = .saved(output, warning: warning)
        } catch {
            log.error("download failed \(job.pageURL.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)")
            if job.state != .cancelled, job.state != .stopping { job.state = .failed(error.localizedDescription) }
        }
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
