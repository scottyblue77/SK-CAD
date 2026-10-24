import AppKit
import CoreGraphics
import Foundation
import PDFKit

/// Zeichnungsblätter als PDF: vektoriell über CoreGraphics, je Blatt eine Seite in seinem Format (A4 und A3 gemischt in
/// einer Datei), Schrift eingebettet, Titel, Autor und Ersteller gesetzt, Inhaltsverzeichnis mit einem Eintrag je Blatt.
public enum BlattPDF {
    public struct Metadaten: Sendable {
        public var titel: String
        public var autor: String
        public var ersteller: String
        public var thema: String?

        public init(titel: String, autor: String = Dokumentautor.standard, ersteller: String = "SK-CAD", thema: String? = nil) {
            self.titel = titel
            self.autor = autor
            self.ersteller = ersteller
            self.thema = thema
        }
    }

    /// PDF-Daten aller Blätter in dieser Reihenfolge.
    public static func daten(_ zeichnungen: [Zeichnung], metadaten: Metadaten,
                             optionen: BlattZeichner.Optionen = .druck, inhaltsverzeichnis: Bool = true) -> Data {
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out as CFMutableData) else { return Data() }
        var info: [CFString: Any] = [
            kCGPDFContextTitle: metadaten.titel, kCGPDFContextAuthor: metadaten.autor,
            kCGPDFContextCreator: metadaten.ersteller,
        ]
        if let t = metadaten.thema { info[kCGPDFContextSubject] = t }
        var erste = CGRect(origin: .zero, size: zeichnungen.first?.seitengroessePunkte ?? CGSize(width: 842, height: 595))
        guard let ctx = CGContext(consumer: consumer, mediaBox: &erste, info as CFDictionary) else { return Data() }
        for z in zeichnungen {
            var box = CGRect(origin: .zero, size: z.seitengroessePunkte)
            let seite: [CFString: Any] = [kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)]
            ctx.beginPDFPage(seite as CFDictionary)
            BlattZeichner.zeichneSeite(z, in: ctx, optionen: optionen)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        let roh = out as Data
        guard inhaltsverzeichnis, zeichnungen.count > 1 else { return roh }
        return mitInhaltsverzeichnis(roh, titel: zeichnungen.map(seitentitel)) ?? roh
    }

    /// Eintrag im Inhaltsverzeichnis: „KS-B-003 Seitenstange links“.
    public static func seitentitel(_ z: Zeichnung) -> String {
        let nr = z.blatt.schriftfeldText("zeichnungsnummer")
        return nr.isEmpty ? z.blatt.titel : "\(nr) \(z.blatt.titel)"
    }

    /// Vorschlag für den Dateinamen (ohne Endung).
    public static func dateiname(_ zeichnungen: [Zeichnung], projekt: String?) -> String {
        if zeichnungen.count == 1, let z = zeichnungen.first { return sicher(seitentitel(z)) }
        return sicher((projekt.map { "\($0) " } ?? "") + "Zeichnungen")
    }

    static func sicher(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    /// Inhaltsverzeichnis über PDFKit (PDFOutline), ein Eintrag je Seite.
    static func mitInhaltsverzeichnis(_ daten: Data, titel: [String]) -> Data? {
        guard let doc = PDFDocument(data: daten), doc.pageCount == titel.count else { return nil }
        let wurzel = PDFOutline()
        for (i, t) in titel.enumerated() {
            guard let seite = doc.page(at: i) else { continue }
            let eintrag = PDFOutline()
            eintrag.label = t
            eintrag.destination = PDFDestination(page: seite, at: CGPoint(x: 0, y: seite.bounds(for: .mediaBox).height))
            wurzel.insertChild(eintrag, at: wurzel.numberOfChildren)
        }
        doc.outlineRoot = wurzel
        return doc.dataRepresentation()
    }

    /// Schreibt die Blätter als PDF nach `url`.
    public static func schreiben(_ zeichnungen: [Zeichnung], nach url: URL, metadaten: Metadaten) throws {
        try daten(zeichnungen, metadaten: metadaten).write(to: url, options: .atomic)
    }
}

/// Drucken der Blätter: immer 1:1 (`.pageScaleNone`, sonst verkleinert macOS ein A4-Blatt auf 97,18 % und der Maßstab
/// stimmt nicht mehr), je Blattformat ein eigener Druckauftrag (ein Auftrag hat genau eine Papiergröße).
@MainActor
public final class BlattDruck: NSObject {
    /// Ein Druckauftrag: Blätter gleicher Papiergröße.
    public struct Auftrag: Sendable {
        public var zeichnungen: [Zeichnung]
        public var format: String
        public var papier: CGSize
    }

    /// Blätter nach Papiergröße gruppiert, in der Reihenfolge ihres ersten Auftretens.
    public nonisolated static func auftraege(_ zeichnungen: [Zeichnung]) -> [Auftrag] {
        var out: [Auftrag] = []
        for z in zeichnungen {
            if let i = out.firstIndex(where: { $0.papier == z.seitengroessePunkte }) {
                out[i].zeichnungen.append(z)
            } else {
                out.append(Auftrag(zeichnungen: [z], format: z.formatText, papier: z.seitengroessePunkte))
            }
        }
        return out
    }

    /// Druckeinstellungen für einen Auftrag: Papier so groß wie das Blatt, ohne Ränder, nicht skaliert.
    public static func druckInfo(_ a: Auftrag) -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.orientation = a.papier.width > a.papier.height ? .landscape : .portrait
        info.paperSize = a.papier
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        info.scalingFactor = 1
        return info
    }

    /// Druckoperation eines Auftrags (für den Druckdialog oder, mit `info.jobDisposition = .save`, in eine Datei).
    public static func operation(_ a: Auftrag, titel: String, info: NSPrintInfo? = nil) -> NSPrintOperation? {
        let daten = BlattPDF.daten(a.zeichnungen, metadaten: .init(titel: titel), inhaltsverzeichnis: false)
        guard let doc = PDFDocument(data: daten) else { return nil }
        let pi = info ?? druckInfo(a)
        guard let op = doc.printOperation(for: pi, scalingMode: .pageScaleNone, autoRotate: true) else { return nil }
        op.jobTitle = titel
        op.showsProgressPanel = true
        return op
    }

    private var offen: [(Auftrag, String)] = []
    private weak var fenster: NSWindow?
    private var hinweis: String?
    private var abschluss: ((Bool) -> Void)?
    private static var laufend: BlattDruck?

    /// Druckdialog(e) als Blatt am Fenster, nacheinander je Format. `abschluss(true)`, wenn alle gedruckt wurden.
    public static func drucken(_ zeichnungen: [Zeichnung], titel: String, fenster: NSWindow?,
                               abschluss: ((Bool) -> Void)? = nil) {
        guard laufend == nil else { return }
        let liste = auftraege(zeichnungen)
        guard !liste.isEmpty else { return }
        let d = BlattDruck()
        d.fenster = fenster
        d.abschluss = abschluss
        if liste.count > 1 {
            let formate = liste.map { "\($0.format) (\($0.zeichnungen.count) \($0.zeichnungen.count == 1 ? "Blatt" : "Blätter"))" }
            d.hinweis = "Gemischte Formate: \(liste.count) Druckaufträge nacheinander – " + formate.joined(separator: ", ")
        }
        d.offen = liste.enumerated().map { i, a in
            (a, liste.count > 1 ? "\(titel) – \(a.format) (\(i + 1)/\(liste.count))" : titel)
        }
        laufend = d
        d.naechster()
    }

    private func naechster() {
        guard !offen.isEmpty else {
            BlattDruck.laufend = nil
            abschluss?(true)
            return
        }
        let (a, titel) = offen.removeFirst()
        guard let op = BlattDruck.operation(a, titel: titel) else {
            BlattDruck.laufend = nil
            abschluss?(false)
            return
        }
        let panel = op.printPanel
        panel.options = [.showsCopies, .showsPageRange, .showsPaperSize, .showsOrientation, .showsPreview]
        panel.addAccessoryController(DruckHinweis(text: zeile(a)))
        if let fenster {
            op.runModal(for: fenster, delegate: self, didRun: #selector(gedruckt(_:erfolg:kontext:)), contextInfo: nil)
        } else {
            let ok = op.run()
            fertig(ok)
        }
    }

    private func zeile(_ a: Auftrag) -> String {
        let basis = "\(a.format), Maßstab 1:1 auf dem Papier (nicht skaliert)"
        guard let hinweis else { return basis }
        return basis + "\n" + hinweis
    }

    @objc private func gedruckt(_ op: NSPrintOperation, erfolg: Bool, kontext: UnsafeMutableRawPointer?) {
        fertig(erfolg)
    }

    private func fertig(_ ok: Bool) {
        if ok {
            DispatchQueue.main.async { self.naechster() }
        } else {
            offen = []
            BlattDruck.laufend = nil
            abschluss?(false)
        }
    }
}

/// Zusatz im Druckdialog: Format, Hinweis auf den 1:1-Druck und auf gemischte Formate.
final class DruckHinweis: NSViewController, NSPrintPanelAccessorizing {
    private let text: String

    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 420
        let box = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
        ])
        view = box
    }

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        [[.itemName: "Maßstab", .itemDescription: "1:1, nicht skaliert"]]
    }

    func keyPathsForValuesAffectingPreview() -> Set<String> { [] }
}
