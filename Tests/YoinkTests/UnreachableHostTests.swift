import Foundation
import Testing
@testable import Yoink

struct UnreachableHostTests {
    @Test func hostWithoutAnyHTTPResponseIsReportedUnreachable() async throws {
        let closedPort = try #require(URL(string: "https://127.0.0.1:9/player.html"))

        #expect(await Downloader.firstUnreachableHost([closedPort]) == "127.0.0.1")
    }
}
