"""STL-Import in der Kernel-Laufzeit: ``stl_laden`` und ``stl_liste`` (SK-CAD).

``StlRuntimeMixin`` gehört zu ``KernelRuntime`` (runtime.py) und nutzt dort ``_project``, ``_log`` und aus
``ReferenzRuntimeMixin`` die Anzeige der Referenzen (REF_LIST, Netz an die App).

Eine geladene STL wird zweimal abgelegt:
- ``<projekt>/stl/<name>.stl``: unveränderte Kopie, Quelle für ``octoprint_drucken`` (Slicer),
- ``<projekt>/referenzen/<name>/`` (art "stl"): Netz in mm als Referenz, damit sie im Viewer erscheint (halb
  durchsichtig wie ein Scan) und ``referenz_abweichung`` gegen ein eigenes Modell vergleichen kann.
"""

from __future__ import annotations

import shutil
from pathlib import Path
from typing import Any

from kevcad_kernel.referenz import ablage as ref_ablage
from kevcad_kernel.referenz import netz as ref_netz
from kevcad_kernel.stl import datei
from kevcad_kernel.stl.datei import StlFehler

STL_ORDNER = "stl"


def stl_pfad(projekt: Path, name: str) -> Path:
    return projekt / STL_ORDNER / f"{name}.stl"


class StlRuntimeMixin:
    _project: Any

    def stl_laden(self, pfad: str, name: str | None = None, auf_bett: bool = True) -> dict[str, Any]:
        """STL ins offene Projekt übernehmen und im Viewer zeigen."""
        proj = self._project
        if proj is None:
            return {"ok": False, "error": "Kein Projekt offen. Erst project_open oder project_new aufrufen."}
        quelle = Path(str(pfad)).expanduser()
        if quelle.suffix.lower() != ".stl":
            return {"ok": False, "error": f"{quelle.name} ist keine .stl-Datei"}
        try:
            ref_ablage.lesbar(quelle)
            tri = datei.lies_stl(quelle)
        except (StlFehler, ref_ablage.ReferenzFehler) as exc:
            return {"ok": False, "error": str(exc)}
        except OSError as exc:
            return {"ok": False, "error": f"{quelle.name} nicht lesbar: {exc}"}
        pos, ind = datei.netz_aus_dreiecken(tri)
        if len(ind) == 0:
            return {"ok": False, "error": f"{quelle.name}: nur entartete Dreiecke"}
        info = datei.kennzahlen(pos, ind)
        anzeige = datei.auf_bett(pos) if auf_bett else pos

        wunsch = ref_ablage.sicherer_name(name or quelle.stem) or "STL"
        n = wunsch if name and not ref_ablage.ordner(proj.path, wunsch).exists() else \
            ref_ablage.freier_name(proj.path, wunsch)
        ziel = stl_pfad(proj.path, n)
        ziel.parent.mkdir(parents=True, exist_ok=True)
        if quelle.resolve() != ziel.resolve():
            shutil.copy2(quelle, ziel)
        datei.schreibe_obj(ref_ablage.ordner(proj.path, n) / ref_ablage.CAPTURE / "netz_mm.obj", anzeige, ind)
        meta = {"art": "stl", "quelle": str(quelle), "erstellt": ref_ablage.jetzt(),
                "stl": {"datei": f"{STL_ORDNER}/{n}.stl", "auf_bett": bool(auf_bett), **info},
                "capture": {"zustand": "fertig", "verfahren": "stl", "huelle": ref_netz.huelle(anzeige)}}
        ref_ablage.schreibe_meta(proj.path, n, meta)
        try:
            self._ref_liste_senden(sofort=True)  # type: ignore[attr-defined]
            self._ref_netz_senden(proj.path, n)  # type: ignore[attr-defined]
        except Exception as exc:  # noqa: BLE001 - Anzeige ist Zugabe, die Ablage zählt
            log = getattr(self, "_log", None)
            if log:
                log(f"[stl] Anzeige {n}: {exc!r}")
        hinweise = []
        if not info["dicht"]:
            hinweise.append(f"Netz nicht dicht ({info['offene_kanten']} offene, {info['mehrfache_kanten']} "
                            "mehrfache Kanten); der Slicer repariert meist, sonst vorher reparieren.")
        if info["innen_nach_aussen"]:
            hinweise.append("Normalen zeigen nach innen; der Slicer dreht sie in der Regel selbst um.")
        if max(info["masz_mm"]) < 2:
            hinweise.append("Sehr klein: vermutlich in Metern oder Zoll gespeichert, nicht in mm.")
        return {"ok": True, "name": n, "stl": str(ziel), "referenz": str(ref_ablage.ordner(proj.path, n)),
                **info, "hinweise": hinweise}

    def stl_liste(self) -> dict[str, Any]:
        """STL-Dateien des offenen Projekts mit Kennzahlen."""
        proj = self._project
        if proj is None:
            return {"ok": False, "error": "Kein Projekt offen. Erst project_open oder project_new aufrufen."}
        eintraege = []
        for n in ref_ablage.namen(proj.path):
            meta = ref_ablage.lese_meta(proj.path, n) or {}
            if meta.get("art") != "stl":
                continue
            s = meta.get("stl") or {}
            eintraege.append({"name": n, "stl": str(proj.path / s.get("datei", f"{STL_ORDNER}/{n}.stl")),
                              "masz_mm": s.get("masz_mm"), "dreiecke": s.get("dreiecke"),
                              "volumen_cm3": s.get("volumen_cm3"), "dicht": s.get("dicht"),
                              "erstellt": meta.get("erstellt")})
        return {"ok": True, "stl": eintraege}

    def stl_datei(self, name_oder_pfad: str) -> Path:
        """Pfad einer STL: Name aus ``stl_liste`` oder ein Dateipfad. Fehler als StlFehler."""
        p = Path(str(name_oder_pfad)).expanduser()
        if p.suffix.lower() in (".stl", ".gcode", ".gco", ".g") and p.is_absolute():
            if not p.is_file():
                raise StlFehler(f"Datei nicht gefunden: {p}")
            return p
        proj = self._project
        if proj is None:
            raise StlFehler("Kein Projekt offen; vollständigen Pfad angeben oder erst project_open aufrufen.")
        kandidat = proj.path / p if p.suffix else stl_pfad(proj.path, str(name_oder_pfad))
        if kandidat.is_file():
            return kandidat
        alle = [e["name"] for e in self.stl_liste().get("stl", [])]
        raise StlFehler(f"Keine STL {name_oder_pfad!r} im Projekt. " +
                        (f"Vorhanden: {', '.join(alle)}." if alle else "Erst stl_laden(pfad) aufrufen."))
