import Foundation

struct MediaInventory: Decodable {
    struct Stream: Decodable {
        struct Disposition: Decodable { let forced: Int? }
        let index: Int
        let codec_type: String
        let codec_name: String?
        let tags: [String: String]?
        let disposition: Disposition?
        let start_time: String?
    }
    struct Format: Decodable { let duration: String?; let start_time: String? }
    let streams: [Stream]
    let format: Format

    static func headerArguments(_ headers: [String: String]) -> [String] {
        headers.isEmpty ? [] : ["-user_agent", Sniffer.userAgent, "-headers", headers.map { "\($0.key): \($0.value)\r\n" }.joined()]
    }

    static func read(_ url: URL) async throws -> MediaInventory {
        try await read(url.path, headers: [:])
    }

    static func read(_ input: String, headers: [String: String]) async throws -> MediaInventory {
        let data = try await MediaCommand.run(MediaCommand.tool("ffprobe"), ["-v", "error"] + headerArguments(headers) + ["-show_streams", "-show_format", "-of", "json", input])
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

struct RemoteSubtitle: Equatable {
    let url: URL
    let language: String
    var isForced = false
}

enum SubtitlePhase: Equatable {
    case inspecting
    case transcribing(Double)
    case translating(Double)
    case muxing
}

actor InferenceQueue {
    static let shared = InferenceQueue()
    private var isBusy = false

    func acquire() async throws {
        while isBusy {
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        isBusy = true
    }

    func release() { isBusy = false }
}

enum SubtitlePipeline {
    typealias Recognizer = (URL, URL, Double, Double, String, Bool) async throws -> WhisperResult

    static var modelURL: URL {
        Bundle.main.url(forResource: "ggml-base", withExtension: "bin")
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("vendor/whisper/ggml-base.bin")
    }

    static var whisperURL: URL {
        Bundle.main.url(forResource: "whisper-cli", withExtension: nil)
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("vendor/whisper/whisper-cli")
    }

    static func extractSources(input: String, headers: [String: String], work: URL) async throws -> [SubtitleTrack] {
        let inventory = try await MediaInventory.read(input, headers: headers)
        var tracks: [SubtitleTrack] = []
        for stream in inventory.streams where stream.codec_type == "subtitle" {
            let file = work.appendingPathComponent("source-\(UUID().uuidString).srt")
            var track = SubtitleTrack(language: SubtitleLanguage.canonical(stream.tags?["language"]), source: .embedded)
            track.coverage = stream.disposition?.forced == 1 ? .forced : .full
            do {
                _ = try await MediaCommand.run(Downloader.ffmpegURL, ["-v", "error", "-nostdin", "-y"] + MediaInventory.headerArguments(headers) + ["-i", input, "-map", "0:\(stream.index)", file.path])
                guard (try String(contentsOf: file, encoding: .utf8)).contains(" --> ") else {
                    throw YoinkError.downloadFailed("The source caption track is empty")
                }
                track.state = .ready(file)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                track.state = .failed("Source captions could not be read as text")
            }
            tracks.append(track)
        }
        return tracks
    }

    static func complete(
        video: URL, work: URL, sourceTracks: [SubtitleTrack],
        onUpdate: @escaping @MainActor (SubtitlePhase, [SubtitleTrack]) -> Void
    ) async throws -> SubtitleOutcome {
        var tracks = sourceTracks
        var language = "und"
        await onUpdate(.inspecting, tracks)
        do {
            let inventory = try await MediaInventory.read(video)
            tracks += try await extractSources(input: video.path, headers: [:], work: work)
            guard let audio = inventory.streams.first(where: { $0.codec_type == "audio" }) else {
                throw YoinkError.downloadFailed("This video has no audio to generate subtitles from")
            }
            guard let duration = inventory.format.duration.flatMap(Double.init), duration.isFinite, duration > 0 else {
                throw YoinkError.downloadFailed("Couldn’t determine the audio duration for subtitles")
            }
            language = SubtitleLanguage.canonical(audio.tags?["language"])
            let existingLanguages = Set(tracks.filter { $0.coverage == .full && $0.isReady }.map(\.language))
            if language != "und", language != "unknown", existingLanguages.contains(language), existingLanguages.contains("en") {
                await onUpdate(.muxing, tracks)
                return SubtitleOutcome(tracks: tracks)
            }
            await onUpdate(.transcribing(0), tracks)
            try await InferenceQueue.shared.acquire()
            do {
                try await generate(video: video, work: work, duration: duration, language: &language, tracks: &tracks, onUpdate: onUpdate)
                await InferenceQueue.shared.release()
            } catch {
                await InferenceQueue.shared.release()
                throw error
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            for index in tracks.indices where !tracks[index].isReady {
                if case .failed = tracks[index].state { continue }
                tracks[index].state = .failed(error.localizedDescription)
            }
            let required: [(String, SubtitleTrack.Source)] = language == "en" ? [("en", .transcribed)] : [(language, .transcribed), ("en", .translated)]
            for (target, source) in required where !tracks.contains(where: { $0.language == target && $0.coverage == .full && $0.isReady }) {
                if !tracks.contains(where: { $0.source == source && $0.language == target }) {
                    tracks.append(SubtitleTrack(language: target, source: source, state: .failed(error.localizedDescription)))
                }
            }
        }
        await onUpdate(.muxing, tracks)
        return SubtitleOutcome(tracks: tracks)
    }

    static func generate(
        video: URL, work: URL, duration: Double, language: inout String, tracks: inout [SubtitleTrack],
        onUpdate: @escaping @MainActor (SubtitlePhase, [SubtitleTrack]) -> Void,
        recognizer: Recognizer = recognize
    ) async throws {
        let chunkDuration = 300.0
        var firstResult: WhisperResult?
        if language == "und" || language == "unknown" {
            for offset in stride(from: 0.0, to: duration, by: chunkDuration) {
                await onUpdate(.transcribing(offset / duration), tracks)
                let result = try await recognizer(video, work, offset, min(chunkDuration, duration - offset), "auto", false)
                let detected = SubtitleLanguage.canonical(result.result.language)
                if detected != "und", detected != "unknown", !result.transcription.isEmpty {
                    language = detected
                    if offset == 0 { firstResult = result }
                    break
                }
            }
            guard language != "und", language != "unknown" else {
                throw YoinkError.downloadFailed("Couldn’t detect spoken language. No subtitles were generated")
            }
        }
        let required: [(String, SubtitleTrack.Source)] = language == "en" ? [("en", .transcribed)] : [(language, .transcribed), ("en", .translated)]
        for (target, source) in required where !tracks.contains(where: { $0.language == target && $0.coverage == .full && $0.isReady }) {
            let index = tracks.count
            tracks.append(SubtitleTrack(language: target, source: source, state: .generating))
            let isTranslation = source == .translated
            do {
                var cues: [SubtitleCue] = []
                for offset in stride(from: 0.0, to: duration, by: chunkDuration) {
                    try Task.checkCancellation()
                    let phase: SubtitlePhase = isTranslation ? .translating(offset / duration) : .transcribing(offset / duration)
                    await onUpdate(phase, tracks)
                    let length = min(chunkDuration, duration - offset)
                    let result: WhisperResult
                    if offset == 0, !isTranslation, let firstResult {
                        result = firstResult
                    } else {
                        result = try await recognizer(video, work, offset, length, language, isTranslation)
                    }
                    cues += result.cues(offset: Int((offset * 1000).rounded()), duration: Int((length * 1000).rounded()))
                }
                guard !cues.isEmpty else { throw YoinkError.downloadFailed("No spoken subtitles could be generated") }
                let file = work.appendingPathComponent("\(source.rawValue)-\(target).srt")
                try SubtitleCue.srt(cues).write(to: file, atomically: true, encoding: .utf8)
                tracks[index].state = .ready(file)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                tracks[index].state = .failed(error.localizedDescription)
            }
            await onUpdate(isTranslation ? .translating(1) : .transcribing(1), tracks)
        }
        await onUpdate(.muxing, tracks)
    }

    static func recognize(video: URL, work: URL, offset: Double, duration: Double, language: String, isTranslation: Bool) async throws -> WhisperResult {
        guard FileManager.default.isExecutableFile(atPath: whisperURL.path), FileManager.default.fileExists(atPath: modelURL.path) else {
            throw YoinkError.downloadFailed("The bundled subtitle engine is unavailable. Download Yoink again")
        }
        let audio = work.appendingPathComponent("audio.wav")
        let stem = work.appendingPathComponent("recognition")
        defer {
            for file in [audio, stem.appendingPathExtension("json")] { try? FileManager.default.removeItem(at: file) }
        }
        _ = try await MediaCommand.run(Downloader.ffmpegURL, ["-v", "error", "-nostdin", "-y", "-ss", String(offset), "-i", video.path, "-t", String(duration), "-map", "0:a:0", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", audio.path])
        var arguments = ["-m", modelURL.path, "-f", audio.path, "-l", language, "-oj", "-of", stem.path, "-np", "-t", "4"]
        if isTranslation { arguments.append("-tr") }
        _ = try await MediaCommand.run(whisperURL, arguments)
        return try JSONDecoder().decode(WhisperResult.self, from: Data(contentsOf: stem.appendingPathExtension("json")))
    }

    static func mux(video: URL, tracks: [SubtitleTrack], to output: URL) async throws {
        var arguments = ["-v", "error", "-nostdin", "-y", "-i", video.path]
        for track in tracks {
            guard case .ready(let file) = track.state else { throw YoinkError.downloadFailed("A subtitle track is not ready") }
            arguments += ["-i", file.path]
        }
        arguments += ["-map", "0:v:0?", "-map", "0:a:0?"]
        for index in tracks.indices { arguments += ["-map", "\(index + 1):0"] }
        arguments += ["-c:v", "copy", "-c:a", "copy", "-c:s", "mov_text"]
        for (index, track) in tracks.enumerated() {
            arguments += ["-metadata:s:s:\(index)", "language=\(SubtitleLanguage.mp4(track.language))", "-metadata:s:s:\(index)", "title=\(track.title)", "-metadata:s:s:\(index)", "handler_name=\(track.title)", "-disposition:s:\(index)", "0"]
        }
        arguments += ["-movflags", "+faststart", "-f", "mp4", output.path]
        _ = try await MediaCommand.run(Downloader.ffmpegURL, arguments)
    }
}
