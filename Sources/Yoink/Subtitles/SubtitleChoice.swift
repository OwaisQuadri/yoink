import Foundation

struct SubtitleChoice: Equatable {
    struct Languages: OptionSet, Hashable {
        let rawValue: Int

        static let original = Self(rawValue: 1 << 0)
        static let english = Self(rawValue: 1 << 1)

        subscript(isSelected language: Self) -> Bool {
            get { contains(language) }
            set {
                if newValue { insert(language) } else { remove(language) }
            }
        }
    }

    var languages: Languages = [.original, .english]
    var isGenerationEnabled = true

    static let `default` = Self()

    func targets(language: String) -> [(language: String, source: SubtitleTrack.Source)] {
        var targets: [(language: String, source: SubtitleTrack.Source)] = []
        if languages.contains(.original) { targets.append((language, .transcribed)) }
        if languages.contains(.english), !targets.contains(where: { $0.language == "en" }) {
            targets.append(("en", language == "en" ? .transcribed : .translated))
        }
        return targets
    }

    func selectedTracks(_ tracks: [SubtitleTrack], language: String) -> [SubtitleTrack] {
        tracks.filter { track in
            targets(language: language).contains { target in
                SubtitleLanguage.isIdentified(target.language) && track.language == target.language
            }
        }
    }
}
