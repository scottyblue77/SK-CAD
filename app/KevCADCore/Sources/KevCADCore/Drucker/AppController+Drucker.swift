import AppKit
import Foundation

// Drucken (Phase 8): Einstellungen an den Kernel (PRINTER_CONFIG nach HELLO und nach jedem Sichern), Status übernehmen
// (PRINTER_STATUS), Dialog „Drucken …“ mit Vorbereiten (PRINT_JOB_REQ bestaetigt=false) und Kevins Klick
// (bestaetigt=true), Fragen des Agenten (PRINT_JOB_ASK → ACK, Dialog öffnen), Steuern (PRINT_CONTROL).

extension AppController: DruckerActions {
    static var druckerTimeout: TimeInterval = 15

    func handleDrucker(_ n: DruckerNachricht) {
        switch n {
        case .status(let s, _):
            let alt = model.drucker.status
            model.drucker.setzeStatus(s)
            if alt?.verbindung != s.verbindung, s.konfiguriert {
                log(s.verbindung == .fehler ? .warning : .info,
                    "Drucker: \(s.verbindung.titel)" + (s.meldung.map { " – \($0)" } ?? ""))
            }
            if alt?.druck?.zustand != s.druck?.zustand, let d = s.druck, alt?.druck != nil {
                log(.info, "Drucker: \(d.zustand.titel)" + (d.aufgabe.map { " (\($0))" } ?? ""))
            }
        case .auftragErgebnis(let e):
            druckAuftragErgebnis(e)
        case .frage(let f):
            // Der Agent bittet um den Dialog. Es geschieht nichts, bis Kevin dort klickt.
            send(AckOutMessage(replyTo: f.id, ok: true, message: "Dialog „Drucken …“ ist offen"))
            log(.info, "Claude möchte drucken" + (f.grund.map { ": \($0)" } ?? "") + " – wartet auf die Bestätigung von \(AppInfo.nutzerName)")
            var d = DruckDialogZustand(platten: DruckDialogZustand.auswahl(f.platten, vorschau: model.druck.vorschau),
                                       weg: f.weg, frage: f)
            d.filamentVorbelegen(model.druck.vorschau)
            if f.weg == .b, model.drucker.status?.wegB.moeglich != true { d.weg = .a }
            model.drucker.setzeDialog(d)
            druckVorbereiten()
        }
    }

    /// Nach HELLO: Einstellungen laden und dem Kernel geben (er verbindet sich nur, wenn „Status lesen“ an ist).
    func druckerNachHello() {
        guard !AppInfo.isDemoMode else { return }
        let datei = DruckerEinstellungenDatei.laden(von: model.drucker.dateiURL)
        let zugang = datei.aktiver.map { model.drucker.speicher.vorhanden(id: $0.id) } ?? false
        model.drucker.setzeEinstellungen(datei, zugang: zugang)
        druckerKonfigSenden()
    }

    /// Eigene Nummern (`d-1`, `d-2` …) für PRINTER_CONFIG, damit das Senden nach HELLO die Nummern der übrigen
    /// Anfragen nicht verschiebt.
    private static var druckerZaehler = 0

    private func druckerKonfigSenden() {
        Self.druckerZaehler += 1
        let msg = DruckerKonfigNachricht(id: "d-\(Self.druckerZaehler)", drucker: model.drucker.aktiver)
        request(msg, timeout: Self.druckerTimeout) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.ack(let a)) where !a.ok:
                self.model.drucker.setzeFehler(a.message ?? "Der Kernel hat die Drucker-Einstellungen abgelehnt.")
            case .failure(let e) where e.message.contains("keine Antwort"):
                self.log(.info, "Drucker: Der Kernel kennt Phase 8 noch nicht (\(e.message))")
            default:
                break
            }
        }
    }

    // MARK: DruckerActions

    public func druckerSpeichern(_ eintrag: DruckerEintrag, seriennummer: String?, zugangscode: String?) throws {
        var e = eintrag
        e.ip = e.ip.trimmingCharacters(in: .whitespaces)
        guard DruckerEintrag.gueltigeID(e.id) else { throw DruckerEingabeFehler("Drucker-ID ungültig") }
        if !e.ip.isEmpty, !DruckerEintrag.gueltigeIP(e.ip) {
            throw DruckerEingabeFehler("Die IP-Adresse ist ungültig (etwa 192.168.178.40).")
        }
        let sn = seriennummer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let code = zugangscode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !sn.isEmpty || !code.isEmpty {
            guard !sn.isEmpty, !code.isEmpty else {
                throw DruckerEingabeFehler("Seriennummer und Zugangscode bitte zusammen eintragen.")
            }
            try model.drucker.speicher.speichern(id: e.id, seriennummer: sn, zugangscode: code)
            e.kennung = DruckerEintrag.kennung(seriennummer: sn)
        }
        var datei = model.drucker.einstellungen
        datei.setze(e)
        try datei.speichern(nach: model.drucker.dateiURL)
        model.drucker.setzeEinstellungen(datei, zugang: model.drucker.speicher.vorhanden(id: e.id))
        model.drucker.setzeFehler(nil)
        log(.info, "Drucker-Einstellungen gesichert: \(e.name), \(e.weg.kurz), Status lesen \(e.statusLesen ? "an" : "aus")"
            + (sn.isEmpty ? "" : ", Zugangsdaten im Schlüsselbund"))
        druckerKonfigSenden()
    }

    public func druckerZugangLoeschen(id: String) throws {
        try model.drucker.speicher.loeschen(id: id)
        var datei = model.drucker.einstellungen
        if var e = datei.drucker.first(where: { $0.id == id }) {
            e.kennung = nil
            e.statusLesen = false
            datei.setze(e)
            try datei.speichern(nach: model.drucker.dateiURL)
        }
        model.drucker.setzeEinstellungen(datei, zugang: false)
        log(.info, "Zugangsdaten des Druckers aus dem Schlüsselbund gelöscht")
        druckerKonfigSenden()
    }

    public func druckerStatusAnfordern() {
        guard !AppInfo.isDemoMode, helloReceived else { return }
        request(DruckerStatusAnfrage(id: nextRequestID()), timeout: Self.druckerTimeout) { _ in }
    }

    public func druckDialogOeffnen(platten: [Int]) {
        guard !AppInfo.isDemoMode else { return }
        let weg: DruckWeg = model.drucker.aktiver?.weg == .b && model.drucker.status?.wegB.moeglich == true ? .b : .a
        var d = DruckDialogZustand(platten: DruckDialogZustand.auswahl(platten, vorschau: model.druck.vorschau), weg: weg)
        d.filamentVorbelegen(model.druck.vorschau)
        model.drucker.setzeDialog(d)
        druckVorbereiten()
    }

    public func druckDialogAendern(platten: [Int], weg: DruckWeg) {
        let platten = DruckDialogZustand.auswahl(platten, vorschau: model.druck.vorschau)
        guard let d = model.drucker.dialog, d.platten != platten || d.weg != weg else { return }
        let nachDruck: Bool
        if case .fertig = d.phase { nachDruck = true } else { nachDruck = false }
        model.drucker.aendereDialog {
            $0.platten = platten
            $0.weg = weg
            if nachDruck {  // „Nächstes Material“: neuer Auftrag
                $0.auftrag = nil
                $0.frage = nil
                $0.bestaetigenID = nil
                $0.auftragZustand = nil
                $0.auftragMeldung = nil
            }
        }
        druckVorbereiten()
    }

    public func druckDialogFilament(klasse: String, filament: String?) {
        guard let d = model.drucker.dialog, d.filament[klasse] != filament else { return }
        if case .laeuft = d.phase { return }
        if case .fertig = d.phase { return }
        model.drucker.aendereDialog {
            if let filament { $0.filament[klasse] = filament } else { $0.filament.removeValue(forKey: klasse) }
        }
        druckVorbereiten()
    }

    public func druckDialogOptionen(_ o: DruckOptionen) {
        model.drucker.aendereDialog { $0.optionen = o }
    }

    public func druckDialogNeuVorbereiten() {
        druckVorbereiten()
    }

    /// PRINT_JOB_REQ mit `bestaetigt: false`: der Kernel slict schon, während Kevin den Dialog liest.
    func druckVorbereiten() {
        guard let d = model.drucker.dialog else { return }
        guard helloReceived else {
            model.drucker.aendereDialog { $0.phase = .fehler("Der Kernel ist nicht verbunden.") }
            return
        }
        let id = nextRequestID()
        model.drucker.aendereDialog {
            $0.vorbereitenID = id
            $0.phase = .bereitet
        }
        // Weg B wird erst beim Klick geprüft; vorbereitet wird immer über Weg A (nur slicen). Ohne gewähltes Filament
        // slict der Kernel mit dem der Druckvorschau, bestätigen geht dann aber nicht (Strang „Rest Druck“).
        let wahl = d.filamentWahl(model.druck.vorschau)
        let msg = DruckAuftragNachricht(id: id, platten: d.platten, weg: .a, bestaetigt: false, auftrag: d.auftrag,
                                        filament: wahl.isEmpty ? nil : wahl)
        request(msg, timeout: Self.druckerTimeout) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.ack(let a)) where !a.ok:
                self.druckDialogFehler(id, a.message ?? "Der Kernel hat den Auftrag abgelehnt.")
            case .failure(let e):
                self.druckDialogFehler(id, e.message.contains("keine Antwort")
                    ? "Der Kernel antwortet nicht. Ältere Kernel-Versionen kennen „Drucken“ noch nicht." : e.message)
            default:
                break  // Ergebnis kommt als PRINT_JOB_RES
            }
        }
    }

    private func druckDialogFehler(_ id: String, _ text: String) {
        guard let d = model.drucker.dialog, d.vorbereitenID == id || d.bestaetigenID == id else { return }
        model.drucker.aendereDialog { $0.phase = .fehler(text) }
        log(.warning, "Drucken: \(text)")
    }

    public func druckBestaetigen() {
        guard let d = model.drucker.dialog, case .bereit = d.phase else { return }
        // Kevin, 22.10.2026: ohne Wahl des Filaments geht kein Druck los
        let fehlt = d.fehlendesFilament(model.druck.vorschau)
        guard fehlt.isEmpty else {
            let namen = fehlt.map { model.druck.vorschau?.klassenTitel($0) ?? $0.uppercased() }
            model.drucker.aendereDialog {
                $0.phase = .fehler("Bitte das Filament wählen (\(namen.joined(separator: ", "))).")
            }
            return
        }
        let id = nextRequestID()
        model.drucker.aendereDialog {
            $0.bestaetigenID = id
            $0.phase = .laeuft
        }
        let msg = DruckAuftragNachricht(id: id, platten: d.platten, weg: d.weg, bestaetigt: true,
                                        optionen: d.weg == .b ? d.optionen : nil, auftrag: d.auftrag,
                                        filament: d.filamentWahl(model.druck.vorschau))
        log(.info, "\(AppInfo.nutzerName) bestätigt: \(d.weg == .a ? "in Bambu Studio öffnen" : "direkt drucken"), Platten "
            + (d.platten.isEmpty ? "alle" : d.platten.map(String.init).joined(separator: ", ")))
        request(msg, timeout: Self.druckerTimeout) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.ack(let a)) where !a.ok:
                self.druckDialogFehler(id, a.message ?? "Der Kernel hat den Auftrag abgelehnt.")
            case .failure(let e):
                self.druckDialogFehler(id, e.message)
            default:
                break
            }
        }
    }

    private func druckAuftragErgebnis(_ e: DruckAuftragErgebnis) {
        guard let d = model.drucker.dialog else {
            if !e.ok, let f = e.fehler { log(.warning, "Drucken: \(f)") }
            return
        }
        if e.replyTo != nil, e.replyTo == d.vorbereitenID {
            model.drucker.aendereDialog {
                $0.auftrag = e.auftrag ?? $0.auftrag
                $0.phase = e.ok ? .bereit(e) : .fehler(e.fehler ?? "Vorbereiten fehlgeschlagen")
            }
        } else if e.replyTo != nil, e.replyTo == d.bestaetigenID {
            model.drucker.aendereDialog { $0.phase = e.ok ? .fertig(e) : .fehler(e.fehler ?? "Fehlgeschlagen") }
            if e.ok {
                log(.info, e.schritt == "geoeffnet"
                    ? "In Bambu Studio geöffnet: \(e.datei?.lastPathComponent ?? "?") – dort „Platte drucken“ und „Senden“"
                    : "Druck gestartet")
            } else if let f = e.fehler {
                log(.warning, "Drucken: \(f)")
            }
        }
    }

    public func druckDialogSchliessen() {
        guard let d = model.drucker.dialog else { return }
        model.drucker.setzeDialog(nil)
        var bestaetigt = false
        switch d.phase {
        case .laeuft, .fertig: bestaetigt = true
        default: break
        }
        if !bestaetigt, let a = d.auftrag, helloReceived {
            request(DruckerSteuerNachricht(id: nextRequestID(), aktion: .verwerfen, auftrag: a),
                    timeout: Self.druckerTimeout) { _ in }
            if d.frage != nil { log(.info, "\(AppInfo.nutzerName) hat den Druckwunsch von Claude verworfen") }
        }
    }

    public func druckerSteuern(_ aktion: DruckerAktion) {
        guard !AppInfo.isDemoMode, helloReceived else { return }
        if aktion != .aktualisieren, aktion != .verwerfen, model.drucker.status?.steuern != true {
            model.drucker.setzeFehler("Steuern geht nur über Weg B (LAN-only und Developer Mode).")
            return
        }
        model.drucker.setzeFehler(nil)
        request(DruckerSteuerNachricht(id: nextRequestID(), aktion: aktion), timeout: Self.druckerTimeout) {
            [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.ack(let a)):
                if a.ok {
                    self.model.drucker.setzeMeldung(a.message)
                } else {
                    self.model.drucker.setzeFehler(a.message ?? "Abgelehnt")
                }
            case .failure(let e):
                self.model.drucker.setzeFehler(e.message)
            default:
                break
            }
        }
    }

    public func druckDateiZeigen(_ datei: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([datei])
    }
}

public struct DruckerEingabeFehler: Error, LocalizedError {
    public var text: String
    public init(_ text: String) { self.text = text }
    public var errorDescription: String? { text }
}
