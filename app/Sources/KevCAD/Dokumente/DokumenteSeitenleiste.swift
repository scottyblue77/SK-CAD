import AppKit
import KevCADCore
import SwiftUI

/// Seitenleiste im Bereich Dokumente: Zusammenbau, Baugruppen, Einzelteile, Bauplan, Berichte.
struct DokumenteSeitenleiste: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: DokumenteStore
    @ObservedObject var zustand: DokumenteZustand
    @EnvironmentObject private var session: AppSession
    @State private var suche = ""

    var body: some View {
        List(selection: $zustand.markiert) {
            if let u = store.uebersicht, !u.blaetter.isEmpty {
                abschnitt("Zusammenbau", u.zusammenbau)
                abschnitt("Baugruppen", u.baugruppen)
                abschnitt("Einzelteile", u.einzelteile)
            } else {
                Section("Zeichnungen") { leer }
            }
            Section("Fertigung") {
                DokumentZeile(titel: "Bauplan", untertitel: bauplanText, symbol: "hammer",
                              warnung: (store.uebersicht?.bauplan?.probleme ?? 0) > 0 ? store.uebersicht?.bauplan?.probleme : nil)
                    .tag(DokumentAuswahl.bauplan.zeile)
                DokumentZeile(titel: "Berichte", untertitel: "Stückliste, Teileliste, Einkaufsliste, Zuschnitt",
                              symbol: "tablecells")
                    .tag(DokumentAuswahl.berichte.zeile)
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $suche, placement: .sidebar, prompt: "Blätter filtern")
        .contextMenu(forSelectionType: String.self) { zeilen in
            kontextmenue(zeilen)
        } primaryAction: { zeilen in
            if let z = zeilen.first, let a = DokumentAuswahl(zeile: z) { zustand.auswahl = a }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { fuss }
        .onChange(of: zustand.markiert) { _, neu in uebernehmeMarkierung(neu) }
    }

    private var bauplanText: String {
        guard let b = store.uebersicht?.bauplan else { return "Schritt für Schritt bauen" }
        var t = KevFormat.count(b.schritte, one: "Schritt", many: "Schritte")
        if b.probleme > 0 { t += " · " + KevFormat.count(b.probleme, one: "Problem", many: "Probleme") }
        return t
    }

    private func gefiltert(_ liste: [BlattEintrag]) -> [BlattEintrag] {
        let q = suche.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return liste }
        return liste.filter { $0.titel.lowercased().contains(q) || $0.teile.contains { $0.lowercased().contains(q) } }
    }

    @ViewBuilder
    private func abschnitt(_ titel: String, _ liste: [BlattEintrag]) -> some View {
        let l = gefiltert(liste)
        if !l.isEmpty {
            Section(titel) {
                ForEach(l) { e in
                    BlattZeile(eintrag: e, laedt: store.laedt.contains(e.id) || store.bearbeitung[e.id] != nil,
                               nummer: store.zeichnung(e.id)?.blatt.schriftfeldText("zeichnungsnummer"))
                        .tag(DokumentAuswahl.blatt(e.id).zeile)
                }
            }
        }
    }

    /// Mehrfachauswahl: die gezeigte Auswahl bleibt, solange sie markiert ist, sonst die erste markierte Zeile.
    private func uebernehmeMarkierung(_ neu: Set<String>) {
        if let a = zustand.auswahl, neu.contains(a.zeile) { return }
        let reihenfolge = (store.uebersicht?.zusammenbau ?? []) + (store.uebersicht?.baugruppen ?? [])
            + (store.uebersicht?.einzelteile ?? [])
        let zeilen = reihenfolge.map { DokumentAuswahl.blatt($0.id).zeile } + ["bauplan", "berichte"]
        if let erste = zeilen.first(where: { neu.contains($0) }), let a = DokumentAuswahl(zeile: erste) {
            zustand.waehle(a)
        }
    }

    @ViewBuilder
    private func kontextmenue(_ zeilen: Set<String>) -> some View {
        let blaetter = zeilen.compactMap { DokumentAuswahl(zeile: $0) }.compactMap { a -> String? in
            if case .blatt(let id) = a { return id }
            return nil
        }
        let reihenfolge = store.uebersicht?.blaetter.map(\.id) ?? []
        let ids = reihenfolge.filter { blaetter.contains($0) }
        if !ids.isEmpty {
            Button(ids.count == 1 ? "Als PDF sichern …" : "\(ids.count) Blätter als PDF sichern …") {
                BlattAusgabe.pdfSichern(ids, model: model, fenster: session.projectWindow) { t, f in zustand.melde(t, fehler: f) }
            }
            Button(ids.count == 1 ? "Drucken …" : "\(ids.count) Blätter drucken …") {
                BlattAusgabe.drucken(ids, model: model, fenster: session.projectWindow) { t, f in zustand.melde(t, fehler: f) }
            }
            let fertig = ids.compactMap { store.zeichnung($0) }
            if fertig.count == ids.count {
                ShareLink(item: BlattPDFDatei(zeichnungen: fertig, name: BlattPDF.dateiname(fertig, projekt: model.project?.name)),
                          preview: SharePreview(fertig.count == 1 ? fertig[0].blatt.titel : "\(fertig.count) Zeichnungen")) {
                    Text("Teilen …")
                }
            }
            Divider()
            Button("Neu rechnen") { for id in ids { model.dokumenteActions?.zeichnungAnfordern(id) } }
            let teile = Array(Set(ids.compactMap { store.uebersicht?.blatt($0) }.flatMap(\.teile))).sorted()
            if !teile.isEmpty {
                Button(teile.count == 1 ? "Teil im 3D-Modell zeigen" : "Teile im 3D-Modell zeigen") {
                    zustand.zeigeIm3D?(teile)
                }
            }
        } else {
            Button("Zeichnungen erzeugen") { erzeugen() }
                .disabled(store.erzeugt || model.parts.isEmpty)
            Button("Alle Blätter neu rechnen") { model.dokumenteActions?.dokumenteAnfordern() }
        }
    }

    private func erzeugen() {
        model.dokumenteActions?.zeichnungenErzeugen(teile: nil, art: "teil", format: nil)
    }

    /// Noch keine Blätter: Hinweis und „Zeichnungen erzeugen“ (DRAWING_CREATE).
    @ViewBuilder
    private var leer: some View {
        if store.uebersichtLaedt || store.erzeugt {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(store.erzeugt ? "Zeichnungen werden angelegt …" : "Blätter werden gerechnet …")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Noch keine Zeichnungen", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Text(model.parts.isEmpty
                     ? "Erst model.py rechnen, dann legt SK-CAD die Zeichnungen an."
                     : "SK-CAD legt für jedes gefertigte Teil ein bemaßtes Blatt an und eines für den Zusammenbau mit Stückliste.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Zeichnungen erzeugen") { erzeugen() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.parts.isEmpty || model.dokumenteActions == nil)
            }
            .padding(.vertical, 8)
            .selectionDisabled()
        }
    }

    private var fuss: some View {
        HStack(spacing: 8) {
            if let u = store.uebersicht, !u.blaetter.isEmpty {
                Text(KevFormat.count(u.blaetter.count, one: "Blatt", many: "Blätter"))
                let verwaist = u.blaetter.reduce(0) { $0 + $1.verwaisteMasse }
                if verwaist > 0 {
                    Label("\(verwaist)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .help("\(verwaist) verwaiste Maße: Bezug nach einer Modelländerung nicht mehr gefunden")
                }
            }
            Spacer()
            if store.uebersichtLaedt || store.erzeugt {
                ProgressView().controlSize(.small)
            }
            Menu {
                Button("Zeichnungen für alle Teile erzeugen") { erzeugen() }
                    .disabled(store.erzeugt || model.parts.isEmpty)
                Button("Alle Blätter neu rechnen") { model.dokumenteActions?.dokumenteAnfordern() }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Zeichnungen anlegen oder neu rechnen")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Eine Zeile für ein Blatt: Titel, Format, Maßstab, Zahl der Maße, verwaiste Maße und Prüfbefunde.
private struct BlattZeile: View {
    let eintrag: BlattEintrag
    let laedt: Bool
    let nummer: String?

    private var symbol: String {
        switch eintrag.inhaltArt {
        case "zusammenbau": return "square.3.layers.3d.down.right"
        case "baugruppe": return "square.stack.3d.up"
        case nil: return "exclamationmark.triangle"
        default: return "doc.text"
        }
    }

    private var untertitel: String {
        if let f = eintrag.fehler { return f }
        var teile = [eintrag.formatText]
        if let m = eintrag.massstab { teile.append(m) }
        teile.append(KevFormat.count(eintrag.masse, one: "Maß", many: "Maße"))
        return teile.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        DokumentZeile(titel: eintrag.titel, untertitel: untertitel, symbol: symbol,
                      fehler: eintrag.verwaisteMasse > 0 ? eintrag.verwaisteMasse : nil,
                      warnung: eintrag.pruefung > 0 ? eintrag.pruefung : nil, laedt: laedt)
            .help([eintrag.titel, nummer].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                  + (eintrag.verwaisteMasse > 0 ? "\n\(eintrag.verwaisteMasse) verwaiste Maße" : "")
                  + (eintrag.pruefung > 0 ? "\n\(eintrag.pruefung) Hinweise der Blattprüfung" : ""))
    }
}

/// Gemeinsames Zeilenlayout der Seitenleiste.
struct DokumentZeile: View {
    let titel: String
    let untertitel: String
    let symbol: String
    var fehler: Int? = nil
    var warnung: Int? = nil
    var laedt = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(titel).lineLimit(1)
                Text(untertitel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if laedt {
                ProgressView().controlSize(.mini)
            }
            if let fehler {
                Text("\(fehler)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.red, in: Capsule())
            }
            if let warnung {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .help("\(warnung) Hinweise")
            }
        }
        .padding(.vertical, 2)
    }
}
