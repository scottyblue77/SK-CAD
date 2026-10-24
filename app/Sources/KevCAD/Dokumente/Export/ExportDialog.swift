import KevCADCore
import SwiftUI
import UniformTypeIdentifiers

/// Dialog „Dokumente exportieren …“ (DOKUMENTE.md „App“, Strang P6-A2): Bausteine ankreuzen und ordnen, Spalten der
/// Tabellen, Auswahl der Zeichnungen, Papier, Vorlagen sichern; dann PDF sichern oder drucken. Rechts eine Vorschau der
/// ersten Seiten mit Seitenzahl und Formaten.
struct ExportDialog: View {
    @ObservedObject var model: AppModel
    @ObservedObject var export: ExportStore
    @ObservedObject var dokumente: DokumenteStore
    let schliessen: () -> Void

    @State private var vorlage: ExportVorlage
    @State private var auswahl: ExportBausteinArt? = .deckblatt
    @State private var vorschau: ExportDokument?
    @State private var vorschauLaeuft = false
    @State private var vorlagenName = ""
    @State private var namenFrage = false
    @State private var ergebnis: ExportErgebnis?
    @State private var fehler: String?
    @State private var aktiv = false

    init(model: AppModel, vorauswahl: [ExportBausteinArt]? = nil, schliessen: @escaping () -> Void) {
        self.model = model
        self.export = model.export
        self.dokumente = model.dokumente
        self.schliessen = schliessen
        var v = model.export.vorlagen.zuletzt.flatMap { model.export.vorlagen.vorlage($0) } ?? .standard
        if let vor = vorauswahl, !vor.isEmpty {
            v = ExportVorlage(name: "Auswahl", format: v.format, ausrichtung: v.ausrichtung,
                              bausteine: vor.map { ExportBausteinWahl(art: $0) }).vollstaendig
        }
        _vorlage = State(initialValue: v.vollstaendig)
        _auswahl = State(initialValue: vorauswahl?.first ?? .deckblatt)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                bausteinListe.frame(width: 300)
                Divider()
                optionen.frame(width: 300)
                Divider()
                vorschauSpalte.frame(minWidth: 280)
            }
            Divider()
            fussLeiste
        }
        .frame(width: 1000, height: 640)
        .task(id: vorschauSchluessel) {
            try? await Task.sleep(for: .milliseconds(350))
            await vorschauBauen()
        }
        .alert("Name der Vorlage", isPresented: $namenFrage) {
            TextField("z. B. Werkstatt", text: $vorlagenName)
            Button("Sichern") { vorlageSichern() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die Vorlage liegt im Projekt unter dokumente/vorlagen.json.")
        }
    }

    private var vorschauSchluessel: String {
        let b = vorlage.bausteine.map { "\($0.art.rawValue):\($0.an):\(($0.spalten ?? []).joined(separator: ",")):\(($0.auswahl ?? []).joined(separator: ","))" }
        return b.joined(separator: "|") + "|\(vorlage.seitenformat.name)|\(model.bom?.run ?? 0)"
    }

    // MARK: Bausteine

    private var bausteinListe: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Bausteine")
                .font(.headline)
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
            Text("Ankreuzen und in die gewünschte Reihenfolge ziehen.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.bottom, 6)
            List(selection: $auswahl) {
                ForEach($vorlage.bausteine) { $b in
                    HStack(spacing: 10) {
                        Toggle("", isOn: $b.an).labelsHidden().toggleStyle(.checkbox)
                        Image(systemName: b.art.symbol)
                            .frame(width: 20)
                            .foregroundStyle(b.an ? Color.kevAkzent : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(b.art.titel).fontWeight(b.an ? .medium : .regular)
                            Text(zusatz(b)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let n = vorschau?.bausteinSeiten.first(where: { $0.art == b.art })?.anzahl, b.an {
                            Text("\(n) S.").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .opacity(b.an ? 1 : 0.6)
                    .tag(b.art)
                    .padding(.vertical, 3)
                }
                .onMove { vorlage.bausteine.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.inset)
        }
    }

    private func zusatz(_ b: ExportBausteinWahl) -> String {
        switch b.art {
        case .zeichnungen:
            let n = dokumente.uebersicht?.blaetter.count ?? 0
            if let a = b.auswahl, !a.isEmpty { return "\(a.count) von \(n) Blättern" }
            return n == 0 ? "alle Blätter (noch keine gerechnet)" : "alle \(n) Blätter, eigenes Format"
        case .stueckliste, .teileliste, .einkaufsliste, .zuschnitt:
            return "\(b.wirksameSpalten.count) Spalten"
        case .druck:  // Druckvorschau (DRUCKVORSCHAU.md)
            guard let d = model.druck.vorschau, !d.istLeer else { return "keine Druckteile im Modell" }
            return KevFormat.count(d.summe.platten, one: "Platte", many: "Platten") + ", "
                + KevFormat.count(d.stueck, one: "Teil", many: "Teile") + ", \(b.wirksameSpalten.count) Spalten"
        case .bauplan:
            if let p = model.bauplan.plan { return KevFormat.count(p.alleSchritte.count, one: "Schritt", many: "Schritte") }
            return "wird bei Bedarf erzeugt"
        case .deckblatt:
            return "Titel, Ansicht, Kennzahlen, Inhalt"
        case .produktbild:  // Phase 7: jüngstes Rendering oder schnell im Studio
            return "Rendering, Studio aus der Produktansicht"
        }
    }

    // MARK: Optionen

    private var optionen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                papier
                Divider()
                if let a = auswahl, let i = vorlage.bausteine.firstIndex(where: { $0.art == a }) {
                    bausteinOptionen(i)
                }
            }
            .padding(16)
        }
    }

    private var papier: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Papier").font(.headline)
            Picker("Format", selection: $vorlage.format) {
                ForEach(ExportPapier.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Ausrichtung", selection: $vorlage.ausrichtung) {
                ForEach(ExportAusrichtung.allCases, id: \.self) { Text($0.titel).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("Gilt für Deckblatt, Listen und Bauplan. Zeichnungen behalten ihr eigenes Blattformat.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func bausteinOptionen(_ i: Int) -> some View {
        let b = vorlage.bausteine[i]
        VStack(alignment: .leading, spacing: 10) {
            Label(b.art.titel, systemImage: b.art.symbol).font(.headline)
            Text(b.art.beschreibung).font(.callout).foregroundStyle(.secondary)
            if !b.art.spalten.isEmpty { spaltenWahl(i) }
            if b.art == .zeichnungen { blattWahl(i) }
            if b.art == .bauplan, model.bauplan.plan == nil {
                Label("Der Bauplan wird beim Export erzeugt, das dauert beim ersten Mal einige Sekunden.",
                      systemImage: "clock")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func spaltenWahl(_ i: Int) -> some View {
        let art = vorlage.bausteine[i].art
        let aktiv = vorlage.bausteine[i].wirksameSpalten.map(\.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Spalten").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Vorgabe") { vorlage.bausteine[i].spalten = nil }
                    .buttonStyle(.link)
                    .disabled(vorlage.bausteine[i].spalten == nil)
            }
            ForEach(art.spalten) { s in
                Toggle(isOn: Binding(
                    get: { aktiv.contains(s.id) },
                    set: { an in
                        var ids = aktiv
                        if an {
                            // in der Reihenfolge der Spaltenliste einsortieren
                            ids.append(s.id)
                            let reihenfolge = art.spalten.map(\.id)
                            ids.sort { (reihenfolge.firstIndex(of: $0) ?? 0) < (reihenfolge.firstIndex(of: $1) ?? 0) }
                        } else {
                            ids.removeAll { $0 == s.id }
                        }
                        vorlage.bausteine[i].spalten = ids.isEmpty ? nil : ids
                    })) {
                    Text(s.titel.isEmpty ? (s.id == "abhaken" ? "Abhaken (Kästchen)" : s.id) : s.titel)
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private func blattWahl(_ i: Int) -> some View {
        let blaetter = dokumente.uebersicht?.blaetter ?? []
        let auswahl = vorlage.bausteine[i].auswahl
        return VStack(alignment: .leading, spacing: 6) {
            Toggle("Alle Blätter", isOn: Binding(
                get: { auswahl == nil || auswahl?.isEmpty == true },
                set: { alle in vorlage.bausteine[i].auswahl = alle ? nil : blaetter.map(\.id) }))
                .toggleStyle(.checkbox)
            if blaetter.isEmpty {
                Text(dokumente.uebersichtLaedt ? "Blätter werden gerechnet …"
                     : "Noch keine Blätter. Beim Export werden die Zeichnungen gerechnet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(blaetter) { blatt in
                Toggle(isOn: Binding(
                    get: { auswahl == nil || auswahl!.isEmpty || auswahl!.contains(blatt.id) },
                    set: { an in
                        var ids = (auswahl?.isEmpty == false ? auswahl! : blaetter.map(\.id))
                        if an { if !ids.contains(blatt.id) { ids.append(blatt.id) } } else { ids.removeAll { $0 == blatt.id } }
                        let reihenfolge = blaetter.map(\.id)
                        ids.sort { (reihenfolge.firstIndex(of: $0) ?? 0) < (reihenfolge.firstIndex(of: $1) ?? 0) }
                        vorlage.bausteine[i].auswahl = ids.count == blaetter.count ? nil : ids
                    })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(blatt.titel)
                        Text([blatt.format, blatt.ausrichtung, blatt.massstab].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(auswahl == nil || auswahl!.isEmpty)
            }
        }
        .onAppear {
            if dokumente.uebersicht == nil, !dokumente.uebersichtLaedt { model.dokumenteActions?.dokumenteAnfordern() }
        }
    }

    // MARK: Vorschau

    private var vorschauSpalte: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Vorschau").font(.headline)
                Spacer()
                if vorschauLaeuft { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            if let d = vorschau, !d.seiten.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(KevFormat.count(d.seiten.count, one: "Seite", many: "Seiten"))
                        .font(.title2.weight(.semibold)).monospacedDigit()
                    Text(d.formate.sorted { $0.value > $1.value }.map { "\($0.key): \($0.value)" }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    if d.formate.count > 1 {
                        Label("Gemischte Formate: beim Drucken ein Auftrag je Format, jeweils 1:1.", systemImage: "printer")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(d.hinweise, id: \.self) { h in
                        Label(h, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 12) {
                        ForEach(d.seiten.indices, id: \.self) { i in
                            let s = d.seiten[i]
                            let k: CGFloat = 110 / max(s.groesse.width, s.groesse.height)
                            VStack(spacing: 3) {
                                SeiteAnsicht(dokument: d, index: i)
                                    .frame(width: s.groesse.width * k, height: s.groesse.height * k)
                                    .background(Color.white)
                                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                                Text("\(i + 1)").font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(height: 130)
                        }
                    }
                    .padding(16)
                }
                .background(Color(nsColor: .underPageBackgroundColor))
            } else {
                ContentUnavailableView(vorschauLaeuft ? "Seiten werden gesetzt …" : "Keine Seiten",
                                       systemImage: "doc.on.doc")
            }
        }
    }

    private func vorschauBauen() async {
        guard let a = model.exportActions else { return }
        vorschauLaeuft = true
        vorschau = await a.exportDokument(vorlage)
        vorschauLaeuft = false
    }

    // MARK: Fuß

    private var fussLeiste: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Alles (Vorgabe)") { vorlage = ExportVorlage.standard }
                if !export.vorlagen.vorlagen.isEmpty {
                    Divider()
                    ForEach(export.vorlagen.vorlagen) { v in
                        Button(v.name) { vorlage = v.vollstaendig }
                    }
                }
                Divider()
                Button("Als Vorlage sichern …") {
                    vorlagenName = vorlage.name == "Alles" || vorlage.name == "Auswahl" ? "" : vorlage.name
                    namenFrage = true
                }
                if export.vorlagen.vorlage(vorlage.name) != nil {
                    Button("Vorlage „\(vorlage.name)“ löschen", role: .destructive) {
                        try? model.exportActions?.exportVorlageLoeschen(vorlage.name)
                    }
                }
            } label: {
                Label("Vorlage: \(vorlage.name)", systemImage: "square.stack")
            }
            .fixedSize()
            if let l = export.laeuft, aktiv {
                ProgressView().controlSize(.small)
                Text(l).foregroundStyle(.secondary).lineLimit(1)
            } else if let e = ergebnis {
                Label("\(KevFormat.count(e.seiten, one: "Seite", many: "Seiten")) in \(KevFormat.number(Double(e.ms) / 1000, digits: 1)) s"
                      + (e.gedruckt.map { " · \($0)" } ?? ""), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if let p = e.pfad {
                    Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([p]) }
                        .buttonStyle(.link)
                    Button("Öffnen") { NSWorkspace.shared.open(p) }
                        .buttonStyle(.link)
                }
            } else if let f = fehler {
                Label(f, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
            }
            Spacer()
            Button("Schließen", role: .cancel) { schliessen() }
                .keyboardShortcut(.cancelAction)
            Button {
                drucken()
            } label: {
                Label("Drucken …", systemImage: "printer")
            }
            .disabled(vorlage.aktive.isEmpty || aktiv)
            Button {
                sichern()
            } label: {
                Label("PDF sichern …", systemImage: "arrow.down.doc")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(vorlage.aktive.isEmpty || aktiv)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func vorlageSichern() {
        let name = vorlagenName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var v = vorlage
        v.name = name
        do {
            try model.exportActions?.exportVorlageSpeichern(v)
            vorlage = v
        } catch {
            fehler = "Vorlage nicht gesichert: \(error.localizedDescription)"
        }
    }

    private func sichern() {
        Task { @MainActor in
            guard let url = await ExportDialogFenster.speicherOrt(model: model, name: "\(model.project?.name ?? "SK-CAD") – Dokumente")
            else { return }
            aktiv = true
            fehler = nil
            defer { aktiv = false }
            do {
                ergebnis = try await model.exportActions?.exportPDF(vorlage, nach: url)
            } catch {
                fehler = (error as? ExportFehler)?.description ?? error.localizedDescription
            }
        }
    }

    private func drucken() {
        Task { @MainActor in
            aktiv = true
            fehler = nil
            defer { aktiv = false }
            do {
                ergebnis = try await model.exportActions?.exportDrucken(vorlage)
            } catch {
                fehler = (error as? ExportFehler)?.description ?? error.localizedDescription
            }
        }
    }
}
