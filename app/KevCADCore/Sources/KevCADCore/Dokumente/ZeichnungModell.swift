import CoreGraphics
import Foundation

// Phase 6, Zeichnungen (DOKUMENTE.md, Vertrag 1.1 mit Anhang P6-Z): was die App vom Kernel bekommt, gelesen und
// fertig zum Zeichnen. Alle Lagen in Blatt-mm, Ursprung links unten, y nach oben. Gelesen wird nachsichtig wie bei allen
// Nachrichten: fehlende Felder haben Vorgaben, unbekannte Linienarten bleiben erhalten (die App zeichnet sie dünn).

/// Linienarten der Zeichnungen in der Reihenfolge des Vertrags (`linien_reihenfolge`, falls der Kopf sie nicht nennt).
public enum Linienart {
    public static let reihenfolge = ["sichtbar", "verdeckt", "mitte", "schnitt", "schraffur", "duenn", "nachbar", "bruch"]
}

/// Polylinien je Linienart (Name aus `linien_reihenfolge` → Polylinien in Blatt-mm).
public typealias LinienGruppe = [String: [[CGPoint]]]

/// Ausrichtung eines Textes an seiner Lage (Grundlinie).
public enum TextAnker: String, Sendable {
    case links, mitte, rechts
}

/// Ein Text auf dem Blatt (Schriftfeld, Tabellen, Ansichtstitel, Positionsnummern, Notizen, allgemeine Angaben) oder eine
/// Zahl einer steigenden Bemaßung. `lage` liegt auf der Grundlinie, `hoehe` ist die Versalhöhe in mm, `winkel` in Grad
/// gegen den Uhrzeigersinn.
public struct BlattText: Equatable, Sendable {
    public var text: String
    public var lage: CGPoint
    public var hoehe: Double
    public var winkel: Double
    public var anker: TextAnker
    public var art: String
    public var wert: Double?

    public init(
        text: String, lage: CGPoint, hoehe: Double = 3.5, winkel: Double = 0, anker: TextAnker = .links,
        art: String = "blatt", wert: Double? = nil
    ) {
        self.text = text
        self.lage = lage
        self.hoehe = hoehe
        self.winkel = winkel
        self.anker = anker
        self.art = art
        self.wert = wert
    }
}

/// Maßlinienbegrenzung: `voll` (gefüllter Pfeil), `punkt` (gefüllter Punkt), `ursprung` (offener Ursprungskreis der
/// steigenden Bemaßung).
public struct MassPfeil: Equatable, Sendable {
    public var spitze: CGPoint
    public var richtung: CGVector
    public var art: String
    public var laenge: Double
    public var breite: Double
    public var polygon: [CGPoint]

    public init(spitze: CGPoint, richtung: CGVector, art: String = "voll", laenge: Double = 2.5, breite: Double = 0.66,
                polygon: [CGPoint] = []) {
        self.spitze = spitze
        self.richtung = richtung
        self.art = art
        self.laenge = laenge
        self.breite = breite
        self.polygon = polygon
    }
}

/// Fertige Darstellung eines Maßes (DRAWING `masse[i]`).
public struct MassDarstellung: Identifiable, Equatable, Sendable {
    public var id: String
    public var linien: [[CGPoint]]
    public var pfeile: [MassPfeil]
    public var text: String
    public var textLage: CGPoint
    public var textWinkel: Double
    public var textHoehe: Double
    public var wert: Double?
    public var einheit: String
    /// Hülle der Zahl (Blatt-mm), nil bei älteren Kerneln.
    public var box: CGRect?
    /// Steigende Bemaßung: Zahl je Lage.
    public var texte: [BlattText]
    public var ansicht: String?
    public var art: String
    public var quelle: String
    public var fest: Bool
    public var verwaist: Bool

    public init(
        id: String, linien: [[CGPoint]] = [], pfeile: [MassPfeil] = [], text: String = "", textLage: CGPoint = .zero,
        textWinkel: Double = 0, textHoehe: Double = 3.5, wert: Double? = nil, einheit: String = "mm", box: CGRect? = nil,
        texte: [BlattText] = [], ansicht: String? = nil, art: String = "linear", quelle: String = "auto",
        fest: Bool = false, verwaist: Bool = false
    ) {
        self.id = id
        self.linien = linien
        self.pfeile = pfeile
        self.text = text
        self.textLage = textLage
        self.textWinkel = textWinkel
        self.textHoehe = textHoehe
        self.wert = wert
        self.einheit = einheit
        self.box = box
        self.texte = texte
        self.ansicht = ansicht
        self.art = art
        self.quelle = quelle
        self.fest = fest
        self.verwaist = verwaist
    }

    /// Von Kevin oder dem Agenten gesetzt (nicht automatisch).
    public var eigenes: Bool { quelle == "kevin" || quelle == "agent" }

    /// Hinweislinie mit Text (Bohrung, Gewinde, Fase …) statt Maßlinie: kein `versatz`, nur die Textlage ist frei.
    public var istHinweis: Bool {
        ["bohrung", "gewinde", "fase", "radius", "merkmal", "durchmesser"].contains(art) && pfeile.count <= 1
    }

    /// Lage für `mass_verschieben.text_lage`: bei Hinweisen der Knick der Hinweislinie (Anfang der Bezugslinie, so legt
    /// der Kernel sie ab), sonst die Mitte der Zahl.
    public var textAnker: CGPoint {
        if istHinweis, let pl = linien.first, pl.count >= 2 { return pl[1] }
        return textLage
    }
}

/// Eine Ansicht des Blatts oder (`id == "blatt"`) Rahmen, Schriftfeld, Tabellen und Positionsnummern.
public struct ZeichnungsGruppe: Identifiable, Equatable, Sendable {
    public var id: String
    public var art: String
    /// Rahmen der Ansicht in Blatt-mm (x0, y0, x1, y1 als Rechteck).
    public var rahmen: CGRect
    public var massstab: String?
    public var titel: String?
    public var linien: LinienGruppe

    public init(id: String, art: String, rahmen: CGRect, massstab: String? = nil, titel: String? = nil,
                linien: LinienGruppe = [:]) {
        self.id = id
        self.art = art
        self.rahmen = rahmen
        self.massstab = massstab
        self.titel = titel
        self.linien = linien
    }

    /// Rahmen, Schriftfeld, Tabellen (keine Ansicht).
    public var istBlatt: Bool { id == "blatt" || art == "blatt" }

    public var anzahlPolylinien: Int { linien.values.reduce(0) { $0 + $1.count } }
}

/// Befund der Blattprüfung (`pruefung[i]`).
public struct BlattBefund: Equatable, Sendable {
    public var art: String
    public var pruefung: String
    public var schwere: String
    public var text: String
    public var masse: [String]
    public var merkmal: String?

    public init(art: String = "bemassung", pruefung: String, schwere: String, text: String, masse: [String] = [],
                merkmal: String? = nil) {
        self.art = art
        self.pruefung = pruefung
        self.schwere = schwere
        self.text = text
        self.masse = masse
        self.merkmal = merkmal
    }
}

// MARK: - Blattdatei

/// Ansicht laut Blattdatei (`blatt.ansichten[i]`).
public struct BlattAnsichtEintrag: Identifiable, Equatable, Sendable {
    public var id: String
    public var art: String
    public var lage: CGPoint?
    public var massstab: String?
    public var fest: Bool
    public var optional: Bool
    public var titel: String?
}

/// Maß laut Blattdatei (`blatt.masse[i]`): Absicht, Bezüge und Lage, nicht die Darstellung.
public struct BlattMassEintrag: Identifiable, Equatable, Sendable {
    public var id: String
    public var art: String
    public var ansicht: String?
    public var richtung: String?
    public var versatz: Double?
    public var text: String?
    public var toleranz: String?
    public var quelle: String
    public var fest: Bool
    public var verwaist: Bool
    public var schluessel: String?
    public var seite: String?
    /// Letzte Ansatzpunkte relativ zur Mitte der Ansicht (Blatt-mm).
    public var anker: [CGPoint]
    /// Lage der Zahl nach einer Verschiebung (Zahl entlang der Maßlinie oder Punkt relativ zum Ziel).
    public var textVersatz: JSONValue?
    /// Bezüge wie gespeichert (für Rückgängig: ein gelöschtes eigenes Maß lässt sich damit neu anlegen).
    public var bezuege: [JSONValue]
}

public struct BlattNotiz: Identifiable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var lage: CGPoint
    public var zeiger: JSONValue?
    public var quelle: String
}

/// Ausgeblendetes automatisches Maß (`unterdrueckt[i]`).
public struct BlattUnterdrueckung: Equatable, Sendable {
    public var art: String
    public var ansicht: String?
    public var schluessel: String?
    public var bezuege: [JSONValue]

    /// Lesbare Bezeichnung wie „Durchmesser · bohrung:3“.
    public var beschreibung: String {
        let merkmale = bezuege.compactMap { $0["merkmal"]?.stringValue ?? $0["ref"]?.stringValue }
        let artText = ZeichnungText.massArt(art)
        if let s = schluessel, merkmale.isEmpty { return "\(artText) · \(s)" }
        return merkmale.isEmpty ? artText : "\(artText) · " + merkmale.joined(separator: ", ")
    }
}

/// Inhalt der Blattdatei (`DRAWING.blatt`), soweit die App ihn braucht; `json` ist das Original.
public struct BlattInfo: Equatable, Sendable {
    public var id: String
    public var titel: String
    public var format: String
    public var ausrichtung: String
    public var massstab: String
    public var inhaltArt: String
    public var teile: [String]
    public var schriftfeld: [String: JSONValue]
    public var schriftfeldFest: [String]
    public var ansichten: [BlattAnsichtEintrag]
    public var masse: [BlattMassEintrag]
    public var notizen: [BlattNotiz]
    public var unterdrueckt: [BlattUnterdrueckung]
    public var autoAnsichten: Bool
    public var autoMasse: Bool
    public var autoMassstab: Bool
    public var autoFormat: Bool
    public var allgemein: [String]
    public var json: JSONValue

    public func mass(_ id: String) -> BlattMassEintrag? { masse.first { $0.id == id } }
    public func ansicht(_ id: String) -> BlattAnsichtEintrag? { ansichten.first { $0.id == id } }

    /// Text eines Schriftfeldes für die Anzeige (Zahlen ohne „.0“).
    public func schriftfeldText(_ feld: String) -> String {
        guard let v = schriftfeld[feld] else { return "" }
        switch v {
        case .string(let s): return s
        case .number(let d): return d == d.rounded() && abs(d) < 1e12 ? String(Int(d)) : String(d)
        case .bool(let b): return b ? "ja" : "nein"
        default: return ""
        }
    }
}

// MARK: - DRAWING

/// Ein gerechnetes Blatt (Nachricht DRAWING), fertig zum Zeichnen.
public struct Zeichnung: Identifiable, Sendable {
    public var blatt: BlattInfo
    /// Blattgröße in mm (Breite, Höhe).
    public var groesse: CGSize
    /// Ansichten und zuletzt die Gruppe `blatt` (Rahmen, Schriftfeld, Tabellen).
    public var gruppen: [ZeichnungsGruppe]
    public var masse: [MassDarstellung]
    public var texte: [BlattText]
    public var gefuellt: [[CGPoint]]
    public var pruefung: [BlattBefund]
    public var hinweise: [String]
    public var stand: String
    public var run: Int?
    public var linienReihenfolge: [String]
    /// Vorbereitete Pfade und Texte (einmal je Blatt gerechnet, danach nur noch gezeichnet).
    public let grafik: BlattGrafik

    public var id: String { blatt.id }

    public init(
        blatt: BlattInfo, groesse: CGSize, gruppen: [ZeichnungsGruppe], masse: [MassDarstellung], texte: [BlattText],
        gefuellt: [[CGPoint]] = [], pruefung: [BlattBefund] = [], hinweise: [String] = [], stand: String = "",
        run: Int? = nil, linienReihenfolge: [String] = Linienart.reihenfolge
    ) {
        self.blatt = blatt
        self.groesse = groesse
        self.gruppen = gruppen
        self.masse = masse
        self.texte = texte
        self.gefuellt = gefuellt
        self.pruefung = pruefung
        self.hinweise = hinweise
        self.stand = stand
        self.run = run
        self.linienReihenfolge = linienReihenfolge
        self.grafik = BlattGrafik(gruppen: gruppen, masse: masse, texte: texte, gefuellt: gefuellt)
    }

    /// Ansichten ohne die Gruppe `blatt`.
    public var ansichten: [ZeichnungsGruppe] { gruppen.filter { !$0.istBlatt } }

    public func gruppe(_ id: String) -> ZeichnungsGruppe? { gruppen.first { $0.id == id } }
    public func mass(_ id: String) -> MassDarstellung? { masse.first { $0.id == id } }

    /// Seitengröße in PDF-Punkten (1 pt = 1/72 Zoll).
    public var seitengroessePunkte: CGSize {
        CGSize(width: groesse.width * BlattZeichner.punkteJeMM, height: groesse.height * BlattZeichner.punkteJeMM)
    }

    /// „A4 quer“, „A3 quer“ …
    public var formatText: String { "\(blatt.format) \(blatt.ausrichtung)" }

    /// Gleiche Papiergröße (für den Druck: ein Auftrag je Blattformat).
    public var papierSchluessel: String {
        "\(Int(groesse.width.rounded()))x\(Int(groesse.height.rounded()))"
    }

    public var verwaisteMasse: [MassDarstellung] { masse.filter(\.verwaist) }

    /// Texte der Notizen in Reihenfolge von `blatt.notizen` (der Kernel schickt sie ohne Kennung).
    public var notizTexte: [(notiz: BlattNotiz, text: BlattText)] {
        let ts = texte.filter { $0.art == "notiz" }
        let ns = blatt.notizen.filter { !$0.text.isEmpty }
        return zip(ns, ts).map { ($0, $1) }
    }

    /// Polylinien insgesamt (für Messwerte).
    public var anzahlPolylinien: Int { gruppen.reduce(0) { $0 + $1.anzahlPolylinien } }
}

// MARK: - DOCS

/// Ein Blatt in der Übersicht (`DOCS.blaetter[i]`).
public struct BlattEintrag: Identifiable, Equatable, Sendable {
    public var id: String
    public var titel: String
    /// `teil`, `baugruppe` oder `zusammenbau` (nil, wenn das Blatt nicht gerechnet werden konnte).
    public var inhaltArt: String?
    public var teile: [String]
    public var format: String?
    public var ausrichtung: String?
    public var massstab: String?
    public var verwaisteMasse: Int
    public var masse: Int
    public var stand: String?
    public var hinweise: [String]
    public var pruefung: Int
    public var fehler: String?

    public init(
        id: String, titel: String, inhaltArt: String? = "teil", teile: [String] = [], format: String? = "A4",
        ausrichtung: String? = "quer", massstab: String? = "1:1", verwaisteMasse: Int = 0, masse: Int = 0,
        stand: String? = nil, hinweise: [String] = [], pruefung: Int = 0, fehler: String? = nil
    ) {
        self.id = id
        self.titel = titel
        self.inhaltArt = inhaltArt
        self.teile = teile
        self.format = format
        self.ausrichtung = ausrichtung
        self.massstab = massstab
        self.verwaisteMasse = verwaisteMasse
        self.masse = masse
        self.stand = stand
        self.hinweise = hinweise
        self.pruefung = pruefung
        self.fehler = fehler
    }

    public var formatText: String {
        [format, ausrichtung].compactMap { $0 }.joined(separator: " ")
    }
}

/// Zusammenfassung des Bauplans in DOCS (Strang P6-B; die Bauplanansicht selbst gehört P6-A2).
public struct BauplanKurz: Equatable, Sendable {
    public struct Abschnitt: Equatable, Sendable {
        public var art: String
        public var titel: String
        public var schritte: Int
    }

    public var abschnitte: [Abschnitt]
    public var schritte: Int
    public var probleme: Int
    public var fehler: Int
    public var hinweise: Int
    public var json: JSONValue
}

/// Nachricht DOCS: alle Blätter des Projekts mit Stand, dazu die Zusammenfassung des Bauplans.
public struct DocsUebersicht: Equatable, Sendable {
    public var run: Int?
    public var blaetter: [BlattEintrag]
    public var bauplan: BauplanKurz?

    public init(run: Int? = nil, blaetter: [BlattEintrag] = [], bauplan: BauplanKurz? = nil) {
        self.run = run
        self.blaetter = blaetter
        self.bauplan = bauplan
    }

    public func blatt(_ id: String) -> BlattEintrag? { blaetter.first { $0.id == id } }

    public var zusammenbau: [BlattEintrag] { blaetter.filter { $0.inhaltArt == "zusammenbau" } }
    public var baugruppen: [BlattEintrag] { blaetter.filter { $0.inhaltArt == "baugruppe" } }
    /// Einzelteile und Blätter, die nicht gerechnet werden konnten.
    public var einzelteile: [BlattEintrag] {
        blaetter.filter { $0.inhaltArt != "zusammenbau" && $0.inhaltArt != "baugruppe" }
    }
}

// MARK: - Texte für die Oberfläche

public enum ZeichnungText {
    public static func massArt(_ art: String) -> String {
        switch art {
        case "linear": return "Länge"
        case "durchmesser": return "Durchmesser"
        case "radius": return "Radius"
        case "winkel": return "Winkel"
        case "fase": return "Fase"
        case "bohrung": return "Bohrung"
        case "gewinde": return "Gewinde"
        case "bezugskette": return "Steigende Bemaßung"
        case "koordinaten": return "Koordinaten"
        case "merkmal": return "Merkmal"
        default: return art.capitalized
        }
    }

    public static func ansichtArt(_ art: String) -> String {
        switch art {
        case "vorn": return "Vorderansicht"
        case "hinten": return "Rückansicht"
        case "oben": return "Draufsicht"
        case "unten": return "Untersicht"
        case "links": return "Seitenansicht von links"
        case "rechts": return "Seitenansicht von rechts"
        case "iso": return "Isometrie"
        case "schnitt": return "Schnitt"
        case "einzelheit": return "Einzelheit"
        default: return art.capitalized
        }
    }

    public static func quelle(_ q: String) -> String {
        switch q {
        case "kevin": return "von \(AppInfo.nutzerName)"
        case "agent": return "von Claude"
        default: return "automatisch"
        }
    }

    /// Maßstäbe nach ISO 5455 für Auswahllisten.
    public static let massstaebe = ["10:1", "5:1", "2:1", "1:1", "1:2", "1:5", "1:10", "1:20", "1:50", "1:100"]

    /// Format mit Ausrichtung für Auswahllisten.
    public struct Format: Hashable, Sendable {
        public var format: String
        public var ausrichtung: String
        public var titel: String { "\(format) \(ausrichtung)" }
    }

    /// Formate mit Ausrichtung (ISO 5457: A4 hoch oder quer, ab A3 quer).
    public static let formate: [Format] = [
        Format(format: "A4", ausrichtung: "hoch"), Format(format: "A4", ausrichtung: "quer"),
        Format(format: "A3", ausrichtung: "quer"), Format(format: "A2", ausrichtung: "quer"),
        Format(format: "A1", ausrichtung: "quer"),
    ]
}
