"""MCP-Werkzeuge von Kev CAD (AP6): Werkzeuge, Ergebnisformat, Anweisungen, Verbindungs- und Tätigkeitsanzeige."""

from __future__ import annotations

from .instructions import INSTRUCTIONS, SERVER_NAME, SERVER_TITLE
from .tools import KevcadTools, register_tools

TOOL_NAMES: tuple[str, ...] = (
    "status",
    "project_open",
    "project_new",
    "run",
    "model_read",
    "model_write",
    "execute",
    "parts",
    "view",
    "focus",
    "visibility",
    "highlight",
    "section",
    "screenshot",
    "selection",
    "measure",
    "annotate",
    "clear_annotations",
    "export",
    "stock_search",
    "stock_get",
    "stock_define",
    "material_list",
    "material_define",
    "catalog_delete",
    "freigabe_anfragen",
    "bom",
    "bestand_liste",
    "bestand_eintragen",
    "einkaufsliste",
    "gebaut_buchen",
    "gedruckt_buchen",
    "buchung_rueckgaengig",
    "zukauf_anlegen",
    "zukauf_html",
    "cad_suchen",
    "cad_uebernehmen",
    "zukauf_liste",
    "pruefen",
    "montage_reihenfolge",
    "ansichten",
    "bedingungen",
    # Phase 5: Animation
    "animation_liste",
    "animation_abspielen",
    "animation_springen",
    "animation_video",
    "kollision_pruefen",
    # Phase 5: Kameras
    "kamera_liste",
    "kamera_info",
    "kamera_ansicht",
    "kamera_bild",
    "kamera_katalog",
    "kamera_vorschlag_aus_ansicht",
    # Phase 6: Bauplan
    "bauplan",
    "bauplan_bearbeiten",
    "bauplan_pruefen",
    # 3D-Druck
    "druckpruefung",
    # Phase 8: Drucken
    "drucker_status",
    "drucken",
    # SK-CAD: STL und OctoPrint
    "stl_laden",
    "stl_liste",
    "octoprint_status",
    "octoprint_einrichten",
    "octoprint_drucken",
    "octoprint_starten",
    # Phase 6: Zeichnungen
    "zeichnungen",
    "zeichnung_erstellen",
    "zeichnung_bearbeiten",
    "zeichnung_bild",
    # Phase 6: Dokumente exportieren
    "dokument_export",
    # Versionen
    "versionen",
    "version_wiederherstellen",
    "versionen_vergleichen",
    "meilenstein",
    "variante",
    # Phase 4: Referenzen
    "referenzen",
    "referenz_video",
    "referenz_fotos",
    "referenz_vermessen",
    "referenz_fotoansicht",
    "referenz_abweichung",
    "referenz_massstab",
    # Statik Stufe 1
    "statik",
    "szenario_rechnen",
    # Phase 7: Renderings
    "render",
)

__all__ = ["INSTRUCTIONS", "SERVER_NAME", "SERVER_TITLE", "TOOL_NAMES", "KevcadTools", "register_tools"]
