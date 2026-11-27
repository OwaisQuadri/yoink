import Foundation
import Network
import Testing
@testable import Yoink

struct UnreachableHostTests {
    @Test func hostWithoutAnyHTTPResponseIsReportedUnreachable() async throws {
        let closedPort = try #require(URL(string: "https://127.0.0.1:9/player.html"))

        #expect(await Downloader.firstUnreachableHost([closedPort]) == "127.0.0.1")
    }

    @Test func redirectToUnreachableHostNamesTheRedirectTarget() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let response = "HTTP/1.1 302 Found\r\nLocation: http://localhost:9/video.m3u8\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: return
                }
            }
            listener.start(queue: .global())
        }
        defer { listener.cancel() }
        let redirecting = try #require(URL(string: "http://127.0.0.1:\(port)/embed"))

        #expect(await Downloader.firstUnreachableHost([redirecting]) == "localhost")
    }
}
