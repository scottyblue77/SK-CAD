"""Scans in der Kernel-Laufzeit: Empfänger starten, ``scans``, ``scan_importieren``.

``ScanRuntimeMixin`` gehört zu ``KernelRuntime`` (runtime.py) und nutzt dort ``socket_path``, ``_project``, ``_log``
und die Referenz-Läufe aus ``ReferenzRuntimeMixin`` (Fortschritt in REF_LIST, REF_UPSERT mit dem Netz, REF_PHOTOS).

- Empfänger: läuft, solange der Kernel läuft, wenn der Kernel zu einer App-Variante gehört (Socket in
  ``…/de.upvis.kevcad…/``) oder ``KEVCAD_SCAN_EMPFANG=1``; ``KEVCAD_SCAN_EMPFANG=0`` schaltet ihn ab. Kevins App meldet
  sich als ``_kevscan._tcp`` mit dem Rechnernamen an, Testvarianten als ``_kevscan-test._tcp`` mit eigenem Namen.
- Mitteilung „Scan empfangen“: Logzeile des Kernels und eine macOS-Mitteilung (nur Kevins App, nicht in Tests und
  Testvarianten; ``KEVCAD_SCAN_MITTEILUNG=0`` schaltet sie ab).
- ``scan_importieren``: ``kevscan auswerten`` als eigener Prozess nach ``<projekt>/referenzen/<name>/capture/``;
  danach ist der Scan eine Referenz wie ein Object-Capture-Video (Netz im Viewer, Fotoansicht, ``referenz_vermessen``).
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import threading
import time
from pathlib import Path
from typing import Any

from kevcad_kernel.referenz import ablage as ref_ablage
from kevcad_kernel.referenz import vermessen as ref_vermessen
from kevcad_kernel.scan import ablage
from kevcad_kernel.scan.ablage import ScanFehler

ZEITLIMIT_S = 3600


class ScanRuntimeMixin:
    def _scan_init(self) -> None:
        self._scan_empfaenger = None
        self._scan_variante = ablage.variante(getattr(self, "socket_path", None))
        self._scan_basis = ablage.scans_ordner(getattr(self, "socket_path", None))
        self._scan_prozesse: dict[tuple[str, str], subprocess.Popen] = {}
        if self._scan_empfang_gewuenscht():
            try:
                self._scan_starten()
            except Exception as exc:  # noqa: BLE001 - ohne Empfänger läuft Kev CAD trotzdem
                self._log(f"[scan] Empfänger startet nicht: {exc!r}")

    def _scan_empfang_gewuenscht(self) -> bool:
        env = os.environ.get("KEVCAD_SCAN_EMPFANG")
        if env is not None:
            return env.strip().lower() not in ("0", "nein", "false", "aus", "")
        return self._scan_variante is not None

    def _scan_starten(self) -> None:
        from kevcad_kernel.scan.empfang import DIENST, DIENST_TEST, Empfaenger, rechnername

        test = ablage.ist_testvariante(self._scan_variante)
        name = rechnername() + (f" ({ablage.anzeigename(self._scan_variante)})" if test else "")
        port = int(os.environ.get("KEVCAD_SCAN_PORT") or 0)
        e = Empfaenger(self._scan_basis, port=port, name=name, dienst=DIENST_TEST if test else DIENST,
                       txt={"variante": "test" if test else "kevcad"},
                       bonjour=os.environ.get("KEVCAD_SCAN_BONJOUR", "1") != "0",
                       projekt=lambda: self._project.name if self._project is not None else None,
                       bei_empfang=self._scan_empfangen, log=self._log)
        e.start()
        self._scan_empfaenger = e

    def _scan_schliessen(self) -> None:
        e = self._scan_empfaenger
        self._scan_empfaenger = None
        if e is not None:
            try:
                e.stop()
            except Exception as exc:  # noqa: BLE001
                self._log(f"[scan] Empfänger beenden: {exc!r}")
        for proc in list(self._scan_prozesse.values()):
            if proc.poll() is None:
                proc.terminate()

    def _scan_empfangen(self, eintrag: dict[str, Any]) -> None:
        text = (f"{eintrag.get('name')}: {eintrag.get('fotos', 0)} Fotos, {eintrag.get('videobilder', 0)} Videobilder"
                f", {eintrag.get('groesse_mb', 0)} MB")
        self._log(f"[scan] Scan empfangen: {text} ({eintrag.get('ordner')})")
        self._scan_liste_senden(neu=eintrag.get("id"))  # App: Band „Neuer Scan empfangen“
        if self._scan_variante == ablage.PRODUKTION and os.environ.get("KEVCAD_SCAN_MITTEILUNG", "1") != "0":
            skript = f'display notification "{_as(text)}" with title "SK-CAD" subtitle "Scan empfangen"'
            try:
                subprocess.run(["osascript", "-e", skript], capture_output=True, timeout=10)
            except (OSError, subprocess.SubprocessError) as exc:
                self._log(f"[scan] Mitteilung: {exc!r}")

    # =================================================================================================================
    # KernelService
    # =================================================================================================================

    def scans(self) -> dict[str, Any]:
        e = self._scan_empfaenger
        empf = {"laeuft": e is not None, "port": e.port if e else None, "name": e.name if e else None,
                "dienst": e.dienst if e else None, "empfangen": e.empfangen if e else 0}
        return {"ok": True, "ordner": str(self._scan_basis), "scans": ablage.liste(self._scan_basis),
                "empfaenger": empf, "kevscan": str(ablage.kevscan_ordner() or "") or None}

    def scan_importieren(self, scan: str | None = None, name: str | None = None, schnell: bool = False,
                         warten_s: float = 0.0) -> dict[str, Any]:
        """Scan auswerten (eigener Prozess) und als Referenz ``<projekt>/referenzen/<name>/`` anlegen."""
        proj = self._project
        if proj is None:
            return {"ok": False, "error": "Kein Projekt offen. Erst project_open oder project_new aufrufen."}
        try:
            ordner = ablage.finde(self._scan_basis, scan)
        except ScanFehler as exc:
            return {"ok": False, "error": str(exc)}
        kern = ablage.finde_wurzel(ordner)
        if kern is None:
            return {"ok": False, "error": f"{ordner} ist kein Scan (meta.json fehlt)"}
        ks = ablage.kevscan_ordner()
        if ks is None:
            return {"ok": False, "error": "Die Auswertung fehlt (Umgebung scan/): im Repo `cd scan && uv sync`, "
                                          "installiert legt ./build.sh sie unter install/scan an."}
        eintrag = ablage.eintrag(ordner) or {}
        n = self._scan_ref_name(proj.path, kern, name or eintrag.get("name") or ordner.name, bool(name))
        schluessel = (str(proj.path), n)
        with self._ref_lock:
            laeuft = self._ref_laeufe.get(schluessel)
        if laeuft is not None:
            return {"ok": False, "error": f"Für die Referenz {n} läuft schon {laeuft['art']}; erst abwarten "
                                          "(referenzen(name, warten_s=…))."}
        ref = ref_ablage.ordner(proj.path, n)
        aus = ref / ref_ablage.CAPTURE
        meta = ref_ablage.lese_meta(proj.path, n) or {"art": "scan", "quelle": str(kern), "erstellt": ref_ablage.jetzt()}
        meta.update(art="scan", quelle=str(kern))
        einstellung = "schnell" if schnell else "genau"
        meta["capture"] = {"einstellung": einstellung, "zustand": "rechnet", "gestartet": ref_ablage.jetzt(),
                           "verfahren": "kevscan"}
        meta["scan"] = {"id": ordner.name, "ordner": str(kern), "schnell": bool(schnell), "geraet": eintrag.get("geraet"),
                        "fotos": eintrag.get("fotos"), "videobilder": eintrag.get("videobilder")}
        meta.pop("lage", None)
        ref_ablage.schreibe_meta(proj.path, n, meta)
        shutil.rmtree(aus, ignore_errors=True)
        cmd = [str(ks / ".venv" / "bin" / "python"), "-m", "kevscan", "auswerten", str(kern), "--aus", str(aus)]
        if schnell:
            cmd.append("--schnell")
        lauf = self._ref_lauf_beginnen(schluessel, "capture", "Scan auswerten")
        self._ref_netz_entfernen(n)
        threading.Thread(target=self._scan_lauf, args=(proj.path, n, ordner, cmd, ks, schnell, lauf),
                         name=f"kevscan-{n}", daemon=True).start()
        out: dict[str, Any] = {"ok": True, "name": n, "ordner": str(ref), "scan": ordner.name, "zustand": "rechnet",
                               "einstellung": einstellung, "befehl": " ".join(cmd)}
        if warten_s and warten_s > 0:
            r = self.referenzen(n, warten_s=warten_s)
            if r.get("ok") and r.get("referenzen"):
                out["referenz"] = r["referenzen"][0]
                out["zustand"] = r["referenzen"][0]["zustand"]
            bericht = aus / "bericht.json"
            if bericht.is_file():
                try:
                    out["bericht"] = _kurzbericht(json.loads(bericht.read_text(encoding="utf-8")))
                except (OSError, ValueError):
                    pass
        return out

    # =================================================================================================================
    # Auswertung
    # =================================================================================================================

    def _scan_ref_name(self, projekt: Path, kern: Path, wunsch: str, ausdruecklich: bool = False) -> str:
        """Ohne ausdrücklichen Namen die Referenz desselben Scans wiederverwenden; mit Namen genau diese Referenz
        (neu, oder dieselbe, wenn sie schon zu diesem Scan gehört). Sonst ein freier Name."""

        def gehoert(n: str) -> bool:
            m = ref_ablage.lese_meta(projekt, n) or {}
            return m.get("art") == "scan" and str(m.get("quelle")) == str(kern)

        if ausdruecklich:
            n = ref_ablage.sicherer_name(wunsch)
            return n if not ref_ablage.ordner(projekt, n).exists() or gehoert(n) else \
                ref_ablage.freier_name(projekt, wunsch)
        for n in ref_ablage.namen(projekt):
            if gehoert(n):
                return n
        return ref_ablage.freier_name(projekt, wunsch)

    def _scan_lauf(self, projekt: Path, n: str, ordner: Path, cmd: list[str], ks: Path, schnell: bool,
                   lauf: dict[str, Any]) -> None:
        schluessel = (str(projekt), n)
        t0 = time.monotonic()
        ref_vermessen.warte_auf_speicher(lambda a, t: self._ref_fortschritt(schluessel, 0.0, t), 0.0)
        env = {k: v for k, v in os.environ.items() if not k.startswith(("VIRTUAL_ENV", "PYTHONPATH", "PYTHONHOME"))}
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + env.get("PATH", "/usr/bin:/bin")  # ffmpeg
        env.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
        ergebnis: dict[str, Any] = {}
        fehler = None
        stderr: list[str] = []
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1,
                                    env=env, cwd=str(ks))
            self._scan_prozesse[schluessel] = proc

            def lies_err() -> None:
                assert proc.stderr is not None
                for z in proc.stderr:
                    stderr.append(z.rstrip())
                    del stderr[:-40]

            threading.Thread(target=lies_err, daemon=True).start()
            tot = threading.Timer(ZEITLIMIT_S, proc.kill)
            tot.start()
            assert proc.stdout is not None
            for z in proc.stdout:
                z = z.strip()
                if not z.startswith("{"):
                    continue
                try:
                    e = json.loads(z)
                except json.JSONDecodeError:
                    continue
                art = e.get("event")
                if art == "progress":
                    from kevcad_kernel.referenz.laufzeit_rest import SCAN_PHASEN

                    with self._ref_lock:
                        lauf["phase"] = SCAN_PHASEN.get(str(e.get("phase") or ""), e.get("phase"))
                    self._ref_fortschritt(schluessel, float(e.get("gesamt") or 0), "Scan: " + str(e.get("text") or ""))
                elif art == "done":
                    ergebnis = e
                elif art == "error":
                    fehler = str(e.get("message") or "Fehler")
            code = proc.wait()
            tot.cancel()
            if code != 0 and fehler is None:
                fehler = f"kevscan endete mit Code {code}" + (f": {stderr[-1]}" if stderr else "")
        except OSError as exc:
            fehler = f"kevscan startet nicht: {exc}"
        finally:
            self._scan_prozesse.pop(schluessel, None)
        self._scan_fertig(projekt, n, ordner, ergebnis, fehler, round(time.monotonic() - t0, 1), schnell, stderr)
        with self._ref_lock:
            aktuell = self._ref_laeufe.get(schluessel)
        if aktuell is lauf:
            self._ref_lauf_beenden(schluessel, lauf)
        if fehler is None and self._project is not None and self._project.path == projekt:
            self._ref_netz_senden(projekt, n)
            self._ref_capture_fotos_senden(projekt, n)
        if fehler is None:
            self._ref_abw_planen()
        self._scan_liste_senden()  # der Scan ist jetzt übernommen

    def _scan_fertig(self, projekt: Path, n: str, ordner: Path, ergebnis: dict[str, Any], fehler: str | None,
                     dauer: float, schnell: bool, stderr: list[str]) -> None:
        schluessel = (str(projekt), n)
        meta = ref_ablage.lese_meta(projekt, n) or {"art": "scan"}
        cap = dict(meta.get("capture") or {})
        if fehler is None:
            bericht_datei = ref_ablage.ordner(projekt, n) / ref_ablage.CAPTURE / "bericht.json"
            try:
                b = json.loads(bericht_datei.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                b = {}
            hu = b.get("huellmass_mm") or {}
            gr = b.get("grundriss_mm") or {}
            cap.update(zustand="fertig", dauer_s=dauer, fertig=ref_ablage.jetzt(),
                       bilder=(b.get("bilder") or {}).get("gesamt"), ausgerichtet=(b.get("bilder") or {}).get("gesamt"),
                       huelle=hu or None, grundkoerper={"laenge": gr.get("laenge"), "breite": gr.get("breite")}
                       if gr else None, oberkante=b.get("oberkante_mm"), massstab_bekannt=True,
                       warnungen=b.get("warnungen") or [], tiefe=b.get("tiefe"), genauigkeit=b.get("genauigkeit"),
                       zeiten=b.get("zeiten"), voxel_mm=b.get("voxel_mm"))
            self._ref_fehler.pop(schluessel, None)
            # Status nur in Scans der eigenen Ablage; ein Ordner, den scan_importieren als Pfad bekam, bleibt unberührt
            if ordner.resolve().parent == self._scan_basis.resolve():
                try:
                    ablage.referenz_merken(ordner, projekt, n, schnell)
                except OSError as exc:
                    self._log(f"[scan] Status in {ordner}: {exc!r}")
            self._log(f"[scan] {n}: ausgewertet in {dauer:.0f} s ({cap.get('bilder')} Bilder, Hülle {hu})")
        else:
            cap.update(zustand="fehler", fehler=fehler, dauer_s=dauer)
            self._ref_fehler[schluessel] = f"Scan: {fehler}"
            self._log(f"[scan] Auswertung {n}: {fehler}\n" + "\n".join(stderr[-8:]))
        meta["capture"] = cap
        ref_ablage.schreibe_meta(projekt, n, meta)


def _kurzbericht(b: dict[str, Any]) -> dict[str, Any]:
    return {k: b.get(k) for k in ("bilder", "huellmass_mm", "grundriss_mm", "voxel_mm", "tiefe", "genauigkeit",
                                  "abdeckung", "zeiten", "warnungen")}


def _as(text: str) -> str:
    """Text für AppleScript in Anführungszeichen."""
    return str(text).replace("\\", "\\\\").replace('"', "'")
