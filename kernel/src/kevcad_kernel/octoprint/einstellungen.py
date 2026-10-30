"""Einstellungen der OctoPrint-Anbindung (SK-CAD) und der API-Schlüssel.

Datei ``~/Library/Application Support/de.upvis.kevcad/octoprint.json`` (``KEVCAD_OCTOPRINT_CONFIG`` geht vor)::

    {
      "url": "http://192.168.1.233",          # OctoPi im LAN
      "slicer": "/Applications/PrusaSlicer.app/Contents/MacOS/PrusaSlicer",   # optional, sonst gesucht
      "profil": "~/Documents/SK-CAD/drucker.ini",                           # aus PrusaSlicer exportiert
      "name": "OctoPi"                         # Anzeige
    }

Der API-Schlüssel steht nicht in dieser Datei, sondern im macOS-Schlüsselbund (generisches Passwort, Dienst
``SCHLUESSEL_DIENST``, Konto ``SCHLUESSEL_KONTO``). ``KEVCAD_OCTOPRINT_KEY`` geht vor (Tests, Notfall). Der Schlüssel
taucht nie in Ergebnissen, Fehlern oder Protokollen auf.
"""

from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

STANDARD_URL = "http://192.168.1.233"
SCHLUESSEL_DIENST = "de.upvis.kevcad.octoprint"
SCHLUESSEL_KONTO = "octopi"
SECURITY = "/usr/bin/security"


class EinstellungFehler(ValueError):
    """Fehler, den der Nutzer beheben kann (Meldung auf Deutsch, ohne Geheimnisse)."""


def config_pfad() -> Path:
    env = os.environ.get("KEVCAD_OCTOPRINT_CONFIG")
    if env:
        return Path(env).expanduser()
    return Path.home() / "Library" / "Application Support" / "de.upvis.kevcad" / "octoprint.json"


@dataclass(frozen=True)
class Einstellungen:
    url: str = STANDARD_URL
    slicer: str | None = None
    profil: str | None = None
    name: str = "OctoPi"
    datei: str = ""
    datei_da: bool = False

    def oeffentlich(self) -> dict[str, Any]:
        return {"url": self.url, "slicer": self.slicer, "profil": self.profil, "name": self.name,
                "einstellungen": self.datei, "einstellungen_da": self.datei_da}


def lesen() -> Einstellungen:
    p = config_pfad()
    if not p.is_file():
        return Einstellungen(datei=str(p))
    try:
        d = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise EinstellungFehler(f"{p} ist kein gültiges JSON: {exc}") from None
    if not isinstance(d, dict):
        raise EinstellungFehler(f"{p}: erwartet ein JSON-Objekt")
    url = str(d.get("url") or STANDARD_URL).strip().rstrip("/")
    if not url.startswith(("http://", "https://")):
        url = "http://" + url
    profil = d.get("profil")
    slicer = d.get("slicer")
    return Einstellungen(url=url, slicer=str(Path(slicer).expanduser()) if slicer else None,
                         profil=str(Path(profil).expanduser()) if profil else None,
                         name=str(d.get("name") or "OctoPi"), datei=str(p), datei_da=True)


def schreiben(**werte: Any) -> Einstellungen:
    """Einzelne Werte (url, slicer, profil, name) setzen; ``None`` entfernt einen Wert. Nie den API-Schlüssel."""
    p = config_pfad()
    d: dict[str, Any] = {}
    if p.is_file():
        try:
            d = json.loads(p.read_text(encoding="utf-8")) or {}
        except (OSError, ValueError):
            d = {}
    for k, v in werte.items():
        if k not in ("url", "slicer", "profil", "name"):
            raise EinstellungFehler(f"Unbekannte Einstellung {k!r}")
        if v is None:
            d.pop(k, None)
        else:
            d[k] = str(v)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_name(f".{p.name}.tmp")
    tmp.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    tmp.replace(p)
    return lesen()


@dataclass(frozen=True)
class Schluessel:
    wert: str = field(repr=False)
    quelle: str = "schluesselbund"

    def __repr__(self) -> str:  # nie den Wert
        return f"Schluessel({self.quelle})"

    __str__ = __repr__


def schluessel(ausfuehren: Any = None) -> Schluessel:
    """API-Schlüssel aus Umgebung oder Schlüsselbund; Fehler nennen nur, dass er fehlt."""
    env = os.environ.get("KEVCAD_OCTOPRINT_KEY", "").strip()
    if env:
        return Schluessel(env, "umgebung")
    run = ausfuehren or subprocess.run
    try:
        r = run([SECURITY, "find-generic-password", "-s", SCHLUESSEL_DIENST, "-a", SCHLUESSEL_KONTO, "-w"],
                capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        r = None
    wert = (r.stdout or "").strip() if r is not None and r.returncode == 0 else ""
    if not wert:
        raise EinstellungFehler(
            "Kein OctoPrint-API-Schlüssel im Schlüsselbund. In OctoPrint unter Einstellungen > Application Keys "
            "(oder API) einen Schlüssel erzeugen und im Terminal eintragen: security add-generic-password -U "
            f"-s {SCHLUESSEL_DIENST} -a {SCHLUESSEL_KONTO} -w")
    return Schluessel(wert, "schluesselbund")
