import AppKit
import SwiftUI
import WRDMCore

// NetworkDetailsView renders shared observations and requires a separate preview before every system edit.
struct NetworkDetailsView: View {
    @ObservedObject var model: AppModel
    @State private var editing: PortProfile?
    @State private var preview: NetworkChangePreview?
    private var inventory: NetworkInventory { model.networkInventory }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Netzwerkanschlüsse").font(.headline)
            Picker("Bevorzugtes Ethernet", selection: Binding(get: {
                model.settings.network.discovery?.preferredPortID ?? ""
            }, set: { value in
                var options = model.settings.network.discovery ?? NetworkOptions()
                options.preferredPortID = value.isEmpty ? nil : value
                options.unresolvedLegacyInterface = nil
                model.settings.network.discovery = options
            })) {
                Text("Automatisch").tag("")
                ForEach(inventory.ports.filter { $0.kind == "ethernet" }) { port in Text(port.name).tag(port.id) }
            }
            if let unresolved = model.settings.network.discovery?.unresolvedLegacyInterface {
                Text("Die bisherige Zuordnung \(unresolved) ist nicht eindeutig. Bitte einen Anschluss oder Automatisch wählen.").foregroundStyle(.orange)
            }
            if let report = model.networkReport {
                Text(model.networkDecisionText).textSelection(.enabled)
                Text("Stabilitätsprüfung \(min(3, report.policyState.lanRecoveryCount)) von 3")
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let until = report.policyState.wifiGraceUntil, until > context.date {
                        Text("WLAN-Zeitfenster: noch \(Int(ceil(until.timeIntervalSince(context.date) / 60))) Minuten")
                    }
                }
                Text("Beobachtung: \(report.observation.timestamp.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
            }
            if let restoration = model.networkRestoration {
                Text("Letzte Einstellungsänderung: " + restoration.outcome).foregroundStyle(restoration.outcome == "VERIFIED" ? Color.secondary : Color.orange)
            }
            ForEach(inventory.ports) { port in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(port.name) · \(port.interface)").font(.headline)
                    Text(port.present ? (port.link == true ? (port.addresses.isEmpty ? "Verbunden, wartet auf IP-Adresse" : "Verbunden") : "Kein aktiver Link") : "Nicht angeschlossen")
                    Text("\(port.speedMbps.map { "\($0) Mbit/s" } ?? "Geschwindigkeit unbekannt") · MTU \(port.mtu.map(String.init) ?? "unbekannt")")
                    Text("Konfiguriert: \(port.configuredMedia?.subtype ?? "unbekannt") · Aktiv: \(port.activeMedia?.subtype ?? "unbekannt") · \(port.activeMedia?.options.joined(separator: ", ") ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Array((model.networkReport?.observation.probes.filter { $0.interface == port.interface } ?? []).enumerated()), id: \.offset) { _, probe in
                        Text("Ziel \(probe.host): \(probe.reachable ? "erreichbar" : "nicht bestätigt") · Systemroute: \(inventory.ports.first { $0.interface == probe.systemRouteInterface }?.name ?? probe.systemRouteInterface ?? "unbekannt")")
                            .font(.caption).foregroundStyle(probe.reachable ? Color.secondary : Color.orange)
                    }
                    if let avb = port.avb { Text("AVB/EAV: \(avb ? "an" : "aus")").font(.caption) }
                    if port.kind == "ethernet" {
                        HStack {
                            Button("Aktuelle Werte übernehmen …") {
                                Task {
                                    let result = await model.run("network.profile.capture", arguments: [port.id])
                                    if let json = result.data["json"], let data = json.data(using: .utf8) {
                                        editing = try? NetworkFiles.decode(PortProfile.self, from: data)
                                    }
                                }
                            }
                            .disabled(port.hardwareID == nil || port.networkID == nil)
                            if port.networkID == nil { Text("Netzwerkidentität unbekannt").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    if port.kind == "ethernet", (port.mtu ?? 0) > 1500 {
                        ForEach(model.settings.mounts.filter(\.enabled)) { mount in
                            if let host = URL(string: mount.url)?.host {
                                Button("Jumbo-Pfad zu \(mount.name) prüfen") {
                                    Task { _ = await model.run("network.mtu.check", arguments: [port.id, host]) }
                                }
                            }
                        }
                    }
                    ForEach(model.settings.network.discovery?.profiles.filter { $0.portID == port.id } ?? []) { profile in
                        HStack {
                            Button("Überwachungsprofil bearbeiten") { editing = profile }
                            Button("Wunschwerte wiederherstellen …") { loadPreview("network.hardware.preview", arguments: [profile.id.uuidString]) }
                                .disabled(!profile.enabled)
                        }
                    }
                    ForEach(model.networkReport?.warnings.filter { $0.portID == port.id } ?? []) { warning in
                        Text(warningText(warning)).foregroundStyle(warning.state == "deviation" ? .orange : .secondary)
                        if let matching = warning.lastMatching { Text("Zuletzt passend: \(matching.formatted())").font(.caption) }
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text("Aktuelle Dienstreihenfolge").font(.headline)
            ForEach(Array(inventory.serviceOrder.enumerated()), id: \.element) { index, id in
                Text("\(index + 1). \(inventory.ports.first { $0.serviceID == id }?.name ?? id)")
            }
            Button("Ethernet-Priorität vorschlagen …") { loadPreview("network.priority.preview") }
            Text("Die Auswahl eines bevorzugten Anschlusses ändert noch keine macOS-Dienstreihenfolge. Speichere die Auswahl vor der Vorschau.").font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { profile in
            PortProfileEditor(model: model, profile: profile, port: inventory.ports.first { $0.id == profile.portID })
        }
        .sheet(item: $preview) { proposal in
            VStack(alignment: .leading, spacing: 16) {
                Text("Netzwerkeinstellungen ändern?").font(.title2)
                if proposal.kind == "priority" {
                    Text("Bisher: " + proposal.before.serviceOrder.compactMap { id in proposal.before.ports.first { $0.serviceID == id }?.name }.joined(separator: " → "))
                }
                Text(proposal.summary.joined(separator: "\n")).textSelection(.enabled)
                Text("Die Änderung kann Verbindungen kurz unterbrechen. Laufende WRDM-Transfers verhindern die Übernahme. macOS fordert bei Bedarf eine Autorisierung an.")
                HStack {
                    Button("Abbrechen") { preview = nil }
                    Button("Bestätigen und übernehmen") {
                        Task {
                            _ = await model.run("network.\(proposal.kind).apply", arguments: [proposal.id.uuidString], confirmed: true)
                            preview = nil
                            await model.refreshNetworkInventory()
                        }
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 540)
        }
    }

    // loadPreview only reads system configuration and persists a short-lived proposal.
    private func loadPreview(_ command: String, arguments: [String] = []) {
        Task {
            let result = await model.run(command, arguments: arguments)
            if let json = result.data["json"] { preview = try? NetworkFiles.decode(NetworkChangePreview.self, from: Data(json.utf8)) }
        }
    }
    private func warningText(_ warning: PortWarning) -> String {
        switch warning.state {
        case "deviation": "Abweichung: " + warning.differences.joined(separator: " · ")
        case "pending": "Abweichung wird erneut geprüft"
        case "matching": "Überwachte Werte stimmen überein"
        case "inactive": "Profil in diesem Netzwerk inaktiv"
        case "disconnected": "Überwachter Anschluss nicht verbunden"
        default: "Überwachung unklar: " + warning.differences.joined(separator: " · ")
        }
    }
}

// PortProfileEditor lets users elect each field instead of implicitly monitoring all captured values.
private struct PortProfileEditor: View {
    @ObservedObject var model: AppModel
    @State var profile: PortProfile
    let port: NetworkPort?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Einstellungen überwachen").font(.title2)
            Toggle("Überwachung für diesen Adapter in diesem Netzwerk aktivieren", isOn: $profile.enabled)
            Toggle("Hardwaremodus überwachen", isOn: selected(\.mode, fallback: "automatic"))
            if profile.mode != nil {
                Picker("Hardwaremodus", selection: Binding(get: { profile.mode ?? "automatic" }, set: { profile.mode = $0 })) {
                    Text("Automatisch").tag("automatic"); Text("Manuell").tag("manual")
                }
            }
            Toggle("Konfiguriertes Medium überwachen", isOn: Binding(get: { profile.media != nil }, set: { profile.media = $0 ? port?.configuredMedia : nil }))
            if profile.media != nil {
                Picker("Medium", selection: Binding(get: { mediaIndex }, set: { profile.media = port?.availableMedia[$0] })) {
                    ForEach(Array((port?.availableMedia ?? []).enumerated()), id: \.offset) { index, media in
                        Text(media.subtype + " · " + media.options.joined(separator: ", ")).tag(index)
                    }
                }
            }
            Toggle("Aktive Geschwindigkeit überwachen", isOn: selected(\.speedMbps, fallback: port?.speedMbps ?? 10000))
            if profile.speedMbps != nil { TextField("Sollgeschwindigkeit in Mbit/s", value: Binding(get: { profile.speedMbps ?? 10000 }, set: { profile.speedMbps = $0 }), format: .number) }
            Toggle("Aktiven Duplexmodus überwachen", isOn: selected(\.duplex, fallback: "full-duplex"))
            if profile.duplex != nil {
                Picker("Duplex", selection: Binding(get: { profile.duplex ?? "full-duplex" }, set: { profile.duplex = $0 })) {
                    Text("Full Duplex").tag("full-duplex"); Text("Half Duplex").tag("half-duplex")
                }
            }
            Toggle("MTU überwachen", isOn: selected(\.mtu, fallback: port?.mtu ?? 1500))
            if profile.mtu != nil {
                TextField("Gewünschte MTU", value: Binding(get: { profile.mtu ?? 1500 }, set: { profile.mtu = $0 }), format: .number)
                Text("Unterstützter Bereich: \(port?.minimumMTU ?? 0)–\(port?.maximumMTU ?? 0). MTU 9000 erfordert einen geeigneten gesamten LAN-Pfad.").font(.caption)
            }
            Toggle("Flusskontrolle überwachen", isOn: selected(\.flowControl, fallback: false))
            if profile.flowControl != nil { Toggle("Flusskontrolle erwartet", isOn: Binding(get: { profile.flowControl ?? false }, set: { profile.flowControl = $0 })) }
            Text("Automatische Medienwahl mit eigener MTU: Hardwaremodus Manuell, Medium autoselect. Aktive Linkwerte und konfiguriertes Medium sind getrennt.").font(.caption)
            HStack {
                Button("Abbrechen") { dismiss() }
                Button("Profil speichern") {
                    Task {
                        guard let data = try? NetworkFiles.encode(profile) else { return }
                        let result = await model.run("network.profile.save", arguments: [String(decoding: data, as: UTF8.self)], confirmed: true)
                        if result.ok { await model.reloadNetworkSettings(); dismiss() }
                    }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 590)
    }
    private var mediaIndex: Int { port?.availableMedia.firstIndex { $0 == profile.media } ?? 0 }
    private func selected<T>(_ key: WritableKeyPath<PortProfile, T?>, fallback: T) -> Binding<Bool> {
        Binding(get: { profile[keyPath: key] != nil }, set: { profile[keyPath: key] = $0 ? fallback : nil })
    }
}
