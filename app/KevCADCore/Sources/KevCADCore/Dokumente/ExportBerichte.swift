import CoreGraphics
import Foundation

// Berichtsseiten (Strang P6-A2): Deckblatt, Stückliste, Teileliste, Einkaufsliste, Zuschnitt. Daten aus einem
// Schnappschuss des App-Modells (`ExportQuellen`), Seiten über den Seitenfluss, gezeichnet auf der Leinwand.

/// Ein Zeichnungsblatt für den Export (gezeichnet von der gemeinsamen Zeichenfunktion der Blätter, Strang P6-A1).
public struct ExportZeichnungsblatt {
    public var id: String
    public var titel: String
    /// Blattgröße in mm (A4/A3, hoch/quer).
    public var groesse: CGSize
    /// Zeichnet das Blatt in Punkt, Ursprung links unten.
    public var zeichne: (CGContext, CGSize) -> Void

    public init(id: String, titel: String, groesse: CGSize, zeichne: @escaping (CGContext, CGSize) -> Void) {
        self.id = id
        self.titel = titel
        self.groesse = groesse
        self.zeichne = zeichne
    }
}

/// Alles, was die Seiten brauchen, als Schnappschuss (die Seiten zeichnen später, auch nach dem nächsten Lauf).
public struct ExportQuellen {
    public var kopf: ExportKopf
    public var bom: BillOfMaterials?
    public var bestand: BOMBestand?
    public var teile: [PartNode]
    public var bauplan: Bauplan?
    public var strichbilder: [String: BauplanStrichbild]
    /// Vorschaubilder je Teilname (weißer Grund, isometrisch).
    public var teilBilder: [String: CGImage]
    public var gesamtBild: CGImage?
    /// Phase 7 (Baustein `produktbild`): Rendering und woher es stammt (Dateiname oder „Studio, schnell“).
    public var produktBild: CGImage?
    public var produktQuelle: String?
    public var zeichnungen: [ExportZeichnungsblatt]
    /// Offene Befunde der Prüfung (für das Deckblatt).
    public var pruefFehler: Int?
    /// Druckvorschau (additiv, Baustein `druck`, DRUCKVORSCHAU.md).
    public var druck: Druckvorschau?
    /// Bestand des Projekts und Katalog (Mindestreste, Werkstoffnamen), wie im Bereich „Material“.
    public var projektBestand: Bestand?
    public var katalog: Catalog?

    public init(kopf: ExportKopf, bom: BillOfMaterials? = nil, bestand: BOMBestand? = nil, teile: [PartNode] = [],
                bauplan: Bauplan? = nil, strichbilder: [String: BauplanStrichbild] = [:],
                teilBilder: [String: CGImage] = [:], gesamtBild: CGImage? = nil,
                zeichnungen: [ExportZeichnungsblatt] = [], pruefFehler: Int? = nil, druck: Druckvorschau? = nil)
    {
        self.druck = druck
        self.kopf = kopf
        self.bom = bom
        self.bestand = bestand
        self.teile = teile
        self.bauplan = bauplan
        self.strichbilder = strichbilder
        self.teilBilder = teilBilder
        self.gesamtBild = gesamtBild
        self.zeichnungen = zeichnungen
        self.pruefFehler = pruefFehler
    }

    /// Dieselbe Datenquelle wie der Bereich „Material“ und die Schnellansichten: Positionen, Gruppen, Kennzeichen,
    /// Zuschnitt, Einkauf und Summen.
    public var material: MaterialDaten {
        MaterialDaten(bom: bom, bestand: bestand, projektBestand: projektBestand, katalog: katalog, druckvorschau: druck)
    }

    /// Bild einer Stücklistenzeile: das erste ihrer Teile mit Bild.
    func bild(_ line: BOMLine) -> CGImage? {
        for t in line.teile { if let b = teilBilder[t] { return b } }
        return nil
    }
}

/// Baut das Dokument aus Vorlage und Quellen.
public enum ExportBauer {
    public static func dokument(_ vorlage: ExportVorlage, _ q: ExportQuellen) -> ExportDokument {
        var seiten: [ExportSeite] = []
        var hinweise: [String] = []
        let format = vorlage.seitenformat
        for wahl in vorlage.aktive {
            let neu: [ExportSeite]
            switch wahl.art {
            case .deckblatt: neu = deckblatt(q, vorlage, format)
            case .produktbild: neu = produktbild(q, format, &hinweise)
            case .stueckliste: neu = stueckliste(q, wahl, format, &hinweise)
            case .teileliste: neu = teileliste(q, wahl, format, &hinweise)
            case .einkaufsliste: neu = einkaufsliste(q, wahl, format, &hinweise)
            case .zuschnitt: neu = zuschnitt(q, wahl, format, &hinweise)
            case .druck: neu = ExportDruckSeiten.seiten(q, wahl, format, &hinweise)
            case .zeichnungen: neu = zeichnungen(q, wahl, &hinweise)
            case .bauplan: neu = ExportBauplanSeiten.seiten(q, format, &hinweise)
            }
            seiten += neu
        }
        return ExportDokument(kopf: q.kopf, seiten: seiten, hinweise: hinweise)
    }

    /// Seiten eines Bausteins aus Blöcken im Fluss; die erste Seite trägt die Überschrift.
    static func flussSeiten(_ art: ExportBausteinArt, _ format: ExportSeitenformat, titel: String? = nil,
                            _ bloecke: [ExportBlock]) -> [ExportSeite]
    {
        let inhalt = ExportRand.inhalt(format.mm)
        return ExportFluss.verteile(bloecke, inhalt: inhalt).map { seite in
            ExportSeite(groesse: format.mm, baustein: art, titel: titel ?? art.titel, gliederung: seite.marken,
                        inhalt: .leinwand { l, _ in
                            for a in seite.auftraege { a.zeichne(l, a.rect) }
                        })
        }
    }

    // MARK: Bausteinkopf

    /// Große Überschrift eines Bausteins mit Kennzeile darunter.
    static func ueberschrift(_ titel: String, _ zeile: String?, symbol: ExportBausteinArt? = nil) -> ExportBlock {
        let h: CGFloat = zeile == nil ? 13 : 19
        return .fest(hoehe: h, mitNaechstem: true) { l, r in
            l.text(titel, x: r.minX, y: r.minY + 8.5, .fett(20), farbe: ExportStil.tinte)
            if let zeile {
                l.text(zeile, x: r.minX, y: r.minY + 15, .normal(9.5), farbe: ExportStil.grau, maxBreite: r.width)
            }
        }
    }

    static func zwischentitel(_ titel: String, _ rechts: String? = nil) -> ExportBlock {
        .fest(hoehe: 10, mitNaechstem: true) { l, r in
            l.text(titel, x: r.minX, y: r.minY + 6.5, .fett(11.5), farbe: ExportStil.tinte, maxBreite: r.width * 0.7)
            if let rechts {
                l.text(rechts, x: r.maxX, y: r.minY + 6.5, .normal(8.5), farbe: ExportStil.grau, .rechts,
                       maxBreite: r.width * 0.45)
            }
        }
    }

    static func hinweisZeile(_ text: String, farbe: CGColor = ExportStil.grau) -> ExportBlock {
        let breite: CGFloat = 170
        let h = ExportSatz(text, breite: breite, schrift: .normal(8)).hoehe + 2
        return .fest(hoehe: h, mitNaechstem: false) { l, r in
            l.absatz(text, x: r.minX, y: r.minY + 1, breite: r.width, .normal(8), farbe: farbe)
        }
    }

    static func leer(_ text: String) -> ExportBlock {
        .fest(hoehe: 24, mitNaechstem: false) { l, r in
            let box = CGRect(x: r.minX, y: r.minY + 2, width: r.width, height: 18)
            l.rechteck(box, fuellung: ExportStil.flaeche, radius: 2)
            l.text(text, x: box.midX, y: box.midY + 1.2, .normal(9.5), farbe: ExportStil.grau, .mitte,
                   maxBreite: box.width - 8)
        }
    }

    // MARK: Produktbild (Phase 7)

    /// Eine Seite mit dem Rendering, so groß wie möglich, Titel und Herkunft darunter.
    static func produktbild(_ q: ExportQuellen, _ format: ExportSeitenformat, _ hinweise: inout [String])
        -> [ExportSeite]
    {
        guard let img = q.produktBild else {
            hinweise.append("Produktbild: kein Rendering möglich (keine sichtbaren Teile?)")
            return []
        }
        let seite = ExportSeite(groesse: format.mm, baustein: .produktbild, titel: "Produktbild",
                                inhalt: .leinwand { l, _ in
            let inhalt = ExportRand.inhalt(format.mm)
            l.text(q.kopf.projekt, x: inhalt.minX, y: inhalt.minY + 8.5, .fett(20), farbe: ExportStil.tinte,
                   maxBreite: inhalt.width)
            let platz = CGRect(x: inhalt.minX, y: inhalt.minY + 16, width: inhalt.width, height: inhalt.height - 26)
            let seitenverhaeltnis = CGFloat(img.width) / CGFloat(max(img.height, 1))
            var w = platz.width, h = w / seitenverhaeltnis
            if h > platz.height {
                h = platz.height
                w = h * seitenverhaeltnis
            }
            let r = CGRect(x: platz.midX - w / 2, y: platz.minY, width: w, height: h)
            l.bild(img, in: r)
            if let quelle = q.produktQuelle {
                l.text("Rendering: \(quelle)", x: r.minX, y: r.maxY + 6, .normal(8), farbe: ExportStil.grau,
                       maxBreite: r.width)
            }
        })
        return [seite]
    }

    // MARK: Deckblatt

    static func deckblatt(_ q: ExportQuellen, _ vorlage: ExportVorlage, _ format: ExportSeitenformat) -> [ExportSeite] {
        let titel = q.kopf.projekt
        let inhaltArten = vorlage.aktive.map(\.art).filter { $0 != .deckblatt }
        let zahlen = deckblattZahlen(q, inhaltArten)
        // Aufteilung vorab: das Inhaltsverzeichnis darf nie in den Fuß laufen (einspaltig, zweispaltig oder eine
        // eigene Seite), die Gesamtansicht nimmt, was übrig bleibt
        let titelSatz = ExportSatz(titel, breite: format.mm.width - 44, schrift: .fett(34), zeilenabstand: 0.95,
                                   maxZeilen: 2)
        let aufteilung = DeckblattAufteilung(groesse: format.mm, titelHoehe: titelSatz.hoehe, kacheln: zahlen.count,
                                             eintraege: max(1, inhaltArten.count))
        let seite = ExportSeite(groesse: format.mm, baustein: .deckblatt, titel: "Deckblatt", mitKopf: false,
                                inhalt: .leinwand { l, info in
            let w = l.groesse.width, h = l.groesse.height
            let x0 = DeckblattAufteilung.rand, x1 = w - DeckblattAufteilung.rand
            // Kennband oben
            l.rechteck(CGRect(x: 0, y: 0, width: w, height: 4.5), fuellung: ExportStil.akzent)
            var y: CGFloat = 26
            l.text("BAUUNTERLAGEN", x: x0, y: y, .mittel(9), farbe: ExportStil.akzent, laufweite: 0.35)
            y += 13
            l.zeichne(titelSatz, x: x0, y: y - 9, breite: x1 - x0)
            y += titelSatz.hoehe - 2
            let inhaltText = inhaltArten.map(\.titel).joined(separator: "  ·  ")
            l.text(inhaltText, x: x0, y: y + 4, .normal(11), farbe: ExportStil.grau, maxBreite: x1 - x0)
            let a = aufteilung
            let bildR = a.bild
            l.rechteck(bildR, fuellung: ExportStil.flaeche, radius: 3)
            if let img = q.gesamtBild {
                l.bild(img, in: bildR.insetBy(dx: 4, dy: 4))
            } else {
                l.text("Keine Gesamtansicht", x: bildR.midX, y: bildR.midY, .normal(10), farbe: ExportStil.grauHell,
                       .mitte)
            }
            let kachelW = (a.spalte.width - CGFloat(a.kachelSpalten - 1) * 4) / CGFloat(a.kachelSpalten)
            for (i, z) in zahlen.enumerated() {
                let sx = a.spalte.minX + CGFloat(i % a.kachelSpalten) * (kachelW + 4)
                let sy = a.kachelnY + CGFloat(i / a.kachelSpalten) * DeckblattAufteilung.kachelRaster
                l.rechteck(CGRect(x: sx, y: sy, width: kachelW, height: 17), rand: ExportStil.linie, randBreite: 0.2,
                           radius: 2)
                l.text(z.0, x: sx + 4, y: sy + 8.6, .fett(14), farbe: ExportStil.tinte, maxBreite: kachelW - 8)
                l.text(z.1.uppercased(), x: sx + 4, y: sy + 13.6, .mittel(6.5), farbe: ExportStil.grau,
                       laufweite: 0.2)
            }
            if a.inhaltAufDeckblatt {
                inhaltsverzeichnis(l, info, x: a.spalte.minX, y: a.inhaltY, breite: a.spalte.width,
                                   spalten: a.inhaltSpalten, titelGroesse: 10.5)
            }
            deckblattFuss(l, q, x0: x0, x1: x1, fy: a.fussY, h: h)
        })
        guard !aufteilung.inhaltAufDeckblatt else { return [seite] }
        // Langes Inhaltsverzeichnis: eigene Seite gleich nach dem Deckblatt, im Stil des Deckblatts
        let inhalt = ExportSeite(groesse: format.mm, baustein: .deckblatt, titel: "Inhalt", mitKopf: false,
                                 inhalt: .leinwand { l, info in
            let w = l.groesse.width, h = l.groesse.height
            let x0 = DeckblattAufteilung.rand, x1 = w - DeckblattAufteilung.rand
            l.rechteck(CGRect(x: 0, y: 0, width: w, height: 4.5), fuellung: ExportStil.akzent)
            l.text(titel.uppercased(), x: x0, y: 26, .mittel(9), farbe: ExportStil.akzent, maxBreite: x1 - x0,
                   laufweite: 0.35)
            l.text("Inhalt", x: x0, y: 40, .fett(26), farbe: ExportStil.tinte)
            let fy = h - 22
            let zeilen = CGFloat(info.bausteinSeiten.filter { $0.art != .deckblatt }.count)
            let spalten = 6 + zeilen * 9 <= fy - 10 - 52 ? 1 : 2
            inhaltsverzeichnis(l, info, x: x0, y: 52, breite: x1 - x0, spalten: spalten, titelGroesse: 12,
                               zeile: 9, ohneKopf: true)
            deckblattFuss(l, q, x0: x0, x1: x1, fy: fy, h: h)
        })
        return [seite, inhalt]
    }

    /// Kennzahlen des Deckblatts (Wert, Bezeichnung).
    static func deckblattZahlen(_ q: ExportQuellen, _ inhaltArten: [ExportBausteinArt]) -> [(String, String)] {
        var zahlen: [(String, String)] = []
        if let bom = q.bom {
            zahlen.append((KevFormat.integer(bom.totals.teile), "Teile"))
            zahlen.append((KevFormat.integer(bom.totals.positionen), "Positionen"))
            zahlen.append((KevFormat.kg(bom.totals.kg), "Gewicht"))
            if let p = bom.totals.preis { zahlen.append(("≈ " + KevFormat.euro(p), "Materialkosten")) }
        } else if !q.teile.isEmpty {
            zahlen.append((KevFormat.integer(q.teile.count), "Teile"))
        }
        if let plan = q.bauplan, inhaltArten.contains(.bauplan) {
            zahlen.append((KevFormat.integer(plan.alleSchritte.count), "Bauschritte"))
        }
        if inhaltArten.contains(.druck), let d = q.druck, !d.platten.isEmpty {
            zahlen.append((DruckFormat.zeit(d.summe.zeitMitWechselS), "Druckzeit"))
            zahlen.append((KevFormat.integer(d.summe.platten), d.summe.platten == 1 ? "Druckplatte" : "Druckplatten"))
        }
        if inhaltArten.contains(.zeichnungen), !q.zeichnungen.isEmpty {
            zahlen.append((KevFormat.integer(q.zeichnungen.count), "Zeichnungen"))
        }
        return zahlen
    }

    /// Inhaltsverzeichnis mit Seitenzahlen, in `spalten` Spalten (spaltenweise gefüllt).
    static func inhaltsverzeichnis(_ l: ExportLeinwand, _ info: ExportSeitenInfo, x: CGFloat, y: CGFloat,
                                   breite: CGFloat, spalten: Int, titelGroesse: CGFloat, zeile: CGFloat = 8,
                                   ohneKopf: Bool = false)
    {
        var ky = y
        if !ohneKopf {
            l.text("INHALT", x: x, y: ky + 3, .mittel(7.5), farbe: ExportStil.grau, laufweite: 0.3)
            ky += 6
        }
        let eintraege = info.bausteinSeiten.filter { $0.art != .deckblatt }
        let n = max(1, spalten)
        let jeSpalte = (eintraege.count + n - 1) / n
        let sw = (breite - CGFloat(n - 1) * 8) / CGFloat(n)
        for (i, b) in eintraege.enumerated() {
            let sx = x + CGFloat(jeSpalte > 0 ? i / jeSpalte : 0) * (sw + 8)
            let sy = ky + CGFloat(jeSpalte > 0 ? i % jeSpalte : i) * zeile
            l.linie(CGPoint(x: sx, y: sy + zeile - 1.2), CGPoint(x: sx + sw, y: sy + zeile - 1.2), breite: 0.12,
                    farbe: ExportStil.linieFein)
            let seiten = b.anzahl == 1 ? "Seite \(b.seite)" : "Seite \(b.seite)–\(b.seite + b.anzahl - 1)"
            let nw = l.text(seiten, x: sx + sw, y: sy + zeile - 3, .normal(titelGroesse - 1), farbe: ExportStil.grau,
                            .rechts)
            l.text(b.art.titel, x: sx, y: sy + zeile - 3, .mittel(titelGroesse), farbe: ExportStil.tinte,
                   maxBreite: sw - nw - 4)
        }
    }

    /// Fuß des Deckblatts: Projekt, Stand, Datum, Eigentümer; darunter „Erstellt mit Kev CAD“.
    static func deckblattFuss(_ l: ExportLeinwand, _ q: ExportQuellen, x0: CGFloat, x1: CGFloat, fy: CGFloat,
                              h: CGFloat)
    {
        l.linie(CGPoint(x: x0, y: fy), CGPoint(x: x1, y: fy), breite: 0.3, farbe: ExportStil.tinte)
        let felder: [(String, String)] = [
            ("Projekt", q.kopf.projekt), ("Stand", q.kopf.version ?? "aktueller Stand"),
            ("Datum", q.kopf.datumText), ("Eigentümer", q.kopf.autor),
        ]
        let fw = (x1 - x0) / CGFloat(felder.count)
        for (i, f) in felder.enumerated() {
            let fx = x0 + CGFloat(i) * fw
            l.text(f.0.uppercased(), x: fx, y: fy + 5, .mittel(6.5), farbe: ExportStil.grau, laufweite: 0.2)
            l.text(f.1, x: fx, y: fy + 10, .normal(9), farbe: ExportStil.tinte, maxBreite: fw - 4)
        }
        l.text("Erstellt mit SK-CAD", x: x1, y: h - 6, .normal(7), farbe: ExportStil.grauHell, .rechts)
    }

    // MARK: Stückliste

    /// Gruppe einer Art (Reihenfolge, Titel), wie im Bereich „Material“.
    static func artGruppe(_ art: String) -> (Int, String) {
        let g = MaterialGruppe(art: art)
        return (g.rawValue, g.titel)
    }

    /// Herkunft einer Position: Zukauf mit Hersteller, Druckteil, Eigenteil, sonst die Quelle aus dem Bestandsabgleich
    /// („Rest + Kaufen“) bzw. „Lager“.
    static func herkunft(_ p: MaterialPosition) -> String {
        if p.herkunft != nil || p.versorgung.isEmpty { return p.herkunftText }
        return p.versorgung.map(\.titel).joined(separator: " + ")
    }

    static func herkunft(_ line: BOMLine) -> String {
        herkunft(MaterialDaten.position(line, zuschnitt: nil, stueckgut: [], katalog: nil))
    }

    static func masseText(_ line: BOMLine) -> String { MaterialText.masseMitGehrung(line) }

    static func stueckliste(_ q: ExportQuellen, _ wahl: ExportBausteinWahl, _ format: ExportSeitenformat,
                            _ hinweise: inout [String]) -> [ExportSeite]
    {
        guard let bom = q.bom, !bom.lines.isEmpty else {
            hinweise.append("Stückliste leer: noch kein Lauf mit Teilen")
            return flussSeiten(.stueckliste, format, [ueberschrift("Stückliste", nil), leer("Keine Stückliste: erst model.py rechnen")])
        }
        let spalten = wahl.wirksameSpalten
        var zeilen: [ExportZeile] = []
        // Gruppen und Texte aus der gemeinsamen Datenquelle (wie im Bereich „Material“)
        for g in q.material.gruppen {
            zeilen.append(.gruppe(g.gruppe.titel))
            for p in g.positionen {
                let line = p.line
                var z: [String: ExportZelle] = [:]
                z["pos"] = ExportZelle("\(line.pos)", fett: true)
                z["bild"] = ExportZelle(bild: q.bild(line))
                // Druck- und Eigenteile heißen wie ihr Teil im Modell: Name groß, Baugruppe darunter
                z["benennung"] = ExportZelle(p.name, unter: p.unter)
                z["norm"] = ExportZelle(line.norm ?? "")
                z["material"] = ExportZelle(p.werkstoff ?? "–")
                z["masse"] = ExportZelle(masseText(line))
                z["anzahl"] = ExportZelle("\(line.anzahl)", fett: true)
                z["gewicht"] = ExportZelle(line.kg.map(KevFormat.kg) ?? "–")
                z["preis_je"] = ExportZelle(line.preisJe.map(KevFormat.euro) ?? "–")
                z["preis"] = ExportZelle(line.preis.map(KevFormat.euro) ?? "–")
                z["herkunft"] = ExportZelle(herkunft(p),
                                            farbe: p.kennzeichen.count == 1 ? ExportStil.farbe(p.kennzeichen[0]) : nil)
                zeilen.append(ExportZeile(z))
            }
        }
        zeilen.append(.summe([
            "benennung": ExportZelle("Summe"), "anzahl": ExportZelle("\(bom.totals.teile)"),
            "gewicht": ExportZelle(KevFormat.kg(bom.totals.kg)),
            "preis": ExportZelle(bom.totals.preis.map(KevFormat.euro) ?? "–"),
        ]))
        var t = ExportTabelle(spalten: spalten, zeilen: zeilen)
        if !spalten.contains(where: { $0.id == "bild" }) { t.bildHoehe = 0 }
        let kennzeile = "\(KevFormat.count(bom.totals.positionen, one: "Position", many: "Positionen")), "
            + "\(KevFormat.count(bom.totals.teile, one: "Teil", many: "Teile")), \(KevFormat.kg(bom.totals.kg))"
            + (bom.totals.preis.map { ", Materialkosten ≈ \(KevFormat.euro($0))" } ?? "")
        var bloecke: [ExportBlock] = [ueberschrift("Stückliste", kennzeile), .tabelle(t)]
        if let h = bom.totals.preisHinweis, !h.isEmpty { bloecke += [.abstand(2), hinweisZeile(h)] }
        for w in bom.warnings.prefix(4) { bloecke.append(hinweisZeile(w, farbe: ExportStil.tinte)) }
        return flussSeiten(.stueckliste, format, bloecke)
    }

    // MARK: Teileliste

    /// Herkunft eines Teils (gemeinsame Datenquelle: Druck- und Eigenteile nach der Stückliste).
    static func herkunft(_ p: PartNode, _ material: MaterialDaten = .leer) -> (String, String?) {
        let h = material.herkunft(p)
        return (h.titel, h.unter)
    }

    static func teileliste(_ q: ExportQuellen, _ wahl: ExportBausteinWahl, _ format: ExportSeitenformat,
                           _ hinweise: inout [String]) -> [ExportSeite]
    {
        guard !q.teile.isEmpty else {
            return flussSeiten(.teileliste, format, [ueberschrift("Teileliste", nil), leer("Keine Teile")])
        }
        let spalten = wahl.wirksameSpalten
        var zeilen: [ExportZeile] = []
        var nr = 0
        let material = q.material
        var gruppe: String?
        var ersteStelle: [String: Int] = [:]
        for (i, p) in q.teile.enumerated() {
            let g = p.path.count > 1 ? p.path[0] : ""
            if ersteStelle[g] == nil { ersteStelle[g] = i }
        }
        let sortiert = q.teile.enumerated().sorted { a, b in
            let ga = ersteStelle[a.element.path.count > 1 ? a.element.path[0] : ""] ?? 0
            let gb = ersteStelle[b.element.path.count > 1 ? b.element.path[0] : ""] ?? 0
            return ga == gb ? a.offset < b.offset : ga < gb
        }.map(\.element)
        for p in sortiert {
            let g = p.path.count > 1 ? p.path[0] : "Einzelteile"
            if g != gruppe {
                zeilen.append(.gruppe(g))
                gruppe = g
            }
            nr += 1
            let (her, herUnter) = herkunft(p, material)
            let size = p.bboxMax - p.bboxMin
            var z: [String: ExportZelle] = [:]
            z["nr"] = ExportZelle("\(nr)", fett: true)
            z["bild"] = ExportZelle(bild: q.teilBilder[p.id])
            z["name"] = ExportZelle(p.name, unter: p.path.count > 2 ? p.path.dropLast().joined(separator: " / ") : nil)
            z["baugruppe"] = ExportZelle(p.path.dropLast().joined(separator: " / "))
            z["herkunft"] = ExportZelle(her, unter: herUnter, farbe: p.inventarFehlt ? ExportStil.rot : nil)
            z["material"] = ExportZelle(p.material ?? p.stock?.material ?? "–")
            z["abmessungen"] = ExportZelle(KevFormat.dimensions(min: p.bboxMin, max: p.bboxMin + size, digits: 1))
            z["gewicht"] = ExportZelle(p.mass.map { KevFormat.mass(grams: $0) } ?? "–")
            zeilen.append(ExportZeile(z))
        }
        let masse = q.teile.compactMap(\.mass).reduce(0, +)
        zeilen.append(.summe([
            "name": ExportZelle("\(q.teile.count) Teile"),
            "gewicht": ExportZelle(KevFormat.mass(grams: masse)),
        ]))
        var t = ExportTabelle(spalten: spalten, zeilen: zeilen)
        if !spalten.contains(where: { $0.id == "bild" }) { t.bildHoehe = 0 }
        let mitBild = q.teile.filter { q.teilBilder[$0.id] != nil }.count
        if spalten.contains(where: { $0.id == "bild" }) && mitBild < q.teile.count {
            hinweise.append("Teileliste: \(q.teile.count - mitBild) Teile ohne Vorschaubild (ausgeblendet)")
        }
        let kennzeile = "\(KevFormat.count(q.teile.count, one: "Teil", many: "Teile")) einzeln, nach Baugruppe"
        return flussSeiten(.teileliste, format, [ueberschrift("Teileliste", kennzeile), .tabelle(t)])
    }

    // MARK: Einkaufsliste

    static func einkaufsliste(_ q: ExportQuellen, _ wahl: ExportBausteinWahl, _ format: ExportSeitenformat,
                              _ hinweise: inout [String]) -> [ExportSeite]
    {
        let spalten = wahl.wirksameSpalten
        var bloecke: [ExportBlock] = []
        let m = q.material
        guard q.bestand != nil || !m.zukaufEinkauf.isEmpty else {
            hinweise.append("Einkaufsliste ohne Bestandsabgleich (Kernel hat keinen Zuschnitt mit Bestand geschickt)")
            return flussSeiten(.einkaufsliste, format, [ueberschrift("Einkaufsliste", nil),
                                                        leer("Noch keine Einkaufsliste: erst model.py rechnen")])
        }
        // Dieselbe Liste wie im Bereich „Material“: Lagerware nach Abzug des Bestands, dazu die Zukaufteile
        let k = m.kennzahlen
        let kennzeile = m.einkauf.isEmpty ? "Alles im Projektbestand vorhanden"
            : "\(KevFormat.count(m.einkauf.count, one: "Position", many: "Positionen")) nach Abzug des Bestands"
                + (k.einkaufSumme.map { ", zusammen ≈ \(KevFormat.euro($0))" } ?? "")
        bloecke.append(ueberschrift("Einkaufsliste", kennzeile))
        if m.einkauf.isEmpty {
            bloecke.append(leer("Nichts zu kaufen: alles ist im Projektbestand"))
        } else {
            var zeilen: [ExportZeile] = []
            for (art, titel) in [(MaterialEinkauf.Art.lager, "Lagerware"), (.zukauf, "Zukaufteile")] {
                let teil = m.einkauf.filter { $0.art == art }
                guard !teil.isEmpty else { continue }
                if !m.lagerEinkauf.isEmpty && !m.zukaufEinkauf.isEmpty { zeilen.append(.gruppe(titel)) }
                for z in teil {
                    let e = z.position
                    zeilen.append(ExportZeile([
                        "abhaken": ExportZelle(kaestchen: true), "menge": ExportZelle(e.mengeText, fett: true),
                        "einheit": ExportZelle(e.einheit), "benennung": ExportZelle(e.benennung, unter: e.hinweis),
                        "preis_je": ExportZelle(e.preisJe.map(KevFormat.euro) ?? "–"),
                        "preis": ExportZelle(e.preis.map(KevFormat.euro) ?? "–"),
                        "bezugsquelle": ExportZelle(e.linkTitel ?? "–", farbe: e.link != nil ? ExportStil.blau : nil,
                                                    verweis: e.link),
                        "hinweis": ExportZelle(e.hinweis ?? ""),
                    ]))
                }
            }
            zeilen.append(.summe(["benennung": ExportZelle("Summe"),
                                  "preis": ExportZelle(k.einkaufSumme.map(KevFormat.euro) ?? "–")]))
            bloecke.append(.tabelle(ExportTabelle(spalten: spalten, zeilen: zeilen)))
            if let h = m.einkaufHinweis, !h.isEmpty { bloecke += [.abstand(2), hinweisZeile(h)] }
            if k.einkaufOhnePreis > 0 {
                bloecke.append(hinweisZeile("\(k.einkaufOhnePreis) Positionen ohne Preis im Katalog, Summe daher unvollständig"))
            }
        }
        // Normteile: Bedarf, aus Bestand, kaufen
        if !m.stueckgut.isEmpty {
            bloecke += [.abstand(6), zwischentitel("Normteile abzählen", "Bedarf, aus dem Projektbestand, zu kaufen")]
            let sp = [
                ExportSpalte("abhaken", "", mindest: 7, .mitte),
                ExportSpalte("benennung", MaterialText.Spalte.benennung, mindest: 60, gewicht: 3),
                ExportSpalte("masse", MaterialText.Spalte.masse, mindest: 24, gewicht: 1),
                ExportSpalte("anzahl", "Bedarf", mindest: 15, .rechts),
                ExportSpalte("bestand", MaterialKennzeichen.bestand.titel, mindest: 17, .rechts),
                ExportSpalte("kaufen", MaterialKennzeichen.kaufen.titel, mindest: 15, .rechts),
            ]
            let zeilen = m.stueckgut.map { s in
                ExportZeile([
                    "abhaken": ExportZelle(kaestchen: true), "benennung": ExportZelle(s.benennung),
                    "masse": ExportZelle(s.laenge.map { "\(s.masseText), L = \(KevFormat.length($0))" } ?? s.masseText),
                    "anzahl": ExportZelle("\(s.anzahl)", fett: true), "bestand": ExportZelle("\(s.ausBestand)"),
                    "kaufen": ExportZelle("\(s.kaufen)", fett: s.kaufen > 0, farbe: s.kaufen > 0 ? ExportStil.akzent : nil),
                ])
            }
            bloecke.append(.tabelle(ExportTabelle(spalten: sp, zeilen: zeilen)))
        }
        // Filament der Druckteile (Spulen führt der Bestand noch nicht)
        if !m.filament.isEmpty {
            bloecke += [.abstand(6), zwischentitel("Filament für Druckteile", "Spulen werden nicht im Bestand geführt")]
            let sp = [
                ExportSpalte("werkstoff", MaterialText.Spalte.werkstoff, mindest: 40, gewicht: 2),
                ExportSpalte("teile", MaterialText.Spalte.anzahl, mindest: 15, .rechts),
                ExportSpalte("gewicht", MaterialText.Spalte.gewicht, mindest: 18, .rechts),
                ExportSpalte("preis", MaterialText.Spalte.preis, mindest: 16, .rechts),
            ]
            let zeilen = m.filament.map { f in
                ExportZeile([
                    "werkstoff": ExportZelle(f.werkstoff), "teile": ExportZelle("\(f.teile)"),
                    "gewicht": ExportZelle(KevFormat.mass(grams: f.gramm), fett: true),
                    "preis": ExportZelle(f.preis.map(KevFormat.euro) ?? "–"),
                ])
            }
            bloecke.append(.tabelle(ExportTabelle(spalten: sp, zeilen: zeilen)))
        }
        if let s = m.bestandStand {
            bloecke += [.abstand(2), hinweisZeile("Bestand vom \(BestandText.anzeige(s) ?? s)")]
        }
        return flussSeiten(.einkaufsliste, format, bloecke)
    }

    // MARK: Zuschnitt

    static func zuschnitt(_ q: ExportQuellen, _ wahl: ExportBausteinWahl, _ format: ExportSeitenformat,
                          _ hinweise: inout [String]) -> [ExportSeite]
    {
        var bloecke: [ExportBlock] = []
        // Dieselben Zuschnitte wie im Bereich „Material“ (ohne Bestandsabgleich: alle Stangen neu)
        let m = q.material
        let zuschnitte = m.zuschnitte
        guard !zuschnitte.isEmpty else {
            return flussSeiten(.zuschnitt, format, [ueberschrift("Zuschnitt", nil), leer("Nichts zuzuschneiden")])
        }
        let k = m.kennzahlen
        var kz = [k.zuschnittText]
        if k.verschnittText != "–" { kz.append("Verschnitt " + k.verschnittText) }
        kz.append(q.bestand == nil ? "ohne Projektbestand: alle Stangen neu" : "Reste aus dem Bestand zuerst")
        bloecke.append(ueberschrift("Zuschnitt", kz.joined(separator: " · ")))
        bloecke.append(legende())
        var tabelle: [ExportZeile] = []
        for z in zuschnitte {
            let mindest = m.mindestrest(z.stockID)
            let rechts = [z.herkunftText] + (m.verschnitt(z).map { ["Verschnitt \(KevFormat.number($0, digits: 1)) %"] } ?? [])
            bloecke.append(zwischentitel(z.benennung, rechts.joined(separator: " · ")))
            let saege = z.saegeschnitt
            for (i, quelle) in z.quellen.enumerated() {
                if z.istPlatte {
                    bloecke.append(platte(quelle, nummer: i + 1, saege: saege, b: quelle.b ?? z.platteB,
                                          h: quelle.h ?? z.platteH))
                } else {
                    bloecke.append(leiste(quelle, nummer: i + 1, saege: saege, mindest: mindest, skala: z.laengsteQuelle))
                }
                let rest: String
                if quelle.istPlatte {
                    rest = quelle.resteNeu.map(\.masseText).joined(separator: ", ")
                } else {
                    let r = quelle.restLaenge(saegeschnitt: saege)
                    rest = r > 0.05 ? KevFormat.length(r) : "–"
                }
                let stuecke = quelle.istPlatte ? quelle.flaechen.map(\.masseText).joined(separator: ", ")
                    : quelle.stuecke.map { KevFormat.compact($0, maxDigits: 1) }.joined(separator: " + ") + " mm"
                tabelle.append(ExportZeile([
                    "stange": ExportZelle("\(z.istPlatte ? "Platte" : "Stange") \(i + 1)", unter: z.benennung),
                    "herkunft": ExportZelle(quelle.titel, farbe: ExportStil.farbe(quelle.art.farbe)),
                    "stuecke": ExportZelle(stuecke), "rest": ExportZelle(rest),
                    "verschnitt": ExportZelle(!quelle.istPlatte
                                              && quelle.restIstVerschnitt(saegeschnitt: saege, mindestrest: mindest)
                                              ? "ja" : "–"),
                ]))
            }
            if z.hatNeueReste {
                bloecke.append(hinweisZeile("Neue Reste für den Bestand: \(z.neueResteText)", farbe: ExportStil.gruen))
            }
            bloecke.append(.abstand(4))
        }
        if !tabelle.isEmpty {
            bloecke += [zwischentitel("Übersicht"), .tabelle(ExportTabelle(spalten: wahl.wirksameSpalten, zeilen: tabelle))]
        }
        bloecke.append(hinweisZeile(MaterialZuschnitt.hilfe))
        return flussSeiten(.zuschnitt, format, bloecke)
    }

    static func legende() -> ExportBlock {
        .fest(hoehe: 9, mitNaechstem: false) { l, r in
            var x = r.minX
            let eintraege: [(ZuschnittFarbe, String)] = ZuschnittFarbe.allCases.map { ($0, $0.titel) }
            for (f, t) in eintraege {
                let box = CGRect(x: x, y: r.minY + 2, width: 5, height: 3.4)
                if f == .restNeu {
                    l.rechteck(box, rand: ExportStil.farbe(f), randBreite: 0.35, radius: 0.5, strich: [0.8, 0.6])
                } else {
                    l.rechteck(box, fuellung: ExportStil.farbe(f), radius: 0.5)
                }
                x += 6.5
                x += l.text(t, x: x, y: r.minY + 4.9, .normal(7.5), farbe: ExportStil.grau) + 6
            }
        }
    }

    /// Zuschnittleiste einer Stange: Stücke farbig nach Quelle mit Längen, Sägeschnitte, neuer Rest, Verschnitt.
    static func leiste(_ q: ZuschnittQuelle, nummer: Int, saege: Double, mindest: Double, skala: Double) -> ExportBlock {
        .fest(hoehe: 15, mitNaechstem: false) { l, r in
            let labelW: CGFloat = 30
            l.text("\(nummer)", x: r.minX, y: r.minY + 7.6, .fett(10), farbe: ExportStil.tinte)
            l.text(q.titel, x: r.minX + 5, y: r.minY + 7.6, .normal(7.5), farbe: ExportStil.grau, maxBreite: labelW - 6)
            let bx = r.minX + labelW
            let bw = r.width - labelW
            let k = bw / CGFloat(max(1, skala))
            let gesamt = CGFloat(q.laenge ?? skala) * k
            let barY = r.minY + 3, barH: CGFloat = 6.5
            l.rechteck(CGRect(x: bx, y: barY, width: gesamt, height: barH), rand: ExportStil.linie, randBreite: 0.2)
            let farbe = ExportStil.farbe(q.art.farbe)
            for s in q.segmente(saegeschnitt: saege, mindestrest: mindest) {
                let sr = CGRect(x: bx + CGFloat(s.start) * k, y: barY, width: max(0.2, CGFloat(s.laenge) * k), height: barH)
                switch s.art {
                case .stueck:
                    l.rechteck(sr, fuellung: farbe)
                    let txt = KevFormat.compact(s.laenge, maxDigits: 1)
                    if ExportLeinwand.breite(txt, .mittel(7)) < sr.width - 1.5 {
                        l.text(txt, x: sr.midX, y: barY + barH / 2 + 1.2, .mittel(7), farbe: ExportStil.weiss, .mitte)
                    }
                case .schnitt:
                    l.rechteck(sr, fuellung: ExportStil.tinte)
                case .restNeu:
                    l.rechteck(sr.insetBy(dx: 0.2, dy: 0.2), rand: ExportStil.farbe(ZuschnittFarbe.restNeu), randBreite: 0.35,
                               strich: [0.8, 0.6])
                    let txt = "Rest " + KevFormat.compact(s.laenge, maxDigits: 0)
                    if ExportLeinwand.breite(txt, .normal(6.5)) < sr.width - 1.5 {
                        l.text(txt, x: sr.midX, y: barY + barH / 2 + 1.1, .normal(6.5), farbe: ExportStil.gruen, .mitte)
                    }
                case .verschnitt:
                    l.rechteck(sr, fuellung: ExportStil.farbe(ZuschnittFarbe.verschnitt))
                }
            }
            // Maßlinie über die ganze Stange
            l.text(KevFormat.length(q.laenge ?? skala), x: bx + gesamt, y: barY + barH + 3.6, .normal(6.5),
                   farbe: ExportStil.grau, .rechts)
        }
    }

    /// Plattenzuschnitt: Platte mit Stücken (Lage aus dem Kernel, Ursprung links unten wie am Bildschirm), neue Reste
    /// gestrichelt.
    static func platte(_ q: ZuschnittQuelle, nummer: Int, saege: Double, b: Double? = nil, h: Double? = nil) -> ExportBlock {
        let pb = CGFloat(b ?? q.b ?? 1000), ph = CGFloat(h ?? q.h ?? 500)
        let breite: CGFloat = 120
        let k = breite / max(1, pb)
        let hoehe = ph * k
        return .fest(hoehe: hoehe + 10, mitNaechstem: false) { l, r in
            l.text("\(nummer)", x: r.minX, y: r.minY + 5, .fett(10), farbe: ExportStil.tinte)
            l.text(q.titel, x: r.minX + 5, y: r.minY + 5, .normal(7.5), farbe: ExportStil.grau, maxBreite: 26)
            let ox = r.minX + 32, oy = r.minY + 2
            let rahmen = CGRect(x: ox, y: oy, width: breite, height: hoehe)
            l.rechteck(rahmen, fuellung: ExportStil.flaeche, rand: ExportStil.grau, randBreite: 0.25)
            let farbe = ExportStil.farbe(q.art.farbe)
            // Kernel: y nach oben ab der Unterkante; Leinwand: y nach unten
            func rechteck(_ f: ZuschnittFlaeche) -> CGRect {
                CGRect(x: ox + CGFloat(f.x) * k, y: oy + (ph - CGFloat(f.y) - CGFloat(f.h)) * k,
                       width: CGFloat(f.b) * k, height: CGFloat(f.h) * k)
            }
            for f in q.flaechenLayout(saegeschnitt: saege) {
                let sr = rechteck(f)
                l.rechteck(sr, fuellung: farbe, rand: ExportStil.weiss, randBreite: 0.3)
                if ExportLeinwand.breite(f.masseText, .mittel(6.5)) < sr.width - 2 && sr.height > 4 {
                    l.text(f.masseText, x: sr.midX, y: sr.midY + 1.1, .mittel(6.5), farbe: ExportStil.weiss, .mitte)
                }
            }
            for f in q.resteNeu {
                l.rechteck(rechteck(f).insetBy(dx: 0.4, dy: 0.4), rand: ExportStil.farbe(ZuschnittFarbe.restNeu), randBreite: 0.35,
                           strich: [0.8, 0.6])
            }
            l.text(BestandText.format(Double(pb), Double(ph)), x: rahmen.maxX + 3, y: rahmen.minY + 3, .normal(7),
                   farbe: ExportStil.grau)
        }
    }

    // MARK: Zeichnungen

    static func zeichnungen(_ q: ExportQuellen, _ wahl: ExportBausteinWahl, _ hinweise: inout [String])
        -> [ExportSeite]
    {
        var blaetter = q.zeichnungen
        if let a = wahl.auswahl, !a.isEmpty {
            let fehlen = a.filter { id in !blaetter.contains { $0.id == id } }
            if !fehlen.isEmpty { hinweise.append("Zeichnungen nicht gefunden: \(fehlen.joined(separator: ", "))") }
            blaetter = a.compactMap { id in blaetter.first { $0.id == id } }
        }
        if blaetter.isEmpty {
            hinweise.append("Keine Zeichnungen: erst „Zeichnungen erstellen“")
            return []
        }
        return blaetter.map { b in
            ExportSeite(groesse: b.groesse, baustein: .zeichnungen, titel: b.titel, mitKopf: false,
                        gliederung: [b.titel], inhalt: .roh(b.zeichne))
        }
    }
}

/// Aufteilung des Deckblatts (mm, Ursprung links oben), vorab gerechnet: Gesamtansicht, Kennzahlen und Inhalt über
/// dem Fuß, ohne dass sich etwas überdeckt. Reicht der Platz nicht, wird das Inhaltsverzeichnis zweispaltig, dann
/// kommt es auf eine eigene Seite; die Gesamtansicht schrumpft dabei nie unter `bildMin`.
public struct DeckblattAufteilung: Equatable {
    public static let rand: CGFloat = 22
    public static let kachelRaster: CGFloat = 20
    public static let bildMin: CGFloat = 50
    /// Abstand des letzten Inhalts zur Fußlinie.
    public static let fussAbstand: CGFloat = 8

    public var bild: CGRect
    /// Spalte für Kennzahlen und Inhalt (hoch: ganze Breite unter dem Bild; quer: rechts neben dem Bild).
    public var spalte: CGRect
    public var kachelSpalten: Int
    public var kachelnY: CGFloat
    public var inhaltY: CGFloat
    public var inhaltSpalten: Int
    public var inhaltAufDeckblatt: Bool
    public var fussY: CGFloat
    /// Unterkante des Inhaltsverzeichnisses (bzw. der Kennzahlen ohne Inhalt).
    public var inhaltEnde: CGFloat

    public static func inhaltHoehe(_ eintraege: Int, spalten: Int) -> CGFloat {
        6 + CGFloat((eintraege + spalten - 1) / max(1, spalten)) * 8
    }

    public init(groesse: CGSize, titelHoehe: CGFloat, kacheln: Int, eintraege: Int) {
        let w = groesse.width, h = groesse.height
        let x0 = Self.rand, x1 = w - Self.rand
        let quer = w > h
        // wie im Deckblatt: Kennband, „BAUUNTERLAGEN“, Titel, Zeile mit den Bausteinen
        let y = 39 + titelHoehe - 2 + 12
        fussY = h - 22
        let unten = fussY - Self.fussAbstand
        if quer {
            // rechts neben dem Bild: Kennzahlen zweispaltig; reicht das nicht für den Inhalt, ein schmaleres Bild und
            // dreispaltige Kennzahlen; sonst kommt der Inhalt auf eine eigene Seite
            var wahl: (anteil: CGFloat, spalten: Int, passt: Bool) = (0.58, 2, false)
            for (anteil, sp) in [(CGFloat(0.58), 2), (CGFloat(0.5), 3)] {
                let kh = CGFloat((kacheln + sp - 1) / sp) * Self.kachelRaster
                if y + kh + 8 + Self.inhaltHoehe(eintraege, spalten: 1) <= unten {
                    wahl = (anteil, sp, true)
                    break
                }
            }
            kachelSpalten = wahl.spalten
            let kachelnH = CGFloat((kacheln + kachelSpalten - 1) / kachelSpalten) * Self.kachelRaster
            let bildW = (x1 - x0) * wahl.anteil
            bild = CGRect(x: x0, y: y, width: bildW, height: max(Self.bildMin, unten - y))
            spalte = CGRect(x: x0 + bildW + 10, y: y, width: x1 - x0 - bildW - 10, height: unten - y)
            kachelnY = y
            inhaltY = y + kachelnH + 8
            inhaltSpalten = 1
            inhaltAufDeckblatt = wahl.passt
            inhaltEnde = inhaltAufDeckblatt ? inhaltY + Self.inhaltHoehe(eintraege, spalten: 1) : y + kachelnH
            return
        }
        kachelSpalten = min(3, max(1, kacheln))
        let kachelnH = CGFloat((kacheln + kachelSpalten - 1) / kachelSpalten) * Self.kachelRaster
        // hoch: Bild, darunter Kennzahlen (9 mm Abstand), Inhalt (8 mm Abstand)
        let frei = unten - y - 9 - kachelnH
        var spalten = 0
        for s in [1, 2] where frei - 8 - Self.inhaltHoehe(eintraege, spalten: s) >= Self.bildMin {
            spalten = s
            break
        }
        inhaltAufDeckblatt = spalten > 0
        inhaltSpalten = max(1, spalten)
        let inhaltH = inhaltAufDeckblatt ? 8 + Self.inhaltHoehe(eintraege, spalten: inhaltSpalten) : 0
        let bildH = min(inhaltAufDeckblatt ? 118 : 150, max(Self.bildMin, frei - inhaltH))
        bild = CGRect(x: x0, y: y, width: x1 - x0, height: bildH)
        kachelnY = bild.maxY + 9
        inhaltY = kachelnY + kachelnH + 8
        spalte = CGRect(x: x0, y: kachelnY, width: x1 - x0, height: unten - kachelnY)
        inhaltEnde = inhaltAufDeckblatt ? inhaltY + Self.inhaltHoehe(eintraege, spalten: inhaltSpalten)
            : kachelnY + kachelnH
    }
}
