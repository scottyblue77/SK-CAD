import KevCADCore
import SwiftUI

/// Inspektor im Bereich Dokumente, solange der Bauplan vorne ist: die Einzelheiten des gewählten Schritts (Teile,
/// Verbindungsmittel, Werkzeug, Hinweise, Prüfung) und alles zum Bearbeiten; ohne Schritt der Überblick über den Plan.
/// Bearbeiten geht wie in der Liste als BAUPLAN_EDIT an den Kernel (`von: "kevin"`).
struct BauplanInspektor: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: BauplanStore
    @ObservedObject private var ui = BauplanUI.shared

    init(model: AppModel) {
        self.model = model
        self.store = model.bauplan
    }

    private var actions: BauplanActions? { model.bauplanActions }

    var body: some View {
        if let plan = store.plan {
            if let id = ui.auswahl, let s = plan.schritt(id) {
                schritt(plan, s)
            } else {
                ueberblick(plan)
            }
        } else {
            ContentUnavailableView {
                Label(store.laedt ? "Bauplan wird erzeugt" : "Noch kein Bauplan", systemImage: "hammer")
            } description: {
                Text("Die Einzelheiten des gewählten Schritts erscheinen hier: Teile, Werkzeug, Hinweise und Bearbeiten.")
            }
        }
    }

    // MARK: Überblick

    private func ueberblick(_ plan: Bauplan) -> some View {
        Form {
            Section("Bauplan") {
                LabeledContent("Schritte") { Text("\(plan.alleSchritte.count)").monospacedDigit() }
                ForEach(plan.abschnitte.filter { !$0.schritte.isEmpty }) { a in
                    LabeledContent(a.titel) {
                        Text(spanne(plan, a)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                let probleme = plan.alleSchritte.flatMap(\.probleme)
                LabeledContent("Simulation") {
                    if probleme.isEmpty {
                        Label("ohne Probleme", systemImage: "checkmark.seal").foregroundStyle(.green)
                    } else {
                        Label(KevFormat.count(probleme.count, one: "Problem", many: "Probleme"),
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            Section("Werkzeug") {
                ForEach(plan.alleWerkzeuge, id: \.self) { w in
                    Label(w, systemImage: BauplanWerkzeug.symbol(w))
                }
            }
            Section {
                Button {
                    actions?.durchspielenStarten(ab: nil)
                } label: {
                    Label("Durchspielen", systemImage: "play.circle")
                }
                .disabled(plan.montage?.schritte.isEmpty ?? true)
                Button {
                    actions?.bauplanPruefen(schritt: nil)
                } label: {
                    Label("Alle Schritte prüfen", systemImage: "checkmark.shield")
                }
            } footer: {
                Text("Einen Schritt in der Liste wählen, um Teile, Werkzeug und Hinweise zu sehen und ihn zu bearbeiten.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func spanne(_ plan: Bauplan, _ a: BauplanAbschnitt) -> String {
        let von = a.schritte.first.flatMap { plan.nummer($0.id) } ?? 0
        let bis = a.schritte.last.flatMap { plan.nummer($0.id) } ?? 0
        return von == bis ? "Schritt \(von)" : "Schritte \(von)–\(bis)"
    }

    // MARK: Schritt

    private func schritt(_ plan: Bauplan, _ s: BauplanSchritt) -> some View {
        let abschnitt = plan.abschnitt(von: s.id)
        return Form {
            Section {
                HStack(spacing: 10) {
                    BauplanNummer(nummer: plan.nummer(s.id) ?? 0, groesse: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.titel).font(.headline).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        Text([abschnitt?.titel, s.baugruppe.map { "Vormontage \($0)" }].compactMap { $0 }
                                .joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if s.anzahl > 1 { BauplanMengenMarke(anzahl: s.anzahl) }
                }
                LabeledContent("Text von") { Text(quelle(s.quelle)).lineLimit(1).truncationMode(.middle) }
                Toggle("Fest", isOn: Binding(
                    get: { s.fest },
                    set: { an in
                        actions?.bauplanBearbeiten([BauplanOp.fest(schritt: s.id, an)],
                                                   titel: an ? "Schritt fest" : "Schritt gelöst")
                    }))
                    .help("Fest: Schritt und Text bleiben bei neuen Läufen, wie sie sind")
            }
            teileAbschnitt(s)
            if !s.verbindungsmittel.isEmpty {
                Section("Verbindungsmittel") {
                    ForEach(Array(s.verbindungsmittel.enumerated()), id: \.offset) { _, v in
                        LabeledContent {
                            Text("\(v.anzahl) ×").monospacedDigit()
                        } label: {
                            Text(v.benennung + (v.geschaetzt ? " (geschätzt)" : "")).lineLimit(2)
                        }
                    }
                }
            }
            if !s.werkzeug.isEmpty {
                Section("Werkzeug") {
                    ForEach(s.werkzeug, id: \.self) { w in
                        Label(w, systemImage: BauplanWerkzeug.symbol(w))
                    }
                }
            }
            if !s.hinweise.isEmpty {
                Section("Hinweise") {
                    ForEach(s.sicherheitsHinweise, id: \.self) { h in
                        Label(h, systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(s.uebrigeHinweise, id: \.self) { h in
                        Text(h).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !s.pruefung.isEmpty {
                Section("Prüfung") {
                    ForEach(s.pruefung) { b in
                        Button {
                            actions?.bauplanZeigen(teile: b.teile, ort: b.ort)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Label(b.text, systemImage: b.schwere.symbol)
                                    .foregroundStyle(b.schwere.farbe)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let l = b.loesung {
                                    Text(l).font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Im 3D-Bereich zeigen")
                    }
                }
            }
            bearbeitenAbschnitt(plan, s, abschnitt)
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func teileAbschnitt(_ s: BauplanSchritt) -> some View {
        let gruppen = s.neueTeileGruppiert
        let bestand = s.neu.isEmpty ? s.teile : s.teile.filter { !s.neu.contains($0) }
        if !gruppen.isEmpty || !bestand.isEmpty {
            Section {
                ForEach(gruppen, id: \.name) { g in
                    LabeledContent {
                        Text("\(g.anzahl) ×").monospacedDigit().foregroundStyle(Color.kevAkzent)
                    } label: {
                        Text(g.name).lineLimit(2)
                    }
                }
                ForEach(gruppiert(bestand), id: \.name) { g in
                    LabeledContent {
                        Text("\(g.anzahl) ×").monospacedDigit().foregroundStyle(.secondary)
                    } label: {
                        Text(g.name).lineLimit(2).foregroundStyle(.secondary)
                    }
                }
            } header: {
                HStack {
                    Text(s.neu.isEmpty ? "Teile" : "Teile (neu orange)")
                    Spacer()
                    Button("Im 3D zeigen") { actions?.bauplanZeigen(teile: s.neu.isEmpty ? s.teile : s.neu, ort: nil) }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .disabled(s.teile.isEmpty)
                }
            }
        }
    }

    private func gruppiert(_ teile: [String]) -> [(name: String, anzahl: Int)] {
        var reihenfolge: [String] = []
        var zaehler: [String: Int] = [:]
        for t in teile {
            let k = BauplanText.ohneNummer(BauplanSchritt.kurzname(t))
            if zaehler[k] == nil { reihenfolge.append(k) }
            zaehler[k, default: 0] += 1
        }
        return reihenfolge.map { ($0, zaehler[$0] ?? 1) }
    }

    private func bearbeitenAbschnitt(_ plan: Bauplan, _ s: BauplanSchritt, _ a: BauplanAbschnitt?) -> some View {
        Section("Bearbeiten") {
            Button { ui.bearbeiten = s } label: { Label("Text bearbeiten …", systemImage: "pencil") }
            if let a, let i = a.schritte.firstIndex(of: s) {
                Button {
                    actions?.bauplanBearbeiten(
                        [BauplanOp.verschieben(schritt: s.id, nach: i >= 2 ? a.schritte[i - 2].id : nil)],
                        titel: "Schritt verschoben")
                } label: { Label("Nach oben", systemImage: "arrow.up") }
                    .disabled(i == 0)
                Button {
                    actions?.bauplanBearbeiten([BauplanOp.verschieben(schritt: s.id, nach: a.schritte[i + 1].id)],
                                               titel: "Schritt verschoben")
                } label: { Label("Nach unten", systemImage: "arrow.down") }
                    .disabled(i + 1 >= a.schritte.count)
                Button {
                    actions?.bauplanBearbeiten([BauplanOp.zusammenfassen([s.id, a.schritte[i + 1].id])],
                                               titel: "Schritte zusammengefasst")
                } label: { Label("Mit nächstem zusammenfassen", systemImage: "arrow.triangle.merge") }
                    .disabled(i + 1 >= a.schritte.count)
            }
            Button { ui.teilen = s } label: { Label("Teilen …", systemImage: "square.split.2x1") }
                .disabled(s.neu.count < 2)
            Button { ui.regel = s } label: { Label("Reihenfolge eintragen …", systemImage: "arrow.right.to.line") }
            Button {
                actions?.bauplanPruefen(schritt: s.id)
            } label: { Label("Schritt prüfen", systemImage: "checkmark.shield") }
            if a?.art == .montage {
                Button {
                    actions?.durchspielenStarten(ab: s.id)
                } label: { Label("Ab hier durchspielen", systemImage: "play.circle") }
            }
        }
    }

    private func quelle(_ q: String) -> String {
        switch q {
        case "kevin": return AppInfo.nutzerName
        case "agent": return "Agent"
        default: return "SK-CAD"
        }
    }
}
