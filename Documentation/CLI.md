# CLI- und MCP-Referenz

## CLI

`wrdm` verwendet dieselben typisierten Einstellungen und Kommandos wie Menüleisten-App und Hintergrunddienst. Lesende Befehle benötigen keine Bestätigung. Zustandsänderungen werden mit `--yes` ausdrücklich bestätigt. `--json` liefert ein stabiles `CommandResult` mit `ok`, `code`, `message` und `data`.

```text
wrdm [--json] [--yes] status
wrdm [--json] [--yes] check
wrdm [--json] config show
wrdm [--json] config export <path>
wrdm [--json] --yes config import <path>
wrdm [--json] --yes config set <key> <value>
wrdm [--json] app login status
wrdm [--json] --yes app login on
wrdm [--json] --yes app login off
wrdm [--json] mounts list
wrdm [--json] mounts recover [mount-id ...]
wrdm [--json] --yes mounts force-recover [mount-id ...]
wrdm [--json] mounts incidents [limit]
wrdm [--json] mounts add <name> <smb-url> [true|false]
wrdm [--json] mounts update <id> <name> <smb-url> [true|false]
wrdm [--json] --yes mounts remove <id>
wrdm [--json] mounts enable <id> <true|false>
wrdm [--json] network status
wrdm [--json] --yes network wifi allow [minutes]
wrdm [--json] --yes network wifi off
wrdm [--json] diagnostics events [limit]
wrdm [--json] diagnostics capture [label]
wrdm [--json] diagnostics export
wrdm [--json] transfer list
wrdm [--json] transfer monitoring
wrdm [--json] transfer status <job-id>
wrdm [--json] --yes transfer start <copy|move> <auto|macToNAS|nasToMac> <ask|autoRetry|manual> <true|false keep-awake> <true|false unlimited-retry> <destination-folder> <source> [source...]
wrdm [--json] --yes transfer pause <job-id>
wrdm [--json] --yes transfer stop <job-id>
wrdm [--json] --yes transfer resume <job-id>
wrdm [--json] --yes transfer finalize-move <job-id>
wrdm [--json] transfer incident [job-id]
wrdm [--json] pi health
wrdm [--json] --yes pi install <installer-path>
wrdm pi password set
wrdm pi password delete
wrdm [--json] --yes capture start [host-filter]
wrdm [--json] --yes capture live [host-filter]
wrdm [--json] --yes capture stop <session-id>
wrdm [--json] capture open <pcapng-path>
wrdm [--json] synology health
wrdm [--json] synology tail [limit]
wrdm [--json] synology ssh-health
wrdm [--json] synology import <csv-path>
wrdm [--json] synology fetch
wrdm [--json] ai analyze <question>
wrdm ai key set
wrdm ai key delete
wrdm [--json] --yes wake <route>
wrdm [--json] --yes wake verify <route>
```

Passwörter und API-Schlüssel werden bei `set` über `stdin` gelesen und nur im macOS-Schlüsselbund gespeichert. `config export` schreibt ausschließlich nicht geheime App-Einstellungen in eine `.wrdmconfig`-Datei. `config import` validiert die Datei vollständig, bevor die aktive Konfiguration ersetzt wird.

## SMB-Zustand und Recovery

`check` ist strikt lesend. Der Befehl prüft Mount-Tabelle und SMB-Sitzungen, löst aber weder Mount noch Unmount aus. `mounts list` liefert für jede Freigabe zwei unabhängige Zustände:

- `availability`: `disabled`, `healthy`, `missing`, `staleMounted` oder `unknown`
- `recoveryPhase`: unter anderem `idle`, `waitingForNetwork`, `scheduled`, `deferredActiveTransfer`, `manualConfirmationRequired`, `circuitOpen` oder `restartRequired`

Zusätzlich stehen ein stabiler `failureCode`, die `incidentID`, der nächste geplante Versuch und eine lesbare Meldung im JSON-Ergebnis. `mounts incidents` liest die höchstens 100 lokalen Mount-Incident-Manifeste.

`mounts recover` startet eine begrenzte normale Recovery. Fehlende Freigaben werden nur bei erreichbarem SMB-Port eingehängt. Bei einem `staleMounted`-Zustand versucht WRDM höchstens einmal ein normales Unmount, prüft danach die Mount-Tabelle erneut und mountet ausschließlich nach nachgewiesenem Detach. Ein laufender WRDM-Transfer auf dem betroffenen Laufwerk blockiert jeden Unmount.

`mounts force-recover` ist ein eigener destruktiver Pfad und verlangt immer `--yes`. Optional begrenzen Mount-IDs beide Recovery-Befehle auf bestimmte Freigaben. Bleibt ein Unmount-Prozess trotz `TERM` und `KILL` im macOS-Kernelzustand `U`, lautet das Ergebnis `RESTART_REQUIRED`. WRDM führt dann bis zu einer geänderten Boot-Identität keine weitere Mount-Mutation für diese Freigabe aus.

Automatische Versuche enden nach `general.maximumAutomaticRecoveryAttempts` im Zustand `circuitOpen`. WRDM beendet oder startet keine gemeinsam genutzten macOS-SMB-Helferprozesse automatisch.

Transfer-Jobs verwenden lokale, gemountete Pfade. Mit `auto` wird die Richtung aus Quelle und Ziel ermittelt. Bei `macToNAS` liegt das Ziel auf einer verbundenen SMB-Freigabe, bei `nasToMac` liegen die Quellen dort. Bereits verbundene SMB-Freigaben können auch ohne Eintrag in der WRDM-Laufwerksverwaltung verwendet werden. `transfer start` legt den Job nur in die Warteschlange; der Hintergrunddienst startet und überwacht den eigentlichen WRDM-Worker-Prozess. Der Parameter `unlimited-retry` gilt pro neuem Job und wirkt nur zusammen mit `autoRetry`. `move` löscht Quellen nicht sofort, sondern erst nach erfolgreicher Kopierprüfung über `transfer finalize-move`.

`transfer monitoring` zeigt neben den gespeicherten Schwellenwerten den Besitzer `background-agent`, die Anzahl wartender und laufender Jobs, den effektiven Retry-Modus und die aktuelle Agent-Phase. Laufende Jobs persistieren Fortschritt, Datei-/Bytezähler, Geschwindigkeit, Stall-Dauer und sustained high-traffic evidence. `transfer.unlimitedAutoRetries=true` wirkt nur zusammen mit `transfer.defaultResumePolicy=autoRetry`; die gespeicherte numerische Grenze bleibt erhalten und wird wieder verwendet, sobald der unbegrenzte Modus ausgeschaltet wird. Unbegrenzte Wiederholungen verwenden einen persistenten, bis fünf Minuten gedeckelten Backoff. Dauerhafte Validierungs- und Berechtigungsfehler werden nicht wiederholt. Dadurch ist kein externer Terminal- oder Codex-Monitor nötig.

## Lokaler MCP-Server

`wrdm-mcp` ist ein lokaler stdio-MCP-Server. Er veröffentlicht die kanonischen Kommandos als Tools und verwendet dieselben Ergebnisobjekte, Risikoklassen und Bestätigungsregeln wie CLI und GUI.

Beispiel für eine Client-Konfiguration:

```json
{
  "command": "/Users/USERNAME/.local/bin/wrdm-mcp"
}
```

Unbekannte Felder werden abgewiesen. Kritische oder entfernte Änderungen erreichen ohne `confirmed: true` keinen Adapter. Schlüsselbund-Operationen für Geheimnisse sind absichtlich keine MCP-Tools.

Die GUI speichert mehrteilige Formularänderungen als einen atomaren, lokal validierten Konfigurationsstand. Einzelne Betriebsaktionen laufen über `CommandService`. CLI und MCP können dieselben nicht geheimen Einstellungen über `config.set`, `config.export`, `config.import` sowie Mounts über die CRUD-Kommandos verwalten. Damit bleiben Formulare transaktional, während AI-Clients die vollständige nicht geheime Bedienoberfläche erhalten.

## Konfigurationsschlüssel

```text
general.enabled
general.openAppAtLogin
general.checkIntervalSeconds
general.bootDelaySeconds
general.maximumAutomaticRecoveryAttempts
general.mountTimeoutSeconds
general.smbHealthTimeoutSeconds
general.language
general.onboardingCompleted
network.enabled
network.lanInterface
network.wifiInterface
network.wifiGraceMinutes
network.disableWifiWhenLanActive
network.enableWifiWhenLanUnhealthy
network.lanFailureThreshold
network.lanRecoveryStableChecks
network.gatewayHost
network.remoteReachabilityHosts
network.trafficEnabled
network.trafficInterfaces
network.trafficMaxBytes
diagnostics.enabled
diagnostics.networkEventsEnabled
diagnostics.sleepWakeEventsEnabled
diagnostics.macLogsEnabled
diagnostics.macLogLookbackMinutes
diagnostics.retentionDays
diagnostics.retentionIntervalMinutes
diagnostics.maximumStoreBytes
diagnostics.redactPathsInExports
transfer.monitoringEnabled
transfer.highTrafficBytesPerSecond
transfer.sustainedSeconds
transfer.rollingPiCaptureEnabled
transfer.incidentBundleOnFailure
transfer.defaultResumePolicy
transfer.maximumAutoRetries
transfer.unlimitedAutoRetries
transfer.verifyAfterCopy
transfer.keepMacAwakeByDefault
packetCapture.enabled
packetCapture.host
packetCapture.user
packetCapture.interface
packetCapture.durationSeconds
packetCapture.remoteDirectory
packetCapture.maximumFiles
packetCapture.maximumFileBytes
synology.syslogEnabled
synology.syslogPort
synology.readOnlySSHEnabled
synology.sshHost
synology.sshUser
synology.dsmAPIEnabled
synology.dsmBaseURL
synology.csvImportEnabled
ai.enabled
ai.provider
ai.actionMode
ai.cloudDataMode
ai.openAIModel
ai.selectedEvidenceIDs
wake.targetName
wake.targetMACAddress
wake.targetHost
wake.route.raspberryPiLAN.enabled
wake.route.raspberryPiLAN.command
```

Listen werden kommasepariert gesetzt. Leere `ai.selectedEvidenceIDs` bedeuten keine explizite Rohdaten-Auswahl. Wake-Routen folgen dem Schema `wake.route.<route>.enabled` und `wake.route.<route>.command` für `raspberryPiLAN`, `tailscale`, `synologyTask`, `iosShortcut` und `cli`.

## Native Netzwerkbeobachtung und Portprofile

`wrdm network status --json` liefert Anschlussnamen, Link-/Medien-/MTU-Werte und
Zielprüfungen sowie die letzte Agentenentscheidung. Profil- und bestätigte
Änderungsbefehle sind im [Überblick zu Netzwerkfunktionen](NETWORK-PORTS-IMPLEMENTATION.md#konfiguration-und-befehle)
beschrieben. `wrdm diagnostics export [Zielordner] --json` liefert den Pfad und die
Größe eines geprüften Support-ZIPs; ohne Zielordner wird Downloads verwendet.
