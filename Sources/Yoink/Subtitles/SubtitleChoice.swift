import Foundation

enum SubtitleChoice: Equatable, Hashable {
    case none
    case sourceOnly
    case original(isGenerationEnabled: Bool)
    case originalAndEnglish(isGenerationEnabled: Bool)

    static let `default` = Self.originalAndEnglish(isGenerationEnabled: true)

    var isGenerationEnabled: Bool {
        switch self {
        case .none, .sourceOnly: false
        case .original(let isEnabled), .originalAndEnglish(let isEnabled): isEnabled
        }
    }

    func targets(language: String) -> [(language: String, source: SubtitleTrack.Source)] {
        switch self {
        case .none, .sourceOnly: []
        case .original: [(language, .transcribed)]
        case .originalAndEnglish:
            language == "en" ? [("en", .transcribed)] : [(language, .transcribed), ("en", .translated)]
        }
    }

    func selectedTracks(_ tracks: [SubtitleTrack], language: String) -> [SubtitleTrack] {
        switch self {
        case .none: []
        case .sourceOnly: tracks
        case .original, .originalAndEnglish:
            tracks.filter { track in
                targets(language: language).contains { target in
                    SubtitleLanguage.isIdentified(target.language) && track.language == target.language
                }
            }
        }
    }
}
