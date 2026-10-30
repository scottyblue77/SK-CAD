"""SK-CAD: STL-Import, OctoPrint-Client, Slicer-Aufruf und Laufzeit (ohne echten Drucker, mit lokalem Testserver)."""

from __future__ import annotations

import json
import struct
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest

from kevcad_kernel.octoprint import einstellungen as einst
from kevcad_kernel.octoprint import slicen
from kevcad_kernel.octoprint.client import OctoPrintClient, OctoPrintFehler
from kevcad_kernel.octoprint.laufzeit import OctoPrintRuntimeMixin
from kevcad_kernel.referenz import ablage as ref_ablage
from kevcad_kernel.stl import datei
from kevcad_kernel.stl.datei import StlFehler
from kevcad_kernel.stl.laufzeit import StlRuntimeMixin

# --- Würfel 10 × 20 × 30 mm als Testnetz -----------------------------------------------------------------------------

ECKEN = np.array([[0, 0, 0], [10, 0, 0], [10, 20, 0], [0, 20, 0], [0, 0, 30], [10, 0, 30], [10, 20, 30], [0, 20, 30]],
                 float) + [5, 5, 5]
FLAECHEN = [[0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7], [0, 1, 5], [0, 5, 4], [1, 2, 6], [1, 6, 5], [2, 3, 7],
            [2, 7, 6], [3, 0, 4], [3, 4, 7]]


def binaer_stl(pfad: Path, flaechen=FLAECHEN) -> Path:
    with open(pfad, "wb") as f:
        f.write(b"solid aber eigentlich binaer".ljust(80, b" "))
        f.write(struct.pack("<I", len(flaechen)))
        for a, b, c in flaechen:
            f.write(struct.pack("<3f", 0, 0, 0))
            for i in (a, b, c):
                f.write(struct.pack("<3f", *ECKEN[i]))
            f.write(b"\0\0")
    return pfad


def ascii_stl(pfad: Path) -> Path:
    zeilen = ["solid wuerfel"]
    for a, b, c in FLAECHEN:
        zeilen += ["facet normal 0 0 0", " outer loop"]
        zeilen += [f"  vertex {x} {y} {z}" for x, y, z in (ECKEN[a], ECKEN[b], ECKEN[c])]
        zeilen += [" endloop", "endfacet"]
    zeilen.append("endsolid wuerfel")
    pfad.write_text("\n".join(zeilen))
    return pfad


@pytest.mark.parametrize("schreiber", [binaer_stl, ascii_stl])
def test_stl_lesen_und_kennzahlen(tmp_path, schreiber):
    tri = datei.lies_stl(schreiber(tmp_path / "w.stl"))
    assert tri.shape == (12, 3, 3)
    pos, ind = datei.netz_aus_dreiecken(tri)
    assert len(pos) == 8 and len(ind) == 12
    k = datei.kennzahlen(pos, ind)
    assert k["masz_mm"] == [10.0, 20.0, 30.0]
    assert k["volumen_cm3"] == pytest.approx(6.0)
    assert k["dicht"] and not k["innen_nach_aussen"]
    bett = datei.auf_bett(pos)
    assert bett[:, 2].min() == 0 and bett[:, 0].min() == -5 and bett[:, 1].max() == 10


def test_stl_offen_und_fehler(tmp_path):
    tri = datei.lies_stl(binaer_stl(tmp_path / "o.stl", FLAECHEN[:-1]))
    k = datei.kennzahlen(*datei.netz_aus_dreiecken(tri))
    assert not k["dicht"] and k["offene_kanten"] == 3
    with pytest.raises(StlFehler):
        datei.lies_stl(tmp_path / "fehlt.stl")
    (tmp_path / "kaputt.stl").write_bytes(b"x" * 80 + struct.pack("<I", 1000))
    with pytest.raises(StlFehler, match="abgeschnitten"):
        datei.lies_stl(tmp_path / "kaputt.stl")


# --- Laufzeit: stl_laden mit Attrappe der Referenzanzeige ------------------------------------------------------------

class Laufzeit(StlRuntimeMixin, OctoPrintRuntimeMixin):
    def __init__(self, projekt: Path | None):
        self._project = SimpleNamespace(path=projekt) if projekt else None
        self.gesendet: list[str] = []

    def _ref_liste_senden(self, sofort: bool = False) -> None:
        self.gesendet.append("liste")

    def _ref_netz_senden(self, projekt: Path, n: str, conn=None) -> None:
        self.gesendet.append(f"netz:{n}")

    def _log(self, text: str) -> None:
        pass


def test_stl_laden_legt_kopie_und_referenz_an(tmp_path):
    proj = tmp_path / "Projekt"
    proj.mkdir()
    lz = Laufzeit(proj)
    res = lz.stl_laden(str(binaer_stl(tmp_path / "Halter V2.stl")))
    assert res["ok"], res
    assert res["name"] == "Halter V2"
    assert (proj / "stl" / "Halter V2.stl").is_file()
    obj = ref_ablage.ordner(proj, "Halter V2") / "capture" / "netz_mm.obj"
    assert obj.is_file()
    from kevcad_kernel.referenz import netz

    m = netz.lies_obj(obj)
    assert m["positions"][:, 2].min() == pytest.approx(0)
    meta = ref_ablage.lese_meta(proj, "Halter V2")
    assert meta["art"] == "stl" and meta["stl"]["dicht"]
    assert lz.gesendet == ["liste", "netz:Halter V2"]
    # zweites Laden: neuer Name, nichts überschrieben
    res2 = lz.stl_laden(str(tmp_path / "Halter V2.stl"))
    assert res2["name"] == "Halter V2 2"
    assert [e["name"] for e in lz.stl_liste()["stl"]] == ["Halter V2", "Halter V2 2"]
    assert lz.stl_datei("Halter V2") == proj / "stl" / "Halter V2.stl"
    with pytest.raises(StlFehler, match="Vorhanden"):
        lz.stl_datei("Gibtsnicht")


def test_stl_laden_ohne_projekt_und_falscher_typ(tmp_path):
    assert "Kein Projekt" in Laufzeit(None).stl_laden(str(tmp_path / "x.stl"))["error"]
    lz = Laufzeit(tmp_path)
    assert "keine .stl" in lz.stl_laden(str(tmp_path / "x.obj"))["error"]


# --- Einstellungen und Schlüssel -------------------------------------------------------------------------------------

@pytest.fixture
def config(tmp_path, monkeypatch):
    p = tmp_path / "octoprint.json"
    monkeypatch.setenv("KEVCAD_OCTOPRINT_CONFIG", str(p))
    monkeypatch.delenv("KEVCAD_OCTOPRINT_KEY", raising=False)
    return p


def test_einstellungen_standard_und_schreiben(config):
    e = einst.lesen()
    assert e.url == "http://192.168.1.233" and not e.datei_da
    e = einst.schreiben(url="192.168.1.50:5000/", profil="~/drucker.ini")
    assert e.url == "http://192.168.1.50:5000"
    assert e.profil.endswith("drucker.ini") and "~" not in e.profil
    assert "api_key" not in json.loads(config.read_text())
    with pytest.raises(einst.EinstellungFehler):
        einst.schreiben(api_key="geheim")


def test_schluessel_nie_im_text(config, monkeypatch):
    def security(cmd, **kw):
        assert cmd[:2] == [einst.SECURITY, "find-generic-password"]
        return subprocess.CompletedProcess(cmd, 0, stdout="GEHEIM123\n", stderr="")

    s = einst.schluessel(security)
    assert s.wert == "GEHEIM123" and "GEHEIM" not in repr(s) and "GEHEIM" not in str(s)
    with pytest.raises(einst.EinstellungFehler, match="security add-generic-password"):
        einst.schluessel(lambda cmd, **kw: subprocess.CompletedProcess(cmd, 44, stdout="", stderr="nicht da"))
    monkeypatch.setenv("KEVCAD_OCTOPRINT_KEY", "AUSUMGEBUNG")
    assert einst.schluessel().quelle == "umgebung"


# --- OctoPrint-Testserver --------------------------------------------------------------------------------------------

class FakeOcto:
    def __init__(self):
        self.anfragen: list[tuple[str, str, bytes, str | None]] = []
        self.verbunden = True
        self.druckt = False
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _antwort(self, code, daten=None):
                body = json.dumps(daten or {}).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def _merken(self):
                n = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(n) if n else b""
                fake.anfragen.append((self.command, self.path, body, self.headers.get("X-Api-Key")))
                return body

            def do_GET(self):
                self._merken()
                if self.headers.get("X-Api-Key") != "KEY":
                    return self._antwort(403, {"error": "Forbidden"})
                if self.path == "/api/version":
                    return self._antwort(200, {"server": "1.10.3", "api": "0.1"})
                if self.path == "/api/printer":
                    if not fake.verbunden:
                        return self._antwort(409, {"error": "Printer is not operational"})
                    flags = {"operational": True, "ready": not fake.druckt, "printing": fake.druckt}
                    return self._antwort(200, {"state": {"text": "Printing" if fake.druckt else "Operational",
                                                         "flags": flags},
                                               "temperature": {"tool0": {"actual": 24.5, "target": 0},
                                                               "bed": {"actual": 23.0, "target": 0}}})
                if self.path == "/api/job":
                    return self._antwort(200, {"state": "Operational", "job": {"file": {"name": None}},
                                               "progress": {"completion": None}})
                return self._antwort(404)

            def do_POST(self):
                body = self._merken()
                if self.path == "/api/files/local":
                    name = body.split(b'filename="')[1].split(b'"')[0].decode()
                    return self._antwort(201, {"done": True, "files": {"local": {"path": f"sk-cad/{name}"}}})
                if self.path.startswith("/api/files/local/"):
                    return self._antwort(204)
                return self._antwort(404)

        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()


@pytest.fixture
def octo(config, monkeypatch):
    f = FakeOcto()
    config.write_text(json.dumps({"url": f.url}))
    monkeypatch.setenv("KEVCAD_OCTOPRINT_KEY", "KEY")
    yield f
    f.server.shutdown()


def test_client_status_und_fehler(octo):
    c = OctoPrintClient(octo.url, einst.Schluessel("KEY"))
    assert c.version()["server"] == "1.10.3"
    assert c.drucker()["state"]["text"] == "Operational"
    octo.verbunden = False
    assert c.drucker() is None
    falsch = OctoPrintClient(octo.url, einst.Schluessel("FALSCH"))
    with pytest.raises(OctoPrintFehler, match="403") as info:
        falsch.version()
    assert "FALSCH" not in str(info.value)
    with pytest.raises(OctoPrintFehler, match="nicht erreichbar"):
        OctoPrintClient("http://127.0.0.1:1", einst.Schluessel("KEY"), timeout_s=2).version()


def test_status_der_laufzeit(octo, tmp_path):
    res = Laufzeit(tmp_path).octoprint_status()
    assert res["ok"] and res["octoprint"] == "1.10.3"
    assert res["drucker"]["verbunden"] and res["drucker"]["duese"]["ist"] == 24.5
    assert "KEY" not in json.dumps(res)


def _gcode(pfad: Path) -> Path:
    pfad.write_text("G28\nG1 X10\n; filament used [mm] = 1234.5\n; filament used [g] = 3.71\n"
                    "; estimated printing time (normal mode) = 25m 12s\n")
    return pfad


def test_gcode_hochladen_ohne_start(octo, tmp_path):
    lz = Laufzeit(tmp_path)
    res = lz.octoprint_drucken(str(_gcode(tmp_path / "teil.gcode")))
    assert res["ok"], res
    assert not res["gestartet"] and "NICHT gestartet" in res["meldung"]
    assert res["druckzeit"] == "25m 12s" and res["filament_g"] == 3.71
    methode, pfad, body, key = octo.anfragen[-1]
    assert (methode, pfad, key) == ("POST", "/api/files/local", "KEY")
    assert b'name="print"\r\n\r\nfalse' in body and b'name="select"\r\n\r\ntrue' in body
    assert b"G28" in body and res["octoprint_datei"].startswith("sk-cad/teil-")


def test_starten_nur_wenn_bereit(octo, tmp_path):
    lz = Laufzeit(tmp_path)
    g = _gcode(tmp_path / "teil.gcode")
    octo.druckt = True
    res = lz.octoprint_drucken(str(g), starten=True)
    assert not res["ok"] and "nicht bereit" in res["error"]
    assert not any(p == "/api/files/local" for _, p, _, _ in octo.anfragen)
    octo.druckt = False
    res = lz.octoprint_drucken(str(g), starten=True)
    assert res["ok"] and res["gestartet"]
    assert b'name="print"\r\n\r\ntrue' in octo.anfragen[-1][2]
    octo.verbunden = False
    assert "nicht mit dem Drucker verbunden" in lz.octoprint_drucken(str(g), starten=True)["error"]
    assert "nicht mit dem Drucker" in lz.octoprint_starten("sk-cad/x.gcode")["error"]


def test_stl_wird_geslict_und_hochgeladen(octo, tmp_path, monkeypatch):
    proj = tmp_path / "P"
    proj.mkdir()
    lz = Laufzeit(proj)
    lz.stl_laden(str(binaer_stl(tmp_path / "Teil.stl")))
    profil = tmp_path / "drucker.ini"
    profil.write_text("layer_height = 0.2\n")
    slicer = tmp_path / "PrusaSlicer"
    slicer.write_text("#!/bin/sh\n")
    slicer.chmod(0o755)
    einst.schreiben(profil=str(profil), slicer=str(slicer))
    aufrufe = []

    def fake_run(cmd, **kw):
        aufrufe.append(cmd)
        _gcode(Path(cmd[cmd.index("--output") + 1]))
        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

    monkeypatch.setattr(slicen.subprocess, "run", fake_run)
    res = lz.octoprint_drucken("Teil")
    assert res["ok"], res
    assert aufrufe[0][:4] == [str(slicer), "--export-gcode", "--load", str(profil)]
    assert aufrufe[0][-1] == str(proj / "stl" / "Teil.stl")
    assert Path(res["gcode"]) == proj / "output" / "Teil.gcode"
    assert not res["gestartet"]


def test_slicer_fehlermeldungen(tmp_path, monkeypatch):
    stl = binaer_stl(tmp_path / "t.stl")
    with pytest.raises(slicen.SlicerFehler, match="Kein Slicer-Profil"):
        slicen.slicen(stl, None, tmp_path / "t.gcode")
    with pytest.raises(slicen.SlicerFehler, match="nicht gefunden"):
        slicen.slicen(stl, str(tmp_path / "fehlt.ini"), tmp_path / "t.gcode")
    profil = tmp_path / "p.ini"
    profil.write_text("")
    monkeypatch.setattr(slicen, "KANDIDATEN", ())
    monkeypatch.setattr(slicen, "PATH_NAMEN", ())
    monkeypatch.delenv("KEVCAD_SLICER", raising=False)
    with pytest.raises(slicen.SlicerFehler, match="PrusaSlicer nicht gefunden"):
        slicen.slicen(stl, str(profil), tmp_path / "t.gcode")


# --- MCP-Werkzeuge gegen die Dienst-Attrappe -------------------------------------------------------------------------

def test_mcp_werkzeuge():
    import anyio
    from mcp_testutil import start_server, texts, with_client

    server, svc = start_server()
    try:
        async def go(client):
            r1 = await client.call_tool("stl_laden", {"pfad": "~/Downloads/Teil.stl"})
            r2 = await client.call_tool("octoprint_status", {})
            r3 = await client.call_tool("octoprint_drucken", {"datei": "Teil"})
            return ["\n".join(texts(r)) for r in (r1, r2, r3)]

        t1, t2, t3 = anyio.run(with_client, server.url, go)
    finally:
        server.stop_thread()
    assert "10.0 × 20.0 × 30.0 mm" in t1
    assert "1.10.3" in t2 and "Operational" in t2
    assert "nicht gestartet" in t3
    assert svc.calls_of("octoprint_drucken")[0][0] == ("Teil", False, None)
