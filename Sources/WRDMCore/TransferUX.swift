import Foundation

// TransferSourceSelection validates user-provided file URLs before they become a transfer draft.
public enum TransferSourceSelection {
    // validatedPaths accepts only existing local files or directories and removes duplicate paths.
    public static func validatedPaths(from urls: [URL], fileManager: FileManager = .default) throws -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        for url in urls {
            guard url.isFileURL else {
                throw TransferServiceError.invalidRequest("Only local files and folders can be transferred.")
            }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix("/"), fileManager.fileExists(atPath: path) else {
                throw TransferServiceError.invalidRequest("The selected file or folder is no longer available: \(path)")
            }
            if seen.insert(path).inserted {
                paths.append(path)
            }
        }
        guard !paths.isEmpty else {
            throw TransferServiceError.invalidRequest("Select at least one source file or folder.")
        }
        return paths
    }
}

// TransferHandoff defines the generic URL contract shared by Finder integration and the main app.
public enum TransferHandoff {
    public static let scheme = "wrdm-transfer"
    public static let openHost = "open"

    // makeURL serializes local source paths without introducing a second transfer engine.
    public static func makeURL(sourcePaths: [String]) -> URL? {
        guard !sourcePaths.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = openHost
        components.queryItems = sourcePaths.map { URLQueryItem(name: "source", value: $0) }
        return components.url
    }

    // sourceURLs parses only the registered handoff route and rejects relative or empty paths.
    public static func sourceURLs(from url: URL) throws -> [URL] {
        guard url.scheme == scheme, url.host == openHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw TransferServiceError.invalidRequest("The Finder transfer request is invalid.")
        }
        let paths = (components.queryItems ?? [])
            .filter { $0.name == "source" }
            .compactMap(\.value)
            .filter { $0.hasPrefix("/") }
        guard !paths.isEmpty else {
            throw TransferServiceError.invalidRequest("The Finder transfer request contains no source files or folders.")
        }
        return paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
    }
}

// TransferStatusSummary is the single compact progress model used by the menu-bar status item.
public struct TransferStatusSummary: Equatable, Sendable {
    public var activeJobCount: Int
    public var percent: Int?

    public init(activeJobCount: Int, percent: Int?) {
        self.activeJobCount = activeJobCount
        self.percent = percent
    }

    // current combines queued and running jobs while preferring byte-weighted progress evidence.
    public static func current(jobs: [TransferJob]) -> TransferStatusSummary {
        let active = jobs.filter { $0.state == .queued || $0.state == .running }
        guard !active.isEmpty else { return TransferStatusSummary(activeJobCount: 0, percent: nil) }

        let byteJobs = active.compactMap { job -> (UInt64, UInt64)? in
            guard let completed = job.progress.completedBytes,
                  let total = job.progress.totalBytes,
                  total > 0 else { return nil }
            return (min(completed, total), total)
        }
        if byteJobs.count == active.count {
            let completed = byteJobs.reduce(UInt64(0)) { $0 + $1.0 }
            let total = byteJobs.reduce(UInt64(0)) { $0 + $1.1 }
            let value = total == 0 ? 0 : Int((Double(completed) / Double(total) * 100).rounded())
            return TransferStatusSummary(activeJobCount: active.count, percent: min(100, max(0, value)))
        }

        let percentages = active.compactMap(\.progress.percent)
        let value = percentages.isEmpty ? 0 : Int((percentages.reduce(0, +) / Double(percentages.count)).rounded())
        return TransferStatusSummary(activeJobCount: active.count, percent: min(100, max(0, value)))
    }
}

// TransferPathSelection derives direction from paths instead of an independent UI toggle.
public enum TransferPathSelection {
    // direction requires one SMB side and resolves aliases before comparing directory boundaries.
    public static func direction(sources: [String], destination: String, smbRoots: [URL]) throws -> TransferDirection {
        let roots = smbRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        func isSMB(_ value: String) -> Bool {
            let path = URL(fileURLWithPath: value).standardizedFileURL.resolvingSymlinksInPath().path
            return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        guard !sources.isEmpty else {
            throw TransferServiceError.invalidRequest("Select at least one source file or folder.")
        }
        if isSMB(destination), sources.allSatisfy({ !isSMB($0) }) { return .macToNAS }
        if !isSMB(destination), sources.allSatisfy({ isSMB($0) }) { return .nasToMac }
        throw TransferServiceError.invalidRequest("Select files on your Mac and a connected SMB destination, or SMB sources and a folder on your Mac.")
    }
}
