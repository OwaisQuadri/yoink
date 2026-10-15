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
        if let bundled = Bundle.main.url(forResource: "ffmpeg", withExtension: nil) { return bundled }
        return URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
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
        let (data, response) = try await fetch(url, headers: media.headers, range: range, attempts: isProbe ? 1 : 3, timeout: isProbe ? 10 : 30)
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
        process: Process,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("yoink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let tracker = await ProgressTracker(onProgress: onProgress)

        let inputs: [String]
        switch media.kind {
        case .hls:
            let tracks = try await hlsTracks(media)
            await MainActor.run { tracker.total = tracks.reduce(0) { $0 + $1.segments.count } }
            var files: [String] = []
            for (index, track) in tracks.enumerated() {
                let file = work.appendingPathComponent("track\(index)")
                try await download(track, media: media, to: file, tracker: tracker)
                files.append(file.path)
            }
            inputs = files
        case .file:
            let track = try await fileTrack(media)
            await MainActor.run { tracker.total = track.segments.count }
            let file = work.appendingPathComponent("file")
            try await download(track, media: media, to: file, tracker: tracker)
            inputs = [file.path]
        case .dash:
            inputs = [media.url.absoluteString]
        }

        let partial = output.appendingPathExtension("part")
        defer { try? FileManager.default.removeItem(at: partial) }
        try await remux(inputs, headers: media.kind == .dash ? media.headers : [:], to: partial, process: process)
        try FileManager.default.moveItem(at: partial, to: output)
    }

    private static func hlsTracks(_ media: FoundMedia) async throws -> [HLSTrack] {
        let (data, _, _) = try await get(media, media.url)
        let text = String(decoding: data, as: UTF8.self)
        guard HLS.isMaster(text), let variant = HLS.pickVariant(text, base: media.url) else {
            return [try HLS.parseTrack(text, base: media.url)]
        }
        var tracks: [HLSTrack] = []
        for url in [variant.video, variant.audio].compactMap({ $0 }) {
            let (trackData, _, _) = try await get(media, url)
            tracks.append(try HLS.parseTrack(String(decoding: trackData, as: UTF8.self), base: url))
        }
        return tracks
    }

    private static func fileTrack(_ media: FoundMedia) async throws -> HLSTrack {
        let (_, total, isPartial) = try await get(media, media.url, range: 0..<1)
        guard isPartial, let size = total else {
            return HLSTrack(segments: [HLSSegment(url: media.url, duration: 0, byteRange: nil, keyURL: nil, iv: nil)])
        }
        let segments = stride(from: 0, to: size, by: chunkSize).map { start in
            HLSSegment(url: media.url, duration: 0, byteRange: start..<min(start + chunkSize, size), keyURL: nil, iv: nil)
        }
        return HLSTrack(segments: segments)
    }

    private static func download(_ track: HLSTrack, media: FoundMedia, to file: URL, tracker: ProgressTracker) async throws {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        if let initSegment = track.initSegment {
            try handle.write(contentsOf: try await get(media, initSegment.url, range: initSegment.byteRange).data)
        }
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
    }

    private static func remux(_ inputs: [String], headers: [String: String], to output: URL, process: Process) async throws {
        var arguments = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error"]
        if !headers.isEmpty {
            arguments += ["-user_agent", Sniffer.userAgent, "-headers", headers.map { "\($0.key): \($0.value)\r\n" }.joined()]
        }
        for input in inputs { arguments += ["-i", input] }
        arguments += ["-map", "0:v:0?"]
        arguments += inputs.count > 1 ? ["-map", "1:a:0?"] : ["-map", "0:a:0?"]
        arguments += ["-c", "copy", "-movflags", "+faststart", "-f", "mp4", output.path]
        process.executableURL = ffmpegURL
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let (status, message) = await Task.detached {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
        try Task.checkCancellation()
        guard status == 0 else {
            throw YoinkError.downloadFailed(message.split(separator: "\n").last.map(String.init) ?? "Couldn’t save the video")
        }
    }
}
