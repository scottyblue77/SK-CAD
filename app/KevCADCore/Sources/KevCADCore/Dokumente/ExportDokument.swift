import CoreGraphics
import Foundation
import PDFKit

// Das Dokument aus allen Bausteinen (Strang P6-A2): Seiten mit eigenem Format, Kopf- und Fußzeile, PDF mit Outline.
// Eine Zeichenfunktion für PDF, Vorschau und Druck.

/// Kopfdaten des Dokuments (Kopf- und Fußzeile, Deckblatt, PDF-Metadaten).
public struct ExportKopf: Sendable {
    public var projekt: String
    /// z. B. „V14 · Meilenstein Halter fertig“; nil ohne Versionen.
    public var version: String?
    public var datum: Date
    public var autor: String

    public init(projekt: String, version: String? = nil, datum: Date = Date(), autor: String = Dokumentautor.standard) {
        self.projekt = projekt
        self.version = version
        self.datum = datum
        self.autor = autor
    }

    public var datumText: String {
        let f = DateFormatter()
        f.locale = KevFormat.locale
        f.dateFormat = "d. MMMM yyyy"
        return f.string(from: datum)
    }

    public var datumKurz: String {
        let f = DateFormatter()
        f.locale = KevFormat.locale
        f.dateFormat = "dd.MM.yyyy"
        return f.string(from: datum)
    }
}

/// Eine Seite: Format (mm), Baustein, Titel in der Kopfzeile, Inhalt.
public struct ExportSeite {
    public enum Inhalt {
        /// Berichtsseite: Inhalt in mm, Ursprung links oben (Kopf- und Fußzeile zeichnet das Dokument).
        case leinwand((ExportLeinwand, ExportSeitenInfo) -> Void)
        /// Eigenes Blatt (Zeichnung): in Punkt, Ursprung links unten, ohne Kopf- und Fußzeile.
        case roh((CGContext, CGSize) -> Void)
    }

    public var groesse: CGSize
    public var baustein: ExportBausteinArt
    public var titel: String
    public var mitKopf: Bool
    public var inhalt: Inhalt
    /// Einträge im Inhaltsverzeichnis des PDF (Unterpunkte des Bausteins), die auf dieser Seite beginnen.
    public var gliederung: [String]

    public init(groesse: CGSize, baustein: ExportBausteinArt, titel: String, mitKopf: Bool = true,
                gliederung: [String] = [], inhalt: Inhalt)
    {
        self.groesse = groesse
        self.baustein = baustein
        self.titel = titel
        self.mitKopf = mitKopf
        self.inhalt = inhalt
        self.gliederung = gliederung
    }

    public var formatName: String {
        if let f = ExportSeitenformat.passend(mm: groesse) { return f.name }
        return "\(Int(groesse.width.rounded())) × \(Int(groesse.height.rounded())) mm"
    }

    public var punkte: CGSize { CGSize(width: groesse.width * ExportSeitenformat.ptJeMM, height: groesse.height * ExportSeitenformat.ptJeMM) }
}

public struct ExportSeitenInfo {
    public var nummer: Int
    public var anzahl: Int
    public var kopf: ExportKopf
    /// Erste Seite je Baustein (für das Inhaltsverzeichnis auf dem Deckblatt).
    public var bausteinSeiten: [(art: ExportBausteinArt, seite: Int, anzahl: Int)]
}

/// Ränder und Bänder der Berichtsseiten.
public enum ExportRand {
    public static let links: CGFloat = 18
    public static let rechts: CGFloat = 14
    public static let oben: CGFloat = 13
    public static let unten: CGFloat = 12
    public static let kopf: CGFloat = 11
    public static let fuss: CGFloat = 9

    /// Inhaltsbereich einer Seite mit Kopf- und Fußzeile (mm, Ursprung links oben).
    public static func inhalt(_ groesse: CGSize) -> CGRect {
        CGRect(x: links, y: oben + kopf, width: groesse.width - links - rechts,
               height: groesse.height - oben - kopf - unten - fuss)
    }
}

public final class ExportDokument {
    public var kopf: ExportKopf
    public private(set) var seiten: [ExportSeite]
    public var hinweise: [String]

    public init(kopf: ExportKopf, seiten: [ExportSeite], hinweise: [String] = []) {
        self.kopf = kopf
        self.seiten = seiten
        self.hinweise = hinweise
    }

    public var bausteinSeiten: [(art: ExportBausteinArt, seite: Int, anzahl: Int)] {
        var out: [(art: ExportBausteinArt, seite: Int, anzahl: Int)] = []
        for (i, s) in seiten.enumerated() {
            if let last = out.last, last.art == s.baustein {
                out[out.count - 1].anzahl += 1
            } else {
                out.append((s.baustein, i + 1, 1))
            }
        }
        return out
    }

    public var formate: [String: Int] {
        var f: [String: Int] = [:]
        for s in seiten { f[s.formatName, default: 0] += 1 }
        return f
    }

    func info(_ i: Int) -> ExportSeitenInfo {
        ExportSeitenInfo(nummer: i + 1, anzahl: seiten.count, kopf: kopf, bausteinSeiten: bausteinSeiten)
    }

    /// Zeichnet Seite `i` in einen Kontext in Punkt mit Ursprung links unten (PDF, Druck, Vorschau mit Skalierung).
    public func zeichne(_ i: Int, in ctx: CGContext) {
        let s = seiten[i]
        ctx.saveGState()
        switch s.inhalt {
        case .roh(let f):
            f(ctx, s.punkte)
        case .leinwand(let f):
            let l = ExportLeinwand(ctx: ctx, groesse: s.groesse)
            if s.mitKopf { kopfUndFuss(l, s, info(i)) }
            f(l, info(i))
        }
        ctx.restoreGState()
    }

    func kopfUndFuss(_ l: ExportLeinwand, _ s: ExportSeite, _ info: ExportSeitenInfo) {
        let w = s.groesse.width, h = s.groesse.height
        let x0 = ExportRand.links, x1 = w - ExportRand.rechts
        let base = ExportRand.oben + 5.2
        // Kopf: Projekt fett, Baustein; rechts Version und Datum
        let pw = l.text(kopf.projekt, x: x0, y: base, .fett(9), farbe: ExportStil.tinte, maxBreite: (x1 - x0) * 0.45)
        l.text("  ·  " + s.titel, x: x0 + pw, y: base, .normal(9), farbe: ExportStil.grau, maxBreite: (x1 - x0) * 0.3)
        let rechts = [kopf.version, kopf.datumKurz].compactMap { $0 }.joined(separator: "  ·  ")
        l.text(rechts, x: x1, y: base, .normal(8), farbe: ExportStil.grau, .rechts, maxBreite: (x1 - x0) * 0.4)
        let linieY = ExportRand.oben + 7.6
        l.linie(CGPoint(x: x0, y: linieY), CGPoint(x: x1, y: linieY), breite: 0.25, farbe: ExportStil.tinte)
        // Akzent links an der Linie (Kennfarbe des Bausteins)
        l.rechteck(CGRect(x: x0, y: linieY - 0.45, width: 12, height: 0.9), fuellung: ExportStil.akzent)
        // Fuß: Kev CAD, Seite x / y
        let fy = h - ExportRand.unten
        l.linie(CGPoint(x: x0, y: fy - 4.8), CGPoint(x: x1, y: fy - 4.8), breite: 0.12, farbe: ExportStil.linie)
        l.text("Erstellt mit SK-CAD  ·  \(kopf.autor)", x: x0, y: fy - 1, .normal(7), farbe: ExportStil.grauHell)
        l.text("Seite \(info.nummer) / \(info.anzahl)", x: x1, y: fy - 1, .mittel(7.5), farbe: ExportStil.grau, .rechts)
    }

    // MARK: PDF

    /// Gliederung für `CGPDFContextSetOutline`: je Baustein ein Eintrag, darunter die Unterpunkte (Abschnitte,
    /// Blätter). Seitenangaben 1-basiert wie im PDF-Betrachter.
    func gliederung() -> [String: Any] {
        var kinder: [[String: Any]] = []
        for (i, s) in seiten.enumerated() {
            let ziel = NSNumber(value: i + 1)
            if kinder.isEmpty || (kinder.last?["art"] as? String) != s.baustein.rawValue {
                kinder.append(["art": s.baustein.rawValue, kCGPDFOutlineTitle as String: s.baustein.titel,
                               kCGPDFOutlineDestination as String: ziel, "unter": [[String: Any]]()])
            }
            for g in s.gliederung {
                var unter = kinder[kinder.count - 1]["unter"] as? [[String: Any]] ?? []
                unter.append([kCGPDFOutlineTitle as String: g, kCGPDFOutlineDestination as String: ziel])
                kinder[kinder.count - 1]["unter"] = unter
            }
        }
        let eintraege: [[String: Any]] = kinder.map { k in
            var e: [String: Any] = [kCGPDFOutlineTitle as String: k[kCGPDFOutlineTitle as String] ?? "",
                                    kCGPDFOutlineDestination as String: k[kCGPDFOutlineDestination as String] ?? 1]
            if let u = k["unter"] as? [[String: Any]], !u.isEmpty { e[kCGPDFOutlineChildren as String] = u }
            return e
        }
        return [kCGPDFOutlineChildren as String: eintraege]
    }

    /// Dauer des letzten PDF in ms (zum Messen).
    public private(set) var pdfMs: Int = 0

    /// Schreibt das PDF (Vektor, Seitenformate gemischt) mit Gliederung direkt aus dem CoreGraphics-Kontext (ohne
    /// erneutes Einlesen über PDFKit, das bei großen Zeichnungsblättern Sekunden kostet).
    public func schreibePDF(nach url: URL) throws {
        let t0 = Date()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var box = CGRect(origin: .zero, size: seiten.first?.punkte ?? ExportSeitenformat().punkte)
        let meta: [CFString: Any] = [
            kCGPDFContextTitle: "\(kopf.projekt) – Dokumente", kCGPDFContextAuthor: kopf.autor,
            kCGPDFContextCreator: "SK-CAD", kCGPDFContextSubject: "Stückliste, Zeichnungen und Bauplan",
        ]
        guard let ctx = CGContext(tmp as CFURL, mediaBox: &box, meta as CFDictionary) else {
            throw ExportFehler.pdf("PDF-Kontext für \(url.path) nicht anlegbar")
        }
        for i in seiten.indices {
            var mb = CGRect(origin: .zero, size: seiten[i].punkte)
            let pageInfo: [CFString: Any] = [kCGPDFContextMediaBox: Data(bytes: &mb, count: MemoryLayout<CGRect>.size)]
            ctx.beginPDFPage(pageInfo as CFDictionary)
            zeichne(i, in: ctx)
            ctx.endPDFPage()
        }
        CGPDFContextSetOutline(ctx, gliederung() as CFDictionary)
        ctx.closePDF()
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.moveItem(at: tmp, to: url)
        pdfMs = Int(Date().timeIntervalSince(t0) * 1000)
    }

    /// Eine Seite als Bild (Vorschau, Prüfbilder), `pixelJeMM` z. B. 4 (≈ 100 dpi).
    public func bild(_ i: Int, pixelJeMM: CGFloat = 4) -> CGImage? {
        let s = seiten[i]
        let w = Int((s.groesse.width * pixelJeMM).rounded()), h = Int((s.groesse.height * pixelJeMM).rounded())
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(ExportStil.weiss)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let k = pixelJeMM / ExportSeitenformat.ptJeMM
        ctx.scaleBy(x: k, y: k)
        zeichne(i, in: ctx)
        return ctx.makeImage()
    }
}

public enum ExportFehler: Error, CustomStringConvertible {
    case pdf(String)
    case leer(String)

    public var description: String {
        switch self {
        case .pdf(let s), .leer(let s): return s
        }
    }
}

/// Autor in PDFs und Berichten: `KEVCAD_AUTOR`, sonst der volle Name des macOS-Benutzers (bei Kevin „Kevin Schwed“).
public enum Dokumentautor {
    public static var standard: String {
        if let name = ProcessInfo.processInfo.environment["KEVCAD_AUTOR"]?.trimmingCharacters(in: .whitespaces),
           !name.isEmpty {
            return name
        }
        let voll = NSFullUserName().trimmingCharacters(in: .whitespaces)
        return voll.isEmpty ? "SK-CAD" : voll
    }
}
