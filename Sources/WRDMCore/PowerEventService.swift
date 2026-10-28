import Foundation

// PowerEventProviding exposes only macOS-authored sleep and wake evidence to the agent.
public protocol PowerEventProviding: Sendable {
    func events(since: Date?, until: Date) -> [DiagnosticEvent]
}

// MacOSPowerEventSource reads bounded pmset history instead of inferring power events from scheduler gaps.
public struct MacOSPowerEventSource: PowerEventProviding {
    private let process: any ProcessExecuting

    public init(process: any ProcessExecuting = SystemProcessExecutor()) {
        self.process = process
    }

    // events returns only source lines whose timestamps fall inside the requested monitoring window.
    public func events(since: Date?, until: Date) -> [DiagnosticEvent] {
        guard let since else { return [] }
        guard let result = try? process.run(
            "/usr/bin/pmset",
            arguments: ["-g", "log"],
            input: nil,
            timeout: 8,
            environment: nil
        ), result.exitCode == 0 else { return [] }
        return Self.parse(result.stdout, since: since, until: until)
    }

    // parse converts only explicit Sleep, Wake, and DarkWake records into canonical diagnostic events.
    public static func parse(_ output: String, since: Date, until: Date) -> [DiagnosticEvent] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        var events: [DiagnosticEvent] = []
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            guard line.count >= 25 else { continue }
            let timestampText = String(line.prefix(25))
            guard let timestamp = formatter.date(from: timestampText), timestamp > since, timestamp <= until else { continue }
            let remainder = String(line.dropFirst(25))
            let sourceKind = remainder.split(whereSeparator: \.isWhitespace).first.map(String.init)
            let eventType: DiagnosticEventType
            let powerKind: String
            if sourceKind == "Sleep" {
                eventType = .sleep
                powerKind = "Sleep"
            } else if sourceKind == "DarkWake" {
                eventType = .wake
                powerKind = "DarkWake"
            } else if sourceKind == "Wake" {
                eventType = .wake
                powerKind = "Wake"
            } else {
                continue
            }
            events.append(DiagnosticEvent(
                timestamp: timestamp,
                type: eventType,
                source: "macOS-pmset",
                summary: "macOS reported \(powerKind)",
                details: ["powerKind": powerKind, "inferred": "false"]
            ))
        }
        return events.sorted { $0.timestamp < $1.timestamp }
    }
}
