import CommonCrypto
import Foundation

struct HLSSegment {
    let url: URL
    let duration: Double
    let byteRange: Range<Int>?
    let keyURL: URL?
    let iv: Data?
    var isDiscontinuity = false
}

struct HLSTrack {
    var initSegment: HLSSegment?
    var segments: [HLSSegment] = []
}

enum HLS {
    static func attributes(_ line: Substring) -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        let body = String(line[line.index(after: colon)...])
        let pattern = try! NSRegularExpression(pattern: #"([A-Z0-9-]+)=("[^"]*"|[^,]*)"#)
        var result: [String: String] = [:]
        for match in pattern.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let keyRange = Range(match.range(at: 1), in: body), let valueRange = Range(match.range(at: 2), in: body) else { continue }
            result[String(body[keyRange])] = body[valueRange].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return result
    }

    static func lines(_ text: String) -> [Substring] {
        text.split(whereSeparator: \.isNewline).map { $0.drop { $0 == " " } }.filter { !$0.isEmpty }
    }

    static func isMaster(_ text: String) -> Bool {
        text.contains("#EXT-X-STREAM-INF")
    }

    static func pickVariant(_ text: String, base: URL) -> (video: URL, audio: URL?, subtitles: [RemoteSubtitle])? {
        let all = lines(text)
        var best: (bandwidth: Int, url: URL, audioGroup: String?, subtitleGroup: String?)?
        for (index, line) in all.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") {
            let attributes = attributes(line)
            guard index + 1 < all.count, !all[index + 1].hasPrefix("#"),
                  let url = URL(string: String(all[index + 1]), relativeTo: base)?.absoluteURL else { continue }
            let bandwidth = Int(attributes["BANDWIDTH"] ?? "") ?? 0
            if bandwidth > best?.bandwidth ?? -1 { best = (bandwidth, url, attributes["AUDIO"], attributes["SUBTITLES"]) }
        }
        guard let best else { return nil }
        let audio = best.audioGroup.flatMap { group in
            let renditions = all.filter { $0.hasPrefix("#EXT-X-MEDIA") }.map(attributes)
                .filter { $0["TYPE"] == "AUDIO" && $0["GROUP-ID"] == group && $0["URI"] != nil }
            let chosen = renditions.first { $0["DEFAULT"] == "YES" } ?? renditions.first
            return chosen.flatMap { URL(string: $0["URI"]!, relativeTo: base)?.absoluteURL }
        }
        let subtitles = all.filter { $0.hasPrefix("#EXT-X-MEDIA") }.map(attributes).compactMap { rendition -> RemoteSubtitle? in
            guard rendition["TYPE"] == "SUBTITLES", rendition["GROUP-ID"] == best.subtitleGroup,
                  let uri = rendition["URI"], let url = URL(string: uri, relativeTo: base)?.absoluteURL else { return nil }
            return RemoteSubtitle(url: url, language: SubtitleLanguage.canonical(rendition["LANGUAGE"]), isForced: rendition["FORCED"] == "YES")
        }
        return (best.url, audio, subtitles)
    }

    static func parseTrack(_ text: String, base: URL) throws -> HLSTrack {
        var track = HLSTrack()
        var sequence = 0
        var duration = 0.0
        var byteRange: Range<Int>?
        var nextOffset = 0
        var keyURL: URL?
        var keyIV: Data?
        var isDiscontinuity = false
        for line in lines(text) {
            if line == "#EXT-X-DISCONTINUITY" {
                isDiscontinuity = true
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                sequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXT-X-KEY") {
                let attributes = attributes(line)
                switch attributes["METHOD"] {
                case "NONE", nil:
                    keyURL = nil
                    keyIV = nil
                case "AES-128":
                    keyURL = attributes["URI"].flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
                    keyIV = attributes["IV"].flatMap(hexData)
                default:
                    throw YoinkError.downloadFailed("This video is copy-protected")
                }
            } else if line.hasPrefix("#EXT-X-MAP") {
                let attributes = attributes(line)
                if let uri = attributes["URI"], let url = URL(string: uri, relativeTo: base)?.absoluteURL {
                    track.initSegment = HLSSegment(url: url, duration: 0, byteRange: attributes["BYTERANGE"].flatMap { parseRange($0, previousEnd: 0) }, keyURL: nil, iv: nil)
                }
            } else if line.hasPrefix("#EXTINF:") {
                duration = Double(line.dropFirst("#EXTINF:".count).prefix { $0 != "," }) ?? 0
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                byteRange = parseRange(String(line.dropFirst("#EXT-X-BYTERANGE:".count)), previousEnd: nextOffset)
                nextOffset = byteRange?.upperBound ?? 0
            } else if !line.hasPrefix("#"), let url = URL(string: String(line), relativeTo: base)?.absoluteURL {
                let iv = keyURL == nil ? nil : keyIV ?? sequenceIV(sequence)
                var segment = HLSSegment(url: url, duration: duration, byteRange: byteRange, keyURL: keyURL, iv: iv)
                segment.isDiscontinuity = isDiscontinuity
                track.segments.append(segment)
                isDiscontinuity = false
                sequence += 1
                duration = 0
                byteRange = nil
            }
        }
        return track
    }

    static func decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var written = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                inputBytes.baseAddress, data.count,
                                outputBytes.baseAddress, outputCapacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw YoinkError.downloadFailed("Couldn’t decrypt the video") }
        return output.prefix(written)
    }

    private static func parseRange(_ text: String, previousEnd: Int) -> Range<Int>? {
        let parts = text.split(separator: "@")
        guard let length = Int(parts[0]) else { return nil }
        let start = parts.count > 1 ? Int(parts[1]) ?? previousEnd : previousEnd
        return start..<(start + length)
    }

    private static func sequenceIV(_ sequence: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        var value = UInt64(sequence)
        for index in (8..<16).reversed() {
            bytes[index] = UInt8(value & 0xff)
            value >>= 8
        }
        return Data(bytes)
    }

    private static func hexData(_ text: String) -> Data? {
        let hex = text.hasPrefix("0x") || text.hasPrefix("0X") ? String(text.dropFirst(2)) : text
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
