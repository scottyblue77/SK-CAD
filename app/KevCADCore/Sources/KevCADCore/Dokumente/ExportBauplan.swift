import CoreGraphics
import Foundation

// Bauplan als Seiten (Strang P6-A2): Anleitung im Stil von IKEA und LEGO mit Werkstatt-Ernst. Eine Einstiegsseite mit
// Werkzeug, Lesehilfe und Sicherheit; je Abschnitt eine neue Seite; Montageschritte groß, je Schritt eine Seite;
// Zuschnitt, Bearbeiten und Drucken kompakt mit Bild links. Mengen deutlich („4×“), Sicherheit gelb, Probleme rot.

public enum ExportBauplanSeiten {
    static let nummerGroesse: CGFloat = 11

    public static func seiten(_ q: ExportQuellen, _ format: ExportSeitenformat, _ hinweise: inout [String]) -> [ExportSeite] {
        guard let plan = q.bauplan, !plan.alleSchritte.isEmpty else {
            hinweise.append("Bauplan noch nicht gerechnet: in der App unter Dokumente › Bauplan öffnen oder "
                            + "bauplan() aufrufen")
            return ExportBauer.flussSeiten(.bauplan, format, [ExportBauer.ueberschrift("Bauplan", nil),
                                                             ExportBauer.leer("Noch kein Bauplan")])
        }
        let ohneBild = plan.alleSchritte.filter { $0.bild != nil && q.strichbilder[$0.id] == nil }.count
        if ohneBild > 0 { hinweise.append("Bauplan: \(ohneBild) Schritte ohne Strichbild") }
        var bloecke: [ExportBlock] = []
        bloecke += einstieg(plan)
        for a in plan.abschnitte where !a.schritte.isEmpty {
            bloecke.append(.neueSeite)
            bloecke.append(.marke(a.titel))
            bloecke.append(abschnittKopf(a, plan))
            for (i, s) in a.schritte.enumerated() {
                let nr = plan.nummer(s.id) ?? 0
                switch a.art {
                case .montage:
                    // je Montageschritt eine Seite; der erste teilt sie mit dem Kopf des Abschnitts
                    if i > 0 { bloecke.append(.neueSeite) }
                    bloecke.append(montageSchritt(s, nr: nr, bild: q.strichbilder[s.id], format: format,
                                                  abzug: i == 0 ? 24 : 0))
                case .material:
                    bloecke += materialSchritt(s, nr: nr)
                default:
                    bloecke.append(kompakterSchritt(s, nr: nr, art: a.art, bild: q.strichbilder[s.id]))
                    if !s.bohrbild.isEmpty { bloecke.append(.tabelle(bohrTabelle(s))) }
                    if !s.pruefung.isEmpty { bloecke.append(befundBlock(s.pruefung)) }
                    bloecke.append(.abstand(7))
                }
            }
        }
        return ExportBauer.flussSeiten(.bauplan, format, bloecke)
    }

    // MARK: Einstieg: Überblick, Werkzeug, Lesehilfe, Sicherheit

    static func einstieg(_ plan: Bauplan) -> [ExportBlock] {
        var b: [ExportBlock] = []
        let n = plan.alleSchritte.count
        var kz = "\(KevFormat.count(n, one: "Schritt", many: "Schritte")) in "
            + KevFormat.count(plan.abschnitte.filter { !$0.schritte.isEmpty }.count, one: "Abschnitt", many: "Abschnitten")
        let probleme = plan.fehlerAnzahl + plan.warnungAnzahl
        kz += probleme == 0 ? " · Simulation ohne Probleme"
            : " · Simulation: \(KevFormat.count(probleme, one: "Problem", many: "Probleme"))"
        b.append(ExportBauer.ueberschrift("Bauplan", kz))
        // Abschnitte mit Schrittbereich
        b.append(.fest(hoehe: CGFloat(plan.abschnitte.filter { !$0.schritte.isEmpty }.count) * 8 + 4, mitNaechstem: false) { l, r in
            var y = r.minY + 2
            for a in plan.abschnitte where !a.schritte.isEmpty {
                let von = plan.nummer(a.schritte.first!.id) ?? 0, bis = plan.nummer(a.schritte.last!.id) ?? 0
                l.rechteck(CGRect(x: r.minX, y: y, width: 6, height: 6), fuellung: ExportStil.tinte, radius: 1.2)
                ExportPiktogramm.zeichne(piktogramm(a.art), in: CGRect(x: r.minX + 0.9, y: y + 0.9, width: 4.2, height: 4.2),
                                         ctx: l.ctx, farbe: ExportStil.weiss)
                l.text(a.titel, x: r.minX + 9, y: y + 4.4, .mittel(10), farbe: ExportStil.tinte)
                let t = von == bis ? "Schritt \(von)" : "Schritte \(von)–\(bis)"
                l.text(t, x: r.maxX, y: y + 4.4, .normal(9), farbe: ExportStil.grau, .rechts)
                l.linie(CGPoint(x: r.minX + 9, y: y + 6.6), CGPoint(x: r.maxX, y: y + 6.6), breite: 0.1,
                        farbe: ExportStil.linieFein)
                y += 8
            }
        })
        b.append(.abstand(6))
        // Werkzeug wie auf der ersten Seite einer IKEA-Anleitung
        let werkzeug = plan.alleWerkzeuge
        if !werkzeug.isEmpty {
            b.append(ExportBauer.zwischentitel("Werkzeug", "für den ganzen Aufbau"))
            let spalten = 3
            let zeilen = (werkzeug.count + spalten - 1) / spalten
            b.append(.fest(hoehe: CGFloat(zeilen) * 11 + 2, mitNaechstem: false) { l, r in
                let w = (r.width - CGFloat(spalten - 1) * 3) / CGFloat(spalten)
                for (i, t) in werkzeug.enumerated() {
                    let x = r.minX + CGFloat(i % spalten) * (w + 3)
                    let y = r.minY + CGFloat(i / spalten) * 11
                    l.rechteck(CGRect(x: x, y: y, width: w, height: 9), fuellung: ExportStil.flaeche, radius: 1.5)
                    ExportPiktogramm.zeichne(BauplanWerkzeug.art(t), in: CGRect(x: x + 1.5, y: y + 1.5, width: 6, height: 6),
                                             ctx: l.ctx, farbe: ExportStil.tinte)
                    l.absatz(t, x: x + 9.5, y: y + 1.2, breite: w - 11, .normal(7.8), farbe: ExportStil.tinte,
                             maxZeilen: 2)
                }
            })
            b.append(.abstand(6))
        }
        // Lesehilfe
        b.append(ExportBauer.zwischentitel("So liest du die Anleitung"))
        b.append(.fest(hoehe: 30, mitNaechstem: false) { l, r in
            let spalten = 4
            let w = (r.width - CGFloat(spalten - 1) * 3) / CGFloat(spalten)
            let eintraege: [(String, String)] = [
                ("Schwarz", "bereits montiert"), ("Grau", "Werkstück beim Bearbeiten"),
                ("Orange", "neu in diesem Schritt"), ("Pfeil", "Einführrichtung"),
                ("4×", "so oft wiederholen"), ("Gelb", "Sicherheit beachten"), ("Rot", "Problem aus der Simulation"),
            ]
            for (i, e) in eintraege.enumerated() {
                let x = r.minX + CGFloat(i % spalten) * (w + 3)
                let y = r.minY + CGFloat(i / spalten) * 14
                let icon = CGRect(x: x, y: y + 1, width: 10, height: 10)
                switch i {
                case 0:
                    l.rechteck(icon.insetBy(dx: 1.5, dy: 2.5), rand: ExportStil.tinte, randBreite: 0.3)
                case 1:
                    l.rechteck(icon.insetBy(dx: 1.5, dy: 2.5), rand: BauplanPalette.papier.kontext, randBreite: 0.22)
                case 2:
                    l.rechteck(icon.insetBy(dx: 1.5, dy: 2.5), rand: ExportStil.akzent, randBreite: 0.45)
                case 3:
                    l.linie(CGPoint(x: icon.midX, y: icon.minY + 1), CGPoint(x: icon.midX, y: icon.maxY - 2.5), breite: 0.45,
                            farbe: ExportStil.akzent)
                    let tri = CGMutablePath()
                    tri.addLines(between: [CGPoint(x: icon.midX - 1.6, y: icon.maxY - 3.2), CGPoint(x: icon.midX, y: icon.maxY - 0.6),
                                           CGPoint(x: icon.midX + 1.6, y: icon.maxY - 3.2)])
                    tri.closeSubpath()
                    l.ctx.addPath(tri)
                    l.ctx.setFillColor(ExportStil.akzent)
                    l.ctx.fillPath()
                case 4:
                    l.text("4×", x: icon.midX, y: icon.midY + 2, .fett(12), farbe: ExportStil.tinte, .mitte)
                case 5:
                    l.rechteck(icon.insetBy(dx: 0.5, dy: 2), fuellung: ExportStil.gelb, radius: 1)
                    l.text("!", x: icon.midX, y: icon.midY + 1.6, .fett(10), farbe: ExportStil.tinte, .mitte)
                default:
                    l.rechteck(icon.insetBy(dx: 0.5, dy: 2), fuellung: ExportStil.rotHell, rand: ExportStil.rot,
                               randBreite: 0.3, radius: 1)
                }
                l.text(e.0, x: x + 13, y: y + 5, .mittel(9), farbe: ExportStil.tinte)
                _ = l.absatz(e.1, x: x + 13, y: y + 7.2, breite: w - 13, .normal(8), farbe: ExportStil.grau, maxZeilen: 2)
            }
        })
        // Sicherheit: alle Sicherheitshinweise der Schritte ohne Doppel
        var gesehen = Set<String>()
        let sicherheit = plan.alleSchritte.flatMap(\.sicherheitsHinweise).filter { gesehen.insert($0).inserted }
        if !sicherheit.isEmpty {
            b.append(.abstand(6))
            b.append(sicherheitsBlock(Array(sicherheit.prefix(8)), titel: "Sicherheit beim ganzen Aufbau"))
        }
        if !plan.nichtImAufbau.isEmpty || plan.ohneVerbinde {
            b.append(.abstand(4))
            if plan.ohneVerbinde {
                b.append(ExportBauer.hinweisZeile("Das Modell beschreibt keine Verbindungen (verbinde): Verbindungsmittel "
                                                  + "und Werkzeug sind aus Kontakt und Normteilen geschätzt."))
            }
            for t in plan.nichtImAufbau.prefix(6) {
                b.append(ExportBauer.hinweisZeile("Nicht im Aufbau: \(t.teil) (\(t.grund))"))
            }
        }
        return b
    }

    static func piktogramm(_ art: BauplanAbschnittArt) -> BauplanWerkzeug.Art {
        switch art {
        case .material: return .hand
        case .zuschnitt: return .saege
        case .bearbeiten: return .bohrer
        case .drucken: return .drucker
        case .montage: return .innensechskant
        case .andere: return .allgemein
        }
    }

    static func abschnittKopf(_ a: BauplanAbschnitt, _ plan: Bauplan) -> ExportBlock {
        .fest(hoehe: 22, mitNaechstem: true) { l, r in
            let idx = (plan.abschnitte.filter { !$0.schritte.isEmpty }.firstIndex { $0.art == a.art } ?? 0) + 1
            let badge = CGRect(x: r.minX, y: r.minY + 1, width: 15, height: 15)
            l.rechteck(badge, fuellung: ExportStil.tinte, radius: 2.5)
            ExportPiktogramm.zeichne(piktogramm(a.art), in: badge.insetBy(dx: 2.6, dy: 2.6), ctx: l.ctx,
                                     farbe: ExportStil.weiss)
            l.text("ABSCHNITT \(idx)", x: r.minX + 19, y: r.minY + 5.5, .mittel(7.5), farbe: ExportStil.akzent, laufweite: 0.3)
            l.text(a.titel, x: r.minX + 19, y: r.minY + 14, .fett(19), farbe: ExportStil.tinte)
            let n = a.schritte.count
            l.text(KevFormat.count(n, one: "Schritt", many: "Schritte"), x: r.maxX, y: r.minY + 14, .normal(9.5),
                   farbe: ExportStil.grau, .rechts)
            l.linie(CGPoint(x: r.minX, y: r.minY + 19.5), CGPoint(x: r.maxX, y: r.minY + 19.5), breite: 0.3,
                    farbe: ExportStil.tinte)
        }
    }

    // MARK: Bausteine eines Schritts

    /// Schrittnummer als Plakette.
    static func nummer(_ l: ExportLeinwand, _ nr: Int, _ at: CGPoint, groesse: CGFloat = nummerGroesse) {
        let r = CGRect(x: at.x, y: at.y, width: groesse, height: groesse)
        l.rechteck(r, fuellung: ExportStil.akzent, radius: groesse * 0.22)
        let pt: CGFloat = nr >= 100 ? groesse * 1.15 : groesse * 1.45
        l.text("\(nr)", x: r.midX, y: r.midY + pt / ExportSeitenformat.ptJeMM * 0.36, .fett(pt), farbe: ExportStil.weiss, .mitte)
    }

    /// Kopfzeile eines Schritts: Nummer, Titel, Untertitel, Wiederholung.
    static func kopf(_ l: ExportLeinwand, _ s: BauplanSchritt, nr: Int, r: CGRect, unter: String?, gross: Bool) {
        let g: CGFloat = gross ? 13 : nummerGroesse
        nummer(l, nr, CGPoint(x: r.minX, y: r.minY), groesse: g)
        let rechtsFrei: CGFloat = s.anzahl > 1 ? 24 : 0
        let titelPt: CGFloat = gross ? 15 : 12
        let x = r.minX + g + 4
        l.text(s.titel, x: x, y: r.minY + (unter == nil ? g * 0.68 : g * 0.52), .fett(titelPt), farbe: ExportStil.tinte,
               maxBreite: r.width - g - 6 - rechtsFrei)
        if let unter {
            l.text(unter, x: x, y: r.minY + g * 0.95, .normal(8), farbe: ExportStil.grau, maxBreite: r.width - g - 6 - rechtsFrei)
        }
        var marken: [String] = []
        if s.fest { marken.append("fest") }
        if s.quelle == "kevin" { marken.append("von \(AppInfo.nutzerName)") } else if s.quelle == "agent" { marken.append("überarbeitet") }
        if s.verwaist { marken.append("Teile fehlen im Modell") }
        if s.anzahl > 1 {
            let box = CGRect(x: r.maxX - 21, y: r.minY, width: 21, height: g)
            l.rechteck(box, rand: ExportStil.tinte, randBreite: 0.45, radius: 2)
            l.text(BauplanText.menge(s.anzahl), x: box.midX, y: box.midY + 2.1, .fett(gross ? 16 : 13),
                   farbe: ExportStil.tinte, .mitte)
        } else if !marken.isEmpty {
            l.text(marken.joined(separator: " · "), x: r.maxX, y: r.minY + 4, .normal(7), farbe: ExportStil.grauHell, .rechts)
        }
    }

    /// Bildfeld mit Strichbild oder Platzhalter.
    static func bildFeld(_ l: ExportLeinwand, _ bild: BauplanStrichbild?, _ r: CGRect) {
        l.rechteck(r, rand: ExportStil.linieFein, randBreite: 0.2, radius: 2)
        if let bild, !bild.leer {
            BauplanZeichner.zeichne(bild, in: l.ctx, ziel: r.insetBy(dx: 2, dy: 2), palette: .papier)
        } else {
            l.text(bild?.fehler.map { "Kein Bild: \($0)" } ?? "Kein Bild", x: r.midX, y: r.midY + 1, .normal(8),
                   farbe: ExportStil.grauHell, .mitte, maxBreite: r.width - 6)
        }
    }

    /// Mengenliste im Stil eines LEGO-Teilekastens: „4×“ groß in Akzentfarbe, Name daneben.
    static func mengenListe(_ eintraege: [(Int, String)], max: Int = 9) -> [(String, String)] {
        var out = eintraege.prefix(max).map { ("\($0.0)×", $0.1) }
        if eintraege.count > max {
            let rest = eintraege.dropFirst(max).reduce(0) { $0 + $1.0 }
            out.append(("+\(rest)", "weitere Teile"))
        }
        return out
    }

    static func vmEintraege(_ s: BauplanSchritt) -> [(Int, String)] {
        s.verbindungsmittel.map { v in
            var name = v.benennung
            if let lg = v.laenge, !name.contains("×"), !name.lowercased().contains("länge") {
                name += " × \(KevFormat.compact(lg, maxDigits: 1))"
            }
            return (v.anzahl, name + (v.geschaetzt ? " (geschätzt)" : ""))
        }
    }

    static func kastenHoehe(_ zeilen: Int) -> CGFloat { zeilen == 0 ? 0 : 8 + CGFloat(zeilen) * 5.6 + 1.5 }

    /// Kasten mit Überschrift und Mengenzeilen; liefert die Höhe.
    @discardableResult
    static func kasten(_ l: ExportLeinwand, titel: String, _ zeilen: [(String, String)], x: CGFloat, y: CGFloat,
                       breite: CGFloat) -> CGFloat
    {
        guard !zeilen.isEmpty else { return 0 }
        let h = kastenHoehe(zeilen.count)
        l.rechteck(CGRect(x: x, y: y, width: breite, height: h), fuellung: ExportStil.flaeche, radius: 2)
        l.text(titel.uppercased(), x: x + 3, y: y + 5, .mittel(6.8), farbe: ExportStil.grau, laufweite: 0.25)
        var yy = y + 8
        for (m, t) in zeilen {
            l.text(m, x: x + 3, y: yy + 4.2, .fett(10.5), farbe: ExportStil.akzent)
            l.text(t, x: x + 15, y: yy + 4.1, .normal(8.5), farbe: ExportStil.tinte, maxBreite: breite - 18)
            yy += 5.6
        }
        return h
    }

    static func werkzeugHoehe(_ s: BauplanSchritt) -> CGFloat { s.werkzeug.isEmpty ? 0 : 8 + CGFloat(s.werkzeug.count) * 6 }

    @discardableResult
    static func werkzeugListe(_ l: ExportLeinwand, _ s: BauplanSchritt, x: CGFloat, y: CGFloat, breite: CGFloat) -> CGFloat {
        guard !s.werkzeug.isEmpty else { return 0 }
        l.text("WERKZEUG", x: x, y: y + 4, .mittel(6.8), farbe: ExportStil.grau, laufweite: 0.25)
        var yy = y + 6.5
        for w in s.werkzeug {
            let ikon = CGRect(x: x, y: yy, width: 5, height: 5)
            l.rechteck(ikon, rand: ExportStil.tinte, randBreite: 0.2, radius: 1)
            ExportPiktogramm.zeichne(BauplanWerkzeug.art(w), in: ikon.insetBy(dx: 0.6, dy: 0.6), ctx: l.ctx,
                                     farbe: ExportStil.tinte)
            l.text(w, x: x + 7, y: yy + 3.7, .normal(8.3), farbe: ExportStil.tinte, maxBreite: breite - 8)
            yy += 6
        }
        return yy - y
    }

    static func sicherheitsHoehe(_ texte: [String], breite: CGFloat) -> CGFloat {
        guard !texte.isEmpty else { return 0 }
        return texte.reduce(CGFloat(4)) { $0 + ExportSatz($1, breite: breite - 14, schrift: .mittel(8.5)).hoehe + 1.2 } + 1
    }

    static func sicherheit(_ l: ExportLeinwand, _ texte: [String], x: CGFloat, y: CGFloat, breite: CGFloat) -> CGFloat {
        guard !texte.isEmpty else { return 0 }
        let h = sicherheitsHoehe(texte, breite: breite)
        let r = CGRect(x: x, y: y, width: breite, height: h)
        l.rechteck(r, fuellung: ExportStil.gelbHell, radius: 1.8)
        l.rechteck(CGRect(x: x, y: y, width: 1.6, height: h), fuellung: ExportStil.gelb)
        // Warndreieck
        let d = CGRect(x: x + 4, y: y + 2.2, width: 5.6, height: 5)
        let tri = CGMutablePath()
        tri.addLines(between: [CGPoint(x: d.midX, y: d.minY), CGPoint(x: d.maxX, y: d.maxY), CGPoint(x: d.minX, y: d.maxY)])
        tri.closeSubpath()
        l.ctx.saveGState()
        l.ctx.addPath(tri)
        l.ctx.setFillColor(ExportStil.gelb)
        l.ctx.setStrokeColor(ExportStil.tinte)
        l.ctx.setLineWidth(0.35)
        l.ctx.drawPath(using: .fillStroke)
        l.ctx.restoreGState()
        l.text("!", x: d.midX, y: d.maxY - 0.6, .fett(8), farbe: ExportStil.tinte, .mitte)
        var yy = y + 2
        for t in texte {
            yy += l.absatz(t, x: x + 12, y: yy, breite: breite - 14, .mittel(8.5), farbe: ExportStil.tinte) + 1.2
        }
        return h
    }

    static func sicherheitsBlock(_ texte: [String], titel: String) -> ExportBlock {
        let breite: CGFloat = 178
        let h = sicherheitsHoehe(texte, breite: breite) + 8
        return .fest(hoehe: h, mitNaechstem: false) { l, r in
            l.text(titel, x: r.minX, y: r.minY + 5, .fett(11.5), farbe: ExportStil.tinte)
            sicherheit(l, texte, x: r.minX, y: r.minY + 8, breite: r.width)
        }
    }

    static func hinweisHoehe(_ texte: [String], breite: CGFloat) -> CGFloat {
        texte.reduce(CGFloat(0)) { $0 + ExportSatz($1, breite: breite - 4, schrift: .normal(8.5)).hoehe + 1 }
    }

    @discardableResult
    static func hinweisListe(_ l: ExportLeinwand, _ texte: [String], x: CGFloat, y: CGFloat, breite: CGFloat) -> CGFloat {
        var yy = y
        for t in texte {
            l.kreis(CGPoint(x: x + 1, y: yy + 2.1), radius: 0.55, fuellung: ExportStil.grau)
            yy += l.absatz(t, x: x + 4, y: yy, breite: breite - 4, .normal(8.5), farbe: ExportStil.grau) + 1
        }
        return yy - y
    }

    static func befundHoehe(_ befunde: [BauplanBefund], breite: CGFloat) -> CGFloat {
        let befunde = BauplanBefund.zusammengefasst(befunde)
        guard !befunde.isEmpty else { return 0 }
        return befunde.reduce(CGFloat(3)) { h, b in
            h + ExportSatz(befundText(b), breite: breite - 10, schrift: .normal(8.3)).hoehe + 2
        } + 1
    }

    static func befundText(_ b: BauplanBefund) -> String {
        "\(b.schwere.titel) · \(b.artTitel): \(b.text)" + (b.loesung.map { "\nLösung: \($0)" } ?? "")
    }

    @discardableResult
    static func befunde(_ l: ExportLeinwand, _ befunde: [BauplanBefund], x: CGFloat, y: CGFloat, breite: CGFloat)
        -> CGFloat
    {
        guard !befunde.isEmpty else { return 0 }
        let h = befundHoehe(befunde, breite: breite)
        let befunde = BauplanBefund.zusammengefasst(befunde)
        let schwer = befunde.contains { $0.schwere != .hinweis }
        l.rechteck(CGRect(x: x, y: y, width: breite, height: h), fuellung: schwer ? ExportStil.rotHell : ExportStil.flaeche,
                   radius: 1.8)
        l.rechteck(CGRect(x: x, y: y, width: 1.6, height: h), fuellung: schwer ? ExportStil.rot : ExportStil.grauHell)
        var yy = y + 2
        for b in befunde.sorted(by: { $0.schwere < $1.schwere }) {
            let farbe = b.schwere == .hinweis ? ExportStil.grau : ExportStil.rot
            l.kreis(CGPoint(x: x + 5, y: yy + 2.2), radius: 1.1, fuellung: farbe)
            yy += l.absatz(befundText(b), x: x + 8, y: yy, breite: breite - 10, .normal(8.3), farbe: ExportStil.tinte) + 2
        }
        return h
    }

    static func befundBlock(_ liste: [BauplanBefund]) -> ExportBlock {
        let h = befundHoehe(liste, breite: 178) + 3
        return .fest(hoehe: h, mitNaechstem: false) { l, r in
            befunde(l, liste, x: r.minX, y: r.minY + 2, breite: r.width)
        }
    }

    // MARK: Montageschritt (eine Seite)

    static func montageSchritt(_ s: BauplanSchritt, nr: Int, bild: BauplanStrichbild?, format: ExportSeitenformat,
                               abzug: CGFloat = 0) -> ExportBlock {
        let inhalt = ExportRand.inhalt(format.mm)
        let breite = inhalt.width
        let links = breite * 0.58, rechts = breite - links - 6
        let teile = mengenListe(s.neueTeileGruppiert.map { ($0.anzahl, $0.name) })
        let vm = mengenListe(vmEintraege(s))
        let textH = s.text.isEmpty ? 0 : ExportSatz(s.text, breite: links, schrift: .normal(10), zeilenabstand: 1.12).hoehe + 3
        let sicherH = sicherheitsHoehe(s.sicherheitsHinweise, breite: links)
        let hinwH = hinweisHoehe(s.uebrigeHinweise, breite: links)
        let linksH = textH + (sicherH > 0 ? sicherH + 3 : 0) + hinwH
        let rechtsH = kastenHoehe(teile.count) + (vm.isEmpty ? 0 : kastenHoehe(vm.count) + 3) + werkzeugHoehe(s) + 2
        let unten = max(linksH, rechtsH)
        let befH = befundHoehe(s.pruefung, breite: breite)
        let kopfH: CGFloat = 18
        let bildH = min(170, max(60, inhalt.height - abzug - kopfH - unten - befH - 14))
        let gesamt = kopfH + bildH + 5 + unten + (befH > 0 ? befH + 4 : 0)
        let unter = s.baugruppe.map { "Vormontage \($0)" } ?? "Hauptmontage"
        return .fest(hoehe: gesamt, mitNaechstem: false) { l, r in
            kopf(l, s, nr: nr, r: CGRect(x: r.minX, y: r.minY, width: r.width, height: 13), unter: unter, gross: true)
            let bildR = CGRect(x: r.minX, y: r.minY + kopfH, width: r.width, height: bildH)
            bildFeld(l, bild, bildR)
            var y = bildR.maxY + 5
            // links: Text, Sicherheit, Hinweise
            var yl = y
            if !s.text.isEmpty {
                yl += l.absatz(s.text, x: r.minX, y: yl, breite: links, .normal(10), farbe: ExportStil.tinte,
                               zeilenabstand: 1.12) + 3
            }
            if !s.sicherheitsHinweise.isEmpty {
                yl += sicherheit(l, s.sicherheitsHinweise, x: r.minX, y: yl, breite: links) + 3
            }
            hinweisListe(l, s.uebrigeHinweise, x: r.minX, y: yl, breite: links)
            // rechts: Teile, Verbindungsmittel, Werkzeug
            let xr = r.minX + links + 6
            var yr = y
            yr += kasten(l, titel: "Neu in diesem Schritt", teile, x: xr, y: yr, breite: rechts)
            if !vm.isEmpty {
                yr += 3
                yr += kasten(l, titel: "Verbindungsmittel", vm, x: xr, y: yr, breite: rechts)
            }
            if !s.werkzeug.isEmpty {
                yr += 2
                werkzeugListe(l, s, x: xr, y: yr, breite: rechts)
            }
            y += unten + 4
            if befH > 0 { befunde(l, s.pruefung, x: r.minX, y: y, breite: r.width) }
        }
    }

    // MARK: Kompakter Schritt (Zuschnitt, Bearbeiten, Drucken)

    static func details(_ s: BauplanSchritt, _ art: BauplanAbschnittArt) -> [(String, String)] {
        var out: [(String, String)] = []
        for z in s.zuschnitt {
            var t = "\(z.anzahl)× \(KevFormat.length(z.laenge))"
            let g = KevFormat.gehrung(z.gehrung)
            if g != "–" { t += ", Gehrung \(g)" }
            out.append(("Ablängen", t))
        }
        if let d = s.druck {
            if let m = d.material { out.append(("Material", m.uppercased())) }
            if let seite = d.seite { out.append(("Lage", seite + " aufs Bett")) }
            if let h = d.hoeheMM { out.append(("Höhe", KevFormat.length(h))) }
            if let g = d.masseG { out.append(("Filament", "je ≈ \(KevFormat.mass(grams: g))")) }
        }
        return out
    }

    static func kompakterSchritt(_ s: BauplanSchritt, nr: Int, art: BauplanAbschnittArt, bild: BauplanStrichbild?) -> ExportBlock {
        let breite: CGFloat = 178
        let mitBild = s.bild != nil
        let bildW: CGFloat = mitBild ? 74 : 0
        let textX = mitBild ? bildW + 6 : 0
        let spalte = breite - textX
        let det = details(s, art)
        let textH = s.text.isEmpty ? 0 : ExportSatz(s.text, breite: spalte, schrift: .normal(9.5), zeilenabstand: 1.1).hoehe + 2.5
        let detH: CGFloat = det.isEmpty ? 0 : CGFloat(det.count) * 4.8 + 2
        let sicherH = sicherheitsHoehe(s.sicherheitsHinweise, breite: spalte)
        // Hinweise laufen unter Bild und Text über die ganze Breite (lange Druckhinweise brauchen so weniger Zeilen)
        let hinwH = hinweisHoehe(s.uebrigeHinweise, breite: breite)
        let wzH = werkzeugHoehe(s)
        let rechtsH = textH + detH + wzH + (sicherH > 0 ? sicherH + 2 : 0)
        let bildH: CGFloat = mitBild ? 50 : 0
        let kopfH: CGFloat = 14
        let oben = max(bildH, rechtsH)
        let gesamt = kopfH + oben + (hinwH > 0 ? hinwH + 3 : 0) + 2
        let unter: String? = {
            switch art {
            case .zuschnitt: return s.zuschnitt.first.map { "Lagerteil \($0.stockID)" }
            case .drucken: return s.druck?.material.map { "3D-Druck · \($0.uppercased())" }
            case .bearbeiten:
                return s.bohrbild.isEmpty ? nil : KevFormat.count(s.bohrbild.count, one: "Bohrung", many: "Bohrungen")
            default: return nil
            }
        }()
        return .fest(hoehe: gesamt, mitNaechstem: false) { l, r in
            kopf(l, s, nr: nr, r: CGRect(x: r.minX, y: r.minY, width: r.width, height: 11), unter: unter, gross: false)
            let y0 = r.minY + kopfH
            if mitBild { bildFeld(l, bild, CGRect(x: r.minX, y: y0, width: bildW, height: bildH)) }
            let x = r.minX + textX
            let w = r.width - textX
            var y = y0
            if !s.text.isEmpty {
                y += l.absatz(s.text, x: x, y: y, breite: w, .normal(9.5), farbe: ExportStil.tinte, zeilenabstand: 1.1) + 2.5
            }
            if !det.isEmpty {
                for (k, v) in det {
                    l.text(k.uppercased(), x: x, y: y + 3.4, .mittel(6.8), farbe: ExportStil.grau, laufweite: 0.2)
                    l.text(v, x: x + 22, y: y + 3.5, .mittel(8.8), farbe: ExportStil.tinte, maxBreite: w - 22)
                    y += 4.8
                }
                y += 2
            }
            if !s.werkzeug.isEmpty { y += werkzeugListe(l, s, x: x, y: y, breite: w) }
            if !s.sicherheitsHinweise.isEmpty { y += sicherheit(l, s.sicherheitsHinweise, x: x, y: y, breite: w) + 2 }
            hinweisListe(l, s.uebrigeHinweise, x: r.minX, y: y0 + oben + 3, breite: r.width)
        }
    }

    static func bohrTabelle(_ s: BauplanSchritt) -> ExportTabelle {
        let spalten = [
            ExportSpalte("nr", "Nr.", mindest: 8, .rechts), ExportSpalte("teil", "Teil", mindest: 34, gewicht: 2),
            ExportSpalte("bohrer", "Bohrer", mindest: 26, gewicht: 1), ExportSpalte("lage", "Lage", mindest: 26, gewicht: 1),
            ExportSpalte("von", "gemessen ab", mindest: 34, gewicht: 1.5), ExportSpalte("tiefe", "Tiefe", mindest: 14, .rechts),
            ExportSpalte("zusatz", "Senkung / für", mindest: 22, gewicht: 0.8),
        ]
        let zeilen = s.bohrbild.enumerated().map { i, b in
            ExportZeile([
                "nr": ExportZelle("\(i + 1)"), "teil": ExportZelle(BauplanSchritt.kurzname(b.teil)),
                "bohrer": ExportZelle(b.bohrerText, fett: true), "lage": ExportZelle(b.lageText),
                "von": ExportZelle(b.von ?? "–"), "tiefe": ExportZelle(b.tiefe.map(KevFormat.length) ?? "durch"),
                "zusatz": ExportZelle([b.senkung, b.fuer.map { "für \($0)" }].compactMap { $0 }.joined(separator: ", ")),
            ])
        }
        var t = ExportTabelle(spalten: spalten, zeilen: zeilen)
        t.schrift = .normal(8)
        t.bildHoehe = 0
        return t
    }

    // MARK: Material

    static func materialSchritt(_ s: BauplanSchritt, nr: Int) -> [ExportBlock] {
        var out: [ExportBlock] = [.fest(hoehe: 14, mitNaechstem: true) { l, r in
            kopf(l, s, nr: nr, r: CGRect(x: r.minX, y: r.minY, width: r.width, height: 11),
                 unter: s.text.isEmpty ? nil : s.text, gross: false)
        }]
        if !s.material.isEmpty {
            let spalten = [
                ExportSpalte("abhaken", "", mindest: 7, .mitte), ExportSpalte("menge", "Menge", mindest: 14, .rechts),
                ExportSpalte("einheit", "Einheit", mindest: 26, gewicht: 0.7),
                ExportSpalte("benennung", "Benennung", mindest: 60, gewicht: 3),
                ExportSpalte("quelle", "Herkunft", mindest: 22, gewicht: 0.8),
                ExportSpalte("preis", "Preis", mindest: 16, .rechts),
            ]
            let zeilen = s.material.map { m in
                ExportZeile([
                    "abhaken": ExportZelle(kaestchen: true), "menge": ExportZelle(KevFormat.compact(m.menge, maxDigits: 3), fett: true),
                    "einheit": ExportZelle(m.einheit), "benennung": ExportZelle(m.benennung, unter: m.hinweis),
                    "quelle": ExportZelle(m.quelle ?? ""), "preis": ExportZelle(m.preis.map(KevFormat.euro) ?? "–"),
                ])
            }
            var t = ExportTabelle(spalten: spalten, zeilen: zeilen)
            t.bildHoehe = 0
            out.append(.tabelle(t))
        } else if !s.teile.isEmpty {
            // ohne Materialliste: Teile nach Kurzname gezählt
            var reihenfolge: [String] = []
            var zaehler: [String: Int] = [:]
            for t in s.teile {
                let k = BauplanText.ohneNummer(BauplanSchritt.kurzname(t))
                if zaehler[k] == nil { reihenfolge.append(k) }
                zaehler[k, default: 0] += 1
            }
            let zeilen = reihenfolge.map { k in
                ExportZeile(["abhaken": ExportZelle(kaestchen: true), "menge": ExportZelle("\(zaehler[k] ?? 1)×", fett: true),
                             "benennung": ExportZelle(k)])
            }
            var t = ExportTabelle(spalten: [ExportSpalte("abhaken", "", mindest: 7, .mitte),
                                            ExportSpalte("menge", "Menge", mindest: 14, .rechts),
                                            ExportSpalte("benennung", "Teil", mindest: 80, gewicht: 1)], zeilen: zeilen)
            t.bildHoehe = 0
            out.append(.tabelle(t))
        }
        if !s.hinweise.isEmpty {
            for h in s.hinweise { out.append(ExportBauer.hinweisZeile(h)) }
        }
        out.append(.abstand(7))
        return out
    }
}
