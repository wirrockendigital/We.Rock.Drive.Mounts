import Foundation
import Darwin
import WRDMCore

// The CLI is a thin presentation adapter over the shared CommandService.
@main
struct WRDMCLIMain {
    static func main() async {
        // Replace the shell environment before parsing commands or opening credential stores.
        ProcessRunner.reexecCurrentProcessWithMinimalEnvironment()
        var arguments = Array(CommandLine.arguments.dropFirst())
        let json = removeFlag("--json", from: &arguments)
        let confirmed = removeFlag("--yes", from: &arguments)

        if arguments.prefix(3) == ["ai", "key", "set"] {
            await setOpenAIKey(json: json)
            return
        }
        if arguments.prefix(3) == ["ai", "key", "delete"] {
            await deleteOpenAIKey(json: json)
            return
        }
        if arguments.prefix(3) == ["pi", "password", "set"] {
            await setPiPassword(json: json)
            return
        }
        if arguments.prefix(3) == ["pi", "password", "delete"] {
            await deletePiPassword(json: json)
            return
        }
        guard let parsed = parse(arguments: arguments, confirmed: confirmed) else {
            printUsage()
            exit(2)
        }

        let service = CommandService()
        let result = await service.execute(parsed, actor: "cli")
        render(result, json: json)
        if parsed.command == "capture.live.start", result.ok, let identifier = result.data["session"] {
            await waitForLiveCapture(identifier: identifier, service: service)
        }
        // Transfer jobs are owned by the background agent, so the CLI must not keep the runner alive.
        await service.shutdown()
        exit(result.ok ? 0 : 1)
    }

    // parse maps ergonomic command words into stable canonical command names.
    private static func parse(arguments: [String], confirmed: Bool) -> CommandRequest? {
        guard let first = arguments.first else { return CommandRequest(command: "status") }
        let rest = Array(arguments.dropFirst())
        switch first {
        case "status": return CommandRequest(command: "status", confirmed: confirmed)
        case "check": return CommandRequest(command: "check", confirmed: confirmed)
        case "config":
            guard let action = rest.first else { return CommandRequest(command: "config.show", confirmed: confirmed) }
            if action == "show" { return CommandRequest(command: "config.show", confirmed: confirmed) }
            if action == "export" { return CommandRequest(command: "config.export", arguments: Array(rest.dropFirst()), confirmed: confirmed) }
            if action == "import" { return CommandRequest(command: "config.import", arguments: Array(rest.dropFirst()), confirmed: confirmed) }
            if action == "set" { return CommandRequest(command: "config.set", arguments: Array(rest.dropFirst()), confirmed: confirmed) }
        case "app":
            if rest == ["login", "status"] {
                return CommandRequest(command: "app.login.status", confirmed: confirmed)
            }
            if rest == ["login", "on"] {
                return CommandRequest(command: "config.set", arguments: ["general.openAppAtLogin", "true"], confirmed: confirmed)
            }
            if rest == ["login", "off"] {
                return CommandRequest(command: "config.set", arguments: ["general.openAppAtLogin", "false"], confirmed: confirmed)
            }
        case "mounts":
            switch rest.first {
            case "recover": return CommandRequest(command: "mounts.recover", arguments: Array(rest.dropFirst()), confirmed: confirmed)
            case "force-recover": return CommandRequest(command: "mounts.force-recover", arguments: Array(rest.dropFirst()), confirmed: confirmed)
            case "incidents": return CommandRequest(command: "mounts.incidents", arguments: Array(rest.dropFirst()), confirmed: confirmed)
            case "add": return CommandRequest(command: "mounts.add", arguments: Array(rest.dropFirst()), confirmed: confirmed)
            case "update": return CommandRequest(command: "mounts.update", arguments: Array(rest.dropFirst()), confirmed: confirmed)
            case "remove": return CommandRequest(command: "mounts.remove", arguments: Array(rest.dropFirst()), confirmed: confirmed)
            case "enable": return CommandRequest(command: "mounts.enable", arguments: Array(rest.dropFirst()), confirmed: confirmed)
            default: return CommandRequest(command: "mounts.list", confirmed: confirmed)
            }
        case "network":
            if rest.count >= 2, ["profile", "priority", "hardware", "mtu"].contains(rest[0]) {
                return CommandRequest(command: "network." + rest[0] + "." + rest[1], arguments: Array(rest.dropFirst(2)), confirmed: confirmed)
            }
            if rest.prefix(2) == ["wifi", "allow"] { return CommandRequest(command: "network.wifi.allow", arguments: Array(rest.dropFirst(2)), confirmed: confirmed) }
            if rest.prefix(2) == ["wifi", "off"] { return CommandRequest(command: "network.wifi.off", confirmed: confirmed) }
            return CommandRequest(command: "network.status", confirmed: confirmed)
        case "diagnostics":
            switch rest.first {
            case "status": return CommandRequest(command: "diagnostics.status", confirmed: confirmed)
            case "capture": return CommandRequest(command: "diagnostics.capture", arguments: Array(rest.dropFirst()), confirmed: confirmed)
            case "export": return CommandRequest(command: "diagnostics.export", arguments: Array(rest.dropFirst()), confirmed: confirmed)
            default: return CommandRequest(command: "diagnostics.events", arguments: rest, confirmed: confirmed)
            }
        case "transfer":
            switch rest.first {
            case "monitoring": return CommandRequest(command: "transfer.monitoring.status", confirmed: confirmed)
            case "list": return CommandRequest(command: "transfer.list", confirmed: confirmed)
            case "status": return CommandRequest(command: "transfer.status", arguments: Array(rest.dropFirst()), confirmed: confirmed)
            case "start": return CommandRequest(command: "transfer.start", arguments: Array(rest.dropFirst()), confirmed: confirmed)
            case "resume": return CommandRequest(command: "transfer.resume", arguments: Array(rest.dropFirst()), confirmed: confirmed)
            case "pause": return CommandRequest(command: "transfer.pause", arguments: Array(rest.dropFirst()), confirmed: confirmed)
            case "stop": return CommandRequest(command: "transfer.stop", arguments: Array(rest.dropFirst()), confirmed: confirmed)
            case "finalize-move": return CommandRequest(command: "transfer.finalizeMove", arguments: Array(rest.dropFirst()), confirmed: confirmed)
            case "incident": return CommandRequest(command: "transfer.incident", arguments: Array(rest.dropFirst()), confirmed: confirmed)
            default: return CommandRequest(command: "transfer.list", confirmed: confirmed)
            }
        case "pi":
            if rest.first == "install" { return CommandRequest(command: "pi.install", arguments: Array(rest.dropFirst()), confirmed: confirmed) }
            return CommandRequest(command: "pi.health", confirmed: confirmed)
        case "capture":
            switch rest.first {
            case "status": return CommandRequest(command: "capture.live.status", confirmed: confirmed)
            case "live": return CommandRequest(command: "capture.live.start", arguments: Array(rest.dropFirst()), confirmed: confirmed)
            case "stop": return CommandRequest(command: "capture.live.stop", arguments: Array(rest.dropFirst()), confirmed: confirmed)
            case "open": return CommandRequest(command: "capture.open", arguments: Array(rest.dropFirst()), confirmed: confirmed)
            default: return CommandRequest(command: "capture.start", arguments: rest.first == "start" ? Array(rest.dropFirst()) : rest, confirmed: confirmed)
            }
        case "synology":
            switch rest.first {
            case "health": return CommandRequest(command: "synology.health", confirmed: confirmed)
            case "ssh-health": return CommandRequest(command: "synology.ssh.health", confirmed: confirmed)
            case "import": return CommandRequest(command: "synology.csv.import", arguments: Array(rest.dropFirst()), confirmed: confirmed)
            case "fetch": return CommandRequest(command: "synology.dsm.fetch", confirmed: confirmed)
            default: return CommandRequest(command: "synology.tail", arguments: Array(rest.dropFirst()), confirmed: confirmed)
            }
        case "ai": return CommandRequest(command: "ai.analyze", arguments: rest.first == "analyze" ? Array(rest.dropFirst()) : rest, confirmed: confirmed)
        case "wake":
            if rest.first == "verify" {
                return CommandRequest(command: "wake.verify", arguments: Array(rest.dropFirst()), confirmed: confirmed)
            }
            return CommandRequest(command: "wake", arguments: rest, confirmed: confirmed)
        default: break
        }
        return nil
    }

    // setOpenAIKey reads stdin so the secret does not enter shell history or process arguments.
    private static func setOpenAIKey(json: Bool) async {
        guard let line = readLine(strippingNewline: true), !line.isEmpty else {
            render(CommandResult(ok: false, code: "EMPTY_SECRET", message: "No key was supplied on stdin."), json: json)
            exit(1)
        }
        do {
            try CredentialStore().write(account: "openai-api-key", secret: line)
            render(CommandResult(ok: true, code: "KEY_STORED", message: "OpenAI key stored in Keychain."), json: json)
        } catch {
            render(CommandResult(ok: false, code: "KEYCHAIN_FAILED", message: error.localizedDescription), json: json)
            exit(1)
        }
    }

    private static func deleteOpenAIKey(json: Bool) async {
        do {
            try CredentialStore().delete(account: "openai-api-key")
            render(CommandResult(ok: true, code: "KEY_REMOVED", message: "OpenAI key removed from Keychain."), json: json)
        } catch {
            render(CommandResult(ok: false, code: "KEYCHAIN_FAILED", message: error.localizedDescription), json: json)
            exit(1)
        }
    }

    // setPiPassword reads stdin so the remote sudo credential never enters process arguments or configuration.
    private static func setPiPassword(json: Bool) async {
        guard let line = readLine(strippingNewline: true), !line.isEmpty else {
            render(CommandResult(ok: false, code: "EMPTY_SECRET", message: "No password was supplied on stdin."), json: json)
            exit(1)
        }
        do {
            try CredentialStore().write(account: "raspberry-pi-sudo-password", secret: line)
            render(CommandResult(ok: true, code: "KEY_STORED", message: "Raspberry Pi installation password stored in Keychain."), json: json)
        } catch {
            render(CommandResult(ok: false, code: "KEYCHAIN_FAILED", message: error.localizedDescription), json: json)
            exit(1)
        }
    }

    // deletePiPassword removes the optional installation credential without changing Pi access.
    private static func deletePiPassword(json: Bool) async {
        do {
            try CredentialStore().delete(account: "raspberry-pi-sudo-password")
            render(CommandResult(ok: true, code: "KEY_REMOVED", message: "Raspberry Pi installation password removed."), json: json)
        } catch {
            render(CommandResult(ok: false, code: "KEYCHAIN_FAILED", message: error.localizedDescription), json: json)
            exit(1)
        }
    }

    private static func removeFlag(_ flag: String, from arguments: inout [String]) -> Bool {
        guard let index = arguments.firstIndex(of: flag) else { return false }
        arguments.remove(at: index)
        return true
    }

    // waitForLiveCapture converts interrupt signals into an orderly paired-stream shutdown.
    private static func waitForLiveCapture(identifier: String, service: CommandService) async {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        interrupt.setEventHandler { Task { await service.shutdown() } }
        terminate.setEventHandler { Task { await service.shutdown() } }
        interrupt.resume()
        terminate.resume()
        _ = await service.waitForLiveCapture(identifier: identifier)
        interrupt.cancel()
        terminate.cancel()
    }

    private static func render(_ result: CommandResult, json: Bool) {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(result) {
                print(String(decoding: data, as: UTF8.self))
            }
            return
        }
        print("\(result.ok ? "OK" : "ERROR") [\(result.code)] \(result.message)")
        for key in result.data.keys.sorted() {
            print("\(key)=\(result.data[key] ?? "")")
        }
    }

    private static func printUsage() {
        print("""
        Usage: wrdm [--json] [--yes] <command>
          status | check
          config show | config export <path> | config import <path> | config set <key> <value>
          app login status | app login on | app login off
          mounts list | mounts incidents [limit]
          mounts recover [mount-id ...]
          mounts force-recover [mount-id ...] --yes
          mounts add <name> <smb-url> [true|false]
          mounts update <id> <name> <smb-url> [true|false]
          mounts remove <id> | mounts enable <id> <true|false>
          network status | network wifi allow [minutes] | network wifi off
          diagnostics events [limit] | diagnostics capture [label] | diagnostics export
          transfer list | transfer monitoring | transfer status <job-id>
          transfer start <copy|move> <auto|macToNAS|nasToMac> <ask|autoRetry|manual> <true|false keep-awake> <true|false unlimited-retry> <destination-folder> <source> [source...]
          transfer pause <job-id> | transfer stop <job-id> | transfer resume <job-id>
          transfer finalize-move <job-id> | transfer incident [job-id]
          pi health | pi install <installer-path> | pi password set | pi password delete
          capture status | capture start [host-filter] | capture live [host-filter]
          capture stop <session-id> | capture open <pcapng-path>
          synology health | synology tail [limit] | synology ssh-health
          synology import <csv-path> | synology fetch
          ai analyze <question> | ai key set | ai key delete
          wake [raspberryPiLAN|tailscale|synologyTask|iosShortcut|cli]
          wake verify [raspberryPiLAN|tailscale|synologyTask|iosShortcut|cli]
        """)
    }
}
