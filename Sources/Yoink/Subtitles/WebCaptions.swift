import Foundation

struct TransportEpoch {
    let start: Int
    let transportStart: Int
}

enum TransportTimeline {
    case available([TransportEpoch])
    case unavailable(String)
}

enum WebCaptions {
    static func time(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), let seconds = Double(parts.last!), seconds.isFinite, (0..<60).contains(seconds),
              let minutes = Int(parts[parts.count - 2]), (0..<60).contains(minutes),
              let hours = parts.count == 3 ? Int(parts[0]) : 0, (0...999_999).contains(hours) else { return nil }
        return hours * 3_600_000 + minutes * 60_000 + Int((seconds * 1000).rounded())
    }

    static func cues(_ text: String, videoStart: Int, segmentStart: Int, epochOffset: Int = 0) throws -> [SubtitleCue] {
        let lines = text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        var offset = 0
        if let map = lines.first(where: { $0.hasPrefix("X-TIMESTAMP-MAP=") }) {
            let values = map.dropFirst("X-TIMESTAMP-MAP=".count).split(separator: ",")
            guard let localText = values.first(where: { $0.hasPrefix("LOCAL:") }),
                  let local = time(String(localText.dropFirst(6))),
                  let mpegText = values.first(where: { $0.hasPrefix("MPEGTS:") }), let mpeg = Int64(mpegText.dropFirst(7)), (0..<(Int64(1) << 33)).contains(mpeg) else {
                throw YoinkError.downloadFailed("Invalid HLS subtitle timestamp map")
            }
            let wrap = Double(Int64(1) << 33) / 90
            let relative = Double(mpeg) / 90 - Double(videoStart) + Double(epochOffset)
            let mapped = relative + ((Double(segmentStart) - relative) / wrap).rounded() * wrap
            guard let mappedMilliseconds = Int(exactly: mapped.rounded()) else {
                throw YoinkError.downloadFailed("Subtitle timestamp map is outside the supported range")
            }
            offset = try SubtitleTime.subtract(mappedMilliseconds, local)
        }
        var cues: [SubtitleCue] = []
        for (index, line) in lines.enumerated() where line.contains(" --> ") {
            let times = line.components(separatedBy: " --> ")
            guard times.count == 2, let start = time(times[0]),
                  let endText = times[1].split(separator: " ").first, let end = time(String(endText)), end > start else {
                throw YoinkError.downloadFailed("Invalid subtitle cue timing")
            }
            let text = lines.dropFirst(index + 1).prefix { !$0.isEmpty }.joined(separator: "\n")
            let mappedStart = try SubtitleTime.add(start, offset)
            let mappedEnd = try SubtitleTime.add(end, offset)
            if !text.isEmpty, mappedEnd > 0 {
                cues.append(SubtitleCue(start: max(0, mappedStart), end: mappedEnd, text: text))
            }
        }
        return cues
    }

    private static func byteRange(_ text: String) throws -> Range<Int> {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, let length = Int(parts[0]), length > 0, let start = Int(parts[1]), start >= 0 else {
            throw YoinkError.downloadFailed("Invalid subtitle initialization byte range")
        }
        return start..<(try SubtitleTime.add(start, length))
    }

    static func download(_ remote: RemoteSubtitle, media: FoundMedia, work: URL, timeline: TransportTimeline, presentationShift: Int) async throws -> SubtitleTrack {
        let (data, _, _) = try await Downloader.get(media, remote.url)
        let text = String(decoding: data, as: UTF8.self)
        let output = work.appendingPathComponent("web-\(UUID().uuidString).srt")
        if text.hasPrefix("#EXTM3U") {
            guard !text.contains("#EXT-X-KEY") else { throw YoinkError.downloadFailed("Encrypted source subtitles are not supported") }
            let epochs: [TransportEpoch]
            switch timeline {
            case .available(let available): epochs = available
            case .unavailable(let reason): throw YoinkError.downloadFailed(reason)
            }
            var all: [SubtitleCue] = []
            var segmentStart = 0
            var duration = 0
            var initialization = ""
            for line in HLS.lines(text) {
                if line.hasPrefix("#EXTINF:") {
                    guard let seconds = Double(line.dropFirst(8).prefix(while: { $0 != "," })) else {
                        throw YoinkError.downloadFailed("Invalid subtitle segment duration")
                    }
                    duration = try SubtitleTime.duration(seconds)
                } else if line.hasPrefix("#EXT-X-MAP:") {
                    let attributes = HLS.attributes(line)
                    guard let uri = attributes["URI"], let url = URL(string: uri, relativeTo: remote.url)?.absoluteURL else {
                        throw YoinkError.downloadFailed("Invalid subtitle initialization section")
                    }
                    let range = try attributes["BYTERANGE"].map(byteRange)
                    let (header, _, _) = try await Downloader.get(media, url, range: range)
                    initialization = String(decoding: header, as: UTF8.self)
                } else if !line.hasPrefix("#"), let url = URL(string: String(line), relativeTo: remote.url)?.absoluteURL {
                    let (segment, _, _) = try await Downloader.get(media, url)
                    let vtt = String(decoding: segment, as: UTF8.self)
                    let epoch = epochs.last { $0.start <= segmentStart } ?? TransportEpoch(start: 0, transportStart: 0)
                    let content = vtt.contains("X-TIMESTAMP-MAP=") ? vtt : initialization + "\n\n" + vtt
                    all += try cues(content, videoStart: epoch.transportStart, segmentStart: segmentStart, epochOffset: SubtitleTime.add(epoch.start, presentationShift))
                    segmentStart = try SubtitleTime.add(segmentStart, duration)
                }
            }
            var seen = Set<String>()
            let ordered = all.sorted { $0.start < $1.start }.filter { seen.insert("\($0.start):\($0.end):\($0.text)").inserted }
            guard !ordered.isEmpty else { throw YoinkError.downloadFailed("The source subtitle playlist is empty") }
            try SubtitleCue.srt(ordered).write(to: output, atomically: true, encoding: .utf8)
        } else {
            let input = work.appendingPathComponent("captions-\(UUID().uuidString)")
            try data.write(to: input)
            _ = try await MediaCommand.run(Downloader.ffmpegURL, ["-v", "error", "-nostdin", "-y", "-i", input.path, output.path])
        }
        guard !(try cues(String(contentsOf: output, encoding: .utf8), videoStart: 0, segmentStart: 0)).isEmpty else {
            throw YoinkError.downloadFailed("The source caption track is empty")
        }
        var track = SubtitleTrack(language: remote.language, source: .web, state: .ready(output))
        track.coverage = remote.isForced ? .forced : .full
        return track
    }
}
