"""Schlanker OctoPrint-REST-Client (nur Standardbibliothek).

Benutzte Endpunkte (OctoPrint 1.x): ``GET /api/version``, ``GET /api/printer``, ``GET /api/job``,
``POST /api/files/local`` (Upload, optional ``select``/``print``), ``POST /api/files/local/<pfad>`` (``select`` mit
``print``). Der Schlüssel geht nur im Kopf ``X-Api-Key`` mit und erscheint nie in Fehlermeldungen.
"""

from __future__ import annotations

import json
import mimetypes
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any

from .einstellungen import Schluessel


class OctoPrintFehler(RuntimeError):
    """Verbindungs- oder API-Fehler, Meldung auf Deutsch ohne Schlüssel."""

    def __init__(self, meldung: str, status: int | None = None) -> None:
        super().__init__(meldung)
        self.status = status


class OctoPrintClient:
    def __init__(self, url: str, schluessel: Schluessel, *, timeout_s: float = 10.0,
                 oeffner: Any = None) -> None:
        self.url = url.rstrip("/")
        self._schluessel = schluessel
        self.timeout_s = timeout_s
        self._oeffnen = oeffner or urllib.request.urlopen

    def __repr__(self) -> str:
        return f"OctoPrintClient({self.url})"

    def _anfrage(self, methode: str, pfad: str, *, daten: bytes | None = None, kopf: dict[str, str] | None = None,
                 timeout_s: float | None = None, erlaubt_409: bool = False) -> Any:
        req = urllib.request.Request(self.url + pfad, data=daten, method=methode)
        req.add_header("X-Api-Key", self._schluessel.wert)
        for k, v in (kopf or {}).items():
            req.add_header(k, v)
        try:
            with self._oeffnen(req, timeout=timeout_s or self.timeout_s) as antwort:
                text = antwort.read().decode("utf-8", errors="replace")
        except urllib.error.HTTPError as exc:
            if exc.code == 409 and erlaubt_409:
                return None
            grund = {401: "Schlüssel ungültig oder fehlt", 403: "Schlüssel ohne Berechtigung (oder ungültig)",
                     404: "nicht gefunden", 409: "Drucker nicht bereit (nicht verbunden oder druckt schon)",
                     415: "Dateityp wird nicht angenommen"}.get(exc.code, exc.reason)
            raise OctoPrintFehler(f"OctoPrint {methode} {pfad}: HTTP {exc.code} – {grund}", exc.code) from None
        except urllib.error.URLError as exc:
            raise OctoPrintFehler(f"OctoPrint unter {self.url} nicht erreichbar: {exc.reason}") from None
        except TimeoutError:
            raise OctoPrintFehler(f"OctoPrint unter {self.url} antwortet nicht (Zeitüberschreitung)") from None
        if not text.strip():
            return {}
        try:
            return json.loads(text)
        except ValueError:
            return {"text": text[:500]}

    # --- lesen -----------------------------------------------------------------------------------------------
    def version(self) -> dict[str, Any]:
        return self._anfrage("GET", "/api/version")

    def drucker(self) -> dict[str, Any] | None:
        """Zustand und Temperaturen; None, wenn OctoPrint nicht mit dem Drucker verbunden ist (HTTP 409)."""
        return self._anfrage("GET", "/api/printer", erlaubt_409=True)

    def auftrag(self) -> dict[str, Any]:
        return self._anfrage("GET", "/api/job")

    # --- schreiben -------------------------------------------------------------------------------------------
    def hochladen(self, pfad: str | Path, *, ziel_name: str | None = None, ordner: str = "sk-cad",
                  waehlen: bool = False, drucken: bool = False) -> dict[str, Any]:
        """Datei nach ``local/<ordner>/`` laden; ``drucken`` startet sofort (setzt ``waehlen`` voraus)."""
        p = Path(pfad)
        name = ziel_name or p.name
        grenze = uuid.uuid4().hex
        teile: list[bytes] = []

        def feld(n: str, wert: str) -> None:
            teile.append(f"--{grenze}\r\nContent-Disposition: form-data; name=\"{n}\"\r\n\r\n{wert}\r\n".encode())

        typ = mimetypes.guess_type(name)[0] or "application/octet-stream"
        teile.append(f"--{grenze}\r\nContent-Disposition: form-data; name=\"file\"; "
                     f"filename=\"{name}\"\r\nContent-Type: {typ}\r\n\r\n".encode())
        teile.append(p.read_bytes())
        teile.append(b"\r\n")
        if ordner:
            feld("path", ordner)
        feld("select", "true" if (waehlen or drucken) else "false")
        feld("print", "true" if drucken else "false")
        teile.append(f"--{grenze}--\r\n".encode())
        return self._anfrage("POST", "/api/files/local", daten=b"".join(teile),
                             kopf={"Content-Type": f"multipart/form-data; boundary={grenze}"}, timeout_s=300)

    def starten(self, datei_pfad: str) -> None:
        """Bereits hochgeladene Datei (Pfad unter ``local``) wählen und drucken."""
        ziel = urllib.parse.quote(datei_pfad.lstrip("/"))
        self._anfrage("POST", f"/api/files/local/{ziel}", daten=json.dumps({"command": "select", "print": True})
                      .encode(), kopf={"Content-Type": "application/json"})
