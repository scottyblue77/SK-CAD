"""Die MCP-Werkzeuge von Kev CAD.

Alle Werkzeuge rufen nur den Vertrag ``KernelService`` (service.py). Blockierende Aufrufe laufen in einem
Worker-Thread, damit der Server parallel weiter antwortet. Beschreibungen sind englisch (für das Modell), Ergebnisse
deutsch (Kevin liest mit).
"""

from __future__ import annotations

import functools
import itertools
import logging
import math
import os
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Annotated, Any, Literal

import anyio
from mcp.server.mcpserver import MCPServer
from mcp_types import CallToolResult, ToolAnnotations
from pydantic import Field

from kevcad_kernel.service import KernelService

from . import format as fmt
from .tracking import ActivityTracker, SessionBoard, claude_session

log = logging.getLogger(__name__)

StandardView = Literal[
    "top", "bottom", "front", "back", "left", "right", "iso", "iso_front_left", "iso_back_right", "iso_back_left"
]
Projection = Literal["perspective", "orthographic"]
Display = Literal["shaded_edges", "shaded", "wireframe", "xray"]
ExportFormat = Literal["step", "stl", "3mf", "glb", "bom_csv", "einkaufsliste_csv"]
StockArt = Literal["rohr", "vierkantrohr", "rechteckrohr", "flach", "rund", "vierkant", "winkel", "u_profil",
                   "nutprofil", "holz", "platte", "schraube", "mutter", "scheibe", "zukaufteil"]
Ebene = Literal["eigen", "projekt"]

VIEW_NAMES = {
    "top": "oben", "bottom": "unten", "front": "vorne", "back": "hinten", "left": "links", "right": "rechts",
    "iso": "isometrisch", "iso_front_left": "isometrisch vorne links", "iso_back_right": "isometrisch hinten rechts",
    "iso_back_left": "isometrisch hinten links",
}
DISPLAY_NAMES = {"shaded_edges": "schattiert mit Kanten", "shaded": "schattiert", "wireframe": "Drahtgitter",
                 "xray": "Röntgen"}
PROJECTION_NAMES = {"perspective": "perspektivisch", "orthographic": "parallel (orthographisch)"}
KIND_NAMES = {"dimension": "ein Maß", "label": "eine Beschriftung", "arrow": "einen Pfeil"}

NAMED_COLORS = {
    "red": "#E53935", "rot": "#E53935", "green": "#43A047", "grün": "#43A047", "gruen": "#43A047",
    "blue": "#1E88E5", "blau": "#1E88E5", "yellow": "#FDD835", "gelb": "#FDD835", "orange": "#FB8C00",
    "magenta": "#D81B60", "pink": "#D81B60", "cyan": "#00ACC1", "türkis": "#00ACC1", "purple": "#8E24AA",
    "lila": "#8E24AA", "white": "#FFFFFF", "weiß": "#FFFFFF", "weiss": "#FFFFFF", "black": "#000000",
    "schwarz": "#000000", "grey": "#9E9E9E", "gray": "#9E9E9E", "grau": "#9E9E9E",
}

READ_ONLY = ToolAnnotations(read_only_hint=True, open_world_hint=False)
VIEWER = ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=True, open_world_hint=False)
WRITES = ToolAnnotations(read_only_hint=False, destructive_hint=True, idempotent_hint=False, open_world_hint=False)
ADDITIVE = ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=False, open_world_hint=False)


class ToolInputError(ValueError):
    """Ungültige Eingabe, die der Agent selbst beheben kann."""


def projects_dir() -> Path:
    return Path(os.environ.get("KEVCAD_PROJECTS_DIR") or Path.home() / "Documents" / "Kev CAD")


def resolve_project_path(path: str) -> str:
    """Absoluter Projektpfad; ein bloßer Name (oder relativer Pfad) landet unter ~/Documents/Kev CAD/."""
    text = path.strip()
    if not text:
        raise ToolInputError("Pfad fehlt.")
    p = Path(text).expanduser()
    if not p.is_absolute():
        p = projects_dir() / p
    return str(p)


def srgb_to_linear(c: float) -> float:
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def parse_color(color: str | list[float] | None) -> list[float] | None:
    """Farbe als lineares RGBA 0…1 (wie ``color`` in PART_UPSERT). Hex und Namen gelten als sRGB."""
    if color is None:
        return None
    if isinstance(color, (list, tuple)):
        values = [float(v) for v in color]
        if len(values) not in (3, 4) or not all(0.0 <= v <= 1.0 for v in values):
            raise ToolInputError("Farbe als Liste: 3 oder 4 Werte zwischen 0 und 1 (lineares RGB[A]).")
        return values + [1.0] * (4 - len(values))
    text = NAMED_COLORS.get(color.strip().lower(), color.strip())
    hexpart = text.lstrip("#")
    if len(hexpart) in (3, 4):
        hexpart = "".join(ch * 2 for ch in hexpart)
    if len(hexpart) not in (6, 8) or any(ch not in "0123456789abcdefABCDEF" for ch in hexpart):
        raise ToolInputError(f"Unbekannte Farbe {color!r}: Hex wie \"#FF8800\", einen Namen wie \"orange\" oder "
                             f"[r, g, b] mit Werten 0…1 angeben.")
    channels = [int(hexpart[i:i + 2], 16) / 255 for i in range(0, len(hexpart), 2)]
    rgba = [round(srgb_to_linear(c), 6) for c in channels[:3]] + [round(channels[3], 6) if len(channels) == 4 else 1.0]
    return rgba


def check_points(points: list[list[float]], need: int) -> list[list[float]]:
    out = []
    for p in points:
        if len(p) != 3 or not all(isinstance(v, (int, float)) and math.isfinite(v) for v in p):
            raise ToolInputError("Jeder Punkt braucht genau drei Zahlen [x, y, z] in mm.")
        out.append([float(v) for v in p])
    if len(out) < need:
        raise ToolInputError(f"Es werden mindestens {need} Punkte gebraucht, angegeben sind {len(out)}.")
    return out


def check_refs(refs: list[str], *, minimum: int = 1, maximum: int | None = None) -> list[str]:
    clean = [r.strip() for r in refs if isinstance(r, str) and r.strip()]
    if len(clean) < minimum:
        raise ToolInputError("Mindestens eine Referenz angeben, z. B. \"Grundplatte\" oder \"Grundplatte#f3\".")
    if maximum is not None and len(clean) > maximum:
        raise ToolInputError(f"Höchstens {maximum} Referenzen angeben.")
    return clean


def cap(text: str) -> str:
    """Erster Buchstabe groß, der Rest bleibt (anders als str.capitalize)."""
    return text[:1].upper() + text[1:]


def short_refs(refs: list[str], limit: int = 3) -> str:
    if not refs:
        return "nichts"
    text = ", ".join(refs[:limit])
    return text + (f" und {len(refs) - limit} weitere" if len(refs) > limit else "")


class KevcadTools:
    """Bindet die Werkzeuge an einen ``KernelService``."""

    def __init__(self, service: KernelService, board: SessionBoard | None = None) -> None:
        self.service = service
        self.activity = ActivityTracker(service.set_agent_activity)
        # Sitzungen (MIRROR.md): ohne eigene Tafel meldet eine neue direkt an den Dienst, falls er das kann
        self.board = board if board is not None else SessionBoard(getattr(service, "set_agent_sessions", None))
        self._annotation_ids = itertools.count(1)

    async def work(self, activity: str | None, fn: Callable[..., Any], *args: Any, **kwargs: Any) -> Any:
        """Führt einen blockierenden Service-Aufruf im Worker-Thread aus und zeigt dabei die Tätigkeit in der App."""

        session = claude_session.get()

        def job() -> Any:
            token = self.activity.begin(activity) if activity else None
            session_token = self.board.activity_begin(session, activity) if activity else None
            try:
                return fn(*args, **kwargs)
            finally:
                if token is not None:
                    self.activity.end(token)
                self.board.activity_end(session_token)

        return await anyio.to_thread.run_sync(job, abandon_on_cancel=True)

    async def view_cmd(self, activity: str, cmd: str, args: dict[str, Any], done: str) -> CallToolResult:
        res = await self.work(activity, self.service.view_command, cmd, args)
        err = fmt.service_error(res)
        msg = res.get("message") if isinstance(res, dict) else None
        data: dict[str, Any] = {"cmd": cmd, "args": args}
        if msg:
            data["message"] = msg
        if err:
            return fmt.error_result(f"Viewer-Befehl {cmd} fehlgeschlagen: {err}", data)
        return fmt.result(done + (f" ({msg})" if msg else ""), data)


RUN_TIMEOUT_MAX_S = 900.0  # Obergrenze für run(timeout_s=…)


def _guard(fn: Callable[..., Awaitable[CallToolResult]]) -> Callable[..., Awaitable[CallToolResult]]:
    """Fängt Fehler ab, damit der Agent sie lesbar als isError sieht (statt einer nichtssagenden Meldung)."""

    @functools.wraps(fn)
    async def wrapper(*args: Any, **kwargs: Any) -> CallToolResult:
        try:
            return await fn(*args, **kwargs)
        except ToolInputError as exc:
            return fmt.error_result(f"Ungültige Eingabe: {exc}")
        except Exception as exc:  # unerwartet: Text trotzdem zeigen, Details ins Protokoll
            log.exception("Werkzeug %s fehlgeschlagen", fn.__name__)
            return fmt.error_result(f"Interner Fehler im Kernel bei {fn.__name__}: {type(exc).__name__}: {exc}")

    return wrapper


def _tracked(fn: Callable[..., Awaitable[CallToolResult]], board: SessionBoard, *,
             mutating: bool) -> Callable[..., Awaitable[CallToolResult]]:
    """Meldet jeden Aufruf mit der Claude-Sitzung der Anfrage an die Sitzungstafel."""

    @functools.wraps(fn)
    async def wrapper(*args: Any, **kwargs: Any) -> CallToolResult:
        board.tool_called(claude_session.get(), mutating)
        return await fn(*args, **kwargs)

    return wrapper


def _unbekannte_ablehnen(mcp: MCPServer, name: str) -> None:
    """Unbekannte Argumente eines Werkzeugs ablehnen statt still zu verwerfen (KevCup, 22.10.2026: run(timeout_s=400)
    verschwand ohne Meldung). Die MCP-Bibliothek prüft die Argumente mit einem pydantic-Modell, das zusätzliche Felder
    ignoriert; hier bekommt es ``extra="forbid"``, und das Schema sagt ``additionalProperties: false``. Ein
    Tippfehler im Namen kommt so als Fehler mit dem Feldnamen zurück („Extra inputs are not permitted“)."""
    from pydantic import ConfigDict

    manager = getattr(mcp, "_tool_manager", None)
    werkzeug = manager.get_tool(name) if manager is not None and hasattr(manager, "get_tool") else None
    meta = getattr(werkzeug, "fn_metadata", None)
    modell = getattr(meta, "arg_model", None)
    if werkzeug is None or modell is None or modell.model_config.get("extra") == "forbid":
        return
    streng = type(modell.__name__, (modell,), {"__module__": modell.__module__,
                                                "model_config": ConfigDict(**{**modell.model_config,
                                                                              "extra": "forbid"})})
    meta.arg_model = streng
    werkzeug.parameters = {**werkzeug.parameters, "additionalProperties": False}


def register_tools(mcp: MCPServer, service: KernelService, board: SessionBoard | None = None) -> KevcadTools:
    """Registriert alle Werkzeuge am Server und liefert das Werkzeug-Objekt (für Tests). ``board`` führt die
    Claude-Sitzungen; jeder Aufruf eines nicht nur lesenden Werkzeugs zählt als verändernd."""
    t = KevcadTools(service, board)
    svc = service

    def tool(name: str, title: str, description: str, annotations: ToolAnnotations) -> Callable[..., Any]:
        def deco(fn: Callable[..., Awaitable[CallToolResult]]) -> Callable[..., Awaitable[CallToolResult]]:
            wrapped = _tracked(_guard(fn), t.board, mutating=not annotations.read_only_hint)
            mcp.add_tool(wrapped, name=name, title=title, description=description, annotations=annotations,
                         structured_output=False)
            _unbekannte_ablehnen(mcp, name)
            return wrapped

        return deco

    # ----------------------------------------------------------------------------------------------------- Projekt

    @tool("status", "Status",
          "Current state: open project (folder, model.py path), kernel state, app connection, summary of the last "
          "run and Kevin's current selection. Call this first.", READ_ONLY)
    async def status() -> CallToolResult:
        res = await t.work("schaut auf den Stand", svc.status)
        project = res.get("project") or None
        lines = []
        if project:
            lines.append(f"Projekt {project.get('name', '?')}: {project.get('path', '?')}")
            if project.get("model"):
                lines.append(f"model.py: {project['model']}")
        else:
            lines.append("Kein Projekt offen: project_open(path) oder project_new(path) aufrufen.")
        kernel = {"ready": "bereit", "busy": "rechnet", "error": "Fehler"}.get(res.get("kernel"), res.get("kernel"))
        app = "verbunden" if res.get("app_connected") else "nicht verbunden (Ansicht, Bilder und Auswahl gehen nicht)"
        lines.append(f"Kernel: {kernel} · App: {app}")
        last = res.get("last_run")
        if isinstance(last, dict) and last:
            if last.get("ok") is False:
                err = last.get("error") or {}
                msg = err.get("message") if isinstance(err, dict) else err
                line = err.get("line") if isinstance(err, dict) else None
                lines.append(f"Letzter Lauf {last.get('run', '?')}: Fehler" + (f" in Zeile {line}" if line else "")
                             + f": {msg}")
            else:
                n = len(last.get("parts") or [])
                lines.append(f"Letzter Lauf {last.get('run', '?')}: erfolgreich, {fmt.plural(n, 'Teil', 'Teile')}"
                             + (f", {fmt.ms_text(last['duration_ms'])}" if last.get("duration_ms") is not None
                                else ""))
        else:
            lines.append("Noch kein Lauf.")
        sel = res.get("selection") or {}
        refs = sel.get("refs") or []
        if refs:
            lines.append(f"Auswahl (Lauf {sel.get('run', '?')}): {short_refs(refs, 6)}")
        else:
            lines.append("Auswahl: nichts")
        inv = res.get("inventar") if isinstance(res.get("inventar"), dict) else None
        if inv is not None and project:
            if inv.get("regel", True):
                bad = inv.get("verstoesse") or []
                lines.append("Inventar-Regel: an (nur Lagerteile und Druckteile)"
                             + (f", {fmt.plural(len(bad), 'Verstoß', 'Verstöße')}: {short_refs(bad, 6)}" if bad else ""))
            else:
                lines.append("Inventar-Regel: aus (von Kevin für dieses Projekt abgeschaltet)")
        pr = res.get("pruefung") if isinstance(res.get("pruefung"), dict) else None
        if pr is not None and project:
            if pr.get("laeuft"):
                lines.append(f"Prüfung: läuft für Lauf {pr['laeuft']}")
            elif pr.get("state") in ("done", "teilweise"):
                hinten = []
                if pr.get("hintergrund"):
                    hinten.append("Bewegungsraum wird im Hintergrund fertig gerechnet")
                if pr.get("statik_hintergrund"):
                    hinten.append("Statik (Ablauf, Festkörper) rechnet im Hintergrund")
                if pr.get("state") == "teilweise" and not hinten:
                    hinten.append("Bewegungsraum nicht vollständig geprüft")
                lines.append(f"Prüfung (Lauf {pr.get('run', '?')}): "
                             + (pr.get("zusammenfassung") or "in Ordnung, keine Befunde")
                             + (f"; {', '.join(hinten)} (pruefen wartet darauf)" if hinten else ""))
        data = dict(res)
        if isinstance(last, dict) and last.get("parts"):
            data["last_run"] = {**last, "parts": [fmt.part_data(p) for p in last["parts"]]}
        return fmt.result("\n".join(lines), data)

    @tool("project_open", "Projekt öffnen",
          "Open an existing Kev CAD project folder (it contains model.py). A bare name or relative path resolves to "
          "~/Documents/Kev CAD/<name>.", WRITES)
    async def project_open(
        path: Annotated[str, Field(description="Project folder: absolute path, ~/..., or a bare project name")],
    ) -> CallToolResult:
        full = resolve_project_path(path)
        res = await t.work(f"öffnet Projekt {Path(full).name}", svc.project_open, full)
        err = fmt.service_error(res)
        if err:
            return fmt.error_result(f"Projekt {full} nicht geöffnet: {err}", res)
        return fmt.result(f"Projekt {res.get('name', Path(full).name)} geöffnet: {res.get('path', full)}\n"
                          f"model.py: {res.get('model', '?')}\nAls Nächstes run aufrufen, um das Modell zu bauen.",
                          res)

    @tool("project_new", "Projekt anlegen",
          "Create a new project folder with model.py and open it. template 'example' writes a small sample model, "
          "'empty' only the imports. A bare name resolves to ~/Documents/Kev CAD/<name>.", ADDITIVE)
    async def project_new(
        path: Annotated[str, Field(description="New project folder: absolute path, ~/..., or a bare project name")],
        template: Annotated[Literal["example", "empty"], Field(description="Starting content of model.py")]
        = "example",
    ) -> CallToolResult:
        full = resolve_project_path(path)
        res = await t.work(f"legt Projekt {Path(full).name} an", svc.project_new, full, template)
        err = fmt.service_error(res)
        if err:
            return fmt.error_result(f"Projekt {full} nicht angelegt: {err}", res)
        return fmt.result(f"Projekt {res.get('name', Path(full).name)} angelegt und geöffnet: "
                          f"{res.get('path', full)}\nmodel.py: {res.get('model', '?')} (Vorlage {template})", res)

    @tool("model_read", "model.py lesen",
          "Return the content of model.py of the open project. Prefer your own file tools when you have them.",
          READ_ONLY)
    async def model_read() -> CallToolResult:
        res = await t.work("liest model.py", svc.model_read)
        err = fmt.service_error(res)
        if err:
            return fmt.error_result(f"model.py nicht gelesen: {err}", res)
        code = res.get("code", "")
        lines = code.count("\n") + (1 if code and not code.endswith("\n") else 0)
        summary = (f"{res.get('path', 'model.py')} ({fmt.plural(lines, 'Zeile', 'Zeilen')}):\n"
                   f"```python\n{code.rstrip(chr(10))}\n```")
        return fmt.result(summary, {"ok": True, "path": res.get("path"), "code": code}, json_block=False)

    @tool("model_write", "model.py schreiben",
          "Overwrite model.py of the open project with the complete new file content. Use only if you have no file "
          "editing tools. Call run afterwards.", WRITES)
    async def model_write(
        code: Annotated[str, Field(description="Complete Python source of model.py")],
    ) -> CallToolResult:
        res = await t.work("schreibt model.py", svc.model_write, code)
        err = fmt.service_error(res)
        if err:
            return fmt.error_result(f"model.py nicht geschrieben: {err}", res)
        return fmt.result(f"model.py gespeichert ({fmt.num(res.get('bytes', len(code.encode())), 0)} Bytes): "
                          f"{res.get('path', '?')}. Jetzt run aufrufen.", res)

    # -------------------------------------------------------------------------------------------------------- Lauf

    @tool("run", "Modell ausführen",
          "Execute model.py of the open project; parts stream live into the viewer. Returns every part with bounding "
          "box size, volume (mm³) and mass (g), the steps, warnings and param() values. On failure (isError) the "
          "line, a code excerpt and a hint. params overrides param() values for this run; slow_ms > 0 pauses after "
          "each step()/show() so Kevin can watch the build (e.g. 400). A run that changed a project file becomes a "
          "version; titel names it in Kevin's words (give one for larger changes).", ADDITIVE)
    async def run(
        params: Annotated[dict[str, float] | None,
                          Field(description="Overrides for param() values by name, e.g. {\"breite\": 140}")] = None,
        slow_ms: Annotated[int, Field(ge=0, le=10000, description="Slow motion pause in ms per step, 0 = off")] = 0,
        titel: Annotated[str | None, Field(max_length=160, description=(
            "Short German description of this change in Kevin's words, e.g. 'Laufrollen auf Kugellager umgestellt'. "
            "Becomes the title of the new version; the automatic title (what changed) stays below it. Give one for "
            "larger changes, omit it for small fixes."))] = None,
        timeout_s: Annotated[float | None, Field(ge=10, le=RUN_TIMEOUT_MAX_S, description=(
            "Time limit for executing model.py in seconds (default 120, at most 900). Raise it only for large "
            "models whose run was refused for the time limit; the check after the run has its own limit"))] = None,
    ) -> CallToolResult:
        activity = "führt model.py aus" + (" in Zeitlupe" if slow_ms else "")
        extra: dict[str, Any] = {}
        if titel and titel.strip():
            extra["titel"] = titel.strip()
        if timeout_s is not None:
            extra["timeout_s"] = float(timeout_s)
        res = await t.work(activity, svc.run, params, slow_ms, **extra)
        summary, data, failed = fmt.run_summary(res)
        return fmt.result(summary, data, error=failed)

    @tool("execute", "Python ausführen",
          "Run Python in the namespace of the last run (all model.py variables, build123d imported) to inspect "
          "geometry, e.g. `print(platte.bounding_box())` or `[round(f.area, 2) for f in platte.faces()]`. Objects "
          "passed to show() appear as a translucent sketch. Returns stdout and the repr of the last expression. "
          "Does not change model.py.", ADDITIVE)
    async def execute(
        code: Annotated[str, Field(description="Python code; the value of a final expression is returned")],
    ) -> CallToolResult:
        res = await t.work("führt Python im Modell aus", svc.execute, code)
        out = (res.get("stdout") or "").rstrip()
        value = res.get("result")
        err = fmt.service_error(res)
        if err:
            text = f"Fehler beim Ausführen: {err}" + (f"\nAusgabe:\n{out}" if out else "")
            return fmt.error_result(text, res)
        parts = []
        if out:
            parts.append(f"Ausgabe:\n{out}")
        if value not in (None, "None", ""):
            parts.append(f"Ergebnis: {value}")
        return fmt.result("\n".join(parts) or "Ausgeführt, keine Ausgabe.", res)

    @tool("parts", "Teile",
          "Parts of the last run as a tree: bounding box (min/max/size in mm), volume mm³, area mm², mass g, "
          "material, color, face/edge/triangle counts, visibility. Use the names as references.", READ_ONLY)
    async def parts() -> CallToolResult:
        res = await t.work("liest die Teileliste", svc.parts)
        if isinstance(res, dict):  # falls die Laufzeit einen Fehler meldet
            err = fmt.service_error(res)
            if err:
                return fmt.error_result(f"Teile nicht verfügbar: {err}", res)
            res = res.get("parts") or []
        items = list(res or [])
        if not items:
            return fmt.result("Keine Teile. Erst run aufrufen (und in model.py show() benutzen).", {"parts": []})
        summary = f"{fmt.plural(len(items), 'Teil', 'Teile')}:\n{fmt.parts_tree(items)}"
        return fmt.result(summary, {"parts": items})

    # ---------------------------------------------------------------------------------------------------- Ansicht

    @tool("view", "Ansicht",
          "Set camera and display in the viewer: standard view, projection, display style, fit everything into view; "
          "explode 0..1 spreads the parts of assemblies apart (0 = assembled). Omitted values stay unchanged.", VIEWER)
    async def view(
        standard: Annotated[StandardView | None, Field(description="Standard view direction")] = None,
        projection: Annotated[Projection | None, Field(description="Camera projection")] = None,
        display: Annotated[Display | None, Field(description="Display style")] = None,
        fit: Annotated[bool, Field(description="Zoom so that all visible parts fit")] = False,
        explode: Annotated[float | None, Field(ge=0, le=1, description="Explosion factor 0..1")] = None,
    ) -> CallToolResult:
        if standard is None and projection is None and display is None and not fit and explode is None:
            raise ToolInputError("Nichts zu tun: standard, projection, display, fit oder explode angeben.")
        bits = []
        if standard:
            bits.append(f"Ansicht {VIEW_NAMES.get(standard, standard)}")
        if projection:
            bits.append(PROJECTION_NAMES.get(projection, projection))
        if display:
            bits.append(DISPLAY_NAMES.get(display, display))
        if fit:
            bits.append("alles eingepasst")
        results = []
        if standard is not None or projection is not None or display is not None or fit:
            args = {"standard": standard, "projection": projection, "display": display, "fit": fit}
            res = await t.view_cmd("stellt die Ansicht ein", "view", args, cap(", ".join(bits)) + ".")
            if res.is_error:
                return res
            results.append(res)
        if explode is not None:
            res = await t.view_cmd("zieht die Baugruppe auseinander" if explode > 0 else "baut die Explosion zurück",
                                   "explode", {"factor": float(explode)},
                                   f"Explosion {fmt.num(explode * 100, 0)} %.")
            if res.is_error:
                return res
            results.append(res)
        if len(results) == 1:
            return results[0]
        texts = [r.content[0].text for r in results]  # type: ignore[union-attr]
        return fmt.result(" ".join(texts), {"commands": [r.structured_content for r in results]})

    @tool("focus", "Fokus",
          "Move the camera (animated) to parts or elements, e.g. [\"Halter/Lasche\"] or [\"Grundplatte#f3\"].", VIEWER)
    async def focus(
        refs: Annotated[list[str], Field(description="Part names or element references of the current run")],
        animate: Annotated[bool, Field(description="Animate the camera move so Kevin can follow")] = True,
    ) -> CallToolResult:
        refs = check_refs(refs)
        return await t.view_cmd(f"zoomt auf {short_refs(refs)}", "focus", {"refs": refs, "animate": animate},
                                f"Kamera auf {short_refs(refs)} ausgerichtet.")

    @tool("visibility", "Sichtbarkeit",
          "Show, hide or isolate parts (isolate = only these visible); show_all makes everything visible again.",
          VIEWER)
    async def visibility(
        mode: Annotated[Literal["show", "hide", "isolate", "show_all"], Field(description="What to do")],
        refs: Annotated[list[str] | None, Field(description="Part names; not needed for show_all")] = None,
    ) -> CallToolResult:
        if mode == "show_all":
            clean: list[str] = []
            activity, done = "zeigt alle Teile", "Alle Teile sichtbar."
        else:
            clean = check_refs(refs or [])
            activity, done = {
                "show": (f"blendet {short_refs(clean)} ein", f"{short_refs(clean)} eingeblendet."),
                "hide": (f"blendet {short_refs(clean)} aus", f"{short_refs(clean)} ausgeblendet."),
                "isolate": (f"isoliert {short_refs(clean)}", f"Nur noch {short_refs(clean)} sichtbar."),
            }[mode]
        return await t.view_cmd(activity, "visibility", {"mode": mode, "refs": clean}, done)

    @tool("highlight", "Hervorheben",
          "Highlight parts, faces, edges or vertices in color, optionally with a text label next to them. "
          "color: hex like \"#FF8800\", a name (red, orange, green, blue, ...) or linear RGB(A) 0..1; default is the "
          "viewer's highlight color. clear=true removes earlier highlights first; refs=[] with clear=true only "
          "clears.", VIEWER)
    async def highlight(
        refs: Annotated[list[str], Field(description="Parts or element references to highlight")],
        color: Annotated[str | list[float] | None, Field(description="Highlight color")] = None,
        label: Annotated[str | None, Field(description="Short text shown next to the highlight")] = None,
        clear: Annotated[bool, Field(description="Remove previous highlights first")] = True,
    ) -> CallToolResult:
        clean = check_refs(refs, minimum=0 if clear else 1)
        rgba = parse_color(color)
        args = {"refs": clean, "color": rgba, "label": label, "clear": clear}
        if not clean:
            return await t.view_cmd("entfernt Hervorhebungen", "highlight", args, "Hervorhebungen entfernt.")
        return await t.view_cmd(f"hebt {short_refs(clean)} hervor", "highlight", args,
                                f"{short_refs(clean)} hervorgehoben" + (f" mit „{label}“" if label else "") + ".")

    @tool("section", "Schnitt",
          "Section view: cut plane perpendicular to axis x, y or z (or along a custom normal) at offset mm from the "
          "origin; material on the positive side is cut away. enabled=false removes the section.", VIEWER)
    async def section(
        enabled: Annotated[bool, Field(description="true = show section, false = remove it")],
        axis: Annotated[Literal["x", "y", "z"] | None, Field(description="Plane normal axis (default z)")] = None,
        offset: Annotated[float, Field(description="Plane position along the normal in mm")] = 0,
        normal: Annotated[list[float] | None, Field(description="Custom plane normal [x, y, z] instead of axis")]
        = None,
    ) -> CallToolResult:
        args: dict[str, Any] = {"enabled": enabled, "offset": float(offset)}
        if normal is not None:
            normal = check_points([normal], 1)[0]
            if not any(normal):
                raise ToolInputError("Die Normale darf nicht [0, 0, 0] sein.")
            args["normal"] = normal
            where = f"Normale {fmt.vec(normal)}"
        else:
            args["axis"] = axis or "z"
            where = f"senkrecht zu {(axis or 'z').upper()}"
        if not enabled:
            return await t.view_cmd("entfernt den Schnitt", "section", args, "Schnitt entfernt.")
        return await t.view_cmd(f"schneidet {where} bei {fmt.num(offset)} mm", "section", args,
                                f"Schnitt {where} bei {fmt.num(offset)} mm.")

    @tool("screenshot", "Bild",
          "PNG image of the viewer. Only when Kevin asks for an image: he watches the viewer himself, and checking "
          "your work goes faster with run, parts and measure. source 'current' shows exactly what Kevin sees; "
          "'offscreen' renders a standard view without moving his camera (pass view). Also returns camera data and "
          "mm per pixel (orthographic only). Keep the default size unless you need fine detail.", READ_ONLY)
    async def screenshot(
        width: Annotated[int, Field(ge=64, le=4096, description="Image width in px")] = 1280,
        height: Annotated[int, Field(ge=64, le=4096, description="Image height in px")] = 800,
        source: Annotated[Literal["current", "offscreen"], Field(description="Current view or offscreen render")]
        = "current",
        view: Annotated[StandardView | None, Field(description="Standard view for offscreen rendering")] = None,
        hide_overlays: Annotated[bool, Field(description="Hide highlights, annotations and measurements")] = False,
    ) -> CallToolResult:
        if view is not None and source == "current":
            source = "offscreen"  # eine Standardansicht gibt es nur offscreen; Kevins Kamera bleibt stehen
        res = await t.work("macht ein Bild der Ansicht", svc.screenshot, width, height, source, view, hide_overlays)
        err = fmt.service_error(res)
        if err:
            return fmt.error_result(f"Kein Bild: {err}")
        png = res.get("png") or b""
        if not png:
            return fmt.error_result("Kein Bild: die App hat leere Bilddaten geliefert.")
        w, h = res.get("width", width), res.get("height", height)
        what = "aktuelle Ansicht" if source == "current" else f"offscreen, Ansicht {VIEW_NAMES.get(view or '', view)}"
        mmpx = res.get("mm_per_px")
        scale = (f"{fmt.num(mmpx, 4)} mm je Pixel" if isinstance(mmpx, (int, float))
                 else "perspektivisch, kein fester Maßstab")
        summary = f"Bild {w} × {h} px ({what}), {scale}.\n{fmt.camera_text(res.get('camera'))}"
        data = {"width": w, "height": h, "source": source, "view": view, "camera": res.get("camera"),
                "mm_per_px": mmpx, "bytes": len(png)}
        return fmt.result(summary, data, extra=[fmt.image_block(png)])

    # ------------------------------------------------------------------------------------------ Messen und Auswahl

    @tool("selection", "Auswahl",
          "What Kevin has currently selected in the viewer: references with their properties (type, area, length, "
          "radius, position, ...). Empty if nothing is selected.", READ_ONLY)
    async def selection() -> CallToolResult:
        res = await t.work("liest die Auswahl", svc.selection)
        err = fmt.service_error(res)
        if err:
            return fmt.error_result(f"Auswahl nicht lesbar: {err}", res)
        refs = res.get("refs") or []
        if not refs:
            return fmt.result("Kevin hat nichts ausgewählt.", res)
        details = res.get("details") or []
        lines = [f"Kevin hat {fmt.plural(len(refs), 'Element', 'Elemente')} ausgewählt (Lauf {res.get('run', '?')}):"]
        by_ref = {}
        for d in details:
            if isinstance(d, dict) and d.get("refs"):
                by_ref[d["refs"][0]] = d
        for ref in refs:
            d = by_ref.get(ref)
            lines.append("- " + (fmt.measure_line(d) if d else ref))
        return fmt.result("\n".join(lines), res)

    @tool("measure", "Messen",
          "Exact measurement in the kernel (OCCT). One ref: its properties (face area/normal/radius, edge "
          "length/radius, vertex position, part bbox/volume/mass). Two refs: minimum distance with dx/dy/dz and both "
          "points, angle, distance of parallel faces or axes. show=true also draws it in the viewer.", ADDITIVE)
    async def measure(
        refs: Annotated[list[str], Field(description="One or two references of the current run")],
        show: Annotated[bool, Field(description="Draw the measurement in the viewer")] = True,
    ) -> CallToolResult:
        refs = check_refs(refs, maximum=2)
        activity = f"misst Abstand {refs[0]} ↔ {refs[1]}" if len(refs) == 2 else f"misst {refs[0]}"
        res = await t.work(activity, svc.measure, refs, show)
        err = fmt.service_error(res)
        if err:
            return fmt.error_result(f"Messung nicht möglich: {err}", res)
        summary = fmt.measure_line(res) + (" (im Viewer eingeblendet)" if show else "")
        return fmt.result(summary, res)

    @tool("annotate", "Anmerkung",
          "Draw an annotation in the viewer: 'dimension' (2 points; text defaults to the measured distance), "
          "'arrow' (from point 1 to point 2, optional text) or 'label' (1 point + text). Points are world "
          "coordinates in mm. Returns the id for clear_annotations.", ADDITIVE)
    async def annotate(
        kind: Annotated[Literal["dimension", "label", "arrow"], Field(description="Kind of annotation")],
        points: Annotated[list[list[float]], Field(description="Points [[x, y, z], ...] in mm")],
        text: Annotated[str | None, Field(description="Text to show")] = None,
        id: Annotated[str | None, Field(description="Own id to remove it later; generated if omitted")] = None,
    ) -> CallToolResult:
        pts = check_points(points, 1 if kind == "label" else 2)
        if kind == "label" and not text:
            raise ToolInputError("Eine Beschriftung (label) braucht text.")
        if kind == "dimension" and not text:
            text = f"{fmt.num(math.dist(pts[0], pts[1]), 2)} mm"
        ann_id = id or f"agent-{next(t._annotation_ids)}"
        args = {"kind": kind, "points": pts, "text": text, "id": ann_id}
        res = await t.view_cmd(f"zeigt {KIND_NAMES[kind]}", "annotate", args,
                               f"{cap(KIND_NAMES[kind])} eingeblendet" + (f": {text}" if text else "")
                               + f" (id {ann_id}).")
        if not res.is_error and isinstance(res.structured_content, dict):
            res.structured_content["id"] = ann_id
        return res

    @tool("clear_annotations", "Anmerkungen entfernen",
          "Remove annotations by id, or all annotations if ids is omitted.", VIEWER)
    async def clear_annotations(
        ids: Annotated[list[str] | None, Field(description="Annotation ids; omit to remove all")] = None,
    ) -> CallToolResult:
        done = "Alle Anmerkungen entfernt." if ids is None else f"Anmerkungen {short_refs(ids)} entfernt."
        return await t.view_cmd("entfernt Anmerkungen", "clear_annotations", {"ids": ids}, done)

    # ------------------------------------------------------------------------------------------------------ Export

    @tool("export", "Export",
          "Export the model into <project>/output/: formats step, stl, 3mf and/or glb; bom_csv writes the bill of "
          "materials with cut list as CSV for Numbers/Excel, einkaufsliste_csv the shopping list. parts limits the 3D export to these part names "
          "(default: all parts).", ADDITIVE)
    async def export(
        formats: Annotated[list[ExportFormat], Field(min_length=1, description="File formats to write")],
        parts: Annotated[list[str] | None, Field(description="Part names to export; omit for all")] = None,
    ) -> CallToolResult:
        names = ", ".join(f.upper() for f in formats)
        res = await t.work(f"exportiert {names}", svc.export, list(formats), parts)
        err = fmt.service_error(res)
        if err:
            return fmt.error_result(f"Export fehlgeschlagen: {err}", res)
        files = res.get("files") or []
        summary = f"{fmt.plural(len(files), 'Datei', 'Dateien')} exportiert:\n" + "\n".join(f"- {f}" for f in files)
        for w in res.get("warnings") or []:
            summary += f"\nHinweis: {w}"
        return fmt.result(summary, res)

    # ----------------------------------------------------------------------------------------- Lager und Stückliste

    @tool("stock_search", "Lagerteile suchen",
          "Search Kevin's stock catalog (tubes, profiles, flat/round bar, angles, aluminium extrusions, timber, sheets, "
          "screws, nuts, washers, released purchased parts) by text and dimensions, e.g. 'vierkantrohr 40x40x3', "
          "'edelstahl rohr 33,7', 'multiplex 18', 'm8', 'alutec 05200'. Use the returned id in model.py: "
          "lager.teil(id).verbauen(...), purchased parts (art zukaufteil) with lager.zukauf(id). art filters by kind.",
          READ_ONLY)
    async def stock_search(
        query: Annotated[str, Field(description="Words and dimensions, e.g. 'rohr 42,4x2' or '40x40'")] = "",
        art: Annotated[StockArt | None, Field(description="Only this kind of stock")] = None,
    ) -> CallToolResult:
        res = await t.work(f"sucht Lagerteile „{query}“" if query else "listet Lagerteile", svc.stock_search,
                           query, art)
        err = fmt.service_error(res)
        if err:
            return fmt.error_result(f"Suche fehlgeschlagen: {err}", res)
        items = res.get("items") or []
        total = int(res.get("total", len(items)))
        what = f"„{query}“" if query else "alles"
        if art:
            what += f" (art {art})"
        if not items:
            text = (f"Keine Lagerteile für {what}. Andere Wörter oder nur ein Maß versuchen; neue Lagerteile nur auf "
                    "Kevins Wunsch mit stock_define anlegen.")
            return fmt.result(text, res)
        head = f"{fmt.plural(total, 'Lagerteil', 'Lagerteile')} für {what}" + (
            f", die ersten {len(items)}:" if total > len(items) else ":")
        text = head + "\n" + fmt.stock_table(items)
        text += "\nIn model.py: lager.teil(\"<id>\").verbauen(...); Details mit stock_get."
        if any(it.get("art") == "zukaufteil" for it in items):
            text += " Zukaufteile (art zukaufteil): lager.zukauf(\"<id>\").verbauen(\"Name\")."
        return fmt.result(text, res)

    @tool("stock_get", "Lagerteil",
          "Details of one stock item by id: dimensions, material and density, cross section area, kg per meter "
          "(table or computed), bar length, price with source and date, and a usage example for model.py.", READ_ONLY)
    async def stock_get(
        id: Annotated[str, Field(description="Stock id from stock_search")],
    ) -> CallToolResult:
        res = await t.work(f"liest Lagerteil {id}", svc.stock_get, id)
        err = fmt.service_error(res)
        if err:
            return fmt.error_result(f"Lagerteil nicht gefunden: {err}", res)
        return fmt.result(fmt.stock_detail(res), res)

    @tool("stock_define", "Lagerteil vorschlagen",
          "Propose a new stock item for Kevin's own catalog (ebene 'eigen') or the project catalog ('projekt'). Only "
          "when Kevin asks for it. It is stored with status 'vorgeschlagen' and cannot be used in model.py until "
          "Kevin releases it (ask with freigabe_anfragen); released entries cannot be changed here. entry "
          "follows KATALOG.md: id (lowercase, hyphens), art, name (German, '33,7 × 2'), norm, masse (mm), material "
          "(material id, see material_list), optional kg_je_m, stangenlaenge (mm), platte [b, h], preis {je_m | "
          "je_m2 | je_stueck, quelle, stand 'YYYY-MM'}, tags. Validated; errors list every problem.", WRITES)
    async def stock_define(
        entry: Annotated[dict[str, Any], Field(description="Stock item as in KATALOG.md")],
        ebene: Annotated[Ebene, Field(description="eigen = Kevin's own catalog, projekt = this project")] = "eigen",
    ) -> CallToolResult:
        name = entry.get("id", "?") if isinstance(entry, dict) else "?"
        res = await t.work(f"legt Lagerteil {name} an", svc.stock_define, entry, ebene)
        err = fmt.service_error(res)
        if err:
            return fmt.error_result(f"Lagerteil nicht gespeichert:\n{err}", res)
        item = res.get("item") or {}
        where = "eigenen Katalog" if ebene == "eigen" else "Projekt-Katalog"
        lines = [f"Lagerteil {item.get('id')} ({item.get('name')}) als Vorschlag im {where} gespeichert: "
                 f"{res.get('datei')}",
                 "Es wartet auf Kevins Freigabe; bis dahin lässt es sich nicht verbauen. Mit "
                 f"freigabe_anfragen([\"{item.get('id')}\"], grund) öffnest du den Dialog im Projektfenster."]
        lines.append(fmt.stock_detail({**res, "beispiel": None}).split("\n", 1)[-1])
        for note in res.get("hinweise") or []:
            lines.append(f"Hinweis: {note}")
        return fmt.result("\n".join(lines), res)

    @tool("material_list", "Materialien",
          "Materials of the catalog (id, name, group, density g/cm³, price €/kg, color, aliases, level). Use ids or "
          "aliases for material= in show() and for stock items. query filters by text.", READ_ONLY)
    async def material_list(
        query: Annotated[str, Field(description="Filter text, e.g. 'edelstahl' or 'holz'")] = "",
    ) -> CallToolResult:
        res = await t.work("liest die Materialien", svc.material_list, query)
        err = fmt.service_error(res)
        if err:
            return fmt.error_result(f"Materialien nicht lesbar: {err}", res)
        mats = res.get("materials") or []
        if not mats:
            return fmt.result(f"Keine Materialien für „{query}“." if query else "Der Katalog hat keine Materialien.",
                              res)
        text = f"{fmt.plural(len(mats), 'Material', 'Materialien')}:\n{fmt.material_table(mats)}"
        return fmt.result(text, res)

    @tool("material_define", "Material vorschlagen",
          "Propose a new material for Kevin's own catalog ('eigen') or the project catalog ('projekt'). Only when "
          "Kevin asks for it. Stored with status 'vorgeschlagen'; usable only after Kevin releases it (ask with "
          "freigabe_anfragen). entry: id, name, gruppe (Stahl, Edelstahl, Aluminium, Holz, Kunststoff, ...), dichte "
          "g/cm³, farbe sRGB hex, optional metallisch/rauheit 0..1, druckbar (true for 3D printing filament), "
          "preis_je_kg with preis_quelle and preis_stand 'YYYY-MM', aliase (lowercase).", WRITES)
    async def material_define(
        entry: Annotated[dict[str, Any], Field(description="Material as in KATALOG.md")],
        ebene: Annotated[Ebene, Field(description="eigen = Kevin's own catalog, projekt = this project")] = "eigen",
    ) -> CallToolResult:
        name = entry.get("id", "?") if isinstance(entry, dict) else "?"
        res = await t.work(f"legt Material {name} an", svc.material_define, entry, ebene)
        err = fmt.service_error(res)
        if err:
            return fmt.error_result(f"Material nicht gespeichert:\n{err}", res)
        mat = res.get("material") or {}
        lines = [f"Material {mat.get('id')} ({mat.get('name')}, {fmt.num(mat.get('dichte'), 3)} g/cm³) als Vorschlag "
                 f"gespeichert: {res.get('datei')}",
                 "Es wartet auf Kevins Freigabe; bis dahin lässt es sich nicht benutzen. Mit "
                 f"freigabe_anfragen([\"{mat.get('id')}\"], grund) öffnest du den Dialog im Projektfenster."]
        for note in res.get("hinweise") or []:
            lines.append(f"Hinweis: {note}")
        return fmt.result("\n".join(lines), res)

    @tool("catalog_delete", "Katalogeintrag löschen",
          "Delete a stock item (kind 'teil') or material ('material') from Kevin's own or the project catalog. Only "
          "when Kevin asks for it. An entry that comes from a lower level (e.g. the bundled catalog) is hidden with "
          "\"entfernt\": true instead.", WRITES)
    async def catalog_delete(
        kind: Annotated[Literal["teil", "material"], Field(description="teil = stock item, material = material")],
        id: Annotated[str, Field(description="id of the entry")],
        ebene: Annotated[Ebene, Field(description="Catalog level to change")] = "eigen",
    ) -> CallToolResult:
        res = await t.work(f"löscht {id} aus dem Katalog", svc.catalog_delete, kind, id, ebene)
        err = fmt.service_error(res)
        if err:
            return fmt.error_result(f"Nicht gelöscht: {err}", res)
        return fmt.result(str(res.get("message") or f"{id} gelöscht."), res)

    @tool("freigabe_anfragen", "Freigabe anfragen",
          "Ask Kevin to release proposals (stock items, materials, purchased parts from stock_define, material_define, "
          "zukauf_anlegen) right in the project window: opens the dialog 'Vorschläge freigeben' with a preview of the "
          "data, the link and a 'Freigeben' button per entry and for all. Use it instead of telling Kevin to open the "
          "stock catalog, and whenever Kevin says in the chat that something is released ('freigegeben'): a chat "
          "answer releases nothing, only his click does. This tool never releases anything itself. It waits up to "
          "warten_s (default 120 s) until Kevin decided or closed the dialog and returns what is released, rejected "
          "and still open. grund: one short sentence why the parts are needed.", ADDITIVE)
    async def freigabe_anfragen(
        ids: Annotated[list[str], Field(min_length=1, description="ids of the proposals to release")],
        grund: Annotated[str, Field(description="Why they are needed (shown to Kevin in the dialog)")] = "",
        warten_s: Annotated[float | None, Field(ge=0, le=900, description="Seconds to wait for Kevin (default 120)")]
        = None,
    ) -> CallToolResult:
        res = await t.work("fragt Kevin nach der Freigabe", svc.freigabe_anfragen, list(ids), grund, warten_s)
        err = fmt.service_error(res)
        if err:
            return fmt.error_result(f"Freigabe nicht angefragt: {err}", res)
        frei, ab, offen = res.get("freigegeben") or [], res.get("abgelehnt") or [], res.get("offen") or []
        lines: list[str] = []
        if res.get("dialog") == "nicht_noetig":
            lines.append("Nichts anzufragen: " + ", ".join(res.get("schon_frei") or []) + " ist schon freigegeben.")
            return fmt.result("\n".join(lines), res)
        lines.append(f"Freigabe {res.get('anfrage')}: Kevin hat "
                     + (f"freigegeben: {', '.join(frei)}" if frei else "noch nichts freigegeben") + ".")
        if ab:
            lines.append(f"Abgelehnt (aus dem Katalog entfernt): {', '.join(ab)}.")
        if offen:
            wie = ("Kevin hat den Dialog geschlossen" if res.get("dialog") == "geschlossen"
                   else f"der Dialog ist nach {fmt.num(res.get('gewartet_s'), 0)} s noch offen")
            lines.append(f"Offen: {', '.join(offen)} ({wie}). Nicht verbauen, bis Kevin freigibt; später erneut "
                         "freigabe_anfragen oder stock_get.")
        if res.get("schon_frei"):
            lines.append(f"Schon vorher frei: {', '.join(res['schon_frei'])}.")
        if frei:
            lines.append("Freigegebene Einträge sind sofort verbaubar; jetzt run.")
        return fmt.result("\n".join(lines), res)

    @tool("bom", "Stückliste",
          "Bill of materials of the last run: positions (same stock, length and miter merged), weight, prices "
          "(guide prices with date), cut list per bar stock (first fit decreasing, 3 mm saw kerf, waste %), totals "
          "and hints (e.g. parts not linked to a stock line). format 'csv' returns the CSV text; export(['bom_csv']) "
          "writes the file.", READ_ONLY)
    async def bom(
        format: Annotated[Literal["text", "csv"], Field(description="text = table, csv = CSV for Numbers/Excel")]
        = "text",
    ) -> CallToolResult:
        res = await t.work("liest die Stückliste", svc.bom)
        err = fmt.service_error(res)
        if err:
            return fmt.error_result(err, res)
        if format == "csv":
            from kevcad_kernel.bom import to_csv

            return fmt.result(to_csv(res), res, json_block=False)
        return fmt.result(fmt.bom_text(res), res)

    from .bestand_tools import register_bestand_tools  # Bestand je Projekt (BESTAND.md)

    register_bestand_tools(tool, t, svc)
    # ------------------------------------------------------------------------------------- Zukaufteile (Phase 3)

    from .zukauf_tools import register_zukauf_tools

    register_zukauf_tools(tool, t, svc)

    # ------------------------------------------------------------------------------------------- Zwangsbedingungen

    @tool("bedingungen", "Bedingungen",
          "Constraints of the last run (kevcad.bedingungen in model.py): every constraint with state (erfüllt / "
          "verletzt / nicht geprüft), target and actual value, model.py line and a concrete fix; degrees of freedom "
          "per part (free motions, joints), fastening per part (B9: verbinde, contact, connected to the floor), "
          "range of motion of every joint with a range (B8: blocking part, free range) and all findings in the "
          "shared format of the checks. Without arguments: summary, violated constraints and findings; part: only "
          "this part (or assembly prefix) with all its constraints; alle=true lists every constraint.", READ_ONLY)
    async def bedingungen(
        part: Annotated[str | None, Field(description="Part name or assembly prefix, e.g. 'Rollwagen/Rahmen'")] = None,
        alle: Annotated[bool, Field(description="List every constraint, also the satisfied ones")] = False,
    ) -> CallToolResult:
        res = await t.work("prüft die Bedingungen", svc.constraints, part)
        err = fmt.service_error(res)
        if err:
            return fmt.error_result(err, res)
        from kevcad_kernel.bedingungen.bericht import bericht_text, fehler_anzahl

        data = {k: v for k, v in res.items() if k != "ok"}
        return fmt.result(bericht_text(res, teil=part, alle=alle), data, error=fehler_anzahl(res) > 0)

    # Phase 5: Animation (eigene Datei, damit parallele Stränge nicht in dieselben Zeilen schreiben)
    from .animation_tools import register_animation_tools

    register_animation_tools(tool, t, svc)

    # Phase 5: Kameras (kamera_tools.py)
    from .kamera_tools import register_camera_tools

    register_camera_tools(t, svc, tool, {"read_only": READ_ONLY, "viewer": VIEWER, "additive": ADDITIVE})

    # 3D-Druck: Ergebnis der Druckprüfung (druck_tools.py)
    from .druck_tools import register_druck_tools

    register_druck_tools(t, svc, tool, {"read_only": READ_ONLY})

    # Phase 8: Drucken auf dem P1P (drucker_tools.py)
    from .drucker_tools import register_drucker_tools

    register_drucker_tools(t, svc, tool, {"read_only": READ_ONLY})
    # SK-CAD: STL laden und über OctoPrint drucken (stl_octoprint_tools.py)
    from .stl_octoprint_tools import register_stl_octoprint_tools

    register_stl_octoprint_tools(t, svc, tool, {"read_only": READ_ONLY})
    # Druckvorschau: Filament, Zeit, Platten, Kosten, Empfehlungen, 3MF (druckvorschau_tools.py, DRUCKVORSCHAU.md)
    from .druckvorschau_tools import register_druckvorschau_tools

    register_druckvorschau_tools(t, svc, tool, {"read_only": READ_ONLY, "additive": ADDITIVE})

    # Versionen, Meilensteine, Varianten (versionen_tools.py)
    from .versionen_tools import register_versionen_tools

    register_versionen_tools(tool, t, svc)

    # Prüfung: pruefen, montage_reihenfolge, ansichten (eigene Datei)
    from .pruef_tools import register_pruef_tools

    register_pruef_tools(t, svc, tool)

    # Phase 6: Bauplan (bauplan_tools.py)
    from .bauplan_tools import register_bauplan_tools

    register_bauplan_tools(tool, t, svc)

    # Phase 6: Zeichnungen (zeichnung_tools.py)
    from .zeichnung_tools import register_zeichnung_tools

    register_zeichnung_tools(t, svc, tool, {"read_only": READ_ONLY, "additive": ADDITIVE, "writes": WRITES})

    # Phase 6: Dokumente exportieren (dokument_tools.py, P6-A2)
    from .dokument_tools import register_dokument_tools

    register_dokument_tools(tool, t, svc)

    # Phase 4: Foto und Video als Referenz (referenz_tools.py)
    from .referenz_tools import register_referenz_tools

    register_referenz_tools(tool, t, svc)
    # Scan mit dem iPhone (scan_tools.py, SCAN.md, PLAN-SCAN.md)
    from .scan_tools import register_scan_tools

    register_scan_tools(tool, t, svc)
    # Statik Stufe 1: statik, szenario_rechnen (statik_tools.py, PLAN-STATIK.md)
    from .statik_tools import register_statik_tools

    register_statik_tools(t, svc, tool, {"read_only": READ_ONLY, "additive": ADDITIVE})
    # Topologieoptimierung (topologie_tools.py, PLAN-TOPOLOGIE.md)
    from .topologie_tools import register_topologie_tools

    register_topologie_tools(t, svc, tool, {"read_only": READ_ONLY, "additive": ADDITIVE})
    # Bereich „Simulation“: Lastfälle der App lesen, ändern, rechnen (simulation_tools.py, PLAN-SIMULATION.md)
    from .simulation_tools import register_simulation_tools

    register_simulation_tools(t, svc, tool, {"read_only": READ_ONLY, "additive": ADDITIVE})
    # Phase 7: Renderings (render_tools.py, PLAN-PHASE7-RENDERINGS.md)
    from .render_tools import register_render_tools

    register_render_tools(tool, t, svc)

    return t
