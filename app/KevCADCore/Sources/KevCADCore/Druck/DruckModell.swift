import Foundation

// Live-Druckvorschau (DRUCKVORSCHAU.md, Abschnitt „Ergebnis“): was das Konstruierte im Druck bedeutet. Rein Daten,
// ohne Oberfläche. Gelesen wird tolerant wie bei allen Nachrichten: fehlende oder falsch getypte Felder werden zu nil
// bzw. Vorgaben, unbekannte Felder bleiben unbeachtet. Einheiten: mm, g, m, s, €; Platte in Drucker-mm, Ursprung vorn
// links, x nach rechts, y nach hinten.

/// Woher die Zahlen stammen: schnelle Schätzung des Kernels oder Bambu Studio.
public enum DruckStand: String, Equatable, Sendable, CaseIterable {
    case schaetzung, slicer, gemischt

    public init(json: JSONValue?) {
        self = json?.stringValue.flatMap { DruckStand(rawValue: $0.lowercased()) } ?? .schaetzung
    }

    public var titel: String {
        switch self {
        case .schaetzung: return "Schätzung"
        case .slicer: return "Bambu Studio"
        case .gemischt: return "Teils Bambu Studio"
        }
    }

    /// Beschreibung für Tooltips und den Bericht.
    public var beschreibung: String {
        switch self {
        case .schaetzung: return "Schnelle Schätzung des Kernels nach dem Lauf"
        case .slicer: return "Gerechnet von Bambu Studio mit deinem Drucker- und Filamentprofil"
        case .gemischt: return "Ein Teil ist schon von Bambu Studio gerechnet, der Rest geschätzt"
        }
    }
}

/// Ein Hinweis aus der Druckpraxis (Trocknen, Verzug, Brim, Stützen, AMS, Düse, Erfolgsrisiko).
public struct DruckpraxisHinweis: Equatable, Hashable, Sendable, Identifiable {
    public enum Schwere: String, Equatable, Hashable, Sendable, Comparable, CaseIterable {
        case hinweis, warnung, fehler

        var rang: Int {
            switch self {
            case .hinweis: return 0
            case .warnung: return 1
            case .fehler: return 2
            }
        }

        public static func < (a: Schwere, b: Schwere) -> Bool { a.rang < b.rang }

        public var titel: String {
            switch self {
            case .hinweis: return "Hinweis"
            case .warnung: return "Warnung"
            case .fehler: return "Fehler"
            }
        }
    }

    public var schwere: Schwere
    public var text: String
    public var art: String?

    public var id: String { "\(schwere.rawValue)|\(art ?? "")|\(text)" }

    public init(schwere: Schwere, text: String, art: String? = nil) {
        self.schwere = schwere
        self.text = text
        self.art = art
    }

    /// Aus `{"schwere", "text", "art"}`; ein bloßer Text gilt als Hinweis. Ohne Text nil.
    public init?(json: JSONValue) {
        if let s = json.stringValue {
            guard !s.isEmpty else { return nil }
            self.init(schwere: .hinweis, text: s)
            return
        }
        guard let text = json["text"]?.lenientString else { return nil }
        let schwere = json["schwere"]?.stringValue.flatMap { Schwere(rawValue: $0.lowercased()) } ?? .hinweis
        self.init(schwere: schwere, text: text, art: json["art"]?.lenientString)
    }

    static func liste(_ json: JSONValue?) -> [DruckpraxisHinweis] {
        (json?.arrayValue ?? []).compactMap(DruckpraxisHinweis.init(json:))
    }
}

/// Ampel eines Teils bzw. der ganzen Vorschau: grün ohne Warnungen, gelb mit Warnung, rot mit Fehler.
public enum DruckAmpel: Int, Equatable, Sendable, Comparable {
    case gruen, gelb, rot

    public init(_ hinweise: [DruckpraxisHinweis]) {
        switch hinweise.map(\.schwere).max() {
        case .fehler?: self = .rot
        case .warnung?: self = .gelb
        default: self = .gruen
        }
    }

    public static func < (a: DruckAmpel, b: DruckAmpel) -> Bool { a.rawValue < b.rawValue }

    public var titel: String {
        switch self {
        case .gruen: return "druckbereit"
        case .gelb: return "mit Warnung"
        case .rot: return "mit Fehler"
        }
    }
}

/// Filament je Material (Summe oder Platte).
public struct DruckMaterialSumme: Equatable, Sendable, Identifiable {
    public var material: String
    public var name: String
    public var g: Double
    public var m: Double?
    public var kosten: Double?
    public var preisKg: Double?
    public var preisStand: String?
    public var stand: DruckStand
    /// Name des Filamentprofils, falls der Kernel ihn mitschickt (additiv, z. B. „Bambu PETG Basic“).
    public var filament: String?
    /// Angenommenes Filament aus Kevins Liste (additiv `filament_id`, Strang „Druckexport 2“) und woher
    /// (`filament_quelle`: projekt, zuletzt, spule, standard, system).
    public var filamentId: String? = nil
    public var filamentQuelle: String? = nil
    /// Strang „Rest Druck“ (additiv `farben`): je Farbe der Platten, sobald ein Teil des Materials eine Farbe hat.
    public var farben: [DruckFarbAnteil] = []

    public var id: String { material }

    public init(material: String, name: String? = nil, g: Double, m: Double? = nil, kosten: Double? = nil,
                preisKg: Double? = nil, preisStand: String? = nil, stand: DruckStand = .schaetzung,
                filament: String? = nil)
    {
        self.material = material
        self.name = name ?? material.uppercased()
        self.g = g
        self.m = m
        self.kosten = kosten
        self.preisKg = preisKg
        self.preisStand = preisStand
        self.stand = stand
        self.filament = filament
    }

    public init?(json: JSONValue, stand standard: DruckStand = .schaetzung) {
        guard let material = json["material"]?.lenientString else { return nil }
        self.init(
            material: material, name: json["name"]?.lenientString, g: json["g"]?.doubleValue ?? 0,
            m: json["m"]?.doubleValue, kosten: json["kosten"]?.doubleValue, preisKg: json["preis_kg"]?.doubleValue,
            preisStand: json["preis_stand"]?.lenientString,
            stand: json["stand"] == nil ? standard : DruckStand(json: json["stand"]),
            filament: json["filament"]?.lenientString ?? json["profil"]?.lenientString)
        filamentId = json["filament_id"]?.lenientString
        filamentQuelle = json["filament_quelle"]?.lenientString
        farben = (json["farben"]?.arrayValue ?? []).compactMap(DruckFarbAnteil.init(json:))
    }
}

/// Filament einer Farbe (`summe.material[].farben[]`, Strang „Rest Druck“): Farbe (nil = ohne Farbe), Gramm, Meter,
/// Kosten und die Platten dieser Farbe.
public struct DruckFarbAnteil: Equatable, Sendable, Identifiable {
    public var farbe: String?
    public var g: Double
    public var m: Double?
    public var kosten: Double?
    public var platten: [Int]

    public var id: String { farbe ?? "" }

    public init(farbe: String?, g: Double, m: Double? = nil, kosten: Double? = nil, platten: [Int] = []) {
        self.farbe = farbe
        self.g = g
        self.m = m
        self.kosten = kosten
        self.platten = platten
    }

    public init?(json: JSONValue) {
        guard json.objectValue != nil else { return nil }
        self.init(farbe: json["farbe"]?.lenientString, g: json["g"]?.doubleValue ?? 0, m: json["m"]?.doubleValue,
                  kosten: json["kosten"]?.doubleValue,
                  platten: (json["platten"]?.arrayValue ?? []).compactMap(\.intValue))
    }
}

/// Ein Filament aus Kevins Liste (additiv `druckvorschau.filamente`, Strang „Druckexport 2“): Auswahl beim Export.
public struct DruckFilament: Equatable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var material: String
    public var preset: String?
    public var basis: String?
    /// Farbe aus Kevins Liste (additiv), Anzahl der Abweichungen vom Basisprofil.
    public var farbe: String? = nil
    public var abweichungen: Int = 0

    public init(id: String, name: String, material: String, preset: String? = nil, basis: String? = nil,
                farbe: String? = nil)
    {
        self.id = id
        self.name = name
        self.material = material
        self.preset = preset
        self.basis = basis
        self.farbe = farbe
    }

    public init?(json: JSONValue) {
        guard let id = json["id"]?.lenientString, let material = json["material"]?.lenientString else { return nil }
        self.init(id: id, name: json["name"]?.lenientString ?? id, material: material,
                  preset: json["preset"]?.lenientString, basis: json["basis"]?.lenientString,
                  farbe: json["farbe"]?.lenientString)
        abweichungen = json["abweichungen"]?.intValue ?? 0
    }

    /// Farbe zum Vergleichen (klein, Leerzeichen zusammengefasst) wie der Kernel.
    public var farbeSchluessel: String? { Druckvorschau.farbeSchluessel(farbe) }
}

/// Summe über alle Platten.
public struct DruckSumme: Equatable, Sendable {
    public var platten: Int
    public var zeitS: Double
    public var zeitMitWechselS: Double
    public var kosten: Double?
    public var kostenFilament: Double?
    public var kostenStrom: Double?
    /// Aufschlag fürs Erfolgsrisiko (additiv, `kosten_teile.risiko`).
    public var kostenRisiko: Double?
    public var material: [DruckMaterialSumme]

    public init(platten: Int = 0, zeitS: Double = 0, zeitMitWechselS: Double? = nil, kosten: Double? = nil,
                kostenFilament: Double? = nil, kostenStrom: Double? = nil, kostenRisiko: Double? = nil,
                material: [DruckMaterialSumme] = [])
    {
        self.kostenRisiko = kostenRisiko
        self.platten = platten
        self.zeitS = zeitS
        self.zeitMitWechselS = zeitMitWechselS ?? zeitS
        self.kosten = kosten
        self.kostenFilament = kostenFilament
        self.kostenStrom = kostenStrom
        self.material = material
    }

    public init(json: JSONValue?, stand: DruckStand) {
        let j = json ?? .object([:])
        let zeit = j["zeit_s"]?.doubleValue ?? 0
        self.init(
            platten: j["platten"]?.intValue ?? 0, zeitS: zeit, zeitMitWechselS: j["zeit_mit_wechsel_s"]?.doubleValue,
            kosten: j["kosten"]?.doubleValue, kostenFilament: j["kosten_teile"]?["filament"]?.doubleValue,
            kostenStrom: j["kosten_teile"]?["strom"]?.doubleValue, kostenRisiko: j["kosten_teile"]?["risiko"]?.doubleValue,
            material: (j["material"]?.arrayValue ?? []).compactMap { DruckMaterialSumme(json: $0, stand: stand) })
    }

    /// Filament über alle Materialien in g.
    public var gramm: Double { material.reduce(0) { $0 + $1.g } }
    public var meter: Double? {
        let m = material.compactMap(\.m)
        return m.isEmpty ? nil : m.reduce(0, +)
    }

    /// Zeit der Plattenwechsel (Summe mit Wechsel minus reine Druckzeit).
    public var wechselS: Double { max(0, zeitMitWechselS - zeitS) }
}

/// Ein Teil auf einer Platte: Lage (x, y), Drehung in Grad und Umriss der Grundfläche.
public struct DruckPlattenTeil: Equatable, Sendable, Identifiable {
    public var name: String
    public var gruppe: String?
    public var x: Double
    public var y: Double
    public var drehung: Double
    /// Umriss, wie ihn der Kernel schickt (meist schon in Plattenkoordinaten, siehe `plattenUmriss`).
    public var umriss: [SIMD2<Double>]
    /// Laufende Nummer auf der Platte (für eindeutige ids bei gleichen Namen).
    public var index: Int
    /// Stück über die im Modell gezeigten hinaus (`name` bleibt das gezeigte Teil), additiv.
    public var ersatz: Bool

    public var id: String { "\(index)|\(name)" }

    public init(name: String, gruppe: String? = nil, x: Double, y: Double, drehung: Double = 0,
                umriss: [SIMD2<Double>] = [], index: Int = 0, ersatz: Bool = false)
    {
        self.ersatz = ersatz
        self.name = name
        self.gruppe = gruppe
        self.x = x
        self.y = y
        self.drehung = drehung
        self.umriss = umriss
        self.index = index
    }

    public init?(json: JSONValue, index: Int) {
        guard let name = json["name"]?.lenientString else { return nil }
        let punkte: [SIMD2<Double>] = (json["umriss"]?.arrayValue ?? []).compactMap { p in
            if let d = p.doubles, d.count >= 2 { return SIMD2(d[0], d[1]) }
            if let x = p["x"]?.doubleValue, let y = p["y"]?.doubleValue { return SIMD2(x, y) }
            return nil
        }
        self.init(name: name, gruppe: json["gruppe"]?.lenientString, x: json["x"]?.doubleValue ?? 0,
                  y: json["y"]?.doubleValue ?? 0, drehung: json["drehung"]?.doubleValue ?? 0, umriss: punkte,
                  index: index, ersatz: json["ersatz"]?.boolValue ?? false)
    }

    /// Umriss in Plattenkoordinaten. Laut Vertrag ist `umriss` die konvexe Hülle, absolut auf der Platte, und (x, y)
    /// die Mitte des Hüllrechtecks. Zur Sicherheit: Liegt der Schwerpunkt der Punkte nahe 0, während (x, y) weit davon
    /// liegt, gilt er als örtlich und wird um `drehung` gedreht und nach (x, y) geschoben. Ohne Umriss: kleines
    /// Quadrat um (x, y).
    public var plattenUmriss: [SIMD2<Double>] {
        guard umriss.count >= 3 else {
            let r = 4.0
            return [SIMD2(x - r, y - r), SIMD2(x + r, y - r), SIMD2(x + r, y + r), SIMD2(x - r, y + r)]
        }
        let mitte = umriss.reduce(SIMD2<Double>(0, 0), +) / Double(umriss.count)
        let lage = SIMD2(x, y)
        let oertlich = betrag(mitte) < 2 && betrag(lage) > 10
        guard oertlich else { return umriss }
        let w = drehung * .pi / 180
        let c = cos(w), s = sin(w)
        return umriss.map { p in SIMD2(p.x * c - p.y * s + x, p.x * s + p.y * c + y) }
    }

    /// Schwerpunkt der Punkte des Umrisses auf der Platte (für Beschriftungen).
    public var mitte: SIMD2<Double> {
        let u = plattenUmriss
        return u.reduce(SIMD2<Double>(0, 0), +) / Double(max(1, u.count))
    }
}

private func betrag(_ v: SIMD2<Double>) -> Double { (v.x * v.x + v.y * v.y).squareRoot() }

/// Eine Druckplatte.
public struct DruckPlatte: Equatable, Sendable, Identifiable {
    public var nr: Int
    public var zeitS: Double
    public var material: [DruckMaterialSumme]
    public var stand: DruckStand
    public var teile: [DruckPlattenTeil]
    /// Belegte Fläche, 0…1.
    public var auslastung: Double?
    /// Additiv: „schnell“ (Kernel) oder „slicer“ (Bambu Studio hat angeordnet), Kosten und höchstes Teil.
    public var anordnung: String?
    public var kosten: Double?
    public var hoeheMM: Double?
    /// Strang „Rest Druck“ (additiv): Farbe der Platte und Klasse für Export und Filamentwahl („petg“, „petg/gelb“).
    public var farbe: String?
    public var klasseRoh: String?

    public var id: Int { nr }

    /// Klasse der Platte: vom Kernel, sonst das Material (ältere Kernel).
    public var klasse: String { klasseRoh ?? material.first?.material ?? "?" }

    public init(nr: Int, zeitS: Double = 0, material: [DruckMaterialSumme] = [], stand: DruckStand = .schaetzung,
                teile: [DruckPlattenTeil] = [], auslastung: Double? = nil)
    {
        self.nr = nr
        self.zeitS = zeitS
        self.material = material
        self.stand = stand
        self.teile = teile
        self.auslastung = auslastung
    }

    public init?(json: JSONValue, index: Int) {
        let stand = DruckStand(json: json["stand"])
        let teile = (json["teile"]?.arrayValue ?? []).enumerated().compactMap { DruckPlattenTeil(json: $1, index: $0) }
        self.init(
            nr: json["nr"]?.intValue ?? index + 1, zeitS: json["zeit_s"]?.doubleValue ?? 0,
            material: (json["material"]?.arrayValue ?? []).compactMap { DruckMaterialSumme(json: $0, stand: stand) },
            stand: stand, teile: teile, auslastung: json["auslastung"]?.doubleValue)
        anordnung = json["anordnung"]?.lenientString
        kosten = json["kosten"]?.doubleValue
        hoeheMM = json["hoehe_mm"]?.doubleValue
        farbe = json["farbe"]?.lenientString
        klasseRoh = json["klasse"]?.lenientString
    }

    /// Hat Bambu Studio die Platte angeordnet?
    public var vomSlicerAngeordnet: Bool { anordnung == "slicer" }

    public var gramm: Double { material.reduce(0) { $0 + $1.g } }

    /// Teile je Gruppe auf dieser Platte in der Reihenfolge des ersten Auftretens (Gruppe oder Name, Anzahl).
    public var gruppen: [(gruppe: String, anzahl: Int)] {
        var reihenfolge: [String] = []
        var zahl: [String: Int] = [:]
        for t in teile {
            let k = t.gruppe ?? t.name
            if zahl[k] == nil { reihenfolge.append(k) }
            zahl[k, default: 0] += 1
        }
        return reihenfolge.map { ($0, zahl[$0] ?? 0) }
    }
}

/// Empfohlene bzw. gesetzte Einstellungen einer Gruppe. Bekannte Felder einzeln, alles im Roh-JSON erhalten.
public struct DruckEinstellungen: Equatable, Sendable {
    public var schichtMM: Double?
    public var waende: Int?
    public var decken: Int?
    public var boeden: Int?
    /// Füllung als Anteil 0…1 (Werte über 1 gelten als Prozent).
    public var fuellung: Double?
    public var muster: String?
    public var stuetzen: String?
    public var brim: Bool?
    public var ausrichtung: String?
    public var json: [String: JSONValue]

    public init(json: JSONValue?) {
        let o = json?.objectValue ?? [:]
        self.json = o
        schichtMM = o["schicht_mm"]?.doubleValue
        waende = o["waende"]?.intValue
        decken = o["decken"]?.intValue
        boeden = o["boeden"]?.intValue
        if let f = o["fuellung"]?.doubleValue { fuellung = f > 1 ? f / 100 : f }
        muster = o["muster"]?.lenientString
        switch o["stuetzen"] {
        case .bool(let b)?: stuetzen = b ? "normal" : "keine"
        default: stuetzen = o["stuetzen"]?.lenientString
        }
        switch o["brim"] {
        case .bool(let b)?: brim = b
        case .number(let n)?: brim = n != 0
        case .string(let s)?: brim = !["", "nein", "aus", "kein", "keiner", "false", "0"].contains(s.lowercased())
        default: brim = nil
        }
        ausrichtung = o["ausrichtung"]?.lenientString
    }

    public init(schichtMM: Double? = nil, waende: Int? = nil, decken: Int? = nil, boeden: Int? = nil,
                fuellung: Double? = nil, muster: String? = nil, stuetzen: String? = nil, brim: Bool? = nil,
                ausrichtung: String? = nil)
    {
        var o: [String: JSONValue] = [:]
        if let schichtMM { o["schicht_mm"] = .number(schichtMM) }
        if let waende { o["waende"] = .number(Double(waende)) }
        if let decken { o["decken"] = .number(Double(decken)) }
        if let boeden { o["boeden"] = .number(Double(boeden)) }
        if let fuellung { o["fuellung"] = .number(fuellung) }
        if let muster { o["muster"] = .string(muster) }
        if let stuetzen { o["stuetzen"] = .string(stuetzen) }
        if let brim { o["brim"] = .bool(brim) }
        if let ausrichtung { o["ausrichtung"] = .string(ausrichtung) }
        self.init(json: .object(o))
    }
}

/// Wer einen Wert festgelegt hat (Vertrag: `PRINT_SETTINGS` von Kevin gelten als feste Vorgabe).
public enum DruckQuelle: String, Equatable, Sendable {
    case kevin, agent

    public var titel: String { self == .kevin ? "von \(AppInfo.nutzerName)" : "vom Agenten" }
}

/// Eine Gruppe gleicher Druckteile (gleicher Formschlüssel, Material und Einstellungen) mit Empfehlung.
public struct DruckGruppe: Equatable, Sendable, Identifiable {
    public var gruppe: String
    public var name: String
    public var teile: [String]
    public var anzahl: Int
    public var material: String?
    public var zweck: String?
    public var zweckGeschaetzt: Bool
    public var g: Double
    public var m: Double?
    public var zeitS: Double
    public var kosten: Double?
    public var stand: DruckStand
    public var abweichung: Double?
    /// Wie `abweichung`, für das Filament (additiv `abweichung_material`).
    public var abweichungMaterial: Double?
    public var einstellungen: DruckEinstellungen
    public var begruendung: [String]
    public var hinweise: [DruckpraxisHinweis]
    /// Werte, die Kevin bzw. Claude festgelegt haben (Schlüssel wie in `einstellungen`, dazu `zweck`). Additiv zum
    /// Vertrag: `vorgaben` als `{schlüssel: "kevin"}` oder Liste der Schlüssel (dann von Kevin).
    public var vorgaben: [String: DruckQuelle]
    /// Je Stück (additiv `je_stueck`); sonst die Werte aller Stück geteilt durch `anzahl`.
    public var jeStueck: DruckJeStueck?
    /// Bambu-Studio-Profile (additiv `profil`): Prozess und Filament.
    public var profilProzess: String?
    public var profilFilament: String?
    /// Fehldruck-Wahrscheinlichkeit 0…1 und Stützmaterial aller Stück in g (additiv).
    public var risiko: Double?
    public var stuetzenG: Double?
    /// Strang „Rest Druck“ (additiv): Farbe der Gruppe (`lager.druckteil(…, farbe=…)`), Zahl der Modifier um
    /// Gewindeeinsätze und Kernlöcher.
    public var farbe: String?
    public var modifier: Int = 0

    public var id: String { gruppe }

    public init(gruppe: String, name: String, teile: [String] = [], anzahl: Int? = nil, material: String? = nil,
                zweck: String? = nil, zweckGeschaetzt: Bool = false, g: Double = 0, m: Double? = nil,
                zeitS: Double = 0, kosten: Double? = nil, stand: DruckStand = .schaetzung, abweichung: Double? = nil,
                einstellungen: DruckEinstellungen = DruckEinstellungen(json: nil), begruendung: [String] = [],
                hinweise: [DruckpraxisHinweis] = [], vorgaben: [String: DruckQuelle] = [:])
    {
        self.gruppe = gruppe
        self.name = name
        self.teile = teile
        self.anzahl = anzahl ?? max(1, teile.count)
        self.material = material
        self.zweck = zweck
        self.zweckGeschaetzt = zweckGeschaetzt
        self.g = g
        self.m = m
        self.zeitS = zeitS
        self.kosten = kosten
        self.stand = stand
        self.abweichung = abweichung
        self.einstellungen = einstellungen
        self.begruendung = begruendung
        self.hinweise = hinweise
        self.vorgaben = vorgaben
    }

    public init?(json: JSONValue, index: Int) {
        let teile = json["teile"]?.stringList ?? []
        guard let id = json["gruppe"]?.lenientString ?? json["name"]?.lenientString ?? teile.first else { return nil }
        var vorgaben: [String: DruckQuelle] = [:]
        // `fest` (Vertrag): Liste der fest vorgegebenen Einstellungen, dazu „zweck“; `fest_von`/`vorgaben` (falls der
        // Kernel unterscheidet) als {schlüssel: "kevin" | "agent"}. Ohne Angabe gilt eine feste Vorgabe als Kevins.
        for key in ["fest", "vorgaben", "fest_von", "von", "gesetzt"] {
            guard let v = json[key] else { continue }
            if let o = v.objectValue {
                for (k, q) in o {
                    if let s = q.stringValue?.lowercased(), let quelle = DruckQuelle(rawValue: s) {
                        vorgaben[k] = quelle
                    } else if q.boolValue == true {
                        vorgaben[k] = .kevin
                    }
                }
            } else if let liste = v.stringList {
                for k in liste { vorgaben[k] = .kevin }
            }
        }
        if let z = json["zweck_von"]?.stringValue.flatMap({ DruckQuelle(rawValue: $0.lowercased()) }) {
            vorgaben["zweck"] = z
        }
        self.init(
            gruppe: id, name: json["name"]?.lenientString ?? teile.first ?? id, teile: teile,
            anzahl: json["anzahl"]?.intValue, material: json["material"]?.lenientString,
            zweck: json["zweck"]?.lenientString, zweckGeschaetzt: json["zweck_geschaetzt"]?.boolValue ?? false,
            g: json["g"]?.doubleValue ?? 0, m: json["m"]?.doubleValue, zeitS: json["zeit_s"]?.doubleValue ?? 0,
            kosten: json["kosten"]?.doubleValue, stand: DruckStand(json: json["stand"]),
            abweichung: json["abweichung"]?.doubleValue, einstellungen: DruckEinstellungen(json: json["einstellungen"]),
            begruendung: json["begruendung"]?.stringList ?? json["begruendung"]?.lenientString.map { [$0] } ?? [],
            hinweise: DruckpraxisHinweis.liste(json["hinweise"]), vorgaben: vorgaben)
        if let j = json["je_stueck"], let g = j["g"]?.doubleValue {
            jeStueck = DruckJeStueck(g: g, m: j["m"]?.doubleValue,
                                     zeitS: j["zeit_s"]?.doubleValue ?? zeitS / Double(max(1, self.anzahl)))
        }
        abweichungMaterial = json["abweichung_material"]?.doubleValue
        profilProzess = json["profil"]?["prozess"]?.lenientString
        profilFilament = json["profil"]?["filament"]?.lenientString
        risiko = json["risiko"]?.doubleValue
        stuetzenG = json["stuetzen_g"]?.doubleValue
        farbe = json["farbe"]?.lenientString
        modifier = json["modifier"]?.arrayValue?.count ?? 0
    }

    public var ampel: DruckAmpel { DruckAmpel(hinweise) }

    /// Kurzer Name ohne Baugruppe („Kugelschieber/Stangenhalter (Druck)“ → „Stangenhalter (Druck)“).
    /// Anzeigename ohne Baugruppe und ohne „(Druck)“ (in der Druckvorschau ist alles Druck):
    /// „Kugelschieber/Stangenhalter (Druck)“ → „Stangenhalter“.
    public var kurzname: String { DruckFormat.teilname(name) }

    /// Gramm und Druckzeit je Stück.
    public var grammJe: Double { jeStueck?.g ?? g / Double(max(1, anzahl)) }
    public var zeitJeS: Double { jeStueck?.zeitS ?? zeitS / Double(max(1, anzahl)) }

    public func quelle(_ schluessel: String) -> DruckQuelle? { vorgaben[schluessel] }

    /// Hat Kevin (oder Claude) irgendetwas festgelegt?
    public var hatVorgaben: Bool { !vorgaben.isEmpty }
}

/// Zustand des Slicers im Hintergrund.
public struct DruckSlicer: Equatable, Sendable {
    public enum Zustand: String, Equatable, Sendable {
        case aus, wartet, rechnet, fertig, fehler, unbekannt
    }

    public var zustand: Zustand
    public var fertig: Int
    public var gesamt: Int
    public var meldung: String?
    /// Fassung von Bambu Studio und Rechenzeit (additiv).
    public var version: String?
    public var ms: Double?

    public init(zustand: Zustand = .aus, fertig: Int = 0, gesamt: Int = 0, meldung: String? = nil) {
        self.zustand = zustand
        self.fertig = fertig
        self.gesamt = gesamt
        self.meldung = meldung
    }

    public init(json: JSONValue?) {
        guard let j = json, j.objectValue != nil else {
            self.init()
            return
        }
        self.init(
            zustand: j["zustand"]?.stringValue.map { Zustand(rawValue: $0.lowercased()) ?? .unbekannt } ?? .aus,
            fertig: j["fertig"]?.intValue ?? 0, gesamt: j["gesamt"]?.intValue ?? 0,
            meldung: j["meldung"]?.lenientString)
        version = j["version"]?.lenientString
        ms = j["ms"]?.doubleValue
    }

    /// Fortschritt 0…1, nil ohne bekannte Gesamtzahl.
    public var anteil: Double? { gesamt > 0 ? min(1, Double(fertig) / Double(gesamt)) : nil }

    public var laeuft: Bool { zustand == .wartet || zustand == .rechnet }
}

/// Bett des Druckers: Größe und gesperrte Bereiche (Vorgabe Bambu Lab P1P: 256 × 256 mm, vorn links 18 × 28 mm).
public struct DruckBett: Equatable, Sendable {
    public var breite: Double
    public var tiefe: Double
    /// Gesperrte Rechtecke in Plattenkoordinaten (x, y, Breite, Tiefe).
    public var sperrzonen: [DruckRechteck]

    public static let p1p = DruckBett(breite: 256, tiefe: 256, sperrzonen: [DruckRechteck(x: 0, y: 0, b: 18, t: 28)])

    public init(breite: Double, tiefe: Double, sperrzonen: [DruckRechteck]) {
        self.breite = breite
        self.tiefe = tiefe
        self.sperrzonen = sperrzonen
    }

    /// Optionales Feld `bett` (additiv): `{"breite", "tiefe", "sperrzonen": [[x, y, b, t], …]}`; sonst P1P.
    public init(json: JSONValue?) {
        guard let j = json, let b = j["breite"]?.doubleValue, let t = j["tiefe"]?.doubleValue, b > 0, t > 0 else {
            self = .p1p
            return
        }
        let zonen: [DruckRechteck]
        if let liste = j["sperrzonen"]?.arrayValue {
            zonen = liste.compactMap { z in
                guard let d = z.doubles, d.count >= 4 else { return nil }
                return DruckRechteck(x: d[0], y: d[1], b: d[2], t: d[3])
            }
        } else {
            zonen = DruckBett.p1p.sperrzonen
        }
        self.init(breite: b, tiefe: t, sperrzonen: zonen)
    }
}

/// Rechteck in mm (Plattenkoordinaten, Ursprung vorn links).
public struct DruckRechteck: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var b: Double
    public var t: Double

    public init(x: Double, y: Double, b: Double, t: Double) {
        self.x = x
        self.y = y
        self.b = b
        self.t = t
    }
}

/// Die ganze Vorschau (`PRINT_PREVIEW`).
public struct Druckvorschau: Equatable, Sendable {
    public var run: Int
    public var stand: DruckStand
    public var drucker: String
    public var summe: DruckSumme
    public var platten: [DruckPlatte]
    public var teile: [DruckGruppe]
    public var hinweise: [DruckpraxisHinweis]
    public var slicer: DruckSlicer
    public var bett: DruckBett
    /// Benutzte Projekt-Einstellungen (additiv `einstellungen`), Lauf mit Reglerwerten (nichts gespeichert, kein
    /// Slicer) und Rechenzeit der Schätzung in ms.
    public var projekt: DruckProjektEinstellungen?
    public var regler: Bool
    public var ms: Double?
    /// Strang „Feinschliff 2“ (additiv `gedruckt`): schon gedruckte Teile (vorhanden, nicht in Platten und Summe).
    public var gedruckt: [DruckGedruckt] = []
    /// Strang „Druckexport 2“ (additiv `filamente`): Kevins Filamente der Materialien, Auswahl beim Export.
    public var filamente: [DruckFilament] = []
    /// Strang „Rest Druck“ (additiv `filament_zuletzt`): zuletzt für das Projekt gewähltes Filament je Material bzw.
    /// Klasse („petg/gelb“), Vorbelegung im Dialog „Drucken …“.
    public var filamentZuletzt: [String: String] = [:]

    public init(run: Int = 0, stand: DruckStand = .schaetzung, drucker: String = "Bambu Lab P1P 0.4",
                summe: DruckSumme = DruckSumme(), platten: [DruckPlatte] = [], teile: [DruckGruppe] = [],
                hinweise: [DruckpraxisHinweis] = [], slicer: DruckSlicer = DruckSlicer(), bett: DruckBett = .p1p)
    {
        self.run = run
        self.stand = stand
        self.drucker = drucker
        self.summe = summe
        self.platten = platten
        self.teile = teile
        self.hinweise = hinweise
        self.slicer = slicer
        self.bett = bett
        projekt = nil
        regler = false
        ms = nil
    }

    /// Aus dem Kopf von PRINT_PREVIEW (oder einem Objekt `druckvorschau` darin, wie es MCP liefert).
    public init(json: JSONValue) {
        let j = json["druckvorschau"]?.objectValue != nil ? json["druckvorschau"]! : json
        let stand = DruckStand(json: j["stand"])
        let platten = (j["platten"]?.arrayValue ?? []).enumerated().compactMap { DruckPlatte(json: $1, index: $0) }
        var summe = DruckSumme(json: j["summe"], stand: stand)
        if summe.platten == 0 { summe.platten = platten.count }
        self.init(
            run: j["run"]?.intValue ?? 0, stand: stand, drucker: j["drucker"]?.lenientString ?? "Bambu Lab P1P 0.4",
            summe: summe, platten: platten,
            teile: (j["teile"]?.arrayValue ?? []).enumerated().compactMap { DruckGruppe(json: $1, index: $0) },
            hinweise: DruckpraxisHinweis.liste(j["hinweise"]), slicer: DruckSlicer(json: j["slicer"]),
            bett: DruckBett(json: j["bett"]))
        projekt = j["einstellungen"].flatMap { $0.objectValue == nil ? nil : DruckProjektEinstellungen(json: $0) }
        regler = j["regler"]?.boolValue ?? false
        ms = j["ms"]?.doubleValue
        gedruckt = (j["gedruckt"]?.arrayValue ?? []).compactMap(DruckGedruckt.init(json:))
        filamente = (j["filamente"]?.arrayValue ?? []).compactMap(DruckFilament.init(json:))
        filamentZuletzt = (j["filament_zuletzt"]?.objectValue ?? [:]).compactMapValues(\.lenientString)
        // Filamentprofil je Material aus den Gruppen, wenn die Summe keins nennt
        for i in self.summe.material.indices where self.summe.material[i].filament == nil {
            let m = self.summe.material[i].material
            self.summe.material[i].filament = self.teile.first { $0.material == m }?.profilFilament
        }
    }

    public func gruppe(_ id: String) -> DruckGruppe? { teile.first { $0.gruppe == id } }

    /// Gruppe, zu der ein Teil des Modells gehört.
    public func gruppe(vonTeil name: String) -> DruckGruppe? {
        teile.first { $0.teile.contains(name) }
            ?? platten.lazy.flatMap(\.teile).first { $0.name == name }.flatMap { $0.gruppe.flatMap(gruppe(_:)) }
    }

    public func platte(_ nr: Int) -> DruckPlatte? { platten.first { $0.nr == nr } }

    /// Platte, auf der ein Teil liegt.
    public func platte(vonTeil name: String) -> DruckPlatte? { platten.first { $0.teile.contains { $0.name == name } } }

    /// Ampel über alles (Teile und allgemeine Hinweise).
    public var ampel: DruckAmpel { DruckAmpel(hinweise + teile.flatMap(\.hinweise)) }

    /// Alle Hinweise nach Schwere (Fehler zuerst), Doppelte zusammengefasst.
    public var alleHinweise: [(hinweis: DruckpraxisHinweis, gruppen: [String])] {
        var reihenfolge: [DruckpraxisHinweis] = []
        var gruppen: [String: [String]] = [:]
        for h in hinweise where gruppen[h.id] == nil {
            reihenfolge.append(h)
            gruppen[h.id] = []
        }
        for g in teile {
            for h in g.hinweise {
                if gruppen[h.id] == nil {
                    reihenfolge.append(h)
                    gruppen[h.id] = []
                }
                gruppen[h.id]?.append(g.gruppe)
            }
        }
        return reihenfolge.enumerated().sorted { a, b in
            a.element.schwere == b.element.schwere ? a.offset < b.offset : a.element.schwere > b.element.schwere
        }.map { ($0.element, gruppen[$0.element.id] ?? []) }
    }

    /// Filamente der Liste zu einem Material (Auswahl beim Export).
    public func filamente(fuer material: String) -> [DruckFilament] { filamente.filter { $0.material == material } }

    /// Vorschlag je Material für die Auswahl beim Export: das angenommene Filament der Vorschau (zuletzt gewählt,
    /// Spule oder erstes der Liste); Kevin wählt im Dialog ausdrücklich.
    public var filamentVorschlag: [String: String] {
        var out: [String: String] = [:]
        for m in summe.material {
            if let f = m.filamentId ?? filamente(fuer: m.material).first?.id { out[m.material] = f }
        }
        return out
    }

    // MARK: Farben und Klassen (Strang „Rest Druck“)

    /// Farbe zum Vergleichen wie der Kernel (`filamente.farbe_schluessel`): klein, Leerzeichen zusammengefasst.
    public static func farbeSchluessel(_ text: String?) -> String? {
        let t = (text ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        return t.isEmpty ? nil : t
    }

    /// Material einer Klasse („petg/gelb“ → „petg“) und ihre Farbe („gelb“, nil ohne).
    public static func material(vonKlasse k: String) -> String { String(k.split(separator: "/", maxSplits: 1).first ?? "") }
    public static func farbe(vonKlasse k: String) -> String? {
        let teile = k.split(separator: "/", maxSplits: 1)
        return teile.count > 1 ? String(teile[1]) : nil
    }

    /// Klassen der gewählten Platten (leer = alle) in der Reihenfolge der Platten.
    public func klassen(platten nrn: [Int]) -> [String] {
        var out: [String] = []
        for p in platten where (nrn.isEmpty || nrn.contains(p.nr)) && !out.contains(p.klasse) { out.append(p.klasse) }
        return out
    }

    /// „PETG gelb“ für eine Klasse.
    public func klassenTitel(_ k: String) -> String {
        let m = Self.material(vonKlasse: k)
        let name = summe.material.first { $0.material == m }?.name ?? m.uppercased()
        let farbe = Self.farbe(vonKlasse: k) ?? platten.first { $0.klasse == k }?.farbe
        return farbe.map { "\(name) \($0)" } ?? name
    }

    /// Filamente der Liste zu einer Klasse: das Material, Filamente der passenden Farbe zuerst.
    public func filamente(fuerKlasse k: String) -> [DruckFilament] {
        let liste = filamente(fuer: Self.material(vonKlasse: k))
        guard let f = Self.farbe(vonKlasse: k) ?? platten.first(where: { $0.klasse == k })?.farbe
            .flatMap({ Self.farbeSchluessel($0) }) else { return liste }
        return liste.filter { $0.farbeSchluessel == f } + liste.filter { $0.farbeSchluessel != f }
    }

    /// Vorbelegung im Dialog „Drucken …“ (Kevin, 22.10.2026: das zuletzt gewählte Filament des Projekts): zuletzt für
    /// diese Klasse, sonst für das Material (wenn die Farbe passt), sonst das Filament aus `kevcad.json`; nil, wenn
    /// Kevin noch keins gewählt hat (dann muss er wählen).
    public func filamentVorbelegung(klasse k: String) -> String? {
        let liste = filamente(fuerKlasse: k)
        let farbe = Self.farbe(vonKlasse: k).flatMap { Self.farbeSchluessel($0) }
        func passt(_ id: String?) -> String? {
            guard let id, let f = liste.first(where: { $0.id == id }) else { return nil }
            if let farbe, let ff = f.farbeSchluessel, ff != farbe { return nil }
            return f.id
        }
        let m = Self.material(vonKlasse: k)
        if let z = passt(filamentZuletzt[k]) { return z }
        if k != m, let z = passt(filamentZuletzt[m]) { return z }
        if let s = summe.material.first(where: { $0.material == m }),
           ["zuletzt", "projekt"].contains(s.filamentQuelle ?? "") {
            return passt(s.filamentId)
        }
        return nil
    }

    /// Anzahl gedruckter Stück über alle Gruppen.
    public var stueck: Int { teile.reduce(0) { $0 + $1.anzahl } }

    /// Leere Vorschau (Lauf ohne Druckteile).
    public var istLeer: Bool { teile.isEmpty && platten.isEmpty }
}

/// Schon gedrucktes Teil (`druckvorschau.gedruckt[]`, Strang „Feinschliff 2“): Name, Material und ob die Form noch zur
/// festgeschriebenen passt (`form`: gleich, geaendert, neu, neu_drucken).
public struct DruckGedruckt: Identifiable, Equatable, Sendable {
    public var name: String
    public var material: String?
    public var form: String
    public var unterschiede: [String]

    public var id: String { name }
    public var geaendert: Bool { form == "geaendert" }

    public init(name: String, material: String? = nil, form: String = "gleich", unterschiede: [String] = []) {
        self.name = name
        self.material = material
        self.form = form
        self.unterschiede = unterschiede
    }

    init?(json: JSONValue) {
        guard let name = json["name"]?.lenientString else { return nil }
        self.init(name: name, material: json["material"]?.lenientString, form: json["form"]?.lenientString ?? "gleich",
                  unterschiede: json["unterschiede"]?.stringList ?? [])
    }
}

/// Werte je Stück einer Gruppe (`je_stueck`).
public struct DruckJeStueck: Equatable, Sendable {
    public var g: Double
    public var m: Double?
    public var zeitS: Double

    public init(g: Double, m: Double? = nil, zeitS: Double) {
        self.g = g
        self.m = m
        self.zeitS = zeitS
    }
}

/// Benutzte Projekt-Einstellungen der Druckvorschau (`kevcad.json` unter `druck`, additiv im Ergebnis).
public struct DruckProjektEinstellungen: Equatable, Sendable {
    public var drucker: String?
    public var strompreisKwh: Double?
    public var leistungW: Double?
    public var plattenwechselS: Double?
    public var slicer: Bool?
    /// Druckplatte als Bambu-Name, z. B. „Textured PEI Plate“ (additiv `einstellungen.platte`).
    public var platte: String?

    public init(json: JSONValue) {
        platte = json["platte"]?.lenientString
        drucker = json["drucker"]?.lenientString
        strompreisKwh = json["strompreis_kwh"]?.doubleValue
        leistungW = json["leistung_w"]?.doubleValue
        plattenwechselS = json["plattenwechsel_s"]?.doubleValue
        slicer = json["slicer"]?.boolValue
    }
}
