import Foundation

struct SubtitleTrack: Identifiable, Equatable {
    enum Source: String {
        case embedded = "Source"
        case web = "Source captions"
        case transcribed = "Generated"
        case translated = "Translated"
    }

    enum State: Equatable {
        case pending
        case generating
        case ready(URL)
        case failed(String)
    }

    enum Coverage { case full, forced }

    let id: UUID
    var coverage: Coverage = .full
    var language: String
    let source: Source
    var state: State

    init(language: String, source: Source, state: State = .pending) {
        id = UUID()
        self.language = language
        self.source = source
        self.state = state
    }

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    var title: String {
        let name = language == "und" ? "Original" : Locale.current.localizedString(forLanguageCode: language) ?? language
        return "\(name) · \(source.rawValue)\(coverage == .forced ? " (forced only)" : "")"
    }
}

struct SubtitleOutcome {
    let tracks: [SubtitleTrack]

    var readyTracks: [SubtitleTrack] { tracks.filter(\.isReady) }

    var warning: String? {
        let failures = tracks.compactMap { track -> String? in
            guard case .failed(let reason) = track.state else { return nil }
            return "\(track.title) unavailable. \(reason)"
        }
        return failures.isEmpty ? nil : failures.joined(separator: " ")
    }
}

struct SubtitleCue: Equatable {
    let start: Int
    let end: Int
    let text: String

    static func srt(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    private static func timestamp(_ milliseconds: Int) -> String {
        String(format: "%02d:%02d:%02d,%03d", milliseconds / 3_600_000,
               milliseconds / 60_000 % 60, milliseconds / 1000 % 60, milliseconds % 1000)
    }
}

struct WhisperResult: Decodable {
    struct Result: Decodable { let language: String }
    struct Segment: Decodable {
        struct Offsets: Decodable { let from: Int; let to: Int }
        let offsets: Offsets
        let text: String
    }
    let result: Result
    let transcription: [Segment]

    func cues(offset: Int, duration: Int) -> [SubtitleCue] {
        transcription.compactMap { segment in
            let start = max(0, segment.offsets.from)
            let end = min(duration, segment.offsets.to)
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard end > start, !text.isEmpty else { return nil }
            return SubtitleCue(start: offset + start, end: offset + end, text: text)
        }
    }
}

enum SubtitleLanguage {
    static func canonical(_ language: String?) -> String {
        let code = (language ?? "und").lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init) ?? "und"
        return aliases[code] ?? code
    }

    private static let aliases = Dictionary(uniqueKeysWithValues: Locale.LanguageCode.isoLanguageCodes.compactMap { code -> (String, String)? in
        guard let alpha2 = code.identifier(.alpha2), let alpha3 = code.identifier(.alpha3), alpha2 != alpha3 else { return nil }
        return (alpha3, alpha2)
    }).merging(["fre": "fr", "ger": "de", "dut": "nl", "chi": "zh", "cze": "cs", "gre": "el", "rum": "ro", "per": "fa", "may": "ms", "bur": "my", "wel": "cy", "ice": "is", "slo": "sk", "alb": "sq", "arm": "hy", "baq": "eu", "geo": "ka", "mac": "mk", "tib": "bo"]) { _, value in value }

    static func mp4(_ language: String) -> String {
        Locale.LanguageCode(canonical(language)).identifier(.alpha3) ?? "und"
    }
}
