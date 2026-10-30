"""STL zu G-Code für den OctoPrint-Drucker: PrusaSlicer-Kommandozeile mit einem exportierten Profil.

Das Profil ist eine ``.ini`` aus PrusaSlicer („Datei > Exportieren > Konfiguration exportieren“), die Drucker,
Filament und Druckeinstellungen in einem enthält. SuperSlicer versteht dieselben Schalter und wird ebenfalls gefunden.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path
from typing import Any

KANDIDATEN = (
    "/Applications/PrusaSlicer.app/Contents/MacOS/PrusaSlicer",
    "/Applications/Original Prusa Drivers/PrusaSlicer.app/Contents/MacOS/PrusaSlicer",
    "/Applications/SuperSlicer.app/Contents/MacOS/SuperSlicer",
    "~/Applications/PrusaSlicer.app/Contents/MacOS/PrusaSlicer",
)
PATH_NAMEN = ("prusa-slicer", "PrusaSlicer", "superslicer")
ZEITLIMIT_S = 600


class SlicerFehler(RuntimeError):
    """Meldung auf Deutsch für Agent und Nutzer."""


def finde_slicer(wunsch: str | None = None) -> Path | None:
    kandidaten = [wunsch] if wunsch else []
    kandidaten += [os.environ.get("KEVCAD_SLICER", "")] + list(KANDIDATEN)
    for k in kandidaten:
        if k:
            p = Path(k).expanduser()
            if p.is_file() and os.access(p, os.X_OK):
                return p
    for n in PATH_NAMEN:
        w = shutil.which(n)
        if w:
            return Path(w)
    return None


def befehl(slicer: Path, profil: Path, stl: Path, gcode: Path) -> list[str]:
    # ohne --center/--arrange legt PrusaSlicer das Objekt selbst mittig aufs Bett
    return [str(slicer), "--export-gcode", "--load", str(profil), "--output", str(gcode), str(stl)]


def slicen(stl: Path, profil: str | None, gcode: Path, slicer_wunsch: str | None = None,
           ausfuehren: Any = None) -> dict[str, Any]:
    if not profil:
        raise SlicerFehler("Kein Slicer-Profil eingestellt. In PrusaSlicer den Drucker einrichten, dann „Datei > "
                           "Exportieren > Konfiguration exportieren“ als .ini speichern und mit octoprint_einrichten("
                           "profil=…) eintragen.")
    profil_p = Path(profil).expanduser()
    if not profil_p.is_file():
        raise SlicerFehler(f"Slicer-Profil nicht gefunden: {profil_p}")
    slicer = finde_slicer(slicer_wunsch)
    if slicer is None:
        raise SlicerFehler("PrusaSlicer nicht gefunden. Installieren (prusa3d.com) oder den Pfad mit "
                           "octoprint_einrichten(slicer=…) setzen. Alternativ fertigen G-Code an octoprint_drucken "
                           "geben.")
    gcode.parent.mkdir(parents=True, exist_ok=True)
    run = ausfuehren or subprocess.run
    cmd = befehl(slicer, profil_p, stl, gcode)
    r = run(cmd, capture_output=True, text=True, timeout=ZEITLIMIT_S)
    if r.returncode != 0 or not gcode.is_file():
        rest = [z for z in ((r.stderr or "") + "\n" + (r.stdout or "")).splitlines() if z.strip()][-6:]
        raise SlicerFehler("Slicen fehlgeschlagen" + (": " + " | ".join(rest) if rest else ""))
    return {"slicer": str(slicer), "profil": str(profil_p), "gcode": str(gcode), **gcode_info(gcode)}


_ZEIT = re.compile(r";\s*estimated printing time(?: \(normal mode\))?\s*=\s*(.+)", re.I)
_GRAMM = re.compile(r";\s*(?:total )?filament used \[g\]\s*=\s*([\d.]+)", re.I)
_MM = re.compile(r";\s*filament used \[mm\]\s*=\s*([\d.]+)", re.I)


def gcode_info(gcode: Path) -> dict[str, Any]:
    """Druckzeit und Filament aus den Kommentaren am Dateiende (PrusaSlicer, SuperSlicer, Cura teilweise)."""
    info: dict[str, Any] = {"groesse_kb": round(gcode.stat().st_size / 1024, 1)}
    with open(gcode, "rb") as f:
        f.seek(max(0, gcode.stat().st_size - 64 * 1024))
        ende = f.read().decode("utf-8", errors="replace")
    for zeile in ende.splitlines():
        if m := _ZEIT.match(zeile):
            info["druckzeit"] = m.group(1).strip()
        elif m := _GRAMM.match(zeile):
            info["filament_g"] = float(m.group(1))
        elif m := _MM.match(zeile):
            info["filament_m"] = round(float(m.group(1)) / 1000, 2)
    return info
