import CryptoKit
import Foundation

// DiagnosticsService captures bounded macOS evidence and creates redacted support bundles.
public struct DiagnosticsService: Sendable {
    public let paths: AppPaths

    public init(paths: AppPaths = AppPaths()) {
        self.paths = paths
    }

    // captureMacEvidence stores only the configured recent power, network, and SMB slices.
    public func captureMacEvidence(lookbackMinutes: Int, label: String) throws -> URL {
        try paths.ensureDirectories()
        let safeLabel = label.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        let file = paths.diagnostics.appendingPathComponent("mac-\(timestamp())-\(safeLabel).log")
        let predicates = [
            "eventMessage CONTAINS[c] 'sleep' OR eventMessage CONTAINS[c] 'wake' OR eventMessage CONTAINS[c] 'DarkWake'",
            "process == 'configd' OR process == 'mDNSResponder' OR process == 'symptomsd'",
            "process == 'NetAuthSysAgent' OR process == 'NetAuthAgent' OR eventMessage CONTAINS[c] 'smb'",
        ]
        var sections: [String] = []
        for (index, predicate) in predicates.enumerated() {
            let result = try? ProcessRunner.run(
                "/usr/bin/log",
                arguments: ["show", "--style", "compact", "--last", "\(max(1, lookbackMinutes))m", "--predicate", predicate],
                timeout: 20
            )
            let boundedOutput = boundedTail(result?.stdout ?? result?.stderr ?? "Unavailable", bytes: 500_000)
            sections.append("## source-\(index + 1)\n\(redact(boundedOutput))")
        }
        let pmset = try? ProcessRunner.run("/usr/bin/pmset", arguments: ["-g", "log"], timeout: 10)
        let boundedPowerLog = boundedTail(pmset?.stdout ?? "Unavailable", bytes: 300_000)
        sections.append("## pmset\n\(redact(boundedPowerLog))")
        try SecureFileAccess.writeAtomically(Data(sections.joined(separator: "\n\n").utf8), to: file)
        return file
    }

    // correlate groups nearby events and reports a hypothesis as uncertain by design.
    public func correlate(events: [DiagnosticEvent], window: TimeInterval = 120) -> [Incident] {
        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        var groups: [[DiagnosticEvent]] = []
        for event in sorted {
            if var latest = groups.popLast() {
                if let previous = latest.last, event.timestamp.timeIntervalSince(previous.timestamp) <= window {
                    latest.append(event)
                    groups.append(latest)
                } else {
                    groups.append(latest)
                    groups.append([event])
                }
            } else {
                groups.append([event])
            }
        }
        return groups.map { group in
            let types = Set(group.map(\.type))
            let containsMountInterruption = types.contains(.mountLost) || types.contains(.mountIncidentOpened)
            let hypothesis: String
            let confidence: Double
            if types.contains(.networkChanged) && containsMountInterruption {
                hypothesis = "The mount interruption is temporally correlated with a network change."
                confidence = 0.7
            } else if types.contains(.sleep) && containsMountInterruption {
                hypothesis = "The mount interruption is temporally correlated with a sleep transition."
                confidence = 0.65
            } else {
                hypothesis = "The available events do not establish a specific cause."
                confidence = 0.25
            }
            return Incident(
                id: UUID(),
                startedAt: group.first?.timestamp ?? Date(),
                endedAt: group.last?.timestamp ?? Date(),
                title: group.count == 1 ? group[0].summary : "\(group.count) related events",
                hypothesis: hypothesis,
                confidence: confidence,
                evidenceIDs: group.map(\.id)
            )
        }
    }

    // exportSupportArchive stages privately and publishes only an integrity-checked ZIP.
    public func exportSupportArchive(settings: AppSettings, status: AgentStatus, events: [DiagnosticEvent],
                                     traffic: [InterfaceTrafficSample], destination: URL? = nil) throws -> URL {
        let bundle = try exportSupportBundle(settings: settings, status: status, events: events, traffic: traffic)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let folder = destination ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard let folder, FileManager.default.isWritableFile(atPath: folder.path) else {
            throw NetworkChangeError.rejected("DOWNLOADS_ACCESS_REQUIRED: Choose a writable export folder.")
        }
        let name = "support-\(timestamp())-\(UUID().uuidString.prefix(8)).zip"
        let temporary = bundle.deletingLastPathComponent().appendingPathComponent(".\(name)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = try ProcessRunner.run("/usr/bin/ditto", arguments: ["-c", "-k", "--keepParent", bundle.path, temporary.path], timeout: 60)
        guard archive.exitCode == 0, !archive.timedOut else { throw NetworkChangeError.rejected("ZIP_CREATION_FAILED") }
        try Self.validateArchive(temporary)
        let output = folder.appendingPathComponent(name)
        // Do not chmod a user's Downloads directory; only the exported file receives private permissions.
        let staging = folder.appendingPathComponent(".wrdm-" + UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: temporary, to: staging)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        try FileManager.default.moveItem(at: staging, to: output)
        return output
    }

    // validateArchive is shared by publication and corruption regression tests.
    public static func validateArchive(_ file: URL) throws {
        let check = try ProcessRunner.run("/usr/bin/unzip", arguments: ["-t", file.path], timeout: 60)
        guard check.exitCode == 0, !check.timedOut else { throw NetworkChangeError.rejected("ZIP_INTEGRITY_FAILED") }
    }

    // exportSupportBundle writes an inspectable directory with a manifest and redacted evidence.
    public func exportSupportBundle(
        settings: AppSettings,
        status: AgentStatus,
        events: [DiagnosticEvent],
        traffic: [InterfaceTrafficSample]
    ) throws -> URL {
        try paths.ensureDirectories()
        let bundle = paths.diagnostics.appendingPathComponent("support-\(timestamp())-\(UUID().uuidString.prefix(8)).supportbundle", isDirectory: true)
        try SecureFileAccess.ensureDirectory(bundle)
        let redactor = SupportRedactor(settings: settings)
        let safeSettings = redactedSettings(settings, using: redactor)
        let safeStatus = redactedStatus(status, using: redactor)
        let safeEvents = events.map { redactedEvent($0, using: redactor) }
        let safeMountIncidents = redactedMountIncidents(using: redactor)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SecureFileAccess.writeAtomically(try encoder.encode(safeSettings), to: bundle.appendingPathComponent("settings.json"))
        try SecureFileAccess.writeAtomically(try encoder.encode(safeStatus), to: bundle.appendingPathComponent("status.json"))
        try SecureFileAccess.writeAtomically(try encoder.encode(safeEvents), to: bundle.appendingPathComponent("events.json"))
        try SecureFileAccess.writeAtomically(try encoder.encode(traffic), to: bundle.appendingPathComponent("traffic.json"))
        try SecureFileAccess.writeAtomically(try encoder.encode(safeMountIncidents), to: bundle.appendingPathComponent("mount-incidents.json"))
        // Export observation is read-only and is kept separate from the agent's last decision.
        let observation = NetworkObservation.collect(settings: settings)
        let networkFiles = NetworkFiles(paths: paths)
        var networkData: [String: Any] = [
            "exportObservation": try JSONSerialization.jsonObject(with: encoder.encode(observation)),
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "agentVersion": "unknown"
        ]
        if let report = networkFiles.report() {
            networkData["agentVersion"] = report.agentVersion ?? "unknown"
            networkData["lastAgentDecision"] = try JSONSerialization.jsonObject(with: encoder.encode(report))
            networkData["observationAgeSeconds"] = Date().timeIntervalSince(report.observation.timestamp)
        }
        if settings.diagnostics.enabled && settings.diagnostics.networkEventsEnabled {
            networkData["history"] = try JSONSerialization.jsonObject(with: encoder.encode(networkFiles.history()))
        }
        if let data = try? Data(contentsOf: NetworkChanges(paths: paths).resultURL),
           let result = try? JSONSerialization.jsonObject(with: data) { networkData["restoration"] = result }
        try SecureFileAccess.writeAtomically(JSONSerialization.data(withJSONObject: redactNetwork(networkData, using: redactor), options: [.prettyPrinted, .sortedKeys]),
                                            to: bundle.appendingPathComponent("network.json"))
        let evidence = try exportEvidenceManifest(events: events, into: bundle, redactor: redactor)
        try SecureFileAccess.writeAtomically(try encoder.encode(evidence), to: bundle.appendingPathComponent("evidence-manifest.json"))
        let manifest = "We Rock Drive Mounts support bundle\nCreated: \(ISO8601DateFormatter().string(from: Date()))\nEvents: \(events.count)\nMount incidents: \(safeMountIncidents.count)\nTraffic samples: \(traffic.count)\n"
        try SecureFileAccess.writeAtomically(Data(manifest.utf8), to: bundle.appendingPathComponent("manifest.txt"))
        return bundle
    }

    // redactNetwork protects identities, names, addresses and probe targets while retaining measurable values.
    private func redactNetwork(_ value: Any, key: String = "", using redactor: SupportRedactor) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues { $0 }.reduce(into: [String: Any]()) { result, pair in
                result[pair.key] = redactNetwork(pair.value, key: pair.key, using: redactor)
            }
        }
        if let array = value as? [Any] { return array.map { redactNetwork($0, key: key, using: redactor) } }
        if let text = value as? String {
            let protected = ["id", "portID", "selectedPortID", "serviceID", "hardwareID", "networkID", "locationID", "contextID", "name", "host", "routerIPv4", "resolvedAddress", "addresses", "serviceOrder", "order", "summary"]
            if protected.contains(key), UUID(uuidString: text) == nil { return redactor.pseudonym(category: "NETWORK", value: text) }
            return redactor.redactText(text)
        }
        return value
    }

    // redactedEvent removes common token classes and optionally user-home paths.
    public func redactedEvent(_ event: DiagnosticEvent) -> DiagnosticEvent {
        redactedEvent(event, using: SupportRedactor())
    }

    // redactedEvent applies field-aware protection while preserving correlation identifiers and event types.
    private func redactedEvent(_ event: DiagnosticEvent, using redactor: SupportRedactor) -> DiagnosticEvent {
        var copy = event
        copy.source = redactor.redactSource(copy.source)
        copy.summary = redactor.redactText(copy.summary)
        copy.details = Dictionary(uniqueKeysWithValues: copy.details.map { key, value in
            (key, redactor.redactDetail(key: key, value: value))
        })
        if let path = copy.evidencePath {
            copy.evidencePath = redactor.pseudonym(category: "PATH", value: path)
        }
        return copy
    }

    public func redact(_ value: String) -> String {
        SupportRedactor().redactText(value)
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    // redactedSettings pseudonymizes every operational endpoint while keeping feature switches inspectable.
    private func redactedSettings(_ settings: AppSettings, using redactor: SupportRedactor) -> AppSettings {
        var copy = settings
        for index in copy.mounts.indices {
            copy.mounts[index].name = redactor.pseudonym(category: "MOUNT", value: copy.mounts[index].name)
            copy.mounts[index].url = redactor.redactSMBURL(copy.mounts[index].url)
        }
        if var discovery = copy.network.discovery {
            discovery.preferredPortID = discovery.preferredPortID.map { redactor.pseudonym(category: "NETWORK", value: $0) }
            discovery.profiles = discovery.profiles.map { profile in
                var safe = profile
                safe.portID = redactor.pseudonym(category: "NETWORK", value: profile.portID)
                safe.networkID = redactor.pseudonym(category: "NETWORK", value: profile.networkID)
                return safe
            }
            copy.network.discovery = discovery
        }
        copy.network.gatewayHost = redactor.redactOptional(category: "HOST", value: copy.network.gatewayHost)
        copy.network.remoteReachabilityHosts = copy.network.remoteReachabilityHosts.map { redactor.pseudonym(category: "HOST", value: $0) }
        copy.packetCapture.host = redactor.redactOptional(category: "HOST", value: copy.packetCapture.host)
        copy.packetCapture.user = redactor.redactOptional(category: "USER", value: copy.packetCapture.user)
        copy.packetCapture.remoteDirectory = redactor.redactOptional(category: "PATH", value: copy.packetCapture.remoteDirectory)
        copy.synology.sshHost = redactor.redactOptional(category: "HOST", value: copy.synology.sshHost)
        copy.synology.sshUser = redactor.redactOptional(category: "USER", value: copy.synology.sshUser)
        copy.synology.dsmBaseURL = redactor.redactOptional(category: "URL", value: copy.synology.dsmBaseURL)
        copy.wake.targetName = redactor.redactOptional(category: "DEVICE", value: copy.wake.targetName)
        copy.wake.targetMACAddress = redactor.redactOptional(category: "MAC", value: copy.wake.targetMACAddress)
        copy.wake.targetHost = redactor.redactOptional(category: "HOST", value: copy.wake.targetHost)
        for index in copy.wake.routes.indices {
            copy.wake.routes[index].command = redactor.redactOptional(category: "WAKE", value: copy.wake.routes[index].command)
        }
        return copy
    }

    // redactedStatus removes paths and adapter error details without changing health counters or state enums.
    private func redactedStatus(_ status: AgentStatus, using redactor: SupportRedactor) -> AgentStatus {
        var copy = status
        copy.lastError = copy.lastError.map(redactor.redactText)
        copy.mountStates = copy.mountStates?.map { state in
            var safe = state
            safe.message = redactor.redactText(safe.message)
            safe.localPath = safe.localPath.map { redactor.pseudonym(category: "PATH", value: $0) }
            return safe
        }
        if var execution = copy.networkExecution {
            execution.reason = redactor.redactText(execution.reason)
            execution.error = execution.error.map(redactor.redactText)
            copy.networkExecution = execution
        }
        return copy
    }

    // redactedMountIncidents includes the durable recovery timeline without exporting names or local paths.
    private func redactedMountIncidents(using redactor: SupportRedactor) -> [MountIncident] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let incidents: [MountIncident] = (try? SecureFileAccess.withLock(for: paths.mountIncidentsFile, exclusive: false) { () -> [MountIncident] in
            guard let data = try? Data(contentsOf: paths.mountIncidentsFile),
                  let values = try? decoder.decode([MountIncident].self, from: data) else { return [] }
            return values
        }) ?? []
        return incidents.map { incident in
            var safe = incident
            safe.mountName = redactor.pseudonym(category: "MOUNT", value: safe.mountName)
            safe.message = redactor.redactText(safe.message)
            safe.evidencePath = redactor.pseudonym(category: "PATH", value: safe.evidencePath)
            safe.diagnosticEvidencePaths = safe.diagnosticEvidencePaths.map { redactor.pseudonym(category: "PATH", value: $0) }
            return safe
        }
    }

    // exportEvidenceManifest includes bounded text evidence and metadata-only packet references.
    private func exportEvidenceManifest(events: [DiagnosticEvent], into bundle: URL, redactor: SupportRedactor) throws -> [EvidenceManifestEntry] {
        let evidenceDirectory = bundle.appendingPathComponent("evidence", isDirectory: true)
        try SecureFileAccess.ensureDirectory(evidenceDirectory)
        let diagnosticsRoot = paths.diagnostics.resolvingSymlinksInPath().path + "/"
        var entries: [EvidenceManifestEntry] = []
        for event in events {
            guard let path = event.evidencePath else { continue }
            let source = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard source.path.hasPrefix(diagnosticsRoot),
                  FileManager.default.fileExists(atPath: source.path) else { continue }
            let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let isText = ["log", "txt", "json"].contains(source.pathExtension.lowercased())
            var includedFile: String?
            if isText, let data = try? Data(contentsOf: source) {
                let outputName = "\(event.id.uuidString).\(source.pathExtension.isEmpty ? "txt" : source.pathExtension)"
                let boundedData = Data(data.suffix(200_000))
                let text = redactor.redactText(String(decoding: boundedData, as: UTF8.self))
                try SecureFileAccess.writeAtomically(Data(text.utf8), to: evidenceDirectory.appendingPathComponent(outputName))
                includedFile = "evidence/\(outputName)"
            }
            entries.append(EvidenceManifestEntry(
                eventID: event.id,
                type: event.type.rawValue,
                source: redactor.redactSource(event.source),
                originalPath: redactor.pseudonym(category: "PATH", value: path),
                sizeBytes: size,
                includedFile: includedFile
            ))
        }
        return entries
    }

    // boundedTail keeps evidence closest to the observed incident when command output is oversized.
    private func boundedTail(_ value: String, bytes: Int) -> String {
        String(decoding: Data(value.utf8.suffix(bytes)), as: UTF8.self)
    }
}

// EvidenceManifestEntry binds exported excerpts or metadata to their originating diagnostic event.
private struct EvidenceManifestEntry: Codable {
    var eventID: UUID
    var type: String
    var source: String
    var originalPath: String
    var sizeBytes: Int
    var includedFile: String?
}

// SupportRedactor creates bundle-local, non-reversible pseudonyms without exporting its random HMAC key.
private struct SupportRedactor {
    private let key: SymmetricKey
    private let literalTargets: [(category: String, value: String)]
    private let canonicalSources: Set<String> = [
        "agent", "agent-scheduler", "app", "cli", "mcp", "macOS", "macOS-pmset", "network-policy", "power",
        "raspberry-pi", "synology", "synology-dsm", "synology-ssh", "synology-syslog",
    ]

    // init binds configured operational labels to this bundle's one-time pseudonym key.
    init(settings: AppSettings? = nil) {
        key = SymmetricKey(size: .bits256)
        guard let settings else {
            literalTargets = []
            return
        }
        var targets: [(category: String, value: String)] = []
        func add(_ category: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 4 else { return }
            targets.append((category, trimmed))
        }
        for mount in settings.mounts {
            add("MOUNT", mount.name)
        }
        add("HOST", settings.network.gatewayHost)
        settings.network.remoteReachabilityHosts.forEach { add("HOST", $0) }
        add("HOST", settings.packetCapture.host)
        add("USER", settings.packetCapture.user)
        add("PATH", settings.packetCapture.remoteDirectory)
        add("HOST", settings.synology.sshHost)
        add("USER", settings.synology.sshUser)
        add("URL", settings.synology.dsmBaseURL)
        add("DEVICE", settings.wake.targetName)
        add("MAC", settings.wake.targetMACAddress)
        add("HOST", settings.wake.targetHost)
        settings.wake.routes.forEach { add("WAKE", $0.command) }
        literalTargets = targets.sorted { $0.value.count > $1.value.count }
    }

    // pseudonym preserves equality inside one bundle but cannot be recomputed after export.
    func pseudonym(category: String, value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = HMAC<SHA256>.authenticationCode(for: Data(normalized.utf8), using: key)
        let token = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "[\(category.uppercased())-\(token)]"
    }

    // redactOptional retains empty optional settings while protecting every populated endpoint.
    func redactOptional(category: String, value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : pseudonym(category: category, value: value)
    }

    // redactSMBURL retains only pseudonymous host/share correlation.
    func redactSMBURL(_ value: String) -> String {
        guard let components = URLComponents(string: value), let host = components.host else {
            return pseudonym(category: "SMB", value: value)
        }
        let path = components.percentEncodedPath.removingPercentEncoding ?? components.path
        return "smb://\(pseudonym(category: "HOST", value: host))/\(pseudonym(category: "SHARE", value: path))"
    }

    // redactSource keeps canonical subsystem labels and pseudonymizes mount, host, and device labels.
    func redactSource(_ value: String) -> String {
        canonicalSources.contains(value) ? value : pseudonym(category: "SOURCE", value: value)
    }

    // redactDetail uses key semantics before applying generic text redaction.
    func redactDetail(key detailKey: String, value: String) -> String {
        let normalizedKey = detailKey.lowercased()
        let sensitiveFragments = [
            "host", "server", "share", "url", "path", "filter", "probe", "target",
            "user", "account", "credential", "password", "secret", "token", "key", "wake",
        ]
        if sensitiveFragments.contains(where: normalizedKey.contains) {
            return pseudonym(category: "VALUE", value: value)
        }
        return redactText(value)
    }

    // redactText protects secrets, SMB endpoints, private addresses, private names, and user paths in free-form evidence.
    func redactText(_ value: String) -> String {
        var output = value
        output = replacingMatches(in: output, pattern: "(?i)smb://[^\\s\\\"'<>]+") { redactSMBURL($0) }
        output = replacingMatches(in: output, pattern: "(?i)/(?:Users|home)/[^\\r\\n\\\"'<>]+") {
            pseudonym(category: "PATH", value: $0)
        }
        output = replacingMatches(in: output, pattern: "(?i)/Volumes/[A-Za-z0-9._% -]+") {
            pseudonym(category: "PATH", value: $0)
        }
        output = replacingMatches(in: output, pattern: "(?i)\\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\\b") {
            pseudonym(category: "MAC", value: $0)
        }
        output = replacingMatches(in: output, pattern: "\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b") {
            isPrivateIPv4($0) ? pseudonym(category: "IP", value: $0) : $0
        }
        output = replacingMatches(in: output, pattern: "(?i)\\b(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}\\b") {
            isPrivateIPv6($0) ? pseudonym(category: "IP", value: $0) : $0
        }
        output = replacingMatches(in: output, pattern: "(?i)\\b(?:[a-z0-9-]+\\.)+(?:local|lan|home|internal|private)\\b") {
            pseudonym(category: "HOST", value: $0)
        }
        let secretPatterns = [
            "(?i)(password|token|secret|authorization|api[_-]?key|credential)[=: ]+[^\\s]+",
            "(?i)bearer[ ]+[A-Za-z0-9._~+/=-]{8,}",
            "gh[pousr]_[A-Za-z0-9_]{20,}",
            "github_pat_[A-Za-z0-9_]{20,}",
            "prd_[A-Za-z0-9_=-]{20,}",
            "sk-[A-Za-z0-9_-]{16,}",
        ]
        for pattern in secretPatterns {
            output = replacingMatches(in: output, pattern: pattern) { pseudonym(category: "SECRET", value: $0) }
        }
        for target in literalTargets {
            output = output.replacingOccurrences(
                of: target.value,
                with: pseudonym(category: target.category, value: target.value),
                options: [.caseInsensitive]
            )
        }
        return output
    }

    // replacingMatches applies computed replacements from the end so regular-expression ranges remain valid.
    private func replacingMatches(in value: String, pattern: String, transform: (String) -> String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let mutable = NSMutableString(string: value)
        let range = NSRange(location: 0, length: mutable.length)
        for match in expression.matches(in: value, range: range).reversed() {
            let raw = mutable.substring(with: match.range)
            mutable.replaceCharacters(in: match.range, with: transform(raw))
        }
        return mutable as String
    }

    // isPrivateIPv4 covers local, private, loopback, link-local, and carrier-grade NAT ranges.
    private func isPrivateIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10
            || parts[0] == 127
            || (parts[0] == 169 && parts[1] == 254)
            || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 100 && (64...127).contains(parts[1]))
    }

    // isPrivateIPv6 covers unique-local, link-local, and loopback addresses.
    private func isPrivateIPv6(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized == "::1"
            || normalized.hasPrefix("fc")
            || normalized.hasPrefix("fd")
            || normalized.hasPrefix("fe8")
            || normalized.hasPrefix("fe9")
            || normalized.hasPrefix("fea")
            || normalized.hasPrefix("feb")
    }
}
