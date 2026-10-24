import CoreGraphics
import Foundation
import PDFKit
import XCTest

@testable import KevCADCore

/// Druckvorschau (DRUCKVORSCHAU.md): Decoder und Encoder, Formate, Plattenansicht (Maßstab, Sperrzone), Store
/// (Wechsel Schätzung → Slicer) und Bericht-Baustein „3D-Druck“. Beispieldaten nach dem Vertrag.
final class DruckTests: XCTestCase {
    /// PRINT_PREVIEW wie im Vertrag: Kugelschieber mit vier Stangenhaltern und zwei Schlitten, zwei Platten.
    static func beispielKopf(stand: String = "schaetzung", zeitFaktor: Double = 1, run: Int = 12) -> [String: Any] {
        func umriss(_ x: Double, _ y: Double, _ b: Double, _ t: Double) -> [[Double]] {
            [[x, y], [x + b, y], [x + b, y + t], [x, y + t]]
        }
        return [
            "type": "PRINT_PREVIEW", "seq": 7, "run": run, "stand": stand, "drucker": "Bambu Lab P1P 0.4",
            "summe": [
                "platten": 2, "zeit_s": 61200 * zeitFaktor, "zeit_mit_wechsel_s": 61200 * zeitFaktor + 120,
                "kosten": 9.85, "kosten_teile": ["filament": 8.12, "strom": 1.73],
                "material": [["material": "petg", "name": "PETG", "g": 812.4, "m": 268.7, "kosten": 8.12,
                              "preis_kg": 10.0, "preis_stand": "2026-10", "stand": stand]],
            ],
            "platten": [
                ["nr": 1, "zeit_s": 22100 * zeitFaktor, "material": [["material": "petg", "g": 301.0]], "stand": stand,
                 "teile": [
                    ["name": "Kugelschieber/Stangenhalter vorn links (Druck)", "gruppe": "g3", "x": 40.0, "y": 52.0,
                     "drehung": 90, "umriss": umriss(20, 40, 40, 24)],
                    ["name": "Kugelschieber/Stangenhalter vorn rechts (Druck)", "gruppe": "g3", "x": 100.0, "y": 52.0,
                     "drehung": 90, "umriss": umriss(80, 40, 40, 24)],
                 ], "auslastung": 0.62],
                ["nr": 2, "zeit_s": 39100 * zeitFaktor, "material": [["material": "petg", "g": 511.4]], "stand": stand,
                 "teile": [
                    ["name": "Kugelschieber/Schlitten (Druck)", "gruppe": "g5", "x": 128.0, "y": 128.0, "drehung": 0,
                     "umriss": [[-30.0, -20.0], [30.0, -20.0], [30.0, 20.0], [-30.0, 20.0]]],
                 ]],
            ],
            "teile": [
                ["gruppe": "g3", "name": "Stangenhalter (Druck)",
                 "teile": ["Kugelschieber/Stangenhalter vorn links (Druck)", "Kugelschieber/Stangenhalter vorn rechts (Druck)"],
                 "anzahl": 2, "material": "petg", "zweck": "tragend", "zweck_geschaetzt": false, "g": 143.4, "m": 47.4,
                 "zeit_s": 5400 * zeitFaktor, "stand": stand, "abweichung": 0.06,
                 "einstellungen": ["schicht_mm": 0.2, "waende": 4, "decken": 5, "boeden": 4, "fuellung": 0.25,
                                   "muster": "gyroid", "stuetzen": "keine", "brim": false,
                                   "ausrichtung": "liegend, Bohrung waagrecht"],
                 "begruendung": ["tragend: 4 Wände, 25 % Gyroid", "Last längs der Schichten"],
                 "hinweise": [["schwere": "hinweis", "text": "PETG vorher trocknen (65 °C, 4 h)", "art": "trocknen"]],
                 "vorgaben": ["waende": "kevin"]],
                ["gruppe": "g5", "name": "Kugelschieber/Schlitten (Druck)", "teile": ["Kugelschieber/Schlitten (Druck)"],
                 "anzahl": 1, "material": "petg", "zweck": "bewegt", "zweck_geschaetzt": true, "g": 511.4,
                 "zeit_s": 39100 * zeitFaktor, "stand": stand,
                 "einstellungen": ["schicht_mm": 0.16, "waende": 3, "fuellung": 15, "muster": "grid", "stuetzen": "baum",
                                   "brim": true],
                 "begruendung": "bewegt: glatte Laufflächen",
                 "hinweise": [["schwere": "warnung", "text": "Braucht Stützen unter der Lasche", "art": "stuetzen"]]],
            ],
            "hinweise": [["schwere": "warnung", "text": "ABS auf offenem Drucker verzieht sich", "art": "material"]],
            "slicer": ["zustand": "rechnet", "fertig": 1, "gesamt": 2, "meldung": NSNull()],
        ]
    }

    static func frame(_ kopf: [String: Any]) throws -> Frame {
        Frame(header: try JSONSerialization.data(withJSONObject: kopf), payload: Data())
    }

    static func vorschau(stand: String = "schaetzung", zeitFaktor: Double = 1, run: Int = 12) throws -> Druckvorschau {
        guard case .druck(.vorschau(let v, _)) = try KernelMessage.decode(
            frame(beispielKopf(stand: stand, zeitFaktor: zeitFaktor, run: run)))
        else { throw NSError(domain: "Druck", code: 1) }
        return v
    }

    private func kopf<M: OutgoingMessage>(_ m: M) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: m.encodedHeader())
    }

    // MARK: Decoder

    func testPrintPreviewDecoder() throws {
        let m = try KernelMessage.decode(Self.frame(Self.beispielKopf()))
        XCTAssertEqual(m.typeName, "PRINT_PREVIEW")
        guard case .druck(.vorschau(let v, let reply)) = m else { return XCTFail("kein PRINT_PREVIEW") }
        XCTAssertNil(reply)
        XCTAssertEqual(v.run, 12)
        XCTAssertEqual(v.stand, .schaetzung)
        XCTAssertEqual(v.drucker, "Bambu Lab P1P 0.4")
        XCTAssertEqual(v.summe.platten, 2)
        XCTAssertEqual(v.summe.zeitMitWechselS, 61320)
        XCTAssertEqual(v.summe.wechselS, 120)
        XCTAssertEqual(v.summe.kosten, 9.85)
        XCTAssertEqual(v.summe.kostenStrom, 1.73)
        XCTAssertEqual(v.summe.material.first?.name, "PETG")
        XCTAssertEqual(v.summe.material.first?.preisStand, "2026-10")
        XCTAssertEqual(v.summe.gramm, 812.4, accuracy: 1e-9)
        XCTAssertEqual(v.platten.map(\.nr), [1, 2])
        XCTAssertEqual(v.platten[0].teile.count, 2)
        XCTAssertEqual(v.platten[0].auslastung, 0.62)
        XCTAssertEqual(v.platten[0].gruppen.map(\.gruppe), ["g3"])
        XCTAssertEqual(v.platten[0].gruppen.map(\.anzahl), [2])
        let g3 = try XCTUnwrap(v.gruppe("g3"))
        XCTAssertEqual(g3.kurzname, "Stangenhalter")
        XCTAssertEqual(g3.anzahl, 2)
        XCTAssertEqual(g3.einstellungen.waende, 4)
        XCTAssertEqual(g3.einstellungen.fuellung, 0.25)
        XCTAssertEqual(g3.einstellungen.stuetzen, "keine")
        XCTAssertEqual(g3.einstellungen.brim, false)
        XCTAssertEqual(g3.einstellungen.ausrichtung, "liegend, Bohrung waagrecht")
        XCTAssertEqual(g3.quelle("waende"), .kevin)
        XCTAssertNil(g3.quelle("fuellung"))
        XCTAssertEqual(g3.ampel, .gruen)
        XCTAssertEqual(g3.abweichung, 0.06)
        let g5 = try XCTUnwrap(v.gruppe(vonTeil: "Kugelschieber/Schlitten (Druck)"))
        XCTAssertEqual(g5.gruppe, "g5")
        XCTAssertEqual(g5.einstellungen.fuellung, 0.15)  // 15 gilt als Prozent
        XCTAssertEqual(g5.begruendung, ["bewegt: glatte Laufflächen"])  // Text statt Liste
        XCTAssertTrue(g5.zweckGeschaetzt)
        XCTAssertEqual(g5.ampel, .gelb)
        XCTAssertEqual(v.ampel, .gelb)
        XCTAssertEqual(v.slicer.zustand, .rechnet)
        XCTAssertEqual(v.slicer.anteil, 0.5)
        XCTAssertTrue(v.slicer.laeuft)
        XCTAssertEqual(v.platte(vonTeil: "Kugelschieber/Schlitten (Druck)")?.nr, 2)
        XCTAssertEqual(v.stueck, 3)
        XCTAssertEqual(v.bett, .p1p)
        // Hinweise: Warnungen vor Hinweisen, mit den betroffenen Gruppen
        let alle = v.alleHinweise
        XCTAssertEqual(alle.map(\.hinweis.schwere), [.warnung, .warnung, .hinweis])
        XCTAssertEqual(alle.first { $0.hinweis.art == "stuetzen" }?.gruppen, ["g5"])
    }

    func testPrintPreviewTolerant() throws {
        // fast leer, unbekannte Felder, falsche Typen, Vorschau unter „druckvorschau“ (wie MCP), Vorgaben als Liste
        let kopf: [String: Any] = [
            "type": "PRINT_PREVIEW", "reply_to": "a-3", "unbekannt": 1,
            "druckvorschau": ["run": "x", "stand": "irgendwas", "platten": [["teile": [["name": "A"]]]],
                              "teile": [["teile": ["A"], "vorgaben": ["fuellung", "zweck"], "hinweise": ["Nur Text", 3]]],
                              "slicer": ["zustand": "neu"]],
        ]
        guard case .druck(.vorschau(let v, let reply)) = try KernelMessage.decode(Self.frame(kopf)) else {
            return XCTFail()
        }
        XCTAssertEqual(reply, "a-3")
        XCTAssertEqual(v.stand, .schaetzung)
        XCTAssertEqual(v.run, 0)
        XCTAssertEqual(v.summe.platten, 1)  // aus der Plattenliste
        XCTAssertEqual(v.platten.first?.nr, 1)
        XCTAssertEqual(v.teile.first?.gruppe, "A")
        XCTAssertEqual(v.teile.first?.vorgaben, ["fuellung": .kevin, "zweck": .kevin])
        XCTAssertEqual(v.teile.first?.hinweise.map(\.text), ["Nur Text"])
        XCTAssertEqual(v.slicer.zustand, .unbekannt)
        // ein Teil ohne Umriss bekommt ein kleines Quadrat um seine Lage
        XCTAssertEqual(v.platten.first?.teile.first?.plattenUmriss.count, 4)
    }

    func testPrintExportResDecoder() throws {
        let kopf: [String: Any] = ["type": "PRINT_EXPORT_RES", "reply_to": "a-9", "ok": true,
                                   "pfad": "/tmp/K/output/K-platten.3mf", "platten": [1, 2], "fehler": NSNull()]
        let m = try KernelMessage.decode(Self.frame(kopf))
        XCTAssertEqual(m.typeName, "PRINT_EXPORT_RES")
        XCTAssertEqual(m.replyTo, "a-9")
        guard case .druck(.exportErgebnis(let e)) = m else { return XCTFail() }
        XCTAssertTrue(e.ok)
        XCTAssertEqual(e.pfad?.path, "/tmp/K/output/K-platten.3mf")
        XCTAssertEqual(e.platten, [1, 2])
        XCTAssertNil(e.fehler)
        guard case .druck(.exportErgebnis(let f)) = try KernelMessage.decode(Self.frame(
            ["type": "PRINT_EXPORT_RES", "reply_to": "a-10", "fehler": "Bambu Studio fehlt", "platten": 3]))
        else { return XCTFail() }
        XCTAssertFalse(f.ok)
        XCTAssertEqual(f.platten, [1, 2, 3])
        XCTAssertEqual(f.fehler, "Bambu Studio fehlt")
    }

    // MARK: Encoder

    func testEncoder() throws {
        let req = try kopf(DruckvorschauAnfrage(id: "a-1"))
        XCTAssertEqual(req["type"]?.stringValue, "PRINT_PREVIEW_REQ")
        XCTAssertEqual(req["id"]?.stringValue, "a-1")
        XCTAssertEqual(req["seq"]?.intValue, 0)

        let s = try kopf(DruckEinstellenNachricht(id: "a-2", ziel: .gruppe("g3"),
                                                  einstellungen: ["waende": 4, "fuellung": 0.3, "brim": .null]))
        XCTAssertEqual(s["type"]?.stringValue, "PRINT_SETTINGS")
        XCTAssertEqual(s["gruppe"]?.stringValue, "g3")
        XCTAssertNil(s["teil"])
        XCTAssertEqual(s["einstellungen"]?["waende"]?.intValue, 4)
        XCTAssertEqual(s["einstellungen"]?["fuellung"]?.doubleValue, 0.3)
        XCTAssertEqual(s["einstellungen"]?["brim"], .null)  // zurücksetzen
        XCTAssertNil(s["zweck"])  // unverändert: Schlüssel fehlt
        XCTAssertNil(s["von"])
        XCTAssertNil(s["zuruecksetzen"])
        let sv = try kopf(DruckEinstellenNachricht(id: "a-2", ziel: .gruppe("g3"), zuruecksetzen: true, von: "kevin"))
        XCTAssertEqual(sv["von"]?.stringValue, "kevin")
        XCTAssertEqual(sv["zuruecksetzen"]?.boolValue, true)
        XCTAssertNil(sv["einstellungen"])

        let z = try kopf(DruckEinstellenNachricht(id: "a-3", ziel: .teil("Halter/Lasche"), zweck: "tragend"))
        XCTAssertEqual(z["teil"]?.stringValue, "Halter/Lasche")
        XCTAssertNil(z["gruppe"])
        XCTAssertNil(z["einstellungen"])
        XCTAssertEqual(z["zweck"]?.stringValue, "tragend")
        let zr = try kopf(DruckEinstellenNachricht(id: "a-4", ziel: .gruppe("g3"), zweck: .null))
        XCTAssertEqual(zr["zweck"], .null)

        let e = try kopf(DruckExportNachricht(id: "a-5", platten: [], ziel: "/tmp/K/output/K-platten.3mf"))
        XCTAssertEqual(e["type"]?.stringValue, "PRINT_EXPORT_REQ")
        XCTAssertEqual(e["platten"]?.arrayValue?.count, 0)
        XCTAssertEqual(e["ziel"]?.stringValue, "/tmp/K/output/K-platten.3mf")
        XCTAssertEqual(try kopf(DruckExportNachricht(id: "a-6", platten: [2], ziel: "/x.3mf"))["platten"]?.arrayValue?
            .compactMap(\.intValue), [2])
        XCTAssertEqual(try kopf(DruckExportNachricht(id: "a-7", platten: [], ziel: nil))["ziel"], .null)
    }

    /// Zurücksetzen: Schlüssel als null, Zweck getrennt.
    @MainActor
    func testZuruecksetzen() {
        final class Aufnahme: DruckActions {
            var gesendet: [(DruckZiel, [String: JSONValue]?, JSONValue?, Bool)] = []
            func druckvorschauAnfordern() {}
            func druckEinstellen(_ ziel: DruckZiel, einstellungen: [String: JSONValue]?, zweck: JSONValue?,
                                 zuruecksetzen: Bool)
            {
                gesendet.append((ziel, einstellungen, zweck, zuruecksetzen))
            }
            func druckExportieren(platten: [Int], nach ziel: URL?) {}
            func druckInBambuStudioOeffnen(_ datei: URL) {}
            func druckTeileWaehlen(_ teile: [String], einpassen: Bool) {}
        }
        let a = Aufnahme()
        a.druckZuruecksetzen(.gruppe("g3"), schluessel: ["waende", "zweck"])
        XCTAssertEqual(a.gesendet.first?.0, .gruppe("g3"))
        XCTAssertEqual(a.gesendet.first?.1, ["waende": .null])
        XCTAssertEqual(a.gesendet.first?.2, .null)
        XCTAssertEqual(a.gesendet.first?.3, false)
        a.druckZuruecksetzen(.gruppe("g3"), schluessel: ["fuellung"])
        XCTAssertNil(a.gesendet.last?.2)
        a.druckZuruecksetzen(.teil("T"), schluessel: [])  // alles: zuruecksetzen
        XCTAssertEqual(a.gesendet.last?.3, true)
        XCTAssertNil(a.gesendet.last?.1)
        a.druckEinstellen(.gruppe("g1"), einstellungen: ["waende": 5], zweck: nil)
        XCTAssertEqual(a.gesendet.last?.3, false)
        XCTAssertEqual(AppController.druckBeschreibung(einstellungen: ["waende": 4, "fuellung": 0.25, "brim": .null],
                                                       zweck: "tragend"),
                       "Zweck Tragend, Brim zurückgesetzt, Füllung 25 %, Wände 4")
    }

    // MARK: Formate

    func testFormate() {
        XCTAssertEqual(DruckFormat.zeit(22080), "6 h 8 min")
        XCTAssertEqual(DruckFormat.zeit(2700), "45 min")
        XCTAssertEqual(DruckFormat.zeit(7200), "2 h")
        XCTAssertEqual(DruckFormat.zeit(20), "< 1 min")
        XCTAssertEqual(DruckFormat.zeit(0), "0 min")
        XCTAssertEqual(DruckFormat.zeit(61440), "17 h 4 min")
        XCTAssertEqual(DruckFormat.zeit(90000), "25 h")
        XCTAssertEqual(DruckFormat.gramm(812.4), "812 g")
        XCTAssertEqual(DruckFormat.gramm(4.23), "4,2 g")
        XCTAssertEqual(DruckFormat.gramm(1234), "1,23 kg")
        XCTAssertEqual(DruckFormat.gramm(999.7), "1,00 kg")
        XCTAssertEqual(DruckFormat.meter(268.7), "268,7 m")
        XCTAssertEqual(DruckFormat.meter(3.254), "3,25 m")
        XCTAssertEqual(DruckFormat.meter(1520.4), "1.520 m")
        XCTAssertEqual(DruckFormat.euro(9.85), "9,85 €")
        XCTAssertEqual(DruckFormat.prozent(0.25), "25 %")
        XCTAssertEqual(DruckFormat.prozent(0.075), "7,5 %")
        XCTAssertEqual(DruckFormat.prozent(0.62), "62 %")
        XCTAssertEqual(DruckFormat.aenderung(0.118), "+12 %")
        XCTAssertEqual(DruckFormat.aenderung(-0.03), "−3 %")
        XCTAssertEqual(DruckFormat.aenderung(0.001), "±0 %")
        XCTAssertEqual(DruckFormat.schicht(0.2), "0,2 mm")
        XCTAssertEqual(DruckFormat.schicht(0.16), "0,16 mm")
        XCTAssertEqual(DruckFormat.zweck("aussen"), "Außen")
        XCTAssertEqual(DruckFormat.muster("gyroid"), "Gyroid")
        XCTAssertEqual(DruckFormat.muster("zigzag"), "Zickzack")
        XCTAssertEqual(DruckFormat.muster("rectilinear"), "Geradlinig")
        XCTAssertEqual(DruckFormat.stuetzen("tree(auto)"), "Baum")
        let e = DruckEinstellungen(waende: 4, fuellung: 0.25, muster: "gyroid", stuetzen: "baum", brim: true)
        XCTAssertEqual(DruckFormat.kurz(e), "4 Wände · 25 % Gyroid · Baumstützen · Brim")
        XCTAssertEqual(DruckFormat.waende(1), "1 Wand")
    }

    // MARK: Plattenansicht

    func testPlattenGeometrieMassstabUndSperrzone() {
        // 300 × 200 Punkte, 10 Punkte Rand: die Höhe begrenzt, 180 / 256 Punkte je mm, mittig
        let g = DruckPlattenGeometrie(in: CGRect(x: 0, y: 0, width: 300, height: 200), rand: 10)
        XCTAssertEqual(g.massstab, 180 / 256, accuracy: 1e-9)
        XCTAssertEqual(g.platte.width, 180, accuracy: 1e-9)
        XCTAssertEqual(g.platte.height, 180, accuracy: 1e-9)
        XCTAssertEqual(g.platte.midX, 150, accuracy: 1e-9)
        XCTAssertEqual(g.platte.midY, 100, accuracy: 1e-9)
        // Ursprung vorn links = unten links der Draufsicht, hinten rechts = oben rechts
        XCTAssertEqual(g.punkt(SIMD2(0, 0)), CGPoint(x: g.platte.minX, y: g.platte.maxY))
        XCTAssertEqual(g.punkt(SIMD2(256, 256)).x, g.platte.maxX, accuracy: 1e-9)
        XCTAssertEqual(g.punkt(SIMD2(256, 256)).y, g.platte.minY, accuracy: 1e-9)
        let r = g.mm(g.punkt(SIMD2(40, 52)))
        XCTAssertEqual(r.x, 40, accuracy: 1e-9)
        XCTAssertEqual(r.y, 52, accuracy: 1e-9)
        // Sperrzone vorn links, 18 × 28 mm, unten links in der Ansicht
        let s = try! XCTUnwrap(g.sperrzonen.first)
        XCTAssertEqual(s.minX, g.platte.minX, accuracy: 1e-9)
        XCTAssertEqual(s.maxY, g.platte.maxY, accuracy: 1e-9)
        XCTAssertEqual(s.width, 18 * g.massstab, accuracy: 1e-9)
        XCTAssertEqual(s.height, 28 * g.massstab, accuracy: 1e-9)
        XCTAssertEqual(g.gitter(schritt: 50).x, [50, 100, 150, 200, 250])
        // Bett aus dem optionalen Feld
        let b = DruckBett(json: ["breite": 180, "tiefe": 180, "sperrzonen": [[0, 0, 10, 10]]])
        XCTAssertEqual(b.sperrzonen, [DruckRechteck(x: 0, y: 0, b: 10, t: 10)])
        XCTAssertEqual(DruckBett(json: nil), .p1p)
    }

    func testUmrissTrefferUndAuslastung() throws {
        let v = try Self.vorschau()
        // Platte 2: Umriss um den Ursprung → um (128, 128) verschoben
        let schlitten = try XCTUnwrap(v.platten[1].teile.first)
        let u = schlitten.plattenUmriss
        XCTAssertEqual(u.first?.x ?? 0, 98, accuracy: 1e-9)
        XCTAssertEqual(u.first?.y ?? 0, 108, accuracy: 1e-9)
        XCTAssertEqual(schlitten.mitte.x, 128, accuracy: 1e-9)
        // Drehung um 90° bei örtlichem Umriss
        let gedreht = DruckPlattenTeil(name: "x", x: 50, y: 50, drehung: 90,
                                       umriss: [SIMD2(-10, -5), SIMD2(10, -5), SIMD2(10, 5), SIMD2(-10, 5)])
        let h = try XCTUnwrap(DruckPlattenGeometrie.huelle(gedreht.plattenUmriss))
        XCTAssertEqual(h.b, 10, accuracy: 1e-9)
        XCTAssertEqual(h.t, 20, accuracy: 1e-9)
        // Platte 1: Umriss schon auf der Platte → bleibt
        XCTAssertEqual(v.platten[0].teile[0].plattenUmriss.first, SIMD2(20, 40))
        // Treffer: Punkt im Halter links, knapp daneben, weit weg
        let g = DruckPlattenGeometrie(in: CGRect(x: 0, y: 0, width: 256, height: 256))
        XCTAssertEqual(g.treffer(v.platten[0].teile, bei: g.punkt(SIMD2(30, 50)))?.name,
                       "Kugelschieber/Stangenhalter vorn links (Druck)")
        XCTAssertEqual(g.treffer(v.platten[0].teile, bei: g.punkt(SIMD2(62, 50)), toleranz: 3)?.name,
                       "Kugelschieber/Stangenhalter vorn links (Druck)")
        XCTAssertNil(g.treffer(v.platten[0].teile, bei: g.punkt(SIMD2(200, 200))))
        XCTAssertEqual(DruckPlattenGeometrie.flaeche(v.platten[0].teile[0].plattenUmriss), 960, accuracy: 1e-9)
        XCTAssertEqual(DruckPlattenGeometrie.auslastung(v.platten[0]), 0.62)
        let frei = 256.0 * 256 - 18 * 28
        XCTAssertEqual(DruckPlattenGeometrie.auslastung(v.platten[1]), 2400 / frei, accuracy: 1e-9)
        // Prüfung der Anordnung: nichts in der Sperrzone; ein Teil vorn links schon
        XCTAssertEqual(DruckPlattenGeometrie.ausserhalb(v.platten[0]), [])
        let falsch = DruckPlatte(nr: 9, teile: [DruckPlattenTeil(name: "zu weit vorn", x: 10, y: 10, umriss: [
            SIMD2(2, 2), SIMD2(30, 2), SIMD2(30, 20), SIMD2(2, 20)])])
        XCTAssertEqual(DruckPlattenGeometrie.ausserhalb(falsch), ["zu weit vorn"])
    }

    // MARK: Store

    @MainActor
    func testStoreWechselSchaetzungZuSlicer() throws {
        let store = DruckStore()
        let schaetzung = try Self.vorschau()
        store.uebernehmen(schaetzung)
        XCTAssertNil(store.aenderung)
        store.uebernehmen(try Self.vorschau(stand: "gemischt", zeitFaktor: 1.05))
        XCTAssertNil(store.aenderung)  // erst wenn alles gerechnet ist
        store.uebernehmen(try Self.vorschau(stand: "slicer", zeitFaktor: 1.12))
        let a = try XCTUnwrap(store.aenderung)
        XCTAssertEqual(a.run, 12)
        let zeit = try XCTUnwrap(a.werte.first { $0.titel == "Druckzeit" })
        XCTAssertEqual(zeit.relativ ?? 0, (61200 * 1.12 + 120 - 61320) / 61320, accuracy: 1e-9)
        XCTAssertEqual(zeit.zeile, "Druckzeit 17 h 2 min → 19 h 4 min (+12 %)")
        XCTAssertEqual(a.kurz, "Druckzeit +12 %, Filament ±0 %, Kosten ±0 %")
        XCTAssertEqual(a.urteil, "Die Schätzung lag etwas daneben")
        XCTAssertEqual(Set(a.teile.map(\.name)), ["Stangenhalter", "Schlitten"])
        XCTAssertEqual(a.teile.first?.relativ ?? 0, 0.12, accuracy: 1e-9)
        // gleicher Lauf, noch einmal Slicer: kein neuer Vergleich, der Hinweis bleibt
        store.uebernehmen(try Self.vorschau(stand: "slicer", zeitFaktor: 1.12))
        XCTAssertEqual(store.aenderung, a)
        // neuer Lauf: Hinweis weg; erste Vorschau gleich vom Slicer (Zwischenspeicher): kein Vergleich
        store.uebernehmen(try Self.vorschau(stand: "slicer", run: 13))
        XCTAssertNil(store.aenderung)
        XCTAssertNil(store.schaetzungDesLaufs)
        store.leeren()
        XCTAssertNil(store.vorschau)
    }

    // MARK: Bericht

    func testBerichtBausteinDruck() throws {
        let v = try Self.vorschau(stand: "slicer")
        let q = ExportQuellen(kopf: ExportKopf(projekt: "Kugelschieber", version: "V7"), druck: v)
        var vorlage = ExportVorlage(name: "Druck", bausteine: [ExportBausteinWahl(art: .deckblatt), ExportBausteinWahl(art: .druck)])
        let doc = ExportBauer.dokument(vorlage, q)
        let seiten = doc.seiten.filter { $0.baustein == .druck }
        XCTAssertFalse(seiten.isEmpty)
        XCTAssertEqual(seiten.first?.titel, "3D-Druck")
        XCTAssertEqual(Array(doc.seiten.flatMap(\.gliederung).filter { $0.hasPrefix("Platte") }), ["Platte 1", "Platte 2"])
        // Tabelle je Platte: Gruppen mit Anzahl auf dieser Platte und anteiliger Zeit
        let t = ExportDruckSeiten.teileTabelle(v.platten[0], v, spalten: ExportBausteinWahl(art: .druck).wirksameSpalten,
                                               nummern: ["g3": 1, "g5": 2])
        XCTAssertEqual(t.zeilen.count, 2)  // g3 und Summe
        XCTAssertEqual(t.zeilen[0].zellen["teil"]?.text, "Stangenhalter")
        XCTAssertEqual(t.zeilen[0].zellen["anzahl"]?.text, "2")
        XCTAssertEqual(t.zeilen[0].zellen["waende"]?.text, "4")
        XCTAssertEqual(t.zeilen[0].zellen["fuellung"]?.text, "25 %")
        XCTAssertEqual(t.zeilen[0].zellen["fuellung"]?.unter, "Gyroid")
        XCTAssertEqual(t.zeilen[0].zellen["zeit"]?.text, "1 h 30 min")
        XCTAssertTrue(t.zeilen[0].zellen["teil"]?.unter?.hasPrefix("Von \(AppInfo.nutzerName): Wände") == true)
        XCTAssertEqual(ExportBausteinWahl(art: .druck).wirksameSpalten.reduce(0) { $0 + $1.mindestbreite },
                       172, accuracy: 0.01)  // passt auf A4 hoch (178 mm)
        // Deckblatt mit Druckzeit und Platten
        let zahlen = ExportBauer.deckblattZahlen(q, [.druck])
        XCTAssertTrue(zahlen.contains { $0.1 == "Druckzeit" })
        XCTAssertTrue(zahlen.contains { $0 == ("2", "Druckplatten") })
        // PDF mit echtem Text
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kc-druck-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try doc.schreibePDF(nach: url)
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(pdf.pageCount, doc.seiten.count)
        let text = pdf.string ?? ""
        XCTAssertTrue(text.contains("Platte 1"))
        XCTAssertTrue(text.contains("Stangenhalter"))
        XCTAssertTrue(text.contains("PETG vorher trocknen"))
        XCTAssertTrue(text.contains("Braucht Stützen unter der Lasche"))
        if let ausgabe = ProcessInfo.processInfo.environment["KEVCAD_TEST_AUSGABE"] {
            try? FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: ausgabe).appendingPathComponent("druck-bericht.pdf"))
        }
        // ohne Vorschau: keine Seiten, ein Hinweis
        vorlage.bausteine = [ExportBausteinWahl(art: .druck)]
        let leer = ExportBauer.dokument(vorlage, ExportQuellen(kopf: ExportKopf(projekt: "X")))
        XCTAssertTrue(leer.seiten.isEmpty)
        XCTAssertEqual(leer.hinweise.count, 1)
        // Kernel und App kennen dieselben Bausteine (fixtures.json, export.bausteine)
        XCTAssertTrue(ExportBausteinArt.allCases.contains(.druck))
    }
}
