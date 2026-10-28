# Öffentliche Beta veröffentlichen

Ein Release besteht aus derselben Versionsnummer im App-Bundle, Git-Tag, GitHub-Release und Sparkle-Appcast. Der Feed liegt unter `docs/appcast.xml` und wird über GitHub Pages bereitgestellt.

1. Tests und den Universal-Build ausführen: `swift test` und `./scripts/build-pkg.sh`.
2. Das vom Build erzeugte ZIP als `We.Rock.Drive.Mounts-<version>.zip` für GitHub Releases bereitstellen.
3. Mit dem offiziellen Sparkle-Werkzeug `generate_appcast` und `scripts/generate-appcast.sh` den Feed aus genau diesem ZIP erzeugen. Der Ed25519-Schlüssel wird ausschließlich über Standardeingabe übergeben. Anschließend die eingebettete Feed-Signatur mit `sign_update --verify` prüfen.
4. Feed und Quellcode committen, den passenden `v<version>`-Tag erstellen und beides veröffentlichen.
5. ZIP und PKG an das GitHub-Release hängen. Danach den öffentlichen Feed, beide Downloads und die darin angegebenen Versionsnummern per HTTPS prüfen.

Sparkle verwendet das signierte ZIP für Updates aus der App. Das PKG dient der Erstinstallation und manuellen Neuinstallation. Bei aktivem Transfer verschiebt die App den Neustart für ein Update bis nach dem Transferende.
