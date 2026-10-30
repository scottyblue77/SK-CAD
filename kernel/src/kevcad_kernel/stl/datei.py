"""STL-Dateien lesen und als Referenznetz (OBJ in mm) ablegen (SK-CAD, STL-Import).

Liest binäre und ASCII-STL ohne Zusatzpakete, fasst gleiche Punkte zusammen und liefert Kennzahlen (Maße, Volumen,
dicht oder nicht). Das Netz geht danach als Referenz ``<projekt>/referenzen/<name>/capture/netz_mm.obj`` in den
Viewer; die Original-STL bleibt unverändert unter ``<projekt>/stl/`` und ist die Quelle fürs Slicen.
"""

from __future__ import annotations

import struct
from pathlib import Path
from typing import Any

import numpy as np

MAX_DATEI_MB = 400


class StlFehler(ValueError):
    """Fehler, den Agent oder Nutzer beheben können (Meldung auf Deutsch)."""


def _ist_binaer(daten: bytes) -> bool:
    if len(daten) < 84:
        return False
    (anzahl,) = struct.unpack_from("<I", daten, 80)
    if 84 + 50 * anzahl == len(daten):
        return True
    # ASCII beginnt mit "solid" und enthält "facet"; manche Binärdateien beginnen ebenfalls mit "solid"
    return not (daten[:5].lower() == b"solid" and b"facet" in daten[:4096])


def lies_stl(pfad: str | Path) -> np.ndarray:
    """Alle Dreiecke als Feld (n, 3, 3) in Dateieinheiten."""
    p = Path(pfad).expanduser()
    if not p.is_file():
        raise StlFehler(f"STL nicht gefunden: {p}")
    if p.stat().st_size > MAX_DATEI_MB * 1024 * 1024:
        raise StlFehler(f"{p.name} ist größer als {MAX_DATEI_MB} MB")
    daten = p.read_bytes()
    if _ist_binaer(daten):
        (anzahl,) = struct.unpack_from("<I", daten, 80)
        if 84 + 50 * anzahl > len(daten):
            raise StlFehler(f"{p.name}: Datei ist abgeschnitten ({anzahl} Dreiecke angekündigt)")
        satz = np.dtype([("n", "<f4", 3), ("v", "<f4", (3, 3)), ("attr", "<u2")])
        feld = np.frombuffer(daten, dtype=satz, count=anzahl, offset=84)
        tri = feld["v"].astype(np.float64)
    else:
        punkte = []
        for zeile in daten.decode("utf-8", errors="replace").splitlines():
            z = zeile.strip()
            if z.startswith("vertex"):
                teile = z.split()
                punkte.append([float(teile[1]), float(teile[2]), float(teile[3])])
        if len(punkte) % 3:
            raise StlFehler(f"{p.name}: ASCII-STL unvollständig")
        tri = np.asarray(punkte, dtype=np.float64).reshape(-1, 3, 3)
    if len(tri) == 0:
        raise StlFehler(f"{p.name} enthält keine Dreiecke")
    if not np.isfinite(tri).all():
        raise StlFehler(f"{p.name} enthält ungültige Koordinaten")
    return tri


def netz_aus_dreiecken(tri: np.ndarray, toleranz: float = 1e-5) -> tuple[np.ndarray, np.ndarray]:
    """Gleiche Punkte zusammenfassen: (Punkte (m, 3), Dreiecke (n, 3) als Indizes); entartete Dreiecke fallen weg."""
    flach = tri.reshape(-1, 3)
    schluessel = np.round(flach / toleranz).astype(np.int64)
    _, erster, rueck = np.unique(schluessel, axis=0, return_index=True, return_inverse=True)
    pos = flach[erster]
    ind = rueck.reshape(-1, 3)
    gut = (ind[:, 0] != ind[:, 1]) & (ind[:, 1] != ind[:, 2]) & (ind[:, 0] != ind[:, 2])
    return pos, ind[gut]


def kennzahlen(pos: np.ndarray, ind: np.ndarray) -> dict[str, Any]:
    """Maße, Volumen (bei dichtem Netz), Fläche und ob jede Kante genau zwei Dreiecke hat."""
    lo, hi = pos.min(axis=0), pos.max(axis=0)
    a, b, c = pos[ind[:, 0]], pos[ind[:, 1]], pos[ind[:, 2]]
    flaeche = float(np.linalg.norm(np.cross(b - a, c - a), axis=1).sum() / 2)
    volumen = float(np.einsum("ij,ij->i", a, np.cross(b, c)).sum() / 6)
    kanten = np.sort(np.concatenate([ind[:, [0, 1]], ind[:, [1, 2]], ind[:, [2, 0]]]), axis=1)
    _, zahl = np.unique(kanten, axis=0, return_counts=True)
    offen = int((zahl == 1).sum())
    mehrfach = int((zahl > 2).sum())
    return {"dreiecke": int(len(ind)), "punkte": int(len(pos)),
            "masz_mm": [round(float(v), 2) for v in (hi - lo)],
            "min_mm": [round(float(v), 2) for v in lo], "max_mm": [round(float(v), 2) for v in hi],
            "flaeche_mm2": round(flaeche, 1), "volumen_cm3": round(abs(volumen) / 1000, 2),
            "dicht": offen == 0 and mehrfach == 0, "offene_kanten": offen, "mehrfache_kanten": mehrfach,
            "innen_nach_aussen": volumen < 0}


def auf_bett(pos: np.ndarray) -> np.ndarray:
    """Mitte in X/Y auf 0, Unterseite auf Z = 0 (wie auf der Druckplatte)."""
    lo, hi = pos.min(axis=0), pos.max(axis=0)
    return pos - np.array([(lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, lo[2]])


def schreibe_obj(pfad: str | Path, pos: np.ndarray, ind: np.ndarray) -> None:
    p = Path(pfad)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_name(f".{p.name}.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("# SK-CAD: aus STL, Millimeter, Z oben\n")
        np.savetxt(f, pos, fmt="v %.5f %.5f %.5f")
        np.savetxt(f, ind + 1, fmt="f %d %d %d")
    tmp.replace(p)
