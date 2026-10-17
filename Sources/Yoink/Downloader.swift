import Foundation

@MainActor
final class ProgressTracker {
    private let onProgress: @MainActor (Double) -> Void
    private var done = 0
    var total = 0

    init(onProgress: @escaping @MainActor (Double) -> Void) {
        self.onProgress = onProgress
    }

    func advance() {
        done += 1
        if total > 0 { onProgress(min(Double(done) / Double(total), 1)) }
    }
}

enum Downloader {
    private static let chunkSize = 5 << 20

    static var ffmpegURL: URL {
        MediaCommand.tool("ffmpeg")
    }

    static func fetch(_ url: URL, headers: [String: String], range: Range<Int>? = nil, attempts: Int = 3, timeout: TimeInterval = 30) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(Sniffer.userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range") }
        var lastError: Error = YoinkError.downloadFailed("Download failed")
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            if attempt > 0 { try await Task.sleep(for: .seconds(attempt)) }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    lastError = YoinkError.downloadFailed("The video server refused the request")
                    continue
                }
                return (data, http)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    static func get(_ media: FoundMedia, _ url: URL, range: Range<Int>? = nil, isProbe: Bool = false) async throws -> (data: Data, total: Int?, isPartial: Bool) {
        if let fetcher = media.fetcher {
            var lastError: Error = YoinkError.downloadFailed("Download failed")
            for attempt in 0..<(isProbe ? 1 : 3) {
                try Task.checkCancellation()
                if attempt > 0 { try await Task.sleep(for: .seconds(attempt)) }
                do { return try await fetcher.fetch(url, range: range, timeout: isProbe ? 10 : 120) } catch { lastError = error }
            }
            throw lastError
        }
        let (data, response) = try await fetch(url, headers: media.requestHeaders(for: url), range: range, attempts: isProbe ? 1 : 3, timeout: isProbe ? 10 : 30)
        let total = (response.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last).flatMap { Int($0) }
        return (data, total, response.statusCode == 206)
    }

    static func probe(_ media: FoundMedia) async throws {
        switch media.kind {
        case .hls:
            let (data, _, _) = try await get(media, media.url, isProbe: true)
            let text = String(decoding: data, as: UTF8.self)
            guard text.hasPrefix("#EXTM3U") else { throw YoinkError.noVideo }
            var track = try HLS.parseTrack(text, base: media.url)
            if HLS.isMaster(text), let variant = HLS.pickVariant(text, base: media.url) {
                let (variantData, _, _) = try await get(media, variant.video, isProbe: true)
                track = try HLS.parseTrack(String(decoding: variantData, as: UTF8.self), base: variant.video)
            }
            guard let first = track.segments.first else { throw YoinkError.noVideo }
            _ = try await get(media, first.url, range: first.byteRange ?? 0..<2, isProbe: true)
        case .file:
            let (data, _, _) = try await get(media, media.url, range: 0..<16, isProbe: true)
            guard let first = data.first, ![UInt8(ascii: "{"), UInt8(ascii: "["), UInt8(ascii: "<")].contains(first) else { throw YoinkError.noVideo }
        case .dash:
            _ = try await get(media, media.url, isProbe: true)
        }
    }

    static func save(
        _ media: FoundMedia,
        to output: URL,
        onAcquired: @escaping @MainActor () -> Void,
        onSubtitles: @escaping @MainActor (SubtitlePhase, [SubtitleTrack]) -> Void,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws -> String? {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("yoink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let tracker = await ProgressTracker(onProgress: onProgress)

        let staged: URL
        let sourceTracks: [SubtitleTrack]
        do {
            (staged, sourceTracks) = try await acquire(media, work: work, tracker: tracker)
            await onAcquired()
        } catch {
            await onAcquired()
            throw error
        }
        let outcome = try await SubtitlePipeline.complete(video: staged, work: work, sourceTracks: sourceTracks, onUpdate: onSubtitles)
        var warning = outcome.warning
        let partial = output.appendingPathExtension("part")
        defer { try? FileManager.default.removeItem(at: partial) }
        do {
            try await SubtitlePipeline.mux(video: staged, tracks: outcome.readyTracks, to: partial)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard !outcome.readyTracks.isEmpty else { throw error }
            try await SubtitlePipeline.mux(video: staged, tracks: [], to: partial)
            var tracks = outcome.tracks
            for index in tracks.indices where tracks[index].isReady { tracks[index].state = .failed("Couldn’t embed the subtitle track") }
            warning = SubtitleOutcome(tracks: tracks).warning
            await onSubtitles(.muxing, tracks)
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: partial, to: output)
        return warning
    }

    private static func acquire(_ media: FoundMedia, work: URL, tracker: ProgressTracker) async throws -> (URL, [SubtitleTrack]) {
        let inputs: [String]
        var subtitles = media.subtitles
        var timeline = TransportTimeline.available([])
        switch media.kind {
        case .hls:
            let (tracks, renditions) = try await hlsTracks(media)
            subtitles += renditions
            await MainActor.run { tracker.total = tracks.reduce(0) { $0 + $1.segments.count } }
            var files: [String] = []
            for (index, track) in tracks.enumerated() {
                let file = work.appendingPathComponent("track\(index)")
                let downloadedTimeline = try await download(track, media: media, to: file, tracker: tracker, isVideo: index == 0)
                if index == 0 { timeline = downloadedTimeline }
                files.append(file.path)
            }
            inputs = files
        case .file:
            let track = try await fileTrack(media)
            await MainActor.run { tracker.total = track.segments.count }
            let file = work.appendingPathComponent("file")
            _ = try await download(track, media: media, to: file, tracker: tracker)
            inputs = [file.path]
        case .dash:
            inputs = [media.url.absoluteString]
        }
        var sourceTracks: [SubtitleTrack] = []
        for input in inputs {
            do {
                sourceTracks += try await SubtitlePipeline.extractSources(input: input, headers: media.kind == .dash ? media.headers : [:], work: work)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                sourceTracks.append(SubtitleTrack(language: "und", source: .embedded, state: .failed("Couldn’t inspect source captions")))
            }
        }
        let staged = work.appendingPathComponent("video.mkv")
        try await remux(inputs, audioInput: inputs.count > 1 ? 1 : 0, headers: media.kind == .dash ? media.headers : [:], to: staged)
        let stagedInventory = try await MediaInventory.read(staged)
        let videoStart = stagedInventory.streams.first { $0.codec_type == "video" }?.start_time.flatMap(Double.init) ?? 0
        let formatStart = stagedInventory.format.start_time.flatMap(Double.init) ?? 0
        let presentationShift: Int
        do {
            presentationShift = try SubtitleTime.milliseconds(videoStart - formatStart)
        } catch {
            timeline = .unavailable(error.localizedDescription)
            presentationShift = 0
        }
        var seen = Set<URL>()
        for remote in subtitles where seen.insert(remote.url).inserted {
            do {
                sourceTracks.append(try await WebCaptions.download(remote, media: media, work: work, timeline: timeline, presentationShift: presentationShift))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                sourceTracks.append(SubtitleTrack(language: remote.language, source: .web, state: .failed("Couldn’t download source captions")))
            }
        }
        return (staged, sourceTracks)
    }

    private static func hlsTracks(_ media: FoundMedia) async throws -> ([HLSTrack], [RemoteSubtitle]) {
        let (data, _, _) = try await get(media, media.url)
        let text = String(decoding: data, as: UTF8.self)
        guard HLS.isMaster(text), let variant = HLS.pickVariant(text, base: media.url) else {
            return ([try HLS.parseTrack(text, base: media.url)], [])
        }
        var tracks: [HLSTrack] = []
        for url in [variant.video, variant.audio].compactMap({ $0 }) {
            let (trackData, _, _) = try await get(media, url)
            tracks.append(try HLS.parseTrack(String(decoding: trackData, as: UTF8.self), base: url))
        }
        return (tracks, variant.subtitles)
    }

    static func fileTrack(_ media: FoundMedia) async throws -> HLSTrack {
        let (_, total, isPartial) = try await get(media, media.url, range: 0..<16)
        guard isPartial, let size = total else {
            return HLSTrack(segments: [HLSSegment(url: media.url, duration: 0, byteRange: nil, keyURL: nil, iv: nil)])
        }
        let segments = stride(from: 0, to: size, by: chunkSize).map { start in
            HLSSegment(url: media.url, duration: 0, byteRange: start..<min(start + chunkSize, size), keyURL: nil, iv: nil)
        }
        return HLSTrack(segments: segments)
    }

    private static func download(_ track: HLSTrack, media: FoundMedia, to file: URL, tracker: ProgressTracker, isVideo: Bool = false) async throws -> TransportTimeline {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var initialization = Data()
        if let initSegment = track.initSegment {
            initialization = try await get(media, initSegment.url, range: initSegment.byteRange).data
            try handle.write(contentsOf: initialization)
        }
        var timeline = TransportTimeline.available([])
        var elapsed = 0
        var keys: [URL: Data] = [:]
        for url in Set(track.segments.compactMap(\.keyURL)) {
            keys[url] = try await get(media, url).data
        }
        let keyTable = keys
        let segments = track.segments

        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var nextStart = 0
            var nextWrite = 0
            var pending: [Int: Data] = [:]
            func start(_ index: Int) {
                let segment = segments[index]
                group.addTask {
                    var data = try await get(media, segment.url, range: segment.byteRange).data
                    if let keyURL = segment.keyURL, let key = keyTable[keyURL], let iv = segment.iv {
                        data = try HLS.decrypt(data, key: key, iv: iv)
                    }
                    return (index, data)
                }
            }
            let parallelRequests = media.fetcher == nil ? 8 : 4
            while nextStart < min(parallelRequests, segments.count) {
                start(nextStart)
                nextStart += 1
            }
            for try await (index, data) in group {
                pending[index] = data
                while let ready = pending.removeValue(forKey: nextWrite) {
                    if isVideo, case .available(var epochs) = timeline {
                        do {
                            let duration = try SubtitleTime.duration(segments[nextWrite].duration)
                            let nextElapsed = try SubtitleTime.add(elapsed, duration)
                            if nextWrite == 0 || segments[nextWrite].isDiscontinuity {
                                let probe = file.appendingPathExtension("epoch")
                                defer { try? FileManager.default.removeItem(at: probe) }
                                try (initialization + ready).write(to: probe)
                                let inventory = try await MediaInventory.read(probe)
                                guard let start = inventory.streams.first(where: { $0.codec_type == "video" })?.start_time.flatMap(Double.init) else {
                                    throw YoinkError.downloadFailed("Couldn’t align HLS subtitle timestamps")
                                }
                                epochs.append(TransportEpoch(start: elapsed, transportStart: try SubtitleTime.milliseconds(start)))
                            }
                            timeline = .available(epochs)
                            elapsed = nextElapsed
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            timeline = .unavailable(error.localizedDescription)
                        }
                    }
                    try handle.write(contentsOf: ready)
                    nextWrite += 1
                }
                await tracker.advance()
                if nextStart < segments.count {
                    start(nextStart)
                    nextStart += 1
                }
            }
        }
        return timeline
    }

    private static func remux(_ inputs: [String], audioInput: Int, headers: [String: String], to output: URL) async throws {
        var arguments = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error"]
        for input in inputs {
            if !headers.isEmpty {
                arguments += ["-user_agent", Sniffer.userAgent, "-headers", headers.map { "\($0.key): \($0.value)\r\n" }.joined()]
            }
            arguments += ["-i", input]
        }
        arguments += ["-map", "0:v:0?", "-map", "\(audioInput):a:0?"]
        arguments += ["-c", "copy", "-f", "matroska", output.path]
        _ = try await MediaCommand.run(ffmpegURL, arguments)
    }
}
