import Foundation
import Darwin
import WRDMCore

// JSONValue supports schema-safe MCP envelopes without an external JSON dependency.
enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

// MCPRequest is the validated JSON-RPC request shape required for local stdio operation.
struct MCPRequest {
    var jsonrpc: String
    var id: JSONValue?
    var method: String
    var params: [String: JSONValue]?
}

// MCPResponse is emitted one JSON object per line to keep stderr available for diagnostics.
struct MCPResponse: Encodable {
    var jsonrpc = "2.0"
    var id: JSONValue?
    var result: JSONValue?
    var error: JSONValue?
}

// The MCP executable exposes the same canonical CommandService as CLI and UI.
@main
struct WRDMMCPMain {
    private static let currentProtocolVersion = "2025-11-25"
    private static let supportedProtocolVersions: Set<String> = [currentProtocolVersion, "2025-06-18"]
    private static let toolCommands: [(String, String)] = [
        ("status", "Read the current agent and mount status."),
        ("check", "Run one read-only mount health check."),
        ("config.show", "Read the complete non-secret configuration."),
        ("config.export", "Write the current non-secret configuration to a local transfer file."),
        ("config.import", "Import one validated local configuration transfer file after confirmation."),
        ("config.set", "Update one validated non-secret configuration value."),
        ("app.login.status", "Read the visible app login LaunchAgent state."),
        ("mounts.list", "Read configured mount states."),
        ("mounts.recover", "Run bounded normal recovery for missing or stale enabled mounts."),
        ("mounts.force-recover", "Force-unmount and recover selected stale mounts after explicit confirmation."),
        ("mounts.incidents", "Read bounded SMB mount incident manifests."),
        ("mounts.add", "Add one credential-free SMB mount definition."),
        ("mounts.update", "Update one SMB mount definition by identifier."),
        ("mounts.remove", "Remove one SMB mount definition after confirmation."),
        ("mounts.enable", "Enable or disable one SMB mount definition."),
        ("network.mtu.check", "Check an explicit configured NAS path using a nonfragmenting IPv4 probe without changing MTU."),
        ("network.profile.list", "Read network-bound monitoring profiles."),
        ("network.profile.capture", "Capture current values for an identified port without enabling monitoring."),
        ("network.profile.save", "Save explicitly confirmed monitoring profile JSON."),
        ("network.profile.remove", "Remove a confirmed monitoring profile."),
        ("network.priority.preview", "Preview complete macOS service order."),
        ("network.priority.apply", "Apply preview; requires interactive authorization in the app."),
        ("network.hardware.preview", "Preview restoration for one profile."),
        ("network.hardware.apply", "Restore preview; requires interactive authorization in the app."),
        ("network.status", "Read Ethernet and Wi-Fi evidence."),
        ("network.wifi.allow", "Enable Wi-Fi for a temporary AirDrop window."),
        ("network.wifi.off", "Disable Wi-Fi after confirmation."),
        ("diagnostics.events", "Read recent diagnostic events."),
        ("diagnostics.status", "Read effective states and disabled reasons for every diagnostic collector."),
        ("diagnostics.capture", "Capture bounded macOS diagnostic evidence."),
        ("diagnostics.export", "Create a redacted support bundle."),
        ("transfer.monitoring.status", "Read large-transfer monitoring settings and active job count."),
        ("transfer.list", "Read persisted transfer jobs."),
        ("transfer.status", "Read one persisted transfer job."),
        ("transfer.start", "Queue one WRDM-worker NAS transfer for the background agent."),
        ("transfer.resume", "Resume one paused, stopped, or failed transfer job."),
        ("transfer.pause", "Pause one active transfer job."),
        ("transfer.stop", "Stop one active transfer job."),
        ("transfer.finalizeMove", "Delete move sources after verified copy completion."),
        ("transfer.incident", "Create one transfer incident evidence bundle."),
        ("pi.health", "Read Raspberry Pi companion health."),
        ("pi.install", "Install the managed Raspberry Pi companion."),
        ("capture.start", "Start and download a bounded Pi packet capture."),
        ("capture.live.status", "Read local Wireshark capability and live capture lifecycle state."),
        ("capture.live.start", "Stream a Pi capture into local Wireshark."),
        ("capture.live.stop", "Stop one live Wireshark capture session."),
        ("capture.open", "Open one app-owned PCAPNG file in Wireshark."),
        ("synology.tail", "Read normalized Synology syslog evidence from the Pi."),
        ("synology.health", "Read independent Synology source health."),
        ("synology.ssh.health", "Run the fixed read-only Synology SSH health query."),
        ("synology.csv.import", "Import one local Synology Log Center CSV export."),
        ("synology.dsm.fetch", "Fetch a bounded read-only DSM Log Center page."),
        ("ai.analyze", "Analyze selected diagnostic evidence."),
        ("wake", "Trigger one verified Mac wake route."),
        ("wake.verify", "Test and verify one configured Mac wake route."),
    ]

    static func main() async {
        // Replace the client environment before accepting any long-lived stdio request.
        ProcessRunner.reexecCurrentProcessWithMinimalEnvironment()
        let service = CommandService()
        var initializeResponded = false
        var initialized = false
        while let line = readLine() {
            guard let data = line.data(using: .utf8) else {
                write(protocolError(id: nil, code: -32700, message: "Parse error"))
                continue
            }
            let request: MCPRequest
            switch decodeRequest(data) {
            case .success(let value):
                request = value
            case .failure(let failure):
                write(protocolError(id: failure.id, code: failure.code, message: failure.message))
                continue
            }
            if request.id == nil {
                if request.method == "notifications/initialized", initializeResponded {
                    initialized = true
                }
                continue
            }
            switch request.method {
            case "initialize":
                guard !initializeResponded,
                      let requestedVersion = request.params?["protocolVersion"]?.stringValue else {
                    write(protocolError(id: request.id, code: -32602, message: "Invalid initialize parameters"))
                    continue
                }
                let negotiatedVersion = supportedProtocolVersions.contains(requestedVersion)
                    ? requestedVersion
                    : currentProtocolVersion
                initializeResponded = true
                write(MCPResponse(id: request.id, result: .object([
                    "protocolVersion": .string(negotiatedVersion),
                    "capabilities": .object(["tools": .object([:])]),
                    "serverInfo": .object(["name": .string("we-rock-drive-mounts"), "version": .string("0.3.7")]),
                ]), error: nil))
            case "ping":
                write(MCPResponse(id: request.id, result: .object([:]), error: nil))
            case "tools/list":
                guard initialized else {
                    write(protocolError(id: request.id, code: -32002, message: "Server not initialized"))
                    continue
                }
                write(MCPResponse(id: request.id, result: .object(["tools": .array(toolDefinitions())]), error: nil))
            case "tools/call":
                guard initialized else {
                    write(protocolError(id: request.id, code: -32002, message: "Server not initialized"))
                    continue
                }
                let response = await callTool(request.params, service: service)
                write(MCPResponse(id: request.id, result: response, error: nil))
            default:
                write(MCPResponse(id: request.id, result: nil, error: errorObject(code: -32601, message: "Method not found")))
            }
        }
        await service.shutdown()
    }

    // decodeRequest distinguishes malformed JSON from structurally invalid JSON-RPC requests.
    private static func decodeRequest(_ data: Data) -> Result<MCPRequest, MCPProtocolFailure> {
        do {
            let raw = try JSONSerialization.jsonObject(with: data)
            guard raw is [String: Any] else {
                return .failure(MCPProtocolFailure(id: nil, code: -32600, message: "Invalid Request"))
            }
        } catch {
            return .failure(MCPProtocolFailure(id: nil, code: -32700, message: "Parse error"))
        }
        guard let object = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            return .failure(MCPProtocolFailure(id: nil, code: -32600, message: "Invalid Request"))
        }
        let identifier: JSONValue?
        if let rawIdentifier = object["id"] {
            switch rawIdentifier {
            case .string:
                identifier = rawIdentifier
            case .number(let value) where value.isFinite && value.rounded() == value:
                identifier = rawIdentifier
            case .null:
                // JSON-RPC permits an explicit null identifier; only an absent id is a notification.
                identifier = rawIdentifier
            default:
                return .failure(MCPProtocolFailure(id: nil, code: -32600, message: "Invalid Request"))
            }
        } else {
            identifier = nil
        }
        guard object["jsonrpc"]?.stringValue == "2.0",
              let method = object["method"]?.stringValue,
              !method.isEmpty else {
            return .failure(MCPProtocolFailure(id: identifier, code: -32600, message: "Invalid Request"))
        }
        let params: [String: JSONValue]?
        if let rawParams = object["params"] {
            guard let value = rawParams.objectValue else {
                return .failure(MCPProtocolFailure(id: identifier, code: -32602, message: "Invalid params"))
            }
            params = value
        } else {
            params = nil
        }
        return .success(MCPRequest(jsonrpc: "2.0", id: identifier, method: method, params: params))
    }

    // toolDefinitions keep mutations explicit and require a confirmed boolean.
    private static func toolDefinitions() -> [JSONValue] {
        toolCommands.map { name, description in
            .object([
                "name": .string(name),
                "description": .string(description),
                "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "arguments": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                        "confirmed": .object(["type": .string("boolean")]),
                    ]),
                    "additionalProperties": .bool(false),
                ]),
            ])
        }
    }

    private static func callTool(_ params: [String: JSONValue]?, service: CommandService) async -> JSONValue {
        guard let params, Set(params.keys).isSubset(of: ["name", "arguments"]),
              case .string(let name) = params["name"] else {
            return toolError("Missing tool name")
        }
        guard toolCommands.contains(where: { $0.0 == name }) else {
            return toolError("Unknown tool name")
        }
        var arguments: [String] = []
        var confirmed = false
        if let rawInput = params["arguments"] {
            guard case .object(let input) = rawInput,
                  Set(input.keys).isSubset(of: ["arguments", "confirmed"]) else {
                return toolError("Invalid tool arguments")
            }
            if case .array(let values) = input["arguments"] {
                let strings = values.compactMap(\.stringValue)
                guard strings.count == values.count else { return toolError("arguments must contain only strings") }
                arguments = strings
            } else if input["arguments"] != nil {
                return toolError("arguments must be an array")
            }
            if case .bool(let value) = input["confirmed"] {
                confirmed = value
            } else if input["confirmed"] != nil {
                return toolError("confirmed must be a boolean")
            }
        }
        let result = await service.execute(CommandRequest(command: name, arguments: arguments, confirmed: confirmed), actor: "mcp")
        let data = (try? JSONEncoder().encode(result)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return .object([
            "content": .array([.object(["type": .string("text"), "text": .string(data)])]),
            "isError": .bool(!result.ok),
        ])
    }

    private static func toolError(_ message: String) -> JSONValue {
        .object([
            "content": .array([.object(["type": .string("text"), "text": .string(message)])]),
            "isError": .bool(true),
        ])
    }

    private static func errorObject(code: Int, message: String) -> JSONValue {
        .object(["code": .number(Double(code)), "message": .string(message)])
    }

    // protocolError creates a JSON-RPC error response without a result member.
    private static func protocolError(id: JSONValue?, code: Int, message: String) -> MCPResponse {
        MCPResponse(id: id, result: nil, error: errorObject(code: code, message: message))
    }

    private static func write(_ response: MCPResponse) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(response), let text = String(data: data, encoding: .utf8) else { return }
        print(text)
        fflush(stdout)
    }
}

// MCPProtocolFailure carries the best valid request identifier into a JSON-RPC error response.
struct MCPProtocolFailure: Error {
    var id: JSONValue?
    var code: Int
    var message: String
}
