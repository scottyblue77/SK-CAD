"""3MF der Druckplatten selbst schreiben (Druckvorschau, wenn Bambu Studio fehlt, etwa auf dem Mac mini).

3MF-Kern (``3D/3dmodel.model``: Netze und Lagen) und die Platten im Format von Bambu Studio
(``Metadata/model_settings.config``: Objekt je Teil mit Name und Filament, je Platte die Teile). Bambu Studio legt die
Platten im Abstand von 1,2 Bettbreiten in Spalten ab (``slicer.PLATTENABSTAND``); so stehen sie hier auch. Ohne
Prozess- und Filamentprofile: die wählt Kevin beim Öffnen in Bambu Studio (mit Bambu Studio schreibt
``slicer.export_3mf`` das 3MF samt Profilen und Einstellungen je Teil). Die Objekte heißen wie die Teile
(``slicer.objekt_namen``, wie im Weg mit Bambu Studio): im Kern (``name``) und in ``model_settings.config`` am Objekt;
von dort nimmt Bambu Studio den Namen für die Objektliste (die Objekte hier haben ihr Netz direkt, ohne ``<part>``).
"""

from __future__ import annotations

import math
import zipfile
from pathlib import Path
from typing import Any
from xml.sax.saxutils import escape

import numpy as np

from kevcad_kernel.druck.slicer import PLATTENABSTAND, PlattenObjekt, lies_stl, objekt_namen

NS = "http://schemas.microsoft.com/3dmanufacturing/core/2015/02"

INHALTSTYPEN = """<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
 <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
 <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>
 <Default Extension="config" ContentType="text/xml"/>
</Types>
"""
BEZIEHUNGEN = """<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
 <Relationship Target="/3D/3dmodel.model" Id="rel-1" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
</Relationships>
"""


def _attr(text: str) -> str:
    """Text für ein XML-Attribut in doppelten Anführungszeichen."""
    return escape(str(text), {'"': "&quot;"})


def _netz(stl: Path) -> tuple[np.ndarray, np.ndarray]:
    tris = lies_stl(stl).reshape(-1, 3)
    pts, inv = np.unique(np.round(tris, 5), axis=0, return_inverse=True)
    T = inv.reshape(-1, 3)
    gut = (T[:, 0] != T[:, 1]) & (T[:, 1] != T[:, 2]) & (T[:, 0] != T[:, 2])
    return pts, T[gut]


def schreibe_3mf(ziel: Path, platten: list[list[PlattenObjekt]], titel: str = "SK-CAD",
                 platten_namen: list[str] | None = None) -> dict[str, Any]:
    """Schreibt das 3MF; liefert {"pfad", "objekte", "platten", "namen"}. ``platten_namen``: Namen der Platten in
    Bambu Studio (sonst „Platte 1“ …)."""
    netze: dict[str, tuple[np.ndarray, np.ndarray]] = {}
    namen = objekt_namen([o for liste in platten for o in liste])
    objekte: list[str] = []
    bau: list[str] = []
    einst_obj: list[str] = []
    einst_platten: list[str] = []
    spalten = max(1, math.ceil(math.sqrt(len(platten))))
    oid = 0
    for i, liste in enumerate(platten):
        ox, oy = (i % spalten) * PLATTENABSTAND, -(i // spalten) * PLATTENABSTAND
        pname = platten_namen[i] if platten_namen and i < len(platten_namen) else f"Platte {i + 1}"
        instanzen = []
        for o in liste:
            key = str(o.stl)
            if key not in netze:
                netze[key] = _netz(o.stl)
            P, T = netze[key]
            oid += 1
            name = _attr(namen[oid - 1])
            v = "\n".join(f'     <vertex x="{x:.5f}" y="{y:.5f}" z="{z:.5f}"/>' for x, y, z in P)
            t = "\n".join(f'     <triangle v1="{a}" v2="{b}" v3="{c}"/>' for a, b, c in T)
            objekte.append(f'  <object id="{oid}" name="{name}" type="model">\n'
                           f"   <mesh>\n    <vertices>\n{v}\n    </vertices>\n    <triangles>\n{t}\n    </triangles>\n"
                           "   </mesh>\n  </object>")
            w = math.radians(float(o.drehung or 0.0))
            c, s = math.cos(w), math.sin(w)
            bau.append(f'  <item objectid="{oid}" transform="{c:.6f} {s:.6f} 0 {-s:.6f} {c:.6f} 0 0 0 1 '
                       f'{o.x + ox:.4f} {o.y + oy:.4f} 0" printable="1"/>')
            einst_obj.append(f'  <object id="{oid}">\n   <metadata key="name" value="{name}"/>\n'
                             f'   <metadata key="extruder" value="{int(o.filament)}"/>\n  </object>')
            instanzen.append(f'   <model_instance>\n    <metadata key="object_id" value="{oid}"/>\n'
                             '    <metadata key="instance_id" value="0"/>\n   </model_instance>')
        einst_platten.append(f'  <plate>\n   <metadata key="plater_id" value="{i + 1}"/>\n'
                             f'   <metadata key="plater_name" value="{_attr(pname)}"/>\n'
                             '   <metadata key="locked" value="false"/>\n' + "\n".join(instanzen) + "\n  </plate>")
    modell = (f'<?xml version="1.0" encoding="UTF-8"?>\n<model unit="millimeter" xml:lang="de-DE" xmlns="{NS}" '
              'xmlns:BambuStudio="http://schemas.bambulab.com/package/2021">\n'
              f' <metadata name="Application">{escape(titel)}</metadata>\n'
              ' <metadata name="BambuStudio:3mfVersion">1</metadata>\n'
              f' <metadata name="Title">{escape(titel)}</metadata>\n'
              " <resources>\n" + "\n".join(objekte) + "\n </resources>\n <build>\n" + "\n".join(bau)
              + "\n </build>\n</model>\n")
    einst = ('<?xml version="1.0" encoding="UTF-8"?>\n<config>\n' + "\n".join(einst_obj) + "\n"
             + "\n".join(einst_platten) + "\n</config>\n")
    ziel = Path(ziel)
    ziel.parent.mkdir(parents=True, exist_ok=True)
    tmp = ziel.with_suffix(".3mf.tmp")
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", INHALTSTYPEN)
        z.writestr("_rels/.rels", BEZIEHUNGEN)
        z.writestr("3D/3dmodel.model", modell)
        z.writestr("Metadata/model_settings.config", einst)
    tmp.replace(ziel)
    return {"pfad": str(ziel), "objekte": oid, "platten": len(platten), "namen": namen}
