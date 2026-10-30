"""Fassade zwischen MCP-Werkzeugen (server.py) und Kernel-Laufzeit (runtime.py).

Vertrag für die parallele Entwicklung: Die MCP-Seite programmiert nur gegen ``KernelService`` (und testet mit einer
Attrappe), die Laufzeit implementiert ihn in ``kevcad_kernel.runtime``. Alle Methoden sind synchron und
threadsicher; sie dürfen blockieren (die MCP-Seite ruft sie in einem Worker-Thread auf). Rückgaben sind
JSON-taugliche Wörterbücher mit den hier beschriebenen Schlüsseln; Fehler, die der Agent beheben kann (Syntaxfehler,
unbekannte Referenz, App nicht verbunden), kommen als ``{"ok": False, "error": "..."}`` zurück, nicht als Ausnahme.
"""

from __future__ import annotations

from typing import Any, Protocol, TypedDict


class PartSummary(TypedDict, total=False):
    name: str  # vollständiger Name aus show(), z. B. "Halter/Lasche"
    bbox: dict[str, list[float]]  # {"min": [x,y,z], "max": [x,y,z], "size": [dx,dy,dz]}
    volume: float  # mm³
    area: float  # mm²
    mass: float | None  # g, nur mit Material
    material: str | None
    color: list[float]  # RGBA 0..1
    faces: int
    edges: int
    triangles: int
    visible: bool


class RunError(TypedDict, total=False):
    message: str
    line: int | None
    excerpt: str
    traceback: str
    hint: str  # kurzer Reparaturhinweis, falls bekannt


class RunResult(TypedDict, total=False):
    ok: bool
    run: int
    duration_ms: int
    parts: list[PartSummary]
    steps: list[str]
    warnings: list[str]
    params: dict[str, float]
    error: RunError
    # Phase 2 (additiv): Summen der Stückliste und Inventar-Regel
    bom: dict[str, Any]  # {"totals", "warnings", "cuts"}
    inventar_regel: bool
    inventar_verstoesse: list[str]  # gezeigte Teile ohne verbauen()/druckteil()
    # Zwangsbedingungen (additiv): Kurzfassung des Berichts, vollständig über constraints()
    bedingungen: dict[str, Any]  # {"summe", "befunde", "befunde_gesamt", "pruef_ms", "loese_ms", ...}
    # Versionen (additiv): Version dieses Laufs, {"nr", "neu", "ms", "titel" (angezeigt: Agent vor Automatik),
    # "titel_auto", "titel_vergeben"? (Titel aus run(titel=…) gesetzt), "hinweis"? (run(titel=…) ohne neue Version)}
    version: dict[str, Any]


class MeasureResult(TypedDict, total=False):
    ok: bool
    refs: list[str]
    run: int
    kind: str  # distance | angle | face | edge | vertex | part
    values: dict[str, Any]
    points: list[list[float]]
    text: str
    error: str


class Screenshot(TypedDict, total=False):
    ok: bool
    png: bytes
    width: int
    height: int
    camera: dict[str, Any]
    mm_per_px: float | None
    error: str


class KernelService(Protocol):
    # Projekt
    def status(self) -> dict[str, Any]:
        """{"project": {"path","name","model"} | None, "kernel": "ready"|"busy"|"error", "app_connected": bool,
        "last_run": RunResult | None, "selection": {"run", "refs"}}"""

    def project_open(self, path: str) -> dict[str, Any]:
        """Öffnet einen Projektordner (legt nichts an). {"ok", "path", "name", "model", "error"?}"""

    def project_new(self, path: str, template: str = "example") -> dict[str, Any]:
        """Legt einen Projektordner mit model.py an (template "empty" oder "example") und öffnet ihn."""

    def model_read(self) -> dict[str, Any]:
        """{"ok", "path", "code"}"""

    def model_write(self, code: str) -> dict[str, Any]:
        """Schreibt model.py des offenen Projekts. {"ok", "path", "bytes"}"""

    # Lauf
    def run(self, params: dict[str, float] | None = None, slow_ms: int = 0, timeout_s: float = 120,
            titel: str | None = None) -> RunResult:
        """Führt model.py aus; Teile gehen dabei live an die App. Läuft für denselben Dateistand schon ein Lauf,
        wird auf dessen Ergebnis gewartet. ``titel`` (additiv): Beschreibung der Änderung in Kevins Worten; wird der
        Titel der Version dieses Laufs (vor dem automatischen, der als Zusatz bleibt)."""

    def execute(self, code: str, timeout_s: float = 60) -> dict[str, Any]:
        """Python im Namensraum des letzten Laufs. {"ok", "stdout", "result" (repr des letzten Ausdrucks), "error"?}
        Mit show() erzeugte Teile erscheinen als Skizze im Viewer."""

    def parts(self) -> list[PartSummary]:
        """Teile des letzten Laufs."""

    # Messen und Auswahl
    def measure(self, refs: list[str], show: bool = False) -> MeasureResult:
        """Exakt messen, 1 oder 2 Referenzen (siehe PROTOCOL.md). show=True blendet das Maß im Viewer ein."""

    def selection(self) -> dict[str, Any]:
        """Auswahl in der App: {"run", "refs": [...], "details": [MeasureResult je Referenz]}"""

    # Ansicht (geht über die App, siehe VIEW_CMD in PROTOCOL.md)
    def view_command(self, cmd: str, args: dict[str, Any], timeout_s: float = 10) -> dict[str, Any]:
        """{"ok", "message"?}; {"ok": False, "error": "App nicht verbunden"} wenn keine App da ist."""

    def screenshot(self, width: int = 1280, height: int = 800, source: str = "current", view: str | None = None,
                   hide_overlays: bool = False, timeout_s: float = 15) -> Screenshot:
        """Bild aus der App: aktuelle Ansicht oder offscreen mit Standardansicht."""

    # Export
    def export(self, formats: list[str], parts: list[str] | None = None) -> dict[str, Any]:
        """{"ok", "files": [...]} in <projekt>/output/"""

    # Phase 2: Lagerteile, Materialien, Stückliste (siehe KATALOG.md und PROTOCOL.md, Abschnitt Phase 2)
    def bom(self) -> dict[str, Any]:
        """Stückliste des letzten Laufs: {"ok", "run", "lines", "cuts", "totals", "warnings"} wie die BOM-Nachricht;
        mit Bestandsabgleich dazu "einkauf_text" (Einkaufsliste wie „Teilen“ in der App, BESTAND.md)."""

    def stock_search(self, query: str = "", art: str | None = None, limit: int = 30) -> dict[str, Any]:
        """Lagerteile suchen (alle drei Ebenen): {"ok", "items": [Lagerteil + "ebene"], "total"}"""

    def stock_get(self, stock_id: str) -> dict[str, Any]:
        """Ein Lagerteil mit berechneten Werten: {"ok", "item", "kg_je_m", "querschnitt_mm2", "preis_je_m"}"""

    def stock_define(self, entry: dict[str, Any], ebene: str = "eigen") -> dict[str, Any]:
        """Lagerteil anlegen oder ersetzen (KATALOG.md). Prüft Pflichtfelder und Maße. {"ok", "item", "datei"}
        Inventar-Regel: über MCP immer als Vorschlag (status "vorgeschlagen"), verbaubar erst nach Kevins Freigabe;
        freigegebene Einträge ersetzt es nicht."""

    def material_list(self, query: str = "") -> dict[str, Any]:
        """{"ok", "materials": [Material + "ebene"]}"""

    def material_define(self, entry: dict[str, Any], ebene: str = "eigen") -> dict[str, Any]:
        """Material anlegen oder ersetzen (KATALOG.md). {"ok", "material", "datei"}
        Wie stock_define über MCP immer als Vorschlag."""

    def catalog_delete(self, kind: str, entry_id: str, ebene: str = "eigen") -> dict[str, Any]:
        """Eintrag aus dem eigenen oder Projekt-Katalog löschen. {"ok"}"""

    def freigabe_anfragen(self, ids: list[str], grund: str = "", warten_s: float | None = None) -> dict[str, Any]:
        """Strang „Feinschliff 2“ (additiv, kevcad_kernel/freigabe.py): Dialog „Vorschläge freigeben“ im
        Projektfenster öffnen und auf Kevins Entscheidung warten (höchstens ``warten_s``, Standard 120 s). Gibt nichts
        selbst frei. {"ok", "anfrage", "freigegeben", "abgelehnt", "offen", "schon_frei", "dialog": "entschieden" |
        "geschlossen" | "offen" | "nicht_noetig"}"""

    # Bestand je Projekt (BESTAND.md; Umsetzung in kevcad_kernel/bestand/anbindung.py)
    def bestand_liste(self, stock_id: str | None = None) -> dict[str, Any]:
        """Bestand und Reste des offenen Projekts: {"ok", "projekt", "datei", "stand", "bestand", "buchungen",
        "text", "posten" (nur mit stock_id)}"""

    def bestand_eintragen(self, stock_id: str | None = None, ganze: Any = None, reste: list[Any] | None = None,
                          reste_entfernen: list[str] | None = None, stueck: Any = None,
                          mindestrest_mm: float | None = None, reste_ersetzen: bool = False,
                          grund: str = "", *, material: str | None = None, gramm: float | None = None,
                          gramm_voll: float | None = None, spule: str | None = None, farbe: str | None = None,
                          hersteller: str | None = None, anzahl: int | None = None, kennung: str | None = None,
                          ort: str | None = None, spulen_entfernen: list[str] | None = None,
                          filament: str | None = None) -> dict[str, Any]:
        """Nur nach Kevins Angabe. {"ok", "buchung", "aenderungen_text" (jede Änderung als Zeile), "posten"}.
        Additiv ``filament``: id aus Kevins Filamentliste (Spule verweist darauf, druck/filamente.py).
        Strang „Bestand Stufe 2“ (additiv): Filament statt ``stock_id`` mit ``material`` (neue Spulen: ``gramm``,
        ``spule`` als Name, ``gramm_voll``, ``farbe``, ``hersteller``, ``ort``, ``anzahl``; 0 = Filament führen ohne
        Spule), ``kennung`` (Spule ändern) oder ``spulen_entfernen``; dann statt ``posten`` die ``spulen``."""

    def einkaufsliste(self) -> dict[str, Any]:
        """Einkaufsliste wie in der App (bestand/einkauf.py): {"ok", "run", "lagerware", "zukauf", "normteile",
        "filament", "positionen", "summe" (Lagerware + Zukaufteile), "summe_lager", "summe_zukauf", "ohne_preis",
        "text", "csv"} und die Felder der Stückliste ("einkaufsliste", "einkauf_summe" nur Lagerware,
        "einkauf_hinweis", "bestand_stand", "fehlt", "stueckgut"); additiv "filament_kauf" (Spulen unter Lagerware),
        "filament_aus_bestand", "filament_bestand"."""

    def gebaut_buchen(self, grund: str = "", run: int | None = None) -> dict[str, Any]:
        """Nur auf Kevins ausdrücklichen Wunsch. {"ok", "buchung", "aenderungen_text"}; führt das Projekt Filament,
        auch das Filament der noch nicht gebuchten Druckplatten ("filament", "filament_text")."""

    def gedruckt_buchen(self, grund: str = "", platten: list[int] | None = None, spule: str | None = None,
                        run: int | None = None) -> dict[str, Any]:
        """Strang „Bestand Stufe 2“ (additiv), nur auf Kevins ausdrücklichen Wunsch: Filament der Druckvorschau
        abbuchen (alle noch nicht gebuchten Platten oder ``platten``; ``spule`` zuerst). {"ok", "buchung",
        "aenderungen_text", "filament", "filament_text", "platten"}"""

    def buchung_rueckgaengig(self, buchung: str) -> dict[str, Any]:
        """{"ok", "buchung" (die Umkehrbuchung), "aenderungen_text"}"""
    # Phase 3: Zukaufteile (KATALOG.md „Zukaufteil“, PROTOCOL.md „Phase 3“, kevcad_kernel.zukauf.dienst)
    def zukauf_anlegen(self, url: str | None = None, mpn: str | None = None, gtin: str | None = None,
                       felder: dict[str, Any] | None = None, ebene: str = "projekt") -> dict[str, Any]:
        """Zukaufteil aus Feldern anlegen, über MCP immer als Vorschlag. {"ok", "angelegt": bool, "item", "datei",
        "zu_pruefen", "hinweise", "text"}; Normteile: {"ok", "angelegt": False, "normteil", "stock_id", "beispiel",
        "vorschlag", "text"}; schon vorhanden: {"ok", "angelegt": False, "vorhanden", "text"}."""

    def zukauf_html(self, url: str | None, html: str, anlegen: bool = False, ebene: str = "projekt") -> dict[str, Any]:
        """Mitgeliefertes HTML auswerten. {"ok", "felder", "entwurf", "quellen", "zu_pruefen", "hinweise",
        "angelegt"?: Ergebnis von zukauf_anlegen, "normteil"?}"""

    def cad_suchen(self, zukauf_id: str) -> dict[str, Any]:
        """Links zu Herstellerportalen und freien Quellen (keine automatische CAD-Quelle). {"ok", "zustand":
        "importiert"|"wartet_auf_cad", "cad_links", "erwartet", "hinweise", "text"}"""

    def cad_uebernehmen(self, zukauf_id: str, pfad: str | None = None, minuten: float = 30,
                        erzwingen: bool = False) -> dict[str, Any]:
        """CAD-Datei (ohne Pfad: neueste passende aus ~/Downloads, auch ZIP) prüfen und übernehmen. {"ok", "zustand",
        "item", "datei", "pruefung", "koerper", "flaechen", "grob", "hinweise", "text"}"""

    def zukauf_liste(self, query: str = "") -> dict[str, Any]:
        """{"ok", "items": [Zukaufteil + "ebene", "cad_art", "cad_datei_fehlt", "zustand", "kurz"], "total"}"""

    # Prüfung (additiv, siehe kevcad_kernel/pruefung und PROTOCOL.md Abschnitt „Prüfung“)
    def pruefen(self, warten_s: float = 120.0, endstand: bool = False) -> dict[str, Any]:
        """Letztes Prüfergebnis nach einem Lauf (wartet auf eine laufende Prüfung): {"ok", "run", "state",
        "zusammenfassung", "zaehler", "befunde", "montage", "stand", "gewinde", "erlaubt", …} wie die Nachricht CHECK.
        ``state`` "teilweise": der Bewegungsraum wird im Hintergrund fertig gerechnet (``im_hintergrund``, offene
        Wege); mit ``endstand`` wird bis ``warten_s`` auf das fertige Ergebnis gewartet (additiv, Prüftempo)."""

    def ansichten(self, ansichten: list[dict[str, Any]], width: int = 640, height: int = 400,
                  timeout_s: float = 20) -> dict[str, Any]:
        """Mehrere Offscreen-Bilder in einem Zug, ohne Kevins Kamera zu ändern. Je Ansicht: name, standard oder
        richtung [x,y,z], ziel (Teile) oder punkt + radius, darstellung, hervorheben, schnittkoerper.
        {"ok", "bilder": [{"name", "png", "width", "height", "camera", "ansicht_umgesetzt"}]}"""

    # Zwangsbedingungen (PLAN-BEDINGUNGEN.md, additiv)
    def constraints(self, part: str | None = None) -> dict[str, Any]:
        """Bericht des letzten erfolgreichen Laufs wie die Nachricht CONSTRAINTS: {"ok", "run", "items", "teile",
        "befunde", "bewegungen", "summe", "pruef_ms", "loese_ms"}; mit ``part`` zusätzlich "teil"."""
    # Phase 5: Animation (siehe PROTOCOL.md, Abschnitt „Phase 5: Animation“; umgesetzt in anim_runtime.py)
    def animation_list(self) -> dict[str, Any]:
        """{"ok", "animationen": [{"name", "dauer", "fps", "bilder", "teile", "kamerafahrt", "spuren", "standard",
        "warnungen"?, "kollisionen"?}], "stand": {"name", "zeit", "bild", "spielt", …} | None}"""

    def animation_play(self, name: str | None = None, an: bool = True, schleife: bool = False,
                       geschwindigkeit: float = 1.0, von_vorn: bool = False) -> dict[str, Any]:
        """Abspielen oder anhalten in der App. {"ok", "name", "an", "schleife", "dauer"}"""

    def animation_seek(self, zeit: float, name: str | None = None) -> dict[str, Any]:
        """Zur Zeit springen (s). {"ok", "name", "zeit", "bild"}"""

    def animation_video(self, name: str | None = None, breite: int = 1920, hoehe: int | None = None,
                        fps: float | None = None, kamera: str | None = None, format: str = "mp4") -> dict[str, Any]:  # noqa: A002
        """Video aus der App nach <projekt>/output/animationen/. {"ok", "path", "width", "height", "fps", "bilder",
        "ms", "kamera"}; ``kamera`` None = Viewer-Kamera bzw. Kamerafahrt aus anim.ansicht, sonst eine Kamera aus
        model.py (Kurzname oder „Kamera/<name>“), Höhe dann aus dem Seitenverhältnis ihres Formats."""

    def collision_check(self, name: str | None = None, schritt: int = 3) -> dict[str, Any]:
        """Kollisionen an jedem ``schritt``-ten Bild. {"ok", "name", "kollisionen": [{"teile", "von", "bis", "zeit",
        "bild", "tiefe", "volumen", "ort"}], "geprueft": {…}}"""
    # Phase 5: Kameras (PROTOCOL.md „Phase 5: Kameras“, Umsetzung in kevcad_kernel.kamera.CameraRuntime)
    def cameras(self) -> dict[str, Any]:
        """Kameras des letzten Laufs: {"ok", "cameras": [CAMERA_UPSERT-Kopf + "vorschlag" (oder None)]}"""

    def camera_info(self, name: str) -> dict[str, Any]:
        """Eine Kamera (Name „FX6“ oder „Kamera/FX6“): {"ok", "camera", "vorschlag", "vorschlag_code"?}"""

    def camera_view(self, name: str | None, timeout_s: float = 10) -> dict[str, Any]:
        """Durch die Kamera schauen (VIEW_CMD camera_view), None = zurück zur freien Ansicht. {"ok", "message"?}"""

    def camera_image(self, name: str, width: int = 1920, save: bool = True, return_png: bool = False,
                     overlays: bool = False, timeout_s: float = 60) -> dict[str, Any]:
        """Bild durch die Kamera (Höhe aus dem Seitenverhältnis des Formats), gespeichert unter
        <projekt>/output/kameras/. {"ok", "file", "width", "height", "camera", "kamera", "png"? (nur mit return_png)}"""

    def camera_catalog(self, query: str = "", art: str | None = None, limit: int = 40) -> dict[str, Any]:
        """Kameras, Objektive und Kamerazubehör aus dem Katalog: {"ok", "items", "total"}"""

    def camera_suggestion(self, name: str = "", timeout_s: float = 10) -> dict[str, Any]:
        """Aktuelle Ansicht der App als neue Lage vorschlagen: {"ok", "name", "vorschlag", "code"}"""

    # Phase 7: Renderings (PROTOCOL.md „Phase 7: Renderings“, umgesetzt in render/laufzeit.py)
    def render(self, szene: str | None = "studio", ansicht: str | None = None, kamera: str | None = None,
               groesse: Any = None, qualitaet: str = "schnell", hintergrund: str | None = None,
               umgebung: str | None = None, ziel: str | None = None, warten_s: float | None = None,
               auftrag: str | None = None, abbrechen: bool = False, bild: bool = False,
               samples: int | None = None) -> dict[str, Any]:
        """Rendering nach <projekt>/output/renders/ (schnell: RealityKit in der App, wartet; foto: Blender im
        Hintergrund, kehrt sofort zurück, außer ``warten_s``). Mit ``auftrag`` („R-3“): Stand abfragen, mit
        ``abbrechen`` abbrechen. {"ok", "auftrag", "zustand" (wartet | laeuft | fertig | fehler | abgebrochen),
        "qualitaet", "szene", "ansicht", "kamera", "width", "height", "pfad", "ms", "fortschritt", "text", "phasen",
        "kamera_json", "png"? (nur mit ``bild``), "error"?}"""

    # Phase 6: Bauplan (DOKUMENTE.md, Abschnitt „Bauplan“; umgesetzt in bauplan/dienst.py)
    def bauplan(self, neu: bool = False) -> dict[str, Any]:
        """Bauplan des letzten Laufs, bei Bedarf erzeugt und als <projekt>/dokumente/bauplan.json gespeichert:
        {"ok", "datei", "bauplan" (Inhalt der Datei mit Prüfung), "zusammenfassung", "zeiten"}"""

    def bauplan_bearbeiten(self, ops: list[dict[str, Any]], von: str = "agent") -> dict[str, Any]:
        """Operationen wie BAUPLAN_EDIT, danach Simulation: {"ok", "meldungen", "zusammenfassung", "befunde"}"""

    def bauplan_pruefen(self, schritt: str | None = None) -> dict[str, Any]:
        """Simulation aller Montageschritte oder eines: {"ok", "befunde", "zusammenfassung", "ms", "schritt"}"""

    # 3D-Druck: Ergebnis der Druckprüfung des letzten Laufs (Prüfer „druck“, druck/laufzeit.py)
    def druckpruefung(self, teil: str | None = None) -> dict[str, Any]:
        """Alle Druckteile oder eines (Name oder Gruppe): {"ok", "run", "drucker", "teile": [{"name", "material",
        "zusammenfassung", "ausrichtung", "kennzahlen", "befunde", …}], "materialien", "zaehler", "statistik"}"""

    # Phase 8: Drucken auf dem Bambu Lab P1P (DRUCKVORSCHAU.md, „Drucken (Phase 8)“)
    def drucker_status(self) -> dict[str, Any]:
        """{"ok", "konfiguriert", "verbindung", "meldung", "drucker", "weg", "wege", "steuern", "druck",
        "temperaturen", "fehler", "kamera", "gefunden", "auftrag", "aktualisiert"} wie PRINTER_STATUS; nie mit
        Seriennummer oder Zugangscode."""

    def drucken(self, platten: list[int] | None = None, weg: str = "a", grund: str | None = None) -> dict[str, Any]:
        """Nur auf Kevins ausdrücklichen Wunsch: öffnet in der App den Dialog „Drucken …“ (PRINT_JOB_ASK). Es geschieht
        nichts, bis Kevin dort bestätigt. {"ok", "auftrag", "zustand": "wartet", "weg", "platten", "meldung"}"""

    # Druckvorschau (DRUCKVORSCHAU.md; umgesetzt in kevcad_kernel.druck.vorschau_laufzeit.DruckvorschauRuntime)
    def druckvorschau(self, detail: bool = False) -> dict[str, Any]:
        """Vorschau des letzten Laufs wie PRINT_PREVIEW: {"ok", "run", "stand", "drucker", "summe", "platten",
        "teile", "hinweise", "slicer", "einstellungen", "regler", "ms"}; ohne ``detail`` ohne Umrisse."""

    # Statik Stufe 1 (PLAN-STATIK.md; umgesetzt in kevcad_kernel.statik.laufzeit.StatikRuntime)
    def statik(self, szenario: str | None = None) -> dict[str, Any]:
        """Statik des letzten Laufs (nach jedem Lauf gerechnet): {"ok", "run", "aktiv", "szenarien": [{"name", "ampel",
        "text", "ziel", "kennzahlen", "urteile"}], "ueberdimensioniert", "grenzen", "vereinfachungen", "modell", "ms"};
        mit ``szenario`` statt "szenarien" ein "szenario" mit Stäben, Lagern, Kippen je Richtung, Rutschen,
        Schrauben, und die App zeigt es."""

    def szenario_rechnen(self, name: str, beschleunigung: Any = None, neigung: float | None = None,
                         richtung: Any = None, lasten: list[dict[str, Any]] | None = None, stoss: float | None = None,
                         ziel: float | None = None, beschreibung: str | None = None, zeigen: bool = True
                         ) -> dict[str, Any]:
        """Neues Szenario mit dem Statikmodell des letzten Laufs (ohne neuen Lauf): {"ok", "run", "szenario",
        "gezeigt", "grenzen", "vereinfachungen", "ms"}. ``lasten``: [{"teil", "kg" | "kraft" [N], "punkt" [mm]?}]."""

    # Statik Stufe 2 (PLAN-STATIK.md T-C; umgesetzt in kevcad_kernel.statik.dynamik.laufzeit.DynamikRuntime)
    def dynamik(self, name: str, geschwindigkeit: float | None = None, bremsen: Any = None, dauer: float | None = None,
                neigung: float | None = None, richtung: Any = None, stoss: float | None = None,
                animation: str | None = None, antrieb: str | None = None, angriff: Any = None,
                fahrtrichtung: Any = None, lasten: list[dict[str, Any]] | None = None, suche: bool = True,
                zeigen: bool = True, beschreibung: str | None = None) -> dict[str, Any]:
        """Ablauf (S2, MuJoCo im eigenen Prozess) mit dem Modell des letzten Laufs: {"ok", "run", "szenario",
        "ablauf" (kennzahlen, urteile, handrechnung, suche, ms), "animation" ("Ablauf: <name>"), "gezeigt",
        "befunde", "grenzen", "vereinfachungen", "ms"}."""

    def dynamik_grenze(self, ohne: str = "beides", bremsen: Any = "abrupt", geschwindigkeit: float = 1.0,
                       name: str | None = None) -> dict[str, Any]:
        """Grenzgeschwindigkeit (Suche mit Rollouts): wie ``dynamik`` plus "grenzen_suche" {"kippen": {"v_abheben",
        "a_abheben", "a_kipp_hand", …}, "ladung": [{"name", "v_grenze"}]}."""

    # Statik Stufe 3 (PLAN-STATIK.md T-D; umgesetzt in kevcad_kernel.statik.festkoerper.laufzeit.FestkoerperRuntime)
    def festigkeit(self, teil: str | None = None, szenario: str | None = None, fein: bool = False,
                   ablauf: bool = False, zeigen: bool = True, verfahren: str | None = None,
                   kontakt: bool | None = None, plastisch: bool | None = None, traglast: bool | None = None,
                   beulen: bool | None = None, klemmkraft: float | None = None,
                   reibwert: float | None = None) -> dict[str, Any]:
        """Festkörper-FEM (S3, eigener Prozess) für Teile mit Last: {"ok", "run", "teile": [{"teil", "ampel",
        "sicherheit", "ziel", "kriterium", "ort", "spannung_max", "verformung_max_mm", "kragtraeger",
        "ausrichtungen", "ausrichtung_beste", "netz", "ms", "text"}], "faelle", "szenarien", "befunde", "hinweise",
        "grenzen", "ms", "gezeigt"}; die App zeigt das Feld (STATICS_FIELD).

        Stufe 4 (additiv, PLAN-STATIK.md „Stand Stufe 4“): ``verfahren="ccx"`` (oder eine der Optionen) rechnet mit
        CalculiX: ``kontakt`` (Standard an), ``plastisch``, ``traglast``, ``beulen``, ``klemmkraft`` (N),
        ``reibwert``. Je Teil zusätzlich "verfahren", "sicherheit_last", "kontakt" {"paare", "klemmungen"},
        "plastisch", "traglast", "beulen", "rutscht"; "verfahren" im Ergebnis. Ohne CalculiX {"ok": False, "error"}."""

    def festigkeit_abbrechen(self) -> dict[str, Any]:
        """Laufende Festkörper-Rechnung beenden: {"ok", "abgebrochen", "szenarien"}."""

    # Topologieoptimierung (PLAN-TOPOLOGIE.md, additiv)
    def topologie_optimieren(self, teil: str | None = None, szenario: str | None = None, behalten: float | None = None,
                             schutz: list[dict[str, Any]] | None = None, ueberhang: bool | None = None,
                             fein: bool | None = None, steg: float | None = None, bett: bool | None = None,
                             neu: bool = False, warten: bool = False, lager: str | None = None) -> dict[str, Any]:
        """Topologieoptimierung eines Druckteils im Hintergrund (eigener Prozess): {"ok", "stand", "teil",
        "szenario", "text"}; mit ``warten`` das Ergebnis wie ``topologie_ergebnis``. ``schutz``: Zonen in Welt
        ({"art": "quader", "min", "max"}, {"art": "kugel", "mitte", "radius"}) oder Flächen des Teils
        ({"art": "index", "index": 12})."""

    def topologie_ergebnis(self, warten_s: float = 0.0) -> dict[str, Any]:
        """Stand der letzten Optimierung: {"ok", "stand" (laeuft|done|failed|abgebrochen|keine), "teil", "szenario",
        "fortschritt", "kennzahlen": {"vorher", "nachher", "ersparnis"}, "schutz", "hinweise", "grenzen",
        "ergebnis": {"datei", "schluessel", "im_modell"}, "text"}."""

    def topologie_abbrechen(self) -> dict[str, Any]:
        """Laufende Optimierung beenden: {"ok", "abgebrochen"}."""

    def topologie_uebernehmen(self, variante: str | None = None, warten: bool = False) -> dict[str, Any]:
        """Letztes Ergebnis als Variante übernehmen (Variante anlegen, model.py ergänzen, Lauf): {"ok", "variante",
        "zeile", "text"}."""

    # Bereich „Simulation“ (PLAN-SIMULATION.md, additiv; umgesetzt in kevcad_kernel.simulation.laufzeit)
    def simulation_liste(self) -> dict[str, Any]:
        """Lastfälle, Lasten, Lager und Topologie-Einstellungen aus der App (<projekt>/simulation.json) mit ihrem
        Zustand im aktuellen Modell: {"ok", "run", "stand", "datei", "vorhanden", "lastfaelle" (je mit "lasten",
        "ampel", "text"), "modell" (Szenarien aus model.py), "lager", "modell_lager", "abgeleitet", "topologie",
        "hinweise", "fehler", "job"}."""

    def simulation_aendern(self, ops: list[dict[str, Any]], basis: int | None = None,
                           von: str = "agent") -> dict[str, Any]:
        """Operationen auf simulation.json wie SIM_EDIT der App (lastfall_neu, lastfall_setzen, lastfall_kopieren,
        lastfall_umbenennen, lastfall_loeschen, last_setzen, last_loeschen, lager_setzen, lager_loeschen, abgeleitet,
        topologie), danach alles mit dem letzten Modell neu gerechnet: {"ok", "stand", "meldungen", "gerechnet",
        "datei", "lastfaelle", "lager", "hinweise"}."""

    def simulation_rechnen(self, was: str, lastfall: str | None = None, teil: str | None = None, fein: bool = False,
                           grenze: str | None = None, warten: bool = True, von: str = "agent", *,
                           verfahren: str | None = None) -> dict[str, Any]:
        """Knopf im Bereich Simulation: ``was`` rechnen | festigkeit | ablauf | grenze (``grenze`` last | neigung |
        geschwindigkeit; additiv ``verfahren`` s0s1 | fem für last und neigung): {"ok", "auftrag", "text",
        "ergebnis"}."""

    def druck_einstellen(self, teil: str, einstellungen: dict[str, Any] | None = None, zweck: str | None = None,
                         von: str = "agent", zuruecksetzen: bool = False) -> dict[str, Any]:
        """Feste Vorgabe wie PRINT_SETTINGS (Teil, Gruppe „g3“ oder Gruppenname), gespeichert in
        <projekt>/druck.json: {"ok", "meldung", "teile", "druck_json", "vorgaben", "gruppe"}"""

    def druck_export(self, ziel: str | None = None, platten: list[int] | None = None, teile: list[str] | None = None,
                     ohne: list[str] | None = None, filament: Any = None) -> dict[str, Any]:
        """3MF der angeordneten Platten für Bambu Studio (ohne Drucken): {"ok", "pfad", "platten", "hinweise",
        "geprueft", "ms", "materialien"}. Additiv: ``teile`` (nur diese) und ``ohne`` (nicht diese; Teilname,
        Baugruppen-Präfix, Gruppe "g3" oder Gruppenname; ``ohne`` gewinnt); im Ergebnis "teile", "weggelassen"
        ([{"name", "grund", "platte", "anzahl"}]), "leere_platten", je Datei "objekte" (Objektnamen im 3MF).
        Additiv ``filament`` (je Material ein Filament aus Kevins Liste, {"petg": "<id>"}, eine id oder ids); fehlt es,
        {"ok": false, "filament_frage": true, "vorschlaege", "error": "Frag Kevin nach dem Filament …"} und nichts
        wird geschrieben; im Ergebnis "filamente" je Material und je Datei "filament_id", "filament_basis",
        "abweichungen", "temperaturen"."""

    def filament_liste(self, material: str | None = None) -> dict[str, Any]:
        """Kevins Filamente (druck/filamente.py, Application Support): {"ok", "pfad", "filamente" (je Eintrag mit
        "anzeige", "preset_name", "abweichungen_text", "temperaturen", "probleme"), "zuletzt", "spulen"}"""

    def filament_define(self, hersteller: str, produkt: str, material: str, farbe: str | None = None,
                        durchmesser_mm: float = 1.75, basis: str | None = None,
                        abweichungen: list[dict[str, Any]] | None = None, farbe_hex: str | None = None,
                        id: str | None = None, preset_name: str | None = None, quelle: str | None = None,  # noqa: A002
                        ersetzen: bool = False) -> dict[str, Any]:
        """Filament in Kevins Liste anlegen oder (``ersetzen``) ändern, ohne Katalog-Freigabe: {"ok", "filament",
        "neu", "hinweise", "pfad"}"""

    # Phase 6: Zeichnungen (DOKUMENTE.md; Umsetzung in kevcad_kernel.zeichnung.laufzeit.ZeichnungRuntimeMixin)
    def drawings(self) -> dict[str, Any]:
        """Blätter des Projekts: {"ok", "ordner", "blaetter": [{"id", "titel", "inhalt", "format", "ausrichtung",
        "massstab", "ansichten", "masse", "verwaiste_masse" (ids), "eigene_masse", "pfad", "hinweise"}]}"""

    def drawing_create(self, teile: list[str] | None = None, art: str = "teil", format: str | None = None) \
            -> dict[str, Any]:  # noqa: A002
        """Blätter anlegen bzw. neu rechnen. Ohne teile: je Stücklistenposition eines gefertigten Teils ein Blatt und
        der Zusammenbau. {"ok", "ordner", "blaetter": [Zusammenfassung je Blatt mit "masse", "pruefung", "hinweise"]}"""

    def drawing_edit(self, blatt: str, ops: list[dict[str, Any]], von: str = "agent") -> dict[str, Any]:
        """Operationen wie DRAWING_EDIT. {"ok", "ergebnisse": [{"op", "ok", "id"?, "fehler"?}], "blatt": Zusammenfassung}"""

    def drawing_image(self, blatt: str, breite: int = 1800) -> dict[str, Any]:
        """Blatt als PNG (Kernel, aus den Vektoren): {"ok", "png", "breite", "hoehe", "blatt": Zusammenfassung}"""

    # Phase 6: Dokumente exportieren (DOKUMENTE.md, Anhang „Export“; umgesetzt in dokument_export.py, P6-A2)
    def dokument_export(self, bausteine: Any = None, ziel: str | None = None, drucken: bool = False,
                        timeout_s: float = 600.0) -> dict[str, Any]:
        """Die App baut das PDF aus den Bausteinen (Deckblatt, Stückliste, Teileliste, Einkaufsliste, Zuschnitt,
        Zeichnungen, Bauplan); ``drucken`` öffnet den Druckdialog. {"ok", "pfad", "seiten", "bausteine" (je {art,
        seiten}), "formate", "gedruckt", "hinweise", "ms", "angefragt", "vorlage"}"""
    # Versionen (PLAN-VERSIONEN.md, PROTOCOL.md „Versionen“; umgesetzt in kevcad_kernel.versionen.laufzeit)
    def versionen(self, limit: int | None = 50, variante: str | None = None) -> dict[str, Any]:
        """{"ok", "verfuegbar", "meldung", "variante", "varianten", "versionen" (neueste zuerst, siehe VERSIONEN),
        "gruppen", "anzahl", "meilensteine", "ungesichert"}"""

    def version_wiederherstellen(self, version: str, *, wer: str = "agent", warten: bool = True,
                                 timeout_s: float = 300) -> dict[str, Any]:
        """Dateien auf den Stand der Version, neue Version „Wiederhergestellt aus …“, neu rechnen.
        {"ok", "version", "aus", "gesichert", "unveraendert", "titel", "lauf" {"ok", "teile", "pruefung"}, "ms"}"""

    def versionen_vergleichen(self, a: str, b: str | None = None, *, zeigen: bool = True,
                              timeout_s: float = 300) -> dict[str, Any]:
        """{"ok", "a", "b", "aktuell", "zusammenfassung", "params", "teile", "stueckliste", "pruefung", "kennzahlen",
        "code" {"dateien", "diff", "gekuerzt"}, "geister", "hinweise", "ms"}; mit ``zeigen`` auch in der App."""

    def meilenstein(self, titel: str, notiz: str = "", version: str | None = None, *, wer: str = "agent",
                    entfernen: bool = False, ersetzen: bool = False) -> dict[str, Any]:
        """{"ok", "version", "titel", "notiz", "warnung"?, "geschuetzt"?, "hinweis"?}. Einen Meilenstein, den Kevin
        vergeben hat, überschreibt ein Agent nicht (``geschuetzt``: er bleibt, der Titel des Agenten wird Titel der
        Version), außer mit ``ersetzen`` (additiv) auf Kevins ausdrücklichen Wunsch."""

    def variante(self, aktion: str = "liste", name: str | None = None, von: str | None = None,
                 neuer_name: str | None = None, *, wer: str = "agent", warten: bool = True,
                 timeout_s: float = 300) -> dict[str, Any]:
        """aktion liste | anlegen | wechseln | umbenennen. {"ok", "aktion", "variante", "name", "von"?, "gesichert"?,
        "lauf"?, "varianten"}"""

    # Phase 4: Foto und Video als Referenz (additiv; PROTOCOL.md „Phase 4: Referenzen“, umgesetzt in
    # kevcad_kernel/referenz/laufzeit.py). Ablage in <projekt>/referenzen/<name>/.
    def referenzen(self, name: str | None = None, warten_s: float = 0.0) -> dict[str, Any]:
        """Referenzen des Projekts mit Zustand und Fortschritt (wie REF_LIST), je Referenz dazu "ordner",
        "capture_einstellung" und, falls vermessen, "messung_ergebnis" (wie REF_RESULT). Mit ``name`` und
        ``warten_s`` wartet es, bis der laufende Auftrag dieser Referenz fertig ist. {"ok", "projekt", "referenzen",
        "werkzeuge"}"""

    def referenz_video(self, pfad: str, name: str | None = None, masz: dict[str, float] | None = None,
                       auflage: bool = False, von: float | None = None, bis: float | None = None,
                       einstellung: str = "schnell", warten_s: float = 0.0) -> dict[str, Any]:
        """Referenznetz aus einem Handyvideo mit Apple Object Capture (kevcad-capture) im Hintergrund. ``masz`` setzt
        den Maßstab ({"laenge": 180}), ``auflage`` für Gegenstände auf einer Unterlage. {"ok", "name", "ordner",
        "zustand", "befehl", "referenz"? (mit warten_s)}"""

    def referenz_fotos(self, pfade: list[str], name: str | None = None) -> dict[str, Any]:
        """Fotos als Referenz ablegen (Arbeitsgröße). {"ok", "name", "ordner", "fotos"}"""

    def referenz_vermessen(self, quelle: str | None = None, freie_masse: list[str] | None = None,
                           bekannte_masse: dict[str, float] | None = None, bilder: int = 8,
                           vorgaben: dict[str, Any] | None = None, grenzen: dict[str, Any] | None = None,
                           maske: dict[str, Any] | None = None, von: float | None = None, bis: float | None = None,
                           kb_brennweite: float | None = None) -> dict[str, Any]:
        """Freie param()-Maße von model.py an der Referenz messen (fotomess, eigener Prozess; ein Bauer rechnet
        model.py mit überschriebenen param-Werten). Synchron. {"ok", "referenz", "stand", "masse": [{"name", "wert",
        "sigma", "start", "aenderung"}], "bekannt", "huelle", "grundkoerper", "teile", "empfehlungen", "bilder",
        "verworfen", "ueberdeckung", "kontrollbilder", "zeiten", "dauer_s", "lage_netz"}"""

    def referenz_fotoansicht(self, name: str | None = None, foto: int | str | None = None, satz: str | None = None,
                             modus: str | None = None, deckkraft: float | None = None, aus: bool = False,
                             bild: bool = False, breite: int = 1280) -> dict[str, Any]:
        """Fotoansicht in der App: Foto (1-basiert oder Name) durch die eingepasste Kamera hinter dem Modell, ``modus``
        "ueberlagern" | "differenz", ``deckkraft`` des Modells; ``aus`` schließt sie. Mit ``bild`` das Bild dazu.
        {"ok", "message", "png"?, "width"?, "height"?, "ueberdeckung"?, "foto"?}"""

    # Rest von Phase 4 (additiv, 22.10.2026; kevcad_kernel/referenz/laufzeit_rest.py)
    def referenz_abweichung(self, name: str | None = None, teile: list[str] | None = None,
                            grenze_mm: float | None = None, skala_mm: float | None = None, zeigen: bool = False,
                            auf: str = "modell", warten_s: float = 120.0) -> dict[str, Any]:
        """Abweichung Modell ↔ Referenznetz (positiv = Referenz außerhalb des Modells), wartet auf die Rechnung im
        Hintergrund. ``grenze_mm``/``skala_mm`` > 0 setzen, 0 = wieder automatisch; ``zeigen`` schaltet die Farbkarte
        in der App ein (``auf`` "modell" | "referenz"). {"ok", "referenz", "grenze_mm", "skala_mm", "skala_fest",
        "teile": [{"teil", "feld", "mittel_mm", "max_mm", "p95_mm", "versatz_mm", "abgedeckt", "punkte", "ort_max"}],
        "referenz_netz", "angelegt", "ms", "run", "hinweise", "gezeigt"?}"""

    def referenz_massstab(self, name: str | None = None, mm: float = 0.0, punkte: list[list[float]] | None = None,
                          kante: str | None = None) -> dict[str, Any]:
        """Maßstab nachträglich: zwei Punkte am Netz (Welt, mm) oder ``kante`` (laenge, breite, hoehe, grund_laenge,
        grund_breite oder ein gemessenes param) mit dem echten Maß ``mm``; Netz, Kameras und (bei einem gemessenen
        Maß) die Vermessung skalieren mit. {"ok", "referenz", "faktor", "faktor_gesamt", "ist_mm", "mm",
        "geaendert", "messung_skaliert", "punkte_am_netz", "text", "hinweise"}"""

    # Scan mit dem iPhone (additiv; SCAN.md, PLAN-SCAN.md, umgesetzt in kevcad_kernel/scan/laufzeit.py)
    def scans(self) -> dict[str, Any]:
        """Empfangene Scans (neueste zuerst) mit Zustand und Referenzen, dazu der Empfänger. {"ok", "ordner",
        "scans": [{"id", "name", "ordner", "empfangen", "erstellt", "geraet", "fotos", "videobilder", "objekt",
        "groesse_mb", "vorschau", "referenzen", "zustand"}], "empfaenger" {"laeuft", "port", "name", "dienst",
        "empfangen"}, "kevscan"}"""

    def scan_importieren(self, scan: str | None = None, name: str | None = None, schnell: bool = False,
                         warten_s: float = 0.0) -> dict[str, Any]:
        """Scan (Kennung, Name, „letzter“ oder Pfad eines Ordners/ZIPs) im Hintergrund auswerten (kevscan, eigener
        Prozess) und als Referenz ``<projekt>/referenzen/<name>/`` (art "scan") anlegen. {"ok", "name", "ordner",
        "scan", "zustand", "einstellung", "befehl", "referenz"? und "bericht"? (mit warten_s)}"""

    # SK-CAD: STL laden (stl/laufzeit.py) und über OctoPrint drucken (octoprint/laufzeit.py)
    def stl_laden(self, pfad: str, name: str | None = None, auf_bett: bool = True) -> dict[str, Any]:
        """STL nach ``<projekt>/stl/<name>.stl`` kopieren und als Referenz (art "stl") im Viewer zeigen. {"ok", "name",
        "stl", "referenz", "dreiecke", "punkte", "masz_mm", "min_mm", "max_mm", "flaeche_mm2", "volumen_cm3",
        "dicht", "offene_kanten", "mehrfache_kanten", "innen_nach_aussen", "hinweise"}"""

    def stl_liste(self) -> dict[str, Any]:
        """STL des offenen Projekts. {"ok", "stl": [{"name", "stl", "masz_mm", "dreiecke", "volumen_cm3", "dicht",
        "erstellt"}]}"""

    def octoprint_status(self) -> dict[str, Any]:
        """Nur lesend. {"ok", "einstellungen", "slicer_gefunden", "octoprint", "drucker" {"verbunden", "zustand",
        "flags", "duese", "bett"}, "auftrag" {"zustand", "datei", "fortschritt_prozent", "vergangen_s", "rest_s"}}"""

    def octoprint_einrichten(self, url: str | None = None, slicer: str | None = None,
                             profil: str | None = None) -> dict[str, Any]:
        """Einstellungen setzen bzw. prüfen (nie der API-Schlüssel). {"ok", "einstellungen", "schluessel_da",
        "slicer_gefunden", "hinweise"}"""

    def octoprint_drucken(self, datei: str, starten: bool = False, profil: str | None = None) -> dict[str, Any]:
        """STL slicen (PrusaSlicer) oder G-Code nehmen, hochladen und auswählen; ``starten`` druckt sofort. {"ok",
        "gestartet", "octoprint_datei", "gcode", "meldung", "drucker", "quelle", "druckzeit"?, "filament_g"?}"""

    def octoprint_starten(self, octoprint_datei: str) -> dict[str, Any]:
        """Hochgeladene Datei drucken. {"ok", "gestartet", "octoprint_datei", "meldung"}"""

    # Anzeige in der App, was der Agent gerade tut
    def set_agent_activity(self, text: str | None) -> None: ...

    def set_agent_connected(self, connected: bool) -> None: ...

    def set_agent_sessions(self, sessions: list[dict[str, Any]]) -> None:
        """Claude-Sitzungen, die Kev CAD bedienen (MIRROR.md, „Sitzungen“): je ``session_id``, ``aktiv``, ``seit``,
        ``taetigkeit``, optional ``zuletzt``; geht an die App im Rahmen AGENT als ``sessions``. Optional: der
        MCP-Server ruft es nur, wenn der Dienst es anbietet."""

    def close(self) -> None: ...


def create_service(socket_path: str, mcp_port: int) -> KernelService:
    """Startet die Laufzeit (Unix-Socket zur App, Rechenprozess) und liefert die Fassade."""
    from kevcad_kernel.runtime import create

    return create(socket_path=socket_path, mcp_port=mcp_port)
