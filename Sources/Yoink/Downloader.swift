import Foundation

enum Downloader {
    static var ffmpegURL: URL {
        if let bundled = Bundle.main.url(forResource: "ffmpeg", withExtension: nil) { return bundled }
        return URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    }

    static func save(
        _ media: FoundMedia,
        to output: URL,
        process: Process,
        onProgress: @escaping @MainActor (_ seconds: Double, _ duration: Double?) -> Void
    ) async throws {
        let partial = output.appendingPathExtension("part")
        let headerLines = media.headers.map { "\($0.key): \($0.value)\r\n" }.joined()
        process.executableURL = ffmpegURL
        process.arguments = [
            "-hide_banner", "-nostdin", "-y",
            "-user_agent", Sniffer.userAgent,
            "-headers", headerLines,
            "-i", media.url.absoluteString,
            "-c", "copy", "-sn", "-dn",
            "-movflags", "+faststart",
            "-f", "mp4",
            "-progress", "pipe:1", "-nostats",
            partial.path,
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let exitCode: Int32 = try await withThrowingTaskGroup(of: Int32?.self) { group in
            let duration = DurationBox()
            group.addTask {
                var tail: [String] = []
                for try await line in stderr.fileHandleForReading.bytes.lines {
                    tail = Array((tail + [line]).suffix(5))
                    if let value = parseDuration(line) { await duration.set(value) }
                }
                await duration.setTail(tail.joined(separator: "\n"))
                return nil
            }
            group.addTask {
                for try await line in stdout.fileHandleForReading.bytes.lines where line.hasPrefix("out_time_us=") {
                    guard let micros = Double(line.dropFirst("out_time_us=".count)) else { continue }
                    let total = await duration.value
                    await onProgress(micros / 1_000_000, total)
                }
                return nil
            }
            group.addTask {
                await withCheckedContinuation { continuation in
                    process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                    do { try process.run() } catch {
                        process.terminationHandler = nil
                        continuation.resume(returning: -1)
                    }
                }
            }
            var code: Int32 = -1
            for try await result in group { if let result { code = result } }
            if code != 0, process.terminationReason != .uncaughtSignal {
                let tail = await duration.tail
                try? FileManager.default.removeItem(at: partial)
                throw YoinkError.downloadFailed(tail.isEmpty ? "Download failed" : tail)
            }
            return code
        }

        guard exitCode == 0 else {
            try? FileManager.default.removeItem(at: partial)
            throw CancellationError()
        }
        try FileManager.default.moveItem(at: partial, to: output)
    }

    private static func parseDuration(_ line: String) -> Double? {
        guard let range = line.range(of: "Duration: ") else { return nil }
        let parts = line[range.upperBound...].prefix(11).split(separator: ":")
        guard parts.count == 3, let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2]) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }
}

private actor DurationBox {
    var value: Double?
    var tail = ""
    func set(_ newValue: Double) { if value == nil { value = newValue } }
    func setTail(_ newValue: String) { tail = newValue }
}
