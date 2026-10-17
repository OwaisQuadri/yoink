import Foundation

enum MediaCommand {
    static func tool(_ name: String) -> URL {
        if let bundled = Bundle.main.url(forResource: name, withExtension: nil) { return bundled }
        let vendor = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("vendor/ffmpeg/\(name)")
        if FileManager.default.isExecutableFile(atPath: vendor.path) { return vendor }
        return URL(fileURLWithPath: "/opt/homebrew/bin/\(name)")
    }

    static func run(_ executable: URL, _ arguments: [String]) async throws -> Data {
        let invocation = Invocation(executable: executable, arguments: arguments)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await Task.detached { try invocation.run() }.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            invocation.cancel()
        }
    }

    private final class Invocation: @unchecked Sendable {
        private let process = Process()
        private let lock = NSLock()
        private var isCancelled = false

        init(executable: URL, arguments: [String]) {
            process.executableURL = executable
            process.arguments = arguments
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            isCancelled = true
            if process.isRunning { process.terminate() }
        }

        func run() throws -> Data {
            let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent("yoink-command-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: errorURL.path, contents: nil)
            defer { try? FileManager.default.removeItem(at: errorURL) }
            let errors = try FileHandle(forWritingTo: errorURL)
            defer { try? errors.close() }
            let output = Pipe()
            process.standardOutput = output
            process.standardError = errors
            try lock.withLock {
                if isCancelled { throw CancellationError() }
                try process.run()
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if lock.withLock({ isCancelled }) { throw CancellationError() }
            guard process.terminationStatus == 0 else {
                let handle = try FileHandle(forReadingFrom: errorURL)
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                try handle.seek(toOffset: size > 4096 ? size - 4096 : 0)
                let message = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
                throw YoinkError.downloadFailed(message.split(separator: "\n").last.map(String.init) ?? "Media processing failed")
            }
            return data
        }
    }
}
