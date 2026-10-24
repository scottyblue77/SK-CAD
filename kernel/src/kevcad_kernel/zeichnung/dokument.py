"""Blatt-Dateien ``<projekt>/dokumente/zeichnungen/<id>.json`` (DOKUMENTE.md, „Zeichnungsblatt“): Vorgaben,
Prüfung, Lesen, Schreiben, Kennungen.

Zusätzliche, optionale Felder (rein additiv, ältere Leser ignorieren sie):

- ``masse[i].schluessel``: Kennung eines automatischen Maßes (z. B. ``lage:bohrung:2:x``), damit Kev CAD es bei jedem
  Lauf wiedererkennt; ``masse[i].seite`` (unten | oben | links | rechts) bevorzugte Seite; ``masse[i].text_versatz``
  Lage der Zahl gegenüber der Mitte der Maßlinie bzw. des Ziels (Blatt-mm, nach ``mass_verschieben``);
  ``masse[i].anker`` letzte Ansatzpunkte relativ zur Ansicht (damit ein verwaistes Maß sichtbar bleibt).
- Bezüge: ``element`` wählt einen Teil eines Merkmals (``lo0``/``hi0`` … Grenzen einer Tasche entlang einer Achse).
- ``ansichten[i].fest``: Kevin hat die Ansicht verschoben, die Anordnung lässt sie stehen; ``ansichten[i].optional``:
  darf bei Platzmangel entfallen (Isometrie); ``ansichten[i].titel``: Beschriftung (z. B. „A–A“).
- ``auto.massstab``, ``auto.format``: Kev CAD wählt Maßstab bzw. Format selbst (bis Kevin sie setzt);
  ``unterdrueckt`` (Vertrag 1.1): gelöschte automatische Maße mit Art, Ansicht, Bezügen und ``schluessel``; die
  automatische Bemaßung legt sie nicht neu an.
- ``allgemein``: allgemeine Angaben über dem Schriftfeld (z. B. „Plattendicke 5 mm“), von Kev CAD gepflegt.
"""

from __future__ import annotations

import datetime as _dt
import json
import os
import re
import unicodedata
from pathlib import Path
from typing import Any

VERSION = 1
FORMATE = ("A4", "A3", "A2", "A1", "A0")
ANSICHT_ARTEN = ("vorn", "hinten", "oben", "unten", "links", "rechts", "iso", "iso_vorn_links", "iso_hinten_rechts",
                 "iso_hinten_links", "schnitt", "einzelheit")
MASS_ARTEN = ("linear", "durchmesser", "radius", "winkel", "fase", "bohrung", "gewinde", "bezugskette", "koordinaten",
              "merkmal")
SCHRIFTFELD = ("benennung", "zeichnungsnummer", "werkstoff", "halbzeug", "masse_g", "allgemeintoleranz", "projekt",
               "version", "datum", "gezeichnet", "notiz", "stueckzahl", "dokumentart", "blatt_nr", "blatt_anzahl",
               "eigentuemer", "freigegeben")


def eigentuemer() -> str:
    """Eigentümer im Schriftfeld: ``KEVCAD_AUTOR``, sonst der volle Name des macOS-Benutzers (bei Kevin „Kevin Schwed“),
    sonst „Kev CAD“."""
    name = os.environ.get("KEVCAD_AUTOR", "").strip()
    if not name:
        try:
            import pwd

            name = pwd.getpwuid(os.getuid()).pw_gecos.split(",")[0].strip()
        except (ImportError, KeyError):
            name = ""
    return name or "SK-CAD"


class BlattFehler(ValueError):
    """Blatt nicht lesbar oder Operation ungültig (Meldung für Agent und App)."""


def ordner(projekt: str | Path) -> Path:
    return Path(projekt) / "dokumente" / "zeichnungen"


def kennung(text: str) -> str:
    """Dateiname aus einer Benennung: „Seitenstange links (Rohr 1)“ → „seitenstange-links-rohr-1“."""
    t = unicodedata.normalize("NFKD", str(text).replace("ß", "ss").replace("ä", "ae").replace("ö", "oe")
                              .replace("ü", "ue").replace("Ä", "Ae").replace("Ö", "Oe").replace("Ü", "Ue"))
    t = "".join(ch for ch in t if not unicodedata.combining(ch)).lower()
    t = re.sub(r"[^a-z0-9]+", "-", t).strip("-")
    return t[:60] or "blatt"


def neu(blatt_id: str, titel: str, art: str, teile: list[str], *, fmt: str | None = None,
        ausrichtung: str | None = None) -> dict[str, Any]:
    return normalisiere({
        "version": VERSION, "id": blatt_id, "titel": titel, "format": fmt or "A4", "ausrichtung": ausrichtung or "quer",
        "massstab": "1:1", "inhalt": {"art": art, "teile": list(teile)},
        "schriftfeld": {"benennung": titel, "datum": _dt.date.today().isoformat(), "gezeichnet": "SK-CAD",
                        "allgemeintoleranz": "ISO 2768-m"},
        "ansichten": [], "masse": [], "notizen": [], "tabellen": [],
        "unterdrueckt": [],
        "auto": {"ansichten": True, "masse": True, "massstab": True, "format": fmt is None},
    })


def normalisiere(blatt: dict[str, Any]) -> dict[str, Any]:
    """Fehlende Felder mit Vorgaben füllen, Kennungen vergeben; wirft BlattFehler bei kaputtem Inhalt."""
    if not isinstance(blatt, dict):
        raise BlattFehler("Blatt ist kein JSON-Objekt")
    b = dict(blatt)
    b.setdefault("version", VERSION)
    if not b.get("id"):
        b["id"] = kennung(b.get("titel") or "blatt")
    b.setdefault("titel", b["id"])
    fmt = str(b.get("format") or "A4").upper()
    if fmt not in FORMATE:
        raise BlattFehler(f"Format {fmt!r} unbekannt (A4, A3, A2, A1, A0)")
    b["format"] = fmt
    b["ausrichtung"] = "hoch" if str(b.get("ausrichtung") or "quer").lower() == "hoch" else "quer"
    b.setdefault("massstab", "1:1")
    inhalt = dict(b.get("inhalt") or {})
    inhalt.setdefault("art", "teil")
    if inhalt["art"] not in ("teil", "baugruppe", "zusammenbau"):
        raise BlattFehler(f"inhalt.art {inhalt['art']!r} unbekannt (teil, baugruppe, zusammenbau)")
    inhalt["teile"] = [str(t) for t in inhalt.get("teile") or []]
    b["inhalt"] = inhalt
    sf = dict(b.get("schriftfeld") or {})
    for k in ("benennung", "zeichnungsnummer", "werkstoff", "halbzeug", "masse_g", "allgemeintoleranz", "projekt",
              "version", "datum", "gezeichnet", "notiz", "dokumentart", "blatt_nr", "blatt_anzahl", "eigentuemer",
              "freigegeben"):
        sf.setdefault(k, None)
    if sf.get("gezeichnet") is None:
        sf["gezeichnet"] = "SK-CAD"
    if sf.get("allgemeintoleranz") is None:
        sf["allgemeintoleranz"] = "ISO 2768-m"
    if sf.get("eigentuemer") is None:
        sf["eigentuemer"] = eigentuemer()
    if sf.get("blatt_nr") is None:
        sf["blatt_nr"] = 1
    if sf.get("blatt_anzahl") is None:
        sf["blatt_anzahl"] = 1
    if sf.get("dokumentart") is None:
        sf["dokumentart"] = "Fertigungszeichnung" if inhalt["art"] == "teil" else "Zusammenbauzeichnung"
    b["schriftfeld"] = sf
    for liste in ("ansichten", "masse", "notizen", "tabellen", "allgemein", "unterdrueckt"):
        b[liste] = list(b.get(liste) or [])
    auto = dict(b.get("auto") or {})
    auto.setdefault("ansichten", True)
    auto.setdefault("masse", True)
    auto.setdefault("massstab", True)
    auto.setdefault("format", True)
    auto.pop("unterdrueckt", None)
    b["auto"] = auto
    benutzt = {a.get("id") for a in b["ansichten"] if a.get("id")}
    for a in b["ansichten"]:
        if a.get("art") not in ANSICHT_ARTEN:
            raise BlattFehler(f"Ansicht {a.get('id')!r}: art {a.get('art')!r} unbekannt ({', '.join(ANSICHT_ARTEN)})")
        if not a.get("id"):
            a["id"] = naechste("v", benutzt)
            benutzt.add(a["id"])
    benutzt = {m.get("id") for m in b["masse"] if m.get("id")}
    for m in b["masse"]:
        if m.get("art") not in MASS_ARTEN:
            raise BlattFehler(f"Maß {m.get('id')!r}: art {m.get('art')!r} unbekannt ({', '.join(MASS_ARTEN)})")
        if not m.get("id"):
            m["id"] = naechste("m", benutzt)
            benutzt.add(m["id"])
        m.setdefault("bezuege", [])
        m.setdefault("richtung", None)
        m.setdefault("versatz", None)
        m.setdefault("text", None)
        m.setdefault("toleranz", None)
        m.setdefault("quelle", "auto")
        m.setdefault("fest", False)
        m.setdefault("verwaist", False)
    benutzt = {n.get("id") for n in b["notizen"] if n.get("id")}
    for n in b["notizen"]:
        if not n.get("id"):
            n["id"] = naechste("n", benutzt)
            benutzt.add(n["id"])
        n.setdefault("zeiger", None)
        n.setdefault("quelle", "kevin")
    return b


def naechste(prefix: str, vorhandene: set[Any]) -> str:
    """Nächste freie Kennung hinter der größten vorhandenen (gelöschte Kennungen werden nicht wiederverwendet, damit
    die App ein neues Maß nicht mit einem gelöschten verwechselt)."""
    zahlen = [int(str(v)[len(prefix):]) for v in vorhandene
              if isinstance(v, str) and v.startswith(prefix) and str(v)[len(prefix):].isdigit()]
    return f"{prefix}{max(zahlen, default=0) + 1}"


def zum_speichern(blatt: dict[str, Any]) -> dict[str, Any]:
    """Interne Felder (Präfix ``_``) entfernen."""
    def clean(v: Any) -> Any:
        if isinstance(v, dict):
            return {k: clean(x) for k, x in v.items() if not str(k).startswith("_")}
        if isinstance(v, list):
            return [clean(x) for x in v]
        return v

    return clean(blatt)


def lade(pfad: str | Path) -> dict[str, Any]:
    try:
        daten = json.loads(Path(pfad).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise BlattFehler(f"Blatt {Path(pfad).name} nicht lesbar: {exc}") from exc
    return normalisiere(daten)


def speichere(pfad: str | Path, blatt: dict[str, Any]) -> bool:
    """Atomar schreiben; nur wenn sich der Inhalt ändert (dann True)."""
    p = Path(pfad)
    text = json.dumps(zum_speichern(blatt), ensure_ascii=False, indent=1) + "\n"
    try:
        if p.exists() and p.read_text(encoding="utf-8") == text:
            return False
    except OSError:
        pass
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_name(f".{p.name}.tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, p)
    return True


def alle(projekt: str | Path) -> list[tuple[Path, dict[str, Any] | None, str | None]]:
    """Alle Blätter des Projekts: (Pfad, Blatt oder None, Fehler)."""
    d = ordner(projekt)
    if not d.is_dir():
        return []
    out = []
    for p in sorted(d.glob("*.json")):
        try:
            out.append((p, lade(p), None))
        except BlattFehler as exc:
            out.append((p, None, str(exc)))
    return out
