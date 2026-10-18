import XCTest
@testable import Yoink

final class SubtitleChoiceTests: XCTestCase {
    func testIndependentLanguageTogglesRetainGenerationPreferenceAcrossNeitherSelection() {
        XCTAssertEqual(SubtitleChoice.default.languages, [.original, .english])
        XCTAssertTrue(SubtitleChoice.default.isGenerationEnabled)
        for isGenerationEnabled in [true, false] {
            var choice = SubtitleChoice(isGenerationEnabled: isGenerationEnabled)
            choice.languages[isSelected: .original] = false
            XCTAssertEqual(choice.languages, .english)
            choice.languages[isSelected: .english] = false
            XCTAssertTrue(choice.languages.isEmpty)
            XCTAssertEqual(choice.isGenerationEnabled, isGenerationEnabled)
            choice.languages[isSelected: .original] = true
            XCTAssertEqual(choice.languages, .original)
            choice.languages[isSelected: .english] = true
            XCTAssertEqual(choice.languages, [.original, .english])
            XCTAssertEqual(choice.isGenerationEnabled, isGenerationEnabled)
        }
    }

    @MainActor
    func testQueuedJobsSnapshotIndependentSelectionsAndRetryRetainsThem() async throws {
        let previousFolder = UserDefaults.standard.object(forKey: "folder")
        let store = Store()
        store.folder = FileManager.default.temporaryDirectory
        defer { UserDefaults.standard.set(previousFolder, forKey: "folder") }
        var formChoice = SubtitleChoice(languages: .original, isGenerationEnabled: false)
        store.add("https://example.com/first", subtitleChoice: formChoice)
        let first = try XCTUnwrap(store.jobs.first)
        formChoice.languages[isSelected: .original] = false
        formChoice.languages[isSelected: .english] = true
        formChoice.isGenerationEnabled = true
        store.add("https://example.com/second", subtitleChoice: formChoice)
        let second = try XCTUnwrap(store.jobs.first)
        formChoice.languages = []
        XCTAssertEqual(first.subtitleChoice, .init(languages: .original, isGenerationEnabled: false))
        XCTAssertEqual(second.subtitleChoice, .init(languages: .english))
        XCTAssertEqual(second.state, .waiting)
        let task = first.task
        store.cancel(first)
        store.cancel(second)
        await task?.value
        store.folder = nil
        first.subtitles = [SubtitleTrack(language: "es", source: .web)]
        store.retry(first)
        XCTAssertEqual(first.subtitleChoice, .init(languages: .original, isGenerationEnabled: false))
        XCTAssertEqual(first.state, .waiting)
        XCTAssertTrue(first.subtitles.isEmpty)
        XCTAssertEqual(second.subtitleChoice, .init(languages: .english))
    }
}
