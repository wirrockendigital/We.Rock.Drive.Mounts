import Foundation
import XCTest
@testable import WRDMCore

// UpdateServiceTests cover published Sparkle enclosure metadata and durable daily state.
final class UpdateServiceTests: XCTestCase {
    // The published Sparkle appcast stores version elements before an enclosure without version attributes.
    func testParsesPublishedSparkleItemElements() throws {
        let xml = """
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
          <sparkle:version>18</sparkle:version>
          <sparkle:shortVersionString>0.3.7</sparkle:shortVersionString>
          <enclosure url="https://github.com/example.zip" length="100" sparkle:edSignature="test" />
        </item></channel></rss>
        """
        let item = try XCTUnwrap(UpdateFeedParser.parse(Data(xml.utf8))?.first)
        XCTAssertEqual(item.build, 18)
        XCTAssertEqual(item.version, "0.3.7")
    }

    // A real appcast stores build metadata on enclosure rather than child elements.
    func testParsesSparkleEnclosureAndRejectsUnsafeNotesURL() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <sparkle:releaseNotesLink>https://github.com/wirrockendigital/We.Rock.Drive.Mounts/releases/tag/v0.3.6</sparkle:releaseNotesLink>
              <enclosure url="https://github.com/example.zip" sparkle:version="17" sparkle:shortVersionString="0.3.6" />
            </item>
            <item>
              <sparkle:releaseNotesLink>file:///tmp/notes</sparkle:releaseNotesLink>
              <enclosure url="https://github.com/other.zip" sparkle:version="18" sparkle:shortVersionString="0.3.7" />
            </item>
          </channel>
        </rss>
        """
        let items = try XCTUnwrap(UpdateFeedParser.parse(Data(xml.utf8)))
        XCTAssertEqual(items.map(\.build), [17, 18])
        XCTAssertEqual(items.map(\.version), ["0.3.6", "0.3.7"])
        XCTAssertEqual(items.first?.releaseNotesURL?.scheme, "https")
        XCTAssertEqual(items.last?.releaseNotesURL?.absoluteString,
                       "https://github.com/wirrockendigital/We.Rock.Drive.Mounts/releases/tag/v0.3.7")
    }

    // A successful check is due after one day, while a failed check retries after an hour.
    func testDailyCheckPersistsAndAvoidsDuplicateFetches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(homeDirectory: root)
        try paths.ensureDirectories()
        let feed = URL(string: "https://wirrockendigital.github.io/We.Rock.Drive.Mounts/appcast.xml")!
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <enclosure sparkle:version="18" sparkle:shortVersionString="0.3.7" />
        </item></channel></rss>
        """
        let protocolClass = UpdateFeedURLProtocol.self
        protocolClass.responseData = Data(xml.utf8)
        protocolClass.requestCount = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        let session = URLSession(configuration: configuration)
        let service = UpdateService(paths: paths, feedURL: feed, session: session, build: 17)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = await service.checkIfDue(now: now)
        XCTAssertEqual(first.availableVersion, "0.3.7")
        XCTAssertEqual(first.lastCheckedAt, now)
        XCTAssertEqual(protocolClass.requestCount, 1)
        _ = await service.checkIfDue(now: now.addingTimeInterval(86_399))
        XCTAssertEqual(protocolClass.requestCount, 1)
        _ = await service.checkIfDue(now: now.addingTimeInterval(86_400))
        XCTAssertEqual(protocolClass.requestCount, 2)
        let restored = await UpdateService(paths: paths, feedURL: feed, session: session, build: 17).read()
        XCTAssertEqual(restored.availableVersion, "0.3.7")
        await service.markNotified(version: "0.3.7")
        let notified = await service.read()
        XCTAssertEqual(notified.lastNotifiedVersion, "0.3.7")
    }

    // An installed release must not keep showing the availability cached by the older app.
    func testInstalledBuildHidesPreviouslyAvailableUpdate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(homeDirectory: root)
        try paths.ensureDirectories()
        let feed = URL(string: "https://wirrockendigital.github.io/We.Rock.Drive.Mounts/appcast.xml")!
        UpdateFeedURLProtocol.responseData = Data(Self.releaseXML.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateFeedURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let oldApp = UpdateService(paths: paths, feedURL: feed, session: session, build: 17)
        let beforeInstallation = await oldApp.check()
        XCTAssertEqual(beforeInstallation.availableVersion, "0.3.7")
        let installedApp = UpdateService(paths: paths, feedURL: feed, session: session, build: 18)
        let snapshot = await installedApp.read()
        XCTAssertNil(snapshot.availableVersion)
        XCTAssertNil(snapshot.availableBuild)
        XCTAssertNil(snapshot.releaseNotesURL)
    }

    // A feed response must retain a notification recorded while the network request was pending.
    func testConcurrentCheckPreservesNotification() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(homeDirectory: root)
        try paths.ensureDirectories()
        let feed = URL(string: "https://wirrockendigital.github.io/We.Rock.Drive.Mounts/appcast.xml")!
        UpdateFeedURLProtocol.responseData = Data(Self.releaseXML.utf8)
        let initialConfiguration = URLSessionConfiguration.ephemeral
        initialConfiguration.protocolClasses = [UpdateFeedURLProtocol.self]
        let original = UpdateService(paths: paths, feedURL: feed,
                                     session: URLSession(configuration: initialConfiguration), build: 17)
        _ = await original.check()

        let started = expectation(description: "Feed request is pending")
        PausedUpdateFeedURLProtocol.onStart = { request in
            PausedUpdateFeedURLProtocol.pending = request
            started.fulfill()
        }
        defer {
            PausedUpdateFeedURLProtocol.onStart = nil
            PausedUpdateFeedURLProtocol.pending = nil
        }
        let delayedConfiguration = URLSessionConfiguration.ephemeral
        delayedConfiguration.protocolClasses = [PausedUpdateFeedURLProtocol.self]
        let delayed = UpdateService(paths: paths, feedURL: feed,
                                    session: URLSession(configuration: delayedConfiguration), build: 17)
        let check = Task { await delayed.check() }
        await fulfillment(of: [started], timeout: 5)
        await original.markNotified(version: "0.3.7")
        PausedUpdateFeedURLProtocol.pending?.complete(with: Data(Self.releaseXML.utf8))
        _ = await check.value
        let afterConcurrentCheck = await original.read()
        XCTAssertEqual(afterConcurrentCheck.lastNotifiedVersion, "0.3.7")
    }

    private static let releaseXML = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <enclosure sparkle:version="18" sparkle:shortVersionString="0.3.7" />
        </item></channel></rss>
        """
}

// UpdateFeedURLProtocol supplies deterministic HTTPS responses without network access.
private final class UpdateFeedURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestCount += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// PausedUpdateFeedURLProtocol exposes the in-flight state needed for a cross-process write regression.
private final class PausedUpdateFeedURLProtocol: URLProtocol {
    nonisolated(unsafe) static var onStart: ((PausedUpdateFeedURLProtocol) -> Void)?
    nonisolated(unsafe) static var pending: PausedUpdateFeedURLProtocol?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.onStart?(self) }
    override func stopLoading() {}

    // complete returns the held HTTPS response after the competing write has finished.
    func complete(with data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
