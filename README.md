# We Rock Drive Mounts für macOS

We Rock Drive Mounts ist eine native macOS-Menüleisten-App für zuverlässige Synology- und SMB-Netzlaufwerke. Sie überwacht verbundene Freigaben, stellt unterbrochene Verbindungen kontrolliert wieder her und hält Ethernet als bevorzugte Verbindung. WLAN kann für AirDrop zeitweise aktiv bleiben und bei einem Ethernet-Ausfall automatisch einspringen.

Die App erfasst auf Wunsch Sleep-/Wake-, Netzwerk-, SMB- und Schnittstellenereignisse. Ein Raspberry Pi kann ergänzend begrenzte Wireshark-Paketmitschnitte und Synology-Syslog-Ereignisse liefern sowie diesen Mac per Wake-on-LAN wecken. Die lokale KI-Auswertung fasst vorhandene Belege und payload-freie `tshark`-Kennzahlen mit Quellenangaben zusammen.

Für große NAS-Transfers kann We Rock Drive Mounts Dateien oder Ordner zwischen Mac und gemounteten SMB-Freigaben kopieren oder verschieben. Transfers laufen über einen eigenen WRDM-Worker im Hintergrunddienst, bleiben als Jobs sichtbar und können nach einem Abbruch fortgesetzt werden. Bei hoher Transferrate oder Fehlern kann die App Diagnoseereignisse, Pi-Captures und ein Incident-Bundle aus Mount-Status, Netzwerkstatus, Traffic, Logs und vorhandenen Synology-Belegen erzeugen.

## Voraussetzungen

- Mac mit Intel-Prozessor oder Apple Silicon und macOS 15 Sequoia oder neuer
- Für lokale KI: Apple Silicon, macOS 26 oder neuer und aktiviertes Apple Intelligence
- SMB-Freigaben, die im Finder erreichbar sind
- Optional: Raspberry Pi mit SSH-Zugang für Paketmitschnitt, Syslog und Wake-on-LAN
- Optional: Wireshark auf dem Mac für Live-Mitschnitte

Die Universal-App enthält beide Prozessorarchitekturen. Mount-Verwaltung, Transfers, Finder-Integration und klassische Diagnosen stehen ab macOS 15 zur Verfügung. Die lokale KI wird abhängig von Betriebssystem und Apple-Intelligence-Verfügbarkeit aktiviert; ein Hinweis in den KI-Einstellungen erklärt den aktuellen Status. Die regelbasierte Diagnose bleibt verfügbar.

## Installation

Lade das aktuelle Universal-Installationspaket unter [GitHub Releases](https://github.com/wirrockendigital/We.Rock.Drive.Mounts/releases/latest) herunter und öffne die `.pkg`-Datei. Folge anschließend dem macOS-Installer. Die öffentliche Beta ist ad hoc signiert; macOS kann beim ersten Start eine zusätzliche Bestätigung verlangen.

### Aus dem Quellcode installieren

Zum Bauen benötigst du Xcode mit macOS-26-SDK und Swift 6.2 oder neuer. Der fertige Build läuft ab macOS 15.


Im Projektordner:

```bash
./install.sh
```

Der Installer baut und signiert die Beta lokal mit festen Komponentenkennungen, installiert sie unter `/Applications/We Rock Drive Mounts.app`, richtet den Hintergrunddienst ein und startet die App. Vorhandene Einstellungen werden automatisch übernommen. Da die Beta bewusst ad-hoc signiert ist, kann macOS nach einem neuen Build erneut um Zugriff auf das lokale Netzwerk bitten.

Die ausgeführten Komponenten bleiben im festen App-Bundle: App unter `/Applications/We Rock Drive Mounts.app/Contents/MacOS/WeRockDriveMounts`, Agent unter `/Applications/We Rock Drive Mounts.app/Contents/Helpers/We Rock Drive Mount Agent.app/Contents/MacOS/We Rock Drive Mount Agent` und CLI unter `/Applications/We Rock Drive Mounts.app/Contents/Helpers/wrdm`. `~/.local/bin/wrdm` ist ein Symlink auf diese CLI.

## Verwendung

Nach der Installation erscheint We Rock Drive Mounts in der macOS-Menüleiste.

Unter **Updates** in den Einstellungen kannst du jederzeit **Auf Updates prüfen** wählen. Der Hintergrunddienst prüft zusätzlich täglich den veröffentlichten Release-Feed. Ist eine neue Version verfügbar, siehst du die Versionsnummer und die Release-Notizen; mit **Update installieren** startest du die Installation. Laufende Transfers werden zuerst abgeschlossen. Wenn du Benachrichtigungen aktivierst, meldet macOS eine neue Version einmalig.

1. Öffne das Symbol in der Menüleiste.
2. Füge unter **Netzlaufwerke** deine SMB-Freigaben hinzu oder prüfe die übernommenen Laufwerke.
3. Aktiviere unter **Ethernet & WLAN** die automatische Verbindungssteuerung. Das AirDrop-Zeitfenster beträgt standardmäßig 15 Minuten.
4. Lege Dateien oder Ordner in das Transfer-Droplet unter dem Menüleistensymbol oder wähle im Finder **We Rock Transfer …**. Ziel, Kopieren/Verschieben, Fortsetzungsverhalten und optionales Wachhalten des Macs legst du im anschließenden Dialog fest. Aktuelle und vergangene Jobs stehen im separaten Transferfenster; unter **Transfers** in den Einstellungen liegen nur die dauerhaften Standards.
5. Schalte unter **Diagnose** die gewünschten lokalen Aufzeichnungen ein.
6. Verbinde unter **Datenquellen** optional den Raspberry Pi und Synology.
7. Aktiviere unter **Diesen Mac wecken** nur die gewünschten und erfolgreich geprüften Wake-Routen.

Ein Linksklick öffnet das Transfer-Droplet direkt unter dem Menüleistensymbol; ein weiterer Linksklick schließt es. Ein Rechtsklick bietet Status-, Diagnose-, Transfer- und Einstellungsaktionen. Während eines laufenden Transfers zeigt die Menüleiste den aggregierten Fortschritt in Prozent neben dem Symbol. Alle technischen Details, Speichergrenzen und Dateipfade liegen im Bereich **Erweitert**.

Unter **Konfiguration** kannst du deine Einstellungen als `.wrdmconfig`-Datei exportieren und auf demselben Mac für einen anderen Benutzer wieder importieren. Der Export enthält nicht geheime App-Einstellungen wie SMB-Adressen, Diagnoseoptionen, Raspberry-Pi-, Synology-, KI- und Wake-on-LAN-Konfiguration. Passwörter, API-Keys und Tokens bleiben im macOS-Schlüsselbund und werden nicht exportiert.

### Ethernet und Portüberwachung

Unter **Ethernet & WLAN** stehen die Anschlüsse mit ihren macOS-Namen. **Automatisch**
berücksichtigt geeignete Ethernet-Dienste und die vorhandene Dienstreihenfolge.
Nach drei stabilen Prüfungen kann WLAN abgeschaltet werden; ein bewusst gestartetes
AirDrop-Fenster behält seine Restzeit. Die App zeigt den Grund jeder Entscheidung.

Mit **Aktuelle Werte übernehmen …** erstellst du ein Profil für einen bestimmten
Adapter in diesem Netzwerk. Wähle die Werte aus, die überwacht werden sollen, und
aktiviere die Überwachung. Bestätigte Abweichungen erscheinen dauerhaft in der App
und als Warnsymbol in der Menüleiste. **Wunschwerte wiederherstellen …** zeigt zuerst
eine Vorschau und benötigt deine Bestätigung. Die Dienstpriorität lässt sich ebenfalls
über eine Vorschau ändern. Laufende WRDM-Transfers verhindern diese Änderungen.

**Support-Datei exportieren** speichert ein ZIP im Downloads-Ordner.
**Support-E-Mail vorbereiten** erstellt zusätzlich einen bearbeitbaren Mailentwurf
oder bietet Nachrichtentext und ZIP zum manuellen Anhängen an.

### Kontrollierte SMB-Wiederherstellung

WRDM unterscheidet ein wirklich fehlendes Netzlaufwerk von einem noch in macOS eingetragenen, aber nicht mehr antwortenden SMB-Mount. Fehlende Laufwerke kann der Hintergrunddienst mit begrenztem Backoff automatisch neu verbinden. Bei einem festgefahrenen Mount versucht er höchstens ein normales Unmount und prüft vor jedem Remount, ob macOS das alte Laufwerk tatsächlich aus der Mount-Tabelle entfernt hat.

Wenn ein WRDM-Transfer das Laufwerk verwendet, wird kein Unmount ausgeführt. Ein erzwungenes Unmount startet nur nach deiner ausdrücklichen Bestätigung über **Force recovery…** oder `wrdm --yes mounts force-recover`. Bleibt der macOS-SMB-Prozess im nicht unterbrechbaren Kernelzustand hängen, zeigt WRDM **Restart required** und beendet für diesen Systemstart alle weiteren Reparaturversuche.

Jeder Ausfall erhält genau einen lokalen Mount-Incident mit Verfügbarkeit, Recovery-Phase, Fehlercode und Evidenzpfad. Sleep- und Wake-Ereignisse werden nur aus tatsächlichen macOS-Power-Logs übernommen; eine verspätete Überwachungsrunde wird separat als Verzögerung gemeldet.

## Kommandozeile und AI-Anbindung

Die Installation stellt `wrdm` und `wrdm-mcp` unter `~/.local/bin` bereit. Damit lassen sich Status, Mounts, Transfers, Netzwerk, Diagnosen, Pi, Synology, KI-Analyse und Wake-on-LAN über dieselbe Kernlogik wie in der App steuern.

```bash
wrdm status
wrdm check
wrdm mounts list
wrdm mounts recover
wrdm --yes mounts force-recover <mount-id>
wrdm mounts incidents
wrdm config export ~/Desktop/we-rock-drive-mounts.wrdmconfig
wrdm --yes config import ~/Desktop/we-rock-drive-mounts.wrdmconfig
wrdm --yes app login on
wrdm network status
wrdm diagnostics export
wrdm transfer list
wrdm --yes transfer start copy macToNAS ask true false "/Volumes/NAS/Ziel" "$HOME/Desktop/Datei"
wrdm pi health
wrdm ai analyze "Was war die wahrscheinlichste Ursache des letzten Abbruchs?"
```

`transfer start` legt einen Job an; der Hintergrunddienst startet und überwacht den eigentlichen WRDM-Worker. Fortschritt, Geschwindigkeit, hohe Transferlast, Pausen, Stops, Fortsetzungen und Fehler stehen danach über App, CLI und MCP im selben persistenten Jobstatus. Automatische Wiederholungen können auf eine feste Anzahl begrenzt oder ohne feste Obergrenze geplant werden. Auch im unbegrenzten Modus bleibt jeder Versuch einzeln abbrechbar und wird mit einer auf fünf Minuten gedeckelten Wartezeit gestartet; dauerhafte Konfigurations- und Berechtigungsfehler stoppen sofort.

Die vollständige Befehlsreferenz steht in [Documentation/CLI.md](Documentation/CLI.md).

## Lizenz

We Rock Drive Mounts steht unter der [GNU General Public License Version 3 oder neuer (GPL-3.0-or-later)](LICENSE). Das eingebundene Sparkle-Framework steht unter seiner eigenen, in [ThirdParty/Sparkle-LICENSE](ThirdParty/Sparkle-LICENSE) dokumentierten Lizenz.

## Deinstallation

```bash
./uninstall.sh
```

Die normale Deinstallation erhält Einstellungen und Diagnosen. Für eine vollständige Entfernung der Benutzerdaten:

```bash
./uninstall.sh --purge
```
