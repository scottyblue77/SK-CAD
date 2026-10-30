"""Attrappe des ``KernelService`` für die MCP-Tests: feste Antworten, zeichnet alle Aufrufe auf.

Wird auch von ``fake_kernel.py`` benutzt, das einen MCP-Server mit dieser Attrappe als eigenen Prozess startet
(für die Tests der stdio-Brücke).
"""

from __future__ import annotations

import struct
import threading
import time
import zlib
from typing import Any


def tiny_png(width: int = 4, height: int = 3, rgb: tuple[int, int, int] = (40, 120, 200)) -> bytes:
    """Kleines, gültiges PNG (einfarbig), damit Tests echte Bilddaten durchreichen."""

    def chunk(kind: bytes, data: bytes) -> bytes:
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    row = b"\x00" + bytes(rgb) * width
    raw = row * height
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


PNG = tiny_png()


def noisy_png(width: int = 1200, height: int = 900, seed: int = 7) -> bytes:
    """Großes, kaum komprimierbares PNG (einige MB), um Größenlimits auf dem Weg zu prüfen."""
    import random

    def chunk(kind: bytes, data: bytes) -> bytes:
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    rng = random.Random(seed)
    raw = b"".join(b"\x00" + rng.randbytes(width * 3) for _ in range(height))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 1)) + chunk(b"IEND", b""))

PARTS = [
    {
        "name": "Grundplatte", "bbox": {"min": [-60.0, -40.0, 0.0], "max": [60.0, 40.0, 5.0], "size": [120.0, 80.0, 5.0]},
        "volume": 47434.5, "area": 20345.2, "mass": 128.07, "material": "aluminium", "color": [0.7, 0.72, 0.75, 1.0],
        "faces": 8, "edges": 18, "triangles": 120, "visible": True,
    },
    {
        "name": "Halter/Lasche", "bbox": {"min": [-20.0, -2.5, 5.0], "max": [20.0, 2.5, 55.0], "size": [40.0, 5.0, 50.0]},
        "volume": 9000.0, "area": 4600.0, "mass": 24.3, "material": "aluminium", "color": [0.7, 0.72, 0.75, 1.0],
        "faces": 10, "edges": 24, "triangles": 200, "visible": True,
    },
]


MATERIALS = [
    {"id": "stahl-s235", "name": "Stahl S235", "gruppe": "Stahl", "dichte": 7.85, "farbe": "#8A9099",
     "preis_je_kg": 2.4, "preis_quelle": "Richtwert", "preis_stand": "2026-10", "aliase": ["stahl"],
     "ebene": "mitgeliefert"},
    {"id": "edelstahl-1.4301", "name": "Edelstahl 1.4301", "gruppe": "Edelstahl", "dichte": 7.9, "farbe": "#C9CED3",
     "ebene": "mitgeliefert"},
]

STOCK = [
    {"id": "vierkantrohr-en10219-40x40x3", "art": "vierkantrohr", "name": "Vierkantrohr 40 × 40 × 3",
     "norm": "DIN EN 10219", "masse": {"a": 40, "s": 3}, "material": "stahl-s235", "kg_je_m": 3.41,
     "stangenlaenge": 6000, "preis": {"je_m": 8.0, "quelle": "Richtwert", "stand": "2026-10"}, "ebene": "mitgeliefert",
     "berechnet": {"kg_je_m": 3.41, "querschnitt_mm2": 420.82, "preis_je_m": 8.0, "preis_text": "8,00 €/m"}},
    {"id": "rohr-en10220-42.4x2.0", "art": "rohr", "name": "Rohr 42,4 × 2,0", "norm": "DIN EN 10220",
     "masse": {"d": 42.4, "s": 2.0}, "material": "stahl-s235", "kg_je_m": 1.99, "stangenlaenge": 6000,
     "ebene": "mitgeliefert",
     "berechnet": {"kg_je_m": 1.99, "querschnitt_mm2": 253.84, "preis_je_m": None, "preis_text": None}},
]

BOM = {
    "lines": [
        {"pos": 1, "art": "vierkantrohr", "stock_id": "vierkantrohr-en10219-40x40x3",
         "benennung": "Vierkantrohr 40 × 40 × 3", "norm": "DIN EN 10219", "material": "Stahl S235", "laenge": 842.0,
         "gehrung": [0.0, 0.0], "masse_text": "842 mm", "anzahl": 4, "kg_je": 2.871, "kg": 11.485, "preis_je": 6.74,
         "preis": 26.94, "teile": ["Gestell/Bein vorn links"], "eigenteil": False},
        {"pos": 2, "art": "vierkantrohr", "stock_id": "vierkantrohr-en10219-40x40x3",
         "benennung": "Vierkantrohr 40 × 40 × 3", "norm": "DIN EN 10219", "material": "Stahl S235", "laenge": 800.0,
         "gehrung": [45.0, 45.0], "masse_text": "800 mm", "anzahl": 2, "kg_je": 2.728, "kg": 5.456, "preis_je": 6.4,
         "preis": 12.8, "teile": ["Gestell/Rahmen hinten", "Gestell/Rahmen vorn"], "eigenteil": False},
        {"pos": 3, "art": "eigenteil", "stock_id": None, "benennung": "Halter", "norm": None, "material": "aluminium",
         "laenge": None, "gehrung": [0.0, 0.0], "masse_text": "60 × 5 × 120 mm", "anzahl": 1, "kg_je": 0.096,
         "kg": 0.096, "preis_je": None, "preis": None, "teile": ["Halter"], "eigenteil": True},
    ],
    "cuts": [{"stock_id": "vierkantrohr-en10219-40x40x3", "benennung": "Vierkantrohr 40 × 40 × 3",
              "stangenlaenge": 6000, "saegeschnitt": 3, "stangen": [[842, 842, 842, 842, 800, 800]],
              "verschnitt_prozent": 17.2, "preis_stangen": 48.0}],
    "totals": {"kg": 17.037, "preis": 39.74, "positionen": 3, "teile": 7, "preis_hinweis": "Richtpreise, Stand 2026-10"},
    "warnings": ["Halter: Eigenteil ohne Preis (Material „aluminium“ steht nicht im Katalog)"],
}

# Bericht der Bedingungen wie die Nachricht CONSTRAINTS (PLAN-BEDINGUNGEN.md)
CONSTRAINTS = {
    "items": [
        {"id": "b1", "art": "auf", "gruppe": "montage", "symbol": "auf", "text": "Halter/Lasche.unten auf Grundplatte.oben",
         "teile": ["Halter/Lasche", "Grundplatte"], "stand": "verletzt", "soll": "Abstand 0 mm, Flächen gegenüber",
         "ist": "Abstand 2 mm (Luft 2 mm)", "abweichung": 2.0, "einheit": "mm", "punkte": [[0, 0, 12], [0, 0, 10]],
         "zeile": 14, "datei": "model.py", "schwere": "fehler",
         "loesung": "Halter/Lasche um 2 mm entlang −Z verschieben"},
        {"id": "b2", "art": "konzentrisch", "gruppe": "montage", "symbol": "konzentrisch",
         "text": "Halter/Bolzen.achse konzentrisch zu Halter/Lasche.Bohrung Ø6,6", "teile": ["Halter/Bolzen", "Halter/Lasche"],
         "stand": "erfuellt", "soll": "Achsen deckungsgleich", "ist": "Versatz 0 mm", "abweichung": 0.0, "einheit": "mm",
         "punkte": [[30, 0, 10], [30, 0, 10]], "zeile": 16, "datei": "model.py", "loesung": None},
    ],
    "teile": [{"name": "Halter/Lasche", "platziert": True, "frei": 0, "freiheitsgrade": [], "gelenke": [],
               "stand": "bestimmt", "bedingungen": ["b1", "b2"], "befestigt": True, "am_boden": True,
               "verbindungen": ["aufliegen"]}],
    "bewegungen": [],
    "befunde": [{"art": "bedingung", "pruefung": "bedingung", "teile": ["Halter/Lasche", "Grundplatte"],
                 "schwere": "fehler", "text": "Halter/Lasche.unten auf Grundplatte.oben: Abstand 2 mm (Luft 2 mm)",
                 "soll": "Abstand 0 mm, Flächen gegenüber", "ist": "Abstand 2 mm (Luft 2 mm)", "wert": 2.0,
                 "einheit": "mm", "ort": [0, 0, 12], "loesung": "Halter/Lasche um 2 mm entlang −Z verschieben",
                 "bedingung": "b1", "unterart": "auf", "zeile": 14}],
    "summe": {"gesamt": 2, "erfuellt": 1, "verletzt": 1, "ungeprueft": 0, "fehler": 1, "warnungen": 0, "hinweise": 0,
              "bewegungen": 0},
    "loese_ms": 1.2, "pruef_ms": 3.4,
}


PRUEFUNG = {
    "zusammenfassung": "1 Durchdringung", "zaehler": {"fehler": 1, "warnung": 0, "hinweis": 0},
    "befunde": [{"id": "du1", "art": "durchdringung", "teile": ["Halter/Lasche", "Halter/Grundplatte"],
                 "schwere": "fehler", "wert": {"volumen": 12.5, "tiefe": 0.5, "achse": [0, 0, 1]}, "ort": [0, 5, 2],
                 "text": "Halter/Lasche und Halter/Grundplatte durchdringen sich: 12,5 mm³, Tiefe etwa 0,5 mm.",
                 "loesung": "Halter/Lasche um 0,7 mm in +Z verschieben (dann 0,2 mm Spiel).", "geometrie": 0}],
    "montage": {"vollstaendig": True, "offen": [], "tests": 3, "abgebrochen": None, "schritte": [
        {"nr": 1, "teile": ["Halter/Grundplatte"], "name": "Halter/Grundplatte", "gruppe": False, "richtung": None,
         "richtung_text": "Grundteil", "werkzeug": None},
        {"nr": 2, "teile": ["Halter/Lasche"], "name": "Halter/Lasche", "gruppe": False, "richtung": [0, 0, -1],
         "richtung_text": "von oben", "werkzeug": None}]},
    "stand": {"boden_z": 0.0, "boden_erklaert": False, "gruppen": [
        {"teile": ["Halter/Grundplatte", "Halter/Lasche"], "masse_kg": 0.31, "kippwinkel": 24.5}]},
}
BESTAND = {"version": 1, "einstellungen": {"mindestrest_mm": 100, "saegeblatt_mm": 3},
           "posten": {"rohr-alfer-12x1": {"ganze": {"anzahl": 2, "laenge": 1000},
                                          "reste": [{"kennung": "R-0001", "laenge": 430, "ort": None,
                                                     "seit": "2026-10-21"}]}}}
EINKAUF = [{"id": "rohr-alfer-12x1", "benennung": "ALFER-Rundrohr 12 × 1", "menge": 1, "einheit": "Stange 1.000 mm",
            "preis_je": 3.9, "preis": 3.9, "link": None, "hinweis": None}]


class FakeService:
    """Implementiert ``KernelService`` mit festen Antworten.

    - ``calls``: Liste ``(methode, args, kwargs)`` aller Aufrufe (threadsicher).
    - ``delays``: Wartezeit je Methode in s, z. B. ``{"run": 1.0}`` für Nebenläufigkeitstests.
    - ``fail_run``: nächster Lauf scheitert mit Syntaxfehler in Zeile 12.
    - ``app_connected``: False lässt Ansichts- und Bildbefehle wie ohne App scheitern.
    """

    def __init__(self, project_name: str = "Wandhalter") -> None:
        self.calls: list[tuple[str, tuple[Any, ...], dict[str, Any]]] = []
        self.lock = threading.Lock()
        self.delays: dict[str, float] = {}
        self.fail_run = False
        self.raise_in: set[str] = set()
        self.app_connected = True
        self.project = {"path": f"/tmp/Kev CAD/{project_name}", "name": project_name,
                        "model": f"/tmp/Kev CAD/{project_name}/model.py"}
        self.code = "from build123d import *\nfrom kevcad import show, step, param\n"
        self.run_no = 0
        self.closed = False
        self.activity: list[str | None] = []
        self.connected: list[bool] = []
        self.sessions: list[list[dict[str, Any]]] = []  # jede gemeldete Sitzungsliste
        self.selection_refs = ["Halter/Lasche#f3", "Grundplatte#f0"]
        self.png = PNG  # Bilddaten für screenshot
        self.violations: list[str] = []  # Inventar-Regel: Teile ohne Lagerteil im nächsten Lauf

    # Hilfen -------------------------------------------------------------------------------------------------------

    def _record(self, name: str, *args: Any, **kwargs: Any) -> None:
        with self.lock:
            self.calls.append((name, args, kwargs))
        if name in self.raise_in:
            raise RuntimeError(f"Attrappe: {name} kaputt")
        delay = self.delays.get(name)
        if delay:
            time.sleep(delay)

    def calls_of(self, name: str) -> list[tuple[tuple[Any, ...], dict[str, Any]]]:
        with self.lock:
            return [(a, k) for n, a, k in self.calls if n == name]

    # KernelService ------------------------------------------------------------------------------------------------

    def status(self) -> dict[str, Any]:
        self._record("status")
        last = None
        if self.run_no:
            last = {"ok": True, "run": self.run_no, "duration_ms": 1234, "parts": PARTS, "steps": ["Grundplatte"],
                    "warnings": [], "params": {"breite": 120.0}}
        return {"project": self.project, "kernel": "ready", "app_connected": self.app_connected, "last_run": last,
                "selection": {"run": self.run_no, "refs": self.selection_refs},
                "inventar": {"regel": True, "verstoesse": list(self.violations)}}

    def project_open(self, path: str) -> dict[str, Any]:
        self._record("project_open", path)
        if path.endswith("/gibtsnicht"):
            return {"ok": False, "error": f"Kein Projektordner: {path}"}
        name = path.rstrip("/").rsplit("/", 1)[-1]
        self.project = {"path": path, "name": name, "model": f"{path}/model.py"}
        return {"ok": True, **self.project}

    def project_new(self, path: str, template: str = "example") -> dict[str, Any]:
        self._record("project_new", path, template)
        name = path.rstrip("/").rsplit("/", 1)[-1]
        self.project = {"path": path, "name": name, "model": f"{path}/model.py"}
        return {"ok": True, **self.project}

    def model_read(self) -> dict[str, Any]:
        self._record("model_read")
        return {"ok": True, "path": self.project["model"], "code": self.code}

    def model_write(self, code: str) -> dict[str, Any]:
        self._record("model_write", code)
        self.code = code
        return {"ok": True, "path": self.project["model"], "bytes": len(code.encode())}

    def run(self, params: dict[str, float] | None = None, slow_ms: int = 0, timeout_s: float = 120,
            titel: str | None = None) -> dict[str, Any]:
        extra: dict[str, Any] = {}
        if titel is not None:
            extra["titel"] = titel
        if timeout_s != 120:
            extra["timeout_s"] = timeout_s
        self._record("run", params, slow_ms, **extra)
        self.run_no += 1
        if self.fail_run:
            return {"ok": False, "run": self.run_no, "duration_ms": 12, "parts": [], "steps": ["Grundplatte"],
                    "warnings": [],
                    "error": {"message": "NameError: name 'platt' is not defined", "line": 12,
                              "excerpt": "  11 | platte = Box(breite, 80, dicke)\n> 12 | show(platt, \"Grundplatte\")",
                              "traceback": "Traceback ...", "hint": "Tippfehler im Variablennamen?"}}
        res = {"ok": True, "run": self.run_no, "duration_ms": 1234, "parts": PARTS, "steps": ["Grundplatte", "Lasche"],
               "warnings": ["Lasche: Fläche sehr klein"], "params": {"breite": (params or {}).get("breite", 120.0)},
               "bom": {"totals": BOM["totals"], "warnings": BOM["warnings"], "cuts": 1},
               "inventar_regel": True, "inventar_verstoesse": list(self.violations)}
        if titel is not None:  # Versionen: Titel des Agenten, der automatische als Zusatz
            res["version"] = {"nr": 4, "neu": True, "ms": 12.0, "titel": titel, "titel_auto": "breite 120 → 140"}
        return res

    def execute(self, code: str, timeout_s: float = 60) -> dict[str, Any]:
        self._record("execute", code)
        if "raise" in code:
            return {"ok": False, "stdout": "vorher\n", "error": "ZeroDivisionError: division by zero"}
        return {"ok": True, "stdout": "47434.5\n", "result": "8"}

    def parts(self) -> list[dict[str, Any]]:
        self._record("parts")
        return PARTS if self.run_no else []

    def measure(self, refs: list[str], show: bool = False) -> dict[str, Any]:
        self._record("measure", refs, show)
        return self._measure_result(refs)

    def _measure_result(self, refs: list[str]) -> dict[str, Any]:
        if any("#f99" in r for r in refs):
            return {"ok": False, "error": f"Unbekannte Referenz {refs[0]} (Lauf {self.run_no})"}
        if len(refs) == 2:
            return {"ok": True, "refs": refs, "run": self.run_no, "kind": "distance",
                    "values": {"distance": 12.5, "dx": 0.0, "dy": 0.0, "dz": 12.5, "parallel": True},
                    "points": [[0, 0, 5], [0, 0, 17.5]], "text": "Abstand 12,500 mm (dz 12,500)"}
        return {"ok": True, "refs": refs, "run": self.run_no, "kind": "face", "values": {"area": 200.0, "type": "plane"},
                "points": [[0, 0, 5]], "text": "Ebene, 200,000 mm²"}

    def selection(self) -> dict[str, Any]:
        self._record("selection")
        details = [self._measure_result([r]) for r in self.selection_refs]
        return {"run": self.run_no, "refs": list(self.selection_refs), "details": details}

    def view_command(self, cmd: str, args: dict[str, Any], timeout_s: float = 10) -> dict[str, Any]:
        self._record("view_command", cmd, args)
        if not self.app_connected:
            return {"ok": False, "error": "App nicht verbunden"}
        return {"ok": True}

    def screenshot(self, width: int = 1280, height: int = 800, source: str = "current", view: str | None = None,
                   hide_overlays: bool = False, timeout_s: float = 15) -> dict[str, Any]:
        self._record("screenshot", width, height, source, view, hide_overlays)
        if not self.app_connected:
            return {"ok": False, "error": "App nicht verbunden"}
        return {"ok": True, "png": self.png, "width": width, "height": height,
                "camera": {"projection": "orthographic", "position": [100.0, -100.0, 80.0], "target": [0.0, 0.0, 20.0]},
                "mm_per_px": 0.125}

    def export(self, formats: list[str], parts: list[str] | None = None) -> dict[str, Any]:
        self._record("export", formats, parts)
        return {"ok": True, "files": [f"{self.project['path']}/output/{self.project['name']}.{f}" for f in formats]}

    # Phase 2 -------------------------------------------------------------------------------------------------------

    def bom(self) -> dict[str, Any]:
        self._record("bom")
        if not self.run_no:
            return {"ok": False, "error": "Noch keine Stückliste: erst run aufrufen."}
        return {"ok": True, "run": self.run_no, **BOM}

    # Prüfung -------------------------------------------------------------------------------------------------

    def pruefen(self, warten_s: float = 120.0, endstand: bool = False) -> dict[str, Any]:
        self._record("pruefen", warten_s, endstand=endstand)
        if not self.run_no:
            return {"ok": False, "error": "Noch keine Prüfung: erst run aufrufen (geprüft wird nach jedem Lauf)."}
        return {"ok": True, "run": self.run_no, "state": "done", **PRUEFUNG}

    def ansichten(self, ansichten: list[dict[str, Any]], width: int = 640, height: int = 400,
                  timeout_s: float = 20) -> dict[str, Any]:
        self._record("ansichten", ansichten, width, height)
        if not self.app_connected:
            return {"ok": False, "error": "App nicht verbunden"}
        return {"ok": True, "bilder": [{"name": a.get("name"), "png": self.png, "width": width, "height": height,
                                        "camera": {"ansicht": True}, "ansicht_umgesetzt": True} for a in ansichten]}

    def stock_search(self, query: str = "", art: str | None = None, limit: int = 30) -> dict[str, Any]:
        self._record("stock_search", query, art)
        items = [it for it in STOCK if (art is None or it["art"] == art)
                 and all(w in (it["id"] + " " + it["name"]).lower().replace(",", ".").replace(" × ", "x")
                         for w in query.lower().replace(",", ".").split())]
        return {"ok": True, "items": items, "total": len(items)}

    def stock_get(self, stock_id: str) -> dict[str, Any]:
        self._record("stock_get", stock_id)
        for it in STOCK:
            if it["id"] == stock_id:
                return {"ok": True, "item": it, "material": MATERIALS[0], **it["berechnet"],
                        "beispiel": f"teil = lager.teil({stock_id!r})"}
        return {"ok": False, "error": f"Lagerteil {stock_id!r} gibt es nicht"}

    def stock_define(self, entry: dict[str, Any], ebene: str = "eigen") -> dict[str, Any]:
        self._record("stock_define", entry, ebene)
        if not entry.get("material"):
            return {"ok": False, "error": f"Lagerteil {entry.get('id')!r}: Feld material fehlt\n"
                                          f"Lagerteil {entry.get('id')!r}: masse.s fehlt (Zahl in mm)"}
        item = {**entry, "ebene": ebene}
        return {"ok": True, "item": item, "datei": "/tmp/katalog/eigene.json", "hinweise": [],
                "kg_je_m": 1.56, "querschnitt_mm2": 199.2, "preis_je_m": 14.5, "preis_text": "14,50 €/m"}

    def material_list(self, query: str = "") -> dict[str, Any]:
        self._record("material_list", query)
        mats = [m for m in MATERIALS if query.lower() in (m["id"] + " " + m["name"]).lower()]
        return {"ok": True, "materials": mats, "total": len(mats)}

    def material_define(self, entry: dict[str, Any], ebene: str = "eigen") -> dict[str, Any]:
        self._record("material_define", entry, ebene)
        return {"ok": True, "material": {**entry, "ebene": ebene}, "datei": "/tmp/katalog/eigene.json",
                "hinweise": ["preis_stand fehlte: 2026-10 eingetragen"]}

    def constraints(self, part: str | None = None) -> dict[str, Any]:
        self._record("constraints", part)
        if not self.run_no:
            return {"ok": False, "error": "Noch kein Bericht: erst run aufrufen."}
        return {"ok": True, "run": self.run_no, **CONSTRAINTS}

    def catalog_delete(self, kind: str, entry_id: str, ebene: str = "eigen") -> dict[str, Any]:
        self._record("catalog_delete", kind, entry_id, ebene)
        if entry_id == "gibtsnicht":
            return {"ok": False, "error": f"Lagerteil {entry_id!r} gibt es nicht."}
        return {"ok": True, "message": f"Lagerteil {entry_id!r} aus eigene.json gelöscht.",
                "datei": "/tmp/katalog/eigene.json"}

    def freigabe_anfragen(self, ids: list[str], grund: str = "", warten_s: float | None = None) -> dict[str, Any]:
        self._record("freigabe_anfragen", ids, grund, warten_s)
        if "gibtsnicht" in ids:
            return {"ok": False, "error": "'gibtsnicht' gibt es im Katalog nicht"}
        frei = [i for i in ids if i != "rohr-offen"]
        offen = [i for i in ids if i == "rohr-offen"]
        return {"ok": True, "anfrage": "F-0001", "freigegeben": frei, "abgelehnt": [], "offen": offen,
                "schon_frei": [], "dialog": "geschlossen" if offen else "entschieden", "gewartet_s": 3.2}

    # Bestand je Projekt ------------------------------------------------------------------------------------------

    def bestand_liste(self, stock_id: str | None = None) -> dict[str, Any]:
        self._record("bestand_liste", stock_id)
        return {"ok": True, "projekt": self.project["name"], "datei": f"{self.project['path']}/bestand.json",
                "stand": "2026-10-21T22:10:00", "bestand": BESTAND, "buchungen": [],
                "text": f"Bestand im Projekt „{self.project['name']}“:\n- ALFER-Rundrohr 12 × 1 (rohr-alfer-12x1): "
                        "2 ganze Stangen à 1000 mm; Reste: R-0001 430 mm"}

    def bestand_eintragen(self, stock_id: str | None = None, ganze: Any = None, reste: list[Any] | None = None,
                          reste_entfernen: list[str] | None = None, stueck: Any = None,
                          mindestrest_mm: float | None = None, reste_ersetzen: bool = False,
                          grund: str = "", **filament: Any) -> dict[str, Any]:
        self._record("bestand_eintragen", stock_id, ganze, reste, reste_entfernen, stueck, mindestrest_mm,
                     reste_ersetzen, grund, **{k: v for k, v in filament.items() if v is not None})
        if filament.get("material"):
            return {"ok": True, "buchung": {"id": "B-0001", "art": "eintrag", "zusammenfassung": "1 Spule neu"},
                    "aenderungen_text": [f"Filament PETG: Spule S-0001 {filament.get('spule') or ''}, "
                                         f"{filament.get('gramm')} von 1.000 g dazu"], "spulen": []}
        if stock_id == "gibtsnicht":
            return {"ok": False, "error": "Lagerteil 'gibtsnicht' gibt es im Katalog nicht"}
        lines = []
        if ganze is not None:
            lines.append(f"ALFER-Rundrohr 12 × 1 ({stock_id}): {ganze} ganze Stangen à 1000 mm dazu")
        for i, r in enumerate(reste or [], 1):
            lines.append(f"ALFER-Rundrohr 12 × 1 ({stock_id}): Rest R-{i:04d} ({r:g} mm) dazu")
        return {"ok": True, "buchung": {"id": "B-0001", "art": "eintrag", "zusammenfassung": "…"},
                "aenderungen_text": lines, "posten": {}}

    def einkaufsliste(self) -> dict[str, Any]:
        self._record("einkaufsliste")
        if not self.run_no:
            return {"ok": False, "error": "Noch keine Stückliste: erst run aufrufen."}
        return {"ok": True, "run": self.run_no, "einkaufsliste": EINKAUF, "einkauf_summe": 3.9, "fehlt": True,
                "text": "Einkaufsliste: 1 Position\n- 1 × Stange 1.000 mm ALFER-Rundrohr 12 × 1, 3,90 € je Einheit = "
                        "3,90 €\nSumme: 3,90 €",
                "csv": f"{self.project['path']}/output/{self.project['name']}-einkaufsliste.csv"}

    def gebaut_buchen(self, grund: str = "", run: int | None = None) -> dict[str, Any]:
        self._record("gebaut_buchen", grund)
        if not self.run_no:
            return {"ok": False, "error": "Noch keine Stückliste: erst rechnen (run), dann „gebaut“ buchen."}
        return {"ok": True, "buchung": {"id": "B-0002", "art": "gebaut",
                                        "zusammenfassung": "2 Reste weg, 1 Rest neu (R-0004 144 mm)"},
                "aenderungen_text": ["ALFER-Rundrohr 12 × 1 (rohr-alfer-12x1): Rest R-0002 (610 mm) weg"]}

    def gedruckt_buchen(self, grund: str = "", platten: list[int] | None = None, spule: str | None = None,
                        run: int | None = None) -> dict[str, Any]:
        self._record("gedruckt_buchen", grund, platten, spule)
        if not self.run_no:
            return {"ok": False, "error": "Keine Druckvorschau: erst rechnen (run), dann „gedruckt“ buchen."}
        return {"ok": True, "buchung": {"id": "B-0004", "art": "gedruckt",
                                        "zusammenfassung": "188,8 g Filament verbraucht"},
                "platten": platten or [1, 2], "filament_text": ["PETG: 188,8 g, davon 188,8 g aus S-0001"],
                "aenderungen_text": ["Filament PETG: 188,8 g von Spule S-0001 verbraucht"]}

    def buchung_rueckgaengig(self, buchung: str) -> dict[str, Any]:
        self._record("buchung_rueckgaengig", buchung)
        if buchung != "B-0002":
            return {"ok": False, "error": f"Buchung {buchung!r} gibt es nicht"}
        return {"ok": True, "buchung": {"id": "B-0003", "art": "rueckgaengig", "zusammenfassung": "1 Rest neu"},
                "aenderungen_text": ["ALFER-Rundrohr 12 × 1 (rohr-alfer-12x1): Rest R-0002 (610 mm) dazu"]}

    # Phase 3: Zukaufteile ----------------------------------------------------------------------------------------

    def zukauf_anlegen(self, url: str | None = None, mpn: str | None = None, gtin: str | None = None,
                       felder: dict[str, Any] | None = None, ebene: str = "projekt") -> dict[str, Any]:
        self._record("zukauf_anlegen", url, mpn, gtin, felder, ebene)
        text = " ".join(str(x) for x in (mpn, (felder or {}).get("name")) if x)
        if "ISO 4762" in text:
            return {"ok": True, "angelegt": False, "normteil": {"art": "schraube", "norm": "iso4762"},
                    "stock_id": "schraube-iso4762-m6", "beispiel": "schraube = lager.teil('schraube-iso4762-m6')",
                    "text": "ISO 4762 (Zylinderschraube mit Innensechskant) M6x20 ist ein Normteil und liegt im "
                            "Lagerkatalog als schraube-iso4762-m6"}
        if not (felder or {}).get("masse"):
            return {"ok": False, "error": "Zukaufteil 'alutec-05200': masse fehlt", "zu_pruefen": ["Maße"]}
        item = {"id": "alutec-05200", "art": "zukaufteil", "name": "ALUTEC Transportroller 05200",
                "hersteller": "ALUTEC", "mpn": "05200", "masse": felder["masse"], "status": "vorgeschlagen",
                "ebene": ebene}
        return {"ok": True, "angelegt": True, "item": item, "datei": "/tmp/Kev CAD/Wandhalter/katalog.json",
                "hinweise": ["Preis: brutto oder netto ist nicht angegeben"], "zu_pruefen": ["Preis"],
                "text": "ALUTEC Transportroller 05200 (ALUTEC 05200, 610 × 410 × 128 mm) angelegt (Vorschlag, wartet "
                        "auf Kevins Freigabe im Lagerkatalog)"}

    def zukauf_html(self, url: str | None, html: str, anlegen: bool = False, ebene: str = "projekt") -> dict[str, Any]:
        self._record("zukauf_html", url, len(html), anlegen, ebene)
        felder = {"name": "ALUTEC Transportroller", "hersteller": "ALUTEC", "mpn": "05200", "gtin": "4014688052004"}
        return {"ok": True, "felder": felder, "quellen": ["json-ld"], "zu_pruefen": ["Preis brutto oder netto"],
                "hinweise": [], "entwurf": {**felder, "id": "alutec-05200", "masse": {"l": 610, "b": 410, "h": 128},
                                            "preis": {"je_stueck": 24.99, "stand": "2026-10-21"}}}

    def cad_suchen(self, zukauf_id: str) -> dict[str, Any]:
        self._record("cad_suchen", zukauf_id)
        links = [{"titel": "Produktseite (CAD-Download oft dort)", "url": "https://shop.example/p/05200"},
                 {"titel": "3Dfindit (CADENAS/PARTcommunity): ALUTEC 05200",
                  "url": "https://www.3dfindit.com/de/?q=ALUTEC+05200"}]
        return {"ok": True, "zustand": "wartet_auf_cad", "cad_links": links, "erwartet": ["step", "stp", "zip"],
                "hinweise": [],
                "text": "CAD für ALUTEC Transportroller 05200: Kevin lädt die STEP-Datei herunter (Links)"}

    def cad_uebernehmen(self, zukauf_id: str, pfad: str | None = None, minuten: float = 30,
                        erzwingen: bool = False) -> dict[str, Any]:
        self._record("cad_uebernehmen", zukauf_id, pfad, minuten, erzwingen)
        if zukauf_id == "x":
            return {"ok": False, "error": "Keine neue STEP- oder ZIP-Datei der letzten 30 Minuten"}
        return {"ok": True, "zustand": "importiert", "item": {"id": zukauf_id, "status": "frei"},
                "datei": "/tmp/Kev CAD/Wandhalter/zukauf/alutec-05200/05200.step", "koerper": 5, "flaechen": 120,
                "grob": False, "pruefung": {"skala": 25.4, "korrigiert": [610, 410, 128], "soll": [610, 410, 128]},
                "hinweise": ["Modell war in Zoll gespeichert"],
                "text": "CAD für ALUTEC Transportroller 05200 übernommen: 05200.step, 5 Körper"}

    def zukauf_liste(self, query: str = "") -> dict[str, Any]:
        self._record("zukauf_liste", query)
        items = [{"id": "alutec-05200", "art": "zukaufteil", "name": "ALUTEC Transportroller 05200",
                  "hersteller": "ALUTEC", "mpn": "05200", "masse": {"l": 610, "b": 410, "h": 128},
                  "preis": {"je_stueck": 24.99, "brutto": True}, "ebene": "projekt", "status": "frei",
                  "cad_art": "vereinfacht", "zustand": "wartet_auf_cad"}]
        items = [it for it in items if query.lower() in (it["id"] + it["name"]).lower()]
        return {"ok": True, "items": items, "total": len(items)}

    # Phase 5: Animation ------------------------------------------------------------------------------------------

    ANIM = {"name": "Fahrt", "dauer": 8.0, "fps": 30.0, "bilder": 241, "teile": 12, "kamerafahrt": True, "spuren": 6,
            "standard": True}

    def animation_list(self) -> dict[str, Any]:
        self._record("animation_list")
        return {"ok": True, "animationen": [dict(self.ANIM)], "stand": {"name": "Fahrt", "zeit": 2.5, "spielt": False}}

    def animation_play(self, name: str | None = None, an: bool = True, schleife: bool = False,
                       geschwindigkeit: float = 1.0, von_vorn: bool = False) -> dict[str, Any]:
        self._record("animation_play", name, an, schleife, geschwindigkeit, von_vorn)
        if name not in (None, "Fahrt"):
            return {"ok": False, "error": f"Animation {name!r} gibt es nicht. Vorhanden: 'Fahrt'"}
        return {"ok": True, "name": "Fahrt", "an": an, "schleife": schleife, "geschwindigkeit": geschwindigkeit,
                "dauer": 8.0}

    def animation_seek(self, zeit: float, name: str | None = None) -> dict[str, Any]:
        self._record("animation_seek", zeit, name)
        if zeit > 8:
            return {"ok": False, "error": f"zeit {zeit:g} s liegt außerhalb der Animation 'Fahrt' (0 bis 8 s)"}
        return {"ok": True, "name": "Fahrt", "zeit": zeit, "bild": int(round(zeit * 30)), "dauer": 8.0}

    def animation_video(self, name: str | None = None, breite: int = 1920, hoehe: int | None = None,
                        fps: float | None = None, kamera: str | None = None, format: str = "mp4") -> dict[str, Any]:  # noqa: A002
        self._record("animation_video", name, breite, hoehe, fps, kamera, format)
        if not self.app_connected:
            return {"ok": False, "error": "App nicht verbunden"}
        return {"ok": True, "name": "Fahrt", "path": f"{self.project['path']}/output/animationen/Fahrt.mp4",
                "width": breite, "height": breite * 9 // 16, "fps": fps or 30.0, "bilder": 241, "format": format,
                "ms": 12000}

    def collision_check(self, name: str | None = None, schritt: int = 3) -> dict[str, Any]:
        self._record("collision_check", name, schritt)
        return {"ok": True, "name": "Fahrt", "run": self.run_no, "kollisionen": [
            {"teile": ["Bowlingball", "Pfosten"], "von": 5.1, "bis": 5.6, "zeit": 5.4, "bild": 162, "tiefe": 12.5,
             "volumen": 830.0, "ort": [1500.0, -340.0, 100.0], "bilder": [153, 156, 159, 162, 165, 168]}],
                "geprueft": {"paare": 40, "geprueft_bilder": 81, "schritt": schritt, "ms": 640.0}}

    # 3D-Druck ------------------------------------------------------------------------------------------------------

    DRUCK_CHECK = {
        "run": 3, "state": "done",
        "befunde": [
            {"id": "dr1", "art": "druck_ueberhang", "teile": ["Halter/Clip (Druck)"], "schwere": "warnung",
             "text": "Halter/Clip (Druck): Überhang 70° an Fläche #f4 bei (1; 2; 3).",
             "loesung": "Fase 45° statt Rundung.", "ort": [1.0, 2.0, 3.0],
             "wert": {"pruefung": "druck", "druckart": "ueberhang", "flaechen": [4], "refs": ["Halter/Clip (Druck)#f4"]},
             "geometrie": None},
        ],
        "druck": {
            "drucker": "Bambu Lab P1P", "neu_geprueft": 1, "aus_zwischenspeicher": 0, "dauer_ms": 85.0,
            "teile": {"Halter/Clip (Druck)": {
                "material": "petg", "material_name": "PETG", "ok": True,
                "zaehler": {"fehler": 0, "warnung": 1, "hinweis": 0},
                "zusammenfassung": "1 Warnung (PETG, Bambu Lab P1P)",
                "ausrichtung": {"text": "−Z-Seite unten", "unten": [0, 0, -1], "drehung": [0, 0, 0],
                                "liegt_auf": "Halter/Clip (Druck)#f0", "automatisch": True, "vorgabe": None,
                                "begruendung": "Wie modelliert liegt das Teil am besten; Stützfläche ca. 12 mm².",
                                "bezug": "druckteil"},
                "kennzahlen": {"abmessungen_mm": [20.0, 10.0, 8.0], "schichten": 40, "stuetzflaeche_mm2": 12.0,
                               "auflageflaeche_mm2": 200.0, "volumen_cm3": 1.2, "masse_voll_g": 1.5,
                               "bauraum_ausnutzung_prozent": 7.8},
                "zwischenspeicher": False, "ms": 85.0}},
            "materialien": {"petg": {"name": "PETG", "druckhinweise": ["PETG: Düse 240–260 °C, Bett 70–80 °C."],
                                     "festigkeit": "Festigkeit: quer zu den Schichten hält PETG nur etwa 50 %."}},
        },
    }

    def druckpruefung(self, teil: str | None = None) -> dict[str, Any]:
        from kevcad_kernel.druck.bericht import druck_auszug

        self._record("druckpruefung", teil)
        if not self.run_no:
            return {"ok": False, "error": "Noch keine Prüfung: erst run aufrufen."}
        return druck_auszug(self.DRUCK_CHECK, teil, ["Halter/Clip (Druck)", "Halter/Platte"])

    # Statik Stufe 1 ------------------------------------------------------------------------------------------------

    def statik(self, szenario: str | None = None) -> dict[str, Any]:
        from kevcad_kernel.protocol import statik_beispiel
        from kevcad_kernel.statik.laufzeit import _szenario_auszug

        self._record("statik", szenario)
        if not self.run_no:
            return {"ok": False, "error": "Noch keine Statik: erst run aufrufen."}
        b = statik_beispiel()
        base = {"ok": True, "run": self.run_no, "aktiv": b["aktiv"], "grenzen": b["grenzen"],
                "vereinfachungen": b["vereinfachungen"], "modell": b["modell"], "ms": b["ms"],
                "ueberdimensioniert": []}
        if szenario:
            e = next((x for x in b["szenarien"] if x["name"] == szenario), None)
            if e is None:
                return {"ok": False, "error": f"Szenario {szenario!r} gibt es nicht"}
            return {**base, "szenario": _szenario_auszug(e)}
        return {**base, "szenarien": [_szenario_auszug(e, detail=False) for e in b["szenarien"]]}

    def szenario_rechnen(self, name: str, beschleunigung: Any = None, neigung: float | None = None,
                         richtung: Any = None, lasten: list[dict[str, Any]] | None = None, stoss: float | None = None,
                         ziel: float | None = None, beschreibung: str | None = None, zeigen: bool = True
                         ) -> dict[str, Any]:
        from kevcad_kernel.protocol import statik_beispiel
        from kevcad_kernel.statik.laufzeit import _szenario_auszug

        self._record("szenario_rechnen", name, lasten)
        if not self.run_no:
            return {"ok": False, "error": "Noch kein Statikmodell: erst run aufrufen."}
        e = dict(statik_beispiel()["szenarien"][1], name=name)
        return {"ok": True, "run": self.run_no, "szenario": _szenario_auszug(e), "gezeigt": zeigen, "ms": 120.0,
                "grenzen": statik_beispiel()["grenzen"], "vereinfachungen": []}

    # Statik Stufe 2 -------------------------------------------------------------------------------------------------

    def dynamik(self, name: str, geschwindigkeit: float | None = None, bremsen: Any = None, dauer: float | None = None,
                neigung: float | None = None, richtung: Any = None, stoss: float | None = None,
                animation: str | None = None, antrieb: str | None = None, angriff: Any = None,
                fahrtrichtung: Any = None, lasten: list[dict[str, Any]] | None = None, suche: bool = True,
                zeigen: bool = True, beschreibung: str | None = None) -> dict[str, Any]:
        from kevcad_kernel.protocol import statik_beispiel_ablauf
        from kevcad_kernel.statik.laufzeit import _szenario_auszug

        self._record("dynamik", name, geschwindigkeit, bremsen)
        if not self.run_no:
            return {"ok": False, "error": "Noch kein Statikmodell: erst run aufrufen."}
        b = statik_beispiel_ablauf()
        e = dict(b["szenarien"][2], name=name)
        return {"ok": True, "run": self.run_no, "szenario": _szenario_auszug(e), "ablauf": e["ablauf"],
                "animation": e["ablauf"]["animation"], "gezeigt": zeigen, "befunde": [],
                "grenzen": b["grenzen"], "vereinfachungen": [], "ms": {"gesamt": 1800.0, "prozess": 1500.0}}

    def dynamik_grenze(self, ohne: str = "beides", bremsen: Any = "abrupt", geschwindigkeit: float = 1.0,
                       name: str | None = None) -> dict[str, Any]:
        res = self.dynamik(name or "Grenze", geschwindigkeit=geschwindigkeit, bremsen=bremsen)
        if not res.get("ok"):
            return res
        return {**res, "grenzen_suche": {"ladung": [{"name": "Bowlingball", "v_grenze": 1.12}],
                                         "kippen": {"v_abheben": 0.29, "a_abheben": 2.46, "a_kipp_hand": 14.1,
                                                    "a_abheben_ohne_ladung": 13.92}}}

    # Statik Stufe 3 -------------------------------------------------------------------------------------------------

    def festigkeit(self, teil: str | None = None, szenario: str | None = None, fein: bool = False,
                   ablauf: bool = False, zeigen: bool = True, **s4: Any) -> dict[str, Any]:
        from kevcad_kernel.protocol import statik_beispiel_festkoerper, statik_beispiel_s4

        self._record("festigkeit", teil, szenario, fein, ablauf, *([s4] if s4 else []))
        if not self.run_no:
            return {"ok": False, "error": "Noch keine Statik: erst run aufrufen."}
        if s4:  # Stufe 4 (CalculiX)
            b = statik_beispiel_s4()
            e = next(x for x in b["szenarien"] if x["name"] == "Haken 2 kg (Kontakt)")
            return {"ok": True, "run": self.run_no, "verfahren": "ccx", "teile": e["festkoerper"]["teile"],
                    "faelle": [], "szenarien": [{"name": e["name"], "ampel": e["ampel"], "text": e["text"]}],
                    "befunde": [], "hinweise": [], "grenzen": b["grenzen"], "ms": {"gesamt": 19000.0,
                                                                                  "prozess": 18400.0},
                    "gezeigt": zeigen}
        b = statik_beispiel_festkoerper()
        e = next(x for x in b["szenarien"] if x["name"] == "Haken 2 kg")
        return {"ok": True, "run": self.run_no, "teile": e["festkoerper"]["teile"], "faelle": [],
                "szenarien": [{"name": e["name"], "ampel": e["ampel"], "text": e["text"]}], "befunde": [],
                "hinweise": [], "grenzen": b["grenzen"], "ms": {"gesamt": 2100.0, "prozess": 1960.0},
                "gezeigt": zeigen}

    def festigkeit_abbrechen(self) -> dict[str, Any]:
        self._record("festigkeit_abbrechen")
        return {"ok": True, "abgebrochen": False, "szenarien": []}

    # Topologieoptimierung -------------------------------------------------------------------------------------------

    def topologie_optimieren(self, teil: str | None = None, szenario: str | None = None, behalten: float | None = None,
                             schutz: list | None = None, ueberhang: bool | None = None, fein: bool | None = None,
                             steg: float | None = None, bett: bool | None = None, neu: bool = False,
                             warten: bool = False, lager: str | None = None) -> dict[str, Any]:
        self._record("topologie_optimieren", teil, szenario, behalten, ueberhang, fein)
        if not self.run_no:
            return {"ok": False, "error": "Noch kein Statikmodell: erst run aufrufen."}
        if warten:
            return self.topologie_ergebnis()
        return {"ok": True, "stand": "laeuft", "teil": teil or "Halter", "szenario": szenario or "Bolzen 50 N",
                "text": f"{teil or 'Halter'}: Topologieoptimierung läuft im Hintergrund"}

    def topologie_ergebnis(self, warten_s: float = 0.0) -> dict[str, Any]:
        from kevcad_kernel.protocol import topo_beispiel

        self._record("topologie_ergebnis", warten_s)
        st = topo_beispiel("done")
        return {"ok": True, **st, "text": st["text_lang"]}

    def topologie_abbrechen(self) -> dict[str, Any]:
        self._record("topologie_abbrechen")
        return {"ok": True, "abgebrochen": False}

    def topologie_uebernehmen(self, variante: str | None = None, warten: bool = False) -> dict[str, Any]:
        self._record("topologie_uebernehmen", variante)
        return {"ok": True, "variante": variante or "Topologie Halter 42 %",
                "zeile": "halter = topologie.optimieren(halter, szenario='Bolzen 50 N', behalten=0.42)",
                "text": "Als Variante übernommen"}

    # Bereich „Simulation“ ------------------------------------------------------------------------------------------

    def simulation_liste(self) -> dict[str, Any]:
        from kevcad_kernel.protocol import sim_beispiel

        self._record("simulation_liste")
        return {"ok": True, **sim_beispiel()}

    def simulation_aendern(self, ops: list, basis: int | None = None, von: str = "agent") -> dict[str, Any]:
        self._record("simulation_aendern", ops, basis, von)
        if not ops:
            return {"ok": False, "error": "Keine Änderung angegeben (ops: Liste von Operationen)"}
        return {"ok": True, "stand": 4, "meldungen": [f"{op.get('op')} ausgeführt" for op in ops], "gerechnet": True,
                "lastfaelle": [], "lager": [], "hinweise": []}

    def simulation_rechnen(self, was: str, lastfall: str | None = None, teil: str | None = None, fein: bool = False,
                           grenze: str | None = None, warten: bool = True, von: str = "agent", *,
                           verfahren: str | None = None) -> dict[str, Any]:
        from kevcad_kernel.protocol import sim_job_beispiel

        if verfahren:
            self._record("simulation_rechnen", was, lastfall, teil, fein, grenze, verfahren)
        else:
            self._record("simulation_rechnen", was, lastfall, teil, fein, grenze)
        j = sim_job_beispiel("done")
        return {"ok": True, "auftrag": j["auftrag"], "text": j["text"], "ergebnis": j["ergebnis"]}

    # Phase 8: Drucken -----------------------------------------------------------------------------------------------

    def drucker_status(self) -> dict[str, Any]:
        from kevcad_kernel.protocol import drucker_status_beispiel

        self._record("drucker_status")
        return {"ok": True, **drucker_status_beispiel()}

    def drucken(self, platten: list[int] | None = None, weg: str = "a", grund: str | None = None) -> dict[str, Any]:
        self._record("drucken", platten, weg, grund)
        if weg == "b":
            return {"ok": False, "error": "Weg B ist nicht eingestellt (Kevin hat Weg A gewählt)."}
        return {"ok": True, "auftrag": "j-1", "zustand": "wartet", "weg": weg, "platten": list(platten or []),
                "meldung": "Der Dialog „Drucken …“ ist in Kev CAD offen. Es geschieht nichts, bis Kevin dort "
                           "bestätigt; den Stand zeigt drucker_status."}

    # SK-CAD: STL und OctoPrint ------------------------------------------------------------------------------------

    def stl_laden(self, pfad: str, name: str | None = None, auf_bett: bool = True) -> dict[str, Any]:
        self._record("stl_laden", pfad, name, auf_bett)
        return {"ok": True, "name": name or "Teil", "stl": "/tmp/p/stl/Teil.stl", "dreiecke": 12, "punkte": 8,
                "masz_mm": [10.0, 20.0, 30.0], "volumen_cm3": 6.0, "dicht": True, "hinweise": []}

    def stl_liste(self) -> dict[str, Any]:
        self._record("stl_liste")
        return {"ok": True, "stl": [{"name": "Teil", "stl": "/tmp/p/stl/Teil.stl", "masz_mm": [10.0, 20.0, 30.0],
                                     "dreiecke": 12, "volumen_cm3": 6.0, "dicht": True}]}

    def octoprint_status(self) -> dict[str, Any]:
        self._record("octoprint_status")
        return {"ok": True, "octoprint": "1.10.3", "einstellungen": {"url": "http://192.168.1.233"},
                "drucker": {"verbunden": True, "zustand": "Operational", "duese": {"ist": 24.0, "soll": 0},
                            "bett": {"ist": 23.0, "soll": 0}},
                "auftrag": {"zustand": "Operational", "datei": None}}

    def octoprint_einrichten(self, url: str | None = None, slicer: str | None = None,
                             profil: str | None = None) -> dict[str, Any]:
        self._record("octoprint_einrichten", url, slicer, profil)
        return {"ok": True, "einstellungen": {"url": url or "http://192.168.1.233", "profil": profil},
                "schluessel_da": False, "slicer_gefunden": None, "hinweise": ["Schlüssel fehlt"]}

    def octoprint_drucken(self, datei: str, starten: bool = False, profil: str | None = None) -> dict[str, Any]:
        self._record("octoprint_drucken", datei, starten, profil)
        return {"ok": True, "gestartet": starten, "octoprint_datei": "sk-cad/Teil.gcode", "gcode": "/tmp/Teil.gcode",
                "meldung": "Gestartet." if starten else "Hochgeladen, nicht gestartet.", "druckzeit": "1h 2m"}

    def octoprint_starten(self, octoprint_datei: str) -> dict[str, Any]:
        self._record("octoprint_starten", octoprint_datei)
        return {"ok": True, "gestartet": True, "octoprint_datei": octoprint_datei, "meldung": "Gestartet."}

    # Druckvorschau (DRUCKVORSCHAU.md) ----------------------------------------------------------------------------------

    def druckvorschau(self, detail: bool = False) -> dict[str, Any]:
        from kevcad_kernel.druck.vorschau import kurz
        from kevcad_kernel.protocol import druckvorschau_beispiel

        self._record("druckvorschau", detail)
        if not self.run_no:
            return {"ok": False, "error": "Noch kein Lauf: erst run aufrufen."}
        v = druckvorschau_beispiel(run=self.run_no)
        return {"ok": True, **(v if detail else kurz(v))}

    def druck_einstellen(self, teil: str, einstellungen: dict[str, Any] | None = None, zweck: str | None = None,
                         von: str = "agent", zuruecksetzen: bool = False) -> dict[str, Any]:
        self._record("druck_einstellen", teil, einstellungen, zweck, von, zuruecksetzen)
        if teil not in ("g1", "Stangenhalter (Druck)"):
            return {"ok": False, "error": f"Druckteil oder Gruppe {teil!r} nicht in der Druckvorschau"}
        return {"ok": True, "meldung": "Stangenhalter (Druck): Wände 5 (fest, druck.json, 4 Teile)",
                "teile": ["Kugelschieber/Stangenhalter vorn links (Druck)"], "druck_json": "druck.json",
                "vorgaben": {}}

    def druck_export(self, ziel: str | None = None, platten: list[int] | None = None, teile: list[str] | None = None,
                     ohne: list[str] | None = None, filament: Any = None) -> dict[str, Any]:
        self._record("druck_export", ziel, platten, teile, ohne, filament)
        if not filament:
            return {"ok": False, "filament_frage": True, "platten": [],
                    "vorschlaege": {"petg": {"zuletzt": None, "spulen": [], "liste": [
                        {"id": "polymaker-polylite-petg-gelb", "name": "Polymaker PolyLite PETG gelb (1,75 mm)"}]}},
                    "error": "Frag Kevin nach dem Filament, bevor du exportierst (es wurde nichts geschrieben)."}
        if ohne and "Nix" in ohne:
            return {"ok": False, "error": "ohne: 'Nix' ist kein Druckteil der Druckvorschau", "platten": []}
        weg = [{"name": n, "grund": "ohne", "platte": 1, "anzahl": 1} for n in ohne or []]
        return {"ok": True, "pfad": ziel or "Kugelschieber-druck.3mf", "platten": platten or [1, 2],
                "hinweise": ["In Bambu Studio geprüft: 2 Platten, 13 Teile."], "geprueft": True, "ms": 1200,
                "teile": ["Kugelschieber/Stangenhalter vorn links (Druck)"], "weggelassen": weg,
                "leere_platten": [],
                "dateien": [{"pfad": ziel or "Kugelschieber-druck.3mf", "material": "petg",
                             "filament": "Bambu PETG Basic @BBL X1C", "platten": platten or [1, 2],
                             "objekte": ["Kugelschieber/Stangenhalter vorn links (Druck)"]}]}

    def filament_liste(self, material: str | None = None) -> dict[str, Any]:
        self._record("filament_liste", material)
        return {"ok": True, "pfad": "filamente.json", "zuletzt": {"petg": "polymaker-polylite-petg-gelb"},
                "spulen": [], "filamente": [{
                    "id": "polymaker-polylite-petg-gelb", "anzeige": "Polymaker PolyLite PETG gelb (1,75 mm)",
                    "material": "petg", "preset": {"name": "Polymaker PolyLite PETG gelb (Kev CAD)",
                                                   "basis": "PolyLite PETG @BBL P1P", "abweichungen": []},
                    "preset_name": "Polymaker PolyLite PETG gelb (Kev CAD)", "abweichungen_text": "keine Abweichungen",
                    "temperaturen": {"duese": 255, "platte": 80, "platte_name": "Textured PEI Plate"},
                    "probleme": []}]}

    def filament_define(self, hersteller: str, produkt: str, material: str, farbe: str | None = None,
                        durchmesser_mm: float = 1.75, basis: str | None = None,
                        abweichungen: list[dict[str, Any]] | None = None, farbe_hex: str | None = None,
                        id: str | None = None, preset_name: str | None = None, quelle: str | None = None,  # noqa: A002
                        ersetzen: bool = False) -> dict[str, Any]:
        self._record("filament_define", hersteller, produkt, material, farbe, basis, abweichungen)
        if any(not a.get("quelle") for a in abweichungen or []):
            return {"ok": False, "error": "abweichungen[0]: quelle fehlt"}
        return {"ok": True, "neu": True, "hinweise": [], "filament": {
            "id": "x", "anzeige": f"{hersteller} {produkt}", "preset": {"name": f"{hersteller} {produkt} (Kev CAD)",
                                                                        "basis": basis or "Generic PETG @BBL P1P"}}}

    # Phase 6: Zeichnungen -------------------------------------------------------------------------------------------

    BLATT = {"id": "seitenstange", "ok": True, "neu": True, "titel": "Seitenstange", "inhalt": {"art": "teil",
             "teile": ["Gestell/Seitenstange"]}, "format": "A4 quer", "massstab": "1:1",
             "ansichten": [{"id": "v1", "art": "vorn"}],
             "masse": [{"id": "m1", "art": "linear", "ansicht": "v1", "text": "1000", "wert": 1000.0, "quelle": "auto",
                        "verwaist": False, "bezuege": ["seite:x-", "seite:x+"]},
                       {"id": "m2", "art": "bohrung", "ansicht": "v1", "text": "3× Ø4,2", "wert": None,
                        "quelle": "auto", "verwaist": False, "bezuege": ["bohrung:1"]}],
             "verwaist": [], "allgemein": ["Halbzeug: Alurohr 12 × 1,0"], "hinweise": [], "pruefung": [], "ms": 80.0}

    def drawings(self) -> dict[str, Any]:
        self._record("drawings")
        return {"ok": True, "ordner": "/tmp/p/dokumente/zeichnungen", "blaetter": [dict(self.BLATT)]}

    def drawing_create(self, teile: list[str] | None = None, art: str = "teil", format: str | None = None) \
            -> dict[str, Any]:  # noqa: A002
        self._record("drawing_create", teile, art, format)
        return {"ok": True, "ordner": "/tmp/p/dokumente/zeichnungen", "blaetter": [dict(self.BLATT)]}

    def drawing_edit(self, blatt: str, ops: list[dict[str, Any]], von: str = "agent") -> dict[str, Any]:
        self._record("drawing_edit", blatt, ops, von)
        if blatt != "seitenstange":
            return {"ok": False, "error": f"Blatt {blatt!r} gibt es nicht"}
        return {"ok": True, "ergebnisse": [{"op": o.get("op"), "ok": True, "id": "m3"} for o in ops],
                "blatt": dict(self.BLATT)}

    def drawing_image(self, blatt: str, breite: int = 1800) -> dict[str, Any]:
        self._record("drawing_image", blatt, breite)
        return {"ok": True, "png": PNG, "breite": breite, "hoehe": int(breite * 210 / 297), "blatt": dict(self.BLATT)}

    # Dokumente exportieren (P6-A2) ---------------------------------------------------------------------------------

    def dokument_export(self, bausteine: Any = None, ziel: str | None = None, drucken: bool = False,
                        timeout_s: float = 600.0) -> dict[str, Any]:
        self._record("dokument_export", bausteine, ziel, drucken)
        if bausteine == ["gibtsnicht"]:
            return {"ok": False, "error": "Baustein 'gibtsnicht' unbekannt"}
        return {"ok": True, "pfad": ziel or "/tmp/p/output/Halter-dokumente.pdf", "seiten": 9,
                "bausteine": [{"art": "deckblatt", "seiten": 1}, {"art": "stueckliste", "seiten": 2},
                              {"art": "bauplan", "seiten": 6}],
                "formate": {"A4 hoch": 9}, "gedruckt": "Druckdialog geöffnet" if drucken else None, "hinweise": [],
                "ms": 1840, "vorlage": None}
    # Versionen ----------------------------------------------------------------------------------------------------

    VERSIONEN = [
        {"nr": 3, "zeit": "2026-10-21T14:32:10", "ts": 1792586000, "wer": "agent", "wer_text": "Agent · 3f2a9c",
         "quelle": "lauf", "titel": "Geändert: model.py", "aktuell": True, "gruppe": None,
         "meilenstein": {"titel": "Halter fertig", "notiz": "Bohrungen M6"},
         "kennzahlen": {"teile": 4, "masse_kg": 1.25, "kosten": 12.4, "fehler": 0}, "params": {"hoehe": 140}},
        {"nr": 2, "zeit": "2026-10-21T14:20:00", "ts": 1792585200, "wer": "kevin", "wer_text": "Kevin",
         "quelle": "lauf", "titel": "Geändert: model.py", "aktuell": False, "gruppe": None, "meilenstein": None,
         "kennzahlen": {"teile": 3, "masse_kg": 1.1}, "params": {"hoehe": 120}},
    ]

    def versionen(self, limit: int | None = 50, variante: str | None = None) -> dict[str, Any]:
        self._record("versionen", limit, variante)
        return {"ok": True, "verfuegbar": True, "variante": "haupt", "anzahl": 2, "meilensteine": 1,
                "ungesichert": False, "gruppen": [],
                "varianten": [{"id": "haupt", "name": "Hauptstand", "aktuell": True, "versionen": 2}],
                "versionen": [dict(v) for v in self.VERSIONEN]}

    def version_wiederherstellen(self, version: str, **kw: Any) -> dict[str, Any]:
        self._record("version_wiederherstellen", version)
        if str(version).lstrip("Vv") not in ("1", "2", "3"):
            return {"ok": False, "error": f"Version {version!r} gibt es nicht (zuletzt: V1, V2, V3)."}
        return {"ok": True, "version": 4, "aus": int(str(version).lstrip("Vv")), "gesichert": None,
                "unveraendert": False, "titel": f"Wiederhergestellt aus {version}",
                "lauf": {"ok": True, "teile": 3, "pruefung": {"zusammenfassung": ""}}, "ms": 900}

    def versionen_vergleichen(self, a: str, b: str | None = None, *, zeigen: bool = True,
                              **kw: Any) -> dict[str, Any]:
        self._record("versionen_vergleichen", a, b, zeigen)
        return {"ok": True, "a": {"nr": 2, "titel": "Geändert: model.py"}, "b": {"nr": None, "titel": "Aktueller Stand"},
                "aktuell": b is None, "zusammenfassung": "Teile: 1 geändert",
                "params": [{"name": "hoehe", "alt": 120, "neu": 140, "art": "geaendert"}],
                "teile": {"neu": ["Deckel"], "weg": [], "geaendert": [{"name": "Grundplatte", "arten": ["form"],
                                                                       "dvolumen": 1200.0}], "gleich": 2},
                "stueckliste": {"neu": [], "weg": [], "geaendert": []},
                "pruefung": {"alt": None, "neu": None}, "kennzahlen": {"alt": {}, "neu": {}},
                "code": {"dateien": [{"pfad": "model.py", "status": "M", "plus": 1, "minus": 1}],
                         "diff": "-hoehe = param(\"hoehe\", 120)\n+hoehe = param(\"hoehe\", 140)\n",
                         "gekuerzt": False, "zeilen": 2},
                "geister": [{"teil": "Grundplatte", "art": "alt"}], "hinweise": [], "ms": 40}

    def meilenstein(self, titel: str, notiz: str = "", version: str | None = None, **kw: Any) -> dict[str, Any]:
        self._record("meilenstein", titel, notiz, version, **kw)
        if version == "V3" and not kw.get("ersetzen"):  # V3 trägt Kevins Meilenstein (VERSIONEN oben)
            return {"ok": True, "version": 3, "titel": "Halter fertig", "notiz": "Bohrungen M6", "entfernt": False,
                    "geschuetzt": True, "hinweis": "V3 trägt Kevins Meilenstein „Halter fertig“; er bleibt "
                                                   f"unverändert. „{titel}“ steht als Titel der Version darunter."}
        return {"ok": True, "version": 3, "titel": titel, "notiz": notiz}

    def variante(self, aktion: str = "liste", name: str | None = None, von: str | None = None,
                 neuer_name: str | None = None, **kw: Any) -> dict[str, Any]:
        self._record("variante", aktion, name, von, neuer_name)
        varianten = [{"id": "haupt", "name": "Hauptstand", "aktuell": aktion == "liste", "versionen": 3}]
        if aktion != "liste":
            varianten.append({"id": "v-leicht", "name": name, "aktuell": True, "versionen": 0})
        return {"ok": True, "aktion": aktion, "variante": "v-leicht", "name": name, "von": 2, "varianten": varianten}

    # Phase 4: Referenzen
    def referenzen(self, name: str | None = None, warten_s: float = 0.0) -> dict[str, Any]:
        self._record("referenzen", name, warten_s)
        from kevcad_kernel.protocol import referenz_beispiele

        beispiele = {n: h for n, h, _ in referenz_beispiele()}
        liste = [dict(r) for r in beispiele["ref_list"]["referenzen"]]
        erg = {k: v for k, v in beispiele["ref_result"].items() if k not in ("type", "seq")}
        liste[0].update(zustand="fertig", laeuft=None, fortschritt=None, text=None, netz=True,
                        messung_ergebnis=erg, lage={"drehung_z": 180.0, "rest_mm": 6.3, "paare": 8},
                        capture={"huelle": {"laenge": 180, "breite": 117.3, "hoehe": 48.4},
                                 "grundkoerper": {"laenge": 174, "breite": 102.1}, "bilder": 60, "ausgerichtet": 42})
        if name:
            liste = [r for r in liste if r["name"] == name]
        return {"ok": True, "projekt": self.project["path"], "referenzen": liste,
                "werkzeuge": {"kevcad_capture": "/x/kevcad-capture", "fotomess": "/x/fotomess"}}

    def referenz_video(self, pfad: str, name: str | None = None, masz: dict[str, float] | None = None,
                       auflage: bool = False, von: float | None = None, bis: float | None = None,
                       einstellung: str = "schnell", warten_s: float = 0.0) -> dict[str, Any]:
        self._record("referenz_video", pfad, name, masz, auflage, von, bis, einstellung, warten_s)
        if not str(pfad).lower().endswith((".mov", ".mp4")):
            return {"ok": False, "error": "kein Video"}
        return {"ok": True, "name": name or "IMG_5186", "ordner": "/tmp/Kev CAD/x/referenzen/IMG_5186",
                "zustand": "rechnet", "befehl": "kevcad-capture lauf …"}

    def referenz_fotos(self, pfade: list[str], name: str | None = None) -> dict[str, Any]:
        self._record("referenz_fotos", pfade, name)
        return {"ok": True, "name": name or "Fotos", "ordner": "/tmp/r", "fotos": list(pfade)}

    def referenz_vermessen(self, quelle: str | None = None, freie_masse: list[str] | None = None,
                           bekannte_masse: dict[str, float] | None = None, bilder: int = 8, vorgaben: Any = None,
                           grenzen: Any = None, maske: Any = None, von: float | None = None, bis: float | None = None,
                           kb_brennweite: float | None = None) -> dict[str, Any]:
        self._record("referenz_vermessen", quelle, freie_masse, bekannte_masse, bilder, vorgaben, grenzen, maske, von,
                     bis, kb_brennweite)
        from kevcad_kernel.protocol import referenz_beispiele

        erg = {k: v for k, v in dict((n, h) for n, h, _ in referenz_beispiele())["ref_result"].items()
               if k not in ("type", "seq")}
        return {"ok": True, **erg, "kontrollbilder": ["/tmp/r/messung/kontrolle/a.jpg"]}

    def referenz_abweichung(self, name: str | None = None, teile: list[str] | None = None,
                            grenze_mm: float | None = None, skala_mm: float | None = None, zeigen: bool = False,
                            auf: str = "modell", warten_s: float = 120.0) -> dict[str, Any]:
        self._record("referenz_abweichung", name, teile, grenze_mm, skala_mm, zeigen, auf)
        from kevcad_kernel.protocol import referenz_beispiele

        kurz = {n: h for n, h, _ in referenz_beispiele()}["ref_list_abweichung"]["referenzen"][0]["abweichung"]
        out = {"ok": True, "referenz": name or "IMG_5186", "grenze_mm": kurz["grenze_mm"],
               "skala_mm": skala_mm or kurz["skala_mm"], "skala_fest": bool(skala_mm), "teile": kurz["teile"],
               "referenz_netz": kurz["referenz"], "angelegt": True, "ms": 840.0, "run": 7, "hinweise": []}
        if zeigen:
            out["gezeigt"] = True
        return out

    def referenz_massstab(self, name: str | None = None, mm: float = 0.0, punkte: Any = None,
                          kante: str | None = None) -> dict[str, Any]:
        self._record("referenz_massstab", name, mm, punkte, kante)
        if punkte is None and not kante:
            return {"ok": False, "error": "Entweder punkte (zwei Punkte am Netz) oder kante (benanntes Maß) angeben"}
        return {"ok": True, "referenz": name or "IMG_5186", "faktor": 1.0125, "faktor_gesamt": 1.0125,
                "ist_mm": 177.78, "mm": mm, "geaendert": ["capture/netz_mm.obj", "capture/poses.json"],
                "messung_skaliert": False, "punkte_am_netz": [[-88.9, -50.4, 0.0], [88.9, -50.4, 0.0]] if punkte
                else None, "text": f"Maßstab von IMG_5186: 177,8 mm an der Referenz sind {mm} mm, Faktor 1.0125",
                "hinweise": []}

    # Scan mit dem iPhone
    def scans(self) -> dict[str, Any]:
        self._record("scans")
        return {"ok": True, "ordner": "/tmp/Scans", "kevscan": "/x/scan",
                "empfaenger": {"laeuft": True, "port": 50123, "name": "MacBook", "dienst": "_kevscan._tcp"},
                "scans": [{"id": "2026-10-22_211000_Quader", "name": "Quader", "ordner": "/tmp/Scans/x", "fotos": 10,
                           "videobilder": 30, "groesse_mb": 41.2, "objekt": False, "geraet": "iPhone16,2",
                           "empfangen": "2026-10-22T21:10:00", "referenzen": [], "zustand": "neu"}]}

    def scan_importieren(self, scan: str | None = None, name: str | None = None, schnell: bool = False,
                         warten_s: float = 0.0) -> dict[str, Any]:
        self._record("scan_importieren", scan, name, schnell, warten_s)
        out = {"ok": True, "name": name or "Quader", "ordner": "/tmp/p/referenzen/Quader", "scan": scan or "x",
               "zustand": "rechnet", "einstellung": "schnell" if schnell else "genau", "befehl": "kevscan auswerten"}
        if warten_s:
            out.update(zustand="fertig", referenz={"name": out["name"], "zustand": "fertig"},
                       bericht={"huellmass_mm": {"laenge": 200.4, "breite": 100.8, "hoehe": 50.2},
                                "bilder": {"fotos": 10, "video": 30}, "tiefe": {"verfahren": "promptda",
                                                                                "modell": "large", "geraet": "mps"},
                                "zeiten": {"gesamt": 95.0, "tiefe_je_bild": 1.9, "tsdf": 3.1}})
        return out

    def referenz_fotoansicht(self, name: str | None = None, foto: Any = None, satz: str | None = None,
                             modus: str | None = None, deckkraft: float | None = None, aus: bool = False,
                             bild: bool = False, breite: int = 1280) -> dict[str, Any]:
        self._record("referenz_fotoansicht", name, foto, satz, modus, deckkraft, aus, bild)
        out = {"ok": True, "message": "Fotoansicht IMG_5186: Foto 1 von 8, Überdeckung 93,5 %"}
        if bild:
            out.update(png=PNG, width=4, height=3, ueberdeckung=0.935)
        return out

    def render(self, szene: str | None = "studio", ansicht: str | None = None, kamera: str | None = None,
               groesse: Any = None, qualitaet: str = "schnell", hintergrund: str | None = None,
               umgebung: str | None = None, ziel: str | None = None, warten_s: float | None = None,
               auftrag: str | None = None, abbrechen: bool = False, bild: bool = False,
               samples: int | None = None) -> dict[str, Any]:
        self._record("render", szene, ansicht, kamera, groesse, qualitaet, hintergrund, umgebung, ziel, warten_s,
                     auftrag, abbrechen, bild)
        if szene == "mond":
            return {"ok": False, "error": "szene 'mond' unbekannt: studio, werkstatt, draussen, wohnraum, freigestellt"}
        foto = qualitaet == "foto" and not auftrag
        out = {"ok": True, "auftrag": auftrag or "R-1", "zustand": "laeuft" if foto else "fertig",
               "qualitaet": qualitaet, "szene": szene or "studio", "szene_titel": "Studio", "ansicht": ansicht or "aktuell",
               "kamera": kamera, "width": 1920, "height": 1080, "fortschritt": 0.1 if foto else 1.0,
               "text": "Blender startet" if foto else "fertig in 0,8 s",
               "pfad": "/tmp/Wandhalter/output/renders/Wandhalter_studio_schnell_20261022-120000.png",
               "ms": None if foto else 840, "phasen": {} if foto else {"rendern_ms": 330, "png_ms": 80}}
        if bild and not foto:
            out["png"] = PNG
        return out

    def set_agent_activity(self, text: str | None) -> None:
        with self.lock:
            self.activity.append(text)

    def set_agent_connected(self, connected: bool) -> None:
        with self.lock:
            self.connected.append(connected)

    def set_agent_sessions(self, sessions: list[dict[str, Any]]) -> None:
        with self.lock:
            self.sessions.append([dict(s) for s in sessions])

    def close(self) -> None:
        self._record("close")
        self.closed = True
