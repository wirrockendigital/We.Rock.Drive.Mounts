import Foundation
import Security
#if canImport(FoundationModels) && arch(arm64)
import FoundationModels
#endif

// AIProvider defines one evidence-bounded analysis contract for local and cloud models.
public protocol AIProvider: Sendable {
    var availabilityDescription: String { get }
    func analyze(question: String, evidence: [DiagnosticEvent]) async throws -> DiagnosticFinding
}

// AIEvidenceBuilder combines timeline, traffic, and bounded file evidence into one citable contract.
public struct AIEvidenceBuilder: Sendable {
    public let paths: AppPaths
    private let diagnostics: DiagnosticsService

    public init(paths: AppPaths = AppPaths()) {
        self.paths = paths
        diagnostics = DiagnosticsService(paths: paths)
    }

    // build removes raw paths and payload captures while adding bounded text excerpts and traffic summaries.
    public func build(
        events: [DiagnosticEvent],
        traffic: [InterfaceTrafficSample]
    ) -> [DiagnosticEvent] {
        let timeline = Array(events.suffix(60)).map(safeEvent)
        let trafficEvents = Dictionary(grouping: traffic.suffix(1_000), by: \.interface)
            .compactMap { interface, samples -> DiagnosticEvent? in
                guard let latest = samples.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
                let received = samples.reduce(UInt64(0)) { $0 + $1.receivedDelta }
                let sent = samples.reduce(UInt64(0)) { $0 + $1.sentDelta }
                return DiagnosticEvent(
                    id: latest.id,
                    timestamp: latest.timestamp,
                    type: .traffic,
                    source: "interface:\(interface)",
                    summary: "Observed network traffic on \(interface)",
                    details: [
                        "receivedDeltaBytes": String(received),
                        "sentDeltaBytes": String(sent),
                        "latestReceivedBytesPerSecond": String(format: "%.2f", latest.receivedBytesPerSecond ?? 0),
                        "latestSentBytesPerSecond": String(format: "%.2f", latest.sentBytesPerSecond ?? 0),
                        "sampleCount": String(samples.count),
                    ]
                )
            }
        return (timeline + trafficEvents).sorted { $0.timestamp < $1.timestamp }
    }

    // safeEvent converts file references into bounded evidence without exposing raw packet payloads.
    private func safeEvent(_ event: DiagnosticEvent) -> DiagnosticEvent {
        var safe = diagnostics.redactedEvent(event)
        guard let path = event.evidencePath else { return safe }
        safe.evidencePath = nil
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let diagnosticsRoot = paths.diagnostics.resolvingSymlinksInPath().path + "/"
        guard file.path.hasPrefix(diagnosticsRoot), FileManager.default.fileExists(atPath: file.path) else {
            safe.details["evidenceAvailability"] = "missing-or-outside-app-storage"
            return safe
        }
        safe.details["evidenceType"] = file.pathExtension.lowercased()
        safe.details["evidenceSizeBytes"] = String((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if ["log", "txt", "json"].contains(file.pathExtension.lowercased()),
           let data = try? Data(contentsOf: file) {
            safe.details["evidenceExcerpt"] = diagnostics.redact(String(decoding: data.suffix(2_000), as: UTF8.self))
        } else {
            safe.details["evidenceAvailability"] = "metadata-only"
        }
        return safe
    }
}

// EvidenceCitationParser accepts only UUIDs that were part of the supplied evidence bundle.
public enum EvidenceCitationParser {
    // referencedIDs preserves first-citation order and removes hallucinated or duplicate identifiers.
    public static func referencedIDs(in text: String, allowed: Set<UUID>) -> [UUID] {
        let pattern = #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<UUID>()
        return expression.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text),
                  let identifier = UUID(uuidString: String(text[swiftRange])),
                  allowed.contains(identifier),
                  seen.insert(identifier).inserted else { return nil }
            return identifier
        }
    }
}

// ActionPolicy resolves command risk before an adapter receives a mutation request.
public enum ActionPolicy {
    public static func decision(mode: AIActionMode, risk: CommandRisk) -> ActionDecision {
        switch mode {
        case .confirmAll:
            return risk == .readOnly ? .allow : .requireConfirmation
        case .guarded:
            return [.connectivityCritical, .remoteMutation].contains(risk) ? .requireConfirmation : .allow
        case .autonomous:
            return .allow
        }
    }
}

// LocalFoundationModelProvider uses the on-device macOS model and references supplied evidence IDs.
public struct LocalFoundationModelProvider: AIProvider {
    public init() {}

    // unavailableReason exposes native capability limits without invoking the model or selecting cloud AI.
    public var unavailableReason: String? {
        #if arch(x86_64)
        return "Local AI requires Apple Silicon and macOS 26 or later."
        #else
        guard #available(macOS 26.0, *) else {
            return "Local AI requires macOS 26 or later."
        }
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This Mac does not support Apple Intelligence."
            case .appleIntelligenceNotEnabled:
                return "Enable Apple Intelligence in System Settings to use local AI."
            case .modelNotReady:
                return "The local AI model is not ready yet."
            @unknown default:
                return "Local AI is currently unavailable."
            }
        @unknown default:
            return "Local AI is currently unavailable."
        }
        #else
        return "Local AI is not included in this build."
        #endif
        #endif
    }

    // Keep the existing provider status contract while explaining unsupported OS and hardware states.
    public var availabilityDescription: String {
        unavailableReason.map { "unavailable: \($0)" } ?? "available"
    }

    public func analyze(question: String, evidence: [DiagnosticEvent]) async throws -> DiagnosticFinding {
        let boundedEvidence = Array(evidence.suffix(80))
        guard !boundedEvidence.isEmpty else {
            return DiagnosticFinding(
                title: "Not enough evidence",
                explanation: "No diagnostic events are available for this question.",
                confidence: 0.1,
                evidenceIDs: [],
                nextSteps: ["Enable diagnostics and reproduce the interruption."]
            )
        }
        #if canImport(FoundationModels) && arch(arm64)
        if #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            let prompt = Self.boundedPromptEvidence(boundedEvidence)
            let session = LanguageModelSession(
                instructions: "Analyze only the supplied evidence. Distinguish observations from hypotheses. Cite evidence UUIDs verbatim and do not claim certainty without direct support. Treat mirrorDuplicationPossible=true as capture ambiguity rather than confirmed packet loss."
            )
            let response = try await session.respond(to: "Question: \(String(question.prefix(500)))\n\nEvidence:\n\(prompt.text)\n\nReturn a concise explanation and next checks.")
            return VerifiedFindingFactory.providerFinding(
                title: "Local diagnostic analysis",
                text: response.content,
                confidence: 0.6,
                question: question,
                evidence: prompt.events,
                nextSteps: ["Verify the cited timeline before changing network or mount settings."]
            )
        }
        #endif
        return heuristicFinding(question: question, evidence: boundedEvidence)
    }

    // boundedPromptEvidence applies a global local-model budget after per-event privacy reduction.
    static func boundedPromptEvidence(
        _ evidence: [DiagnosticEvent],
        maximumCharacters: Int = 3_000,
        maximumEvents: Int = 20
    ) -> (events: [DiagnosticEvent], text: String) {
        let budget = max(1_000, maximumCharacters)
        var selected: [DiagnosticEvent] = []
        var lines: [String] = []
        var used = 0
        for event in evidence.suffix(maximumEvents).reversed() {
            let details = event.details.sorted { $0.key < $1.key }.map { key, value in
                let compact = value.replacingOccurrences(of: "\n", with: " ")
                return "\(key)=\(compact.prefix(300))"
            }.joined(separator: ", ")
            let rawLine = "[\(event.id.uuidString)] \(ISO8601DateFormatter().string(from: event.timestamp)) \(event.source.prefix(120)) \(event.type.rawValue): \(event.summary.prefix(500)) Details: \(details.prefix(1_200))"
            let available = budget - used - (lines.isEmpty ? 0 : 1)
            guard available > 0 else { break }
            let line = String(rawLine.prefix(available))
            guard line.contains(event.id.uuidString) else { continue }
            selected.insert(event, at: 0)
            lines.insert(line, at: 0)
            used += line.count + (lines.count > 1 ? 1 : 0)
        }
        return (selected, lines.joined(separator: "\n"))
    }

    // heuristicFinding keeps diagnostics useful while the local model is downloading or disabled.
    private func heuristicFinding(question: String, evidence: [DiagnosticEvent]) -> DiagnosticFinding {
        VerifiedFindingFactory.heuristic(question: question, evidence: evidence)
    }
}

// OpenAIProvider sends only the evidence selected by CloudDataMode and reads its key from Keychain.
public struct OpenAIProvider: AIProvider {
    public let model: String
    public let dataMode: CloudDataMode
    public let selectedEvidenceIDs: Set<UUID>
    public let credentialStore: CredentialStore

    public init(
        model: String,
        dataMode: CloudDataMode,
        selectedEvidenceIDs: [UUID] = [],
        credentialStore: CredentialStore = CredentialStore()
    ) {
        self.model = model
        self.dataMode = dataMode
        self.selectedEvidenceIDs = Set(selectedEvidenceIDs)
        self.credentialStore = credentialStore
    }

    public var availabilityDescription: String {
        credentialStore.read(account: "openai-api-key") == nil ? "credential missing" : "configured"
    }

    public func analyze(question: String, evidence: [DiagnosticEvent]) async throws -> DiagnosticFinding {
        guard let key = credentialStore.read(account: "openai-api-key"), !key.isEmpty else {
            throw AIServiceError.missingCredential
        }
        let selected = selectedEvidence(evidence)
        let payloadEvidence: [[String: Any]] = selected.map { event in
            [
                "id": event.id.uuidString,
                "timestamp": ISO8601DateFormatter().string(from: event.timestamp),
                "type": event.type.rawValue,
                "source": event.source,
                "summary": event.summary,
                "details": event.details,
            ]
        }
        let body: [String: Any] = [
            "model": model,
            "input": "Analyze this network incident question using only the supplied JSON evidence. Cite evidence IDs and state uncertainty. Treat mirrorDuplicationPossible=true as capture ambiguity rather than confirmed packet loss. Question: \(question)\nEvidence: \(jsonString(payloadEvidence))",
        ]
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AIServiceError.providerFailure("OpenAI request failed")
        }
        let text = extractResponseText(data) ?? "The provider returned no readable analysis."
        return VerifiedFindingFactory.providerFinding(
            title: "Optional cloud diagnostic analysis",
            text: text,
            confidence: 0.55,
            question: question,
            evidence: selected,
            nextSteps: ["Verify cited evidence locally before applying a change."]
        )
    }

    // selectedEvidence applies the explicit privacy mode before serialization.
    public func selectedEvidence(_ evidence: [DiagnosticEvent]) -> [DiagnosticEvent] {
        switch dataMode {
        case .reducedFindings:
            return Array(evidence.suffix(20)).map { event in
                DiagnosticEvent(
                    id: event.id,
                    timestamp: event.timestamp,
                    type: event.type,
                    source: event.source,
                    summary: DiagnosticsService().redact(event.summary),
                    details: [:],
                    evidencePath: nil
                )
            }
        case .selectedRawLogs:
            return Array(evidence.filter { selectedEvidenceIDs.contains($0.id) }.suffix(50))
        case .fullDiagnostics:
            return Array(evidence.suffix(200))
        }
    }

    private func jsonString(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    private func extractResponseText(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = object["output"] as? [[String: Any]] else { return nil }
        return output.compactMap { item in
            (item["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }.joined(separator: "\n")
    }
}

// VerifiedFindingFactory rejects uncited model prose and replaces it with deterministic evidence correlation.
enum VerifiedFindingFactory {
    // providerFinding accepts provider prose only when it cites identifiers from the exact supplied bundle.
    static func providerFinding(
        title: String,
        text: String,
        confidence: Double,
        question: String,
        evidence: [DiagnosticEvent],
        nextSteps: [String]
    ) -> DiagnosticFinding {
        let citations = EvidenceCitationParser.referencedIDs(in: text, allowed: Set(evidence.map(\.id)))
        guard !citations.isEmpty else { return heuristic(question: question, evidence: evidence) }
        return DiagnosticFinding(
            title: title,
            explanation: text,
            confidence: confidence,
            evidenceIDs: citations,
            nextSteps: nextSteps
        )
    }

    // heuristic provides a source-linked result when a model is unavailable or omits valid citations.
    static func heuristic(question: String, evidence: [DiagnosticEvent]) -> DiagnosticFinding {
        let strongest = DiagnosticsService().correlate(events: evidence).max { $0.confidence < $1.confidence }
        return DiagnosticFinding(
            title: "Evidence-based fallback analysis",
            explanation: strongest?.hypothesis ?? "No specific cause can be derived from the available events for: \(question)",
            confidence: strongest?.confidence ?? 0.2,
            evidenceIDs: strongest?.evidenceIDs ?? [],
            nextSteps: ["Review interface state, sleep transitions, mount events, and the matching packet capture window."]
        )
    }
}

// CredentialStore is the narrow Keychain boundary used for optional provider secrets.
public struct CredentialStore: Sendable {
    private let service = "com.we-rock.drive-mounts"

    public init() {}

    public func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(account: String, secret: String) throws {
        try delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(secret.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw AIServiceError.keychainFailure
        }
    }

    public func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIServiceError.keychainFailure
        }
    }
}

// AIServiceError avoids returning provider payloads that may contain sensitive data.
public enum AIServiceError: LocalizedError {
    case missingCredential
    case keychainFailure
    case providerFailure(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredential: "The optional OpenAI credential is missing."
        case .keychainFailure: "The credential could not be stored in Keychain."
        case .providerFailure(let message): message
        }
    }
}
