---
name: kev-cad
description: |-
  Leitfaden für Kev CAD, Kevins nativen CAD-Viewer auf dem Mac (MCP-Server „kevcad“, Werkzeuge wie run, screenshot, measure). Verwenden, sobald Kevin in Kev CAD ein 3D-Modell bauen, ändern, vermessen, ansehen oder exportieren will – Halter, Gehäuse, Bauteile, Möbel, Baugruppen als model.py mit build123d, die sich live im Viewer aufbauen. Auch bei „bau mir …“, „mach die Bohrung größer“, „wie weit ist das vom Rand weg“, „zeig mir die Lasche von der Seite“, „was hab ich angeklickt“, „exportier als STEP/STL/3MF“ in einem Kev-CAD-Projekt, ebenso bei Lagerteilen (Rohre, Profile, Platten, Holz, Schrauben aus dem Katalog), Stückliste, Zuschnitt, Gewicht und Kosten („was kostet das“, „wie viele Stangen“), 3D-Druckteilen, Zukaufteilen per Shop-Link, Herstellernummer oder EAN („bau diesen Auszug ein: https://…“, Hersteller-CAD, STEP aus den Downloads übernehmen), Kameras („setz die FX6 mit 35 mm auf den Wagen“, „zeig mir ihr Bild“, „rendere das Kamerabild in 4K“) und Animationen („lass den Wagen rollen“, „Kollision prüfen“, „mach ein Video aus Sicht der FX6“), technischen Zeichnungen („mach mir Zeichnungen“, „Werkstattzeichnung vom Rohr“, „bemaß die Platte“, „Maß fehlt auf dem Blatt“) sowie Bauplan und Bauanleitung („mach mir einen Bauplan“, „was muss ich bohren und in welcher Reihenfolge montieren“) und Referenzen aus Handyvideo oder Fotos („hier ist ein Video vom Gerät, bau es nach“, „miss die Maße aus den Fotos“, „leg das Video als Referenz an“, „passt das Modell zum Foto?“) sowie Scans vom iPhone mit Kev Scan („ich hab das gescannt“, „übernimm den Scan“, „miss das am Scan“).
---

# Kev CAD

Ein Modell ist `model.py` im Projektordner (build123d, Millimeter, Z nach oben). Der Kernel führt die Datei aus, jedes
`show()` erscheint sofort im Viewer, Kevin sieht beim Bauen zu. Die Datei ist die Quelle der Wahrheit: Änderungen immer
dort, nie nur per `execute`.

## Konstruktionsregeln (Kevin, 21.10.2026, gilt immer)

Jedes Design folgt den 15 Regeln in [konstruktion.md](konstruktion.md), vor der ersten Zeile Geometrie lesen.
Optimiert wird für Einzelstücke und kleine Stückzahlen; notwendige Funktionen, Schnittstellen und Sicherheit bleiben
erhalten. Kurz: Anforderungen vor Geometrie (fehlende Angaben erfragen, Annahmen kennzeichnen), Wirkprinzip
hinterfragen, Weglassen vor Optimieren, Gesamtaufwand bewerten, Standardteile vor Sonderteilen, Druckorientierung
früh, Kräfte führen statt Material häufen, Montage und Wartung mitkonstruieren, nichts als geprüft behaupten, was
nicht nachgewiesen ist. Auf „prüfe das Design kritisch“ folgt das Design-Review mit den fünf wichtigsten
Verbesserungen im festen Format (konstruktion.md).

## Prüfen vor dem Fertigmelden (Kevin, 21.10.2026, gilt immer)

Nichts darf physikalisch unmöglich sein. Kev CAD prüft jeden Lauf selbst (Durchdringung, Schweben, Standsicherheit,
Einbaubarkeit), `run` wartet auf das Ergebnis; `pruefen` zeigt alles samt Stand und Montage. Befunde beheben, nicht nur
melden:

- **Vor dem Fertigmelden auf den Endstand warten** (Prüftempo, 22.10.2026): Schafft der Bewegungsraum das Zeitlimit
  eines Laufs nicht, sagt `run` „Bewegungsraum: 2 Gelenke noch nicht geprüft (Zeitlimit), wird im Hintergrund fertig
  gerechnet“ (Zustand `teilweise`). Das ist kein fertiges Ergebnis. Kev CAD rechnet ohne neuen Lauf weiter; `pruefen()`
  (wartet standardmäßig, `warten=true`) bzw. `bedingungen()` zeigt den Endstand. Erst wenn dort keine Fehler mehr
  stehen, fertig melden. Nicht einfach `run` wiederholen, das verwirft das Fertigrechnen und beginnt von vorn.
- Große Modelle: `run(timeout_s=…)` (höchstens 900 s) hebt das Zeitlimit für model.py an, wenn ein Lauf daran scheitert.

- **Keine Durchdringungen:** Teile dürfen sich berühren, aber nicht ineinander stecken (gemeldet ab 0,001 mm³
  Schnittvolumen und 0,01 mm Tiefe). Verbindungselemente sind keine Ausnahme: Scheibe in Scheibe, Kopf in Scheibe,
  Schraube in einer zu kleinen Durchgangsbohrung. Die einzige Ausnahme erkennt Kev CAD selbst: echter
  Gewindeeingriff (Schraube in Mutter, Einsatz oder Kern-/Gewindeloch, gleiche Achse, nur im Gewindeband), metrisch
  und Zoll (UNC/UNF, etwa 1/4"-20 und 3/8"-16 an Kameras und Stativen). Innengewinde dafür als Kernloch modellieren
  (M4 3,3, M6 5,0, 1/4"-20 5,1, 3/8"-16 7,94; Tabelle unten). Ohne App (im geklonten Repo, bei Kevin
  `~/Code Experiments/Kev CAD`): `cd "<Repo>/kernel" && .venv/bin/python tools/check_interference.py
  "<Projektordner>" [--kontakte] [--gewinde]` rechnet eine Kopie mit genau dieser Prüfung (gleiche Schwellen,
  Gewindeeingriff, `erlaubt_ueberlappung`).
- Befunde kommen als isError mit Ort, Volumen, Tiefe und einer Lösung je Befund. Kevin sieht die Teile rot und das
  Schnittvolumen als roten Körper; Export ist gesperrt, bis alles behoben ist.
- **Beheben, nicht wegerklären:** Spiel oder Bohrung vorsehen, Teil verschieben, Maß korrigieren, dann wieder `run`.
  Gewollte Überlappungen (Presspassung, nachgiebiger Schaum) nur nach Rückfrage bei Kevin und mit Grund in model.py:
  `erlaubt_ueberlappung(a, b, grund="Presspassung, mit Kevin abgestimmt")` (`from kevcad import erlaubt_ueberlappung`;
  a und b als Name aus `show()`, Gruppe oder Form). Ohne Grund gilt sie nicht.
- **Nichts schwebt, alles ist befestigt:** Jedes Teil berührt sein Gegenstück oder steht auf dem Boden, und zu jedem
  Teil ist konstruiert, **wie es befestigt ist** (Schraube mit Bohrung und Gewinde bzw. Mutter, Klemmung, Steckverbindung,
  Formschluss, Kleben oder nur Aufliegen). Die Befestigung steht als Kommentar am Teil und lässt sich mit Werkzeug
  montieren. Nie Teile einfach in den Raum setzen. Mit `bed.verbinde(...)` (Abschnitt „Teile über Bedingungen
  setzen“) prüft Kev CAD bei jedem Lauf, dass die Befestigung physisch da ist und alles über Verbindungen am Boden
  hängt. Modelle ganz ohne Bedingungen prüft die eingebaute Prüfung trotzdem auf Schweben: Gruppen ohne Kontakt zum
  Boden kommen mit Fallweg („fiele 12 mm auf Rahmen“); Spielpassungen bis 0,5 mm zählen als Verbindung, „berührt“
  heißt bis 0,05 mm. Boden ist der tiefste Punkt oder `boden(z)`. Hängt etwas an Wand oder Decke:
  `befestigt(teil, grund="an der Wand verschraubt")`, nur nach Rückfrage bei Kevin.
- **Steht sicher:** Je Gruppe auf dem Boden rechnet die Prüfung Masse (Materialdichte, sonst angenommen 1 g/cm³ mit
  Hinweis), Schwerpunkt, Standfläche und Kippwinkel. Liegt der Schwerpunkt außerhalb: Fehler; unter 3° Kippwinkel:
  Warnung. Lösung: Standfläche verbreitern, Schwerpunkt senken, Gegengewicht.
- **Lässt sich einbauen:** siehe „Montagegerecht konstruieren“.
- **Nachgiebige Teile** (Material mit `nachgiebig` im Katalog: PE-Schaum, Gummi, TPU) dürfen bis zur halben Dicke
  zusammengedrückt werden; das ist ein Hinweis („verformt“), kein Fehler.
- **Bewegungsraum:** Alles, was man bedient oder was sich bewegt (Hebel, Klappen, Griffe, Schlitten, Räder, Lenkrollen),
  muss seinen ganzen Weg ohne Kollision schaffen, mit Platz für Finger und Werkzeug. Die Quelle sind die **Gelenke in
  model.py** mit `bereich=…` und `bedienung=…` (Kevin, 22.10.2026); `run` prüft sie bei jedem Lauf (Befunde
  „Bewegungsraum“ mit freiem Bereich). Was schon in der Ausgangslage im Gewinde greift, sperrt den Weg entlang bzw. um
  die Gewindeachse nicht (herausdrehen), quer dazu schon. Ein unveränderter Stand kommt aus dem Zwischenspeicher, bei
  Änderungen rechnen nur die betroffenen Gelenke neu. `<projekt>/bewegungen.json` gilt nur noch für Teile ohne Gelenk. Zum Ausloten
  weiter Bereiche einmalig `cd "<Repo>/kernel" && .venv/bin/python
  tools/check_motion.py "<Projektordner>" --teile … --drehen …`. Reicht der freie Bereich nicht für die Bedienung, wird
  umkonstruiert, nicht der Bereich verkleinert. Hat das Projekt eine Animation, zusätzlich `kollision_pruefen(name)`
  für jede Animation (siehe „Animation“).
- **Druckteile:** Die Druckprüfung läuft bei jedem Lauf für jedes `lager.druckteil` mit; `druckpruefung` zeigt
  Ausrichtung, Kennzahlen und alle Hinweise (siehe 3d-druck.md). Jedem Druckteil seinen Zweck geben
  (`lager.druckteil(…, zweck="tragend")`: zier, funktion, tragend, bewegt, aussen); `druckvorschau` sagt danach
  Filament, Zeit, Platten, Kosten und empfohlene Einstellungen (3d-druck.md, Abschnitt 16).
- Befestigung (`bed.verbinde`), Bewegungsraum, Schweben, Standsicherheit und Einbaubarkeit prüft Kev CAD bei jedem
  Lauf; `pruefen` zeigt das ganze Ergebnis, `montage_reihenfolge` die Einbaufolge.

## Montagegerecht konstruieren (Kevin, 21.10.2026, gilt immer)

Teile nicht irgendwo platzieren, sondern so, dass man sie vernünftig einbauen kann. Die Prüfung zerlegt jedes Modell
gedanklich (Montage durch Demontage): Ein Teil muss sich auf geradem Weg (±X, ±Y, ±Z, Achsen von Bohrungen und Bolzen,
erklärte Richtungen) aus dem Rest herausziehen lassen, dann das nächste. Umgekehrt ist das die Montagereihenfolge mit
Einführrichtung je Teil (`montage_reihenfolge`; Kevin sieht sie im Prüfband unter „Montage“ Schritt für Schritt).

- **Einbaulage mitdenken:** Jedes Teil so konstruieren und platzieren, wie es eingesetzt wird; Reihenfolge und
  Einführrichtung beim Konstruieren festlegen und im Kommentar nennen.
- **Schrauben:** nur entlang ihrer Achse einführbar (Durchgangsbohrung bis zum Kopf), und beim Einsetzen braucht das
  Werkzeug Platz über dem Kopf (Inbus: Ø Kopf + 2 mm, mindestens 30 mm bzw. 5·d lang; Steckschlüssel: Ø 1,6·SW + 4 mm;
  sonst Gabelschlüssel von der Seite). Fehlt der Platz: Durchgang für das Werkzeug, Schraube von der anderen Seite oder vor dem Hindernis einsetzen.
- **Spiel vorsehen**, damit Teile ohne Gewalt hineingehen (Druckteile 0,2–0,3 mm je Seite).
- **Keine eingesperrten Teile:** Ein Teil in einem geschlossenen Gehäuse ist nicht einbaubar; Gehäuse teilen (Deckel),
  Öffnung vorsehen.
- **Unlösbares vermeiden:** Bolzen mit zwei Köpfen aus einem Stück, Ringe auf Achsen ohne Ende, Klemmbolzen, deren
  Kopf und Zunge beide nicht durch die Bohrung passen: lösbar konstruieren (Achse als eigenes Teil, Sicherungsring,
  Teilung).
- **Zukaufteile** kommen fertig montiert: Alle gezeigten Teile derselben Zukauf-Instanz (eine Stücklistenzeile, etwa
  Rahmen und Lenkrollen aus `lager.zukauf("alutec-05200").verbauen("Rollwagen")`) sind automatisch eine Baugruppe.
  Erklärte und gelieferte Baugruppen zählen auch in der übergeordneten Gruppe als ein Körper.
- **Befunde beheben statt wegerklären.** Erklärungen nur, wo sie stimmen, und im Code kommentiert:
  `montage("Rollwagen/Lenkrolle 1", baugruppe=True)` für Teile, die fertig montiert geliefert werden;
  `montage(clip, schnappt=True)` für Schnappverbindungen; `montage(mutter, eingedruckt=True)` für Muttern, die beim
  Druck eingelegt werden (Druckpause); `montage(teil, richtung="-z", nach=[...], werkzeug="inbus 6")` für Richtung,
  Reihenfolge und Werkzeug eigener Teile.

## Teile über Bedingungen setzen (Kevin, 21.10.2026, gilt immer)

Wie in CAD-Programmen hängt jedes Teil über Bedingungen an seinem Gegenstück, nicht an frei gewählten Koordinaten.
Feste Regel neben Prüfungen, Druckregeln und Inventar-Regel: **Teile werden mit `platziere` gesetzt, jedes Teil ist mit
`verbinde` befestigt, Bewegliches ist ein Gelenk mit Bereich.** Kev CAD prüft alle Bedingungen nach jedem Lauf gegen
die echte Geometrie; verletzte sind Befunde wie eine Durchdringung (`run` isError, rot im Viewer, Export gesperrt).

```python
import kevcad.bedingungen as bed   # als Modul: kollidiert nicht mit eigenen Namen wie spiel, winkel, boden

platte = Box(200, 120, 10, align=(Align.CENTER, Align.CENTER, Align.MIN)) - Pos(60, 0, 5) * Cylinder(4.5, 20)
show(platte, "Halter/Platte")
klotz = Box(40, 30, 20)                                    # im eigenen System bauen, dann setzen
klotz = bed.platziere(klotz,
                      bed.auf((klotz, "unten"), (platte, "oben")),            # Fläche auf Fläche
                      bed.mittig((klotz, "mitte"), (platte, "mitte"), "xy"),   # mittig in X und Y
                      bed.parallel((klotz, "vorn"), (platte, "vorn")))        # nicht verdreht
show(klotz, "Halter/Klotz")
schraube = lager.teil("schraube-iso4762-m8").verbauen(laenge=25, name="Halter/Schraube")
schraube = bed.platziere(schraube, bed.in_bohrung(schraube, bed.bezug(platte, "bohrung", nahe=(60, 0, 0))))
show(schraube, "Halter/Schraube")
bed.verbinde(klotz, platte, art="kleben")                 # Befestigung (Pflicht für jedes Teil)
bed.verbinde(platte, bed.boden, art="aufliegen")
wand = param("wand", 2.0, min=1.2)                        # Grenzen: 0,8 ist ein Befund mit Soll, Ist und Lösung
```

- **Bezüge** über Namen, nie über Flächennummern: als Tupel `(teil, "unten")` oder `bed.bezug(teil, …)` mit
  `oben`/`unten` (±Z), `rechts`/`links` (±X), `hinten`/`vorn` (±Y, vorn = −Y), `mitte`, `schwerpunkt`, `achse`
  (größter Zylinder), `achse_x/y/z`, `bohrung` (mit `nahe=(x, y, z)`), `teil`; **Richtung einer Bohrung:** aus dem
  Loch heraus durch seine Öffnung (Sackloch), bei Durchgangsbohrungen in die positive Hauptrichtung (+Z, +X, +Y);
  `richtung="-x"` oder `(dx, dy, dz)` legt sie bei jedem Bezug mit Achse oder Normale fest, z. B.
  `bed.bezug(halter, "bohrung", nahe=p, richtung="+x")`. Gelenke zählen `bereich` und `weg` entlang der Richtung des
  **festen** (zweiten) Bezugs, also dort `richtung=` setzen, wenn + in eine bestimmte Richtung zeigen soll; eigene Auswahl
  `bed.bezug(teil, "Auflage", teil.faces().sort_by(Axis.Z)[0])` oder `lambda t: …`, dazu `Plane`, `Axis`, `Location`
  und Bezugspunkte aus dem Katalog; Teile auch über ihren Namen aus `show()` (`bed.verbinde("Gestell/Bein 1", …)`).
  `bed.boden` ist die Ebene z = 0. **Der erste Bezug gehört zum Teil, das sich anpasst** (bei `platziere` das bewegte).
- **Montage:** `auf` (Flächen gegenüber, `abstand=` für Luft), `buendig`, `konzentrisch`, `parallel`, `senkrecht`,
  `abstand(a, b, wert)`, `winkel(a, b, grad)`, `tangential` (Zylinder/Kugel an Ebene oder Zylinder), `mittig(…, "xy")`,
  `in_bohrung(schraube, bohrung, gewinde=False)` (konzentrisch, Kopf liegt auf, Durchmesser ISO 273 bzw. Kernloch und
  Länge geprüft). Teile im eigenen System bauen, mit `bed.platziere(teil, …)` setzen, danach erst bohren ist erlaubt
  (die Prüfung findet das Teil wieder); was danach noch verschoben wird, verschiebt seine Bezüge mit.
- **Gelenke** (Grundlage build123d-Joints, Freiheitsgrade für Animation und Prüfung): `drehgelenk(achse_bewegt,
  achse_fest, winkel=0, bereich=(min, max))`, `schiebegelenk(…, weg=0, bereich=…)`, `zylindergelenk`, `kugelgelenk`,
  `fest`. Mit `bereich` prüft jeder Lauf den ganzen Weg auf Kollision (`mitbewegt=[…]` für Teile, die mitfahren,
  `ignorieren=[…]`); Bedienteile mit `bedienung="finger" | "hand" | "werkzeug" | "fluegel"` oder `freiraum=mm` am
  `griff`. Hebel und Klappen prüfen den Freiraum am Griffpunkt über den Weg (finger 15, hand 25, werkzeug 10 mm). Teile,
  die um ihre eigene Achse gedreht werden (Flügelmutter, Flügelschraube, Drehknopf: `bedienung="fluegel"`, 10 mm; bei
  `"finger"`/`"hand"` ohne `griff` automatisch, wenn der Schwerpunkt auf der Drehachse liegt), prüfen den **Griffraum**:
  einen Ring um die Drehachse über der Auflage, bis Flügelspitze plus Freiraum, also nur auf der Griffseite. Beispiel:
  `bed.drehgelenk(achse("Flügelmutter M4"), achse("Gewindestift M4x30"), bereich=(0, 180), bedienung="fluegel")`.
  `gelenk.fuer_animation()` liefert Art, Achse und Grenzen für `animation.gelenk`.
- **Befestigung (B9):** jedes Teil `bed.verbinde(a, b, art="schraube" | "klemmung" | "steck" | "formschluss" |
  "kleben" | "aufliegen", mit=[schraube, mutter, scheibe])`. Geprüft wird, dass es die Verbindung wirklich gibt
  (Kontakt bzw. Spielpassung bis 0,5 mm; bei Schrauben fluchtende Bohrungen in beiden Teilen, Kopf und Mutter liegen
  auf) und dass alle Teile über Verbindungen am Boden hängen. Gelenke, `in_bohrung` und `auf` von oben zählen mit.
  In `mit=[…]` ordnet die Prüfung Schraube, Mutter, Scheibe und Gewindeeinsatz nach dem Lagerteil (`art`, `typ`) zu,
  sonst nach der Form: ein Ring mit Innenbohrung ist nie eine Schraube. Selbst gebaute Normteile deshalb mit
  `form.lagerteil = lager.teil("…")` kennzeichnen, wenn es sie im Katalog gibt. Zollgewinde (`1/4-20`, `3/8"-16 UNC`)
  gelten wie metrische.
  Kevin, 22.10.2026: Solange ein Modell kein `verbinde` nutzt, ist fehlende Befestigung nur ein Hinweis; sobald es
  `verbinde` nutzt, ist jede fehlende Angabe ein Fehler mit Exportsperre. Bei neuen Modellen gleich alles verbinden.
- **Bewegungen:** Die Gelenke in model.py sind die Quelle dafür, was sich wie bewegt (Bereich, Bedienung,
  mitbewegte Teile). `<projekt>/bewegungen.json` gilt nur noch für Teile ohne Gelenk; Einträge für Teile mit Gelenk
  werden übergangen (Kevin, 22.10.2026).
- **Maße:** `param(name, wert, min=, max=)`, `bed.gleich(a, b)`, `bed.spiel(deckel, gehaeuse, min=0.2)`,
  `bed.min_abstand(a, b, wert)`, `bed.min_wand(teil, 1.2)`.
- **Prüfen:** `run` meldet Befunde mit Soll, Ist, Zeile und Lösung; `bedingungen` zeigt alle Bedingungen, Freiheitsgrade
  je Teil (unterbestimmt = Hinweis), Widersprüche (Fehler mit den beteiligten Bedingungen), Befestigung und
  Bewegungsraum (`bedingungen(part="…", alle=true)` für ein Teil). Jeden Fehler beheben, bevor du fertig meldest; die
  Lösung steht im Befund. Beispiel mit Kevins Kugelschieber: `samples/kugelschieber-bedingungen/model.py`.

## 3D-Druckteile konstruieren (Kevin, 21.10.2026, immer beachten)

Drucker: Bambu Lab **P1P** (offen, ohne Gehäuse und Kammer; von Kevin am 21.10.2026 bestätigt), Bauraum
256 × 256 × 250 mm (vorne links 18 × 28 mm gesperrt), Düse 0,4 mm, Schicht 0,2 mm. Standardmaterial PLA oder PETG; ABS, ASA, PC und PA nur mit
Einhausung. Die Druckausrichtung beim Konstruieren
mitdenken und im Bericht nennen. Kurzfassung; das ganze Regelwerk mit Zahlen, Quellen und geprüften build123d-Rezepten
(Tropfenbohrung, Bettfase, Passungen, Gewindeeinsatz, Muttertasche, Opferschicht, Schnapphaken, Teilung) steht in
[3d-druck.md](3d-druck.md), vor jedem Druckteil lesen:

- **Wände** als Vielfache der Linienbreite (~0,42 mm): mindestens 1,2 mm, tragend 2–3 mm; Merkmale nicht unter 0,8 mm.
- **Überhänge** bis 45° ohne Stütze; Unterseiten fasen statt runden; Brücken höchstens ~15 mm.
- **Waagrechte Bohrungen** als Tropfenform (Spitze nach oben); Bohrungen drucken etwa 0,1–0,2 mm zu klein, Ø vorhalten.
- **Bettseite** mit Fase 0,4–0,6 mm gegen Elefantenfuß; eine ebene, große Auflagefläche einplanen.
- **Spiel** je Seite: Presspassung 0,1, Spielpassung 0,2, beweglich/Print-in-Place 0,3–0,5 mm.
- **Gewinde**: Gewindeeinsätze (Tasche nach Herstellermaß, z. B. M3 Ø 4,0–4,2 mm) oder eingeschlossene Muttern
  (Sechskant +0,2–0,3 mm, Einführschräge); Kernlöcher für Schrauben direkt ins Teil etwa 0,8 × d.
- **Gegenbohrungen und Senkungen**, die nach unten zeigen, mit Opferschicht (0,2 mm) drucken, sonst Stütze nötig.
- **Festigkeit**: Last längs der Schichten führen, nicht quer (Schichtfugen sind die Schwachstelle); Innenkanten
  verrunden; Schnapphaken in Schichtrichtung legen.
- **Verzug** bei ABS/ASA/PA: große ebene Flächen und spitze Ecken vermeiden, Ecken verrunden.
- **Z-Maße** möglichst als Vielfache von 0,2 mm; Schrift mindestens 0,6 mm erhaben, Strich ab 0,8 mm.
- **Größer als der Bauraum**: teilen, mit Passstiften oder Schwalbenschwanz und ebenen Fügeflächen.

**Druckprüfung bei jedem Lauf:** Jedes Teil aus `lager.druckteil(...)` prüft der Kernel nach jedem `run` automatisch
für den P1P (Prüfer „druck“ der gemeinsamen Prüfung, Befunde `druck_*` mit ids `dr1`, `dr2` …, Teil, Fläche
`Teil#f<n>`, Ort und Abhilfe). **Fehler** (Export gesperrt) nur aus harten Gründen: passt nicht in den Bauraum (samt
Sperrfläche vorne links), Harzdruck, Material nur mit gehärteter Düse (CF). Überhänge, Brücken, Auskragungen,
waagrechte Bohrungen, dünne Wände, Verzug sind **Warnungen** (beheben oder Kevin begründen), der Rest **Hinweise**
(abwägen). `run` nennt Fehler und Warnungen und je Druckteil die gewählte Ausrichtung mit Begründung;
**`druckpruefung`** (alle Teile) bzw. `druckpruefung(teil="…")` liefert die Einzelheiten: Ausrichtung, Fläche auf
dem Bett, Kennzahlen (Maße auf dem Bett, Schichten, Stützfläche, Auflage, Volumen), alle Hinweise mit Referenzen und
die Materialeinstellungen. Die Ausrichtung wählt die Prüfung selbst; muss die Hauptlast in die Schichtebene, mit
`lager.druckteil(form, name, material="petg", ausrichtung="-z")` vorgeben (`"+x"` usw. = diese Seite aufs Bett,
ebene Flächennummer, Vektor oder `Rot(...)`, bezogen auf die Form, wie sie an `druckteil` geht). Unveränderte Teile
kommen aus dem Zwischenspeicher; der Live-Aufbau wartet nie auf die Prüfung. Kevin die Ausrichtung neuer Druckteile
nennen.

## Statik (Kevin, 22.10.2026)

Nach jedem Lauf rechnet Kev CAD Lastszenarien: Eigengewicht, auf Rollen das Bremsen, eine Nutzlast aus einem
Parameter in kg und Kevins eigene aus model.py (`import kevcad.statik as st`, `st.szenario("…")`,
`st.last(teil, kg=30)` oder `kraft=(fx, fy, fz)` mit `punkt=`; drückt ein Teil gegen ein anderes, als Kraftpaar mit
`gegen="Teil"`, sonst kippt oder rutscht das Ganze scheinbar). Rahmen aus Lagerteilen rechnet es als Stabwerk
(Spannung, Durchbiegung, Knicken), belastete Halter und Druckteile als Kragträger (quer zur Schicht nur ein Teil der
Festigkeit), dazu Kippen je Richtung, Rutschen und Schraubenlast. Jedes Szenario bekommt eine Ampel gegen das Ziel
(statisch 2, dynamisch 3, Druckteile das Doppelte); rot und gelb sind Befunde `statik_*` (sperren den Export nicht).
Auf „hält das, wenn …?“ mit **`szenario_rechnen`** antworten (unter einer Sekunde, ohne neuen Lauf, im Viewer
gezeigt), Überblick mit **`statik`**. Vorschläge für leichtere oder stärkere Profile kommen nur aus dem Lager. Immer
die Grenzen dazusagen: vereinfacht (Balken, linear-elastisch, Verbinder starr), kein Ersatz für einen Statiker bei
sicherheitsrelevanten Dingen. Teile mit Last (Druckteile, Halter, Verbinder) rechnet Kev CAD zusätzlich als
Festkörper-FEM im Hintergrund; Einzelheiten mit **`festigkeit`** (Farbverlauf auf dem Netz, Sicherheit je Drucklage).
Rutscht die Klemmung, hebt etwas ab, fließt Metall oder beult ein Blech: **`festigkeit(…, verfahren="ccx")`**
(Stufe 4, CalculiX: Kontakt mit Klemmkraft, `plastisch=True`, Traglast, `beulen=True`; in model.py `st.kontakt`,
`st.festigkeit`). Einzelheiten, API und Urteile: [statik.md](statik.md).

Lager setzt `st.lager(teil, flaeche=…|punkt=…, art="fest"|"gelenkig"|"gleitend", szenario=…, gleiten=…)`
ausdrücklich (sonst aus den Kontakten abgeleitet): je Lastfall oder für alle, gleitend in der Fläche (genau senkrecht
gehalten) oder wie auf einer Schiene entlang einer Achse oder Kante, gelenkig in der FEM wie ein RBE3 (Fläche hält im
Mittel und dreht frei). Lastfälle, Kräfte und Lager, die Kevin im Bereich „Simulation“ (⌘4) per Klick anlegt, liegen in
`simulation.json` und gehören zu jedem Lauf: `statik` und `szenario_rechnen` sehen sie, **`simulation_liste`** zeigt
sie mit Zustand (nach Modelländerungen neu zugeordnet oder nicht mehr zuordenbar), **`simulation_aendern`** ändert sie
nur auf Kevins Wunsch (auch Lasten auf der ganzen Fläche, Druck in N/mm²), **`simulation_rechnen`** rechnet wie seine
Knöpfe (auch „Grenze suchen“: wie viel Last, wie steil, wie schnell; Last und Neigung wahlweise mit der FEM,
`verfahren="fem"`). Einzelheiten: [statik.md](statik.md), Abschnitte „Lager“ und „Lastfälle aus der App“.

Material sparen an einem Druckteil („mach den Halter leichter“, „Topologie optimieren wie implicit“): in model.py
**`topologie.optimieren(teil, szenario=…, behalten=0.4)`** hinter `lager.druckteil(…)` (oder MCP
**`topologie_optimieren`**, Ergebnis mit **`topologie_ergebnis`**). Rechnet im Hintergrund (etwa eine Minute), Lager
und Lasten aus der Statik, Bohrungen und Lastflächen bleiben massiv; danach Kennzahlen vorher → nachher (Volumen,
Filament, Druckzeit, Sicherheit) nennen und dazusagen: Näherung, kein Festigkeitsnachweis. Übernehmen als Variante
(`topologie_uebernehmen`) nur auf Kevins Wunsch. Einzelheiten: [statik.md](statik.md), Abschnitt „Topologie
optimieren“.

Bewegung über der Zeit (Stufe 2, MuJoCo im eigenen Prozess): „Was passiert, wenn ich mit 1 m/s schiebe und abrupt
bremse?“ → **`dynamik`**(name, geschwindigkeit=1, bremsen="abrupt"); „wie schnell darf ich schieben, ohne dass der
Ball herausspringt?“ → **`dynamik_grenze`**. Antwort mit Kippreserve, Abheben in mm, ob die Ladung bleibt (mit
Grenzgeschwindigkeit), Rutschgrenze, Handrechnung a = g·b/h und den Grenzen (Starrkörper, Reibung vereinfacht, keine
Verformung); Kevin sieht den Ablauf als Animation „Ablauf: …“ in der Zeitleiste.

## Arbeitsablauf

1. `status`: offenes Projekt, Pfad von model.py, letzter Lauf, Kevins Auswahl, Inventar-Regel.
2. Kein Projekt: `project_new("Wandhalter")` oder `project_open("Wandhalter")`. Ein bloßer Name landet in
   `~/Documents/Kev CAD/<Name>`.
3. Teile im Lager suchen: `stock_search("vierkantrohr 40x40x3")`, Materialien mit `material_list` (siehe
   Inventar-Regel).
4. model.py mit den eigenen Dateiwerkzeugen schreiben oder ändern (Pfad aus `status`). `model_write` nur, wenn es keine
   Dateiwerkzeuge gibt.
5. `run`: liefert jedes Teil mit Hüllmaß, Volumen und Masse und kurz die Summen der Stückliste. Ein Fehler kommt als
   isError mit Zeile, Auszug und Hinweis; die letzte gute Geometrie bleibt stehen. Korrigieren, wieder `run`. Bei
   größeren Änderungen mit `titel` (siehe „Versionen“).
6. Prüfen: Befunde der Prüfung aus `run` beheben (siehe „Prüfen vor dem Fertigmelden“; meldet `run` den Bewegungsraum
   als „wird im Hintergrund fertig gerechnet“, vorher `pruefen()` abwarten), Zahlen aus `run` mit der
   Aufgabe vergleichen, wichtige Sollmaße mit `measure` nachmessen, `bom` für Stückliste und Zuschnitt, `bedingungen` für
   Bedingungen, Freiheitsgrade, Befestigung und Bewegungsraum. Kevin keine
   Screenshots schicken; Bilder nur zur eigenen Analyse (siehe „Bilder“).
7. Meilenstein setzen (gilt immer): nach dem letzten erfolgreichen Lauf der Aufgabe
   `meilenstein("Kurzer Titel", "Ein, zwei Sätze, was sich geändert hat und warum")`, siehe „Versionen“.
8. Kevin kurz berichten: was gebaut ist, Hauptmaße, Masse, Kosten (Richtpreise), offene Annahmen. Bei Bedarf `focus`,
   `highlight`, `annotate` nutzen, damit er es im Viewer sieht.

Speichert Kevin model.py selbst und ist Auto-Lauf an, rechnet der Kernel von allein. `run` wartet dann auf diesen Lauf,
statt doppelt zu rechnen.

## Versionen (Kevin, 21.10.2026, gilt immer)

Kev CAD versioniert wie Onshape oder Fusion: Jeder erfolgreiche Lauf, der eine Projektdatei geändert hat, wird eine
Version V<n> (alle Projektdateien: model.py, Hilfsmodule, `geometrie/`, `bewegungen.json`, `katalog.json`,
`kevcad.json`, `zukauf/`; nicht `output/` und `bestand.json`). Kevin sieht sie in der Leiste „Versionen“ mit
Vorschaubild, Zeit, wer (Kevin oder Agent), Teilen, Masse, Kosten und Prüfstand.

- **Titel:** Jede Version bekommt automatisch einen Titel aus dem Inhalt der Änderung („breite 120 → 140“,
  „+ Flügelschraube M4 (4×)“, „Rahmen, Schlitten geändert“, „Code aufgeräumt (ohne Wirkung)“). Bei größeren
  Änderungen `run(titel="Laufrollen auf Kugellager umgestellt")` in Kevins Worten mitgeben: Das wird der Titel der
  Version, der automatische steht darunter. Kleine Korrekturen brauchen keinen.
- **Am Ende jeder Aufgabe ein Meilenstein:** `meilenstein(titel, notiz)` mit kurzem deutschem Titel
  („Stangenhalter mit Gewindeeinsätzen“) und einer Notiz in ein, zwei Sätzen. Erst nach dem letzten erfolgreichen
  Lauf, nicht auf einen kaputten Stand. Hat Kevin die Version selbst benannt, bleibt sein Name (`meilenstein`
  meldet das, dein Titel steht dann darunter); `ersetzen=true` nur, wenn Kevin ausdrücklich darum bittet.
- `versionen` zeigt die Geschichte; `versionen_vergleichen("V12")` vergleicht mit dem aktuellen Stand (Parameter,
  Teile, Stückliste, Prüfstand, Code) und zeigt Kevin die alte Geometrie als Geisterkörper im Viewer.
- `version_wiederherstellen("V12")` nur auf Kevins Wunsch. Es ist nie zerstörend: ungesicherte Änderungen werden
  vorher eine Version, der Rückweg ist ein weiteres Wiederherstellen.
- `variante(aktion="anlegen", name="Leichtbau")` für Ideen, die den Hauptstand nicht anfassen sollen; `variante(
  aktion="wechseln", name="Hauptstand")` zurück. Kein Zusammenführen: Kevin entscheidet, wo es weitergeht.
- Kein eigenes Git im Projektordner anlegen und `.kevcad/` nicht anfassen; die Versionen verwaltet Kev CAD.

## Inventar-Regel

Standard für jedes Projekt: **Gebaut wird nur aus dem Inventar.**

- Jedes Teil in `show()` stammt aus `lager.teil(...).verbauen(...)`, aus einem freigegebenen Zukaufteil
  (`lager.zukauf(...).verbauen(...)`, siehe „Zukaufteile“) oder ist ausdrücklich ein 3D-Druckteil:
  `lager.druckteil(form, "Halter/Schelle", material="petg")`. Druckmaterial muss freigegeben und druckbar sein
  (`material_list` zeigt „druckbar“: PLA, PETG, ABS, ASA, TPU 95A, PA, PA-CF, PC-Filament, PLA-CF, Standardharz);
  `verfahren="3d-druck"` (Standard) oder `"harzdruck"`.
- Materialien nur aus dem Katalog (id oder Alias), auch bei `show(material=...)`. Unbekannte oder nur vorgeschlagene
  Materialien brechen den Lauf mit Vorschlägen ab.
- Nichts erfinden. Fehlt ein Teil oder Material: erst `stock_search` mit anderen Wörtern, dann Kevin fragen. Nur auf
  seinen Wunsch mit `stock_define` bzw. `material_define` vorschlagen. Ein Vorschlag wartet auf Kevins Freigabe und
  lässt sich vorher nicht verbauen. **Freigabe anfragen:** `freigabe_anfragen(["id", …], grund="wofür")` öffnet im
  Projektfenster den Dialog „Vorschläge freigeben“ (Daten, Link, „Freigeben“ je Eintrag und für alle), wartet auf
  Kevins Klick (Standard 120 s) und meldet, was freigegeben, abgelehnt oder offen ist. Nie „bitte im Lagerkatalog
  freigeben“ schreiben. Schreibt Kevin im Chat „freigegeben“, ist damit nichts freigegeben: dann ebenfalls
  `freigabe_anfragen` aufrufen, er klickt nur noch. Das Werkzeug gibt nie selbst frei. Freigegebene Einträge ändert
  nur Kevin. Ist VoiceBridge verbunden, kann Kevin die Anfrage auch vom iPhone freigeben (sie geht direkt an ihn, am
  Agenten vorbei); der Agent gibt nie selbst frei und reicht keine Freigabe weiter.
- Verstöße: `run` meldet „Inventar-Regel: 2 Teile sind nicht aus dem Inventar: …“ als isError. Die Geometrie ist zu
  sehen, aber Export (STEP, STL, 3MF, Stückliste) wird verweigert. Passendes Lagerteil verbauen, als Druckteil
  kennzeichnen oder Kevin bitten, das Lagerteil anzulegen.
- **Kulisse** (Kevin, 22.10.2026): Umgebung nur für Bilder und Videos, die weder gekauft noch gebaut wird (gekachelter
  Boden, Wand, Tisch, Straße): `show(form, "Kulisse/Boden", color="#D9D6CF", kulisse=True)` oder
  `show(lager.kulisse(form, "Kulisse/Wand"), "Kulisse/Wand")`. Ausgenommen von Stückliste, Inventar-Regel (Material
  frei), Druckprüfung, Befestigung (`verbinde`) und Einbaubarkeit; weiter erfasst bei der Durchdringung (nichts steckt
  im Boden) und als Auflage: was auf einer Kulisse steht, steht auf dem Boden (Schweben, Standsicherheit). Namen unter
  „Kulisse/“, dann lässt sich die Gruppe im Viewer ausblenden; ohne Farbe kommt sie hellgrau. **Nur für Umgebung, nie
  für echte Teile des Entwurfs.**
- Abschalten kann nur Kevin, je Projekt (kevcad.json `"inventar_regel": false`, etwa für Nachbauten aus Fotos). Diese
  Einstellung nie selbst ändern. Ist die Regel aus, gelten auch Materialnamen aus build123d (`aluminum`, `oak`, …) und
  frei modellierte Teile mit Material erscheinen als „Eigenteil“.

## Gerüst von model.py

```python
from build123d import *
from kevcad import lager, param, show, step

hoehe = param("hoehe", 120)        # Länge der Grundplatte
abstand = param("abstand", 70)     # Wand bis Rohrmitte
loch = param("loch", 6.6)          # Durchgangsbohrung M6, mittel
schelle_h = param("schelle_h", 30)
wand = param("wand", 4)

flach = lager.teil("flach", b=40, s=5, material="stahl-s235")   # vorher mit stock_search gefunden
rohr = lager.teil("rohr-en10220-42.4x2.0")
blech, rohr_d = flach.masse["s"], rohr.masse["d"]

step("Grundplatte")
platte = Pos(0, blech / 2, -hoehe / 2) * flach.verbauen(laenge=hoehe, name="Halter/Grundplatte")
show(platte, "Halter/Grundplatte")

step("Bohrungen")
for z in (-40, 40):
    platte -= Pos(0, 0, z) * Rot(90, 0, 0) * Cylinder(loch / 2, 3 * blech)
show(platte, "Halter/Grundplatte")   # gleicher Name: ersetzt, man sieht das Teil wachsen; bleibt Lagerteil

step("Lasche")
ring_r = rohr_d / 2 + wand
lasche = flach.verbauen(laenge=abstand - ring_r - blech, name="Halter/Lasche")
show(Pos(0, blech, 0) * Rot(-90, 0, 0) * lasche, "Halter/Lasche")   # erst drehen, dann schieben

step("Schelle")
ring = Pos(0, abstand, 0) * (Cylinder(ring_r, schelle_h) - Cylinder(rohr_d / 2, schelle_h + 2))
show(lager.druckteil(ring, "Halter/Schelle", material="petg"), "Halter/Schelle")

step("Rohr")
show(Pos(0, abstand, -150) * rohr.verbauen(laenge=300, name="Rohr"), "Rohr")
```

## API von kevcad

| Aufruf | Wirkung |
|---|---|
| `param(name, wert, min=None, max=None)` | benannter Parameter (mm). Liefert den Vorgabewert oder den Wert aus `run(params={"breite": 140})`. Alle Parameter oben in der Datei. |
| `step("Bohrungen")` | Bauschritt, erscheint in Kevins Statusleiste. Vor jedem Schritt aufrufen. |
| `show(obj, name, color=None, material=None, kulisse=False)` | zeigt Part, Compound, Sketch, Kanten oder ein Builder-Ergebnis (`bp.part`) sofort an. Gleicher Name ersetzt. `/` im Namen bildet den Baum. `kulisse=True`: Umgebung (siehe „Inventar-Regel“, Kulisse). |
| `lager.kulisse(form, name=None)` | kennzeichnet eine Form als Kulisse (gleich wie `show(..., kulisse=True)`). |
| `lager.teil(id)` / `lager.teil(art, **maße, material=None)` | Lagerteil aus dem Katalog, genau passend, sonst Fehler mit Vorschlägen. |
| `lager.suche("rohr 42,4")` | Liste von Lagerteilen (zum Ausprobieren in `execute`). |
| `teil.verbauen(...)` | build123d-Teil mit Name, Farbe und Material, dazu eine Stücklistenzeile (siehe unten). |
| `lager.druckteil(form, name, material, verfahren="3d-druck", ausrichtung=None, zweck=None, anzahl=None, gedruckt=False, neu_drucken=False, spaeter=False)` | selbst konstruiertes Druckteil; Material druckbar; Druckprüfung bei jedem Lauf, `ausrichtung` gibt die Lage aufs Bett vor (None = automatisch); `zweck` (zier, funktion, tragend, bewegt, aussen) bestimmt die Empfehlungen der Druckvorschau, `anzahl` nur für zusätzliche Stück; `gedruckt=True` für schon gedruckte Teile (Form in gedruckt.json festgeschrieben, Änderung = Warnung `gedruckt_geaendert`, `neu_drucken=True` einen Lauf lang schreibt die neue Form fest); `spaeter=True` für Teile, die erst später gedruckt werden (in der Druckvorschau gelistet, auf keiner Platte, nicht im 3MF). Vor jedem Druck oder Druckexport Kevin nach dem Filament fragen (`filament_liste`, dann `druck_export(filament={"petg": "<id>"})`; 3d-druck.md Abschnitt 11a). |
| `topologie.optimieren(teil, szenario=None, behalten=0.4, schutz=None, ueberhang=False, fein=False, steg=6, bett=False, bohrungen=True, einsaetze=True, kontakt=True, iterationen=60, lager="kontakt", automatisch=True)` | topologieoptimiertes Druckteil (`from kevcad import topologie`): das Ergebnis aus `topologie/<teil>-<schlüssel>.brep`, solange es fehlt das Ausgangsteil (Rechnung im Hintergrund, danach neuer Lauf); Stückliste und Masse folgen dem neuen Volumen; `topologie.aus_datei(pfad, name, material)` verbaut eine gespeicherte Form als Druckteil; `lager="bohrungen"` für angeschraubte Halter (die Schrauben halten statt der Auflage). Siehe statik.md, „Topologie optimieren“. |
| `lager.zukauf(id)` → `.verbauen(name)`, `.bezugspunkt(name)` | Zukaufteil mit Hersteller-CAD, Skript oder Ersatzkörper (siehe „Zukaufteile“). |
| `erlaubt_ueberlappung(a, b, grund="…")` | gewollte Überlappung, nur nach Rückfrage bei Kevin (siehe „Prüfen vor dem Fertigmelden“). |
| `montage(teil, richtung=, nach=, werkzeug=, baugruppe=, schnappt=, eingedruckt=)` | Einbau erklären, wo die Prüfung es nicht selbst wissen kann (siehe „Montagegerecht konstruieren“). |
| `befestigt(teil, grund="…")`, `boden(z)` | an Wand/Decke befestigt (nur nach Rückfrage), Bodenebene. |
| `import kevcad.bedingungen as bed` | Bezüge, Bedingungen, Gelenke, Befestigung, `bed.platziere(teil, …)` (Abschnitt „Teile über Bedingungen setzen“). |

- `color`: Hex wie `"#B8BEC4"`; Lager- und Druckteile haben schon die Farbe ihres Materials.
- `material`: id oder Alias aus dem Katalog (`material_list`), z. B. `stahl-s235`, `edelstahl`, `alu`,
  `multiplex-birke`, `petg`. Lagerteile tragen ihr Material selbst, `material=` ist dort nicht nötig.
- Langsam aufbauen, wenn Kevin zuschauen soll: `run(slow_ms=400)`.

## Lagerteile verbauen

- Stangenware (Rohr, Vierkant-/Rechteckrohr, Flach-, Rund-, Vierkantstahl, Winkel, U-Profil, Nutprofil, Holz):
  `teil.verbauen(laenge=842, name="Gestell/Bein vorn links", gehrung=(0, 0))`. Das Teil liegt entlang +Z ab z = 0,
  der Querschnitt mittig. `laenge` ist das **Zuschnittmaß an der längsten Kante**. `gehrung=(anfang, ende)` in Grad um
  die lokale X-Achse: positiv lässt die Kante bei +Y lang (Rahmenleiste mit Außenkante bei +Y), negativ die bei -Y.
  `drehung=90` dreht den Querschnitt vorher um Z (Gehrung über die andere Seite). Querschnitte: Breite b in X,
  Höhe h bzw. Dicke s in Y; Winkel mit Schenkel a nach +Y und b nach +X; U-Profil nach +X offen.
- Platten: `platte.verbauen(breite=800, tiefe=600, name="Deckel")` in der XY-Ebene ab z = 0, mittig; oder
  `form=Rectangle(800, 600) - Circle(40)` (Skizze in XY).
- Schrauben: `schraube.verbauen(laenge=60, name="Schrauben/M8x60 1")` (bd_warehouse, Kopf auf z = 0, Schaft nach -Z,
  ohne Gewinde); Muttern und Scheiben ohne `laenge`.
- **Name in `show()` gleich wie in `verbauen()`.** Dann kennt die Stückliste das gezeigte Teil, auch nach Verschieben,
  Drehen oder Bohren. Gleiche Teile durchnummerieren: „Schrauben/M8x60 1“ … „8“.
- Rahmen mit Gehrung: Leiste mit `gehrung=(45, 45)` verbauen, erst um die eigene Achse drehen (lange Kante nach außen),
  dann hinlegen, dann schieben. Beispiel: `samples/gestell/model.py`.
- Jede `verbauen`-Zeile steht in der Stückliste, auch wenn das Teil später gebohrt wird. Gleiche Lagerteile mit
  gleicher Länge und Gehrung werden zusammengefasst.

## Stückliste

- `bom`: Positionen (Anzahl, Maße, Gehrung, Material, kg, €), Zuschnitt je Stangenware („Stange 1: 882 + 882 + … =
  5.394 mm, Rest 606 mm“, Sägeschnitt 3 mm, Verschnitt in %), Summen mit Richtpreis-Hinweis, Hinweise (etwa nicht
  zugeordnete Lagerteile). Verschnitt heißt wie in der App: Sägeschnitte und Reste unter dem Mindestrest, bezogen auf
  die verplante Länge bzw. Fläche; neue Reste zählen nicht (`verschnitt_definition: "2"`). `bom(format="csv")` liefert CSV, `export(["bom_csv"])` schreibt die Datei.
- Preise sind Richtwerte mit Stand; so auch an Kevin weitergeben.

## Bestand und Einkauf (Kevin, 21.10.2026)

Jedes Projekt hat seinen eigenen Bestand (`bestand.json` im Projektordner): ganze Stangen und Platten, Reste mit
Kennung (R-0001, P-0001) und Länge bzw. Maß, Stückgut wie Schrauben je Länge. Nichts gilt projektübergreifend.

- Der Zuschnitt nimmt nach jedem Lauf zuerst passende Reste, dann ganze Stangen bzw. Platten aus dem Bestand, dann
  zu kaufende (optimiert, mit Mindestrest und Sägeblatt). `bom` zeigt je Rest, Stange und Platte die Stücke und die
  neuen Reste, `bestand_liste` den Bestand.
- `einkaufsliste` liefert genau die Liste, die Kevin unter „Material › Einkaufsliste“ sieht und teilt (gleicher Text,
  gleiche CSV): Lagerware (was nach Resten und Bestand fehlt, Normteile zum Kaufen eingeschlossen), Zukaufteile (Link
  und Preis aus dem Katalog), Summe dieser beiden, dann „Normteile abzählen“ (gebraucht, aus Bestand, kaufen) und
  „Filament für Druckteile“ (aus der Druckvorschau, sonst Volumen × Dichte; nicht in der Summe).
- **Bestand nur nach Kevins Angabe eintragen** (`bestand_eintragen`, seine Worte in `grund`), nie schätzen oder
  erfinden; jede Änderung aus der Antwort an Kevin nennen. Zukaufteile, Kameras, Objektive und Kamerazubehör sind
  Stückgut: `bestand_eintragen("blackmagic-pocket-6k-pro", stueck=1, grund=…)`; was Kevin hat, fällt aus der
  Einkaufsliste („Zukaufteile aus dem Bestand“).
- **Filament** (Strang „Bestand Stufe 2“): Spulen je Material und Farbe mit Kennung S-0001, Gramm übrig, Gramm voll,
  Name, Hersteller, Ort: `bestand_eintragen(material="petg", gramm=640, spule="Bambu PETG Basic schwarz",
  grund=…)`; mehrere volle Spulen mit `anzahl`, ändern mit `kennung="S-0002", gramm=310`, entfernen mit
  `spulen_entfernen`; „kein Filament da“ mit `anzahl=0`. Sobald das Projekt Filament führt, stehen unter Lagerware die
  Spulen, die der Druckvorschau desselben Laufs fehlen (Fehlmenge auf ganze Spulen aufgerundet, Spulengröße aus dem
  Katalog `spule_g`, sonst 1 kg), mit Preis in der Summe. Farben kennt die Druckvorschau nicht: Bedarf und Bestand
  gelten je Material.
- **„Gedruckt“ nur auf Kevins ausdrücklichen Wunsch** (`gedruckt_buchen(grund, platten=…, spule=…)`): bucht das
  Filament der Druckvorschau ab, angebrochene Spulen zuerst bzw. die Spule, die Kevin nennt; was der Bestand nicht
  deckt, gilt als von gekauften Spulen gedruckt, deren Rest als neue Spule dazukommt. Jede Platte nur einmal je Lauf.
- **„Gebaut“ nur auf Kevins ausdrücklichen Wunsch** (`gebaut_buchen`): bucht verplante Reste, ganze Stangen und
  Stückgut ab, legt die neuen Reste an und bucht das Filament der noch nicht als gedruckt gebuchten Platten ab. Jede
  Buchung lässt sich mit `buchung_rueckgaengig` umkehren.
- **Einkaufsliste im Bericht nennen:** nach dem Bauen eines Modells die Positionen mit Summe aus `einkaufsliste`
  aufführen, oder ausdrücklich sagen, dass alles aus dem Bestand kommt.

## Zukaufteile

Fertig gekaufte Teile mit Hersteller und Nummer (Schubladenauszug, Scharnier, Rolle, Rollwagen). Sie zählen zum
Inventar, sobald Kevin sie freigegeben hat. Kameras, Objektive und Kamera-Zubehör: siehe „Kameras“.

```python
wagen = lager.zukauf("alutec-05200")          # nach id; sonst lager.zukauf(mpn="05200", hersteller="ALUTEC") oder gtin=
rw = wagen.verbauen("Rollwagen")              # Hersteller-CAD, Skript-Geometrie oder Ersatzkörper
show(Pos(0, y, 0) * rw, "Rollwagen")          # gleicher Name wie in verbauen
oben = wagen.bezugspunkt("oben")              # Location im System des verbauten Teils
show(Pos(0, y, 0) * oben * ball, "Ball")      # auf die Ladefläche gesetzt
```

- Das verbaute Teil liegt mit seinem **Einbaupunkt** im Ursprung (Standard: Mitte der Unterseite, Z oben).
  Bezugspunkte (`bezugspunkte` im Katalog) gelten im selben System; Lage daraus ableiten statt Zahlen abzuschreiben.
- Hersteller-CAD mit Baugruppe erscheint als Baum („Rollwagen/Platte“, „Rollwagen/Rolle_1“). Ohne Modell ist es ein
  **Ersatzkörper** (Quader oder Zylinder aus den Shop-Maßen), halbtransparent und mit „(vereinfacht)“ im Namen.
  **Vereinfachte Teile im Bericht an Kevin immer nennen.**
- Die Prüfung behandelt Zukaufteile wie alle Teile: Hersteller-CAD und Ersatzkörper dürfen nichts durchdringen.
  Überlappt ein Zukaufteil sein Gegenstück nur, weil das Modell vereinfacht ist (Gewinde als Vollzylinder,
  Ersatzquader), ist das trotzdem ein Befund: im Modell lösen oder `erlaubt_ueberlappung(…, grund=…)` erst nach
  Rückfrage bei Kevin.
- Skript-Geometrie (`cad.quelle: "skript"` mit `datei`/`modul` und `funktion`): `verbauen(name, **kwargs)` reicht
  Schlüsselwörter an die Funktion weiter.

Ablauf, wenn Kevin einen Link, eine Herstellernummer oder eine EAN nennt:

1. **Seite selbst lesen** (Browser oder WebFetch). Kev CAD lädt keine Shop-Seiten und umgeht keinen Bot-Schutz. Bei
   einer EAN erst den Artikel suchen.
2. **Normteil?** „ISO 4762 M6×20“, „DIN 934 M8“: kein Zukaufteil, sondern `stock_search` und `lager.teil(...)`
   (`zukauf_anlegen` leitet selbst um).
3. **Anlegen:** HTML an `zukauf_html(url, html)` (wertet JSON-LD, Microdata und Open Graph aus) oder die gelesenen
   Felder an `zukauf_anlegen(url, felder={name, hersteller, mpn, gtin, preis {je_stueck, waehrung, brutto}, masse {l,
   b, h} bzw. {d, l}, gewicht, bild})`. Preis immer mit brutto/netto wie im Shop. Kevin Hersteller, Nummer, Preis und
   Maße bestätigen lassen (`zu_pruefen` in der Antwort). Das Teil ist ein **Vorschlag**, bis Kevin es freigibt
   (`freigabe_anfragen([id], grund)` öffnet den Dialog im Projektfenster); vorher lässt es sich nicht verbauen.
4. **CAD suchen:** `cad_suchen(id)` liefert Links (Produktseite, Herstellerportal, 3Dfindit, Websuche); eine
   automatische CAD-Quelle gibt es nicht (TraceParts ist seit dem 22.10.2026 stillgelegt, Kevins Entscheidung):
   **Kevin bitten, das STEP (oder ein ZIP mit STEP) mit seinem Konto herunterzuladen.** Die App beobachtet derweil
   `~/Downloads` und fragt ihn selbst.
5. **Übernehmen:** `cad_uebernehmen(id)` ohne Pfad nimmt die neueste passende Datei aus `~/Downloads` (auch aus ZIP).
   Zoll, Zentimeter und „Y oben“ werden erkannt und korrigiert (steht im Ergebnis); passt das Hüllmaß nicht zu den
   Katalogmaßen, wird abgelehnt (falsche Datei? Maße prüfen; `erzwingen=True` nur nach Rückfrage). Die Datei liegt
   danach in `<projekt>/zukauf/<id>/` (nie im Git, Herstellerbedingungen).
6. `run`, prüfen wie immer, `bom` zeigt das Teil mit Hersteller, Nummer, Stückpreis mit Datum, Link und CAD-Quelle.

`zukauf_liste` zeigt alle Zukaufteile mit Freigabe und CAD-Stand. Die Summe der Stückliste mischt Richtpreise (netto)
und Shoppreise (oft brutto); die Stückliste sagt das dazu, so auch an Kevin weitergeben.

## Kameras

Kameras wie am Set: Gehäuse, Objektiv und Aufnahmeformat aus dem Katalog (`kamera_katalog`), gesetzt in model.py.
Beispiel: `samples/kamerawagen/model.py`; Felder in KATALOG.md, Abschnitt „Kameras und Objektive“.

```python
fx6 = lager.kamera("sony-fx6", objektiv="sigma-ff-hs-35-t1.5-e", format="ff-uhd", blende=2.8, fokus=1500,
                   name="FX6")                              # format: ff-uhd, ff-dci, ff-hd, ff-uhd-120, s35-hd
fx6.setzen((0, -400, 180), blick_auf=(800, 0, 108))         # Sensormitte, Blick auf einen Punkt (Fokus = Abstand)
fx6.an("Rollwagen/Deckel", punkt=(150, 0, 40), richtung=(1, 0, 0), bezug="stativ_1_4", lokal=True)  # folgt dem Teil
show(fx6.koerper(), "Kamera FX6")                           # Gehäuse und Objektiv, zählt als Inventar
platte = lager.kamerazubehoer("tilta-es-t20-qrbp")          # Rig-Teile mit Bezugspunkten
show(platte.verbauen("Rig/Baseplate", an=fx6.bezugspunkt("stativ_1_4"), bezug="kamera_1_4"), "Rig/Baseplate")
```

- `bezug` ist ein Bezugspunkt der Kamera, der an der angegebenen Stelle liegt. Gültig sind genau diese Namen:
  `sensor`, `bajonett`, `front_unten`, `stativ_1_4`, `stativ_3_8`, `akkuschacht`, dazu eingebaut `auge` und `front`
  (`fx6.bezugspunkte()` listet sie). Andere Schreibweisen wie `gewinde_14` oder `gewinde_38` gibt es nicht.
  `richtung` oder `blick_auf` geben den Blick, `roll` kippt (Grad). Brennweite bei Zooms innerhalb des Bereichs,
  Blende nicht offener als die Lichtstärke (Fehler mit Erklärung), `fokus` in mm ab Sensorebene oder `"unendlich"`.
  Der Lauf meldet Bildwinkel, Schärfe von–bis und Warnungen (Naheinstellgrenze, Vignettierung bei Super-35-Objektiven
  an Vollformat).
- `an(teil, …, lokal=True)` nach dem `show` des Teils aufrufen; die Kamera wandert dann mit dem Teil, auch in
  Animationen (siehe „Kamera und Animation“). An ein Teil hängen, nicht an eine Baugruppe. Kamera setzen, nicht
  `Pos(...) * fx6.koerper()` verschieben.
- Werkzeuge: `kamera_liste`, `kamera_info(name)` (alle Werte), `kamera_ansicht(name)` bzw. `"aus"` (Viewer schaut
  durch die Kamera, mit Formatrahmen und Sicherheitsbereichen), `kamera_bild(name, breite)` speichert ein PNG unter
  output/kameras/ und nennt nur den Pfad (Bild nur mit `bild_zeigen=true`, wenn Kevin es hier sehen will),
  `kamera_vorschlag_aus_ansicht(name)` liefert die setzen-Zeile für Kevins aktuelle Ansicht (in der App Strg+Alt+0).
- Kevin: Taste 0 schaut durch die gewählte Kamera, noch einmal 0 zurück; Kameras stehen im Teilebaum unter „Kameras“.
- Kevins Kamera ist die FX6 (Tilta-Käfig ES-T20). Objektive, Akkus und Platten im Katalog sind Beispiele, bis Kevin
  seine nennt; fehlt etwas, fragen und erst auf seinen Wunsch per `stock_define` vorschlagen.

## Referenzen aus Video und Fotos (Phase 4)

Kevin gibt ein Handyvideo oder einige Fotos des echten Gegenstands. Daraus entstehen ein maßstäbliches Referenznetz
(Apple Object Capture) und die gemessenen `param()`-Werte des Modells (fotomess), beides in
`<projekt>/referenzen/<name>/`. Beispiel mit Messmodell: `samples/scarlett/model.py`.

1. `referenz_video(pfad, masz={"laenge": 180}, auflage=True)` startet Object Capture im Hintergrund (rund 1 min);
   `referenzen(name, warten_s=300)` wartet. Ein echtes Maß ist Pflicht für den Maßstab (`laenge` = längste waagrechte
   Ausdehnung, sonst `breite`, `hoehe`, `grund_laenge`, `grund_breite`); `auflage=True`, wenn der Gegenstand auf einer
   Scheibe oder einem Tisch liegt; `von`/`bis` (s) schneiden das Video zu (etwa vor dem Umdrehen). Das Ergebnis nennt
   Hülle mit Anbauten und Grundkörper ohne Anbauten getrennt. Object Capture ist nicht deterministisch; misslingt die
   Freistellung, rechnet der Kernel selbst bis zu dreimal.
2. model.py als Messmodell bauen: ein Teil je sichtbarem Bauteil, Maße als `param()`, Teile, die sich nicht messen
   lassen (Unterseite, Füße), fest. Gemessen wird nur, was die Bilder zeigen; ein Modellfehler (falscher Rand,
   fehlender Knopf) verfälscht die Maße – die Kontrollbilder zeigen ihn (rote Punkte ohne Partner).
3. Optional `messmodell()` in model.py (wird nur zum Vermessen gelesen):

```python
def messmodell(p):                       # p: alle param()-Werte des Grundstands
    return dict(
        frei=["tiefe", "hoehe", "kanten_r"],            # zu messen
        bekannt={"breite": 180.0},                      # fest, gibt den Maßstab (von Hand gemessen)
        farbteile=lambda teil, flaeche: teil == "Gehaeuse",   # oder ["Gehaeuse"]: Flächen in der Objektfarbe
        zwillinge=["z180"],                             # vorn und hinten sehen gleich aus
        maske=dict(maske="vision+farbe", farbe_hsv=[[168, 4], 70, 25],   # Objektfarbe (OpenCV-HSV, über 0 hinweg)
                   ausschluss_hsv=[[6, 24], 50, 45], gehaeuse=True),     # Farbe der Unterlage, Blenden einfassen
        vorgaben={"tiefe": (110, 25)}, grenzen={"tiefe": (80, 130)},     # weich (Mittel, Sigma) und hart (mm)
        hoehen=[0, 80],                                 # Grobsuche: Kamerahöhen (Grad); kopfueber=True bei Unterseite
    )
```

4. `referenz_vermessen(quelle, freie_masse=None, bekannte_masse=None, bilder=8)` (ohne Angaben aus `messmodell()`):
   rund 1 min, Ergebnis Maße mit Sigma, Hülle und Grundkörper des eingepassten Modells, Hinweise (welches Maß von Hand
   nachmessen, welche Zusatzaufnahme). Liegt Object Capture zum selben Video vor, erkennt der Kernel Bilder, in denen
   das Modell gedreht liegt (Zwillingslage), rechnet sie neu und legt das Netz genau an das Modell an.
5. Prüfen: `referenz_fotoansicht(name, foto=n, bild_zeigen=true)` für dich selbst (nie an Kevin schicken), sonst die
   Kontrollbilder aus dem Ergebnis. Stimmen vorn und hinten nicht, Modell oder Messmodell korrigieren und neu messen;
   Bilder ohne Object-Capture-Kamera nennt das Ergebnis eigens.
6. Werte nicht selbst in model.py schreiben: Kevin übernimmt sie in der App mit „Maße übernehmen“ (auf 0,1 mm). Nur
   wenn er es ausdrücklich sagt, die `param()`-Werte selbst ändern. Unsicherheiten ehrlich nennen (Sigma) und das
   empfohlene Nachmessen vorschlagen.
7. **Abweichung:** `referenz_abweichung(name, zeigen=False, auf="modell")` nennt je Teil die mittlere, die 95-%- und
   die größte Abweichung zum Referenznetz, den Versatz mit Vorzeichen (**positiv = der echte Gegenstand ragt über das
   Modell hinaus, das Modell ist dort zu klein**; negativ = Modell zu groß) und den abgedeckten Anteil (Stellen ohne
   Referenz in der Nähe, etwa die Unterseite eines Scans, zählen nicht). Der Kernel rechnet sie nach jedem Lauf im
   Hintergrund (rund 1 s); `referenzen(name)` zeigt die Kurzfassung. Sinnvoll erst, wenn das Netz am Modell anliegt
   (nach `referenz_vermessen`), sonst steckt der Lagefehler mit drin (das Ergebnis sagt es). `zeigen=true` schaltet
   bei Kevin die Farbkarte ein (blau Modell zu groß, grün passt, rot Modell zu klein, grau ohne Referenz, Legende in
   mm), `auf="referenz"` färbt stattdessen das Netz; `skala_mm` legt die Legende fest, 0 wieder automatisch. Nutze die
   Zahlen, um gezielt nachzubessern (größte Abweichung mit Ort), und nenne Kevin die Teile mit großer Abweichung.
8. **Maßstab nachträglich:** Hatte das Video kein oder ein falsches Maß, `referenz_massstab(mm, name, punkte=[[x, y, z],
   [x, y, z]])` mit zwei Punkten am Netz (Weltkoordinaten wie im Viewer, werden aufs Netz gezogen) oder
   `kante="laenge"` (Hülle: `laenge`, `breite`, `hoehe`, `grund_laenge`, `grund_breite`) bzw. dem Namen eines
   gemessenen `param`. Netz, Punktwolke, Kameras von Object Capture und Bericht skalieren mit, die Vermessung nur bei
   einem gemessenen `param` (dann gilt es beim nächsten Vermessen als bekannt). Scans vom iPhone sind metrisch und
   werden nicht skaliert. Kevin macht dasselbe in der App mit „Maßstab …“ (zwei Punkte anklicken, Maß eintragen).

- Kevin: Video oder Fotos auf das Fenster ziehen öffnet „Referenz hinzufügen“ (bekanntes Maß, Unterlage, Abschnitt);
  im Inspektor unter „Referenzen“ Netz mit Deckkraft, „Abweichung“ (Farbkarte auf Modell oder Netz, Legende in mm
  unten links im Viewer), „Maßstab …“, „Fotoansicht“ (Foto durch die eingepasste Kamera hinter dem Modell, Differenz
  rot nur Foto, blau nur Modell), „Vermessen …“ und „Maße übernehmen“.
- macOS fragt beim ersten Zugriff auf Downloads oder ein Wechselmedium, ob Kev CAD darf; bis Kevin antwortet, bricht
  `referenz_video` mit einer Meldung ab. Dann Kevin bitten zu erlauben oder die Datei ins Projekt zu legen.

## Scan mit dem iPhone (Kev Scan)

Kevins iPhone-App Kev Scan nimmt LiDAR-Tiefe, ARKit-Kameralagen, Video und hochaufgelöste Fotos auf und schickt den
Scan per WLAN an Kev CAD (Bonjour, Ablage `~/Documents/Kev CAD/Scans/<datum>_<name>/`, Vertrag SCAN.md). Gegenüber
`referenz_video` sind die Kameras bekannt und der Scan ist metrisch: kein bekanntes Maß nötig.

1. `scans` zeigt die empfangenen Scans (Kennung, Fotos, Videobilder, ob eine Box gesetzt ist, wohin übernommen).
2. `scan_importieren(scan, name=None, schnell=False, warten_s=600)`: wertet im Hintergrund aus (alle Fotos plus
   Videobilder nach Abstand und Winkel, Prompt Depth Anything mit der LiDAR-Tiefe als Prompt, TSDF etwa 2 mm, größte
   Komponente; Boden z = 0, Mitte x = y = 0, lange Seite = X) und legt eine Referenz an, Netz halbdurchsichtig im
   Viewer. `schnell=True` (kleines Modell, weniger Bilder) als Vorschau in ein bis zwei Minuten; genau braucht etwa
   2 s je Bild (typisch 2 bis 4 min). Ohne WLAN: ZIP per AirDrop, dann
   `scan_importieren("/Users/…/Downloads/x.kevscan.zip")`.
3. Messmodell bauen wie bei Phase 4, dann `referenz_vermessen(name, freie_masse=[…])`: fotomess nimmt die
   ARKit-Kameras als feste Startwerte (nur fein nachgeführt), passt die Modellkanten an die Bilder und das Modell an die
   gemessene Tiefe (robust, nach Konfidenz gewichtet) und legt das Netz an das Modell. `bekannte_masse` sind nicht
   nötig; wenn Kevin ein Maß sicher kennt, darf es trotzdem fest sein.
4. Ergebnis wie bei Phase 4 prüfen (Kontrollbilder, Sigma, `referenz_abweichung`) und Kevin „Maße übernehmen“
   lassen.

In der App: Ein neu empfangener Scan erscheint als Band „Neuer Scan empfangen: <Name>“ mit „Scan übernehmen“
(Schnell oder Genau) ins offene Projekt, dasselbe wie `scan_importieren`; im Inspektor unter „Referenzen“ steht die
Liste der Scans, die laufende Auswertung zeigt „Scan wird ausgewertet …“ mit Phase und Fortschritt.

Ehrliche Grenzen: LiDAR misst nur bis etwa 5 m und schlecht auf Glas, Spiegeln, sehr dunklen und glänzenden Flächen;
dort fehlt Tiefe (Konfidenz 0) und das Netz hat Löcher. Dünne Teile unter etwa 5 mm (Kabel, Bleche von der Kante)
fallen in der TSDF weg. Lagen von ARKit driften bei langen Aufnahmen um einige Millimeter; das Nachführen in fotomess
fängt das bei den Maßen ab, das Netz selbst bleibt so genau wie die Aufnahme. Die Unterseite fehlt immer. Bewegliche
Teile (Deckel, Räder) müssen während der Aufnahme stillstehen.

## build123d: Kurzreferenz und Fallen

**Algebra-Modus bevorzugen** (Objekte und Operatoren). Builder (`with BuildPart() as bp:`) nur, wo er klar hilft, etwa
für Bohrungen auf einer Fläche. Ergebnis eines Builders ist `bp.part`, nicht `bp`.

- **Ausrichtung:** `Box`, `Cylinder` und `Sphere` sind standardmäßig um den Ursprung **zentriert** (eine Box der Höhe 10
  reicht von z = −5 bis +5). Auf die XY-Ebene stellen: `align=(Align.CENTER, Align.CENTER, Align.MIN)`.
- **Lage:** `Pos(x, y, z) * teil` verschiebt, `Rot(x, y, z) * teil` dreht in Grad um den Ursprung. Gelesen wird von
  rechts nach links: `Pos(100, 0, 0) * Rot(0, 0, 90) * teil` dreht erst und schiebt dann. Andersherum kreist das Teil um
  den Ursprung. `Rot(90, 0, 0)` legt die Z-Achse eines Zylinders auf −Y.
- **Boolesch:** `a + b` vereinigen, `a - b` abziehen, `a & b` Schnittmenge. Listen gehen auch: `platte -= [Pos(x, 0, 0)
  * zyl for x in xs]` oder `platte -= GridLocations(40, 20, 2, 2) * Cylinder(3, 10)`.
- **Werkzeugkörper überstehen lassen:** Durchgangsbohrungen und Schlitze länger als das Material machen (z. B.
  `dicke + 2`, um 1 nach unten versetzt). Genau bündige Flächen hinterlassen sonst Häute oder kaputte Flächen.
  Beim Vereinigen gilt dasselbe: Teile leicht überlappen lassen, nicht nur berühren.
- **Kanten und Flächen wählen:**
  - `teil.edges().filter_by(Axis.Z)`: Kanten parallel zu Z (senkrechte Ecken)
  - `teil.edges().group_by(Axis.Z)[-1]`: oberste Kanten, `[0]` unterste
  - `teil.faces().sort_by(Axis.Z)[-1]`: oberste Fläche
  - `teil.edges().filter_by(GeomType.CIRCLE)`: Kreiskanten (Bohrungsränder)
  - `teil.edges().filter_by(Axis.Z).group_by(SortBy.DISTANCE)[-1]`: nur die äußersten senkrechten Kanten
  - Kurzformen: `|` = filter_by, `>` = sort_by, `>>` = group_by(...)[-1], `<<` = group_by(...)[0]
- **Fillet und Fase:** `teil = fillet(kanten, radius=4)` und `teil = chamfer(kanten, length=1)`. Das Ergebnis neu
  zuweisen. Der Radius muss kleiner sein als die halbe Wandstärke dort. `filter_by(Axis.Z)` erfasst nach dem Bohren
  auch die Nahtkanten der Bohrungen; deshalb Ecken vor dem Bohren runden oder die Auswahl eingrenzen. Scheitert ein
  Fillet („command not done“), ist meist der Radius zu groß oder die Auswahl zu breit.
- **Skizzen:** `extrude(Plane.XY.offset(10) * (Rectangle(40, 20) - Circle(5)), amount=5)`,
  `revolve(Plane.XZ * Pos(20, 0) * Rectangle(4, 10), Axis.Z)`, `mirror(teil, about=Plane.YZ)`,
  `Text("KEV", font_size=10)`.
- **Bohrungen im Builder** (Bohrung geht von der gewählten Fläche ins Material):

  ```python
  with BuildPart() as bp:
      Box(60, 40, 10)
      with Locations(bp.faces().sort_by(Axis.Z)[-1]):
          with GridLocations(40, 20, 2, 2):
              CounterBoreHole(radius=3.3, counter_bore_radius=5.5, counter_bore_depth=6.4)
  show(bp.part, "Deckel")
  ```

  `Hole(radius)`, `CounterBoreHole(...)` und `CounterSinkHole(radius, counter_sink_radius, counter_sink_angle=90)` gehen
  nur im Builder. **Falle:** `CounterSinkHole` nimmt standardmäßig 82° (Zoll-Norm). Metrische Senkschrauben brauchen
  `counter_sink_angle=90`.

### Löcher für Schrauben (Durchmesser in mm)

| Gewinde | Durchgang mittel (ISO 273) | Kernloch für Gewinde | Senkung Zylinderkopf ISO 4762 (Ø × Tiefe) | Senkung 90° ISO 10642 (Ø) |
|---|---|---|---|---|
| M3 | 3,4 | 2,5 | 6,5 × 3,4 | 6,7 |
| M4 | 4,5 | 3,3 | 8 × 4,4 | 9,0 |
| M5 | 5,5 | 4,2 | 10 × 5,4 | 11,2 |
| M6 | 6,6 | 5,0 | 11 × 6,4 | 13,4 |
| M8 | 9,0 | 6,8 | 15 × 8,6 | 17,9 |
| M10 | 11,0 | 8,5 | 18 × 10,6 | 22,4 |

Zollgewinde (ASME B1.1; Kernloch 75 % und Durchgang „free fit“ der üblichen Bohrtabelle), Größe im Lagerteil z. B.
`"1/4-20"`, `"3/8-16 UNC"`, `"#10-24"`:

| Gewinde | Nenn-Ø | Steigung | Kernloch | Durchgang |
|---|---|---|---|---|
| #10-24 UNC | 4,83 | 1,06 | 3,8 | 5,1 |
| 1/4"-20 UNC (Kamera, Stativ) | 6,35 | 1,27 | 5,1 | 6,8 |
| 5/16"-18 UNC | 7,94 | 1,41 | 6,5 | 8,4 |
| 3/8"-16 UNC (Stativkopf) | 9,53 | 1,59 | 7,9 | 10,1 |
| 1/2"-13 UNC | 12,7 | 1,95 | 10,7 | 13,5 |

Für den 3D-Druck Löcher 0,2 bis 0,3 mm größer und Passungen mit Spiel. Rohrmaße sind Außendurchmesser (42,4 mm =
DN 32, 1¼ Zoll).

## Benennung und Baugruppen

- Jedes echte Teil bekommt einen sprechenden deutschen Namen: „Grundplatte“, „Lasche“, „Schelle“.
- Baugruppen über `/`: „Halter/Grundplatte“, „Halter/Schelle“. Gleiche Teile nummerieren: „Schrauben/M6x20 1“.
- Ein Teil nach jedem Bauschritt mit demselben Namen erneut zeigen. So sieht Kevin es wachsen.
- Hilfsgeometrie (Werkzeugkörper, Schnittkörper) nicht zeigen.
- Lagerteile und Druckteile tragen Material, Farbe und Masse; die Masse steht in `run`, `parts` und `measure`.

## Referenzen und Auswahl

- `Halter/Lasche` ist das Teil, `Halter/Lasche#f3` Fläche 3, `#e2` Kante 2, `#v1` Punkt 1. Die Nummer folgt
  `teil.faces()`, `teil.edges()` und `teil.vertices()` des zuletzt gezeigten Objekts.
- Referenzen gelten **nur für einen Lauf**. Nach jedem `run` neu holen, nie alte Nummern wiederverwenden.
- Flächennummer finden: `execute("[(i, f.geom_type.name, round(f.area, 1), f.center()) for i, f in
  enumerate(platte.faces())]")` mit der Variablen des gezeigten Teils.
- Sagt Kevin „diese Bohrung“, „hier“ oder „das da“: zuerst `selection`. Sie liefert seine angeklickten Referenzen samt
  Werten (Typ, Fläche, Radius).

## Messen

- `measure(["Grundplatte#f3"])`: Eigenschaften eines Elements (Fläche, Normale, Radius, Länge, Lage, beim Teil Hüllmaß,
  Volumen, Masse).
- `measure(["Lasche#f2", "Grundplatte#f0"])`: kleinster Abstand mit dx, dy, dz und beiden Punkten, Winkel, Abstand
  paralleler Flächen. Zwei Bohrungswände (Zylinderflächen) ergeben den Achsabstand.
- `show=True` (Standard) blendet das Maß im Viewer ein. Werte stimmen exakt (OCCT), nicht aus dem Bild schätzen.
- Rechnungen und Abfragen im Modell mit `execute` (z. B. `platte.volume`, `schelle.bounding_box()`), ohne model.py zu
  ändern.

## Kevin etwas zeigen

| Werkzeug | Zweck |
|---|---|
| `focus(["Halter/Lasche"])` | Kamera fährt hin (animiert) |
| `highlight(refs, color="orange", label="M6")` | einfärben, beschriften; `clear=True` entfernt alte |
| `annotate("dimension", [[x,y,z],[x,y,z]])` | Maßlinie (Text = Abstand, wenn leer); auch `arrow`, `label` |
| `clear_annotations()` | alle Anmerkungen weg (oder `ids=[...]`) |
| `visibility("isolate", ["Halter/Lasche"])` | nur diese Teile; `show_all` stellt alles wieder her |
| `section(True, axis="y", offset=0)` | Schnitt; `section(False)` hebt ihn auf |
| `view(standard="front", projection="orthographic", fit=True)` | Standardansicht, Darstellung (`xray`, `wireframe`), `explode=0.6` |

„Zoom auf die Lasche und zeig sie von der Seite“: `view(standard="right", projection="orthographic")`, dann
`focus(["Halter/Lasche"])`. Kevin sieht das Ergebnis selbst im Viewer.

## Bilder

Kevin keine Screenshots schicken, außer er will ausdrücklich ein Bild: Er sieht den Viewer beim Arbeiten selbst, und
jedes Bild hält die Generierung auf.

Zur eigenen Analyse sind Bilder aus mehreren Blickwinkeln ausdrücklich erlaubt, wenn sie zu einer besseren Entscheidung
führen (Kevin, 21.10.2026): Durchdringungen und Einbaubarkeit beurteilen, Proportionen und Lage prüfen, mit
Referenzfotos vergleichen. Dann gezielt: wenige Offscreen-Ansichten in kleiner Auflösung in einem Zug (etwa iso, vorn,
rechts, oben), nicht nach jedem Schritt. Erste Quelle bleiben die Zahlen aus `run`, `parts`, `measure` und der Prüfung.

- `ansichten()` liefert mehrere Offscreen-Ansichten in einem Aufruf (Standard iso, vorn, rechts, oben, 640 × 400),
  frei wählbare Blickrichtungen (`richtungen=[[1, 1, -1]]`), auf Teile (`ziel`) oder einen Punkt (`punkt`, `radius`)
  eingepasst, mit Röntgen (`darstellung="xray"`) für verdeckte Teile, rot hervorgehobenen Teilen und den roten
  Schnittkörpern der Prüfung. Kevins Kamera und Darstellung bleiben unverändert.
- `pruefen(bilder=True)` zeigt die schlimmsten Befunde aus zwei, drei Richtungen von nah, mit Schnittvolumen.
- `screenshot()` zeigt genau Kevins Ansicht, 1280 × 800 px. Größer nur, wenn Details fehlen.
- `mm_per_px` gibt es nur in paralleler Projektion. Maße trotzdem mit `measure` bestätigen.

## Renderings (Phase 7)

Schöne Bilder für Kevin (Produktbild, Deckblatt, Kunden, Social Media) macht `render`, nicht `screenshot`. Nur auf
Kevins Wunsch, und das Bild ist für ihn: die Antwort nennt den Pfad; selbst ansehen nur mit `bild_zeigen=true`, wenn
Kevin danach fragt oder du etwas prüfen musst.

- `render(szene="studio", ansicht=None, kamera=None, groesse="hd", qualitaet="schnell", hintergrund=None, ziel=None)`
  schreibt ein PNG nach `<projekt>/output/renders/`. Es zeigt, was der Viewer zeigt: sichtbare Teile, Explosion und
  Animationslage; ohne Schnitt, Hervorhebungen und Maße.
- Szenen: `studio` (heller Hintergrund, weicher Schatten), `werkstatt` (Werkstatt mit Werkbank und Regalen), `draussen` (Garten
  bei Tageslicht), `wohnraum`, `freigestellt` (PNG mit Alpha und halbdurchsichtigem Schatten). `hintergrund` ersetzt den
  Hintergrund (`weiss`, `hell`, `grau`, `dunkel`, `schwarz`, `transparent`, `#RRGGBB`).
- `ansicht`: `aktuell` (Kevins Ansicht, Vorgabe; steht der Viewer auf paralleler Projektion, wird das Bild in beiden
  Qualitäten echt orthografisch mit derselben sichtbaren Höhe), `produkt` (3/4 von vorn rechts, leicht von oben,
  eingepasst) oder eine Standardansicht (perspektivisch); `kamera="FX6"` rendert durch eine Kamera aus model.py
  (Seitenverhältnis ihres Formats).
- `groesse`: `hd`, `4k`, `quadrat`, `hochkant` (Instagram 4:5), `story`, `deckblatt` (3:2), `a4`, `vorschau` oder
  `"2400x1600"`.
- `qualitaet="schnell"`: RealityKit in der App, ein bis wenige Sekunden, wartet. `qualitaet="foto"`: Blender Cycles im
  Hintergrund, eine bis wenige Minuten; die Antwort kommt sofort mit Auftrag `R-n`. Stand mit
  `render(auftrag="R-3", warten_s=120)`, Abbruch mit `abbrechen=true`. Kevin sieht den Fortschritt in der App.
- Materialien kommen aus dem Katalog (`render`: eloxiert, gebürstet, verzinkt, Schichtlinien bei Druckteilen, Holz,
  Gummi). Die Schichtlinien liegen quer zur Druckrichtung des Teils (Ausrichtung aus der Druckprüfung, wie in der
  Druckvorschau). Den Schatten auf dem Boden rechnet das Schnellbild wie die Flächenlichter des Fotos (Kontaktschatten
  unter dem Objekt, weicher Schlagschatten). Eine Farbe in `show(..., color=...)` hat Vorrang vor der Katalogfarbe, Glanz und Metall bleiben.
- Kevin selbst: Ablage → „Rendern …“ (⌥⌘R) mit Vorschau, Finder und Teilen; im Export-Dialog der Baustein
  „Produktbild“.

## Animation

Bewegungen gehören wie die Geometrie in `model.py`: `from kevcad import animation`, am Ende nach allen `show()`.
Ziele sind Teilnamen oder Baugruppenpräfixe („Rollwagen“ bewegt alle „Rollwagen/…“). Zeiten in s, Längen in mm,
Winkel in Grad. Der Kernel rechnet daraus je Bild die Lage jedes Teils, die App spielt flüssig ab (Zeitleiste unter dem
Viewport, Leertaste, Pfeiltasten, Umschalt+Pfeil für Anfang und Ende).

```python
fahrt = animation(dauer=8, fps=30, name="Fahrt")          # mehrere Animationen je Projekt mit eigenem Namen
fahrt.bewege("Rollwagen", nach=(2000, 0, 0), von=1, bis=7, kurve="weich")
for i in range(1, 5):                                     # Räder drehen mit: Winkel = Strecke / Radius
    fahrt.rolle(f"Rollwagen/Lenkrolle {i}/Rad", auf="Rollwagen", radius=50, achse="y")
fahrt.folge("Kugelschieber", "Rollwagen")                 # fährt starr mit
fahrt.rolle("Bowlingball", auf="Rollwagen", radius=108.5) # rollt frei vor dem Schieber
fahrt.ansicht(0, lage=(-900, -1800, 700), ziel=(300, -340, 150), mit="Rollwagen/Rahmen")  # Kamerafahrt
```

| Spur | Wirkung |
|---|---|
| `bewege(name, nach=(dx,dy,dz), von, bis, kurve)` | verschieben; `kurve` `"linear"`, `"weich"`, `"ein"`, `"aus"` |
| `drehe(name, achse, winkel, von, bis, kurve)` | drehen; `achse=((x,y,z),(dx,dy,dz))`, `Axis`, Richtung oder `"x"/"y"/"z"` durch die Teilmitte |
| `pfad(name, punkte, von, bis, ausrichten=False, spline=False)` | entlang Polylinie oder Spline, gleichmäßig nach Bogenlänge |
| `rolle(name, auf, radius, achse=None)` | Rollbedingung; mit Achse wie ein Rad, ohne frei wie eine Kugel |
| `folge(name, eltern)` | Kind folgt allen Bewegungen des Elternteils |
| `gelenk(name, art="dreh"/"schub", achse, werte={t: wert}, grenzen=(min, max), eltern)` | Gelenkwinkel/-weg über die Zeit, an den Grenzen begrenzt (Warnung) |
| `sichtbar(name, an, zeit)` / `ansicht(zeit, lage, ziel, bildwinkel, mit)` / `erlaube(a, b)` | ein-/ausblenden, Kamerafahrt, gewollte Berührung |

Drehachsen gelten in der Ruhelage (Koordinaten wie in model.py); Drehungen wirken vor Verschiebungen, beides vor der
Bewegung des Elternteils. Ein unbekanntes Teil oder eine Zeit außerhalb der Dauer bricht den Lauf mit Zeile ab.

- `kollision_pruefen(name)` prüft jedes 3. Bild exakt (OCCT-Schnittvolumen, Berühren ist erlaubt) und meldet Zeit,
  Teilpaar, Eindringtiefe und Volumen; die App markiert sie auf der Zeitleiste und färbt das Paar rot. **Jede
  Durchdringung muss gelöst werden**, gewollte Anlage mit `erlaube` oder Luft im Modell. Eine Überlappung, die die
  eingebaute Prüfung über `erlaubt_ueberlappung(a, b, grund=…)` zulässt, gilt auch in der Animation als erlaubt. Die
  eingebaute Prüfung nach jedem Lauf sieht nur die Ruhelage; ihre roten Schnittkörper blendet die App beim Abspielen
  aus.
- `animation_abspielen(name, an=True, schleife=False)`, `animation_springen(zeit)`, `animation_liste()`.
- `animation_video(name, breite=1920)` schreibt ein H.264-MP4 (oder `format="prores"`) nach
  `<Projekt>/output/animationen/` aus der Viewer-Sicht bzw. der Kamerafahrt.

### Kamera und Animation

Eine Kamera mit `an(teil)` fährt mit ihrem Teil: beim Abspielen (Pyramide), beim Blick durch die Kamera (Taste 0
bleibt beim Abspielen aktiv) und im Video. Eine frei gesetzte Kamera mit gezeigtem `koerper()` folgt ihrem Gehäuse.

```python
fx6 = lager.kamera("sony-fx6", objektiv="sigma-ff-hs-35-t1.5-e", format="ff-uhd", name="FX6")
fx6.an("Rollwagen/Deckel", punkt=(150, 0, 40), richtung=(1, 0, 0), bezug="stativ_1_4", lokal=True)
show(fx6.koerper(), "Kamera FX6")      # fährt in jeder Animation von selbst mit dem Deckel mit
fahrt = animation(dauer=8, fps=30, name="Fahrt")
fahrt.bewege("Rollwagen", nach=(2000, 0, 0), von=1, bis=7, kurve="weich")
fahrt.folge("Rig", "Rollwagen/Deckel")  # Rig-Zubehör hängt nicht an der Kamera: eigene Spur
```

- `animation_video("Fahrt", kamera="FX6")` rendert durch die Kamera (Bildwinkel der Kamera, Seitenverhältnis ihres
  Formats, eigenes Objektiv ausgeblendet) nach `output/animationen/Fahrt_FX6.mp4`. `animation_liste` und `run` nennen
  je Animation die Kameras, die mitfahren.
- Kevin: Taste 0, dann Leertaste; das Video aus Menü oder Zeitleiste entsteht beim Blick durch eine Kamera aus ihrer
  Sicht.
- Den Körper bewegt der Kernel nur, wenn keine eigene Spur ihn bewegt; Werte von `kamera_info` gelten für die Ruhelage.

## Technische Zeichnungen

Werkstattzeichnungen nach ISO 128/129-1 (Projektionsmethode 1, Schriftfeld ISO 7200, Allgemeintoleranz ISO 2768-m)
entstehen aus dem Modell; die Maße hängen an erkannten Merkmalen (Bohrung, Lochbild, Langloch, Tasche, Fase, Radius,
Stange mit Gehrung, Einsatz- und Muttertasche) und überleben Änderungen am Modell. Blätter liegen unter
`<Projekt>/dokumente/zeichnungen/<id>.json`, Kevin sieht und bearbeitet sie in der App (Bereich „Dokumente“).

Ablauf:

1. `zeichnung_erstellen()` nach einem fehlerfreien `run`: je Stücklistenposition eines gefertigten Teils (Rohre und
   Profile, Platten, Druckteile) ein Blatt, dazu der Zusammenbau mit Positionsnummern und Stückliste. Einzelne Teile
   mit `teile=["Gestell/Bein vorn links"]`, eine Baugruppe mit `art="baugruppe"`. Normteile und Zukaufteile bekommen
   keine Zeichnung. Vorhandene Blätter behalten Kevins Änderungen und werden nur neu gerechnet.
2. Jedes Blatt selbst prüfen: `zeichnung_bild(blatt)` (nur zur eigenen Prüfung, **Kevin keine Bilder schicken**) und
   die Prüfung im Ergebnis lesen (fehlendes Größen- oder Lagemaß, Überbemaßung, Überlappung, verwaiste Maße). Frage:
   Kann eine Werkstatt das Teil allein mit diesem Blatt fertigen?
3. Fehlende oder falsche Maße mit `zeichnung_bearbeiten(blatt, ops)` korrigieren, Bezüge über Merkmal-Kennungen aus
   dem Ergebnis von `zeichnung_erstellen`:
   - `{"op": "mass_neu", "art": "linear", "ansicht": "v1", "bezuege": [{"merkmal": "seite:x-"}, {"merkmal": "bohrung:2"}], "richtung": "x"}`
   - `{"op": "mass_loeschen", "id": "m7"}` (automatische Maße bleiben dann weg), `{"op": "mass_aendern", "id": "m3", "toleranz": "H7"}`
   - `{"op": "ansicht_neu", "art": "schnitt", "schnitt": {"von": "v1", "ebene": {"punkt": [x, y, z], "normale": [0, 1, 0]}}}`
     für Innenmerkmale; `{"op": "massstab", "wert": "1:2"}`, `{"op": "format", "wert": "A3"}`, `{"op": "notiz", "text": "Grat entfernen", "lage": [30, 30]}`.
4. Kevin kurz berichten: welche Blätter, Format und Maßstab, was von Hand ergänzt wurde, offene Punkte.

Regeln der automatischen Bemaßung: Vorlage je Teiletyp (Rohr: eine Ansicht längs, Länge, Gehrung, Bohrungen ab dem
Rohrende; Platte: eine Ansicht, Dicke als Angabe, Lagen ab der Ecke unten links; Druckteil: Hüll- und Funktionsmaße,
sonst „nach 3D-Modell“), jedes Maß einmal, Lochbilder als „n× Ø“, symmetrische Lagen zur Mittellinie, ab vier Lagen
steigende Bemaßung, Hüllmaße außen. Gewinde und Einsatztaschen erkennt Kev CAD nur mit Gegenstück im Modell (Schraube,
Gewindestift, Gewindeeinsatz auf derselben Achse); fehlt es, steht nur der Durchmesser da. Abweichende Hausregeln
(Maßlinienabstand, Schraffur, Pfeil, Schrift) in `dokumente/hausregeln.json`.

## Export

`export(["step", "stl", "3mf"])` schreibt nach `<Projekt>/output/`, `export(["bom_csv"])` die Stückliste als CSV. STEP für CAD und Fertigung, STL oder 3MF für den
Bambu-Drucker, GLB für Ansichten. `parts=["Halter/Schelle"]` exportiert nur diese Teile.

## Drucken auf dem P1P (Phase 8)

Kevins Entscheidung (22.10.2026): Weg A. Kev CAD slict die Platten der Druckvorschau mit Bambu Studio fertig und öffnet
sie dort; Kevin klickt in Bambu Studio „Platte drucken“ und „Senden“, die Handy-App bleibt. Ein Material je Auftrag
(P1P ohne AMS).

- `drucker_status` liest den Stand (nur lesend): Verbindung, Fortschritt, Schicht, Restzeit, Temperaturen, Fehler,
  letzter Auftrag. Seriennummer und Zugangscode stehen nie darin; frag Kevin nie danach, er trägt sie in der App ein.
- `drucken(platten=[1], grund="…")` nur, wenn Kevin ausdrücklich drucken will. Es öffnet in Kev CAD den Dialog
  „Drucken …“; es geschieht nichts, bis Kevin dort klickt. Nie zum Testen, nie aus eigenem Antrieb.
- Starten, Pausieren oder Abbrechen am Drucker gibt es für den Agenten nicht. Weg B (direkt im LAN) ist gesperrt,
  solange der Drucker nicht im LAN-only-Modus mit Developer Mode läuft.

## Bauplan

Kev CAD erzeugt aus dem Modell eine Bauanleitung zum Ausdrucken (Kevin, 22.10.2026: „was muss wann gemacht werden,
was muss wie montiert werden … alle Löcher, die gebohrt werden“). Datei `<projekt>/dokumente/bauplan.json`, in der
App im Bereich „Dokumente“ mit Strichbild je Schritt; Vertrag in DOKUMENTE.md.

- **Erzeugen:** `bauplan` (bei neuem Lauf rechnet Kev CAD einen vorhandenen Bauplan selbst nach). Fünf Abschnitte:
  Material (Einkauf, Bestand), Zuschnitt (je Stange mit Gehrung), Bearbeiten (Bohrbild je Teil mit Ø und Lage ab
  Rohrende bzw. Außenkante, Gewinde, Senkungen; Gewindeeinsätze einschmelzen, Gewindestifte einkleben), Drucken
  (Material, Ausrichtung als Schätzung, Temperaturen), Montage (Unterbaugruppen aus dem Namensbaum zuerst, dann die
  Hauptmontage; je Schritt ein Hauptteil mit seinen Verbindungsmitteln, gleiche Schritte als „4×“).
- **Was Kev CAD weiß, was du schreibst:** Reihenfolge, Einführrichtung, Teile, Verbindungsmittel, Werkzeug, Maße und
  Lagen kommen aus dem Kernel. Du formulierst danach die Texte mit `bauplan_bearbeiten` (`{"op": "text", "schritt",
  "titel", "text", "hinweise"}`), knapp wie für eine Werkstatt: Schritt, Handgriff, Werkzeug, worauf achten, dazu
  Sicherheit (Quetschstellen an beweglichen Teilen, scharfe Kanten nach Sägen und Bohren, heißer Lötkolben,
  Schutzbrille). Zahlen nur aus den Schrittdaten übernehmen, nie schätzen oder anders runden; fehlt eine, schreiben,
  was zu messen ist.
- **Prüfen:** Jeder Montageschritt wird simuliert (`bauplan_pruefen`): Einführweg frei (`einfuehrweg`), Reihenfolge
  (`reihenfolge`, auch die Regeln „a vor b“), Werkzeugzugang (`werkzeugzugang`: Innensechskant gerade über dem Kopf,
  Schlüssel um die Mutter, Finger um die Flügelmutter), Standsicherheit der Teilbaugruppe (`standsicherheit`), neue
  Teile im Bild sichtbar (`verdeckt`, Agrawala: mindestens 50 %). Hinweis „unter die Aufstandsfläche“ heißt: Baugruppe
  aufbocken oder umdrehen.
- **Probleme im Modell beheben, nicht im Text verstecken:** Passt ein Teil nicht hinein oder kommt das Werkzeug nicht
  hin, wird model.py geändert (Spiel, Einführschräge, Schlitz, Teilung, Muttertasche statt Schlüssel, Zugangsbohrung),
  dann `run`; der Bauplan folgt. Reihenfolge nur ändern (`verschieben`, `{"op": "vorher", "a", "b", "grund"}`), wenn
  mehrere Folgen gleich gut sind, und dann Kevin fragen.
- **Erhalten:** Texte von Agent und Kevin und Schritte mit `fest` bleiben bei jedem neuen Lauf (Zuordnung über die id
  und die Teile). Teile, die nicht zum Aufbau gehören (Umgebung, lose daneben), nimmt Kev CAD selbst heraus; weitere mit
  `{"op": "umfang", "ohne": ["Umgebung"]}`.
- **Grenzen:** Montage nur durch Schieben (ein- oder zweistufig), kein Drehen; Eigenteile einer Gruppe, die
  zusammenhängen (Rollwagen, Fluidkopf, Kamera), gelten als vorhanden und vormontiert; ohne `verbinde` sind Verbindungen
  und Werkzeug aus Kontakt und Normteilen geschätzt (steht am Schritt). Kevin keine Bilder schicken, die App zeigt sie.
- **Durchspielen:** Kevin spielt den Aufbau in der App Schritt für Schritt im 3D-Bereich durch (nur montierte Teile,
  neue fahren entlang der Einführrichtung ein). Das ist seine Ansicht; du prüfst mit `bauplan_pruefen`.

## Dokumente als PDF

`dokument_export(bausteine, ziel=None, drucken=False)` lässt die App ein PDF bauen, dieselben Seiten wie im Dialog
„Dokumente exportieren …“ (⇧⌘E): `deckblatt`, `produktbild` (Rendering auf eigener Seite: das jüngste aus
`output/renders/`, wenn es nach dem letzten Lauf entstand, sonst ein schnelles Studio-Bild), `stueckliste`,
`teileliste`, `einkaufsliste`, `zuschnitt`, `zeichnungen`, `bauplan`, in der angegebenen Reihenfolge; leer oder
`"alle"` = alles. Objekte wie
`{"art": "stueckliste", "spalten": ["pos", "bild", "benennung", "masse", "anzahl"]}` oder
`{"art": "zeichnungen", "auswahl": ["<blatt-id>", …]}` wählen Spalten bzw. Blätter; `"vorlage:<Name>"` nimmt eine
Vorlage, die Kevin im Dialog gesichert hat; `{"format": "A3", "ausrichtung": "quer"}` setzt das Papier der Listen und
des Bauplans (Zeichnungen behalten ihr Blattformat). Ohne `ziel` landet das PDF in `<projekt>/output/<Projekt>-dokumente.pdf`.
`drucken=true` öffnet den Druckdialog in der App, **nur wenn Kevin ausdrücklich drucken will**. Vorher `bauplan` und
`zeichnung_erstellen`, damit die Bausteine Inhalt haben; die Antwort nennt Seiten je Baustein, Formate und Hinweise.

## Wenn etwas hakt

| Meldung | Bedeutung |
|---|---|
| Lauf fehlgeschlagen in Zeile N | Fehler in model.py; Auszug lesen, korrigieren, `run` |
| Unbekannte oder veraltete Referenz | nach dem letzten Lauf neu holen (`parts`, `selection`, `execute`) |
| App nicht verbunden | der Kernel läuft, die App hängt (noch) nicht an ihm; kurz warten, sonst Kevin bitten, Kev CAD zu öffnen |
| Kev CAD läuft nicht – bitte starten | die Brücke erreicht die App nicht; Kevin bitten, Kev CAD zu starten |
| Inventar-Regel: … nicht aus dem Inventar | Teil ohne `verbauen`/`druckteil` gezeigt; Lagerteil suchen, Druckteil kennzeichnen oder Kevin fragen |
| … wartet auf Kevins Freigabe | Vorschlag aus `stock_define`/`material_define`/`zukauf_anlegen`; `freigabe_anfragen([id], grund)` öffnet den Dialog im Projektfenster |
| Material '…' gibt es im Katalog nicht | nur Katalogmaterialien (`material_list`); fehlt eins, Kevin fragen |
| Lagerteil „…“ ist keinem gezeigten Teil zugeordnet | Name in `show()` anders als in `verbauen()`; gleich benennen |
| Export verweigert | erst die Verstöße gegen die Inventar-Regel beheben |
| Prüfung: 2 Durchdringungen … | Teile stecken ineinander; je Befund die Lösung umsetzen (Spiel, Bohrung, verschieben), `run` |
| … schwebt: … fiele 12 mm auf … | Teil absenken oder mit dem tragenden Teil verbinden |
| … kippt / steht knapp | Standfläche verbreitern, Schwerpunkt senken |
| … lässt sich nicht einbauen / nur als Baugruppe / eingesperrt | umkonstruieren (Reihenfolge, Teilung, Öffnung, lösbare Verbindung); Zukaufteil als Baugruppe erklären |
| … Werkzeug kommt nicht hin | Freiraum für den Schlüssel schaffen oder Schraube anders setzen |
| Export verweigert. Prüfung: … | erst die Befunde der Prüfung beheben |
| Bedingungen: … verletzt (Soll …, Ist …) | Teil nicht von Hand verschieben, sondern mit `bed.platziere` aus den Bedingungen setzen; Lösung im Befund |
| Widerspruch beim Platzieren | die genannten Bedingungen passen nicht zusammen; eine weglassen oder Werte angleichen |
| … ist unterbestimmt (Hinweis) | freie Freiheitsgrade: weitere Bedingung (konzentrisch, mittig, parallel, abstand) |
| … nicht befestigt / Nicht am Boden | `bed.verbinde(teil, gegenstück, art=…)` angeben und die Befestigung konstruieren |
| Bewegungsraum: stößt bei … an … | Platz schaffen oder umkonstruieren; den Bereich nur verkleinern, wenn die Bedienung das erlaubt |
| … nicht geprüft: Teil … nicht gefunden | Bezug nach der letzten Änderung nehmen oder das Teil über seinen Namen angeben |
