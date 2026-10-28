import Foundation

// UpdateSnapshot is the shared, private status shown by the menu-bar app.
public struct UpdateSnapshot: Codable, Equatable, Sendable {
    public var lastAttemptAt: Date?
    public var lastCheckedAt: Date?
    public var availableVersion: String?
    public var availableBuild: Int?
    public var releaseNotesURL: URL?
    public var lastError: String?
    public var lastNotifiedVersion: String?

    public init(lastAttemptAt: Date? = nil, lastCheckedAt: Date? = nil, availableVersion: String? = nil,
                availableBuild: Int? = nil, releaseNotesURL: URL? = nil, lastError: String? = nil,
                lastNotifiedVersion: String? = nil) {
        self.lastAttemptAt = lastAttemptAt
        self.lastCheckedAt = lastCheckedAt
        self.availableVersion = availableVersion
        self.availableBuild = availableBuild
        self.releaseNotesURL = releaseNotesURL
        self.lastError = lastError
        self.lastNotifiedVersion = lastNotifiedVersion
    }
}

// UpdateFeedItem contains only data needed to compare a published appcast entry.
public struct UpdateFeedItem: Equatable, Sendable {
    public let version: String
    public let build: Int
    public let releaseNotesURL: URL?
}

// UpdateFeedParser accepts only versioned releases from the fixed GitHub-hosted feed.
public final class UpdateFeedParser: NSObject, XMLParserDelegate {
    private var items: [UpdateFeedItem] = []
    private var currentBuild: Int?
    private var currentVersion: String?
    private var currentNotes: URL?
    private var buffer = ""

    // parse returns all well-formed version entries without trusting release titles.
    public static func parse(_ data: Data) -> [UpdateFeedItem]? {
        guard data.count <= 1_000_000 else { return nil }
        let delegate = UpdateFeedParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.items
    }

    public func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                       qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        buffer = ""
        if elementName == "item" {
            currentBuild = nil
            currentVersion = nil
            currentNotes = nil
        }
        if elementName == "sparkle:releaseNotesLink", let raw = attributeDict["href"] {
            currentNotes = Self.allowedNotesURL(raw)
        }
        // Sparkle publishes the build and display version on the enclosure.
        if elementName == "enclosure" {
            currentBuild = attributeDict["sparkle:version"].flatMap(Int.init)
            currentVersion = attributeDict["sparkle:shortVersionString"]
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        if buffer.count < 2_000 { buffer += string }
    }

    public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                       qualifiedName qName: String?) {
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "sparkle:version": currentBuild = Int(value)
        case "sparkle:shortVersionString": currentVersion = value
        case "sparkle:releaseNotesLink": currentNotes = Self.allowedNotesURL(value)
        case "item":
            if let build = currentBuild, build > 0, let version = currentVersion,
               version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil {
                // Embedded notes are opened through their canonical GitHub release page.
                let notes = currentNotes ?? URL(string: "https://github.com/wirrockendigital/We.Rock.Drive.Mounts/releases/tag/v\(version)")
                items.append(UpdateFeedItem(version: version, build: build, releaseNotesURL: notes))
            }
        default: break
        }
        buffer = ""
    }

    // allowedNotesURL prevents remote feed content from opening arbitrary locations.
    private static func allowedNotesURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme == "https",
              ["github.com", "wirrockendigital.github.io"].contains(url.host?.lowercased() ?? "") else { return nil }
        return url
    }
}

// UpdateService performs read-only checks and persists one cross-process status snapshot.
public actor UpdateService {
    public static let feedURL = URL(string: "https://wirrockendigital.github.io/We.Rock.Drive.Mounts/appcast.xml")!
    private let paths: AppPaths
    private let feedURL: URL
    private let session: URLSession
    private let build: Int

    public init(paths: AppPaths = AppPaths(), feedURL: URL = UpdateService.feedURL,
                session: URLSession = .shared, build: Int? = nil) {
        self.paths = paths
        self.feedURL = feedURL
        self.session = session
        self.build = build ?? Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
    }

    // read returns the latest durable status without assuming that no status means up to date.
    public func read() -> UpdateSnapshot {
        (try? SecureFileAccess.withLock(for: paths.updateStatusFile, exclusive: false) {
            guard let data = try? Data(contentsOf: paths.updateStatusFile) else { return UpdateSnapshot() }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode(UpdateSnapshot.self, from: data)) ?? UpdateSnapshot()
        }) ?? UpdateSnapshot()
    }

    // checkIfDue checks every day after success and retries failures after one hour.
    public func checkIfDue(now: Date = Date()) async -> UpdateSnapshot {
        let snapshot = read()
        if let last = snapshot.lastAttemptAt {
            let interval: TimeInterval = snapshot.lastError == nil ? 86_400 : 3_600
            if now.timeIntervalSince(last) < interval { return snapshot }
        }
        return await check(now: now)
    }

    // check fetches the fixed feed with a bounded request and records explicit errors.
    @discardableResult
    public func check(now: Date = Date()) async -> UpdateSnapshot {
        var snapshot = read()
        snapshot.lastAttemptAt = now
        do {
            var request = URLRequest(url: feedURL)
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  response.url?.scheme == "https", response.url?.host == feedURL.host,
                  let items = UpdateFeedParser.parse(data), !items.isEmpty else {
                throw UpdateCheckError.invalidFeed
            }
            let newest = items.max { $0.build < $1.build }
            snapshot.lastCheckedAt = now
            let isNewer = (newest?.build ?? 0) > build
            snapshot.availableVersion = isNewer ? newest?.version : nil
            snapshot.availableBuild = isNewer ? newest?.build : nil
            snapshot.releaseNotesURL = isNewer ? newest?.releaseNotesURL : nil
            snapshot.lastError = nil
        } catch {
            snapshot.lastError = "Update-Server nicht erreichbar oder Antwort ungültig."
        }
        try? write(snapshot)
        return snapshot
    }

    // markNotified persists notification deduplication across agent restarts.
    public func markNotified(version: String) {
        var snapshot = read()
        guard snapshot.availableVersion == version else { return }
        snapshot.lastNotifiedVersion = version
        try? write(snapshot)
    }

    // write uses the existing private, atomic runtime-file contract.
    private func write(_ snapshot: UpdateSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try SecureFileAccess.withLock(for: paths.updateStatusFile) {
            try SecureFileAccess.writeAtomically(try encoder.encode(snapshot), to: paths.updateStatusFile)
        }
    }
}

// UpdateCheckError keeps malformed feed content separate from a valid empty result.
private enum UpdateCheckError: Error {
    case invalidFeed
}
