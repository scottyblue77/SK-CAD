import AppKit
import KevCADCore
import SwiftUI

/// Inspektor im Bereich Dokumente: Blatt (Format, Maßstab, Automatik), Auswahl (Maß, Ansicht, Notiz), Schriftfeld,
/// Prüfung, verwaiste und ausgeblendete Maße. Jede Änderung geht als DRAWING_EDIT an den Kernel.
struct BlattInspektor: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: DokumenteStore
    @ObservedObject var zustand: DokumenteZustand

    private var z: Zeichnung? { zustand.blattID.flatMap { store.zeichnung($0) } }

    var body: some View {
        Group {
            if let z {
                Form {
                    blattAbschnitt(z)
                    auswahlAbschnitt(z)
                    SchriftfeldAbschnitt(z: z) { ops in bearbeite(ops, z) }
                    pruefAbschnitt(z)
                    ausgeblendetAbschnitt(z)
                    allgemeinAbschnitt(z)
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView {
                    Label(zustand.auswahl == nil ? "Kein Blatt" : "Kein Zeichnungsblatt", systemImage: "doc.text")
                } description: {
                    Text("Format, Maßstab, Schriftfeld und Maße eines Blatts erscheinen hier.")
                }
            }
        }
    }

    private func bearbeite(_ ops: [ZeichnungsOp], _ z: Zeichnung, titel: String? = nil) {
        zustand.bearbeiter.ausfuehren(ops, blatt: z.id, titel: titel)
    }

    // MARK: Blatt

    private func blattAbschnitt(_ z: Zeichnung) -> some View {
        Section("Blatt") {
            LabeledContent("Titel") { Text(z.blatt.titel).lineLimit(1).truncationMode(.middle) }
            // Menüs statt Picker: ein Picker schreibt beim Neuaufbau gelegentlich den alten Wert zurück, und jede
            // Rückschrift wäre eine Änderung am Blatt
            LabeledContent("Format") {
                Menu(z.formatText) {
                    ForEach(ZeichnungText.formate, id: \.self) { f in
                        Button(f.titel) { bearbeite([.format(f.format, ausrichtung: f.ausrichtung)], z) }
                            .disabled(f.format == z.blatt.format && f.ausrichtung == z.blatt.ausrichtung)
                    }
                }
                .fixedSize()
            }
            .help(z.blatt.autoFormat ? "SK-CAD wählt das Format, bis du eines setzt" : "von dir gesetzt")
            LabeledContent("Maßstab") {
                Menu(z.blatt.massstab) {
                    ForEach(ZeichnungText.massstaebe, id: \.self) { m in
                        Button(m) { bearbeite([.massstab(m)], z) }
                            .disabled(m == z.blatt.massstab)
                    }
                }
                .fixedSize()
            }
            .help(z.blatt.autoMassstab ? "SK-CAD wählt den größten Maßstab der ISO-Reihe, der passt"
                  : "von dir gesetzt (ISO 5455)")
            if z.blatt.autoFormat || z.blatt.autoMassstab {
                Text([z.blatt.autoFormat ? "Format" : nil, z.blatt.autoMassstab ? "Maßstab" : nil].compactMap { $0 }
                        .joined(separator: " und ") + " wählt SK-CAD automatisch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Ansichten automatisch", isOn: Binding(
                get: { z.blatt.autoAnsichten }, set: { bearbeite([.auto(ansichten: $0, masse: nil, zuruecksetzen: nil)], z) }))
            Toggle("Maße automatisch", isOn: Binding(
                get: { z.blatt.autoMasse }, set: { bearbeite([.auto(ansichten: nil, masse: $0, zuruecksetzen: nil)], z) }))
        }
    }

    // MARK: Auswahl

    @ViewBuilder
    private func auswahlAbschnitt(_ z: Zeichnung) -> some View {
        switch zustand.element {
        case .mass(let id)?:
            if let m = z.mass(id) {
                MassAbschnitt(z: z, m: m, b: z.blatt.mass(id), zustand: zustand) { ops, titel in bearbeite(ops, z, titel: titel) }
            }
        case .ansicht(let id)?:
            if let g = z.gruppe(id) {
                Section("Ansicht") {
                    LabeledContent("Art", value: ZeichnungText.ansichtArt(g.art))
                    LabeledContent("Maßstab", value: g.massstab ?? z.blatt.massstab)
                    LabeledContent("Maße", value: KevFormat.integer(z.masse.filter { $0.ansicht == id }.count))
                    if z.blatt.ansicht(id)?.fest == true {
                        LabeledContent("Lage", value: "von dir gesetzt")
                    }
                    if g.art == "schnitt" {
                        Button {
                            bearbeite([.schnittUmkehren(id: id)], z)
                        } label: {
                            Label("Blickrichtung umkehren", systemImage: "arrow.left.arrow.right")
                        }
                        .help("Der Schnitt zeigt dann die andere Hälfte; die Pfeile am Schnittverlauf drehen sich mit")
                    }
                    Button("Ansicht löschen …", role: .destructive) { zustand.ansichtLoeschen = id }
                }
            }
        case .notiz(let id)?:
            if let n = z.blatt.notizen.first(where: { $0.id == id }) {
                NotizAbschnitt(n: n) { ops in bearbeite(ops, z, titel: "Notiz ändern") }
            }
        case nil:
            Section("Auswahl") {
                Text("Maß, Ansicht oder Notiz auf dem Blatt anklicken. Maße ziehen, Maßzahl verschieben, mit ⌫ löschen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Prüfung und verwaiste Maße

    @ViewBuilder
    private func pruefAbschnitt(_ z: Zeichnung) -> some View {
        let verwaist = z.verwaisteMasse
        if !z.pruefung.isEmpty || !verwaist.isEmpty || !z.hinweise.isEmpty {
            Section("Prüfung") {
                ForEach(Array(verwaist.enumerated()), id: \.offset) { _, m in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Verwaist: \(m.text.isEmpty ? ZeichnungText.massArt(m.art) : m.text)")
                            Text("Bezug nach einer Modelländerung nicht gefunden. Löschen oder neu setzen.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Zeigen") { zustand.element = .mass(m.id) }.controlSize(.small)
                        Button("Löschen") { bearbeite([.massLoeschen(id: m.id)], z) }.controlSize(.small)
                    }
                }
                ForEach(Array(z.pruefung.enumerated()), id: \.offset) { _, b in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: b.schwere == "fehler" ? "xmark.octagon.fill"
                              : b.schwere == "warnung" ? "exclamationmark.triangle.fill" : "info.circle")
                            .foregroundStyle(b.schwere == "fehler" ? Color.red : b.schwere == "warnung" ? Color.orange
                                             : Color.secondary)
                        Text(b.text).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if let m = b.masse.first, z.mass(m) != nil {
                            Button("Zeigen") { zustand.element = .mass(m) }.controlSize(.small)
                        }
                    }
                }
                ForEach(z.hinweise, id: \.self) { h in
                    Label(h, systemImage: "info.circle").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func ausgeblendetAbschnitt(_ z: Zeichnung) -> some View {
        if !z.blatt.unterdrueckt.isEmpty {
            Section {
                ForEach(Array(z.blatt.unterdrueckt.enumerated()), id: \.offset) { i, u in
                    HStack {
                        Text(u.beschreibung).lineLimit(2)
                        Spacer()
                        Button("Wiederherstellen") { bearbeite([.unterdrueckungAufheben(index: i)], z) }
                            .controlSize(.small)
                    }
                }
            } header: {
                HStack {
                    Text("Ausgeblendete automatische Maße")
                    Spacer()
                    Button("Alle") {
                        bearbeite([.auto(ansichten: nil, masse: true, zuruecksetzen: true)], z,
                                  titel: "Automatische Maße zurücksetzen")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Alle ausgeblendeten Maße wiederherstellen und die automatischen Maße neu setzen")
                }
            }
        }
    }

    @ViewBuilder
    private func allgemeinAbschnitt(_ z: Zeichnung) -> some View {
        if !z.blatt.allgemein.isEmpty {
            Section("Allgemeine Angaben") {
                ForEach(z.blatt.allgemein, id: \.self) { Text($0).font(.callout) }
            }
        }
    }
}

/// Ein ausgewähltes Maß: Werte, Text und Toleranz, Lage, Löschen.
private struct MassAbschnitt: View {
    let z: Zeichnung
    let m: MassDarstellung
    let b: BlattMassEintrag?
    @ObservedObject var zustand: DokumenteZustand
    let bearbeite: ([ZeichnungsOp], String?) -> Void
    @State private var text = ""
    @State private var toleranz = ""

    var body: some View {
        Section {
            LabeledContent("Art", value: ZeichnungText.massArt(m.art))
            if let w = m.wert {
                LabeledContent("Messwert", value: MassVorschau.zahl(w) + (m.einheit == "°" ? "°" : " mm"))
            }
            LabeledContent("Herkunft", value: ZeichnungText.quelle(m.quelle))
            if m.verwaist {
                Label("Verwaist: Bezug nicht mehr gefunden", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            TextField("Text", text: $text, prompt: Text("<> = Messwert"))
                .onSubmit(uebernehmen)
            TextField("Toleranz", text: $toleranz, prompt: Text("z. B. ±0,1 oder H7"))
                .onSubmit(uebernehmen)
            HStack {
                if b?.fest == true && m.quelle == "auto" {
                    Button("Automatisch platzieren") {
                        bearbeite([.massAendern(id: m.id, text: nil, toleranz: nil, fest: false)], "Automatisch platzieren")
                    }
                }
                Spacer()
                Button(m.quelle == "auto" ? "Ausblenden" : "Löschen", role: .destructive) {
                    bearbeite([.massLoeschen(id: m.id)], nil)
                    zustand.element = nil
                }
            }
            .controlSize(.small)
        } header: {
            Text("Maß \(m.text)")
        } footer: {
            if m.quelle == "auto" {
                Text("Automatische Maße kommen nach dem Ausblenden nicht wieder; unten wiederherstellen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: laden)
        .onChange(of: m.id) { _, _ in laden() }
        .onChange(of: b?.text) { _, _ in laden() }
    }

    private func laden() {
        text = b?.text ?? ""
        toleranz = b?.toleranz ?? ""
    }

    private func uebernehmen() {
        guard text != (b?.text ?? "") || toleranz != (b?.toleranz ?? "") else { return }
        bearbeite([.massAendern(id: m.id, text: text, toleranz: toleranz, fest: nil)], "Maßtext ändern")
    }
}

/// Ausgewählte Notiz: Text ändern (löschen und neu anlegen, Lage und Zeiger bleiben), löschen.
private struct NotizAbschnitt: View {
    let n: BlattNotiz
    let bearbeite: ([ZeichnungsOp]) -> Void
    @State private var text = ""

    var body: some View {
        Section("Notiz") {
            TextField("Text", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .onSubmit(uebernehmen)
            LabeledContent("Herkunft", value: ZeichnungText.quelle(n.quelle))
            LabeledContent("Zeiger", value: n.zeiger == nil ? "ohne" : "auf Geometrie")
            HStack {
                Spacer()
                Button("Notiz löschen", role: .destructive) { bearbeite([.notizLoeschen(id: n.id)]) }
            }
            .controlSize(.small)
        }
        .onAppear { text = n.text }
        .onChange(of: n.id) { _, _ in text = n.text }
    }

    private func uebernehmen() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != n.text else { return }
        bearbeite([.notizLoeschen(id: n.id), .notiz(text: t, lage: n.lage, zeiger: BlattLeinwand.zeiger(n))])
    }
}

/// Schriftfeld nach ISO 7200: Felder bearbeiten, Kevins Werte bleiben (Kev CAD überschreibt sie nicht mehr).
private struct SchriftfeldAbschnitt: View {
    let z: Zeichnung
    let bearbeite: ([ZeichnungsOp]) -> Void
    @State private var werte: [String: String] = [:]

    static let felder: [(feld: String, titel: String)] = [
        ("benennung", "Benennung"), ("zeichnungsnummer", "Sachnummer"), ("werkstoff", "Werkstoff"),
        ("halbzeug", "Halbzeug"), ("allgemeintoleranz", "Allgemeintoleranz"), ("stueckzahl", "Stückzahl"),
        ("dokumentart", "Dokumentart"), ("freigegeben", "Freigegeben"), ("gezeichnet", "Erstellt"),
        ("datum", "Ausgabedatum"), ("notiz", "Bemerkung"),
    ]

    var body: some View {
        Section {
            ForEach(Self.felder, id: \.feld) { f in
                TextField(f.titel, text: Binding(
                    get: { werte[f.feld] ?? z.blatt.schriftfeldText(f.feld) },
                    set: { werte[f.feld] = $0 }))
                    .onSubmit { uebernehmen(f.feld) }
            }
        } header: {
            Text("Schriftfeld")
        } footer: {
            Text("Mit ⏎ übernehmen. Was du hier setzt, überschreibt SK-CAD nicht mehr.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: z.stand) { _, _ in werte = [:] }
    }

    private func uebernehmen(_ feld: String) {
        guard let t = werte[feld], t != z.blatt.schriftfeldText(feld) else { return }
        bearbeite([.schriftfeld(feld: feld, wert: BlattLeinwand.schriftfeldWert(feld, t))])
    }
}
