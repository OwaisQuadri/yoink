import XCTest
@testable import Yoink

final class SubtitleChoiceTests: XCTestCase {
    @MainActor
    func testQueuedJobsSnapshotFormChoiceAndRetryRetainsIt() async throws {
        let previousFolder = UserDefaults.standard.object(forKey: "folder")
        let store = Store()
        store.folder = FileManager.default.temporaryDirectory
        defer { UserDefaults.standard.set(previousFolder, forKey: "folder") }
        var formChoice = SubtitleChoice.original(isGenerationEnabled: false)
        store.add("https://example.com/first", subtitleChoice: formChoice)
        let first = try XCTUnwrap(store.jobs.first)
        formChoice = .none
        store.add("https://example.com/second", subtitleChoice: formChoice)
        let second = try XCTUnwrap(store.jobs.first)
        XCTAssertEqual(first.subtitleChoice, .original(isGenerationEnabled: false))
        XCTAssertEqual(second.subtitleChoice, .none)
        XCTAssertEqual(second.state, .waiting)
        let task = first.task
        store.cancel(first)
        store.cancel(second)
        await task?.value
        store.folder = nil
        first.subtitles = [SubtitleTrack(language: "es", source: .web)]
        store.retry(first)
        XCTAssertEqual(first.subtitleChoice, .original(isGenerationEnabled: false))
        XCTAssertEqual(first.state, .waiting)
        XCTAssertTrue(first.subtitles.isEmpty)
        XCTAssertEqual(second.subtitleChoice, .none)
    }
}
