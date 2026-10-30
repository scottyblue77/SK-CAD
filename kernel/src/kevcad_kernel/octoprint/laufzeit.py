"""OctoPrint in der Kernel-Laufzeit: ``octoprint_status``, ``octoprint_einrichten``, ``octoprint_drucken`` (SK-CAD).

``OctoPrintRuntimeMixin`` gehört zu ``KernelRuntime`` (runtime.py) und nutzt ``_project`` sowie ``stl_datei`` aus
``StlRuntimeMixin``. Drucken ist zweistufig: ohne ``starten`` wird nur geslict, hochgeladen und ausgewählt; der Druck
startet erst mit ``starten=True``, und das ruft der Agent nur auf ausdrückliche Bitte des Nutzers auf.
"""

from __future__ import annotations

import time
from pathlib import Path
from typing import Any

from kevcad_kernel.octoprint import einstellungen as einst
from kevcad_kernel.octoprint import slicen
from kevcad_kernel.octoprint.client import OctoPrintClient, OctoPrintFehler
from kevcad_kernel.stl.datei import StlFehler

GCODE_ENDUNGEN = (".gcode", ".gco", ".g")
OCTO_ORDNER = "sk-cad"


def _kurz_drucker(d: dict[str, Any] | None) -> dict[str, Any]:
    if d is None:
        return {"verbunden": False}
    zustand = d.get("state") or {}
    temp = d.get("temperature") or {}

    def t(k: str) -> dict[str, Any] | None:
        w = temp.get(k)
        return {"ist": w.get("actual"), "soll": w.get("target")} if isinstance(w, dict) else None

    return {"verbunden": True, "zustand": zustand.get("text"), "flags": {k: v for k, v in
            (zustand.get("flags") or {}).items() if v}, "duese": t("tool0"), "bett": t("bed")}


def _kurz_auftrag(j: dict[str, Any]) -> dict[str, Any]:
    job = j.get("job") or {}
    fort = j.get("progress") or {}
    datei = (job.get("file") or {}).get("name")
    return {"zustand": j.get("state"), "datei": datei,
            "fortschritt_prozent": round(fort["completion"], 1) if isinstance(fort.get("completion"), (int, float))
            else None,
            "vergangen_s": fort.get("printTime"), "rest_s": fort.get("printTimeLeft")}


class OctoPrintRuntimeMixin:
    _project: Any

    def _octo_client(self) -> tuple[einst.Einstellungen, OctoPrintClient]:
        e = einst.lesen()
        return e, OctoPrintClient(e.url, einst.schluessel())

    def octoprint_status(self) -> dict[str, Any]:
        try:
            e = einst.lesen()
        except einst.EinstellungFehler as exc:
            return {"ok": False, "error": str(exc)}
        basis: dict[str, Any] = {"einstellungen": e.oeffentlich(),
                                 "slicer_gefunden": str(slicen.finde_slicer(e.slicer) or "") or None}
        try:
            _, c = self._octo_client()
            v = c.version()
            d = c.drucker()
            j = c.auftrag()
        except einst.EinstellungFehler as exc:
            return {"ok": False, "error": str(exc), **basis}
        except OctoPrintFehler as exc:
            return {"ok": False, "error": str(exc), **basis}
        return {"ok": True, **basis, "octoprint": v.get("server") or v.get("text"), "drucker": _kurz_drucker(d),
                "auftrag": _kurz_auftrag(j)}

    def octoprint_einrichten(self, url: str | None = None, slicer: str | None = None,
                             profil: str | None = None) -> dict[str, Any]:
        werte = {k: v for k, v in (("url", url), ("slicer", slicer), ("profil", profil)) if v is not None}
        try:
            e = einst.schreiben(**werte) if werte else einst.lesen()
        except einst.EinstellungFehler as exc:
            return {"ok": False, "error": str(exc)}
        hinweise = []
        if e.profil and not Path(e.profil).is_file():
            hinweise.append(f"Profil {e.profil} existiert (noch) nicht.")
        try:
            einst.schluessel()
            schluessel_da = True
        except einst.EinstellungFehler as exc:
            schluessel_da = False
            hinweise.append(str(exc))
        return {"ok": True, "einstellungen": e.oeffentlich(), "schluessel_da": schluessel_da,
                "slicer_gefunden": str(slicen.finde_slicer(e.slicer) or "") or None, "hinweise": hinweise}

    def octoprint_drucken(self, datei: str, starten: bool = False, profil: str | None = None) -> dict[str, Any]:
        """STL (Name im Projekt oder Pfad) slicen bzw. G-Code nehmen, hochladen, auswählen; mit starten drucken."""
        try:
            quelle = self.stl_datei(datei)  # type: ignore[attr-defined]
        except StlFehler as exc:
            return {"ok": False, "error": str(exc)}
        try:
            e, c = self._octo_client()
        except einst.EinstellungFehler as exc:
            return {"ok": False, "error": str(exc)}
        ergebnis: dict[str, Any] = {"quelle": str(quelle)}
        if quelle.suffix.lower() in GCODE_ENDUNGEN:
            gcode = quelle
            ergebnis.update(slicen.gcode_info(gcode))
        else:
            proj = self._project
            ausgabe = (proj.path / "output") if proj is not None else quelle.parent
            gcode = ausgabe / f"{quelle.stem}.gcode"
            try:
                ergebnis.update(slicen.slicen(quelle, profil or e.profil, gcode, e.slicer))
            except slicen.SlicerFehler as exc:
                return {"ok": False, "error": str(exc), **ergebnis}
            except Exception as exc:  # noqa: BLE001 - z. B. Zeitüberschreitung des Slicers
                return {"ok": False, "error": f"Slicen fehlgeschlagen: {exc}", **ergebnis}
        try:
            d = c.drucker()
            if starten:
                if d is None:
                    return {"ok": False, "error": "OctoPrint ist nicht mit dem Drucker verbunden (in OctoPrint "
                                                  "„Verbinden“ klicken).", **ergebnis}
                flags = (d.get("state") or {}).get("flags") or {}
                if flags.get("printing") or flags.get("paused") or not flags.get("ready", True):
                    return {"ok": False, "error": f"Drucker nicht bereit: {(d.get('state') or {}).get('text')}. "
                                                  "Nichts gestartet.", **ergebnis}
            name = f"{quelle.stem}-{time.strftime('%Y%m%d-%H%M')}.gcode"
            antwort = c.hochladen(gcode, ziel_name=name, ordner=OCTO_ORDNER, waehlen=True, drucken=bool(starten))
        except OctoPrintFehler as exc:
            return {"ok": False, "error": str(exc), **ergebnis}
        ziel = ((antwort.get("files") or {}).get("local") or {}).get("path") or f"{OCTO_ORDNER}/{name}"
        meldung = (f"Druck auf {e.name} gestartet." if starten else
                   f"Auf {e.name} hochgeladen und ausgewählt, Druck NICHT gestartet.")
        return {"ok": True, "gestartet": bool(starten), "octoprint_datei": ziel, "gcode": str(gcode),
                "meldung": meldung, "drucker": _kurz_drucker(d), **ergebnis}

    def octoprint_starten(self, octoprint_datei: str) -> dict[str, Any]:
        """Bereits hochgeladene Datei drucken (nur auf ausdrückliche Bitte)."""
        try:
            e, c = self._octo_client()
            d = c.drucker()
            if d is None:
                return {"ok": False, "error": "OctoPrint ist nicht mit dem Drucker verbunden."}
            flags = (d.get("state") or {}).get("flags") or {}
            if flags.get("printing") or flags.get("paused"):
                return {"ok": False, "error": f"Drucker beschäftigt: {(d.get('state') or {}).get('text')}."}
            c.starten(octoprint_datei)
        except (einst.EinstellungFehler, OctoPrintFehler) as exc:
            return {"ok": False, "error": str(exc)}
        return {"ok": True, "gestartet": True, "octoprint_datei": octoprint_datei,
                "meldung": f"Druck auf {e.name} gestartet."}
