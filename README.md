# SK-CAD

SK-CAD ist Sebastians Fork von [Kev CAD](https://github.com/UPVIS/kev-cad) (Kevin Schwed, UPVIS, MIT). Sichtbar heißt die
App SK-CAD und spricht Sebastian an; Code-Bezeichner, Pfade, Bundle-ID (`de.upvis.kevcad`) und der MCP-Name `kevcad`
bleiben wie im Original, damit sich neue Stände von Kevin weiter übernehmen lassen:

```bash
git fetch upstream && git merge upstream/main   # upstream = https://github.com/UPVIS/kev-cad.git
./build.sh
```

Name und Anrede stehen an einer Stelle: `KEVCAD_DISPLAY_NAME` und `KEVCAD_USER_NAME` in `app/project.yml`,
`DISPLAY_NAME` in `build.sh` und `KEVCAD_NUTZER` (Umgebung des Kernels, Vorgabe „Sebastian“).

Die folgende Beschreibung stammt aus Kev CAD.

# Kev CAD

Kev CAD ist ein nativer CAD-Viewer für den Mac, den ein KI-Agent über MCP bedient. Der Agent schreibt ein
parametrisches `model.py` mit [build123d](https://github.com/gumyr/build123d), und Kev CAD baut das Modell Teil für
Teil live auf. Messen, Ansichten, Schnitte und Export gehen per Klick oder durch den Agenten. Nach jedem Lauf prüft
Kev CAD die Konstruktion: Durchdringung, Standsicherheit, Einbaubarkeit, Druckbarkeit und Statik.

Entstanden ist es als Kevins eigenes Werkzeug für Werkstatt- und Filmbauten. Es lässt sich aber auf jedem Mac mit
Apple Silicon bauen.

## Was es kann

- **Modellieren im Gespräch:**
  - `model.py` mit build123d und `param()`-Maßen, Live-Aufbau im Metal-Viewer.
  - Versionen, Meilensteine und Varianten.
- **Lager und Einkauf:**
  - Lagerkatalog mit Rohren, Profilen, Platten, Schrauben und Materialien.
  - Zukaufteile per Shop-Link oder Hersteller-CAD.
  - Stückliste, Zuschnitt mit Resten, Bestand und Einkaufsliste.
- **Prüfen:**
  - Durchdringung (mit Gewindeeingriff), Schweben und Kippen, Montagereihenfolge.
  - Zwangsbedingungen und Gelenke mit Bewegungsraum.
- **3D-Druck:**
  - Konstruktionsregeln und Druckprüfung je Teil.
  - Druckvorschau mit Filament, Zeit und Kosten.
  - Druckfertiger Export als Bambu-Studio-Projekt.
- **Statik und Simulation:**
  - Stabwerk (PyNite), Ablauf (MuJoCo), Festkörper-FEM (Gmsh, scikit-fem).
  - Kontakt und Plastizität mit CalculiX.
  - Lastfälle per Klick, Topologieoptimierung.
- **Referenzen:**
  - Video oder Fotos des echten Gegenstands (Apple Object Capture).
  - Maße des Modells aus den Bildern vermessen (fotomess).
  - iPhone-Scans mit LiDAR und Prompt Depth Anything (App Kev Scan).
- **Dokumente und Bilder:**
  - Technische Zeichnungen nach ISO, Bauplan Schritt für Schritt, Berichte als PDF.
  - Kameras mit echtem Sensor und Objektiv, Animationen, Renderings (RealityKit, Blender Cycles).

## Einrichten

Voraussetzungen:
- Mac mit Apple Silicon und macOS 15 oder neuer.
- Xcode mit Metal-Toolchain.
- Homebrew mit `xcodegen` und `librsvg`.
- [uv](https://docs.astral.sh/uv/).

```bash
git clone https://github.com/UPVIS/kev-cad.git && cd kev-cad
./build.sh
claude mcp add kevcad -s user -e KEVCAD_LAUNCH_ON_START=0 \
  -- "$HOME/Library/Application Support/de.upvis.kevcad/install/kernel/.venv/bin/kevcad-mcp"
ln -sfn "$HOME/Library/Application Support/de.upvis.kevcad/install/skill/kev-cad" ~/.claude/skills/kev-cad
```

Die ganze Anleitung mit Prüfschritten, anderen MCP-Clients, Zusatzprogrammen, iPhone-App und Fehlerbehebung steht in
**[EINRICHTUNG.md](EINRICHTUNG.md)**. Sie ist so geschrieben, dass ein KI-Agent sie ausführen kann:

> Richte Kev CAD nach `EINRICHTUNG.md` in diesem Repo ein und prüf zum Schluss mit dem MCP-Werkzeug `status`, ob App
> und Kernel verbunden sind.

Danach in einer neuen Sitzung zum Beispiel: „Leg in Kev CAD ein Projekt Regalwinkel an und bau einen Winkel aus
4-mm-Stahlblech mit zwei Bohrungen.“

## Aufbau

| Ordner | Inhalt |
|---|---|
| `app/` | SwiftUI-App mit dem Metal-Viewport [OCCTSwiftViewport](https://github.com/SecondMouseAU/OCCTSwiftViewport); `app/KevCADCore` ist der testbare Kern ohne Oberfläche |
| `kernel/` | Python-Kernel (build123d, ocp-tessellate) mit MCP-Server; `kevcad` ist die API für `model.py` |
| `skill/kev-cad/` | Leitfaden für den Agenten (Modellieren, 3D-Druck, Statik, Zeichnungen …) |
| `fotomess/` | Maße eines Modells aus Fotos, Video oder Scan einpassen |
| `scan/` | iPhone-Scans auswerten (Prompt Depth Anything, TSDF) |
| `tools/capture/` | `kevcad-capture`, Referenznetz aus einem Video mit Apple Object Capture |
| `ios/KevScan/` | iPhone-App Kev Scan (optional) |
| `samples/` | Beispielprojekte |

Verträge zwischen den Teilen:
- [PROTOCOL.md](PROTOCOL.md): Kernel und App.
- [SCAN.md](SCAN.md): iPhone und Mac.
- [MIRROR.md](MIRROR.md): Spiegel aufs iPhone.
- [DRUCKVORSCHAU.md](DRUCKVORSCHAU.md), [BESTAND.md](BESTAND.md), [DOKUMENTE.md](DOKUMENTE.md).

Stand und Geschichte der Phasen: [ROADMAP.md](ROADMAP.md). Pläne je Phase: `PLAN-*.md`. Herkunft der Bausteine:
[RECHERCHE.md](RECHERCHE.md). Fremde Bausteine und ihre Lizenzen: [DRITTANBIETER.md](DRITTANBIETER.md).

## Entwickeln

- `./build.sh --core-tests` führt die Tests von KevCADCore (swift test) und Kernel (pytest) aus.
- `./build.sh --test` baut eine Testvariante, die neben der installierten App laufen kann.
- Schnittstellen, die nur gemeinsam geändert werden dürfen, und die Arbeitsregeln für Agenten stehen in
  [CLAUDE.md](CLAUDE.md). Die dortigen Regeln zu Mac mini und Monitoren gelten für Kevins Rechner.
- Oberfläche, Kommentare und Doku sind auf Deutsch, Bezeichner im Code englisch.

## Lizenz

[MIT](LICENSE), © 2026 Kevin Schwed (UPVIS). Fremde Bausteine stehen unter ihren eigenen Lizenzen, siehe
[DRITTANBIETER.md](DRITTANBIETER.md); manche davon (etwa CalculiX, GPL) lädt Kev CAD nur zur Laufzeit als eigenes
Programm und liefert sie nicht mit.
