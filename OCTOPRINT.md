# STL laden und über OctoPrint drucken (SK-CAD)

Ergänzung zum Bambu-Weg (Phase 8): Fremde oder eigene STL-Dateien ins Projekt holen und über einen OctoPi im LAN
drucken. Kernel: `kernel/src/kevcad_kernel/stl/` und `kernel/src/kevcad_kernel/octoprint/`, MCP:
`mcp_tools/stl_octoprint_tools.py`, Tests: `kernel/tests/test_stl_octoprint.py`.

## Einrichtung (einmalig)

1. **API-Schlüssel in OctoPrint erzeugen:** OctoPrint öffnen (`http://192.168.1.233`), Einstellungen (Schraubenschlüssel)
   > Application Keys > Schlüssel für „SK-CAD“ erzeugen und kopieren.
2. **Schlüssel in den macOS-Schlüsselbund legen** (fragt nach dem Wert, er landet nicht in der Shell-Historie):

   ```bash
   security add-generic-password -U -s de.upvis.kevcad.octoprint -a octopi -w
   ```

3. **PrusaSlicer installieren** (prusa3d.com) und dort den Drucker, das Filament und die Druckeinstellungen einrichten,
   die OctoPrint drucken soll. Dann „Datei > Exportieren > Konfiguration exportieren“ als `.ini` speichern, z. B.
   `~/Documents/SK-CAD/octopi-drucker.ini`.
4. **Einstellungen setzen** – im Gespräch mit Claude: „richte OctoPrint ein, Profil ~/Documents/SK-CAD/octopi-drucker.ini“
   (Werkzeug `octoprint_einrichten`), oder von Hand in
   `~/Library/Application Support/de.upvis.kevcad/octoprint.json`:

   ```json
   {"url": "http://192.168.1.233", "profil": "~/Documents/SK-CAD/octopi-drucker.ini", "name": "OctoPi"}
   ```

   `slicer` nur angeben, wenn PrusaSlicer nicht unter `/Applications` liegt.

`octoprint_status` zeigt danach Verbindung, Temperaturen und laufende Drucke.

## Ablauf

| Werkzeug | Wirkung |
|---|---|
| `stl_laden(pfad)` | Kopie nach `<projekt>/stl/<name>.stl`, Netz als Referenz (art `stl`) im Viewer |
| `stl_liste` | STL des Projekts mit Maßen, Volumen, dicht/offen |
| `octoprint_status` | nur lesend |
| `octoprint_drucken(datei)` | slicen (PrusaSlicer), nach `sk-cad/` auf OctoPrint laden, auswählen – **druckt nicht** |
| `octoprint_drucken(datei, starten=true)` | wie oben und sofort drucken (nur auf ausdrückliche Bitte) |
| `octoprint_starten(octoprint_datei)` | bereits hochgeladene Datei drucken (nur auf ausdrückliche Bitte) |

Gestartet wird nur, wenn OctoPrint mit dem Drucker verbunden und der Drucker frei ist.

## Sicherheit

- Der API-Schlüssel steht nur im Schlüsselbund (oder `KEVCAD_OCTOPRINT_KEY` für Tests), nie in `octoprint.json`, in
  Ergebnissen, Fehlermeldungen oder Protokollen.
- Drucken ist eine physische Handlung: Agenten starten nie von sich aus, auch nicht zum Testen.

## Vertragsänderung

`service.py` (`KernelService`) hat sechs neue Methoden (`stl_laden`, `stl_liste`, `octoprint_status`,
`octoprint_einrichten`, `octoprint_drucken`, `octoprint_starten`); `KernelRuntime` erbt sie von `StlRuntimeMixin` und
`OctoPrintRuntimeMixin`. Protokoll Kernel ↔ App unverändert: Die STL erscheint über den bestehenden Referenzweg.
