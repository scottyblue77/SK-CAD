"""Kernel-Laufzeit: implementiert ``KernelService`` (service.py).

Besitzt den Unix-Socket zur App (app_link.py), den Rechenprozess (worker.py), das offene Projekt (project.py), die
Szene mit den Teilen des aktuellen Stands (refs.py), das Ergebnis des letzten Laufs und die Auswahl aus der App.

Fäden:
- ``kevcad-jobs``: arbeitet Läufe und ``execute`` nacheinander ab (der Rechenprozess kann nur eins zugleich).
- ``kevcad-watch``: beobachtet model.py (mtime alle 250 ms, 300 ms entprellt) für den Auto-Lauf.
- Lesefäden des Rechenprozesses: leiten ``PART``/``STEP`` sofort an die App weiter.
- App-Verbindung: Lese- und Schreibfaden; Anfragen der App, die länger dauern können, laufen in einem kleinen Pool.

Debug ohne MCP: ``python -m kevcad_kernel.runtime --socket PFAD [--project ORDNER]`` startet die Laufzeit und blockiert.
"""

from __future__ import annotations

import argparse
import collections
import concurrent.futures
import hashlib
import importlib.metadata
import itertools
import json
import os
import signal
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import kevcad_kernel
from kevcad_kernel.anim_runtime import AnimationRuntimeMixin
from kevcad_kernel.app_link import AppConnection, AppLink
from kevcad_kernel.bauplan.dienst import BauplanDienst
from kevcad_kernel.bestand.anbindung import ANFRAGEN as BESTAND_ANFRAGEN
from kevcad_kernel.bestand.anbindung import BestandAnbindung
from kevcad_kernel.dokument_export import DokumentExportDienst
from kevcad_kernel.bom import inventory_text
from kevcad_kernel.catalog import ALLE_ARTEN, STANGENWARE, ZUKAUF_ARTEN, Catalog, CatalogError, own_dir
from kevcad_kernel.druck.laufzeit import DruckRuntime
from kevcad_kernel.drucker.laufzeit import DruckerRuntimeMixin  # Phase 8: Drucken auf dem P1P
from kevcad_kernel.octoprint.laufzeit import OctoPrintRuntimeMixin  # SK-CAD: Drucken über OctoPrint
from kevcad_kernel.stl.laufzeit import StlRuntimeMixin  # SK-CAD: STL laden
from kevcad_kernel.druck.vorschau_laufzeit import DruckvorschauRuntime
from kevcad_kernel.druck.gedruckt import GedrucktAnbindung
from kevcad_kernel.freigabe import FreigabeAnbindung
from kevcad_kernel.kamera import CameraRuntime
from kevcad_kernel.project import Project, ProjectError, new_project, open_project
from kevcad_kernel.statik.laufzeit import StatikRuntime  # Statik Stufe 1: statik, szenario_rechnen, STATICS
from kevcad_kernel.statik.dynamik.laufzeit import DynamikRuntime  # Statik Stufe 2: dynamik, Ablauf als Animation
from kevcad_kernel.statik.festkoerper.laufzeit import FestkoerperRuntime  # Statik Stufe 3: festigkeit, FEM
from kevcad_kernel.topologie.laufzeit import TopologieRuntime  # Topologieoptimierung (PLAN-TOPOLOGIE.md)
from kevcad_kernel.simulation.laufzeit import SimulationRuntime  # Bereich „Simulation“ (PLAN-SIMULATION.md)
from kevcad_kernel.pruefung.anbindung import PruefStand, fuer_ergebnis
from kevcad_kernel.pruefung.dienst import PruefDienst
from kevcad_kernel.protocol import PROTOCOL_VERSION
from kevcad_kernel.referenz.laufzeit import ReferenzRuntimeMixin  # Phase 4: Foto und Video als Referenz
from kevcad_kernel.render.laufzeit import RenderRuntime  # Phase 7: Renderings
from kevcad_kernel.scan.laufzeit import ScanRuntimeMixin  # Scan mit dem iPhone (SCAN.md, PLAN-SCAN.md)
from kevcad_kernel.refs import RefError, Scene
from kevcad_kernel.versionen.laufzeit import VersionenRuntimeMixin
from kevcad_kernel.worker import WorkerClient
from kevcad_kernel.zukauf.dienst import ZukaufDienst
from kevcad_kernel.zeichnung.laufzeit import ZeichnungRuntimeMixin

APP_NOT_CONNECTED = "App nicht verbunden"
NO_PROJECT = "Kein Projekt offen. Erst project_open oder project_new aufrufen."
WORKER_START_TIMEOUT_S = 240.0  # erster Import von build123d in frischer Umgebung dauert bis ~50 s


def _log(line: str) -> None:
    print(line, file=sys.stderr, flush=True)


def _b123d_version() -> str:
    try:
        return importlib.metadata.version("build123d")
    except importlib.metadata.PackageNotFoundError:
        return "?"


def _params_key(params: dict[str, Any] | None) -> str:
    return json.dumps(params or {}, sort_keys=True, default=str)


@dataclass
class Job:
    kind: str  # "run" | "exec" | "schatten" (Lauf ohne Live-Aufbau, Versionen) | "aufgabe" (fn im Auftragsfaden)
    code: str
    source: str  # agent | app | auto
    timeout_s: float
    path: str = ""
    params: dict[str, Any] = field(default_factory=dict)
    slow_ms: int = 0
    file_hash: str = ""
    run: int = 0
    generation: int = 0
    done: threading.Event = field(default_factory=threading.Event)
    finished: threading.Event = field(default_factory=threading.Event)
    final: dict[str, Any] | None = None
    result: dict[str, Any] | None = None
    steps: list[str] = field(default_factory=list)
    started: float = 0.0
    cancelled: str | None = None  # Grund, wenn der Lauf nicht mehr zählt (anderes Projekt geöffnet)
    animations: list = field(default_factory=list)  # Phase 5: ANIM-Nachrichten des Rechenprozesses (Kopf, Nutzlast)
    teile: list = field(default_factory=list)  # Versionen: Teile eines Schattenlaufs (Name, Schlüssel, Kopf, Nutzlast)
    fn: Any = None  # Versionen: Aufgabe für kind "aufgabe"

    @property
    def key(self) -> tuple[str, str, str]:
        return self.kind, self.file_hash, _params_key(self.params)


class KernelRuntime(BestandAnbindung, AnimationRuntimeMixin, CameraRuntime, DruckRuntime, PruefDienst, BauplanDienst,
                    ZeichnungRuntimeMixin, VersionenRuntimeMixin, DokumentExportDienst, DruckvorschauRuntime,
                    DruckerRuntimeMixin, FreigabeAnbindung, GedrucktAnbindung, ReferenzRuntimeMixin,
                    StatikRuntime, DynamikRuntime, RenderRuntime, FestkoerperRuntime, ScanRuntimeMixin,
                    TopologieRuntime, SimulationRuntime, StlRuntimeMixin, OctoPrintRuntimeMixin):
    """Fassade für die MCP-Werkzeuge (KernelService) und Gegenstelle der App. Bestand je Projekt: bestand/anbindung.py.
    Phase 5: Animation (``AnimationRuntimeMixin``) und Kameras (``CameraRuntime``); Druckprüfung (``DruckRuntime``);
    Prüfung: pruefen, ansichten (``PruefDienst``, pruefung/dienst.py); Phase 6: Bauplan (``BauplanDienst``) und
    Zeichnungen (``ZeichnungRuntimeMixin``); Versionen (``VersionenRuntimeMixin``); Dokumente exportieren
    (``DokumentExportDienst``, dokument_export.py); Druckvorschau (``DruckvorschauRuntime``, druck/vorschau_laufzeit.py)."""

    def __init__(self, socket_path: str, mcp_port: int, *, auto_run: bool = True, run_timeout_s: float = 120.0,
                 poll_interval_s: float = 0.25, debounce_s: float = 0.3, start_worker: bool = True,
                 log=None) -> None:
        self.socket_path = socket_path
        self.mcp_port = mcp_port
        self.run_timeout_s = run_timeout_s
        self.poll_interval_s = poll_interval_s
        self.debounce_s = debounce_s
        self._log = log or _log
        self._lock = threading.RLock()  # Zustand
        self._app_lock = threading.RLock()  # Reihenfolge der Rahmen an die App
        self._occ_lock = threading.RLock()  # OCCT-Arbeit im Elternprozess (Messen, Export) nacheinander
        self._jobs_cond = threading.Condition(threading.Lock())
        self._jobs: collections.deque[Job] = collections.deque()
        self._current: Job | None = None
        self._closed = False
        self.scene = Scene()
        self._project: Project | None = None
        self._settings: dict[str, Any] = {"auto_run": bool(auto_run), "slow_ms": 0}
        self._agent: dict[str, Any] = {"connected": False, "activity": None, "sessions": []}
        self._selection: dict[str, Any] = {"run": None, "refs": []}
        self._last_result: dict[str, Any] | None = None
        self._bom: dict[str, Any] | None = None  # Stückliste des letzten erfolgreichen Laufs (wie die Nachricht BOM)
        self._violations: list[str] = []  # Inventar-Regel: Teile des letzten erfolgreichen Laufs ohne Lager/Druck
        self._constraints: dict[str, Any] | None = None  # Bericht der Bedingungen des letzten erfolgreichen Laufs
        self._pruef = PruefStand()  # Prüfung nach jedem Lauf (Durchdringungen …), siehe pruefung/anbindung.py
        self._run_end_run = 0  # letzter Lauf, für den RUN_END an die App ging (unter _app_lock)
        self.pruef_warten_s = 120.0  # so lange wartet run auf das Prüfergebnis
        self.bedingungen_warten_s = 60.0  # so lange wartet bedingungen() auf den Bewegungsraum im Hintergrund
        self.catalog = Catalog(own=own_dir(socket_path))
        self.zukauf = ZukaufDienst(self)  # Phase 3: Zukaufteile
        self._last_hash: str | None = None  # zuletzt angestoßener Dateistand (für den Auto-Lauf)
        self._run_no = 0
        self._regler: dict[str, Any] = {}  # überschriebene Parameter des letzten erfolgreichen Laufs (Reglerstand)
        self._state: tuple[str, str] = ("busy", "Rechenprozess startet")
        self._pending: dict[str, dict[str, Any]] = {}
        self._ids = itertools.count(1)
        self._annotations = itertools.count(1)
        self._pool = concurrent.futures.ThreadPoolExecutor(max_workers=4, thread_name_prefix="kevcad-app")
        self._zeichnung_init()  # Phase 6: Zeichnungen
        self._versionen_init()
        self._worker = WorkerClient(self._on_worker_message, self._on_worker_exit, log=self._log)
        self._bestand_init()
        self._freigabe_init()  # Freigabe im Projektfenster (freigabe.py)
        self._drucker_init()  # Phase 8: Drucken (drucker/laufzeit.py)
        self._druckvorschau_init()  # Druckvorschau (DRUCKVORSCHAU.md)
        self._referenz_init()  # Phase 4: Referenzen (referenz/laufzeit.py)
        self._scan_init()  # Scan mit dem iPhone: Empfänger (scan/laufzeit.py), nur mit App-Variante
        self._link = AppLink(socket_path, self._on_app_connect, self._on_app_message, self._on_app_disconnect,
                             log=self._log)
        self._link.start()
        self._threads = [
            threading.Thread(target=self._job_loop, name="kevcad-jobs", daemon=True),
            threading.Thread(target=self._watch_loop, name="kevcad-watch", daemon=True),
            threading.Thread(target=self._warm_parent, name="kevcad-warm", daemon=True),
        ]
        for t in self._threads:
            t.start()
        if start_worker:
            self._spawn_worker()

    # =================================================================================================================
    # KernelService: Projekt
    # =================================================================================================================

    def status(self) -> dict[str, Any]:
        with self._lock:
            proj = self._project.info() if self._project else None
            state, message = self._state
            return {
                "project": proj,
                "kernel": state,
                "message": message,
                "app_connected": self._link.connected,
                "last_run": self._last_result,
                "selection": dict(self._selection),
                "settings": dict(self._settings),
                "worker": {"alive": self._worker.alive, "ready": self._worker.ready,
                           "pid": self._worker.info.get("pid"), "restarts": max(0, self._worker.generation - 1)},
                "agent": dict(self._agent),
                "inventar": {"regel": self._project.inventar_regel if self._project else True,
                             "verstoesse": list(self._violations)},
                "bedingungen": dict((self._constraints or {}).get("summe") or {}),
                "pruefung": self._pruef.kurz(),
            }

    def project_open(self, path: str, reply_to: str | None = None) -> dict[str, Any]:
        try:
            proj = open_project(path)
        except ProjectError as exc:
            return {"ok": False, "error": str(exc)}
        self._set_project(proj, reply_to)
        out = {"ok": True, **proj.info()}
        if proj.warnings:
            out["warnings"] = list(proj.warnings)
        return out

    def project_new(self, path: str, template: str = "example", reply_to: str | None = None) -> dict[str, Any]:
        try:
            proj = new_project(path, template)
        except ProjectError as exc:
            return {"ok": False, "error": str(exc)}
        self._set_project(proj, reply_to)
        return {"ok": True, **proj.info(), "template": template}

    def model_read(self) -> dict[str, Any]:
        proj = self._project
        if proj is None:
            return {"ok": False, "error": NO_PROJECT}
        try:
            return {"ok": True, "path": str(proj.model), "code": proj.model.read_text(encoding="utf-8")}
        except OSError as exc:
            return {"ok": False, "error": f"model.py nicht lesbar: {exc}"}

    def model_write(self, code: str) -> dict[str, Any]:
        proj = self._project
        if proj is None:
            return {"ok": False, "error": NO_PROJECT}
        if not isinstance(code, str):
            return {"ok": False, "error": "code muss Text sein"}
        try:
            data = code.encode("utf-8")
            tmp = proj.model.with_name(f".{proj.model.name}.tmp")
            tmp.write_bytes(data)
            os.replace(tmp, proj.model)
            return {"ok": True, "path": str(proj.model), "bytes": len(data)}
        except OSError as exc:
            return {"ok": False, "error": f"model.py nicht schreibbar: {exc}"}

    # =================================================================================================================
    # KernelService: Lauf
    # =================================================================================================================

    def run(self, params: dict[str, float] | None = None, slow_ms: int = 0, timeout_s: float = 120,
            titel: str | None = None) -> dict[str, Any]:
        job = self._submit_run(params, slow_ms, timeout_s, source="agent")
        if isinstance(job, dict):
            return job
        job.done.wait()
        result = job.result or {"ok": False, "error": "Lauf ohne Ergebnis beendet"}
        if result.get("ok") and job.run:
            check = fuer_ergebnis(self._pruef.warte(job.run, self.pruef_warten_s))
            if check is not None:
                result = {**result, "pruefung": check}
        if titel:  # Versionen: Titel des Agenten für die Version dieses Laufs (versionen/laufzeit.py)
            result = self._versionen_agent_titel(result, titel)
        return result

    def execute(self, code: str, timeout_s: float = 60) -> dict[str, Any]:
        with self._lock:
            proj = self._project
            run = self._run_no
        job = Job(kind="exec", code=code, source="agent", timeout_s=float(timeout_s or 60),
                  path=str(proj.path) if proj else "", run=run)
        self._enqueue(job)
        job.done.wait()
        return job.result or {"ok": False, "error": "execute ohne Ergebnis beendet"}

    def parts(self) -> list[dict[str, Any]]:
        return [r.summary() for r in self.scene.records()]

    # =================================================================================================================
    # KernelService: Messen und Auswahl
    # =================================================================================================================

    def measure(self, refs: list[str], show: bool = False, run: int | None = None) -> dict[str, Any]:
        refs = [refs] if isinstance(refs, str) else list(refs or [])
        base: dict[str, Any] = {"refs": refs, "run": run if run is not None else self._run_no}
        if len(refs) not in (1, 2):
            return {"ok": False, **base, "error": "Messen braucht eine oder zwei Referenzen"}
        try:
            from kevcad_kernel.measure import measure as do_measure
            from kevcad_kernel.refs import resolve

            with self._occ_lock:
                resolved = [resolve(self.scene, r, run=run, latest_run=self._run_no) for r in refs]
                res = do_measure(resolved)
        except RefError as exc:
            return {"ok": False, **base, "error": str(exc)}
        except Exception as exc:  # noqa: BLE001
            return {"ok": False, **base, "error": f"Messen fehlgeschlagen: {type(exc).__name__}: {exc}"}
        result = {"ok": True, **base, **res}
        if show:
            aid = f"m-{next(self._annotations)}"
            kind = "dimension" if len(refs) == 2 and len(res.get("points", [])) == 2 else "label"
            args = {"kind": kind, "points": res.get("points", []), "text": res.get("text", ""), "id": aid}
            if self._send_view_nowait("annotate", args):
                result["annotation"] = aid
        return result

    def selection(self) -> dict[str, Any]:
        with self._lock:
            sel = dict(self._selection)
        refs = list(sel.get("refs") or [])
        details = [self.measure([r], show=False, run=sel.get("run")) for r in refs]
        return {"run": sel.get("run"), "refs": refs, "details": details}

    # =================================================================================================================
    # KernelService: Ansicht und Bild (über die App)
    # =================================================================================================================

    def view_command(self, cmd: str, args: dict[str, Any], timeout_s: float = 10) -> dict[str, Any]:
        args = dict(args or {})
        if not self._link.connected:
            return {"ok": False, "error": APP_NOT_CONNECTED}
        bad = self._check_view_refs(cmd, args)
        if bad:
            return {"ok": False, "error": bad}
        reply, _payload, error = self._request({"type": "VIEW_CMD", "cmd": cmd, "args": args}, timeout_s)
        if error:
            return {"ok": False, "error": error}
        ok = bool(reply.get("ok", True))
        if ok and cmd == "visibility":
            self._apply_visibility(args)
        out = {"ok": ok}
        if reply.get("message"):
            out["message" if ok else "error"] = reply["message"]
        elif not ok:
            out["error"] = "App hat den Befehl abgelehnt"
        return out

    def screenshot(self, width: int = 1280, height: int = 800, source: str = "current", view: str | None = None,
                   hide_overlays: bool = False, timeout_s: float = 15) -> dict[str, Any]:
        if not self._link.connected:
            return {"ok": False, "error": APP_NOT_CONNECTED}
        req = {"type": "SCREENSHOT_REQ", "width": int(width), "height": int(height), "source": source,
               "view": view if source == "offscreen" else None, "hide_overlays": bool(hide_overlays)}
        reply, payload, error = self._request(req, timeout_s)
        if error:
            return {"ok": False, "error": error}
        if not reply.get("ok", False):
            return {"ok": False, "error": reply.get("message") or "App konnte kein Bild erzeugen"}
        return {"ok": True, "png": payload, "width": reply.get("width", width), "height": reply.get("height", height),
                "camera": reply.get("camera") or {}, "mm_per_px": reply.get("mm_per_px")}

    # =================================================================================================================
    # KernelService: Export, Agent, Ende
    # =================================================================================================================

    def export(self, formats: list[str], parts: list[str] | None = None) -> dict[str, Any]:
        proj = self._project
        if proj is None:
            return {"ok": False, "error": NO_PROJECT}
        from kevcad_kernel.export import ExportError, export_records

        formats = [str(f) for f in (formats or [])]
        with self._lock:
            violations = list(self._violations)
            constraints = self._constraints
        locked = [f for f in formats if f.lower().lstrip(".") in ("step", "stp", "stl", "3mf", "bom_csv", "csv")]
        if violations and locked:
            return {"ok": False, "error": "Export verweigert. " + inventory_text(violations),
                    "inventar_verstoesse": violations}
        if locked:
            from kevcad_kernel.pruefung.text import export_sperre

            offen, laeuft = self._pruef.offen(warten_s=60.0)
            sperre = export_sperre(offen, laeuft)
            if sperre:
                return {"ok": False, "error": sperre, "befunde": offen}
        want_csv = any(f.lower().lstrip(".") in ("bom_csv", "csv") for f in formats)
        want_einkauf = any(f.lower().lstrip(".") == "einkaufsliste_csv" for f in formats)
        formats = [f for f in formats if f.lower().lstrip(".") not in ("bom_csv", "csv", "einkaufsliste_csv")]
        csv_files: list[str] = []
        csv_notes: list[str] = []
        if want_einkauf:  # Einkaufsliste (BESTAND.md), ohne Sperre: sie beschreibt nur, was fehlt
            res = self._bestand_export_csv(proj)
            if res.get("ok"):
                csv_files.append(res["file"])
            else:
                csv_notes.append(res["error"])
            if not formats and not want_csv:
                out_e: dict[str, Any] = {"ok": bool(csv_files), "files": csv_files}
                if csv_notes:
                    out_e["error"] = "; ".join(csv_notes)
                return out_e
        if want_csv:
            res = self._export_bom_csv(proj)
            if res.get("ok"):
                csv_files.append(res["file"])
            else:
                csv_notes.append(res["error"])
            if not formats:
                out: dict[str, Any] = {"ok": bool(csv_files), "files": csv_files}
                if csv_notes:
                    out["error"] = "; ".join(csv_notes)
                return out
        try:
            if parts:
                records = self.scene.select(list(parts))
                base = proj.name if len(parts) != 1 else f"{proj.name}-{parts[0].replace('/', '-')}"
            else:
                records = [r for r in self.scene.records() if not r.name.startswith("Skizze/")]
                base = proj.name
            with self._occ_lock:
                files, notes = export_records(records, list(formats or []), proj.output_dir, base)
        except (RefError, ExportError) as exc:
            return {"ok": False, "error": str(exc)}
        except Exception as exc:  # noqa: BLE001
            return {"ok": False, "error": f"Export fehlgeschlagen: {type(exc).__name__}: {exc}"}
        files = files + csv_files
        notes = notes + csv_notes
        out = {"ok": bool(files), "files": files}
        if notes:
            out["warnings"] = notes
        if not files:
            out["error"] = "; ".join(notes) or "Keine Datei geschrieben"
        return out

    def _export_bom_csv(self, proj: Project) -> dict[str, Any]:
        from kevcad_kernel.bom import to_csv
        from kevcad_kernel.export import safe_name

        with self._lock:
            bom = self._bom
        if bom is None:
            return {"ok": False, "error": "Stückliste: noch kein erfolgreicher Lauf"}
        path = (proj.output_dir / f"{safe_name(proj.name)}-stueckliste.csv").resolve()
        try:
            proj.output_dir.mkdir(parents=True, exist_ok=True)
            path.write_text(to_csv(bom, proj.name), encoding="utf-8-sig", newline="")
        except OSError as exc:
            return {"ok": False, "error": f"Stückliste nicht geschrieben: {exc}"}
        return {"ok": True, "file": str(path)}

    # =================================================================================================================
    # KernelService: Phase 2 (Lagerteile, Materialien, Stückliste)
    # =================================================================================================================

    def constraints(self, part: str | None = None) -> dict[str, Any]:
        """Bericht der Bedingungen des letzten erfolgreichen Laufs (wie die Nachricht CONSTRAINTS)."""
        with self._lock:
            rep = self._constraints
        if rep is None:
            return {"ok": False, "error": "Noch kein Bericht: erst run aufrufen."}
        out = {"ok": True, **rep}
        # Bewegungsraum prüft die gemeinsame Prüfung nach RUN_END: ihre Befunde dazunehmen, wenn sie zum Lauf gehören.
        # Rechnet er noch im Hintergrund (CHECK „teilweise“), kurz auf den Endstand warten
        if self._pruef.hintergrund == rep.get("run"):
            self._pruef.warte(int(rep["run"]), self.bedingungen_warten_s, endstand=True, statik=False)
        check, _ = self._pruef.letztes()
        if check is not None and check.get("run") == rep.get("run") and check.get("state") == "teilweise":
            out["bewegungsraum_im_hintergrund"] = list(check.get("im_hintergrund") or [])
        if check is not None and check.get("run") == rep.get("run"):
            weg = [{**b, "pruefung": "bewegungsraum"} for b in check.get("befunde") or []
                   if b.get("art") == "bewegungsraum"]
            if weg:
                out["befunde"] = list(out.get("befunde") or []) + weg
        if part:
            names = self.scene.names()
            if part not in names and not any(n.startswith(part.rstrip("/") + "/") for n in names):
                from kevcad_kernel.refs import unknown_part_message

                return {"ok": False, "error": unknown_part_message(part, names)}
            out["teil"] = part
        return out

    def bom(self) -> dict[str, Any]:
        with self._lock:
            bom = self._bom
        if bom is None:
            return {"ok": False, "error": "Noch keine Stückliste: erst run aufrufen (Lagerteile mit "
                                          "lager.teil(...).verbauen(...) oder Teile mit material= zeigen)."}
        out = {"ok": True, **bom}
        try:  # Strang „Feinschliff 2“: Filament der Druckteile aus der Druckvorschau desselben Laufs
            from kevcad_kernel.druck.vorschau import filament_je_zeile

            with self._dv_lock:
                dv = self._dv_vorschau
            fil = filament_je_zeile(bom, dv)
            if fil:
                out["druck_filament"] = {str(k): v for k, v in fil.items()}
        except Exception:  # noqa: BLE001 - die Stückliste kommt auch ohne
            pass
        if bom.get("einkaufsliste") is not None:  # Einkaufsliste wie in der App (Text wie „Teilen“)
            from kevcad_kernel.bestand.einkauf import heute_text, text

            e = self.einkauf_zusammenstellen(bom)
            proj = self._project
            if e is not None:
                out["einkauf_text"] = text(e, proj.name if proj is not None else None, heute_text())
        return out

    def stock_search(self, query: str = "", art: str | None = None, limit: int = 30) -> dict[str, Any]:
        if art is not None and art not in ALLE_ARTEN:
            return {"ok": False, "error": f"art {art!r} unbekannt (erlaubt: {', '.join(ALLE_ARTEN)})"}
        try:
            items, total = self.catalog.search(query or "", art=art or None, limit=max(1, int(limit or 30)))
        except Exception as exc:  # noqa: BLE001
            return {"ok": False, "error": f"Katalog nicht lesbar: {type(exc).__name__}: {exc}"}
        out = {"ok": True, "items": [self._with_values(it) for it in items], "total": total}
        if self.catalog.warnings:
            out["warnings"] = list(self.catalog.warnings)
        return out

    def stock_get(self, stock_id: str) -> dict[str, Any]:
        it = self.catalog.item(str(stock_id or "").strip())
        if it is None:
            hits, _ = self.catalog.search(str(stock_id or ""), limit=5)
            import difflib

            close = difflib.get_close_matches(str(stock_id), self.catalog.item_ids(), n=3, cutoff=0.6)
            tips = list(dict.fromkeys(close + [h["id"] for h in hits]))[:5]
            return {"ok": False, "error": f"Lagerteil {stock_id!r} gibt es nicht"
                                          + (f"; meinten Sie {', '.join(repr(t) for t in tips)}?" if tips else ".")}
        values = self._values(it)
        mat = self.catalog.material(it.get("material", ""))
        return {"ok": True, "item": it, "material": mat, **values, "beispiel": _usage_example(it)}

    def stock_define(self, entry: dict[str, Any], ebene: str = "eigen", *, proposal: bool = True) -> dict[str, Any]:
        """Über MCP immer ein Vorschlag (status "vorgeschlagen"), den Kevin freigibt (Lagerkatalog oder Dialog im
        Projektfenster, ``freigabe_anfragen``). Die App
        (Kevin) speichert mit ``proposal=False``."""
        try:
            saved, path, notes = self.catalog.save("teil", entry, ebene, proposal=proposal)
        except CatalogError as exc:
            return {"ok": False, "error": str(exc)}
        values = self._values(saved)
        notes += _plausibility(saved, values, self.catalog.material(saved.get("material", "")))
        return {"ok": True, "item": saved, "datei": str(path), "hinweise": notes, **values}

    def material_list(self, query: str = "") -> dict[str, Any]:
        mats = self.catalog.search_materials(query or "")
        out = {"ok": True, "materials": mats, "total": len(mats)}
        if self.catalog.warnings:
            out["warnings"] = list(self.catalog.warnings)
        return out

    def material_define(self, entry: dict[str, Any], ebene: str = "eigen", *, proposal: bool = True) -> dict[str, Any]:
        """Wie stock_define: über MCP ein Vorschlag, aus der App (``proposal=False``) direkt gespeichert."""
        try:
            saved, path, notes = self.catalog.save("material", entry, ebene, proposal=proposal)
        except CatalogError as exc:
            return {"ok": False, "error": str(exc)}
        return {"ok": True, "material": saved, "datei": str(path), "hinweise": notes}

    def catalog_delete(self, kind: str, entry_id: str, ebene: str = "eigen") -> dict[str, Any]:
        try:
            path, message = self.catalog.delete(kind, str(entry_id or "").strip(), ebene)
        except CatalogError as exc:
            return {"ok": False, "error": str(exc)}
        return {"ok": True, "message": message, "datei": str(path)}

    def catalog_message(self, query: str | None = None, art: str | None = None) -> dict[str, Any]:
        """Inhalt der Nachricht CATALOG (ohne type/reply_to)."""
        if query or art:
            items, _ = self.catalog.search(query or "", art=art or None, limit=None)
        else:
            items = self.catalog.items()
        return {"materials": self.catalog.materials(), "items": items, "arten": list(ALLE_ARTEN)}

    # =================================================================================================================
    # KernelService: Phase 3 (Zukaufteile, kevcad_kernel.zukauf.dienst)
    # =================================================================================================================

    def zukauf_anlegen(self, url: str | None = None, mpn: str | None = None, gtin: str | None = None,
                       felder: dict[str, Any] | None = None, ebene: str = "projekt") -> dict[str, Any]:
        return self.zukauf.anlegen(url=url, mpn=mpn, gtin=gtin, felder=felder, ebene=ebene, proposal=True)

    def zukauf_html(self, url: str | None, html: str, anlegen: bool = False, ebene: str = "projekt") -> dict[str, Any]:
        return self.zukauf.html(url, html, anlegen=anlegen, ebene=ebene)

    def cad_suchen(self, zukauf_id: str) -> dict[str, Any]:
        return self.zukauf.suchen(zukauf_id)

    def cad_uebernehmen(self, zukauf_id: str, pfad: str | None = None, minuten: float = 30,
                        erzwingen: bool = False) -> dict[str, Any]:
        return self.zukauf.uebernehmen(zukauf_id, pfad, minuten=minuten, erzwingen=erzwingen)

    def zukauf_liste(self, query: str = "") -> dict[str, Any]:
        return self.zukauf.liste(query)

    def _values(self, item: dict[str, Any]) -> dict[str, Any]:
        """Berechnete Werte eines Lagerteils: kg_je_m, querschnitt_mm2, preis_je_m, preis_text."""
        from kevcad_kernel.profiles import flaeche_mm2, kg_je_m

        mat = self.catalog.material(item.get("material", ""))
        out: dict[str, Any] = {"kg_je_m": None, "querschnitt_mm2": None, "preis_je_m": None, "preis_text": None}
        try:
            if item.get("art") in STANGENWARE:
                out["querschnitt_mm2"] = round(flaeche_mm2(item["art"], item.get("masse") or {}), 2)
                kgm = kg_je_m(item, mat)
                out["kg_je_m"] = round(kgm, 3) if kgm is not None else None
        except (KeyError, TypeError, ValueError):
            pass
        preis = item.get("preis") if isinstance(item.get("preis"), dict) else {}
        from kevcad_kernel.bom import de_fixed

        if preis.get("je_m") is not None:
            out["preis_je_m"] = preis["je_m"]
            out["preis_text"] = f"{de_fixed(float(preis['je_m']))} €/m"
        elif preis.get("je_m2") is not None:
            out["preis_text"] = f"{de_fixed(float(preis['je_m2']))} €/m²"
        elif preis.get("je_stueck") is not None:
            out["preis_text"] = f"{de_fixed(float(preis['je_stueck']))} €/Stück"
        elif mat and mat.get("preis_je_kg") is not None:
            out["preis_text"] = f"{de_fixed(float(mat['preis_je_kg']))} €/kg (Material)"
            if out["kg_je_m"] is not None:
                out["preis_je_m"] = round(out["kg_je_m"] * float(mat["preis_je_kg"]), 2)
        return out

    def _with_values(self, item: dict[str, Any]) -> dict[str, Any]:
        return {**item, "berechnet": self._values(item)}

    def set_agent_activity(self, text: str | None) -> None:
        self._agent_seen = time.monotonic()  # Versionen: Wer hat zuletzt etwas getan
        with self._lock:
            self._agent["activity"] = text or None
            msg = {"type": "AGENT", **self._agent}
        self._send_app(msg)

    def set_agent_connected(self, connected: bool) -> None:
        with self._lock:
            self._agent["connected"] = bool(connected)
            if not connected:
                self._agent["activity"] = None
                self._agent["sessions"] = []
            msg = {"type": "AGENT", **self._agent}
        self._send_app(msg)

    def set_agent_sessions(self, sessions: list[dict[str, Any]]) -> None:
        with self._lock:
            self._agent["sessions"] = [dict(s) for s in sessions]
            msg = {"type": "AGENT", **self._agent}
        self._send_app(msg)

    def close(self) -> None:
        with self._lock:
            if self._closed:
                return
            self._closed = True
        with self._jobs_cond:
            for job in self._jobs:
                job.result = {"ok": False, "error": "Kernel wird beendet"}
                job.done.set()
            self._jobs.clear()
            self._jobs_cond.notify_all()
        cur = self._current
        if cur is not None and not cur.finished.is_set():
            cur.final = {"type": "CLOSED"}
            cur.finished.set()
        self._worker.stop(timeout=1.0)
        self._zeichnung_schliessen()
        self._versionen_schliessen()  # Versionen: Hintergrund-Rechenprozess der Nachberechnung
        self._drucker_close()  # Phase 8: MQTT trennen, SSDP und Auftragsfaden beenden
        self._druckvorschau_schliessen()  # Druckvorschau: Slicer abbrechen
        self._referenz_schliessen()  # Phase 4: laufendes Object Capture beenden
        self._fk_abbrechen_intern()  # Statik S3: laufenden FEM-Prozess beenden
        self._scan_schliessen()  # Scan: Empfänger und Bonjour beenden, laufende Auswertung abbrechen
        self._fail_pending("Kernel wird beendet")
        self._link.close()
        self._pool.shutdown(wait=False, cancel_futures=True)

    # =================================================================================================================
    # Zusätzlich (nicht im Vertrag): Einstellungen wie SETTINGS der App
    # =================================================================================================================

    def configure(self, auto_run: bool | None = None, slow_ms: int | None = None) -> dict[str, Any]:
        with self._lock:
            if auto_run is not None:
                self._settings["auto_run"] = bool(auto_run)
            if slow_ms is not None:
                self._settings["slow_ms"] = max(0, int(slow_ms))
            return dict(self._settings)

    def wait_idle(self, timeout: float = 60.0) -> bool:
        """Wartet, bis keine Läufe mehr anstehen (für Tests)."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self._jobs_cond:
                if not self._jobs and self._current is None:
                    return True
            time.sleep(0.02)
        return False

    def wait_worker_ready(self, timeout: float = WORKER_START_TIMEOUT_S) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self._worker.ready:
                return True
            time.sleep(0.05)
        return False

    # =================================================================================================================
    # Projekt intern
    # =================================================================================================================

    def _set_project(self, proj: Project, reply_to: str | None = None) -> None:
        with self._lock:
            same = self._project is not None and self._project.path == proj.path
            self._project = proj
            if not same:
                self._last_hash = None
                self._last_result = None
                self._bom = None
                self._violations = []
                self._constraints = None
                self._regler = {}
                self._selection = {"run": None, "refs": []}
                self._pruef.reset()
            run = self._run_no
        self.catalog.set_project(proj.path)
        if not same:
            with self._jobs_cond:
                cur = self._current
                if cur is not None and cur.kind == "run":
                    cur.cancelled = "anderes Projekt geöffnet"
                for pending in [j for j in self._jobs if j.kind == "run"]:
                    self._jobs.remove(pending)
                    pending.result = {"ok": False, "error": "Lauf abgebrochen: anderes Projekt geöffnet"}
                    pending.done.set()
        with self._app_lock:
            if not same:
                for rec in self.scene.clear():
                    self._send_app({"type": "PART_REMOVE", "run": run, "name": rec.name})
                self._anim_project_changed()
                self.cameras_clear(run)
                self._bauplan_project_changed()
                self._zeichnung_projekt()
            self._druckvorschau_projekt(same)  # Druckvorschau: Stand des alten Projekts vergessen
            msg = {"type": "PROJECT", **proj.info()}
            if reply_to:
                msg["reply_to"] = reply_to
            self._send_app(msg)
            self._bestand_projekt(same)  # BESTAND nach jedem Projektwechsel
            self._referenz_projekt(same)  # Phase 4: Referenzen des neuen Projekts
            for status in self.zukauf.offene_status():  # Zukaufteile, die auf ihr CAD warten
                self._send_app(status)
        self._versionen_projekt(proj, same)  # Versionen: Repo anlegen, alte Stände übernehmen
        if self._settings.get("auto_run") and (not same or self._last_result is None):
            self._submit_run(None, int(self._settings.get("slow_ms") or 0), self.run_timeout_s, source="auto")

    # =================================================================================================================
    # Läufe intern
    # =================================================================================================================

    def _reglerstand(self) -> dict[str, Any]:
        """Überschriebene Parameter des letzten erfolgreichen Laufs (Regler der App, ``run(params=…)``); leer, wenn die
        Szene den Stand der Dateien zeigt."""
        with self._lock:
            return dict(self._regler)

    def _regler_sperre(self, was: str = "Blätter und Bauplan") -> str | None:
        """Meldung, wenn die Szene einen Reglerstand zeigt: Dann bearbeiten Kevin und der Agent keine Dokumente (sie
        bezögen sich auf Maße, die es in model.py nicht gibt, und die Versionen erfassten den Reglerstand)."""
        regler = self._reglerstand()
        if not regler:
            return None
        werte = ", ".join(f"{k} = {v:g}" if isinstance(v, (int, float)) else f"{k} = {v}" for k, v in regler.items())
        return (f"Das Modell zeigt gerade einen Reglerstand ({werte}). {was} werden dazu nur gezeigt, nicht "
                "gespeichert; bearbeiten geht erst nach einem Lauf ohne überschriebene Parameter (Regler zurück, "
                "run ohne params).")

    def _submit_run(self, params: dict[str, Any] | None, slow_ms: int, timeout_s: float, source: str,
                    katalog_neu: bool = False):
        """Lauf einreihen. ``katalog_neu``: der Katalog hat sich geändert (CAD übernommen, Eintrag gesichert); ein schon
        laufender Lauf mit gleichem Dateistand hat den alten Katalog gelesen und zählt dann nicht."""
        proj = self._project
        if proj is None:
            return {"ok": False, "error": NO_PROJECT}
        try:
            code = proj.model.read_text(encoding="utf-8")
        except OSError as exc:
            return {"ok": False, "error": f"model.py nicht lesbar: {exc}"}
        job = Job(kind="run", code=code, source=source, timeout_s=float(timeout_s or self.run_timeout_s),
                  path=str(proj.model), params=dict(params or {}), slow_ms=int(slow_ms or 0),
                  file_hash=hashlib.sha1(code.encode("utf-8")).hexdigest()[:12])
        with self._jobs_cond:
            # Gleicher Dateistand mit gleichen Parametern läuft schon oder wartet: auf dessen Ergebnis warten
            cur = self._current
            if cur is not None and cur.key == job.key and cur.path == job.path and not cur.done.is_set() \
                    and not katalog_neu:
                if source == "agent":
                    cur.source = "agent"  # Versionen: der Agent hat diesen Stand ausgelöst
                return cur
            for pending in self._jobs:
                if pending.key == job.key and pending.path == job.path:
                    if source == "agent":
                        pending.source = "agent"
                    return pending
            if source == "auto":
                for pending in [j for j in self._jobs if j.kind == "run" and j.source == "auto"]:
                    self._jobs.remove(pending)
                    pending.result = {"ok": False, "error": "durch neueren Dateistand ersetzt"}
                    pending.done.set()
            self._last_hash = job.file_hash
            self._jobs.append(job)
            self._jobs_cond.notify_all()
        return job

    def _enqueue(self, job: Job) -> None:
        with self._jobs_cond:
            self._jobs.append(job)
            self._jobs_cond.notify_all()

    def _job_loop(self) -> None:
        while True:
            with self._jobs_cond:
                while not self._jobs and not self._closed:
                    self._jobs_cond.wait(0.5)
                if self._closed:
                    return
                job = self._jobs.popleft()
                self._current = job
            try:
                if job.kind == "run":
                    job.result = self._run_job(job)
                elif job.kind == "schatten":
                    job.result = self._schatten_job(job)
                elif job.kind == "aufgabe":
                    job.result = job.fn()
                else:
                    job.result = self._exec_job(job)
            except Exception as exc:  # noqa: BLE001
                import traceback

                self._log(traceback.format_exc())
                job.result = {"ok": False, "error": f"Interner Fehler der Laufzeit: {type(exc).__name__}: {exc}"}
            finally:
                with self._jobs_cond:
                    self._current = None
                job.done.set()

    def _spawn_worker(self) -> None:
        """Rechenprozess starten (kehrt sofort zurück); ein Hilfsfaden meldet, wenn er bereit ist."""
        if self._closed:
            return
        self._set_state("busy", "Rechenprozess startet")
        gen = self._worker.start()
        threading.Thread(target=self._await_worker, args=(gen,), name="kevcad-worker-wait", daemon=True).start()

    def _await_worker(self, gen: int) -> None:
        if self._worker.wait_ready(WORKER_START_TIMEOUT_S):
            with self._jobs_cond:
                busy = self._current is not None
            if not busy and gen == self._worker.generation:
                self._set_state("ready", "bereit")
        elif gen == self._worker.generation and not self._closed:
            self._set_state("error", "Rechenprozess startet nicht: " + (self._worker.stderr_tail(5) or "ohne Meldung"))

    def _ensure_worker(self) -> str | None:
        """Rechenprozess bereit machen; Fehlermeldung oder None."""
        if self._worker.ready:
            return None
        if not self._worker.alive:
            self._worker.start()
        self._set_state("busy", "Rechenprozess startet")
        if self._worker.wait_ready(WORKER_START_TIMEOUT_S):
            return None
        tail = self._worker.stderr_tail(8)
        self._set_state("error", "Rechenprozess startet nicht")
        return "Rechenprozess startet nicht" + (f":\n{tail}" if tail else "")

    def _restart_worker_async(self) -> None:
        self._spawn_worker()

    def _precision(self) -> tuple[float, float]:
        proj = self._project
        return proj.precision if proj else (0.1, 0.2)

    def _run_job(self, job: Job) -> dict[str, Any]:
        err = self._ensure_worker()
        if err:
            return {"ok": False, "error": err}
        deviation, angular = self._precision()
        with self._lock:
            self._run_no += 1
            job.run = self._run_no
        job.generation = self._worker.generation
        job.started = time.perf_counter()
        self._topologie_lauf_beginn(job.run)  # Topologie: Aufrufe aus model.py ab hier gehören zu diesem Lauf
        self._set_state("busy", f"Lauf {job.run} rechnet")
        self._send_app({"type": "RUN_START", "run": job.run, "file_hash": job.file_hash, "params": job.params,
                        "slow_ms": job.slow_ms})
        self._fk_abbrechen_intern()  # Statik S3: FEM des alten Laufs beenden, der neue Lauf hat die Kerne
        sent = self._worker.send({"type": "RUN", "run": job.run, "path": job.path, "code": job.code,
                                  "params": job.params, "slow_ms": job.slow_ms, "deviation": deviation,
                                  "angular": angular, "catalog": self._catalog_dirs(),
                                  "inventar_regel": self._inventory_rule(reload=True)})
        finished = sent and job.finished.wait(job.timeout_s)
        duration_ms = int(round((time.perf_counter() - job.started) * 1000))
        final = job.final or {}

        if not finished or final.get("type") in ("CRASH", "CLOSED"):
            if not finished:
                self._worker.kill()
                message = (f"Zeitlimit von {job.timeout_s:g} s überschritten: Lauf abgebrochen, Rechenprozess wird neu "
                           "gestartet. Endlosschleife oder sehr aufwendige Operation?")
                hint = "Schleifen und Abbruchbedingungen prüfen; bei großen Modellen run(timeout_s=…) erhöhen."
            elif final.get("type") == "CLOSED":
                message, hint = "Kernel wird beendet", ""
            else:
                code = final.get("code")
                sig = f" (Signal {-code})" if isinstance(code, int) and code < 0 else (f" (Exitcode {code})" if code
                                                                                       else "")
                message = f"Rechenprozess abgestürzt{sig}. Die letzte gute Geometrie bleibt stehen."
                hint = "Häufig ein OCCT-Absturz bei ungültiger Geometrie (z. B. Verrundung zu groß). Die letzten " \
                       "Ausgaben stehen im Traceback."
            error = {"message": message, "line": None, "excerpt": "", "traceback": final.get("stderr", ""),
                     "hint": hint}
            if final.get("type") == "CRASH":
                line = _line_from_crash(final.get("stderr", ""), job.path)
                if line:
                    from kevcad_kernel.runner import excerpt as make_excerpt

                    error["line"] = line
                    error["excerpt"] = make_excerpt(job.code, line)
            self._send_app({"type": "RUN_ERROR", "run": job.run, **{k: error[k] for k in
                                                                    ("message", "line", "excerpt", "traceback")},
                            "hint": hint})
            result = self._result(job, ok=False, duration_ms=duration_ms, final=final, error=error)
            self._finish(job, result)
            if final.get("type") != "CLOSED":
                self._restart_worker_async()
            return result

        if job.cancelled:
            error = {"message": f"Lauf abgebrochen: {job.cancelled}", "line": None, "excerpt": "", "traceback": "",
                     "hint": ""}
            self._send_app({"type": "RUN_ERROR", "run": job.run, "message": error["message"], "line": None,
                            "excerpt": "", "traceback": ""})
            result = self._result(job, ok=False, duration_ms=duration_ms, final=final, error=error)
            self._set_state("ready", "bereit")
            return result
        if final.get("type") == "RUN_DONE":
            shown = set(final.get("shown") or [])
            with self._app_lock:
                for rec in self.scene.records():
                    if rec.name not in shown:
                        self.scene.remove(rec.name)
                        self._send_app({"type": "PART_REMOVE", "run": job.run, "name": rec.name})
                records = self.scene.records()
                self.cameras_after_run(job.run, final.get("cameras"))  # Phase 5: Kameras vor RUN_END
                violations = list(final.get("inventar_verstoesse") or [])
                with self._lock:
                    self._violations = violations
                self._send_app({"type": "RUN_END", "run": job.run, "duration_ms": duration_ms, "parts": len(records),
                                "triangles": sum(r.counts.get("tri", 0) for r in records),
                                "warnings": final.get("warnings") or [], "params": final.get("params") or {},
                                "inventar_regel": bool(final.get("inventar_regel", False)),
                                "inventar_verstoesse": violations})
                if isinstance(final.get("bom"), dict):
                    bom = self._bestand_bom({"run": job.run, **final["bom"]})  # Zuschnitt mit Bestand, Einkauf
                    with self._lock:
                        self._bom = bom
                    self._send_app({"type": "BOM", **bom})
                if isinstance(final.get("bedingungen"), dict):  # Zwangsbedingungen (PLAN-BEDINGUNGEN.md)
                    report = {"run": job.run, **final["bedingungen"]}
                    report.pop("fehler", None)
                    with self._lock:
                        self._constraints = report
                    self._send_app({"type": "CONSTRAINTS", **report})
                # Prüfung: läuft sie noch, „running“ melden; ist sie schon fertig (schneller als RUN_END), das Ergebnis
                self._run_end_run = job.run
                if self._pruef.erwarte(job.run):
                    from kevcad_kernel.protocol import pack_check

                    laeuft, _ = pack_check(run=job.run, state="running")
                    laeuft.pop("seq", None)
                    self._send_app(laeuft)
                else:
                    fertig, fertig_payload = self._pruef.fuer_lauf(job.run)
                    if fertig is not None:
                        self._send_app(fertig, fertig_payload)
            result = self._result(job, ok=True, duration_ms=duration_ms, final=final)
            with self._lock:
                self._regler = dict(job.params or {})  # Szene zeigt einen Reglerstand, wenn Parameter überschrieben
            self._druckvorschau_lauf(job.run, job.params)  # Druckvorschau: Lauf abgeschlossen (Reglerwerte)
            self._referenz_nach_lauf(job.run)  # Phase 4: Abweichung zum Referenznetz im Hintergrund
            self._anim_publish(job, result)
            # Versionen zuerst: die Hintergrundrechnung der Dokumente gehört zur Version dieses Laufs und wird in sie
            # nachgetragen (versionen/laufzeit.py); mit überschriebenen Parametern speichert sie nichts
            self._versionen_nach_lauf(job, result)  # Versionen: neue Version bei Änderung (ohne Git: save_version)
            speichern = not job.params
            hintergrund = [self._bauplan_nach_lauf(job.run, result, speichern=speichern),  # Phase 6: Bauplan
                           self._zeichnung_nach_lauf(job.run, speichern=speichern)]  # Phase 6: Blätter, danach DOCS
            self._versionen_dokumente_nach_lauf(job, hintergrund)
        else:  # RUN_FAILED
            error = dict(final.get("error") or {"message": "Unbekannter Fehler"})
            self._send_app({"type": "RUN_ERROR", "run": job.run, "message": error.get("message", ""),
                            "line": error.get("line"), "excerpt": error.get("excerpt", ""),
                            "traceback": error.get("traceback", ""), "hint": error.get("hint", "")})
            result = self._result(job, ok=False, duration_ms=duration_ms, final=final, error=error)
        self._finish(job, result)
        return result

    def _result(self, job: Job, *, ok: bool, duration_ms: int, final: dict[str, Any],
                error: dict[str, Any] | None = None) -> dict[str, Any]:
        result: dict[str, Any] = {
            "ok": ok,
            "run": job.run,
            "duration_ms": duration_ms,
            "file_hash": job.file_hash,
            "parts": self.parts(),
            "steps": list(final.get("steps") or job.steps),
            "warnings": list(final.get("warnings") or []),
            "params": dict(final.get("params") or {}),
        }
        if final.get("stdout"):
            result["stdout"] = final["stdout"]
        if "cached" in final:
            result["cached_parts"] = final.get("cached", 0)
            result["tess_ms"] = final.get("tess_ms", 0.0)
        if final.get("cameras"):
            from kevcad_kernel.kamera import camera_line

            result["kameras"] = [camera_line(c) for c in final["cameras"]]
        if "inventar_regel" in final:
            result["inventar_regel"] = bool(final["inventar_regel"])
            result["inventar_verstoesse"] = list(final.get("inventar_verstoesse") or [])
        if final.get("kulisse"):  # Umgebung (show(..., kulisse=True)): ohne Stückliste und Inventar-Regel
            result["kulisse"] = list(final["kulisse"])
        bom = final.get("bom")
        if isinstance(bom, dict) and (bom.get("lines") or bom.get("warnings")):
            result["bom"] = {"totals": bom.get("totals") or {}, "warnings": list(bom.get("warnings") or [])[:10],
                             "cuts": len(bom.get("cuts") or [])}
            with self._lock:
                full = self._bom
            if ok and full is not None and full.get("run") == job.run and full.get("einkaufsliste") is not None:
                # wie die Kennzeile der App: Lagerware und Zukaufteile, Summe beider
                from kevcad_kernel.bestand.einkauf import zusammenstellen

                e = zusammenstellen(full)
                result["bom"]["einkauf"] = {"positionen": e["positionen"], "summe": e["summe"],
                                            "hinweis": full.get("einkauf_hinweis")}
        rep = final.get("bedingungen")
        if isinstance(rep, dict):
            from kevcad_kernel.bedingungen.bericht import kurzbericht

            result["bedingungen"] = kurzbericht(rep)
        if error is not None:
            result["error"] = error
        return result

    def _finish(self, job: Job, result: dict[str, Any]) -> None:
        with self._lock:
            self._last_result = result
        if result.get("ok"):
            self._set_state("ready", f"Lauf {job.run} fertig ({result['duration_ms']} ms)")
        else:
            line = (result.get("error") or {}).get("line")
            self._set_state("ready", f"Lauf {job.run}: Fehler" + (f" in Zeile {line}" if line else ""))
        proj = self._project
        if proj is not None:
            err = result.get("error") or {}
            proj.log_run({"run": job.run, "ok": result.get("ok"), "source": job.source,
                          "duration_ms": result.get("duration_ms"), "parts": len(result.get("parts") or []),
                          "file_hash": job.file_hash, "error": err.get("message"), "line": err.get("line")})

    def _exec_job(self, job: Job) -> dict[str, Any]:
        err = self._ensure_worker()
        if err:
            return {"ok": False, "error": err}
        deviation, angular = self._precision()
        with self._lock:
            job.run = self._run_no
        job.generation = self._worker.generation
        self._set_state("busy", "execute")
        sent = self._worker.send({"type": "EXEC", "run": job.run, "code": job.code, "project": job.path or None,
                                  "deviation": deviation, "angular": angular, "catalog": self._catalog_dirs(),
                                  "inventar_regel": self._inventory_rule()})
        finished = sent and job.finished.wait(job.timeout_s)
        final = job.final or {}
        if not finished or final.get("type") != "EXEC_RES":
            if not finished:
                self._worker.kill()
                error = f"Zeitlimit von {job.timeout_s:g} s überschritten; Rechenprozess wird neu gestartet " \
                        "(Namensraum des letzten Laufs ist danach leer)."
            else:
                error = "Rechenprozess abgestürzt; wird neu gestartet (Namensraum des letzten Laufs ist danach leer)."
            self._set_state("ready", "bereit")
            if final.get("type") != "CLOSED":
                self._restart_worker_async()
            return {"ok": False, "error": error, "stdout": ""}
        self._set_state("ready", "bereit")
        out = {k: v for k, v in final.items() if k not in ("type", "seq")}
        out.setdefault("ok", True)
        return out

    # =================================================================================================================
    # Rechenprozess → Laufzeit
    # =================================================================================================================

    def _on_worker_message(self, gen: int, header: dict[str, Any], payload: bytes) -> None:
        kind = header.get("type")
        if kind == "CHECK_DONE":  # kommt nach RUN_DONE, wenn der Lauf schon abgeschlossen ist
            app_len = int(header.get("app_len", 0))
            check = dict(header.get("app") or {})
            statik = self._statik_check(check)  # Statik: volles Ergebnis heraus, im CHECK bleibt die Kurzfassung
            self._dynamik_nach_lauf(statik)  # Statik S2: Abläufe aus model.py im Hintergrund (eigener Prozess)
            self._festkoerper_nach_lauf(statik)  # Statik S3: Festkörper-FEM für Teile mit Last (eigener Prozess)
            self._topologie_nach_lauf(check, statik)  # Topologie: fehlende Ergebnisse aus model.py im Hintergrund
            # Druckvorschau: Geometrie je Druckteil aus der Prüfung, und zwar bevor fertig() das wartende run weckt;
            # sonst fragt ein Aufrufer direkt nach run (PRINT_JOB_REQ, druckvorschau) eine Vorschau ohne Eingang ab,
            # während die Versionen hier noch schreiben (Wettlauf, sichtbar seit die Statik die Prüfung verlängert)
            self._druckvorschau_pruefung(check)
            with self._app_lock:  # erst nach RUN_END dieses Laufs an die App (sonst schickt es _run_job)
                # Statik S2/S3: was schon fertig ist, als Befund dazu; was noch rechnet, macht das CHECK „teilweise“
                # (T34). Unter derselben Sperre wie das Nachtragen, damit kein fertiger Hintergrund verloren geht
                check = self._statik_in_check(check, vom_rechenprozess=True)
                if self._pruef.fertig(check, payload[:app_len]) and self._run_end_run >= int(check.get("run") or 0):
                    self._send_app({**check, "type": "CHECK"}, payload[:app_len])
            self._versionen_pruefung(check)  # Versionen: Prüfstand an die Version des Laufs
            self._gedruckt_check(check)  # gedruckte Teile: neue Formen in gedruckt.json festschreiben
            if statik is not None:
                self._statik_senden()  # Statik: STATICS (nach allem anderen, es eilt nicht)
                self._simulation_nach_lauf()  # Simulation: SIM mit dem Zustand der Lasten und Lager dieses Laufs
            return
        if kind == "READY":
            self._log(f"[kernel] Rechenprozess bereit (pid {header.get('pid')}, Import {header.get('import_s')} s)")
            return
        job = self._current
        if job is None or job.generation != gen:
            return
        if job.cancelled and kind in ("STEP", "PART"):
            return
        if job.kind == "schatten" and kind in ("STEP", "PART", "ANIM"):
            self._schatten_nachricht(job, kind, header, payload)  # Versionen: Lauf ohne Live-Aufbau
            return
        if kind == "STEP":
            if header.get("run") != job.run:
                return
            job.steps.append(str(header.get("text", "")))
            self._send_app({"type": "STEP", "run": job.run, "index": header.get("index", len(job.steps)),
                            "text": header.get("text", "")})
        elif kind == "PART":
            if header.get("run") != job.run:
                return
            app_len = int(header.get("app_len", 0))
            app_header = dict(header.get("app") or {})
            app_payload, brep = payload[:app_len], payload[app_len:]
            with self._app_lock:
                self.scene.upsert(name=header["name"], run=job.run, key=str(header.get("key", "")),
                                  header=app_header, payload=app_payload, brep=brep, density=header.get("density"))
                self._send_app(app_header, app_payload)
        elif kind == "ANIM":
            if header.get("run") == job.run:
                job.animations.append((header, payload))
        elif kind in ("RUN_DONE", "RUN_FAILED", "EXEC_RES"):
            job.final = header
            job.finished.set()

    def _on_worker_exit(self, gen: int, code: int | None) -> None:
        if self._closed:
            return
        self._log(f"[kernel] Rechenprozess {gen} beendet (Exitcode {code})")
        self._pruef.abbrechen("Rechenprozess beendet")
        job = self._current
        if job is not None and job.generation == gen and not job.finished.is_set():
            job.final = {"type": "CRASH", "code": code, "stderr": self._worker.stderr_tail(25)}
            job.finished.set()

    # =================================================================================================================
    # App
    # =================================================================================================================

    def _send_app(self, header: dict[str, Any], payload: bytes = b"") -> bool:
        with self._app_lock:
            return self._link.send(header, payload)

    def _set_state(self, state: str, message: str) -> None:
        with self._lock:
            changed = self._state != (state, message)
            self._state = (state, message)
        if changed:
            self._send_app({"type": "STATUS", "state": state, "message": message})

    def _on_app_connect(self, conn: AppConnection) -> None:
        with self._app_lock:
            with self._lock:
                proj = self._project
                state, message = self._state
                agent = dict(self._agent)
            conn.send({"type": "HELLO", "protocol": PROTOCOL_VERSION, "kernel_version": kevcad_kernel.__version__,
                       "build123d": _b123d_version(), "mcp_port": self.mcp_port})
            if proj is not None:
                conn.send({"type": "PROJECT", **proj.info()})
            conn.send({"type": "STATUS", "state": state, "message": message})
            for rec in self.scene.records():
                conn.send(rec.header, rec.payload)
            with self._lock:
                bom = self._bom
                constraints = self._constraints
            if bom is not None:
                conn.send({"type": "BOM", **bom})
            conn.send(self._bestand_nachricht())  # Bestand des offenen Projekts (null ohne Projekt)
            if constraints is not None:
                conn.send({"type": "CONSTRAINTS", **constraints})
            self._anim_on_connect(conn)
            self.cameras_on_connect(conn, self._run_no)
            self._bauplan_on_connect(conn)
            check, check_payload = self._pruef.letztes()
            if check is not None:
                conn.send(check, check_payload)
            self._statik_on_connect(conn)  # Statik: letztes STATICS
            self._festkoerper_on_connect(conn)  # Statik S3: Felder (STATICS_FIELD) des letzten Laufs
            self._topologie_on_connect(conn)  # Topologie: letzter Stand (TOPO) und Netze (TOPO_FIELD)
            self._simulation_on_connect(conn)  # Simulation: SIM (Lastfälle, Lasten, Lager der App)
            self._zeichnung_on_connect(conn)
            self._druckvorschau_on_connect(conn)
            conn.send({"type": "AGENT", **agent})
            for status in self.zukauf.offene_status():  # Downloads-Beobachtung nach Neustart fortsetzen
                conn.send(status)
            self._drucker_on_connect(conn)  # Phase 8: PRINTER_STATUS
            self._referenz_on_connect(conn)  # Phase 4: Referenzen (Liste, Netze, Fotos, Messergebnisse)
            self._link.activate(conn)
            self._versionen_on_connect(conn)
        self._log(f"[kernel] App verbunden ({len(self.scene.records())} Teile geschickt)")

    def _on_app_disconnect(self, conn: AppConnection) -> None:
        self._log("[kernel] App getrennt")
        self._fail_pending("App-Verbindung getrennt")

    def _fail_pending(self, message: str) -> None:
        with self._lock:
            pending = list(self._pending.values())
            self._pending.clear()
        for slot in pending:
            slot["error"] = message
            slot["event"].set()

    def _request(self, header: dict[str, Any], timeout_s: float,
                 payload: bytes = b"") -> tuple[dict[str, Any], bytes, str | None]:
        rid = f"k-{next(self._ids)}"
        slot: dict[str, Any] = {"event": threading.Event(), "reply": None, "payload": b"", "error": None}
        with self._lock:
            self._pending[rid] = slot
        if not self._send_app({**header, "id": rid}, payload):
            with self._lock:
                self._pending.pop(rid, None)
            return {}, b"", APP_NOT_CONNECTED
        if not slot["event"].wait(timeout_s):
            with self._lock:
                self._pending.pop(rid, None)
            return {}, b"", f"Keine Antwort der App innerhalb von {timeout_s:g} s"
        if slot["error"]:
            return {}, b"", slot["error"]
        reply = slot["reply"] or {}
        if reply.get("type") == "ERROR":
            return {}, b"", str(reply.get("message") or "Fehler in der App")
        return reply, slot["payload"], None

    def _send_view_nowait(self, cmd: str, args: dict[str, Any]) -> bool:
        return self._send_app({"type": "VIEW_CMD", "id": f"k-{next(self._ids)}", "cmd": cmd, "args": args})

    def _check_view_refs(self, cmd: str, args: dict[str, Any]) -> str | None:
        refs = args.get("refs")
        if cmd not in ("focus", "visibility", "highlight") or not refs:
            return None
        names = self.scene.names()
        for r in refs:
            part = str(r).split("#", 1)[0]
            if part not in names and not any(n.startswith(part.rstrip("/") + "/") for n in names):
                from kevcad_kernel.refs import unknown_part_message

                return unknown_part_message(part, names)
        return None

    def _apply_visibility(self, args: dict[str, Any]) -> None:
        mode = args.get("mode")
        refs = [str(r).split("#", 1)[0] for r in (args.get("refs") or [])]

        def hit(name: str) -> bool:
            return any(name == r or name.startswith(r.rstrip("/") + "/") for r in refs)

        for rec in self.scene.records():
            if mode == "show_all":
                rec.visible = True
            elif mode == "show" and hit(rec.name):
                rec.visible = True
            elif mode == "hide" and hit(rec.name):
                rec.visible = False
            elif mode == "isolate":
                rec.visible = hit(rec.name)

    def _on_app_message(self, conn: AppConnection, header: dict[str, Any], payload: bytes) -> None:
        kind = header.get("type")
        reply_to = header.get("reply_to")
        if kind in ("ACK", "SCREENSHOT_RES", "ERROR", "ANIM_VIDEO_RES", "DOC_EXPORT_RES", "RENDER_RES",
                    "RENDER_SCENE") and reply_to:
            with self._lock:
                slot = self._pending.pop(str(reply_to), None)
            if slot is not None:
                slot["reply"] = header
                slot["payload"] = payload
                slot["event"].set()
            return
        if kind == "HELLO_APP":
            conn.info = {k: header.get(k) for k in ("app_version", "bundle_id")}
            self._log(f"[kernel] App meldet sich: {conn.info}")
        elif kind == "CAMERA_SUGGEST":
            self.camera_suggest_from_app(header)
        elif kind == "SELECTION":
            with self._lock:
                self._selection = {"run": header.get("run"), "refs": list(header.get("refs") or [])}
        elif kind == "SETTINGS":
            was = bool(self._settings.get("auto_run"))
            self.configure(auto_run=header.get("auto_run"), slow_ms=header.get("slow_ms"))
            if isinstance(header.get("inventar_regel"), bool):
                self._pool.submit(self.set_inventory_rule, header["inventar_regel"])
            if not was and self._settings.get("auto_run"):
                self._pool.submit(self._auto_check)
        elif kind == "BOM_REQ":
            from kevcad_kernel.bom import empty_bom

            with self._lock:
                bom = self._bom or {"run": 0, **empty_bom()}
            self._send_app({"type": "BOM", "reply_to": header.get("id"), **bom})
        elif kind == "DOWNLOAD_SEEN":
            self.zukauf.app_download_seen(header)
        elif kind in ("PROJECT_OPEN", "PROJECT_NEW", "RUN_REQ", "MEASURE_REQ", "EXPORT_REQ", "CATALOG_REQ",
                      "CATALOG_SAVE", "CATALOG_DELETE", "ZUKAUF_NEU", "ZUKAUF_CAD"):
            self._pool.submit(self._handle_app_request, header)
        elif kind in BESTAND_ANFRAGEN:
            self._pool.submit(self._bestand_anfrage_sicher, header)
        elif self._freigabe_app_message(kind, header):  # FREIGABE_GESCHLOSSEN
            pass
        elif self._anim_app_message(kind, header):
            pass
        elif self._bauplan_app_message(kind, header):
            pass
        elif self._zeichnung_app_message(kind, header):
            pass
        elif self._versionen_app_message(kind, header):
            pass
        elif self._drucker_app_message(kind, header):  # Phase 8: PRINTER_*, PRINT_JOB_REQ, PRINT_CONTROL
            pass
        elif self._druckvorschau_app_message(kind, header):
            pass
        elif self._referenz_app_message(kind, header):  # Phase 4: REF_ADD, REF_MEASURE_REQ, REF_APPLY
            pass
        elif self._render_app_message(kind, header):  # Phase 7: RENDER_START, RENDER_CANCEL
            pass
        elif self._festkoerper_app_message(kind, header):  # Statik S3: STATICS_CANCEL
            pass
        elif self._topologie_app_message(kind, header):  # Topologie: TOPO_START, TOPO_CANCEL, TOPO_APPLY
            pass
        elif self._simulation_app_message(kind, header):  # Simulation: SIM_REQ, SIM_EDIT, SIM_RUN, SIM_CANCEL
            pass
        else:
            self._log(f"[kernel] Unbekannte Nachricht von der App: {kind}")

    def _handle_app_request(self, header: dict[str, Any]) -> None:
        kind = header.get("type")
        rid = header.get("id")
        try:
            if kind == "PROJECT_OPEN":
                res = self.project_open(str(header.get("path", "")), reply_to=rid)
                if not res.get("ok"):
                    self._send_app({"type": "ERROR", "reply_to": rid, "message": res["error"]})
            elif kind == "PROJECT_NEW":
                res = self.project_new(str(header.get("path", "")), header.get("template") or "example", reply_to=rid)
                if not res.get("ok"):
                    self._send_app({"type": "ERROR", "reply_to": rid, "message": res["error"]})
            elif kind == "RUN_REQ":
                slow = header.get("slow_ms")
                slow = int(self._settings.get("slow_ms") or 0) if slow is None else int(slow)
                job = self._submit_run(header.get("params"), slow, self.run_timeout_s, source="app")
                if isinstance(job, dict):
                    self._send_app({"type": "ACK", "reply_to": rid, "ok": False, "message": job["error"]})
                else:
                    self._send_app({"type": "ACK", "reply_to": rid, "ok": True, "message": ""})
            elif kind == "MEASURE_REQ":
                res = self.measure(list(header.get("refs") or []), show=bool(header.get("show")),
                                   run=header.get("run"))
                if res.get("ok"):
                    result = {k: v for k, v in res.items() if k not in ("ok", "annotation")}
                    self._send_app({"type": "MEASURE_RES", "reply_to": rid, "result": result})
                else:
                    self._send_app({"type": "ERROR", "reply_to": rid, "message": res.get("error", "Messen fehlgeschlagen")})
            elif kind == "EXPORT_REQ":
                res = self.export(list(header.get("formats") or []), header.get("parts"))
                if res.get("ok"):
                    self._send_app({"type": "EXPORT_RES", "reply_to": rid, "files": res["files"]})
                else:
                    self._send_app({"type": "ERROR", "reply_to": rid, "message": res.get("error", "Export fehlgeschlagen")})
            elif kind == "ZUKAUF_NEU":  # Kevin hat im Dialog bestätigt: sofort frei; ACK, danach ZUKAUF_STATUS
                self.zukauf.app_neu(header, lambda ok, message: self._send_app(
                    {"type": "ACK", "reply_to": rid, "ok": ok, "message": message}))
            elif kind == "ZUKAUF_CAD":
                teil = str(header.get("teil") or "")
                entry = self.catalog.item(teil)
                if entry is None or entry.get("art") not in ZUKAUF_ARTEN:
                    self._send_app({"type": "ACK", "reply_to": rid, "ok": False,
                                    "message": f"Zukaufteil {teil!r} gibt es nicht"})
                else:
                    self._send_app({"type": "ACK", "reply_to": rid, "ok": True, "message": "CAD wird übernommen"})
                    self.zukauf.app_cad(header)
            elif kind == "CATALOG_REQ":
                art = header.get("art") or None
                if art is not None and art not in ALLE_ARTEN:
                    self._send_app({"type": "ERROR", "reply_to": rid, "message": f"art {art!r} unbekannt"})
                else:
                    self._send_app({"type": "CATALOG", "reply_to": rid,
                                    **self.catalog_message(header.get("query") or None, art)})
            elif kind in ("CATALOG_SAVE", "CATALOG_DELETE"):
                ebene = header.get("ebene") or "eigen"
                if kind == "CATALOG_SAVE":
                    entry = header.get("entry")
                    if str(header.get("kind")) == "material":  # Kevin speichert, was die App schickt (Freigabe)
                        res = self.material_define(entry, ebene, proposal=False)  # type: ignore[arg-type]
                    elif str(header.get("kind")) == "teil":
                        res = self.stock_define(entry, ebene, proposal=False)  # type: ignore[arg-type]
                    else:
                        res = {"ok": False, "error": f"kind {header.get('kind')!r} unbekannt (teil oder material)"}
                    message = "; ".join(res.get("hinweise") or []) if res.get("ok") else res.get("error", "")
                else:
                    res = self.catalog_delete(str(header.get("kind") or ""), str(header.get("entry_id") or ""), ebene)
                    message = res.get("message", "") if res.get("ok") else res.get("error", "")
                self._send_app({"type": "ACK", "reply_to": rid, "ok": bool(res.get("ok")), "message": message})
                if res.get("ok"):
                    self._freigabe_katalog_geaendert()  # wartende freigabe_anfragen prüfen neu
                    self._rerun_after_catalog_change()
        except Exception as exc:  # noqa: BLE001
            self._send_app({"type": "ERROR", "reply_to": rid, "message": f"{type(exc).__name__}: {exc}"})

    def _bestand_anfrage_sicher(self, header: dict[str, Any]) -> None:
        try:
            self._bestand_anfrage(header)
        except Exception as exc:  # noqa: BLE001
            self._send_app({"type": "ERROR", "reply_to": header.get("id"), "message": f"{type(exc).__name__}: {exc}"})

    def _inventory_rule(self, reload: bool = False) -> bool:
        """Inventar-Regel des offenen Projekts (kevcad.json, Standard an). ``reload`` liest die Datei neu."""
        proj = self._project
        if proj is None:
            return True
        if reload:
            proj.reload_settings()
        return proj.inventar_regel

    def set_inventory_rule(self, enabled: bool) -> dict[str, Any]:
        """Nur für die App (SETTINGS.inventar_regel): schreibt die Regel in kevcad.json des offenen Projekts und rechnet
        mit Auto-Lauf neu. Bewusst kein MCP-Werkzeug: abschalten darf nur Kevin."""
        proj = self._project
        if proj is None:
            return {"ok": False, "error": NO_PROJECT}
        if proj.inventar_regel == bool(enabled) and "inventar_regel" in proj.settings:
            return {"ok": True, "inventar_regel": proj.inventar_regel}
        try:
            proj.set_setting("inventar_regel", bool(enabled))
        except OSError as exc:
            self._log(f"[kernel] kevcad.json nicht schreibbar: {exc}")
            return {"ok": False, "error": f"kevcad.json nicht schreibbar: {exc}"}
        self._log(f"[kernel] Inventar-Regel {'an' if enabled else 'aus'} für {proj.name}")
        self._send_app({"type": "PROJECT", **proj.info()})
        with self._lock:
            ok = bool(self._settings.get("auto_run"))
        if ok:
            self._submit_run(None, 0, self.run_timeout_s, source="auto")
        return {"ok": True, "inventar_regel": bool(enabled)}

    def _catalog_dirs(self) -> dict[str, str | None]:
        d = self.catalog.dirs
        return {"builtin": d["builtin"], "own": d["own"]}

    def _rerun_after_catalog_change(self) -> None:
        """Kevin hat in der App einen Katalogeintrag geändert: mit Auto-Lauf neu rechnen, damit die Stückliste die
        neuen Preise und Gewichte zeigt. Läuft gerade ein Lauf mit demselben Dateistand, hat er noch den alten Katalog
        gelesen: dann folgt ein weiterer (sonst ginge etwa ein zweites übernommenes CAD verloren)."""
        with self._lock:
            ok = bool(self._settings.get("auto_run")) and self._project is not None and self._bom is not None
        if ok:
            self._submit_run(None, 0, self.run_timeout_s, source="auto", katalog_neu=True)

    # =================================================================================================================
    # Auto-Lauf
    # =================================================================================================================

    def _auto_check(self) -> None:
        proj = self._project
        if proj is None or not self._settings.get("auto_run"):
            return
        try:
            code = proj.model.read_text(encoding="utf-8")
        except OSError:
            return
        h = hashlib.sha1(code.encode("utf-8")).hexdigest()[:12]
        if h == self._last_hash:
            return
        self._submit_run(None, int(self._settings.get("slow_ms") or 0), self.run_timeout_s, source="auto")

    def _watch_loop(self) -> None:
        watched: Path | None = None
        last_sig = None
        changed_at: float | None = None
        while not self._closed:
            time.sleep(self.poll_interval_s)
            proj = self._project
            if proj is None:
                watched, last_sig, changed_at = None, None, None
                continue
            try:
                self._bestand_pruefen()  # bestand.json von außen geändert?
            except Exception as exc:  # noqa: BLE001
                self._log(f"[kernel] Bestand prüfen: {exc!r}")
            path = proj.model
            try:
                st = path.stat()
                sig = (st.st_mtime_ns, st.st_size, st.st_ino)
            except OSError:
                sig = None
            if path != watched:
                # neues Projekt: einmal prüfen (inhaltsbasiert), falls die Datei schon vor dem ersten Blick geändert wurde
                watched, last_sig, changed_at = path, sig, time.monotonic()
                continue
            now = time.monotonic()
            if sig != last_sig:
                last_sig, changed_at = sig, now
                continue
            if changed_at is not None and now - changed_at >= self.debounce_s:
                changed_at = None
                if sig is not None and self._settings.get("auto_run"):
                    try:
                        self._auto_check()
                    except Exception as exc:  # noqa: BLE001
                        self._log(f"[kernel] Auto-Lauf: {exc!r}")

    def _warm_parent(self) -> None:
        """build123d und die Messfunktionen im Elternprozess vorladen, damit das erste Messen schnell ist."""
        try:
            import kevcad_kernel.export  # noqa: F401
            import kevcad_kernel.measure  # noqa: F401
            from kevcad_kernel.bestand import vorladen

            vorladen()  # scipy für den Zuschnitt mit Bestand
        except Exception as exc:  # noqa: BLE001
            self._log(f"[kernel] Vorladen fehlgeschlagen: {exc!r}")


def _usage_example(item: dict[str, Any]) -> str:
    """Aufruf für model.py zu einem Lagerteil."""
    art = item.get("art")
    if art in ZUKAUF_ARTEN:
        return (f"teil = lager.zukauf({item['id']!r})\nstueck = teil.verbauen(\"{item.get('name') or 'Teil'}\")\n"
                f"show(stueck, \"{item.get('name') or 'Teil'}\")")
    head = f"teil = lager.teil({item['id']!r})\n"
    if art in STANGENWARE:
        return head + 'stueck = teil.verbauen(laenge=800, name="Gruppe/Teil", gehrung=(0, 0))\nshow(stueck, "Gruppe/Teil")'
    if art == "platte":
        return head + 'stueck = teil.verbauen(breite=800, tiefe=600, name="Platte")\nshow(stueck, "Platte")'
    if art == "schraube":
        return head + 'stueck = teil.verbauen(laenge=40, name="Schrauben/1")\nshow(stueck, "Schrauben/1")'
    return head + 'stueck = teil.verbauen(name="Kleinteile/1")\nshow(stueck, "Kleinteile/1")'


def _plausibility(item: dict[str, Any], values: dict[str, Any], material: dict[str, Any] | None) -> list[str]:
    """Hinweis, wenn ein angegebenes kg_je_m stark vom berechneten Querschnitt abweicht (Tippfehler?)."""
    from kevcad_kernel.bom import de_num
    from kevcad_kernel.catalog import number

    table = number(item.get("kg_je_m"))
    area = values.get("querschnitt_mm2")
    dichte = number((material or {}).get("dichte"))
    if table is None or not area or dichte is None or item.get("art") == "nutprofil":
        return []
    calc = area * dichte / 1000.0
    if abs(table - calc) / calc <= 0.15:
        return []
    return [f"kg_je_m {de_num(table, 3)} weicht stark vom Querschnitt ab (berechnet {de_num(calc, 3)} kg/m aus "
            f"{de_num(area, 1)} mm²): Maße und Gewicht prüfen"]


def _line_from_crash(stderr: str, model_path: str) -> int | None:
    """Zeile in model.py aus der faulthandler-Ausgabe eines abgestürzten Rechenprozesses."""
    needle = f'File "{model_path}", line '
    line = None
    for row in stderr.splitlines():
        i = row.find(needle)
        if i >= 0:
            rest = row[i + len(needle):]
            num = "".join(itertools.takewhile(str.isdigit, rest))
            if num:
                line = int(num)
                break  # faulthandler: innerster Rahmen zuerst
    return line


def create(socket_path: str, mcp_port: int) -> KernelRuntime:
    """Startet die Laufzeit (Unix-Socket zur App, Rechenprozess) und liefert die Fassade (KernelService)."""
    return KernelRuntime(socket_path, mcp_port)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m kevcad_kernel.runtime",
                                     description="Kernel-Laufzeit ohne MCP (zum Testen der App)")
    parser.add_argument("--socket", required=True, help="Pfad des Unix-Sockets zur App")
    parser.add_argument("--port", type=int, default=0, help="MCP-Port, der im HELLO gemeldet wird")
    parser.add_argument("--project", help="Projektordner gleich öffnen")
    parser.add_argument("--new", metavar="TEMPLATE", choices=("example", "empty"),
                        help="Projektordner neu anlegen (mit --project)")
    parser.add_argument("--no-auto-run", action="store_true", help="Auto-Lauf ausschalten")
    parser.add_argument("--timeout", type=float, default=120.0, help="Zeitlimit je Lauf in s")
    args = parser.parse_args(argv)
    rt = KernelRuntime(args.socket, args.port, auto_run=not args.no_auto_run, run_timeout_s=args.timeout)
    stop = threading.Event()

    def on_signal(signum, frame):  # noqa: ARG001
        stop.set()

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)
    _log(f"[kernel] lauscht auf {rt.socket_path}")
    if args.project:
        res = rt.project_new(args.project, args.new) if args.new else rt.project_open(args.project)
        _log(f"[kernel] Projekt: {res}")
    try:
        while not stop.wait(0.5):
            pass
    finally:
        rt.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
