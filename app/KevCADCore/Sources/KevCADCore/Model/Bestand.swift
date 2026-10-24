import Foundation

// Bestand (BESTAND.md): Material, das Kevin für das offene Projekt hat (ganze Stangen und Platten, Reste mit Kennung,
// Stückgut), der Zuschnitt mit Resten aus der Stückliste, die Einkaufsliste und das Buchungsprotokoll. Rein additiv zu
// AppModel (ein eigenes @Published-Feld `bestandZustand`), damit die Stränge beim Zusammenführen nicht kollidieren.

/// Lieferform eines Postens: Stangenware, Platte oder Stückgut.
public enum BestandForm: String, Sendable, CaseIterable {
    case stange, platte, stueckgut

    /// Aus der Art des Katalogeintrags (Stangenware, Platte, Stückware).
    public init(art: String) {
        switch CatalogSchema.art(art).supply {
        case .bar: self = .stange
        case .sheet: self = .platte
        case .piece: self = .stueckgut
        }
    }

    /// „Stange“, „Platte“, „Stück“.
    public var einheit: String {
        switch self {
        case .stange: return "Stange"
        case .platte: return "Platte"
        case .stueckgut: return "Stück"
        }
    }

    public var einheitMehrzahl: String {
        switch self {
        case .stange: return "Stangen"
        case .platte: return "Platten"
        case .stueckgut: return "Stück"
        }
    }

    /// Kennungsvorsatz der Reste: `R-` für Stangen, `P-` für Platten.
    public var kennungPrefix: String { self == .platte ? "P" : "R" }
}

public struct BestandEinstellungen: Equatable, Sendable {
    public var mindestrestMM: Double
    public var saegeblattMM: Double

    public static let standard = BestandEinstellungen(mindestrestMM: 100, saegeblattMM: 3)

    public init(mindestrestMM: Double, saegeblattMM: Double) {
        self.mindestrestMM = mindestrestMM
        self.saegeblattMM = saegeblattMM
    }

    public init(json: JSONValue?) {
        self.init(
            mindestrestMM: json?["mindestrest_mm"]?.doubleValue ?? Self.standard.mindestrestMM,
            saegeblattMM: json?["saegeblatt_mm"]?.doubleValue ?? Self.standard.saegeblattMM)
    }

    public var json: JSONValue {
        .object(["mindestrest_mm": .number(mindestrestMM), "saegeblatt_mm": .number(saegeblattMM)])
    }
}

/// Ein Rest: Länge (Stange) bzw. Breite × Höhe (Platte), mit Kennung und Ort.
public struct BestandRest: Identifiable, Equatable, Sendable {
    public var kennung: String?
    public var laenge: Double?
    public var b: Double?
    public var h: Double?
    public var ort: String?
    public var seit: String?
    /// Stelle in `reste` (für Reste ohne Kennung).
    public var index: Int

    public var id: String { kennung ?? "#\(index)" }
    public var istPlatte: Bool { b != nil && h != nil }

    public init(
        kennung: String?, laenge: Double? = nil, b: Double? = nil, h: Double? = nil, ort: String? = nil,
        seit: String? = nil, index: Int = 0
    ) {
        self.kennung = kennung
        self.laenge = laenge
        self.b = b
        self.h = h
        self.ort = ort
        self.seit = seit
        self.index = index
    }

    /// „430 mm“ bzw. „600 × 400 mm“.
    public var masseText: String {
        if let b, let h { return BestandText.format(b, h) }
        return laenge.map(KevFormat.length) ?? "–"
    }

    /// Sortierschlüssel: Länge bzw. Fläche.
    public var groesse: Double {
        if let b, let h { return b * h }
        return laenge ?? 0
    }
}

/// Stückgut einer Länge (Schrauben, Gewindestifte) oder ohne Länge (Muttern, Scheiben).
public struct BestandStueck: Identifiable, Equatable, Sendable {
    public var laenge: Double?
    public var anzahl: Int

    public var id: String { laenge.map { "L" + KevFormat.input($0) } ?? "-" }

    public init(laenge: Double?, anzahl: Int) {
        self.laenge = laenge
        self.anzahl = anzahl
    }
}

public struct BestandPosten: Identifiable, Equatable, Sendable {
    /// Katalog-id des Lagerteils.
    public var id: String
    public var form: BestandForm
    public var ganzeAnzahl: Int
    public var ganzeLaenge: Double?
    public var ganzeB: Double?
    public var ganzeH: Double?
    public var reste: [BestandRest]
    public var stueck: [BestandStueck]
    public var mindestrestMM: Double?
    /// Der Posten roh wie in der Datei (Bearbeiten behält unbekannte Felder).
    public var json: JSONValue

    public init(id: String, json: JSONValue, formHint: BestandForm? = nil) {
        self.id = id
        self.json = json
        let ganze = json["ganze"]
        ganzeAnzahl = max(0, ganze?["anzahl"]?.intValue ?? 0)
        ganzeLaenge = ganze?["laenge"]?.doubleValue
        ganzeB = ganze?["b"]?.doubleValue
        ganzeH = ganze?["h"]?.doubleValue
        reste = (json["reste"]?.arrayValue ?? []).enumerated().compactMap { i, r in
            guard r.objectValue != nil else { return nil }
            return BestandRest(
                kennung: r["kennung"]?.lenientString, laenge: r["laenge"]?.doubleValue, b: r["b"]?.doubleValue,
                h: r["h"]?.doubleValue, ort: r["ort"]?.lenientString, seit: r["seit"]?.lenientString, index: i)
        }
        stueck = (json["stueck"]?.arrayValue ?? []).compactMap { s in
            guard s.objectValue != nil else { return nil }
            return BestandStueck(laenge: s["laenge"]?.doubleValue, anzahl: max(0, s["anzahl"]?.intValue ?? 0))
        }
        mindestrestMM = json["mindestrest_mm"]?.doubleValue
        if json["stueck"] != nil && ganze == nil && reste.isEmpty {
            form = .stueckgut
        } else if ganzeB != nil || ganzeH != nil || reste.contains(where: \.istPlatte) {
            form = .platte
        } else if ganze != nil || !reste.isEmpty {
            form = .stange
        } else {
            form = formHint ?? .stange
        }
    }

    /// Reste der Größe nach, längste zuerst.
    public var resteSortiert: [BestandRest] {
        reste.sorted { ($0.groesse, $0.id) > ($1.groesse, $1.id) }
    }

    public var stueckGesamt: Int { stueck.reduce(0) { $0 + $1.anzahl } }

    /// Format der ganzen Stangen bzw. Platten: „1.000 mm“, „2.500 × 1.250 mm“ (nil, wenn unbekannt).
    public var ganzeMasseText: String? {
        switch form {
        case .stange: return ganzeLaenge.map(KevFormat.length)
        case .platte:
            if let b = ganzeB, let h = ganzeH { return BestandText.format(b, h) }
            return nil
        case .stueckgut: return nil
        }
    }

    /// Kurzfassung für Listen: „2 Stangen à 1.000 mm · 3 Reste“, „52 Stück (16 mm: 40, 20 mm: 12)“.
    public var zusammenfassung: String {
        switch form {
        case .stueckgut:
            let n = stueckGesamt
            guard stueck.contains(where: { $0.laenge != nil }) else { return "\(KevFormat.integer(n)) Stück" }
            let teile = stueck.sorted { ($0.laenge ?? 0) < ($1.laenge ?? 0) }
                .map { "\($0.laenge.map { KevFormat.compact($0, maxDigits: 1) } ?? "–") mm: \(KevFormat.integer($0.anzahl))" }
            return "\(KevFormat.integer(n)) Stück (\(teile.joined(separator: ", ")))"
        case .stange, .platte:
            var parts: [String] = []
            let ganze = KevFormat.count(ganzeAnzahl, one: form.einheit, many: form.einheitMehrzahl)
            parts.append(ganzeMasseText.map { "\(ganze) à \($0)" } ?? ganze)
            if !reste.isEmpty { parts.append(KevFormat.count(reste.count, one: "Rest", many: "Reste")) }
            return parts.joined(separator: " · ")
        }
    }

    /// Nichts mehr da (weder ganze noch Reste noch Stückgut).
    public var leer: Bool { ganzeAnzahl == 0 && reste.isEmpty && stueckGesamt == 0 }
}

public struct Bestand: Equatable, Sendable {
    public var version: Int
    public var einstellungen: BestandEinstellungen
    /// Nach id sortiert; die Oberfläche sortiert nach Namen.
    public var posten: [BestandPosten]
    public var json: JSONValue

    public init(json: JSONValue) {
        self.json = json
        version = json["version"]?.intValue ?? 1
        einstellungen = BestandEinstellungen(json: json["einstellungen"])
        posten = (json["posten"]?.objectValue ?? [:])
            .filter { $0.value.objectValue != nil }
            .map { BestandPosten(id: $0.key, json: $0.value) }
            .sorted { $0.id < $1.id }
    }

    public static let leer = Bestand(json: .object(["version": 1, "posten": .object([:])]))

    public func posten(_ id: String) -> BestandPosten? { posten.first { $0.id == id } }

    /// Mindestrest eines Postens: eigener Wert, sonst die Einstellung.
    public func mindestrest(_ id: String) -> Double {
        posten(id)?.mindestrestMM ?? einstellungen.mindestrestMM
    }

    /// Nächste freie Kennung, fortlaufend über den ganzen Bestand: „R-0009“, „P-0004“.
    public func naechsteKennung(_ form: BestandForm) -> String {
        let prefix = form.kennungPrefix + "-"
        let hoechste = posten.flatMap(\.reste).compactMap(\.kennung)
            .filter { $0.hasPrefix(prefix) }
            .compactMap { Int($0.dropFirst(prefix.count)) }
            .max() ?? 0
        return prefix + String(format: "%04d", hoechste + 1)
    }
}

// MARK: - Bearbeiten

/// Änderungen an einem Posten für BESTAND_SAVE: jede Funktion liefert den ganzen Posten neu, unbekannte Felder bleiben.
public enum BestandBearbeitung {
    /// Leerer Posten passend zur Form, mit dem Standardformat aus dem Katalog.
    public static func neuerPosten(form: BestandForm, laenge: Double? = nil, b: Double? = nil, h: Double? = nil) -> JSONValue {
        switch form {
        case .stange:
            var ganze: [String: JSONValue] = ["anzahl": 0]
            if let laenge { ganze["laenge"] = .number(laenge) }
            return .object(["ganze": .object(ganze), "reste": .array([])])
        case .platte:
            var ganze: [String: JSONValue] = ["anzahl": 0]
            if let b, let h {
                ganze["b"] = .number(b)
                ganze["h"] = .number(h)
            }
            return .object(["ganze": .object(ganze), "reste": .array([])])
        case .stueckgut:
            return .object(["stueck": .array([])])
        }
    }

    /// Ganze Stangen bzw. Platten um `delta` ändern (nie unter 0); fehlende Maße kommen aus den Vorgaben.
    public static func ganze(
        _ posten: JSONValue, delta: Int, laenge: Double? = nil, b: Double? = nil, h: Double? = nil
    ) -> JSONValue {
        let anzahl = max(0, (posten["ganze"]?["anzahl"]?.intValue ?? 0) + delta)
        return setzeGanze(posten, anzahl: anzahl, laenge: laenge, b: b, h: h, nurWennFehlt: true)
    }

    /// Anzahl und Maße der ganzen Stangen bzw. Platten setzen. `nurWennFehlt`: vorhandene Maße bleiben.
    public static func setzeGanze(
        _ posten: JSONValue, anzahl: Int, laenge: Double? = nil, b: Double? = nil, h: Double? = nil,
        nurWennFehlt: Bool = false
    ) -> JSONValue {
        var p = posten.objectValue ?? [:]
        var ganze = p["ganze"]?.objectValue ?? [:]
        ganze["anzahl"] = .number(Double(max(0, anzahl)))
        func set(_ key: String, _ value: Double?) {
            guard let value, value > 0 else { return }
            if nurWennFehlt, ganze[key]?.doubleValue != nil { return }
            ganze[key] = .number(value)
        }
        set("laenge", laenge)
        set("b", b)
        set("h", h)
        p["ganze"] = .object(ganze)
        return .object(p)
    }

    /// Rest anhängen (Stange: `laenge`, Platte: `b` und `h`) mit heutigem Datum. Ohne `kennung` vergibt der Kernel
    /// die nächste freie (er kennt auch die schon verbrauchten aus den Buchungen, BESTAND.md Anhang S-K).
    public static func restHinzu(
        _ posten: JSONValue, kennung: String? = nil, laenge: Double? = nil, b: Double? = nil, h: Double? = nil,
        ort: String? = nil, seit: String = BestandText.heute()
    ) -> JSONValue {
        var p = posten.objectValue ?? [:]
        var reste = p["reste"]?.arrayValue ?? []
        var rest: [String: JSONValue] = ["seit": .string(seit)]
        if let kennung { rest["kennung"] = .string(kennung) }
        if let b, let h {
            rest["b"] = .number(b)
            rest["h"] = .number(h)
        } else if let laenge {
            rest["laenge"] = .number(laenge)
        }
        rest["ort"] = ort.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : JSONValue.string($0) } ?? .null
        reste.append(.object(rest))
        p["reste"] = .array(reste)
        return .object(p)
    }

    /// Rest ändern (Maße und Ort), erkannt an der Kennung bzw. der Stelle.
    public static func restAendern(
        _ posten: JSONValue, rest id: String, laenge: Double? = nil, b: Double? = nil, h: Double? = nil, ort: String?
    ) -> JSONValue {
        mapRest(posten, id) { r in
            var r = r
            if let b, let h {
                r["b"] = .number(b)
                r["h"] = .number(h)
            }
            if let laenge { r["laenge"] = .number(laenge) }
            let o = ort?.trimmingCharacters(in: .whitespaces) ?? ""
            r["ort"] = o.isEmpty ? .null : .string(o)
            return r
        }
    }

    /// Rest entfernen.
    public static func restEntfernen(_ posten: JSONValue, rest id: String) -> JSONValue {
        mapRest(posten, id) { _ in nil }
    }

    private static func mapRest(
        _ posten: JSONValue, _ id: String, _ change: ([String: JSONValue]) -> [String: JSONValue]?
    ) -> JSONValue {
        var p = posten.objectValue ?? [:]
        let reste = p["reste"]?.arrayValue ?? []
        var out: [JSONValue] = []
        for (i, r) in reste.enumerated() {
            let key = r["kennung"]?.lenientString ?? "#\(i)"
            if key == id, let o = r.objectValue {
                if let changed = change(o) { out.append(.object(changed)) }
            } else {
                out.append(r)
            }
        }
        p["reste"] = .array(out)
        return .object(p)
    }

    /// Stückgut einer Länge um `delta` ändern; eine Länge mit 0 Stück verschwindet.
    public static func stueck(_ posten: JSONValue, laenge: Double?, delta: Int) -> JSONValue {
        let jetzt = (posten["stueck"]?.arrayValue ?? []).first { gleicheLaenge($0["laenge"]?.doubleValue, laenge) }
        return setzeStueck(posten, laenge: laenge, anzahl: max(0, (jetzt?["anzahl"]?.intValue ?? 0) + delta))
    }

    /// Stückgut einer Länge auf `anzahl` setzen (0 entfernt die Länge), Längen aufsteigend.
    public static func setzeStueck(_ posten: JSONValue, laenge: Double?, anzahl: Int) -> JSONValue {
        var p = posten.objectValue ?? [:]
        var liste = (p["stueck"]?.arrayValue ?? []).filter { !gleicheLaenge($0["laenge"]?.doubleValue, laenge) }
        if anzahl > 0 {
            var e: [String: JSONValue] = ["anzahl": .number(Double(anzahl))]
            if let laenge { e["laenge"] = .number(laenge) }
            liste.append(.object(e))
        }
        liste.sort { ($0["laenge"]?.doubleValue ?? -1) < ($1["laenge"]?.doubleValue ?? -1) }
        p["stueck"] = .array(liste)
        return .object(p)
    }

    /// Eigener Mindestrest des Postens (nil = Einstellung gilt).
    public static func mindestrest(_ posten: JSONValue, _ wert: Double?) -> JSONValue {
        var p = posten.objectValue ?? [:]
        if let wert, wert >= 0 { p["mindestrest_mm"] = .number(wert) } else { p.removeValue(forKey: "mindestrest_mm") }
        return .object(p)
    }

    static func gleicheLaenge(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let x?, let y?): return abs(x - y) < 0.01
        default: return false
        }
    }
}

// MARK: - Buchungen

public struct BestandBuchung: Identifiable, Equatable, Sendable {
    public var id: String
    public var zeit: Date?
    public var zeitText: String
    /// `eintrag`, `gebaut`, `korrektur`, `rueckgaengig`
    public var art: String
    public var projekt: String?
    /// `kevin` oder `agent`
    public var von: String?
    public var grund: String?
    public var zusammenfassung: String?
    public var aenderungen: Int
    /// id der Umkehrbuchung, wenn diese Buchung schon rückgängig gemacht ist.
    public var rueckgaengigDurch: String?
    /// Bei `rueckgaengig`: die umgekehrte Buchung.
    public var bezug: String?

    public init(
        id: String, zeit: Date? = nil, zeitText: String = "", art: String, projekt: String? = nil, von: String? = nil,
        grund: String? = nil, zusammenfassung: String? = nil, aenderungen: Int = 0, rueckgaengigDurch: String? = nil,
        bezug: String? = nil
    ) {
        self.id = id
        self.zeit = zeit
        self.zeitText = zeitText
        self.art = art
        self.projekt = projekt
        self.von = von
        self.grund = grund
        self.zusammenfassung = zusammenfassung
        self.aenderungen = aenderungen
        self.rueckgaengigDurch = rueckgaengigDurch
        self.bezug = bezug
    }

    public init?(json: JSONValue) {
        guard let id = json["id"]?.lenientString else { return nil }
        let zeitText = json["zeit"]?.lenientString ?? ""
        let bezugRoh = json["bezug"] ?? json["verweis"] ?? json["rueckgaengig_von"] ?? json["buchung"]
        self.init(
            id: id, zeit: BestandText.datum(zeitText), zeitText: zeitText, art: json["art"]?.lenientString ?? "eintrag",
            projekt: json["projekt"]?.lenientString, von: json["von"]?.lenientString, grund: json["grund"]?.lenientString,
            zusammenfassung: json["zusammenfassung"]?.lenientString,
            aenderungen: json["aenderungen"]?.arrayValue?.count ?? 0,
            rueckgaengigDurch: json["rueckgaengig_durch"]?.lenientString, bezug: bezugRoh?.lenientString)
    }

    /// „Eintrag“, „Gebaut“, „Korrektur“, „Rückgängig“.
    public var artTitel: String {
        switch art {
        case "eintrag": return "Eintrag"
        case "gebaut": return "Gebaut"
        case "korrektur": return "Korrektur"
        case "rueckgaengig": return "Rückgängig"
        default: return art.capitalized
        }
    }

    public var vonTitel: String? {
        switch von {
        case "kevin": return AppInfo.nutzerName
        case "agent": return "Claude"
        case let v?: return v
        case nil: return nil
        }
    }

    public var schonRueckgaengig: Bool { rueckgaengigDurch != nil }

    /// Text der Zeile: Zusammenfassung des Kernels, sonst der Grund.
    public var text: String {
        zusammenfassung ?? grund ?? KevFormat.count(aenderungen, one: "Änderung", many: "Änderungen")
    }
}

// MARK: - Zuschnitt mit Bestand (Erweiterung von BOM.cuts)

public enum ZuschnittQuelleArt: String, Sendable, CaseIterable {
    case rest, bestand, kaufen

    public var titel: String {
        switch self {
        case .rest: return "Rest"
        case .bestand: return "Bestand"
        case .kaufen: return "kaufen"
        }
    }

    public var farbe: ZuschnittFarbe {
        switch self {
        case .rest: return .rest
        case .bestand: return .bestand
        case .kaufen: return .kaufen
        }
    }
}

/// Farben der Zuschnittansicht (sRGB 0…1), in der Oberfläche als SwiftUI-Farben verwendet.
public enum ZuschnittFarbe: String, Sendable, CaseIterable {
    case rest, bestand, kaufen, restNeu, verschnitt

    public var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .rest: return (0.20, 0.64, 0.33)  // grün: Rest wird verwertet
        case .bestand: return (0.16, 0.45, 0.86)  // blau: ganze Stange aus dem Bestand
        case .kaufen: return (0.93, 0.53, 0.10)  // orange: muss gekauft werden
        case .restNeu: return (0.20, 0.64, 0.33)  // gestrichelt grün: kommt als Rest in den Bestand
        case .verschnitt: return (0.56, 0.56, 0.58)  // grau
        }
    }

    public var titel: String {
        switch self {
        case .rest: return "aus Rest"
        case .bestand: return "aus Bestand"
        case .kaufen: return "kaufen"
        case .restNeu: return "neuer Rest"
        case .verschnitt: return "Verschnitt"
        }
    }
}

/// Stück auf einer Platte (mm, Ursprung links oben der Platte).
public struct ZuschnittFlaeche: Equatable, Sendable {
    public var b: Double
    public var h: Double
    public var x: Double
    public var y: Double
    public var gedreht: Bool

    public init(b: Double, h: Double, x: Double = 0, y: Double = 0, gedreht: Bool = false) {
        self.b = b
        self.h = h
        self.x = x
        self.y = y
        self.gedreht = gedreht
    }

    init?(json: JSONValue) {
        guard let b = json["b"]?.doubleValue, let h = json["h"]?.doubleValue else { return nil }
        self.init(
            b: b, h: h, x: json["x"]?.doubleValue ?? 0, y: json["y"]?.doubleValue ?? 0,
            gedreht: json["gedreht"]?.boolValue ?? false)
    }

    public var masseText: String { BestandText.format(b, h) }
}

/// Eine Stange bzw. Platte im Zuschnitt: woher sie kommt und was aus ihr geschnitten wird.
public struct ZuschnittQuelle: Identifiable, Equatable, Sendable {
    public var index: Int
    public var art: ZuschnittQuelleArt
    public var kennung: String?
    /// Stange: Länge; Platte: `b`, `h`.
    public var laenge: Double?
    public var b: Double?
    public var h: Double?
    public var stuecke: [Double]
    public var flaechen: [ZuschnittFlaeche]
    /// Stange: Länge des Rests nach dem Zuschnitt; Platte: neue Restrechtecke.
    public var restNeu: Double?
    public var resteNeu: [ZuschnittFlaeche]
    /// Der Rest ist Verschnitt (unter dem Mindestrest).
    public var verschnitt: Bool
    /// `verschnitt` kam vom Kernel (sonst entscheidet der Mindestrest der Ansicht).
    public var verschnittAngegeben: Bool

    public var id: Int { index }
    public var istPlatte: Bool { b != nil && h != nil }

    public init(
        index: Int, art: ZuschnittQuelleArt, kennung: String? = nil, laenge: Double? = nil, b: Double? = nil,
        h: Double? = nil, stuecke: [Double] = [], flaechen: [ZuschnittFlaeche] = [], restNeu: Double? = nil,
        resteNeu: [ZuschnittFlaeche] = [], verschnitt: Bool = false, verschnittAngegeben: Bool = false
    ) {
        self.index = index
        self.art = art
        self.kennung = kennung
        self.laenge = laenge
        self.b = b
        self.h = h
        self.stuecke = stuecke
        self.flaechen = flaechen
        self.restNeu = restNeu
        self.resteNeu = resteNeu
        self.verschnitt = verschnitt
        self.verschnittAngegeben = verschnittAngegeben
    }

    init?(json: JSONValue, index: Int) {
        guard json.objectValue != nil else { return nil }
        let art = ZuschnittQuelleArt(rawValue: json["art"]?.lenientString ?? "") ?? .kaufen
        let roh = json["stuecke"]?.arrayValue ?? []
        let rest = json["rest_neu"]
        self.init(
            index: index, art: art, kennung: json["kennung"]?.lenientString, laenge: json["laenge"]?.doubleValue,
            b: json["b"]?.doubleValue, h: json["h"]?.doubleValue,
            stuecke: roh.compactMap { $0.objectValue == nil ? $0.doubleValue : nil },
            flaechen: roh.compactMap(ZuschnittFlaeche.init(json:)),
            restNeu: rest?.doubleValue, resteNeu: rest?.arrayValue?.compactMap(ZuschnittFlaeche.init(json:)) ?? [],
            verschnitt: json["verschnitt"]?.boolValue ?? false, verschnittAngegeben: json["verschnitt"]?.boolValue != nil)
    }

    /// „R-0008 · 610 mm“, „Bestand · 1.000 mm“, „kaufen · 2.500 × 1.250 mm“.
    public var titel: String {
        let masse = istPlatte ? BestandText.format(b ?? 0, h ?? 0) : (laenge.map(KevFormat.length) ?? "–")
        switch art {
        case .rest: return "\(kennung ?? "Rest") · \(masse)"
        case .bestand: return "Bestand · \(masse)"
        case .kaufen: return "kaufen · \(masse)"
        }
    }

    /// Restlänge nach allen Stücken und Sägeschnitten (Stange), aus `rest_neu` oder gerechnet.
    public func restLaenge(saegeschnitt: Double) -> Double {
        if let restNeu { return max(0, restNeu) }
        let l = laenge ?? 0
        return max(0, l - stuecke.reduce(0, +) - Double(stuecke.count) * saegeschnitt)
    }

    /// Ob der Rest dieser Stange Verschnitt ist: Angabe des Kernels, sonst unter dem Mindestrest.
    public func restIstVerschnitt(saegeschnitt: Double, mindestrest: Double) -> Bool {
        if verschnittAngegeben { return verschnitt }
        return restLaenge(saegeschnitt: saegeschnitt) < mindestrest
    }

    /// Abschnitte der Leiste von links nach rechts (mm): Stücke, Sägeschnitte und am Ende der Rest.
    public func segmente(saegeschnitt: Double, mindestrest: Double) -> [LeistenSegment] {
        var out: [LeistenSegment] = []
        var pos = 0.0
        for (i, s) in stuecke.enumerated() {
            out.append(LeistenSegment(art: .stueck, start: pos, laenge: s, index: i))
            pos += s
            if saegeschnitt > 0, pos + saegeschnitt <= (laenge ?? .infinity) + 0.01 {
                out.append(LeistenSegment(art: .schnitt, start: pos, laenge: saegeschnitt, index: i))
                pos += saegeschnitt
            }
        }
        let rest = restLaenge(saegeschnitt: saegeschnitt)
        if rest > 0.05 {
            let verschnitt = restIstVerschnitt(saegeschnitt: saegeschnitt, mindestrest: mindestrest)
            out.append(LeistenSegment(art: verschnitt ? .verschnitt : .restNeu, start: pos, laenge: rest, index: 0))
        }
        return out
    }
}

/// Abschnitt einer Zuschnittleiste in mm.
public struct LeistenSegment: Equatable, Sendable {
    public enum Art: Equatable, Sendable { case stueck, schnitt, restNeu, verschnitt }
    public var art: Art
    public var start: Double
    public var laenge: Double
    /// Bei Stücken: Stelle in `stuecke`.
    public var index: Int

    public init(art: Art, start: Double, laenge: Double, index: Int = 0) {
        self.art = art
        self.start = start
        self.laenge = laenge
        self.index = index
    }

    public var farbe: ZuschnittFarbe? {
        switch art {
        case .stueck, .schnitt: return nil  // Farbe der Quelle bzw. Lücke
        case .restNeu: return .restNeu
        case .verschnitt: return .verschnitt
        }
    }
}

/// Zuschnitt einer Stangenware oder Plattensorte mit Quellen aus dem Bestand.
public struct BestandZuschnitt: Identifiable, Equatable, Sendable {
    public var stockID: String
    public var benennung: String
    public var istPlatte: Bool
    public var platteB: Double?
    public var platteH: Double?
    public var stangenlaenge: Double?
    public var saegeschnitt: Double
    public var quellen: [ZuschnittQuelle]
    /// Neue Reste ab Mindestrest: Längen (Stangen) bzw. Rechtecke (Platten).
    public var neueReste: [Double]
    public var neueResteFlaechen: [ZuschnittFlaeche]
    public var ausBestandReste: Int
    public var ausBestandGanze: Int
    public var kaufen: Int
    /// Verschnitt laut Kernel in Prozent. Mit `verschnittDefinition` "2" (Kernel ab 22.10.2026) genau wie
    /// `MaterialZuschnitt.prozent`: Sägeschnitte und Reste unter dem Mindestrest, bezogen auf die verplante Länge bzw.
    /// Fläche; ohne Angabe ein älterer Kernel (Stangen: alles außer den Stücken), dann rechnet die App selbst.
    public var verschnittProzent: Double?
    public var verschnittDefinition: String?
    /// Mindestrest dieses Lagerteils, mit dem der Kernel gerechnet hat.
    public var mindestrest: Double?
    /// Platten: Stücke, die größer als die Platte sind.
    public var zuGross: [ZuschnittFlaeche]

    public var id: String { stockID }

    public init(
        stockID: String, benennung: String, istPlatte: Bool = false, platteB: Double? = nil, platteH: Double? = nil,
        stangenlaenge: Double? = nil, saegeschnitt: Double = 3, quellen: [ZuschnittQuelle], neueReste: [Double] = [],
        neueResteFlaechen: [ZuschnittFlaeche] = [], ausBestandReste: Int = 0, ausBestandGanze: Int = 0, kaufen: Int = 0,
        verschnittProzent: Double? = nil, mindestrest: Double? = nil, zuGross: [ZuschnittFlaeche] = [],
        verschnittDefinition: String? = nil
    ) {
        self.stockID = stockID
        self.benennung = benennung
        self.istPlatte = istPlatte
        self.platteB = platteB
        self.platteH = platteH
        self.stangenlaenge = stangenlaenge
        self.saegeschnitt = saegeschnitt
        self.quellen = quellen
        self.neueReste = neueReste
        self.neueResteFlaechen = neueResteFlaechen
        self.ausBestandReste = ausBestandReste
        self.ausBestandGanze = ausBestandGanze
        self.kaufen = kaufen
        self.verschnittProzent = verschnittProzent
        self.verschnittDefinition = verschnittDefinition
        self.mindestrest = mindestrest
        self.zuGross = zuGross
    }

    /// Aus `BOM.cuts[i]`; nil ohne `quellen` (älterer Kernel, dann gilt der bisherige Zuschnitt).
    public init?(json: JSONValue) {
        guard json.objectValue != nil, let roh = json["quellen"]?.arrayValue else { return nil }
        let quellen = roh.enumerated().compactMap { ZuschnittQuelle(json: $1, index: $0) }
        let platte = json["platte"]
        let istPlatte = json["art"]?.lenientString == "platte" || platte != nil || quellen.contains(where: \.istPlatte)
        let stockID = json["stock_id"]?.lenientString ?? json["benennung"]?.lenientString ?? ""
        // ohne `neue_reste`: Reste der Quellen, die kein Verschnitt sind
        let neu = json["neue_reste"]?.arrayValue
        var kaufen = json["kaufen"]?.intValue ?? quellen.filter { $0.art == .kaufen }.count
        if json["kaufen"]?.arrayValue != nil { kaufen = quellen.filter { $0.art == .kaufen }.count }
        self.init(
            stockID: stockID, benennung: json["benennung"]?.lenientString ?? stockID, istPlatte: istPlatte,
            platteB: platte?["b"]?.doubleValue ?? platte?.doubles?.first,
            platteH: platte?["h"]?.doubleValue ?? platte?.doubles.flatMap { $0.count > 1 ? $0[1] : nil },
            stangenlaenge: json["stangenlaenge"]?.doubleValue,
            saegeschnitt: json["saegeschnitt"]?.doubleValue ?? 3, quellen: quellen,
            neueReste: neu?.compactMap { $0.objectValue == nil ? $0.doubleValue : nil }
                ?? quellen.filter { !$0.verschnitt && !$0.istPlatte }.compactMap(\.restNeu).filter { $0 > 0 },
            neueResteFlaechen: neu?.compactMap(ZuschnittFlaeche.init(json:)) ?? quellen.flatMap(\.resteNeu),
            ausBestandReste: json["aus_bestand"]?["reste"]?.intValue ?? quellen.filter { $0.art == .rest }.count,
            ausBestandGanze: json["aus_bestand"]?["ganze"]?.intValue ?? quellen.filter { $0.art == .bestand }.count,
            kaufen: kaufen, verschnittProzent: json["verschnitt_prozent"]?.doubleValue,
            mindestrest: json["mindestrest"]?.doubleValue,
            zuGross: json["zu_gross"]?.arrayValue?.compactMap(ZuschnittFlaeche.init(json:)) ?? [],
            verschnittDefinition: json["verschnitt_definition"]?.lenientString)
    }

    /// Längste Quelle (gemeinsamer Maßstab aller Leisten dieses Zuschnitts).
    public var laengsteQuelle: Double {
        quellen.compactMap(\.laenge).max() ?? stangenlaenge ?? 1
    }

    /// „aus Bestand: 1 Rest, 1 Stange · kaufen: 1 Stange“.
    public var herkunftText: String {
        let einheit = istPlatte ? ("Platte", "Platten") : ("Stange", "Stangen")
        var aus: [String] = []
        if ausBestandReste > 0 { aus.append(KevFormat.count(ausBestandReste, one: "Rest", many: "Reste")) }
        if ausBestandGanze > 0 { aus.append(KevFormat.count(ausBestandGanze, one: einheit.0, many: einheit.1)) }
        var parts: [String] = []
        if !aus.isEmpty { parts.append("aus Bestand: " + aus.joined(separator: ", ")) }
        if kaufen > 0 { parts.append("kaufen: " + KevFormat.count(kaufen, one: einheit.0, many: einheit.1)) }
        return parts.isEmpty ? "nichts zu schneiden" : parts.joined(separator: " · ")
    }

    /// Neue Reste als Text: „144 mm, 697 mm“ bzw. „600 × 400 mm“.
    public var neueResteText: String {
        istPlatte
            ? neueResteFlaechen.map(\.masseText).joined(separator: ", ")
            : neueReste.map(KevFormat.length).joined(separator: ", ")
    }

    public var hatNeueReste: Bool { istPlatte ? !neueResteFlaechen.isEmpty : !neueReste.isEmpty }

    /// Der Kernel rechnet den Verschnitt wie die App (Definition 2, siehe `verschnittProzent`).
    public var verschnittWieApp: Bool { verschnittDefinition == MaterialZuschnitt.definition }
}

/// Maßstab der Zuschnittansicht.
public enum ZuschnittMassstab {
    /// Punkte je mm für Leisten: alle Quellen eines Zuschnitts im selben Maßstab, die längste füllt die Breite.
    public static func skala(breite: Double, laengen: [Double]) -> Double {
        guard breite > 0, let laengste = laengen.filter({ $0 > 0 }).max() else { return 0 }
        return breite / laengste
    }

    /// Punkte je mm für Platten: alle Platten im selben Maßstab, die größte passt in `breite` × `hoehe`.
    public static func skala2D(breite: Double, hoehe: Double, platten: [(b: Double, h: Double)]) -> Double {
        let maxB = platten.map(\.b).max() ?? 0
        let maxH = platten.map(\.h).max() ?? 0
        guard breite > 0, hoehe > 0, maxB > 0, maxH > 0 else { return 0 }
        return min(breite / maxB, hoehe / maxH)
    }
}

// MARK: - Einkaufsliste

public struct EinkaufsPosition: Identifiable, Equatable, Sendable {
    public var id: String
    public var benennung: String
    public var menge: Double
    public var einheit: String
    public var preisJe: Double?
    public var preis: Double?
    public var link: URL?
    public var linkName: String?
    public var hinweis: String?
    /// Preisstand (Monat), falls der Kernel ihn mitschickt.
    public var stand: String?

    public init(
        id: String, benennung: String, menge: Double, einheit: String, preisJe: Double? = nil, preis: Double? = nil,
        link: URL? = nil, linkName: String? = nil, hinweis: String? = nil, stand: String? = nil
    ) {
        self.id = id
        self.benennung = benennung
        self.menge = menge
        self.einheit = einheit
        self.preisJe = preisJe
        self.preis = preis
        self.link = link
        self.linkName = linkName
        self.hinweis = hinweis
        self.stand = stand
    }

    init?(json: JSONValue, index: Int) {
        guard json.objectValue != nil else { return nil }
        let id = json["id"]?.lenientString ?? "position-\(index + 1)"
        let menge = json["menge"]?.doubleValue ?? 1
        let preisJe = json["preis_je"]?.doubleValue
        let linkRoh = json["link"]
        let urlText = linkRoh?.stringValue ?? linkRoh?["url"]?.stringValue ?? json["bezugsquelle"]?["url"]?.stringValue
        self.init(
            id: id, benennung: json["benennung"]?.lenientString ?? json["name"]?.lenientString ?? id, menge: menge,
            einheit: json["einheit"]?.lenientString ?? "Stück", preisJe: preisJe,
            preis: json["preis"]?.doubleValue ?? preisJe.map { $0 * menge },
            link: urlText.flatMap(Self.url),
            linkName: json["link_text"]?.lenientString ?? linkRoh?["name"]?.lenientString
                ?? json["bezugsquelle"]?["name"]?.lenientString,
            hinweis: json["hinweis"]?.lenientString, stand: json["preis_stand"]?.lenientString ?? json["stand"]?.lenientString)
    }

    /// Nur http(s)-Adressen werden zu Links.
    static func url(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: t), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme), u.host != nil
        else { return nil }
        return u
    }

    public var mengeText: String { KevFormat.compact(menge, maxDigits: 2) }

    /// Anzeigename des Links: Name der Bezugsquelle, sonst der Host.
    public var linkTitel: String? {
        guard let link else { return nil }
        return linkName ?? link.host?.replacingOccurrences(of: "www.", with: "")
    }
}

/// Erweiterung der BOM um Bestand (BESTAND.md): Zuschnitt mit Quellen, Einkaufsliste, Stand der Bestandsdatei.
public struct BOMBestand: Equatable, Sendable {
    public var run: Int
    public var zuschnitte: [BestandZuschnitt]
    public var einkaufsliste: [EinkaufsPosition]
    public var bestandStand: String?
    /// Es fehlt Material (die Einkaufsliste ist nicht leer).
    public var fehlt: Bool
    /// Stückgut je Schraubenlänge, Mutter, Scheibe: gebraucht, aus dem Bestand, zu kaufen.
    public var stueckgut: [StueckgutBedarf]
    /// Summe der Einkaufsliste vom Kernel (sonst gerechnet) und sein Hinweis zu den Preisen.
    public var einkaufSumme: Double?
    public var einkaufHinweis: String?
    /// Zukaufteile mit Bestand (`BOM.zukauf_bestand`, Strang „Feinschliff 2“): je Stücklistenzeile gebraucht, aus dem
    /// Bestand, zu kaufen. nil: der Kernel gleicht Zukaufteile nicht ab (dann stehen sie ganz auf der Einkaufsliste).
    public var zukaufBestand: [ZukaufBestand]?
    /// Filament im Bestand je Material (`BOM.filament_bestand`, Strang „Bestand Stufe 2“). nil: das Projekt führt kein
    /// Filament (dann nennt die Einkaufsliste keine Spulen).
    public var filamentBestand: [FilamentBestand]?

    public init(
        run: Int, zuschnitte: [BestandZuschnitt], einkaufsliste: [EinkaufsPosition], bestandStand: String? = nil,
        fehlt: Bool? = nil, stueckgut: [StueckgutBedarf] = [], einkaufSumme: Double? = nil, einkaufHinweis: String? = nil,
        zukaufBestand: [ZukaufBestand]? = nil, filamentBestand: [FilamentBestand]? = nil
    ) {
        self.run = run
        self.zuschnitte = zuschnitte
        self.einkaufsliste = einkaufsliste
        self.bestandStand = bestandStand
        self.fehlt = fehlt ?? !einkaufsliste.isEmpty
        self.stueckgut = stueckgut
        self.einkaufSumme = einkaufSumme
        self.einkaufHinweis = einkaufHinweis
        self.zukaufBestand = zukaufBestand
        self.filamentBestand = filamentBestand
    }

    /// Aus der BOM-Nachricht; nil, wenn der Kernel keine Bestandsfelder schickt.
    public init?(json: JSONValue) {
        let zuschnitte = (json["cuts"]?.arrayValue ?? []).compactMap(BestandZuschnitt.init(json:))
        let liste = json["einkaufsliste"]?.arrayValue
        guard !zuschnitte.isEmpty || liste != nil || json["bestand_stand"] != nil || json["fehlt"] != nil
            || json["stueckgut"] != nil || json["zukauf_bestand"] != nil || json["filament_bestand"] != nil
        else {
            return nil
        }
        self.init(
            run: json["run"]?.intValue ?? 0, zuschnitte: zuschnitte,
            einkaufsliste: (liste ?? []).enumerated().compactMap { EinkaufsPosition(json: $1, index: $0) },
            bestandStand: json["bestand_stand"]?.lenientString, fehlt: json["fehlt"]?.boolValue,
            stueckgut: (json["stueckgut"]?.arrayValue ?? []).compactMap(StueckgutBedarf.init(json:)),
            einkaufSumme: json["einkauf_summe"]?.doubleValue, einkaufHinweis: json["einkauf_hinweis"]?.lenientString,
            zukaufBestand: json["zukauf_bestand"]?.arrayValue.map { $0.compactMap(ZukaufBestand.init(json:)) },
            filamentBestand: json["filament_bestand"]?.arrayValue.map { $0.compactMap(FilamentBestand.init(json:)) })
    }

    /// Summe der Einkaufsliste: Angabe des Kernels, sonst gerechnet (nil, wenn keine Position einen Preis hat).
    public var summe: Double? {
        if let einkaufSumme { return einkaufSumme }
        let preise = einkaufsliste.compactMap(\.preis)
        return preise.isEmpty ? nil : preise.reduce(0, +)
    }

    /// Positionen ohne Preis (die Summe ist dann unvollständig).
    public var ohnePreis: Int { einkaufsliste.filter { $0.preis == nil }.count }

    public func zuschnitt(_ stockID: String) -> BestandZuschnitt? { zuschnitte.first { $0.stockID == stockID } }

    /// Etwas aus dem Bestand wird verplant oder es entstehen Reste: „Gebaut“ hat etwas zu buchen.
    public var hatBuchbares: Bool {
        zuschnitte.contains { $0.quellen.contains { $0.art != .kaufen } || $0.hatNeueReste }
            || stueckgut.contains { $0.ausBestand > 0 } || (zukaufBestand ?? []).contains { $0.ausBestand > 0 }
    }

    /// Bestand einer Zukauf-Zeile der Stückliste: gleiche `stock_id` und Position, sonst der erste noch freie Eintrag
    /// mit gleicher `stock_id` (wie `_bestand_fuer` in `kernel/src/kevcad_kernel/bestand/einkauf.py`).
    public static func zukaufBestand(
        stockID: String?, pos: Int?, in liste: [ZukaufBestand], benutzt: inout Set<Int>
    ) -> ZukaufBestand? {
        guard let stockID else { return nil }
        let kandidaten = liste.indices.filter { liste[$0].stockID == stockID && !benutzt.contains($0) }
        if let pos, let i = kandidaten.first(where: { liste[$0].pos == pos }) {
            benutzt.insert(i)
            return liste[i]
        }
        guard let i = kandidaten.first else { return nil }
        benutzt.insert(i)
        return liste[i]
    }
}

/// Zukaufteil der Stückliste mit Bestand (`BOM.zukauf_bestand`): Zukaufteile, Kameras, Objektive und Kamerazubehör
/// führt der Bestand als Stückgut ohne Länge (Strang „Feinschliff 2“).
public struct ZukaufBestand: Identifiable, Equatable, Sendable {
    public var stockID: String
    /// Position der Stückliste (nil, wenn der Kernel keine schickt).
    public var pos: Int?
    public var benennung: String
    public var anzahl: Int
    public var ausBestand: Int
    public var kaufen: Int

    public var id: String { stockID + "/" + (pos.map(String.init) ?? "-") }

    public init(stockID: String, pos: Int? = nil, benennung: String, anzahl: Int, ausBestand: Int, kaufen: Int) {
        self.stockID = stockID
        self.pos = pos
        self.benennung = benennung
        self.anzahl = anzahl
        self.ausBestand = ausBestand
        self.kaufen = kaufen
    }

    init?(json: JSONValue) {
        guard let id = json["stock_id"]?.lenientString else { return nil }
        let anzahl = json["anzahl"]?.intValue ?? 0
        let aus = json["aus_bestand"]?.intValue ?? 0
        self.init(
            stockID: id, pos: json["pos"]?.intValue, benennung: json["benennung"]?.lenientString ?? id, anzahl: anzahl,
            ausBestand: aus, kaufen: json["kaufen"]?.intValue ?? max(0, anzahl - aus))
    }
}

/// Stückgut der Stückliste mit Bestand (`BOM.stueckgut`, BESTAND.md Anhang S-K).
public struct StueckgutBedarf: Identifiable, Equatable, Sendable {
    public var stockID: String
    public var benennung: String
    public var masseText: String
    public var laenge: Double?
    public var anzahl: Int
    public var ausBestand: Int
    public var kaufen: Int

    public var id: String { stockID + "/" + (laenge.map { KevFormat.input($0) } ?? "-") }

    public init(
        stockID: String, benennung: String, masseText: String = "", laenge: Double? = nil, anzahl: Int,
        ausBestand: Int, kaufen: Int
    ) {
        self.stockID = stockID
        self.benennung = benennung
        self.masseText = masseText
        self.laenge = laenge
        self.anzahl = anzahl
        self.ausBestand = ausBestand
        self.kaufen = kaufen
    }

    init?(json: JSONValue) {
        guard let id = json["stock_id"]?.lenientString else { return nil }
        let anzahl = json["anzahl"]?.intValue ?? 0
        let aus = json["aus_bestand"]?.intValue ?? 0
        self.init(
            stockID: id, benennung: json["benennung"]?.lenientString ?? id,
            masseText: json["masse_text"]?.lenientString ?? "", laenge: json["laenge"]?.doubleValue, anzahl: anzahl,
            ausBestand: aus, kaufen: json["kaufen"]?.intValue ?? max(0, anzahl - aus))
    }
}

// MARK: - Zustand im AppModel

public enum BestandAktivitaet: Equatable, Sendable {
    case idle
    case saving
    case failed(String)
}

/// Hinweis nach einer Buchung („Gebaut“ oder „Rückgängig“), mit der Buchungs-id für „Rückgängig“.
public struct BuchungsHinweis: Equatable, Sendable {
    public var buchung: String?
    public var text: String
    public var zeit: Date

    public init(buchung: String?, text: String, zeit: Date = Date()) {
        self.buchung = buchung
        self.text = text
        self.zeit = zeit
    }
}

public struct BestandZustand: Equatable, Sendable {
    /// Bestand des offenen Projekts; nil ohne Projekt oder bevor BESTAND da ist.
    public var bestand: Bestand?
    /// BESTAND kam seit dem Verbinden mindestens einmal (sonst kennt der Kernel den Bestand noch nicht).
    public var empfangen: Bool
    public var buchungen: [BestandBuchung]
    public var stand: String?
    /// Pfad der Bestandsdatei des Projekts und Fehlertext, wenn sie nicht lesbar ist (dann ist `bestand` nil).
    public var datei: String?
    public var fehler: String?
    /// Bestandsteil der letzten Stückliste (gehört zu `AppModel.bom`).
    public var zuschnitt: BOMBestand?
    public var aktivitaet: BestandAktivitaet
    public var hinweis: BuchungsHinweis?
    /// Was „Gebaut“ vom Filament abbuchen würde (BESTAND `gebaut_filament`, Strang „Bestand Stufe 2“); nil, wenn das
    /// Projekt kein Filament führt oder der Kernel älter ist.
    public var gebautFilament: GebautFilament?

    public init(
        bestand: Bestand? = nil, empfangen: Bool = false, buchungen: [BestandBuchung] = [], stand: String? = nil,
        zuschnitt: BOMBestand? = nil, aktivitaet: BestandAktivitaet = .idle, hinweis: BuchungsHinweis? = nil,
        gebautFilament: GebautFilament? = nil
    ) {
        self.bestand = bestand
        self.empfangen = empfangen
        self.buchungen = buchungen
        self.stand = stand
        self.zuschnitt = zuschnitt
        self.aktivitaet = aktivitaet
        self.hinweis = hinweis
        self.gebautFilament = gebautFilament
    }
}

/// Aktionen zum Bestand, implementiert vom App-Kern (AppController). Die Oberfläche ruft sie über
/// `model.actions as? BestandActions` auf; der Demomodus kennt sie nicht.
@MainActor
public protocol BestandActions: AnyObject {
    func requestBestand()
    /// Ganzen Posten speichern (`posten` nil entfernt ihn).
    func saveBestandPosten(id: String, posten: JSONValue?, grund: String)
    func saveBestandEinstellungen(_ einstellungen: BestandEinstellungen, grund: String)
    /// Filament (Strang „Bestand Stufe 2“): `kennung` nil legt `anzahl` gleiche Spulen an, sonst ändert es diese Spule;
    /// `spule` nil mit `kennung` entfernt sie. Dieselben Regeln wie MCP `bestand_eintragen`.
    func saveBestandSpule(kennung: String?, spule: SpulenEingabe?, anzahl: Int?, grund: String)
    /// Filament im Projekt führen, ohne dass eine Spule da ist (dann steht alles Filament auf der Einkaufsliste).
    func fuehreFilament(grund: String)
    /// „Gebaut“: bucht ab, was der Zuschnitt der aktuellen Stückliste aus dem Bestand verplant.
    func bucheGebaut()
    /// „Gedruckt“ (Strang „Rest Druck“): bucht das Filament dieser Platten der Druckvorschau ab (leer = alle noch nicht
    /// gebuchten), `spule` zuerst; wie MCP `gedruckt_buchen`.
    func bucheGedruckt(platten: [Int], spule: String?)
    func buchungRueckgaengig(_ id: String)
    func verwerfeBuchungsHinweis()
    /// Einkaufsliste als CSV nach `<projekt>/output/` schreiben und im Finder zeigen.
    func exportEinkaufsliste()
}

// MARK: - Texte

public enum BestandText {
    /// „600 × 400 mm“.
    public static func format(_ b: Double, _ h: Double) -> String {
        "\(KevFormat.compact(b, maxDigits: 1)) × \(KevFormat.compact(h, maxDigits: 1)) mm"
    }

    /// Heutiges Datum im Dateiformat „2026-10-21“.
    public static func heute(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// ISO-Zeit oder Datum lesen; ohne Zeitzone gilt die Ortszeit (Python `datetime.now().isoformat()`).
    public static func datum(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            iso.formatOptions = options
            if let d = iso.date(from: text) { return d }
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = pattern
            if let d = f.date(from: text) { return d }
        }
        return nil
    }

    /// „21.10.2026, 22:14“ bzw. „21.10.2026“.
    public static func anzeige(_ text: String?, mitZeit: Bool = true) -> String? {
        guard let text, let d = datum(text) else { return text }
        let f = DateFormatter()
        f.locale = KevFormat.locale
        f.dateFormat = mitZeit && text.count > 10 ? "dd.MM.yyyy, HH:mm" : "dd.MM.yyyy"
        return f.string(from: d)
    }

    /// Längen aus einer Eingabe wie „430, 610 und 180“ oder „430 610 180 mm“.
    public static func laengen(_ text: String) -> [Double]? {
        let t = text.replacingOccurrences(of: " und ", with: ";").replacingOccurrences(of: "mm", with: " ")
        var teile: [String] = []
        for teil in t.split(whereSeparator: { ";\n\t ".contains($0) }).map(String.init) {
            // „430,610“ ohne Leerzeichen ist eine Liste, „12,5“ eine Zahl: Komma mit drei Ziffern danach trennt
            let stuecke: [String] = teil.components(separatedBy: ",")
            let liste = stuecke.count > 1 && stuecke.dropFirst().allSatisfy { $0.isEmpty || $0.count >= 3 }
            teile.append(contentsOf: liste ? stuecke : [teil])
        }
        let werte = teile.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ", ")) }.filter { !$0.isEmpty }
        let zahlen = werte.compactMap(KevFormat.parseNumber)
        guard !werte.isEmpty, zahlen.count == werte.count, zahlen.allSatisfy({ $0 > 0 }) else { return nil }
        return zahlen
    }

    /// Rechtecke aus einer Eingabe wie „600 × 400, 300 x 200“.
    public static func rechtecke(_ text: String) -> [(b: Double, h: Double)]? {
        let teile: [String] = text.components(separatedBy: CharacterSet(charactersIn: ";\n"))
            .flatMap { $0.components(separatedBy: ",") }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        // Kommas können auch Dezimalzeichen sein: nur trennen, wenn jedes Stück ein × enthält
        let liste = teile.allSatisfy { $0.contains("×") || $0.lowercased().contains("x") || $0.contains("*") }
            ? teile
            : text.components(separatedBy: CharacterSet(charactersIn: ";\n"))
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var out: [(b: Double, h: Double)] = []
        for teil in liste {
            let t = teil.lowercased().replacingOccurrences(of: "mm", with: "")
            let zahlen = t.split(whereSeparator: { "×x*".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
            guard zahlen.count == 2, let b = KevFormat.parseNumber(zahlen[0]), let h = KevFormat.parseNumber(zahlen[1]),
                  b > 0, h > 0
            else { return nil }
            out.append((b, h))
        }
        return out.isEmpty ? nil : out
    }
}

// MARK: - Hilfen für die Oberfläche

extension CatalogItem {
    /// Lieferform nach der Art (Stangenware, Platte, Stückgut).
    public var bestandForm: BestandForm { BestandForm(art: art) }

    /// Standardlänge der Stange aus dem Katalog (`stangenlaenge`).
    public var stangenlaenge: Double? { entry["stangenlaenge"]?.doubleValue }

    /// Standardformat der Platte (`platte: [b, h]` oder `{b, h}`).
    public var plattenformat: (b: Double, h: Double)? {
        let p = entry["platte"]
        if let d = p?.doubles, d.count >= 2 { return (d[0], d[1]) }
        if let b = p?["b"]?.doubleValue, let h = p?["h"]?.doubleValue { return (b, h) }
        return nil
    }

    /// Schrauben werden nach Länge geführt.
    public var stueckMitLaenge: Bool { art == "schraube" }
}

extension Bestand {
    /// `anzahl` neue Kennungen in Folge, ab der nächsten freien.
    public func naechsteKennungen(_ form: BestandForm, anzahl: Int) -> [String] {
        guard anzahl > 0 else { return [] }
        let prefix = form.kennungPrefix + "-"
        let start = Int(naechsteKennung(form).dropFirst(prefix.count)) ?? 1
        return (0..<anzahl).map { prefix + String(format: "%04d", start + $0) }
    }
}

extension ZuschnittQuelle {
    /// Lage der Stücke auf der Platte: die des Kernels, sonst zeilenweise nebeneinander (nur für die Zeichnung).
    public func flaechenLayout(saegeschnitt: Double = 3) -> [ZuschnittFlaeche] {
        guard flaechen.count > 1, flaechen.allSatisfy({ $0.x == 0 && $0.y == 0 }) else { return flaechen }
        let breite = b ?? flaechen.map(\.b).reduce(0, +)
        var out: [ZuschnittFlaeche] = []
        var x = 0.0
        var y = 0.0
        var zeile = 0.0
        for f in flaechen.sorted(by: { $0.h > $1.h }) {
            if x > 0, x + f.b > breite {
                x = 0
                y += zeile + saegeschnitt
                zeile = 0
            }
            var g = f
            g.x = x
            g.y = y
            out.append(g)
            x += f.b + saegeschnitt
            zeile = max(zeile, f.h)
        }
        return out
    }
}

extension BestandZuschnitt {
    /// Bisheriger Zuschnitt ohne Bestandsangaben (älterer Kernel oder ein Lagerteil ohne Quellen): alles zu kaufen.
    public init(cut: CutPlan) {
        self.init(
            stockID: cut.stockID, benennung: cut.benennung, stangenlaenge: cut.stangenlaenge,
            saegeschnitt: cut.saegeschnitt,
            quellen: cut.stangen.enumerated().map { i, stuecke in
                ZuschnittQuelle(index: i, art: .kaufen, laenge: cut.stangenlaenge, stuecke: stuecke)
            },
            kaufen: cut.stangen.count, verschnittProzent: cut.verschnittProzent)
    }
}
