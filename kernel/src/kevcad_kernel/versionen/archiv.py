"""Versionsarchiv eines Projekts: Versionen, Meilensteine, Wiederherstellen, Varianten, Aufräumen, Übernahme
(PLAN-VERSIONEN.md, V1–V10). Kennt nur Dateien und Git, nicht die Laufzeit; die Laufzeit (laufzeit.py) ruft es auf.

```
<Projekt>/.kevcad/
├── git/                   eigenes Repo (GIT_DIR), Arbeitskopie = Projektordner
└── versionen/
    ├── index.json         Kennzahlen, Prüfstand, Meilensteine, Vorschaubilder, Varianten (je Versionsnummer)
    ├── daten/<nr>.json    Teile, Stückliste, Parameter eines Stands (für den Vergleich), siehe schnappschuss.py
    ├── geometrie/         Netze je Formschlüssel (für Geisterkörper), siehe schnappschuss.py
    └── bilder/<nr>.png    Vorschaubild
```

Jede Version ist ein Commit. Die Nachricht trägt die unveränderlichen Angaben als Zeilen am Ende
(``Kevcad-Nr``, ``Kevcad-Wer``, ``Kevcad-Sitzung``, ``Kevcad-Quelle``, ``Kevcad-Zweig``, ``Kevcad-Aus``, ``Kevcad-Lauf``);
die Nummer ist projektweit eindeutig und bleibt auch beim Aufräumen gleich. Varianten sind Zweige, der Hauptstand
heißt ``haupt``.

Titel (PLAN-VERSIONEN.md, „Titel“): Die erste Zeile der Commit-Nachricht ist nur der Grundtitel beim Anlegen
(„Übernommener Stand“, „Geändert: model.py“, „Gesichert vor …“) und wird nie umgeschrieben. Was die Leiste zeigt,
steht in ``index.json`` je Version: ``titel_auto`` (aus dem Vergleich mit der Vorgängerversion, titel.py, mit
``titel_regel``, ``titel_basis``, ``titel_gegen``), ``titel_agent`` (``run(titel=…)``) und der Meilenstein (Kevin oder
Agent). Vorrang in ``version_dict``: Agent vor Automatik vor Grundtitel; den Meilenstein zeigt die App darüber.
Kevins Meilensteine überschreibt nur Kevin selbst (oder der Agent auf Kevins ausdrücklichen Wunsch, ``ersetzen``).
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import threading
import time
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from kevcad_kernel.versionen.dokumente import ist_dokument, vergleiche_dokumente
from kevcad_kernel.versionen.git import HAUPT, GitFehler, GitRepo, git_verfuegbar
from kevcad_kernel.versionen.titel import REGEL as TITEL_REGEL
from kevcad_kernel.versionen.titel import auto_titel, dateien_titel

HAUPT_NAME = "Hauptstand"
AUTOMATISCH = ("lauf", "uebernahme", "sicherung")  # werden nach 30 Tagen ausgedünnt
DICHT_ABSTAND_S = 5 * 60  # Versionen mit höchstens diesem Abstand bilden eine Folge
DICHT_MIN = 3  # ab so vielen Versionen fasst die Leiste eine Folge zusammen
# SK-CAD: Anzeigename des Nutzers für Einträge mit wer="kevin" (Kennung bleibt wegen Kompatibilität mit Kev CAD).
NUTZER = os.environ.get("KEVCAD_NUTZER", "").strip() or "Sebastian"
WER_TEXT = {"kevin": NUTZER, "agent": "Agent", "kevcad": "SK-CAD", "unbekannt": "Auto-Lauf"}
QUELLE_TEXT = {"lauf": "Lauf", "wiederherstellen": "Wiederhergestellt", "sicherung": "Sicherung",
               "uebernahme": "Vorgeschichte", "meilenstein": "Meilenstein", "variante": "Variante"}
_TRAILER = re.compile(r"^Kevcad-([A-Za-z]+):\s?(.*)$")
UEBERNOMMEN = "Übernommener Stand"
MAX_TEXT_BYTES = 2_000_000  # größere Dateien vergleicht der Titel nur nach Namen
DOKUMENTE = "dokumente"  # Blätter und Bauplan (DOKUMENTE.md): im Vergleich eine eigene Gruppe, nicht Code
OHNE_DOKUMENTE = (".", f":(exclude){DOKUMENTE}")


class VersionsFehler(ValueError):
    """Bedienfehler (unbekannte Version, Variante gibt es schon …); Text geht an Kevin und den Agenten."""


class KevinsMeilenstein(VersionsFehler):
    """Die Version trägt einen Meilenstein, den Kevin vergeben hat; nur Kevin ändert ihn (oder der Agent mit
    ``ersetzen`` auf Kevins Wunsch)."""

    def __init__(self, version: "Version", meilenstein: dict[str, Any]) -> None:
        super().__init__(f"V{version.nr} trägt Kevins Meilenstein „{meilenstein.get('titel', '')}“; er bleibt.")
        self.version = version
        self.meilenstein = meilenstein


@dataclass
class Version:
    nr: int
    commit: str
    ts: int
    wer: str = "unbekannt"
    sitzung: str | None = None
    quelle: str = "lauf"
    titel: str = ""
    zweig: str = HAUPT
    aus: int | None = None
    lauf: int | None = None
    dateien: list[str] = field(default_factory=list)
    eltern: str | None = None

    @property
    def wer_text(self) -> str:
        text = WER_TEXT.get(self.wer, self.wer)
        if self.wer == "agent" and self.sitzung:
            text += f" · {self.sitzung[:6]}"
        return text


def nachricht(titel: str, **felder: Any) -> str:
    zeilen = [titel.strip() or "Version", ""]
    for k, v in felder.items():
        if v is None or v == "":
            continue
        zeilen.append(f"Kevcad-{k.capitalize()}: {v}")
    return "\n".join(zeilen) + "\n"


def lies_nachricht(text: str) -> tuple[str, dict[str, str]]:
    zeilen = text.strip("\n").splitlines()
    titel = zeilen[0].strip() if zeilen else ""
    felder = {}
    for z in zeilen[1:]:
        m = _TRAILER.match(z.strip())
        if m:
            felder[m.group(1).lower()] = m.group(2).strip()
    return titel, felder


def version_aus_log(eintrag: dict[str, Any]) -> Version | None:
    titel, f = lies_nachricht(eintrag["nachricht"])
    try:
        nr = int(f.get("nr", ""))
    except ValueError:
        return None

    def zahl(k: str) -> int | None:
        try:
            return int(f[k]) if f.get(k) else None
        except ValueError:
            return None

    return Version(nr=nr, commit=eintrag["commit"], ts=eintrag["ts"], wer=f.get("wer", "unbekannt"),
                   sitzung=f.get("sitzung") or None, quelle=f.get("quelle", "lauf"), titel=titel,
                   zweig=f.get("zweig", HAUPT), aus=zahl("aus"), lauf=zahl("lauf"),
                   dateien=list(eintrag.get("dateien") or []),
                   eltern=(eintrag.get("eltern") or [None])[0])


def zeit_text(ts: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(ts))


def slug(name: str) -> str:
    text = name.replace("ß", "ss").replace("ä", "ae").replace("ö", "oe").replace("ü", "ue")
    text = text.replace("Ä", "Ae").replace("Ö", "Oe").replace("Ü", "Ue")
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    text = re.sub(r"[^A-Za-z0-9]+", "-", text).strip("-").lower()
    return text[:40] or "variante"


def gruppiere(versionen: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Dichte Folgen automatischer Versionen (V2): mindestens ``DICHT_MIN`` hintereinander, je höchstens
    ``DICHT_ABSTAND_S`` auseinander, ohne Meilenstein. ``versionen`` neueste zuerst; setzt ``gruppe`` je Version und
    liefert die Gruppen. Die neueste Version bleibt immer einzeln."""
    gruppen: list[dict[str, Any]] = []
    folge: list[dict[str, Any]] = []

    def schliessen() -> None:
        if len(folge) >= DICHT_MIN:
            gid = f"g{folge[-1]['nr']}"
            von, bis = folge[-1]["ts"], folge[0]["ts"]
            minuten = max(1, round((bis - von) / 60))
            for v in folge:
                v["gruppe"] = gid
            gruppen.append({"id": gid, "anzahl": len(folge), "von": von, "bis": bis,
                            "neueste": folge[0]["nr"], "aelteste": folge[-1]["nr"],
                            "text": f"{len(folge)} Läufe in {minuten} {'Minute' if minuten == 1 else 'Minuten'}"})
        folge.clear()

    for i, v in enumerate(versionen):
        v.setdefault("gruppe", None)
        einzeln = i == 0 or v.get("meilenstein") or v.get("quelle") not in AUTOMATISCH or v.get("aktuell") \
            or v.get("geerbt")
        if einzeln:
            schliessen()
            continue
        if folge and folge[-1]["ts"] - v["ts"] > DICHT_ABSTAND_S:
            schliessen()
        folge.append(v)
    schliessen()
    return gruppen


class Versionsarchiv:
    """Versionen eines Projektordners. Threadsicher (eine Sperre für alle Git-Aufrufe)."""

    def __init__(self, projekt: str | Path, log=None) -> None:
        self.projekt = Path(projekt)
        self.git = GitRepo(self.projekt)
        self.ordner = self.projekt / ".kevcad" / "versionen"
        self.lock = threading.RLock()
        self._log = log or (lambda s: None)
        ok, meldung = git_verfuegbar()
        self.verfuegbar = ok
        self.meldung = meldung
        self.meta: dict[str, Any] = {"format": 1, "versionen": {}, "varianten": {}}
        self._naechste = 1
        self._liste_cache: dict[str, list[Version]] = {}

    # =================================================================================================================
    # Öffnen und Übernahme der alten Stände (V10)
    # =================================================================================================================

    def oeffnen(self) -> dict[str, Any]:
        """Repo anlegen, falls nötig, und alte Stände aus ``.kevcad/versions`` übernehmen. Rückgabe:
        {"neu": bool, "uebernommen": n}."""
        if not self.verfuegbar:
            return {"neu": False, "uebernommen": 0, "fehler": self.meldung}
        with self.lock:
            self._lade_meta()
            neu = not self.git.vorhanden
            uebernommen = 0
            if neu:
                self.git.init()
                uebernommen = self._uebernehmen()
                if uebernommen:
                    self.meta["uebernahme"] = {"zeit": int(time.time()), "anzahl": uebernommen}
                    self._speichere_meta()
            else:
                self.git.schreibe_ausschluss()  # Ausschlussliste aktuell halten (neue Einträge in neueren Versionen)
            self._naechste = self._hoechste_nr() + 1
            self._liste_cache.clear()
            return {"neu": neu, "uebernommen": uebernommen}

    def _uebernehmen(self) -> int:
        alt = self.projekt / ".kevcad" / "versions"
        dateien = sorted(alt.glob("[0-9][0-9][0-9][0-9]-model.py")) if alt.is_dir() else []
        if not dateien:
            return 0
        laeufe = self._laufprotokoll()
        # übrige Dateien des Projekts im heutigen Stand (die Geschichte kennt nur model.py)
        andere = [p for p in self.git.unversionierte() if p != "model.py"]
        pfade = [self.projekt / p for p in andere]
        shas = self.git.hash_objekte(pfade)
        strom = bytearray()
        vorher_ts = 0
        nr = 0
        for i, datei in enumerate(dateien):
            try:
                code = datei.read_bytes()
            except OSError:
                continue
            nr = int(datei.name[:4])
            h = hashlib.sha1(code).hexdigest()[:12]
            ts, quelle = None, None
            for zeit, ok, src, fh in laeufe:
                if ok and fh == h and zeit >= vorher_ts - 1:
                    ts, quelle = zeit, src
                    break
            if ts is None:
                try:
                    ts = int(datei.stat().st_mtime)
                except OSError:
                    ts = int(time.time())
            ts = max(ts, vorher_ts)
            vorher_ts = ts
            wer = {"agent": "agent", "app": "kevin"}.get(quelle or "", "unbekannt")
            text = nachricht(UEBERNOMMEN, nr=nr, wer=wer, quelle="uebernahme",
                             zweig=HAUPT).encode("utf-8")
            strom += f"commit refs/heads/{HAUPT}\nmark :{i + 1}\n".encode()
            strom += f"author Kev CAD <kevcad@localhost> {ts} +0000\n".encode()
            strom += f"committer Kev CAD <kevcad@localhost> {ts} +0000\n".encode()
            strom += f"data {len(text)}\n".encode() + text + b"\n"
            if i == 0:
                for rel, sha in zip(andere, shas):
                    modus = "100755" if os.access(self.projekt / rel, os.X_OK) else "100644"
                    strom += f"M {modus} {sha} {_fi_pfad(rel)}\n".encode()
            strom += b"M 100644 inline model.py\n" + f"data {len(code)}\n".encode() + code + b"\n"
        strom += b"done\n"
        self.git.fast_import(bytes(strom))
        self.git.run("read-tree", "HEAD")  # Index = letzter übernommener Stand, Arbeitskopie bleibt
        self._log(f"[versionen] {len(dateien)} alte Stände übernommen ({self.projekt.name})")
        return len(dateien)

    def _laufprotokoll(self) -> list[tuple[int, bool, str, str]]:
        datei = self.projekt / ".kevcad" / "log" / "runs.jsonl"
        out = []
        try:
            zeilen = datei.read_text(encoding="utf-8").splitlines()
        except OSError:
            return out
        for z in zeilen:
            try:
                e = json.loads(z)
                ts = int(time.mktime(time.strptime(e["time"], "%Y-%m-%dT%H:%M:%S")))
                out.append((ts, bool(e.get("ok")), str(e.get("source") or ""), str(e.get("file_hash") or "")))
            except (ValueError, KeyError, TypeError):
                continue
        return out

    # =================================================================================================================
    # Metadaten
    # =================================================================================================================

    @property
    def meta_datei(self) -> Path:
        return self.ordner / "index.json"

    def _lade_meta(self) -> None:
        try:
            data = json.loads(self.meta_datei.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                data.setdefault("versionen", {})
                data.setdefault("varianten", {})
                self.meta = data
        except (OSError, json.JSONDecodeError):
            pass

    def _speichere_meta(self) -> None:
        self.ordner.mkdir(parents=True, exist_ok=True)
        tmp = self.meta_datei.with_name(".index.json.tmp")
        tmp.write_text(json.dumps(self.meta, ensure_ascii=False, indent=1), encoding="utf-8")
        tmp.replace(self.meta_datei)

    def meta_von(self, nr: int) -> dict[str, Any]:
        return self.meta["versionen"].setdefault(str(nr), {})

    def aktualisiere(self, nr: int, **werte: Any) -> None:
        with self.lock:
            m = self.meta_von(nr)
            for k, v in werte.items():
                if v is None:
                    m.pop(k, None)
                else:
                    m[k] = v
            self._speichere_meta()

    def _hoechste_nr(self) -> int:
        hoechste = 0
        for e in self.git.log("", alle=True):
            v = version_aus_log(e)
            if v is not None:
                hoechste = max(hoechste, v.nr)
        for k in self.meta.get("versionen", {}):
            if k.isdigit():
                hoechste = max(hoechste, int(k))
        return hoechste

    # =================================================================================================================
    # Neue Versionen
    # =================================================================================================================

    def _neue_version(self, titel: str, *, wer: str, sitzung: str | None, quelle: str, lauf: int | None = None,
                      aus: int | None = None, datum: int | None = None) -> Version:
        nr = self._naechste
        zweig = self.git.zweig()
        vorher = self.git.head()
        text = nachricht(titel, nr=nr, wer=wer, sitzung=sitzung, quelle=quelle, zweig=zweig, lauf=lauf, aus=aus)
        sha = self.git.commit(text, datum=datum)
        self._naechste = nr + 1
        self._liste_cache.clear()
        return Version(nr=nr, commit=sha, ts=int(datum or time.time()), wer=wer, sitzung=sitzung, quelle=quelle,
                       titel=titel, zweig=zweig, aus=aus, lauf=lauf, eltern=vorher)

    def _vormerken(self) -> bool:
        """Änderungen vormerken; True, wenn der vorgemerkte Stand von HEAD abweicht (oder noch nichts da ist)."""
        gross, etwas = self.git.bereite_vor()
        if gross:
            self._log(f"[versionen] zu groß für die Versionen, ausgeschlossen: {', '.join(gross)}")
        if not etwas and self.git.head() is not None:
            return False
        return self.git.geaendert()

    def _geaenderte_dateien(self) -> list[str]:
        if self.git.head() is None:
            return [p for p in self.git.text("ls-files").splitlines() if p]
        return [p for p in self.git.text("diff", "--cached", "--name-only", "--no-renames", "HEAD").splitlines() if p]

    def nach_lauf(self, *, wer: str, sitzung: str | None = None, lauf: int | None = None,
                  nachtrag: tuple[int, str] | None = None,
                  wer_dokumente: str | None = None) -> tuple[Version | None, bool]:
        """Nach einem erfolgreichen Lauf: Änderung → neue Version; sonst gilt der Lauf für die aktuelle Version.
        ``nachtrag`` (Nummer, Commit): Version, die die Hintergrundrechnung ihres Laufs noch aufnimmt; betrifft die
        Änderung nur ``dokumente/`` und ist diese Version noch die Spitze, entsteht keine neue (die Blätter und der
        Bauplan werden in sie nachgetragen, ``dokumente_nachtragen``). ``wer_dokumente``: wer eine neue Version führt,
        die nur ``dokumente/`` ändert (``"kevcad"`` für von Kev CAD selbst angelegte Dokumente). Rückgabe:
        (Version, neu)."""
        if not self.verfuegbar:
            return None, False
        with self.lock:
            if self._vormerken():
                dateien = self._geaenderte_dateien()
                if nachtrag is not None and dateien and all(ist_dokument(p) for p in dateien) \
                        and self.nachtrag_moeglich(*nachtrag) is not None:
                    return self.aktuelle(), False
                titel = "Erster Stand" if self.git.head() is None else dateien_titel(dateien)
                if wer_dokumente and self.git.head() is not None and dateien and all(ist_dokument(p) for p in dateien):
                    wer, sitzung = wer_dokumente, None
                v = self._neue_version(titel, wer=wer, sitzung=sitzung, quelle="lauf", lauf=lauf)
                v.dateien = dateien
                return v, True
            return self.aktuelle(), False

    # =================================================================================================================
    # Nachtragen der Hintergrundrechnung (Blätter, Bauplan)
    # =================================================================================================================

    def nachtrag_moeglich(self, nr: int, commit: str) -> Version | None:
        """Die Version, wenn sie noch Ergebnisse der Hintergrundrechnung aufnehmen darf: Spitze des aktuellen Zweigs,
        kein Meilenstein, kein anderer Zweig enthält sie (sonst änderte das Nachtragen eine fremde Geschichte)."""
        with self.lock:
            v = self.aktuelle()
            if v is None or v.nr != nr or v.commit != commit or self.git.head() != commit:
                return None
            if (self.meta.get("versionen", {}).get(str(nr), {}) or {}).get("meilenstein"):
                return None
            zweig = self.git.zweig()
            if any(z != zweig for z in self.git.enthaltende_zweige(commit)):
                return None
            return v

    def dokumente_nachtragen(self, nr: int, commit: str) -> Version | None:
        """Änderungen der Arbeitskopie in ``dokumente/`` in Version ``nr`` nachtragen (Hintergrundrechnung des Laufs,
        der sie angelegt hat): neuer Commit mit dem Baum der Version plus ``dokumente/``, gleiche Eltern, Nachricht und
        Zeiten, der Zweig zeigt danach darauf. Nummer, Titel, Bild und Metadaten bleiben (sie hängen an der Nummer).
        Andere Änderungen (model.py …) bleiben für den nächsten Lauf liegen. Rückgabe: die Version mit dem neuen
        Commit oder None (nichts nachzutragen oder nicht mehr erlaubt)."""
        if not self.verfuegbar:
            return None
        with self.lock:
            v = self.nachtrag_moeglich(nr, commit)
            if v is None:
                return None
            baum = self.git.baum_mit(commit, DOKUMENTE)
            if baum == self.git.baum(commit):
                return None
            autor_ts, commit_ts = self.git.zeiten(commit)
            neu = self.git.commit_baum(baum, v.eltern, self.git.nachricht(commit), autor_ts, commit_ts)
            self.git.setze_zweig(self.git.zweig(), neu)
            self.git.vormerken(DOKUMENTE)
            self._liste_cache.clear()
            dateien = [d["pfad"] for d in self.git.diff_zahlen(commit, neu)]
            self._log(f"[versionen] V{nr}: {len(dateien)} Dateien der Hintergrundrechnung nachgetragen")
            return self.version_von_commit(neu) or v

    def sichern(self, *, wer: str, sitzung: str | None, titel: str, quelle: str = "sicherung") -> Version | None:
        """Ungesicherte Änderungen als eigene Version festhalten (vor Wiederherstellen, Variantenwechsel)."""
        if not self.verfuegbar:
            return None
        with self.lock:
            if not self._vormerken():
                return None
            dateien = self._geaenderte_dateien()
            v = self._neue_version(f"{titel} ({', '.join(dateien[:3])})" if dateien else titel, wer=wer,
                                   sitzung=sitzung, quelle=quelle)
            v.dateien = dateien
            return v

    def ungesichert(self) -> bool:
        if not self.verfuegbar or not self.git.vorhanden:
            return False
        with self.lock:
            return self._vormerken()

    # =================================================================================================================
    # Abfragen
    # =================================================================================================================

    def versionen(self, zweig: str | None = None) -> list[Version]:
        """Versionen eines Zweigs (Standard: aktueller), neueste zuerst, entlang der ersten Eltern."""
        if not self.verfuegbar or not self.git.vorhanden:
            return []
        with self.lock:
            z = zweig or self.git.zweig()
            if z in self._liste_cache:
                return list(self._liste_cache[z])
            if self.git.rev(f"refs/heads/{z}") is None:
                return []
            out = [v for v in (version_aus_log(e) for e in self.git.log(f"refs/heads/{z}")) if v is not None]
            self._liste_cache[z] = out
            return list(out)

    def alle_versionen(self) -> dict[int, Version]:
        with self.lock:
            out = {}
            for e in self.git.log("", alle=True):
                v = version_aus_log(e)
                if v is not None:
                    out[v.nr] = v
            return out

    def aktuelle(self) -> Version | None:
        liste = self.versionen()
        return liste[0] if liste else None

    def finde(self, ref: Any) -> Version:
        """Version über Nummer (37, "37", "V37"), Meilensteintitel, Commit-Anfang oder "aktuell"."""
        if not self.verfuegbar:
            raise VersionsFehler(self.meldung)
        text = str(ref if ref is not None else "aktuell").strip()
        with self.lock:
            if text.lower() in ("aktuell", "head", "jetzt", ""):
                v = self.aktuelle()
                if v is None:
                    raise VersionsFehler("Noch keine Version: erst ein erfolgreicher Lauf legt die erste an.")
                return v
            alle = self.alle_versionen()
            m = re.fullmatch(r"[Vv]?\s*(\d+)", text)
            if m and int(m.group(1)) in alle:
                return alle[int(m.group(1))]
            for nr, meta in self.meta.get("versionen", {}).items():
                ms = meta.get("meilenstein") or {}
                if ms and str(ms.get("titel", "")).strip().lower() == text.lower() and int(nr) in alle:
                    return alle[int(nr)]
            if re.fullmatch(r"[0-9a-f]{6,40}", text):
                for v in alle.values():
                    if v.commit.startswith(text):
                        return v
            bekannte = ", ".join(f"V{n}" for n in sorted(alle)[-5:])
            raise VersionsFehler(f"Version {text!r} gibt es nicht" + (f" (zuletzt: {bekannte})" if bekannte else "")
                                 + ".")

    def zweig_von(self, name: str) -> str:
        text = name.strip()
        zweige = self.git.zweige()
        if text in zweige:
            return text
        if text.lower() in (HAUPT, HAUPT_NAME.lower(), "haupt", "main"):
            return HAUPT
        for z, m in self.meta.get("varianten", {}).items():
            if str(m.get("name", "")).strip().lower() == text.lower() and z in zweige:
                return z
        if "v-" + slug(text) in zweige:
            return "v-" + slug(text)
        raise VersionsFehler(f"Variante {name!r} gibt es nicht (vorhanden: "
                             f"{', '.join(self.varianten_namen().values())}).")

    def varianten_namen(self) -> dict[str, str]:
        zweige = self.git.zweige() if self.verfuegbar and self.git.vorhanden else {}
        out = {}
        for z in sorted(zweige, key=lambda z: (z != HAUPT, z)):
            out[z] = HAUPT_NAME if z == HAUPT else str(self.meta.get("varianten", {}).get(z, {}).get("name") or z)
        if not out:
            out[HAUPT] = HAUPT_NAME
        return out

    def varianten(self) -> list[dict[str, Any]]:
        if not self.verfuegbar or not self.git.vorhanden:
            return [{"id": HAUPT, "name": HAUPT_NAME, "aktuell": True, "versionen": 0, "letzte": None, "von": None}]
        with self.lock:
            aktuell = self.git.zweig()
            out = []
            for z, name in self.varianten_namen().items():
                liste = self.versionen(z)
                eigene = [v for v in liste if v.zweig == z]
                m = self.meta.get("varianten", {}).get(z, {})
                out.append({"id": z, "name": name, "aktuell": z == aktuell, "versionen": len(eigene),
                            "letzte": zeit_text(liste[0].ts) if liste else None,
                            "letzte_nr": liste[0].nr if liste else None, "von": m.get("von")})
            return out

    def liste(self, zweig: str | None = None, limit: int | None = None) -> dict[str, Any]:
        """Für VERSIONEN und das MCP-Werkzeug: Versionen mit Metadaten (neueste zuerst), Gruppen, Varianten."""
        if not self.verfuegbar:
            return {"verfuegbar": False, "meldung": self.meldung, "versionen": [], "gruppen": [],
                    "varianten": self.varianten(), "variante": HAUPT}
        with self.lock:
            z = zweig or (self.git.zweig() if self.git.vorhanden else HAUPT)
            versionen = self.versionen(z)
            head = versionen[0].nr if versionen else None
            out = []
            for v in versionen:
                out.append(self.version_dict(v, aktuell=v.nr == head, zweig=z))
            gruppen = gruppiere(out)
            if limit is not None and len(out) > limit:
                behalten = out[:limit] + [v for v in out[limit:] if v.get("meilenstein")]
                out = behalten
            return {"verfuegbar": True, "meldung": None, "variante": z, "varianten": self.varianten(),
                    "versionen": out, "gruppen": gruppen, "anzahl": len(versionen),
                    "meilensteine": sum(1 for v in out if v.get("meilenstein"))}

    def titel_von(self, v: Version) -> tuple[str, str | None, str]:
        """Angezeigter Titel, Zusatzzeile und woher der Titel stammt (``agent``, ``auto``, ``fest``, ``offen``).

        - Wiederhergestellt, gesichert: fester Titel, die Automatik als Zusatz.
        - Titel vom Agenten (``run(titel=…)``): vor der Automatik, die als Zusatz darunter steht.
        - Übernommene Stände: der automatische Titel, sobald berechnet, mit „Übernommener Stand“ als Zusatz; bis dahin
          „Übernommener Stand“ (``offen``).
        Meilensteine (Kevin oder Agent) zeigt die App über allem; sie stehen in ``meilenstein``."""
        m = self.meta.get("versionen", {}).get(str(v.nr), {}) or {}
        auto = (m.get("titel_auto") or "").strip() or None
        agent = (m.get("titel_agent") or "").strip() or None
        if v.quelle == "wiederherstellen" and v.aus is not None:
            ms = (self.meta.get("versionen", {}).get(str(v.aus), {}) or {}).get("meilenstein") or {}
            return f"Wiederhergestellt aus V{v.aus}" + (f" „{ms['titel']}“" if ms.get("titel") else ""), auto, "fest"
        if v.quelle in ("sicherung", "meilenstein"):
            grund = re.sub(r" \([^()]*\)$", "", v.titel) if auto else v.titel
            if agent:
                return agent, auto or grund, "agent"
            return grund, auto, "fest"
        if agent:
            return agent, auto, "agent"
        if auto:
            return auto, UEBERNOMMEN if v.quelle == "uebernahme" else None, "auto"
        return v.titel, None, "offen" if v.quelle in ("uebernahme", "lauf") and v.titel != "Erster Stand" else "fest"

    def version_dict(self, v: Version, *, aktuell: bool = False, zweig: str | None = None) -> dict[str, Any]:
        m = self.meta.get("versionen", {}).get(str(v.nr), {})
        bild = m.get("bild")
        bild_pfad = str(self.ordner / bild) if bild and (self.ordner / bild).is_file() else None
        titel, zusatz, titel_quelle = self.titel_von(v)
        return {
            "nr": v.nr, "commit": v.commit[:10], "zeit": zeit_text(v.ts), "ts": v.ts, "wer": v.wer,
            "wer_text": v.wer_text, "sitzung": v.sitzung, "quelle": v.quelle, "titel": titel, "aus": v.aus,
            "zusatz": zusatz, "titel_quelle": titel_quelle, "titel_auto": m.get("titel_auto"),
            "meilenstein": m.get("meilenstein"), "kennzahlen": m.get("kennzahlen"), "params": m.get("params") or {},
            "pruefung": m.get("pruefung"), "bild": bild_pfad, "aktuell": aktuell,
            "geerbt": zweig is not None and v.zweig != zweig, "zweig": v.zweig, "dateien": v.dateien[:20],
            "nachberechnung": m.get("nachberechnung"),
        }

    # =================================================================================================================
    # Automatische Titel (titel.py)
    # =================================================================================================================

    def version_von_commit(self, sha: str | None, zweig: str | None = None) -> Version | None:
        if not sha:
            return None
        with self.lock:
            for w in self.versionen(zweig):
                if w.commit == sha:
                    return w
            for w in self.alle_versionen().values():
                if w.commit == sha:
                    return w
        return None

    def _text(self, commit: str, pfad: str) -> str | None:
        data = self.git.datei(commit, pfad)
        if data is None or len(data) > MAX_TEXT_BYTES:
            return None
        try:
            return data.decode("utf-8")
        except UnicodeDecodeError:
            return None

    def aenderungen(self, a: Version, b: Version | None, *, pfade: tuple[str, ...] = ()) -> list[dict[str, Any]]:
        """Geänderte Dateien von ``a`` nach ``b`` (None = aktueller Stand der Arbeitskopie) mit altem und neuem Inhalt
        (Text; None = fehlt, binär, zu groß). ``pfade``: nur diese Pfadangaben."""
        with self.lock:
            if b is None:
                self._vormerken()
            zahlen = self.git.diff_zahlen(a.commit, b.commit if b else None, pfade=pfade)
            neu_ref = b.commit if b else ""  # "" + ":pfad" = vorgemerkter Stand
            out = []
            for d in zahlen:
                e: dict[str, Any] = {"pfad": d["pfad"], "status": d["status"], "alt": None, "neu": None,
                                     "binaer": bool(d.get("binaer"))}
                if not e["binaer"]:
                    if d["status"] != "A":
                        e["alt"] = self._text(a.commit, d["pfad"])
                    if d["status"] != "D":
                        e["neu"] = self._text(neu_ref, d["pfad"])
                    if (d["status"] != "A" and e["alt"] is None) or (d["status"] != "D" and e["neu"] is None):
                        e["binaer"] = True
                out.append(e)
            return out

    def titel_veraltet(self, v: Version, vor: Version | None, *, daten_da: bool) -> bool:
        """Muss der automatische Titel (neu) berechnet werden? Fehlt, ältere Regeln, anderer Vorgänger (nach dem
        Ausdünnen) oder bisher nur aus dem Code, obwohl jetzt beide Stände Daten haben (``daten_da``)."""
        m = self.meta.get("versionen", {}).get(str(v.nr), {}) or {}
        if not m.get("titel_auto") or m.get("titel_regel") != TITEL_REGEL:
            return True
        if m.get("titel_gegen") != (vor.nr if vor else None):
            return True
        return m.get("titel_basis") != "daten" and daten_da

    def titel_berechnen(self, v: Version, vor: Version | None, alt: dict[str, Any] | None,
                        neu: dict[str, Any] | None) -> dict[str, Any]:
        """Automatischen Titel aus dem Vergleich mit ``vor`` berechnen und in den Metadaten ablegen (nie in Git; den
        Meilenstein und den Titel des Agenten berührt das nicht)."""
        aend = self.aenderungen(vor, v) if vor is not None else []
        res = auto_titel(aend, alt, neu, erster=vor is None)
        self.aktualisiere(v.nr, titel_auto=res["titel"] or None, titel_regel=TITEL_REGEL, titel_basis=res["basis"],
                          titel_gegen=vor.nr if vor else None)
        return res

    def titel_agent(self, nr: int, titel: str) -> None:
        self.aktualisiere(nr, titel_agent=" ".join((titel or "").split())[:160] or None)

    # =================================================================================================================
    # Meilensteine (V3)
    # =================================================================================================================

    def meilenstein(self, ref: Any, titel: str, notiz: str = "", *, wer: str, sitzung: str | None = None,
                    ersetzen: bool = False) -> Version:
        """Version benennen; ``ref`` None = aktueller Stand (ungesicherte Änderungen werden vorher eine Version).
        Einen Meilenstein, den Kevin vergeben hat, ändert nur Kevin: sonst ``KevinsMeilenstein`` (außer mit
        ``ersetzen``, wenn Kevin es ausdrücklich will)."""
        titel = (titel or "").strip()
        if not titel:
            raise VersionsFehler("Ein Meilenstein braucht einen Titel.")
        with self.lock:
            if ref is None or str(ref).strip().lower() in ("", "aktuell", "head", "jetzt"):
                v = self.sichern(wer=wer, sitzung=sitzung, titel="Stand für Meilenstein", quelle="meilenstein") \
                    or self.aktuelle()
                if v is None:
                    raise VersionsFehler("Noch keine Version im Projekt.")
            else:
                v = self.finde(ref)
            alt = (self.meta.get("versionen", {}).get(str(v.nr), {}) or {}).get("meilenstein") or {}
            if alt and alt.get("wer") == "kevin" and wer != "kevin" and not ersetzen:
                raise KevinsMeilenstein(v, alt)
            self.aktualisiere(v.nr, meilenstein={"titel": titel, "notiz": (notiz or "").strip(),
                                                 "zeit": zeit_text(time.time()), "wer": wer, "sitzung": sitzung})
            return v

    def meilenstein_entfernen(self, ref: Any) -> Version:
        with self.lock:
            v = self.finde(ref)
            self.aktualisiere(v.nr, meilenstein=None)
            return v

    # =================================================================================================================
    # Wiederherstellen (V5)
    # =================================================================================================================

    def wiederherstellen(self, ref: Any, *, wer: str, sitzung: str | None = None) -> dict[str, Any]:
        """Dateien auf den Stand von ``ref`` setzen, nie zerstörend: vorher ungesicherte Änderungen sichern, danach
        eine neue Version „Wiederhergestellt aus …“ anlegen."""
        with self.lock:
            ziel = self.finde(ref)
            gesichert = self.sichern(wer=wer, sitzung=sitzung, titel="Gesichert vor dem Wiederherstellen")
            head = self.git.head()
            if head is not None and self.git.baum(head) == self.git.baum(ziel.commit):
                return {"version": self.aktuelle(), "aus": ziel, "gesichert": gesichert, "unveraendert": True}
            self.git.stelle_her(ziel.commit)
            ms = (self.meta.get("versionen", {}).get(str(ziel.nr), {}) or {}).get("meilenstein") or {}
            titel = f"Wiederhergestellt aus V{ziel.nr}" + (f" „{ms['titel']}“" if ms.get("titel") else "")
            neu = self._neue_version(titel, wer=wer, sitzung=sitzung, quelle="wiederherstellen", aus=ziel.nr)
            # Kennzahlen bis zum nächsten Lauf aus der Quelle übernehmen (gleiche Dateien, gleicher Stand)
            alt = dict(self.meta.get("versionen", {}).get(str(ziel.nr), {}))
            werte = {k: alt[k] for k in ("kennzahlen", "params", "pruefung") if k in alt}
            if werte:
                self.aktualisiere(neu.nr, **werte)
            return {"version": neu, "aus": ziel, "gesichert": gesichert, "unveraendert": False}

    # =================================================================================================================
    # Varianten (V7)
    # =================================================================================================================

    def variante_anlegen(self, name: str, von: Any = None, *, wer: str, sitzung: str | None = None) -> dict[str, Any]:
        name = (name or "").strip()
        if not name:
            raise VersionsFehler("Eine Variante braucht einen Namen.")
        with self.lock:
            if any(n.lower() == name.lower() for n in self.varianten_namen().values()):
                raise VersionsFehler(f"Variante {name!r} gibt es schon.")
            gesichert = self.sichern(wer=wer, sitzung=sitzung, titel="Gesichert vor dem Variantenwechsel")
            basis = self.finde(von) if von is not None else self.aktuelle()
            if basis is None:
                raise VersionsFehler("Noch keine Version, von der eine Variante abzweigen kann.")
            zweige = self.git.zweige()
            z = "v-" + slug(name)
            n = 2
            while z in zweige:
                z = f"v-{slug(name)}-{n}"
                n += 1
            vorher = self.git.zweig()
            self.git.neuer_zweig(z, basis.commit)
            self.git.wechsle(z)
            self.meta.setdefault("varianten", {})[z] = {"name": name, "von": basis.nr, "aus_variante": vorher,
                                                        "angelegt": zeit_text(time.time()), "wer": wer}
            self._speichere_meta()
            self._liste_cache.clear()
            return {"zweig": z, "name": name, "von": basis, "gesichert": gesichert, "vorher": vorher}

    def variante_wechseln(self, name: str, *, wer: str, sitzung: str | None = None) -> dict[str, Any]:
        with self.lock:
            z = self.zweig_von(name)
            vorher = self.git.zweig()
            if z == vorher:
                return {"zweig": z, "name": self.varianten_namen()[z], "gesichert": None, "unveraendert": True,
                        "vorher": vorher}
            gesichert = self.sichern(wer=wer, sitzung=sitzung, titel="Gesichert vor dem Variantenwechsel")
            self.git.wechsle(z)
            self._liste_cache.clear()
            return {"zweig": z, "name": self.varianten_namen()[z], "gesichert": gesichert, "unveraendert": False,
                    "vorher": vorher}

    def variante_umbenennen(self, name: str, neuer_name: str) -> dict[str, Any]:
        neuer_name = (neuer_name or "").strip()
        if not neuer_name:
            raise VersionsFehler("Neuer Name fehlt.")
        with self.lock:
            z = self.zweig_von(name)
            if z == HAUPT:
                raise VersionsFehler("Der Hauptstand behält seinen Namen.")
            self.meta.setdefault("varianten", {}).setdefault(z, {})["name"] = neuer_name
            self._speichere_meta()
            return {"zweig": z, "name": neuer_name}

    # =================================================================================================================
    # Code und Dateien
    # =================================================================================================================

    def code_diff(self, a: Version, b: Version | None, *, max_zeilen: int = 4000) -> dict[str, Any]:
        """Unterschied der Dateien von ``a`` nach ``b`` (None = aktueller Stand der Arbeitskopie), ohne
        ``dokumente/`` (die nennt der Vergleich als eigene Gruppe, ``dokumente_vergleich``)."""
        with self.lock:
            if b is None:
                self._vormerken()
            dateien = self.git.diff_zahlen(a.commit, b.commit if b else None, pfade=OHNE_DOKUMENTE)
            text = self.git.diff_text(a.commit, b.commit if b else None, pfade=OHNE_DOKUMENTE)
        zeilen = text.splitlines()
        gekuerzt = len(zeilen) > max_zeilen
        if gekuerzt:
            text = "\n".join(zeilen[:max_zeilen]) + "\n"
        return {"dateien": dateien, "diff": text, "gekuerzt": gekuerzt, "zeilen": len(zeilen)}

    def dokumente_vergleich(self, a: Version, b: Version | None) -> list[dict[str, Any]]:
        """Inhaltliche Änderungen an Blättern, Bauplan und übrigen Dateien in ``dokumente/`` von ``a`` nach ``b``
        (None = aktueller Stand), siehe dokumente.py."""
        return vergleiche_dokumente(self.aenderungen(a, b, pfade=(DOKUMENTE,)))

    def materialisiere(self, v: Version, ziel: Path) -> Path:
        """Dateien einer Version in einen eigenen Ordner auspacken (für den Lauf ohne Live-Aufbau)."""
        import io
        import tarfile

        ziel.mkdir(parents=True, exist_ok=True)
        with self.lock:
            daten = self.git.archiv(v.commit)
        with tarfile.open(fileobj=io.BytesIO(daten)) as tar:
            tar.extractall(ziel, filter="data")
        return ziel

    # =================================================================================================================
    # Aufräumen (V9)
    # =================================================================================================================

    def aufraeumen(self, *, jetzt: float | None = None, tage: float = 30.0, gc: bool = True) -> dict[str, Any]:
        """Automatische Versionen älter als ``tage`` auf eine je Stunde ausdünnen (die letzte der Stunde bleibt).
        Meilensteine, Spitzen und Abzweigpunkte von Varianten, wiederhergestellte Stände und Variantenanfänge bleiben
        immer. Schreibt die Kette mit ``commit-tree`` neu (Nummern bleiben)."""
        if not self.verfuegbar or not self.git.vorhanden:
            return {"entfernt": [], "behalten": 0}
        jetzt = time.time() if jetzt is None else jetzt
        grenze = jetzt - tage * 86400
        with self.lock:
            zweige = self.git.zweige()
            if not zweige:
                return {"entfernt": [], "behalten": 0}
            zeilen = self.git.text("rev-list", "--topo-order", "--reverse", "--parents", *zweige.values()).splitlines()
            eltern: dict[str, str | None] = {}
            reihenfolge: list[str] = []
            kinder: dict[str, int] = {}
            for z in zeilen:
                teile = z.split()
                if not teile:
                    continue
                eltern[teile[0]] = teile[1] if len(teile) > 1 else None
                reihenfolge.append(teile[0])
                if len(teile) > 1:
                    kinder[teile[1]] = kinder.get(teile[1], 0) + 1
            info = {e["commit"]: e for e in self.git.log("", alle=True)}
            spitzen = set(zweige.values())
            enthalten: dict[str, frozenset[str]] = {c: frozenset() for c in reihenfolge}
            for name, sha in zweige.items():
                for c in self.git.text("rev-list", sha).split():
                    enthalten[c] = enthalten.get(c, frozenset()) | {name}
            meta_v = self.meta.get("versionen", {})
            # je Stunde und Abschnitt (gleiche Menge enthaltender Zweige) bleibt der jüngste Stand; ist das schon ein
            # fester (Meilenstein, Abzweig …), kommt kein weiterer dazu
            stunden: dict[tuple[int, frozenset[str]], list[str]] = {}
            behalten: set[str] = set()
            for c in reihenfolge:
                e = info.get(c)
                v = version_aus_log(e) if e else None
                fest = (v is None or c in spitzen or kinder.get(c, 0) > 1 or v.quelle not in AUTOMATISCH
                        or bool((meta_v.get(str(v.nr)) or {}).get("meilenstein")) or v.ts >= grenze)
                if fest:
                    behalten.add(c)
                if v is not None and v.ts < grenze:
                    stunden.setdefault((int(v.ts // 3600), enthalten.get(c, frozenset())), []).append(c)
            stelle = {c: i for i, c in enumerate(reihenfolge)}
            for liste in stunden.values():
                behalten.add(max(liste, key=lambda c: (info[c]["ts"], stelle[c])))
            weg = [c for c in reihenfolge if c not in behalten]
            if not weg:
                return {"entfernt": [], "behalten": len(behalten)}
            neu: dict[str, str] = {}
            for c in reihenfolge:  # Eltern vor Kindern
                if c not in behalten:
                    continue
                p = eltern.get(c)
                while p is not None and p not in behalten:
                    p = eltern.get(p)
                neue_eltern = neu[p] if p is not None else None
                if neue_eltern == eltern.get(c):
                    neu[c] = c  # Vorgänger unverändert: Commit bleibt
                    continue
                e = info[c]
                autor = int(e["ts"])
                neu[c] = self.git.commit_baum(self.git.baum(c), neue_eltern, e["nachricht"], autor, autor)
            for name, sha in zweige.items():
                if neu.get(sha, sha) != sha:
                    self.git.setze_zweig(name, neu[sha])
            entfernt_nr = []
            for c in weg:
                v = version_aus_log(info[c]) if c in info else None
                if v is not None:
                    entfernt_nr.append(v.nr)
                    self.meta.get("versionen", {}).pop(str(v.nr), None)
                    for datei in (self.ordner / "daten" / f"{v.nr}.json", self.ordner / "bilder" / f"{v.nr}.png"):
                        try:
                            datei.unlink()
                        except OSError:
                            pass
            self.meta["aufgeraeumt"] = int(jetzt)
            self._speichere_meta()
            self._liste_cache.clear()
            if gc:
                self.git.aufraeumen_speicher()
            self._log(f"[versionen] aufgeräumt: {len(entfernt_nr)} alte automatische Versionen ausgedünnt")
            return {"entfernt": sorted(entfernt_nr), "behalten": len(behalten)}

    def aufraeumen_faellig(self, jetzt: float | None = None) -> bool:
        jetzt = time.time() if jetzt is None else jetzt
        return jetzt - float(self.meta.get("aufgeraeumt") or 0) > 86400


def _fi_pfad(pfad: str) -> str:
    """Pfad für git fast-import (in Anführungszeichen, wenn nötig)."""
    if "\n" in pfad or pfad.startswith('"') or '"' in pfad or "\\" in pfad:
        return '"' + pfad.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'
    return pfad


__all__ = ["HAUPT", "HAUPT_NAME", "UEBERNOMMEN", "GitFehler", "KevinsMeilenstein", "Version", "VersionsFehler",
           "Versionsarchiv", "dateien_titel", "gruppiere", "lies_nachricht", "nachricht", "zeit_text"]
