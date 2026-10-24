import AppKit
import Foundation
import OCCTSwiftViewport
import PDFKit
import simd

/// Dokument-Export (DOKUMENTE.md, Anhang „Export“, Strang P6-A2): Vorlagen lesen und speichern, Daten zusammentragen
/// (Stückliste, Bestand, Bauplan, Blätter, Vorschaubilder vom Offscreen-Renderer), PDF schreiben, drucken, und die
/// Anfrage des Kernels (DOC_EXPORT_REQ → DOC_EXPORT_RES) beantworten.
extension AppController: ExportActions {
    // MARK: Vorlagen

    public func exportVorlagenLaden() {
        guard let p = model.project else {
            model.export.vorlagen = ExportVorlagenDatei()
            return
        }
        let (d, fehler) = ExportVorlagenDatei.laden(projekt: p.path)
        model.export.vorlagen = d
        model.export.vorlagenFehler = fehler
        if let fehler { log(.warning, fehler) }
    }

    public func exportVorlageSpeichern(_ v: ExportVorlage) throws {
        guard let p = model.project else { throw ExportFehler.leer("Kein Projekt offen") }
        var d = model.export.vorlagen
        d.setze(v.vollstaendig)
        try d.speichern(projekt: p.path)
        model.export.vorlagen = d
        log(.info, "Export-Vorlage „\(v.name)“ gespeichert")
    }

    public func exportVorlageLoeschen(_ name: String) throws {
        guard let p = model.project else { throw ExportFehler.leer("Kein Projekt offen") }
        var d = model.export.vorlagen
        d.entferne(name)
        try d.speichern(projekt: p.path)
        model.export.vorlagen = d
    }

    func resetExport() {
        model.export.leeren()
    }

    // MARK: Dokument bauen

    public func exportDokument(_ v: ExportVorlage) async -> ExportDokument {
        let q = await exportQuellen(v)
        model.export.laeuft = "Seiten werden gesetzt"
        let t = Date()
        let doc = ExportBauer.dokument(v, q)
        model.export.phasen["seiten_ms"] = Int(Date().timeIntervalSince(t) * 1000)
        model.export.laeuft = nil
        return doc
    }

    /// Wartet, bis `fertig` gilt (höchstens `sekunden`).
    func exportWarte(_ sekunden: Double, _ fertig: () -> Bool) async -> Bool {
        let ende = Date().addingTimeInterval(sekunden)
        while Date() < ende {
            if fertig() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return fertig()
    }

    func exportKopf() -> ExportKopf {
        var version: String?
        if let v = model.versionen.stand?.aktuelleVersion {
            version = "V\(v.nr)" + (v.meilenstein.map { " · \($0.titel)" } ?? "")
        }
        return ExportKopf(projekt: model.project?.name ?? "SK-CAD", version: version)
    }

    func exportQuellen(_ v: ExportVorlage) async -> ExportQuellen {
        let store = model.export
        let arten = Set(v.aktive.map(\.art))
        store.phasen = [:]
        var uhr = Date()
        func phase(_ name: String) {
            store.phasen[name] = Int(Date().timeIntervalSince(uhr) * 1000)
            uhr = Date()
        }
        var q = ExportQuellen(kopf: exportKopf(), bom: model.bom, bestand: model.bestandZustand.zuschnitt,
                              teile: model.parts)
        q.druck = model.druck.vorschau  // Baustein „3D-Druck“ (DRUCKVORSCHAU.md)
        q.projektBestand = model.bestandZustand.bestand  // Material: dieselbe Datenquelle wie am Bildschirm
        q.katalog = model.catalog
        // Bauplan: wenn nötig beim Kernel holen (erzeugt ihn beim ersten Mal)
        if arten.contains(.bauplan) || arten.contains(.deckblatt) {
            if model.bauplan.plan == nil && connected {
                store.laeuft = "Bauplan wird geholt"
                bauplanAnfordern()
                _ = await exportWarte(300) { !model.bauplan.laedt }
            }
            q.bauplan = model.bauplan.plan
            q.strichbilder = model.bauplan.bilder
            phase("bauplan_ms")
        }
        // Zeichnungen: Übersicht und alle gewählten Blätter (gerechnet und aktuell)
        if let wahl = v.aktive.first(where: { $0.art == .zeichnungen }) {
            q.zeichnungen = await exportZeichnungen(wahl)
            phase("blaetter_ms")
        }
        // Vorschaubilder
        let stueck = v.aktive.first { $0.art == .stueckliste }
        let teile = v.aktive.first { $0.art == .teileliste }
        var namen: [String] = []
        if let s = stueck, s.wirksameSpalten.contains(where: { $0.id == "bild" }) {
            namen += (model.bom?.lines ?? []).compactMap { $0.teile.first { scene.record($0) != nil } }
        }
        if let t = teile, t.wirksameSpalten.contains(where: { $0.id == "bild" }) {
            namen += model.parts.map(\.id)
        }
        if !namen.isEmpty {
            store.laeuft = "Vorschaubilder werden gerendert"
            q.teilBilder = await exportTeilBilder(Array(Set(namen)))
        }
        if arten.contains(.deckblatt) { q.gesamtBild = exportGesamtBild() }
        if arten.contains(.produktbild) {  // Phase 7: Rendering (Render/AppController+Render.swift)
            store.laeuft = "Produktbild wird gerendert"
            if let p = await exportProduktbild() {
                q.produktBild = p.bild
                q.produktQuelle = p.quelle
            }
        }
        phase("bilder_ms")
        q.pruefFehler = model.pruefung?.fehler
        store.laeuft = nil
        return q
    }

    func exportZeichnungen(_ wahl: ExportBausteinWahl) async -> [ExportZeichnungsblatt] {
        let docs = model.dokumente
        guard connected else {
            return docs.zeichnungen.values.sorted { $0.id < $1.id }.map(Self.exportBlatt)
        }
        if docs.uebersicht == nil {
            model.export.laeuft = "Blätter werden gerechnet"
            dokumenteAnfordern()
            _ = await exportWarte(300) { docs.uebersicht != nil && !docs.uebersichtLaedt }
        }
        let alle = docs.uebersicht?.blaetter.map(\.id) ?? []
        let ids = (wahl.auswahl?.isEmpty == false ? wahl.auswahl! : alle).filter { alle.contains($0) }
        let fehlen = ids.filter { docs.zeichnung($0) == nil || docs.istVeraltet($0) }
        if !fehlen.isEmpty {
            model.export.laeuft = "\(KevFormat.count(fehlen.count, one: "Blatt wird", many: "Blätter werden")) gerechnet"
            for id in fehlen where !docs.laedt.contains(id) { zeichnungAnfordern(id) }
            _ = await exportWarte(300) { ids.allSatisfy { docs.zeichnung($0) != nil || docs.fehler[$0] != nil }
                && docs.laedt.isDisjoint(with: ids) }
        }
        return ids.compactMap { docs.zeichnung($0) }.map(Self.exportBlatt)
    }

    static func exportBlatt(_ z: Zeichnung) -> ExportZeichnungsblatt {
        ExportZeichnungsblatt(id: z.id, titel: z.blatt.titel, groesse: z.groesse) { ctx, _ in
            BlattZeichner.zeichneSeite(z, in: ctx)  // die gemeinsame Zeichenfunktion der Blätter (P6-A1)
        }
    }

    /// Isometrische Vorschaubilder einzelner Teile auf weißem Grund (Offscreen-Renderer), zwischengespeichert je Teil
    /// und Formschlüssel. Auch für den Bereich „Material“ (MaterialBildActions); der weiße Grund gilt nur während des
    /// einzelnen Bildes, damit sich zwei Aufrufe, die abwechselnd laufen, nicht den Grund des Viewports verstellen.
    func exportTeilBilder(_ namen: [String], pixel: Int = 260, nachJeweils: Int = 8) async -> [String: CGImage] {
        let store = model.export
        var out: [String: CGImage] = [:]
        let iso = ViewportCoordinator.standardView(protocolName: "iso")!
        var bodies: [ViewportBody]?
        for (i, name) in namen.enumerated() {
            guard let rec = scene.record(name) else { continue }
            if let c = store.bildCache[name], c.digest == rec.digest {
                out[name] = c.bild
                continue
            }
            if bodies == nil { bodies = scene.snapshotBodies(applySection: false) }
            let eigene = bodies!.filter { Self.teilName(ofBody: $0.id) == name }.map { b -> ViewportBody in
                var k = b
                let c = rec.header.colorVector
                k.color = SIMD4(c.x, c.y, c.z, max(c.w, 1))
                return k
            }
            guard !eigene.isEmpty, let b = scene.worldBounds(of: [.part(name)]) else { continue }
            var cam = iso.cameraState(distance: 1000, orthographicScale: 100)
            cam.isOrthographic = true
            cam = ViewportCoordinator.fitted(cam, to: b, aspect: 1, padding: 1.08)
            let alterGrund = screenshots.backgroundColor
            screenshots.backgroundColor = SIMD4(1, 1, 1, 1)
            let r = screenshots.render(bodies: eigene, camera: cam, width: pixel, height: pixel,
                                       displayMode: .shadedWithEdges, lighting: viewport.controller.lightingConfiguration)
            screenshots.backgroundColor = alterGrund
            if let r {
                out[name] = r.image
                store.bildCache[name] = (rec.digest, r.image)
            }
            if i % max(1, nachJeweils) == max(1, nachJeweils) - 1 { await Task.yield() }
        }
        return out
    }

    /// Gesamtansicht für das Deckblatt.
    func exportGesamtBild() -> CGImage? {
        let store = model.export
        let sig = scene.order.reduce(into: Hasher()) { h, n in h.combine(n); h.combine(scene.record(n)?.digest) }
            .finalize()
        if let c = store.gesamtCache, c.signatur == sig { return c.bild }
        guard let b = scene.visibleBounds() else { return nil }
        let iso = ViewportCoordinator.standardView(protocolName: "iso")!
        var cam = iso.cameraState(distance: 1000, orthographicScale: 100)
        cam.isOrthographic = true
        cam = ViewportCoordinator.fitted(cam, to: b, aspect: 1.5, padding: 1.04)
        let bodies = scene.snapshotBodies(applySection: false).map { b -> ViewportBody in
            var k = b
            if let n = Self.teilName(ofBody: b.id), let rec = scene.record(n) {
                let c = rec.header.colorVector
                k.color = SIMD4(c.x, c.y, c.z, k.color.w)
            }
            return k
        }
        let alterGrund = screenshots.backgroundColor
        screenshots.backgroundColor = SIMD4(0.955, 0.957, 0.965, 1)
        defer { screenshots.backgroundColor = alterGrund }
        guard let r = screenshots.render(bodies: bodies, camera: cam, width: 2100, height: 1400,
                                         displayMode: .shadedWithEdges, lighting: viewport.controller.lightingConfiguration)
        else { return nil }
        store.gesamtCache = (sig, r.image)
        return r.image
    }

    // MARK: PDF und Druck

    public func exportPDF(_ v: ExportVorlage, nach url: URL) async throws -> ExportErgebnis {
        let t0 = Date()
        model.export.fehler = nil
        let doc = await exportDokument(v)
        guard !doc.seiten.isEmpty else {
            throw ExportFehler.leer("Keine Seiten: alle gewählten Bausteine sind leer")
        }
        model.export.laeuft = "PDF wird geschrieben"
        defer { model.export.laeuft = nil }
        let tPDF = Date()
        try await Task.detached(priority: .userInitiated) { try doc.schreibePDF(nach: url) }.value
        model.export.phasen["pdf_ms"] = Int(Date().timeIntervalSince(tPDF) * 1000)
        let e = exportErgebnis(doc, pfad: url, t0: t0)
        model.export.letztes = e
        log(.info, "Dokumente exportiert: \(url.path), \(e.seiten) Seiten, \(e.ms) ms "
            + "(\(e.phasen.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")))")
        for h in doc.hinweise { log(.info, "Export: \(h)") }
        return e
    }

    public func exportDrucken(_ v: ExportVorlage) async throws -> ExportErgebnis {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KevCAD-Druck-\(UUID().uuidString).pdf")
        var e = try await exportPDF(v, nach: url)
        guard let pdf = PDFDocument(url: url) else { throw ExportFehler.pdf("Druck: PDF nicht lesbar") }
        let fenster = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        let titel = model.project?.name ?? "SK-CAD"
        ExportDrucker.drucke(pdf, titel: titel, fenster: fenster) { [weak self] n in
            try? FileManager.default.removeItem(at: url)
            self?.log(.info, "Druck: \(n) Aufträge abgeschickt")
        }
        let auftraege = ExportDrucker.auftraege(pdf)
        e.pfad = nil
        e.gedruckt = auftraege.count > 1 ? "Druckdialog geöffnet (\(auftraege.count) Aufträge, je Format einer)"
            : "Druckdialog geöffnet"
        if let h = ExportDrucker.hinweis(auftraege) { e.hinweise.append(h) }
        model.export.letztes = e
        return e
    }

    func exportErgebnis(_ doc: ExportDokument, pfad: URL?, t0: Date) -> ExportErgebnis {
        ExportErgebnis(
            pfad: pfad, seiten: doc.seiten.count, bausteine: doc.bausteinSeiten.map { ($0.art, $0.anzahl) },
            formate: doc.formate, hinweise: doc.hinweise, ms: Int(Date().timeIntervalSince(t0) * 1000),
            phasen: model.export.phasen)
    }

    // MARK: Anfrage des Kernels

    func handleDokumentExport(_ a: DokumentExportAnfrage) {
        exportVorlagenLaden()
        let (vorlage, hinweise) = a.vorlage(aus: model.export.vorlagen)
        Task { @MainActor in
            do {
                var e: ExportErgebnis
                if let ziel = a.ziel {
                    e = try await exportPDF(vorlage, nach: ziel)
                    if a.drucken, let pdf = PDFDocument(url: ziel) {
                        let fenster = NSApp.keyWindow ?? NSApp.mainWindow
                        ExportDrucker.drucke(pdf, titel: model.project?.name ?? "SK-CAD", fenster: fenster)
                        let n = ExportDrucker.auftraege(pdf).count
                        e.gedruckt = n > 1 ? "Druckdialog geöffnet (\(n) Aufträge, je Format einer)" : "Druckdialog geöffnet"
                        if let h = ExportDrucker.hinweis(ExportDrucker.auftraege(pdf)) { e.hinweise.append(h) }
                    }
                } else if a.drucken {
                    e = try await exportDrucken(vorlage)
                } else {
                    throw ExportFehler.leer("Weder Ziel noch Drucken angegeben")
                }
                e.hinweise = hinweise + e.hinweise
                send(DokumentExportAntwortMessage(replyTo: a.id, ergebnis: e))
            } catch {
                let text = (error as? ExportFehler)?.description ?? error.localizedDescription
                model.export.fehler = text
                log(.error, "Export für den Kernel: \(text)")
                send(DokumentExportAntwortMessage(replyTo: a.id, fehler: text))
            }
        }
    }
}
