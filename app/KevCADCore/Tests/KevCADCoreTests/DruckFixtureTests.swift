import Foundation
import XCTest

@testable import KevCADCore

/// Druckvorschau gegen die Testdateien des Kernels (kernel/tools/make_druck_fixtures.py, Abschnitt `druck` in
/// fixtures.json): Kugelschieber mit 2 Materialien, 2 Platten, 4 Gruppen, Slicer halb fertig.
final class DruckFixtureTests: XCTestCase {
    private func erwartet() throws -> JSONValue {
        try XCTUnwrap(try Fixtures.expected()["druck"])
    }

    private func vorschau(_ name: String) throws -> (Druckvorschau, String?) {
        guard case .druck(.vorschau(let v, let r)) = try Fixtures.message(name) else {
            throw NSError(domain: "Druck", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(name) ist kein PRINT_PREVIEW"])
        }
        return (v, r)
    }

    /// Kopf einer Testdatei ohne `seq` (die App setzt ihn beim Senden).
    private func fixtureKopf(_ name: String) throws -> JSONValue {
        var j = try JSONDecoder().decode(JSONValue.self, from: Fixtures.frame(name).header)
        if case .object(var o) = j { o["seq"] = nil; j = .object(o) }
        return j
    }

    private func kopf<M: OutgoingMessage>(_ m: M) throws -> JSONValue {
        var j = try JSONDecoder().decode(JSONValue.self, from: m.encodedHeader())
        if case .object(var o) = j { o["seq"] = nil; j = .object(o) }
        return j
    }

    func testPrintPreviewVoll() throws {
        let e = try XCTUnwrap(try erwartet()["vorschau"])
        let (v, reply) = try vorschau("print_preview.frame")
        XCTAssertNil(reply)
        XCTAssertEqual(v.run, e["run"]?.intValue)
        XCTAssertEqual(v.stand.rawValue, e["stand"]?.stringValue)
        XCTAssertEqual(v.drucker, e["drucker"]?.stringValue)
        XCTAssertEqual(v.summe.platten, e["summe"]?["platten"]?.intValue)
        XCTAssertEqual(v.summe.zeitS, e["summe"]?["zeit_s"]?.doubleValue)
        XCTAssertEqual(v.summe.zeitMitWechselS, e["summe"]?["zeit_mit_wechsel_s"]?.doubleValue)
        XCTAssertEqual(v.summe.kosten, e["summe"]?["kosten"]?.doubleValue)
        XCTAssertEqual(v.summe.kostenFilament, e["kosten_teile"]?["filament"]?.doubleValue)
        XCTAssertEqual(v.summe.kostenStrom, e["kosten_teile"]?["strom"]?.doubleValue)
        XCTAssertEqual(v.summe.kostenRisiko, e["kosten_teile"]?["risiko"]?.doubleValue)
        // Summe der Kostenteile = Kosten (Vertrag)
        let teile = (v.summe.kostenFilament ?? 0) + (v.summe.kostenStrom ?? 0) + (v.summe.kostenRisiko ?? 0)
        XCTAssertEqual(teile, v.summe.kosten ?? 0, accuracy: 0.011)
        let mats = try XCTUnwrap(e["material"]?.arrayValue)
        XCTAssertEqual(v.summe.material.map(\.material), mats.compactMap { $0["material"]?.stringValue })
        for (m, x) in zip(v.summe.material, mats) {
            XCTAssertEqual(m.g, x["g"]?.doubleValue)
            XCTAssertEqual(m.m, x["m"]?.doubleValue)
            XCTAssertEqual(m.kosten, x["kosten"]?.doubleValue)
            XCTAssertEqual(m.stand.rawValue, x["stand"]?.stringValue)
        }
        // Filamentprofil aus den Gruppen
        XCTAssertEqual(v.summe.material.first { $0.material == "pla" }?.filament, "Amazon Basics PLA")
        let platten = try XCTUnwrap(e["platten"]?.arrayValue)
        XCTAssertEqual(v.platten.map(\.nr), platten.compactMap { $0["nr"]?.intValue })
        for (p, x) in zip(v.platten, platten) {
            XCTAssertEqual(p.zeitS, x["zeit_s"]?.doubleValue)
            XCTAssertEqual(p.stand.rawValue, x["stand"]?.stringValue)
            XCTAssertEqual(p.teile.count, x["teile"]?.intValue)
            XCTAssertEqual(p.auslastung, x["auslastung"]?.doubleValue)
            XCTAssertEqual(p.material.first?.material, x["material"]?.stringValue)
            // nichts außerhalb der Platte oder in der Sperrzone
            XCTAssertEqual(DruckPlattenGeometrie.ausserhalb(p, bett: v.bett), [], "Platte \(p.nr)")
        }
        XCTAssertTrue(v.platten[0].vomSlicerAngeordnet)
        XCTAssertEqual(v.platten[0].hoeheMM, 32)
        let erstes = try XCTUnwrap(e["erstes_plattenteil"])
        let t = try XCTUnwrap(v.platten.first?.teile.first)
        XCTAssertEqual(t.name, erstes["name"]?.stringValue)
        XCTAssertEqual(t.gruppe, erstes["gruppe"]?.stringValue)
        XCTAssertEqual(t.x, erstes["x"]?.doubleValue)
        XCTAssertEqual(t.y, erstes["y"]?.doubleValue)
        XCTAssertEqual(t.drehung, erstes["drehung"]?.doubleValue)
        let umriss = (erstes["umriss"]?.arrayValue ?? []).compactMap(\.doubles).map { SIMD2($0[0], $0[1]) }
        XCTAssertEqual(t.plattenUmriss, umriss)  // absolut: bleibt, wie es ist
        // x, y = Mitte des Hüllrechtecks
        let h = try XCTUnwrap(DruckPlattenGeometrie.huelle(t.plattenUmriss))
        XCTAssertEqual(h.x + h.b / 2, t.x, accuracy: 1e-9)
        XCTAssertEqual(h.y + h.t / 2, t.y, accuracy: 1e-9)
        XCTAssertEqual(v.platten.flatMap(\.teile).filter(\.ersatz).map(\.name), e["ersatzteile"]?.stringList)
        // Gruppen
        let gruppen = try XCTUnwrap(e["teile"]?.arrayValue)
        XCTAssertEqual(v.teile.map(\.gruppe), gruppen.compactMap { $0["gruppe"]?.stringValue })
        for (g, x) in zip(v.teile, gruppen) {
            XCTAssertEqual(g.name, x["name"]?.stringValue)
            XCTAssertEqual(g.anzahl, x["anzahl"]?.intValue)
            XCTAssertEqual(g.material, x["material"]?.stringValue)
            XCTAssertEqual(g.zweck, x["zweck"]?.stringValue)
            XCTAssertEqual(g.zweckGeschaetzt, x["zweck_geschaetzt"]?.boolValue)
            XCTAssertEqual(g.g, x["g"]?.doubleValue)
            XCTAssertEqual(g.zeitS, x["zeit_s"]?.doubleValue)
            XCTAssertEqual(g.stand.rawValue, x["stand"]?.stringValue)
            XCTAssertEqual(g.abweichung, x["abweichung"]?.doubleValue)
        }
        let g1 = try XCTUnwrap(v.gruppe("g1"))
        let et = try XCTUnwrap(e["erstes_teil"])
        XCTAssertEqual(g1.einstellungen.json, et["einstellungen"]?.objectValue)
        XCTAssertEqual(g1.einstellungen.waende, 4)
        XCTAssertEqual(g1.einstellungen.fuellung, 0.25)
        XCTAssertEqual(g1.einstellungen.muster, "gyroid")
        XCTAssertEqual(g1.begruendung, et["begruendung"]?.stringList)
        XCTAssertEqual(g1.hinweise.map(\.text), et["hinweise"]?.arrayValue?.compactMap { $0["text"]?.stringValue })
        XCTAssertEqual(g1.jeStueck?.g, et["je_stueck"]?["g"]?.doubleValue)
        XCTAssertEqual(g1.jeStueck?.zeitS, et["je_stueck"]?["zeit_s"]?.doubleValue)
        XCTAssertEqual(g1.grammJe, 35.6)
        XCTAssertEqual(Set(g1.vorgaben.keys), Set(et["fest"]?.stringList ?? []))
        XCTAssertEqual(g1.quelle("waende"), .kevin)
        XCTAssertEqual(g1.profilProzess, "0.20mm Standard @BBL P1P")
        XCTAssertEqual(g1.risiko, 0.04)
        XCTAssertEqual(v.gruppe("g2")?.ampel, .gelb)  // Warnung: Stützen
        XCTAssertEqual(v.gruppe("g4")?.ampel, .gruen)
        // je Platte: Gruppen mit Anzahl (Fangrolle zweimal, eins davon Ersatz)
        XCTAssertEqual(v.platten[0].gruppen.map(\.gruppe), ["g1", "g2", "g3"])
        XCTAssertEqual(v.platten[0].gruppen.map(\.anzahl), [4, 2, 1])
        XCTAssertEqual(v.alleHinweise.first?.hinweis.schwere, .warnung)
        XCTAssertEqual(v.hinweise.map(\.text), e["hinweise"]?.arrayValue?.compactMap { $0["text"]?.stringValue })
        let s = try XCTUnwrap(e["slicer"])
        XCTAssertEqual(v.slicer.zustand.rawValue, s["zustand"]?.stringValue)
        XCTAssertEqual(v.slicer.fertig, s["fertig"]?.intValue)
        XCTAssertEqual(v.slicer.gesamt, s["gesamt"]?.intValue)
        XCTAssertEqual(v.slicer.meldung, s["meldung"]?.stringValue)
        XCTAssertEqual(v.slicer.version, s["version"]?.stringValue)
        XCTAssertEqual(v.projekt?.plattenwechselS, 120)
        XCTAssertEqual(v.projekt?.leistungW, 150)
        XCTAssertFalse(v.regler)
        XCTAssertNotNil(v.ms)
    }

    func testPrintPreviewLeerUndAntwort() throws {
        let e = try erwartet()
        let (leer, _) = try vorschau("print_preview_leer.frame")
        XCTAssertEqual(leer.run, e["leer"]?["run"]?.intValue)
        XCTAssertEqual(leer.summe.platten, e["leer"]?["platten"]?.intValue)
        XCTAssertEqual(leer.slicer.zustand.rawValue, e["leer"]?["slicer"]?.stringValue)
        XCTAssertTrue(leer.istLeer)
        XCTAssertEqual(leer.slicer.meldung, "Keine Druckteile im Modell.")
        let (antwort, reply) = try vorschau("print_preview_antwort.frame")
        XCTAssertEqual(reply, e["antwort"]?["reply_to"]?.stringValue)
        XCTAssertEqual(antwort.slicer.zustand.rawValue, e["antwort"]?["slicer"]?.stringValue)
        XCTAssertEqual(try Fixtures.message("print_preview_antwort.frame").replyTo, "a-31")
    }

    func testPrintExportResUndAck() throws {
        let e = try erwartet()["export"]
        guard case .druck(.exportErgebnis(let ok)) = try Fixtures.message("print_export_res.frame") else {
            return XCTFail("kein PRINT_EXPORT_RES")
        }
        XCTAssertTrue(ok.ok)
        XCTAssertEqual(ok.replyTo, "a-35")
        XCTAssertEqual(ok.pfad?.path, e?["pfad"]?.stringValue)
        XCTAssertEqual(ok.platten, e?["platten"]?.arrayValue?.compactMap(\.intValue))
        XCTAssertEqual(ok.hinweise, ["In Bambu Studio geprüft: 2 Platten, 13 Teile"])
        XCTAssertEqual(ok.geprueft, true)
        XCTAssertEqual(ok.ms, 1840)
        guard case .druck(.exportErgebnis(let f)) = try Fixtures.message("print_export_res_fehler.frame") else {
            return XCTFail()
        }
        XCTAssertFalse(f.ok)
        XCTAssertNil(f.pfad)
        XCTAssertEqual(f.fehler, "Keine Druckteile im Modell.")
        guard case .ack(let a) = try Fixtures.message("ack_print_settings.frame") else { return XCTFail() }
        XCTAssertEqual(a.replyTo, "a-32")
        XCTAssertTrue(a.ok)
        guard case .ack(let b) = try Fixtures.message("ack_print_export.frame") else { return XCTFail() }
        XCTAssertEqual(b.replyTo, "a-35")
    }

    /// Mehrere Materialien: je Material eine Datei (`dateien`, sonst `pfade`); `fest_von` mit Kevin und Agent.
    func testMehrereDateienUndFestVon() throws {
        let kopf = #"""
            {"type":"PRINT_EXPORT_RES","reply_to":"a-9","ok":true,"pfad":"/p/output/K-druck-petg.3mf",
             "pfade":["/p/output/K-druck-petg.3mf","/p/output/K-druck-pla.3mf"],
             "dateien":[{"pfad":"/p/output/K-druck-petg.3mf","material":"petg","filament":"Bambu PETG Basic @BBL X1C","platten":[1]},
                        {"pfad":"/p/output/K-druck-pla.3mf","material":"pla","filament":"Amazon Basics PLA","platten":[2]}],
             "platten":[1,2],"fehler":null,"geprueft":true,"ms":5120,"hinweise":["2 Materialien: je Material ein Bambu-Projekt"]}
            """#
        guard case .druck(.exportErgebnis(let e)) = try KernelMessage.decode(Frame(header: Data(kopf.utf8))) else {
            return XCTFail()
        }
        XCTAssertEqual(e.dateien.map(\.material), ["petg", "pla"])
        XCTAssertEqual(e.dateien.map(\.platten), [[1], [2]])
        XCTAssertEqual(e.dateien.last?.filament, "Amazon Basics PLA")
        XCTAssertEqual(e.dateien.first?.pfad.lastPathComponent, "K-druck-petg.3mf")
        // nur `pfade` bzw. nur `pfad`
        guard case .druck(.exportErgebnis(let f)) = try KernelMessage.decode(Frame(header: Data(
            #"{"type":"PRINT_EXPORT_RES","ok":true,"pfad":"/a.3mf","pfade":["/a.3mf","/b.3mf"],"platten":[1,2]}"#.utf8)))
        else { return XCTFail() }
        XCTAssertEqual(f.dateien.map(\.pfad.path), ["/a.3mf", "/b.3mf"])
        guard case .druck(.exportErgebnis(let g)) = try KernelMessage.decode(Fixtures.frame("print_export_res.frame"))
        else { return XCTFail() }
        XCTAssertEqual(g.dateien.count, 1)
        XCTAssertEqual(g.dateien.first?.platten, [1, 2])

        let teil = #"""
            {"type":"PRINT_PREVIEW","run":3,"einstellungen":{"platte":"Textured PEI Plate","drucker":"p1p-0.4"},
             "teile":[{"gruppe":"g1","name":"Halter (Druck)","teile":["A/Halter (Druck)"],"fest":["waende","fuellung","zweck"],
                       "fest_von":{"waende":"kevin","fuellung":"agent","zweck":"kevin"},"abweichung":0.06,
                       "abweichung_material":-0.02}]}
            """#
        guard case .druck(.vorschau(let v, _)) = try KernelMessage.decode(Frame(header: Data(teil.utf8))) else {
            return XCTFail()
        }
        let g1 = try XCTUnwrap(v.gruppe("g1"))
        XCTAssertEqual(g1.quelle("waende"), .kevin)
        XCTAssertEqual(g1.quelle("fuellung"), .agent)
        XCTAssertEqual(g1.quelle("zweck"), .kevin)
        XCTAssertEqual(g1.abweichungMaterial, -0.02)
        XCTAssertEqual(g1.kurzname, "Halter")
        XCTAssertEqual(v.projekt?.platte, "Textured PEI Plate")
        XCTAssertEqual(DruckFormat.vorgaben(g1.vorgaben), ["Von \(AppInfo.nutzerName): Wände, Zweck", "Vom Agenten: Füllung"])
        XCTAssertEqual(DruckQuelle.agent.titel, "vom Agenten")
    }

    /// Bereich Material: Kennzahlen der Druckteile aus der Vorschau.
    func testMaterialKennzahlenAusVorschau() throws {
        let (v, _) = try vorschau("print_preview.frame")
        var d = MaterialDaten(bom: nil)
        XCTAssertNil(d.kennzahlen.druckZeitS)
        d.druckvorschauEinrechnen(v)
        XCTAssertEqual(d.kennzahlen.druckZeitS, v.summe.zeitMitWechselS)
        XCTAssertEqual(d.kennzahlen.druckPlatten, 2)
        XCTAssertEqual(d.kennzahlen.druckGramm, v.summe.gramm, accuracy: 1e-9)
        XCTAssertEqual(d.kennzahlen.druckPreis, v.summe.kosten)
        XCTAssertEqual(d.kennzahlen.druckteile, v.stueck)
        var leer = MaterialDaten(bom: nil)
        let (l, _) = try vorschau("print_preview_leer.frame")
        leer.druckvorschauEinrechnen(l)
        XCTAssertNil(leer.kennzahlen.druckZeitS)
    }

    /// Die Anfragen der App entsprechen Byte für Byte im Inhalt den Testdateien des Kernels (ohne `seq`).
    func testAnfragenWieTestdateien() throws {
        XCTAssertEqual(try kopf(DruckvorschauAnfrage(id: "a-31")), try fixtureKopf("print_preview_req.frame"))
        let s = try XCTUnwrap(try erwartet()["settings"])
        XCTAssertEqual(try kopf(DruckEinstellenNachricht(id: "a-32", ziel: .gruppe(s["gruppe"]?.stringValue ?? ""),
                                                         einstellungen: s["einstellungen"]?.objectValue)),
                       try fixtureKopf("print_settings.frame"))
        XCTAssertEqual(try kopf(DruckEinstellenNachricht(id: "a-33", ziel: .teil("Kugelschieber/Lenksperre (Druck)"),
                                                         zweck: "tragend")),
                       try fixtureKopf("print_settings_zweck.frame"))
        XCTAssertEqual(try kopf(DruckEinstellenNachricht(id: "a-34", ziel: .gruppe("g1"), einstellungen: ["waende": .null])),
                       try fixtureKopf("print_settings_zurueck.frame"))
        XCTAssertEqual(try kopf(DruckEinstellenNachricht(id: "a-37", ziel: .teil("Kugelschieber/Fangrolle (Druck)"),
                                                         zuruecksetzen: true)),
                       try fixtureKopf("print_settings_reset.frame"))
        XCTAssertEqual(try kopf(DruckExportNachricht(id: "a-35", platten: [],
                                                     ziel: try erwartet()["export"]?["pfad"]?.stringValue)),
                       try fixtureKopf("print_export_req.frame"))
        // additiv: Auswahl der Teile (ohne), Ergebnis mit weggelassen und Objektnamen
        let auswahl = try XCTUnwrap(try erwartet()["export_auswahl"])
        var filament: [String: String] = [:]
        for (k, w) in auswahl["filament"]?.objectValue ?? [:] { filament[k] = w.stringValue }
        XCTAssertEqual(filament, ["petg": "polymaker-polylite-petg-gelb"])
        XCTAssertEqual(try kopf(DruckExportNachricht(id: "a-38", platten: [],
                                                     ziel: try erwartet()["export"]?["pfad"]?.stringValue,
                                                     ohne: auswahl["ohne"]?.stringList ?? [], filament: filament)),
                       try fixtureKopf("print_export_req_auswahl.frame"))
        guard case .druck(.exportErgebnis(let frage)) = try Fixtures.message("print_export_res_frage.frame") else {
            return XCTFail("kein PRINT_EXPORT_RES (Rückfrage)")
        }
        XCTAssertFalse(frage.ok)
        XCTAssertTrue(frage.filamentFrage)
        // Filamentliste und angenommenes Filament der Vorschau (Auswahl im Sichern-Dialog)
        let (v, _) = try vorschau("print_preview.frame")
        let liste = try XCTUnwrap(try erwartet()["filamente"]?.arrayValue)
        XCTAssertEqual(v.filamente.map(\.id), liste.compactMap { $0["id"]?.stringValue })
        XCTAssertEqual(v.filamente(fuer: "petg").map(\.id), ["polymaker-polylite-petg-gelb", "bambu-petg-basic"])
        XCTAssertEqual(v.filamente.first?.preset, "Polymaker PolyLite PETG gelb (Kev CAD)")
        var ids: [String: String] = [:]
        for (k, w) in try erwartet()["material_filament_id"]?.objectValue ?? [:] { ids[k] = w.stringValue }
        XCTAssertEqual(v.filamentVorschlag, ids)
        XCTAssertEqual(v.summe.material.first { $0.material == "petg" }?.filamentQuelle, "zuletzt")
        guard case .druck(.exportErgebnis(let ex)) = try Fixtures.message("print_export_res_auswahl.frame") else {
            return XCTFail("kein PRINT_EXPORT_RES")
        }
        XCTAssertTrue(ex.ok)
        XCTAssertEqual(ex.platten, auswahl["platten"]?.arrayValue?.compactMap(\.intValue))
        XCTAssertEqual(ex.dateien.count, 1)
    }

    /// Ablauf im App-Kern: Einstellung senden (wartet bis zur neuen Vorschau), Vorschau übernehmen, 3MF-Export mit
    /// ACK und PRINT_EXPORT_RES, Projektwechsel leert alles.
    @MainActor
    func testControllerAblauf() throws {
        func nachricht(_ json: String) throws -> IncomingEvent {
            .message(try KernelMessage.decode(Frame(header: Data(json.utf8))))
        }
        let c = AppController(model: AppModel())
        c.handle([.connected])
        c.handle([.message(try Fixtures.message("hello.frame"))])
        let m = c.model
        XCTAssertNil(m.druck.vorschau)
        c.druckEinstellen(.gruppe("g1"), einstellungen: ["waende": 5, "fuellung": 0.3], zweck: nil)  // a-1
        XCTAssertTrue(m.druck.wartet(.gruppe("g1")))
        c.handle([try nachricht(#"{"type":"ACK","reply_to":"a-1","ok":true,"message":"Wände 5"}"#)])
        XCTAssertTrue(m.druck.wartet(.gruppe("g1")), "wartet bis zur neuen Vorschau")
        c.handle([.message(try Fixtures.message("print_preview.frame"))])
        XCTAssertEqual(m.druck.vorschau?.run, 12)
        XCTAssertFalse(m.druck.wartet(.gruppe("g1")))
        // abgelehnt: Fehler, nicht mehr wartend
        c.druckEinstellen(.teil("X"), einstellungen: ["waende": 99], zweck: nil)  // a-2
        c.handle([try nachricht(#"{"type":"ACK","reply_to":"a-2","ok":false,"message":"waende: 1 bis 12"}"#)])
        XCTAssertEqual(m.druck.fehler, "waende: 1 bis 12")
        XCTAssertFalse(m.druck.wartet(.teil("X")))
        // Export: ACK, dann das Ergebnis
        c.druckExportieren(platten: [], nach: nil)  // a-3
        XCTAssertEqual(m.druck.export, .laeuft(ziel: nil))
        c.handle([try nachricht(#"{"type":"ACK","reply_to":"a-3","ok":true,"message":"3MF wird geschrieben"}"#)])
        XCTAssertEqual(m.druck.export, .laeuft(ziel: nil))
        c.handle([try nachricht(#"""
            {"type":"PRINT_EXPORT_RES","reply_to":"a-3","ok":true,"pfad":"/tmp/K/output/K-druck.3mf","platten":[1,2],
             "fehler":null,"geprueft":true}
            """#)])
        guard case .fertig(let e) = m.druck.export else { return XCTFail("Export nicht fertig: \(m.druck.export)") }
        XCTAssertEqual(e.pfad?.lastPathComponent, "K-druck.3mf")
        XCTAssertEqual(e.geprueft, true)
        // Fehler beim Export
        c.druckExportieren(platten: [2], nach: URL(fileURLWithPath: "/tmp/K/p2.3mf"))  // a-4
        c.handle([try nachricht(#"{"type":"PRINT_EXPORT_RES","reply_to":"a-4","ok":false,"pfad":null,"platten":[],"fehler":"Keine Druckteile im Modell."}"#)])
        XCTAssertEqual(m.druck.export, .fehler("Keine Druckteile im Modell."))
        // Projektwechsel
        c.handle([try nachricht(#"{"type":"PROJECT","path":"/tmp/anderes","name":"anderes"}"#)])
        XCTAssertNil(m.druck.vorschau)
        XCTAssertEqual(m.druck.export, .bereit)
    }

    /// Bericht und Plattenansicht mit dem echten Beispiel.
    func testBerichtMitBeispiel() throws {
        let (v, _) = try vorschau("print_preview.frame")
        let q = ExportQuellen(kopf: ExportKopf(projekt: "Kugelschieber"), druck: v)
        let doc = ExportBauer.dokument(ExportVorlage(name: "x", bausteine: [ExportBausteinWahl(art: .druck)]), q)
        XCTAssertGreaterThanOrEqual(doc.seiten.count, 1)
        XCTAssertTrue(doc.hinweise.isEmpty)
        let t = ExportDruckSeiten.teileTabelle(v.platten[0], v, spalten: ExportBausteinWahl(art: .druck).wirksameSpalten,
                                               nummern: ["g1": 1, "g2": 2, "g3": 3, "g4": 4])
        XCTAssertEqual(t.zeilen.count, 4)  // drei Gruppen und Summe
        XCTAssertEqual(t.zeilen[1].zellen["anzahl"]?.text, "2")  // Fangrolle mit Ersatz
        XCTAssertEqual(t.zeilen[1].zellen["stuetzen"]?.text, "Baum")
        XCTAssertEqual(t.zeilen[0].zellen["zeit"]?.text, DruckFormat.zeit(19920))
        if let ausgabe = ProcessInfo.processInfo.environment["KEVCAD_TEST_AUSGABE"] {
            let url = URL(fileURLWithPath: ausgabe).appendingPathComponent("druck-bericht-beispiel.pdf")
            try doc.schreibePDF(nach: url)
        }
    }
}
