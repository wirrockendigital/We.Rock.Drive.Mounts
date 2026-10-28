# Diagnose- und Datenschutzreferenz

## Lokale Daten

Die App speichert ihre Konfiguration unter `~/Library/Application Support/we-rock-drive-mounts` und Diagnoseinformationen unter `~/Library/Logs/we-rock-drive-mounts`.

- `agent-status.json`: letzter Zustand des Hintergrunddienstes
- `diagnostics/events.jsonl`: Sleep/Wake-, Netzwerk-, Mount-, Pi- und Synology-Ereignisse
- `state/mount-incidents.json`: begrenzter Index der letzten Mount-Ausfälle
- `mount-incidents/<incident-id>.json`: genau ein fortgeschriebenes Evidenzmanifest pro Mount-Ausfall
- `network-traffic.jsonl`: Byte-Zähler, Deltas und Raten je Schnittstelle
- `diagnostics/mac-*.log`: ausdrücklich ausgelöste macOS-Log-Snapshots
- `diagnostics/pcap/*.pcapng`: vollständig geladene Pi-Mitschnitte
- `diagnostics/support-*.supportbundle`: redigierte Support-Exporte
- `action-audit.jsonl`: angeforderte Aktionen, Risikoklasse und Ergebnis

Aufbewahrungsdauer und Größenlimits sind konfigurierbar. Deaktivierte Collector schreiben keine neuen Ereignisse der jeweiligen Quelle.

## Paketmitschnitt

Paketmitschnitte sind standardmäßig ausgeschaltet. Der Pi filtert auf SMB (`TCP 445`), ICMP und ARP sowie optional auf einen Zielhost. Dauer, Dateianzahl und Gesamtgröße sind begrenzt. Downloads werden als `.partial` übertragen, geprüft und erst danach atomar als PCAPNG veröffentlicht.

Nach einem gespeicherten Mitschnitt erzeugt `tshark` auf dem Pi eine payload-freie Zusammenfassung mit Paket- und Protokollzahlen, TCP-Retransmits, TCP-Resets, ICMP-Fehlern und Anzahl der Kommunikationspaare. Endpunktadressen und Paketinhalte werden nicht in diese Zusammenfassung übernommen. Gemischte VLAN-getaggte und ungetaggte Frames werden als mögliche Mirror-Duplizierung markiert, damit AI-Auswertungen daraus keinen sicheren Paketverlust ableiten.

## Power- und Mount-Ereignisse

Sleep, Wake und DarkWake werden ausschließlich aus datierten macOS-`pmset`-Ereignissen übernommen. Eine längere Pause zwischen zwei Agent-Zyklen erzeugt nur `monitoringDelayed` und wird nicht als Schlafzustand interpretiert.

Mount-Incidents speichern Beobachtung und Recovery getrennt. Die Verfügbarkeit beschreibt den SMB-Zustand; die Recovery-Phase beschreibt, ob WRDM wartet, einen Versuch plant, durch einen Transfer blockiert ist, eine Bestätigung benötigt, den Circuit Breaker geöffnet hat oder einen Neustart verlangt. Wiederholte Prüfungen desselben Ausfalls aktualisieren das bestehende Manifest. Erst eine nachgewiesen gesunde SMB-Sitzung schließt den Incident.

## Synology

Der Pi empfängt Syslog standardmäßig auf UDP-Port `5514`, wenn die Quelle aktiviert ist. In Synology Log Center kann der konfigurierte Pi-Host mit Port `5514` als Syslog-Ziel eingetragen werden. CSV-Import, DSM API und der feste read-only SSH-Status sind unabhängige Quellen.

## AI-Auswertung

Die Standardauswertung läuft lokal. Sie erhält die kanonischen Ereignisse einschließlich der abgeleiteten Capture-Kennzahlen und muss ihre Aussagen auf deren Evidence-IDs beziehen. Für OpenAI stehen getrennte Datenmodi zur Verfügung: reduzierte Befunde, ausdrücklich ausgewählte Protokolle oder vollständige Diagnosen. Der API-Schlüssel liegt ausschließlich im macOS-Schlüsselbund.
