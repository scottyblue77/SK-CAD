"""MCP-Werkzeuge für STL-Import und OctoPrint (SK-CAD): stl_laden, stl_liste, octoprint_status,
octoprint_einrichten, octoprint_drucken, octoprint_starten.

Eigene Datei wie drucker_tools.py. Beschreibungen englisch (für das Modell), Ergebnisse deutsch. Gedruckt wird nur,
wenn der Nutzer es ausdrücklich verlangt; sonst wird nur geslict, hochgeladen und ausgewählt.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Annotated, Any

from mcp_types import CallToolResult, ToolAnnotations
from pydantic import Field

from . import format as fmt

STL_OCTOPRINT_TOOL_NAMES: tuple[str, ...] = ("stl_laden", "stl_liste", "octoprint_status", "octoprint_einrichten",
                                             "octoprint_drucken", "octoprint_starten")

WRITES = ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=False, open_world_hint=False)
PHYSICAL = ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=False, open_world_hint=True)


def _dauer(s: Any) -> str:
    if not isinstance(s, (int, float)):
        return "–"
    s = int(s)
    return f"{s // 3600} h {s % 3600 // 60:02d} min" if s >= 3600 else f"{s // 60} min"


def register_stl_octoprint_tools(t: Any, svc: Any, tool: Callable[..., Any], annotations: dict[str, Any]) -> None:
    @tool("stl_laden", "STL laden",
          "Load an STL file (binary or ASCII, mm) into the open project: copies it to <project>/stl/<name>.stl and "
          "shows it in the viewer as a semi-transparent reference (art 'stl', placed on the bed: XY centred, bottom at "
          "z = 0 unless auf_bett=false). Returns size, triangles, volume and whether the mesh is closed. The STL is "
          "display/print only, not editable CAD geometry; use it with octoprint_drucken or as a reference for "
          "referenz_abweichung. Needs an open project (project_open / project_new).", WRITES)
    async def stl_laden(
        pfad: Annotated[str, Field(description="Path of the .stl file (absolute or ~/...)")],
        name: Annotated[str | None, Field(description="Name in the project (default: file name)")] = None,
        auf_bett: Annotated[bool, Field(description="Place on the bed (XY centred, bottom at z=0)")] = True,
    ) -> CallToolResult:
        res = await t.work("lädt eine STL", svc.stl_laden, pfad, name, auf_bett)
        err = fmt.service_error(res)
        if err:
            return fmt.error_result(f"STL laden: {err}", res)
        m = res.get("masz_mm") or [0, 0, 0]
        text = (f"STL „{res.get('name')}“ geladen: {m[0]} × {m[1]} × {m[2]} mm, {res.get('dreiecke')} Dreiecke, "
                f"{res.get('volumen_cm3')} cm³, {'dicht' if res.get('dicht') else 'nicht dicht'}.")
        for h in res.get("hinweise") or []:
            text += f"\nHinweis: {h}"
        return fmt.result(text, {k: v for k, v in res.items() if k != "ok"})

    @tool("stl_liste", "STL-Dateien im Projekt",
          "List the STL files loaded into the open project with size, triangles, volume and closed/open.",
          annotations["read_only"])
    async def stl_liste() -> CallToolResult:
        res = await t.work("listet STL-Dateien", svc.stl_liste)
        err = fmt.service_error(res)
        if err:
            return fmt.error_result(f"STL-Liste: {err}", res)
        zeilen = [f"- {s['name']}: {' × '.join(str(v) for v in s.get('masz_mm') or [])} mm, "
                  f"{s.get('volumen_cm3')} cm³" for s in res.get("stl") or []]
        return fmt.result("\n".join(zeilen) or "Keine STL im Projekt.", {"stl": res.get("stl")})

    @tool("octoprint_status", "OctoPrint-Status",
          "Read-only status of the OctoPrint server (OctoPi in the LAN, default http://192.168.1.233): server "
          "version, printer connection and state, nozzle/bed temperatures, current job with progress and time left, "
          "plus the settings (URL, slicer, slicer profile). Sends nothing to the printer. Never contains the API key.",
          annotations["read_only"])
    async def octoprint_status() -> CallToolResult:
        res = await t.work("liest den OctoPrint-Status", svc.octoprint_status)
        err = fmt.service_error(res)
        if err:
            return fmt.error_result(f"OctoPrint: {err}", res)
        d = res.get("drucker") or {}
        a = res.get("auftrag") or {}
        if not d.get("verbunden"):
            zeile = "Drucker: nicht mit OctoPrint verbunden."
        else:
            du, be = d.get("duese") or {}, d.get("bett") or {}
            zeile = (f"Drucker: {d.get('zustand')}, Düse {du.get('ist')}/{du.get('soll')} °C, "
                     f"Bett {be.get('ist')}/{be.get('soll')} °C.")
        if a.get("datei"):
            zeile += (f"\nAuftrag: {a.get('datei')} – {a.get('zustand')}, {a.get('fortschritt_prozent')} %, "
                      f"Rest {_dauer(a.get('rest_s'))}.")
        return fmt.result(f"OctoPrint {res.get('octoprint')} erreichbar.\n{zeile}",
                          {k: v for k, v in res.items() if k != "ok"})

    @tool("octoprint_einrichten", "OctoPrint einrichten",
          "Set or check the OctoPrint settings: url (OctoPi address), slicer (path to PrusaSlicer/SuperSlicer), "
          "profil (a PrusaSlicer config .ini exported with printer, filament and print settings). Omitted values stay. "
          "The API key is never passed here: it lives in the macOS keychain and the user enters it himself (the "
          "result says how).", WRITES)
    async def octoprint_einrichten(
        url: Annotated[str | None, Field(description="OctoPrint URL, e.g. http://192.168.1.233")] = None,
        slicer: Annotated[str | None, Field(description="Path to the PrusaSlicer executable")] = None,
        profil: Annotated[str | None, Field(description="Path to the exported PrusaSlicer .ini")] = None,
    ) -> CallToolResult:
        res = await t.work("richtet OctoPrint ein", svc.octoprint_einrichten, url, slicer, profil)
        err = fmt.service_error(res)
        if err:
            return fmt.error_result(f"OctoPrint einrichten: {err}", res)
        e = res.get("einstellungen") or {}
        text = (f"OctoPrint: {e.get('url')}, Profil: {e.get('profil') or 'fehlt'}, Slicer: "
                f"{res.get('slicer_gefunden') or 'nicht gefunden'}, API-Schlüssel: "
                f"{'vorhanden' if res.get('schluessel_da') else 'fehlt'}.")
        for h in res.get("hinweise") or []:
            text += f"\nHinweis: {h}"
        return fmt.result(text, {k: v for k, v in res.items() if k != "ok"})

    @tool("octoprint_drucken", "An OctoPrint senden",
          "Send a print to the OctoPrint printer. datei: name of an STL from stl_liste, a project-relative path, or an "
          "absolute path to an .stl or ready .gcode. An STL is sliced with PrusaSlicer and the configured profile "
          "into <project>/output/<name>.gcode (print time and filament in the result), then uploaded to OctoPrint "
          "(folder sk-cad) and selected. starten=false (default): NOTHING is printed. starten=true starts the print "
          "immediately and is ONLY allowed when the user explicitly asks to print now in this conversation "
          "(e.g. 'druck das jetzt'); never on your own initiative, never to test. Check octoprint_status first.",
          PHYSICAL)
    async def octoprint_drucken(
        datei: Annotated[str, Field(description="STL name from stl_liste, or path to .stl / .gcode")],
        starten: Annotated[bool, Field(description="Start printing now (only on explicit user request)")] = False,
        profil: Annotated[str | None, Field(description="Other PrusaSlicer .ini for this print only")] = None,
    ) -> CallToolResult:
        taetigkeit = "startet einen Druck" if starten else "slict und lädt auf OctoPrint"
        res = await t.work(taetigkeit, svc.octoprint_drucken, datei, starten, profil)
        err = fmt.service_error(res)
        if err:
            return fmt.error_result(f"OctoPrint: {err}", res)
        text = res.get("meldung") or ""
        if res.get("druckzeit") or res.get("filament_g"):
            text += f" Druckzeit {res.get('druckzeit') or '–'}, Filament {res.get('filament_g') or '–'} g."
        text += f" Datei auf OctoPrint: {res.get('octoprint_datei')}."
        return fmt.result(text, {k: v for k, v in res.items() if k != "ok"})

    @tool("octoprint_starten", "Druck starten",
          "Start printing a file that is already on OctoPrint (octoprint_datei from octoprint_drucken). ONLY when the "
          "user explicitly asks to start the print now; never on your own initiative. Refuses if the printer is "
          "disconnected or busy.", PHYSICAL)
    async def octoprint_starten(
        octoprint_datei: Annotated[str, Field(description="Path on OctoPrint, e.g. sk-cad/teil-20261030-2100.gcode")],
    ) -> CallToolResult:
        res = await t.work("startet einen Druck", svc.octoprint_starten, octoprint_datei)
        err = fmt.service_error(res)
        if err:
            return fmt.error_result(f"Druck starten: {err}", res)
        return fmt.result(res.get("meldung") or "Gestartet.", {k: v for k, v in res.items() if k != "ok"})
