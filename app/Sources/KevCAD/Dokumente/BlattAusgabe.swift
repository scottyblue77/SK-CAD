import AppKit
import CoreTransferable
import KevCADCore
import SwiftUI
import UniformTypeIdentifiers

/// PDF, Druck und Teilen der Zeichnungsblätter direkt aus dem Bereich Dokumente (der große Export-Dialog für alle
/// Bausteine gehört P6-A2 und nutzt denselben BlattZeichner).
@MainActor
enum BlattAusgabe {
    /// Alle Blätter gerechnet holen; fehlende werden angefordert (höchstens 90 s warten).
    static func sicherstellen(_ ids: [String], model: AppModel) async -> [Zeichnung] {
        let store = model.dokumente
        for id in ids where store.zeichnung(id) == nil && !store.laedt.contains(id) {
            model.dokumenteActions?.zeichnungAnfordern(id)
        }
        let ende = Date().addingTimeInterval(90)
        while Date() < ende, ids.contains(where: { store.zeichnung($0) == nil && store.fehler[$0] == nil }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return ids.compactMap { store.zeichnung($0) }
    }

    static func titel(_ zs: [Zeichnung], model: AppModel) -> String {
        if zs.count == 1, let z = zs.first { return BlattPDF.seitentitel(z) }
        return "\(model.project?.name ?? "SK-CAD") – Zeichnungen"
    }

    /// „Als PDF sichern …“: Sichern-Dialog am Fenster, Vorgabe output/ im Projektordner.
    static func pdfSichern(_ ids: [String], model: AppModel, fenster: NSWindow?, melde: @escaping (String, Bool) -> Void) {
        guard !ids.isEmpty else { return }
        Task { @MainActor in
            let zs = await sicherstellen(ids, model: model)
            guard !zs.isEmpty else {
                melde("Die Blätter sind noch nicht gerechnet", true)
                return
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.nameFieldStringValue = BlattPDF.dateiname(zs, projekt: model.project?.name) + ".pdf"
            if let p = model.project?.path {
                let out = p.appendingPathComponent("output", isDirectory: true)
                try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                panel.directoryURL = out
            }
            panel.message = zs.count == 1 ? "Zeichnung als PDF sichern (vektoriell, Maßstab 1:1)"
                : "\(zs.count) Zeichnungen als ein PDF sichern (vektoriell, Formate je Blatt)"
            let fertig: (NSApplication.ModalResponse) -> Void = { r in
                guard r == .OK, let url = panel.url else { return }
                do {
                    try BlattPDF.schreiben(zs, nach: url, metadaten: .init(titel: titel(zs, model: model)))
                    melde("PDF gesichert: \(url.lastPathComponent)", false)
                    model.append(LogLine(text: "PDF gesichert: \(url.path) (\(zs.count) Seiten)"))
                } catch {
                    melde("PDF nicht gesichert: \(error.localizedDescription)", true)
                }
            }
            if let fenster { panel.beginSheetModal(for: fenster, completionHandler: fertig) } else { fertig(panel.runModal()) }
        }
    }

    /// „Drucken …“: macOS-Druckdialog, 1:1 und je Blattformat ein Auftrag.
    static func drucken(_ ids: [String], model: AppModel, fenster: NSWindow?, melde: @escaping (String, Bool) -> Void) {
        guard !ids.isEmpty else { return }
        Task { @MainActor in
            let zs = await sicherstellen(ids, model: model)
            guard !zs.isEmpty else {
                melde("Die Blätter sind noch nicht gerechnet", true)
                return
            }
            BlattDruck.drucken(zs, titel: titel(zs, model: model), fenster: fenster)
        }
    }
}

/// PDF der Blätter zum Teilen (ShareLink): entsteht erst, wenn ein Dienst gewählt ist.
struct BlattPDFDatei: Transferable {
    let zeichnungen: [Zeichnung]
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { d in
            let ordner = FileManager.default.temporaryDirectory.appendingPathComponent("Kev CAD Teilen", isDirectory: true)
            try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
            let datei = ordner.appendingPathComponent(d.name + ".pdf")
            try BlattPDF.daten(d.zeichnungen, metadaten: .init(titel: d.name)).write(to: datei, options: .atomic)
            return SentTransferredFile(datei)
        }
    }
}
