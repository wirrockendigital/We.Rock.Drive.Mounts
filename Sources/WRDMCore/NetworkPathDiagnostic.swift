import Foundation

// NetworkPathDiagnostic performs an optional, explicitly requested ICMP check without modifying MTU.
public enum NetworkPathDiagnostic {
    public static func check(port: NetworkPort, host: String) throws -> CommandResult {
        guard port.kind == "ethernet", port.usable, let mtu = port.mtu, mtu > 1500,
              let source = port.addresses.first(where: { !$0.contains(":") }) else {
            return CommandResult(ok: false, code: "MTU_PROBE_UNAVAILABLE", message: "Die optionale Jumbo-Prüfung benötigt einen verbundenen IPv4-Anschluss mit MTU über 1500.")
        }
        let result = try ProcessRunner.run("/sbin/ping", arguments: ["-D", "-S", source, "-c", "1", "-W", "1000", "-s", String(mtu - 28), host], timeout: 3)
        let success = result.exitCode == 0 && !result.timedOut
        return CommandResult(ok: success, code: success ? "JUMBO_PATH_CONFIRMED" : "JUMBO_PATH_UNCLEAR",
                             message: success ? "Ein unfragmentiertes IPv4-Paket der eingestellten MTU wurde vom ausgewählten Ziel beantwortet." : "Keine Bestätigung: ICMP kann gesperrt sein oder der Pfad unterstützt die Paketgröße nicht. Die MTU wurde nicht verändert.",
                             data: ["interface": port.interface, "mtu": String(mtu), "host": host])
    }
}
