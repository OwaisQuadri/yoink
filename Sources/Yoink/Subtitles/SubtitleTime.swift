import Foundation

enum SubtitleTime {
    static func milliseconds(_ seconds: Double) throws -> Int {
        guard seconds.isFinite, let value = Int(exactly: (seconds * 1000).rounded()) else {
            throw YoinkError.downloadFailed("Subtitle timing is outside the supported range")
        }
        return value
    }

    static func duration(_ seconds: Double) throws -> Int {
        guard seconds >= 0 else { throw YoinkError.downloadFailed("Invalid subtitle segment duration") }
        return try milliseconds(seconds)
    }

    static func add(_ first: Int, _ second: Int) throws -> Int {
        let (value, isOverflow) = first.addingReportingOverflow(second)
        guard !isOverflow else { throw YoinkError.downloadFailed("Subtitle timing is outside the supported range") }
        return value
    }

    static func subtract(_ first: Int, _ second: Int) throws -> Int {
        let (value, isOverflow) = first.subtractingReportingOverflow(second)
        guard !isOverflow else { throw YoinkError.downloadFailed("Subtitle timing is outside the supported range") }
        return value
    }
}
