import Foundation

struct ReleaseError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func require(_ isValid: Bool, _ message: String) throws {
    if !isValid { throw ReleaseError(message) }
}

struct Version {
    let components: [UInt64]
    let text: String

    init(_ text: String, isBuild: Bool = false) throws {
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        try require(!pieces.isEmpty && (isBuild ? pieces.count == 1 : pieces.count <= 3), "Invalid version format")
        var numbers: [UInt64] = []
        for piece in pieces {
            try require(!piece.isEmpty && piece.allSatisfy { $0.isASCII && $0.isNumber } && (piece == "0" || !piece.hasPrefix("0")), "Invalid version component")
            guard let number = UInt64(piece) else { throw ReleaseError("Version exceeds integer range") }
            numbers.append(number)
        }
        self.text = text
        components = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    func isSame(as other: Self) -> Bool { components == other.components }
    func isGreater(than other: Self) -> Bool { other.components.lexicographicallyPrecedes(components) }
}

struct AppVersion {
    let version: Version
    let build: Version

    init(version: String, build: String) throws {
        self.version = try Version(version)
        self.build = try Version(build, isBuild: true)
    }

    init(plist: String) throws {
        let values = try plistValues(plist)
        guard let version = values["CFBundleShortVersionString"] as? String,
              let build = values["CFBundleVersion"] as? String else { throw ReleaseError("Missing plist versions") }
        try self.init(version: version, build: build)
    }

    func checkIncrease(from previous: Self) throws {
        try require(version.isGreater(than: previous.version) && build.isGreater(than: previous.build), "Both display version and build must increase; rollback and reuse are forbidden")
    }

    var tag: String { "v\(version.text)" }
    var archive: String { "Yoink-\(version.text)-\(build.text).dmg" }
    var source: String { "Yoink-\(version.text)-\(build.text)-FFmpeg-source.tar.gz" }
    var assets: Set<String> { [archive, source, "appcast.xml", "SHA256SUMS"] }
}

func plistValues(_ path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        throw ReleaseError("Invalid plist")
    }
    return values
}

struct Release: Decodable {
    struct Asset: Decodable {
        let id: Int
        let name: String
        let size: Int
        let browser_download_url: String
    }
    let id: Int
    let tag_name: String
    let isDraft: Bool
    let isPrerelease: Bool
    let target_commitish: String
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case id, tag_name, target_commitish, assets
        case isDraft = "draft"
        case isPrerelease = "prerelease"
    }
}

func readRelease(_ path: String) throws -> Release {
    try JSONDecoder().decode(Release.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
}

func readReleases(_ path: String) throws -> [Release] {
    try JSONDecoder().decode([[Release]].self, from: Data(contentsOf: URL(fileURLWithPath: path))).flatMap { $0 }
}

struct Feed {
    let app: AppVersion
    let signature: String
    let length: Int
    let url: String

    init(_ path: String) throws {
        let document = try XMLDocument(contentsOf: URL(fileURLWithPath: path), options: [.nodeLoadExternalEntitiesNever])
        try require(document.dtd == nil, "Feed DTD is forbidden")
        let items = try document.nodes(forXPath: "/rss/channel/item")
        try require(items.count == 1, "Expected exactly one appcast item")
        let item = items[0]
        func field(_ xpath: String) throws -> String {
            let nodes = try item.nodes(forXPath: xpath)
            guard nodes.count == 1, let value = nodes[0].stringValue, !value.isEmpty else { throw ReleaseError("Missing or duplicate appcast field") }
            return value
        }
        app = try AppVersion(version: field("sparkle:shortVersionString"), build: field("sparkle:version"))
        signature = try field("enclosure/@sparkle:edSignature")
        url = try field("enclosure/@url")
        guard let length = Int(try field("enclosure/@length")), length > 0 else { throw ReleaseError("Invalid enclosure length") }
        self.length = length
        try require(Data(base64Encoded: signature)?.count == 64, "Invalid archive signature")
    }

    func check(_ expected: AppVersion, repository: String) throws {
        try require(app.version.isSame(as: expected.version) && app.build.isSame(as: expected.build), "Feed version does not match app")
        try require(url == "https://github.com/\(repository)/releases/download/\(expected.tag)/\(expected.archive)", "Unexpected enclosure URL")
    }
}

func checkAssets(_ release: Release, app: AppVersion, repository: String) throws {
    try require(release.tag_name == app.tag, "Release tag does not match version")
    try require(release.assets.count == 4 && Set(release.assets.map(\.name)) == app.assets, "Release must contain exactly the four generated assets")
    for asset in release.assets {
        try require(asset.size > 0 && asset.browser_download_url == "https://github.com/\(repository)/releases/download/\(app.tag)/\(asset.name)", "Invalid release asset")
    }
}

func run(_ executable: String, _ arguments: [String], input: String? = nil, environment: [String: String]? = nil, isQuiet: Bool = false) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = environment ?? ProcessInfo.processInfo.environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = isQuiet ? FileHandle.nullDevice : FileHandle.standardError
    let pipe = Pipe()
    if input != nil { process.standardInput = pipe }
    try process.run()
    if let input {
        try pipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try pipe.fileHandleForWriting.close()
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try require(process.terminationStatus == 0, "\(URL(fileURLWithPath: executable).lastPathComponent) failed")
    return isQuiet ? "" : String(decoding: data, as: UTF8.self)
}

func requiredEnvironment(_ name: String) throws -> String {
    guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { throw ReleaseError("Missing \(name)") }
    return value
}

struct NotaryCredentials: Decodable {
    let appleID: String
    let appSpecificPassword: String
    let teamID: String
}

func credentialDirectory() throws -> String {
    let temporary = try requiredEnvironment("RUNNER_TEMP")
    let runID = try requiredEnvironment("GITHUB_RUN_ID")
    let attempt = try requiredEnvironment("GITHUB_RUN_ATTEMPT")
    try require([runID, attempt].allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }, "Invalid run identity")
    return "\(temporary)/yoink-signing-\(runID)-\(attempt)"
}

func security(_ command: String) throws {
    _ = try run("/usr/bin/security", ["-i"], input: command + "\n", isQuiet: true)
}

func quoted(_ value: String) throws -> String {
    try require(!value.contains("\n") && !value.contains("\r") && !value.contains("\0"), "Invalid credential or path encoding")
    return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

func cleanupCredentials() throws {
    let directory = try credentialDirectory()
    guard FileManager.default.fileExists(atPath: directory) else { return }
    let state = "\(directory)/state.json"
    if FileManager.default.fileExists(atPath: state) {
        let data = try Data(contentsOf: URL(fileURLWithPath: state))
        let values = try JSONDecoder().decode([String: String].self, from: data)
        guard let search = values["search"], let original = values["default"] else { throw ReleaseError("Missing keychain restoration state") }
        try security("default-keychain -d user -s \(original)")
        try security("list-keychains -d user -s \(search)")
    }
    let keychain = "\(directory)/release.keychain-db"
    if FileManager.default.fileExists(atPath: keychain) {
        try security("delete-keychain \(quoted(keychain))")
    }
    try FileManager.default.removeItem(atPath: directory)
}

func configureCredentials() throws {
    let directory = try credentialDirectory()
    try require(!FileManager.default.fileExists(atPath: directory), "Signing directory already exists")
    let p12String = try requiredEnvironment("MACOS_SIGNING_P12_BASE64")
    guard let p12 = Data(base64Encoded: p12String, options: .ignoreUnknownCharacters), !p12.isEmpty else { throw ReleaseError("Invalid signing archive") }
    let p12Password = try requiredEnvironment("MACOS_SIGNING_P12_PASSWORD")
    let sparkle = try requiredEnvironment("SPARKLE_PRIVATE_KEY").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let key = Data(base64Encoded: sparkle), [32, 64, 96].contains(key.count) else { throw ReleaseError("Invalid Sparkle private key export") }
    let credentials = try JSONDecoder().decode(NotaryCredentials.self, from: Data(requiredEnvironment("APPLE_NOTARY_CREDENTIALS_JSON").utf8))
    for value in [credentials.appleID, credentials.appSpecificPassword, credentials.teamID] {
        try require(!value.isEmpty && !value.contains(where: { $0.isNewline || $0 == "\0" }), "Invalid notary credential field")
    }
    let search = try run("/usr/bin/security", ["list-keychains", "-d", "user"]).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    let original = try run("/usr/bin/security", ["default-keychain", "-d", "user"]).trimmingCharacters(in: .whitespacesAndNewlines)
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    do {
        try JSONEncoder().encode(["search": search, "default": original]).write(to: URL(fileURLWithPath: "\(directory)/state.json"))
        let keychain = try quoted("\(directory)/release.keychain-db")
        let password = try quoted(UUID().uuidString + UUID().uuidString)
        try security("create-keychain -p \(password) \(keychain)")
        try security("set-keychain-settings -lut 21600 \(keychain)")
        try security("unlock-keychain -p \(password) \(keychain)")
        try security("list-keychains -d user -s \(keychain) \(search)")
        try security("default-keychain -d user -s \(keychain)")
        let p12Path = "\(directory)/certificate.p12"
        try require(FileManager.default.createFile(atPath: p12Path, contents: p12, attributes: [.posixPermissions: 0o600]), "Could not create signing archive")
        defer { try? FileManager.default.removeItem(atPath: p12Path) }
        try security("import \(quoted(p12Path)) -k \(keychain) -P \(quoted(p12Password)) -T /usr/bin/codesign -T /usr/bin/security")
        try security("set-key-partition-list -S apple-tool:,apple:,codesign: -s -k \(password) \(keychain)")
        let tools = FileManager.default.currentDirectoryPath + "/.build/artifacts/sparkle/Sparkle/bin"
        let values = try plistValues("Resources/Info.plist")
        guard let account = values["CFBundleIdentifier"] as? String, let publicKey = values["SUPublicEDKey"] as? String else { throw ReleaseError("Missing Sparkle identity") }
        try security("add-generic-password -a \(quoted(account)) -s https://sparkle-project.org -w \(quoted(sparkle)) -T \(quoted(tools + "/generate_keys")) -T \(quoted(tools + "/generate_appcast")) -T \(quoted(tools + "/sign_update")) \(keychain)")
        let actual = try run(tools + "/generate_keys", ["--account", account, "-p"], isQuiet: false).trimmingCharacters(in: .whitespacesAndNewlines)
        try require(actual == publicKey, "Sparkle private key does not match SUPublicEDKey")
        var environment = ProcessInfo.processInfo.environment
        environment["YOINK_NOTARY_APPLE_ID"] = credentials.appleID
        environment["YOINK_NOTARY_PASSWORD"] = credentials.appSpecificPassword
        environment["YOINK_NOTARY_TEAM_ID"] = credentials.teamID
        environment["YOINK_SIGNING_KEYCHAIN"] = "\(directory)/release.keychain-db"
        _ = try run("/usr/bin/expect", ["-c", """
        log_user 0
        set timeout 120
        spawn -noecho /usr/bin/xcrun notarytool store-credentials yoink-ci --keychain $env(YOINK_SIGNING_KEYCHAIN)
        expect {
            "Path to App Store Connect API private key:" {send -- "\\r"}
            timeout {exit 1}
            eof {exit 1}
        }
        expect {
            "Developer Apple ID:" {send -- "$env(YOINK_NOTARY_APPLE_ID)\\r"}
            timeout {exit 1}
            eof {exit 1}
        }
        expect {
            -re {App-specific password for .*:} {send -- "$env(YOINK_NOTARY_PASSWORD)\\r"}
            timeout {exit 1}
            eof {exit 1}
        }
        expect {
            "Developer Team ID:" {send -- "$env(YOINK_NOTARY_TEAM_ID)\\r"}
            timeout {exit 1}
            eof {exit 1}
        }
        expect {
            eof {}
            timeout {exit 1}
        }
        catch wait result
        exit [lindex $result 3]
        """], environment: environment, isQuiet: true)
    } catch {
        try cleanupCredentials()
        throw error
    }
}

func main() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else { throw ReleaseError("Missing command") }
    switch command {
    case "credentials":
        try configureCredentials()
    case "cleanup":
        try cleanupCredentials()
    case "candidate":
        try require(arguments.count == 3, "candidate expects current and previous plists")
        let app = try AppVersion(plist: arguments[1])
        let previous = try AppVersion(plist: arguments[2])
        let currentValues = try plistValues(arguments[1])
        let previousValues = try plistValues(arguments[2])
        for key in ["CFBundleIdentifier", "SUPublicEDKey", "SUFeedURL"] {
            try require(currentValues[key] as? String == previousValues[key] as? String, "Updater identity changes require separate review")
        }
        for key in ["SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"] {
            try require(currentValues[key] as? Bool == true, "Sparkle signature enforcement is required")
        }
        if app.version.isSame(as: previous.version) && app.build.isSame(as: previous.build) {
            print("is_release=false")
        } else {
            try app.checkIncrease(from: previous)
            print("is_release=true\nversion=\(app.version.text)\nbuild=\(app.build.text)\ntag=\(app.tag)")
        }
    case "inventory":
        try require(arguments.count == 4, "inventory expects plist, releases, latest")
        let app = try AppVersion(plist: arguments[1])
        let releases = try readReleases(arguments[2])
        let latest = try readRelease(arguments[3])
        try require(!latest.isDraft && !latest.isPrerelease && releases.contains { $0.id == latest.id }, "Missing preceding stable release")
        for release in releases {
            try require(release.tag_name != app.tag, "Release already exists, including drafts")
            try require(release.tag_name.hasPrefix("v"), "Unexpected release tag")
            let previous = try Version(String(release.tag_name.dropFirst()))
            try require(app.version.isGreater(than: previous), "Release version rollback or reuse")
            let feeds = release.assets.filter { $0.name == "appcast.xml" }
            try require(feeds.count == 1, "Every existing release must have its signed appcast; inspect incomplete drafts manually")
            print("\(release.id) \(feeds[0].id) \(release.tag_name)")
        }
    case "previous":
        try require(arguments.count == 5, "previous expects plist, verified feed, tag, repository")
        let app = try AppVersion(plist: arguments[1])
        let feed = try Feed(arguments[2])
        try require(feed.app.tag == arguments[3], "Previous feed/tag mismatch")
        try feed.check(feed.app, repository: arguments[4])
        try app.checkIncrease(from: feed.app)
    case "assets":
        try require(arguments.count == 5, "assets expects plist, metadata, repository, draft|published")
        let app = try AppVersion(plist: arguments[1])
        let release = try readRelease(arguments[2])
        try checkAssets(release, app: app, repository: arguments[3])
        try require(!release.isPrerelease && release.isDraft == (arguments[4] == "draft"), "Wrong publication state")
        try require(release.target_commitish == requiredEnvironment("GITHUB_SHA"), "Release target is not triggering commit")
        print(release.id)
    case "verify":
        try require(arguments.count == 4, "verify expects plist, assets directory, repository")
        let app = try AppVersion(plist: arguments[1])
        let directory = arguments[2]
        try require(Set(FileManager.default.contentsOfDirectory(atPath: directory)) == app.assets, "Unexpected local assets")
        let feed = try Feed("\(directory)/appcast.xml")
        try feed.check(app, repository: arguments[3])
        let attributes = try FileManager.default.attributesOfItem(atPath: "\(directory)/\(app.archive)")
        try require((attributes[.size] as? NSNumber)?.intValue == feed.length, "Archive length mismatch")
        let lines = try String(contentsOfFile: "\(directory)/SHA256SUMS", encoding: .utf8).split(separator: "\n")
        try require(lines.count == 3, "Expected three checksums")
        var names = Set<String>()
        for line in lines {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            try require(fields.count == 2 && fields[0].count == 64 && fields[0].allSatisfy { $0.isHexDigit && $0.isASCII }, "Malformed checksum")
            names.insert(String(fields[1]))
        }
        try require(names == app.assets.subtracting(["SHA256SUMS"]), "Checksum filenames mismatch")
        print(feed.signature)
    default:
        throw ReleaseError("Unknown command")
    }
}

do {
    try main()
} catch let error as ReleaseError {
    fputs("Release error: \(error.description)\n", stderr)
    exit(1)
} catch {
    fputs("Release input or operation failed\n", stderr)
    exit(1)
}
