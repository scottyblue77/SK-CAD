import KevCADCore
import SwiftUI

/// Dialog „Drucken …“ und Drucker-Einstellungen am Projektfenster (ein Platz für beide, egal von wo sie kommen:
/// Druckerleiste, Frage des Agenten über MCP `drucken`, Selbsttest).
struct DruckerDialoge: ViewModifier {
    @ObservedObject var model: AppModel
    @ObservedObject private var drucker: DruckerStore
    @ObservedObject private var ui = DruckerUI.shared

    init(model: AppModel) {
        self.model = model
        _drucker = ObservedObject(wrappedValue: model.drucker)
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: dialogBindung) { _ in DruckenDialog(model: model) }
            .sheet(isPresented: $ui.einstellungenOffen) { DruckerEinstellungen(model: model) }
    }

    private var dialogBindung: Binding<DruckDialogZustand?> {
        Binding(get: { drucker.dialog }, set: { neu in
            if neu == nil, drucker.dialog != nil { model.druckerActions?.druckDialogSchliessen() }
        })
    }
}

/// Dialog „Drucken …“ (Phase 8): Platten, Filament je Material bzw. Farbe, Zeit, Weg. Kevin bestätigt hier; vorher
/// geschieht am Drucker nichts. Weg A slict fertig und öffnet die Datei in Bambu Studio (dort „Platte drucken“ und
/// „Senden“). Weg B ist ausgegraut, solange der Kernel den Developer Mode nicht nachgewiesen hat, mit Grund und
/// Anleitung. Strang „Rest Druck“: das Filament wählt Kevin hier aus seiner Liste (wie im Sichern-Dialog), vorbelegt
/// mit dem zuletzt für das Projekt gewählten; das Preset steht darunter. Ohne Wahl geht kein Druck los.
struct DruckenDialog: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var drucker: DruckerStore
    @ObservedObject private var druck: DruckStore
    @State private var anleitungOffen = false

    init(model: AppModel) {
        self.model = model
        _drucker = ObservedObject(wrappedValue: model.drucker)
        _druck = ObservedObject(wrappedValue: model.druck)
    }

    private var status: DruckerStatus { drucker.status ?? DruckerStatus() }
    private var platten: [DruckPlatte] { druck.vorschau?.platten ?? [] }

    var body: some View {
        if let d = drucker.dialog {
            VStack(alignment: .leading, spacing: 14) {
                kopf(d)
                Divider()
                plattenAbschnitt(d)
                materialAbschnitt(d)
                wegAbschnitt(d)
                Divider()
                phase(d)
                knoepfe(d)
            }
            .padding(20)
            .frame(width: 560)
        }
    }

    // MARK: Abschnitte

    private func kopf(_ d: DruckDialogZustand) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Drucken", systemImage: "printer.fill").font(.title2.weight(.semibold))
            if let f = d.frage {
                Text("Claude fragt: \(f.grund ?? "Soll gedruckt werden?")")
                    .font(.callout)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.kevAkzent.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                Text("Es geschieht nichts, bis du hier bestätigst.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(drucker.aktiver.map { "\($0.name) (Bambu Lab P1P, 0,4-mm-Düse)" } ?? "Bambu Lab P1P, 0,4-mm-Düse")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func plattenAbschnitt(_ d: DruckDialogZustand) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Platten").font(.headline)
            if platten.isEmpty {
                Text("Ohne Druckvorschau: alle Druckteile, je Material eine Platte; Bambu Studio richtet sie aus und "
                     + "ordnet sie an.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(platten) { p in
                    Toggle(isOn: Binding(get: { gewaehlt(p.nr, d) }, set: { setze(p.nr, $0, d) })) {
                        HStack(spacing: 10) {
                            Text("Platte \(p.nr)").monospacedDigit().frame(width: 62, alignment: .leading)
                            Text(materialText(p)).lineLimit(1).frame(width: 110, alignment: .leading)
                            Text(DruckFormat.zeit(p.zeitS)).monospacedDigit().frame(width: 84, alignment: .trailing)
                            Text(DruckFormat.gramm(p.gramm)).monospacedDigit().frame(width: 64, alignment: .trailing)
                            Text(KevFormat.count(p.teile.count, one: "Teil", many: "Teile")).foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(gesperrt(d))
                }
                Text(summenText(d)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func materialAbschnitt(_ d: DruckDialogZustand) -> some View {
        if let v = druck.vorschau, !v.platten.isEmpty {
            let klassen = v.klassen(platten: d.platten)
            VStack(alignment: .leading, spacing: 8) {
                Text("Filament im Drucker").font(.headline)
                ForEach(klassen, id: \.self) { k in filamentZeile(k, v, d) }
                Text("Externe Spule (P1P ohne AMS). Das Preset des gewählten Filaments kommt in die Datei.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            let mats = materialien(d)
            if !mats.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Material und Spule").font(.headline)
                    ForEach(mats, id: \.material) { m in
                        Text("\(m.name): externe Spule" + (m.filament.map { " – Profil „\($0)“" } ?? ""))
                            .font(.callout)
                    }
                }
            }
        }
    }

    /// Eine Klasse („PETG“ bzw. „PETG gelb“): Auswahl aus Kevins Filamentliste, darunter Preset und Basisprofil.
    private func filamentZeile(_ k: String, _ v: Druckvorschau, _ d: DruckDialogZustand) -> some View {
        let liste = v.filamente(fuerKlasse: k)
        let gewaehlt = d.filament[k]
        let f = liste.first { $0.id == gewaehlt }
        let farbe = Druckvorschau.farbe(vonKlasse: k)
            ?? v.platten.first(where: { $0.klasse == k })?.farbe.flatMap { Druckvorschau.farbeSchluessel($0) }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("\(v.klassenTitel(k)):").frame(width: 120, alignment: .leading)
                Picker("Filament \(v.klassenTitel(k))", selection: Binding(
                    get: { gewaehlt ?? "" },
                    set: { model.druckerActions?.druckDialogFilament(klasse: k, filament: $0.isEmpty ? nil : $0) }))
                {
                    Text(liste.isEmpty ? "Kein Filament in der Liste" : "Bitte wählen …").tag("")
                    ForEach(liste) { x in Text(x.name).tag(x.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 340)
                .disabled(gesperrt(d) || liste.isEmpty)
            }
            Group {
                if let f {
                    Text("Preset „\(f.preset ?? f.name)“" + (f.basis.map { " · Basis „\($0)“" } ?? "")
                        + (f.abweichungen > 0 ? " · \(KevFormat.count(f.abweichungen, one: "Abweichung", many: "Abweichungen"))"
                            : " · keine Abweichungen")
                        + (v.filamentZuletzt[k] == f.id ? " · zuletzt gewählt" : ""))
                        .foregroundStyle(.secondary)
                    if let farbe, let ff = f.farbeSchluessel, ff != farbe {
                        Label("Das Filament ist \(ff), die Teile sind \(farbe).", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                } else if liste.isEmpty {
                    Text("Erst ein Filament dieses Materials in die Filamentliste aufnehmen (Claude: filament_define).")
                        .foregroundStyle(.orange)
                } else {
                    Text("Noch kein Filament gewählt: ohne Wahl geht kein Druck los.").foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .padding(.leading, 128)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func wegAbschnitt(_ d: DruckDialogZustand) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Weg").font(.headline)
            Picker("Weg", selection: Binding(get: { d.weg }, set: { w in
                guard w == .a || status.wegB.moeglich else { return }  // Weg B bleibt gesperrt
                model.druckerActions?.druckDialogAendern(platten: w == .b ? Array(d.platten.prefix(1)) : d.platten,
                                                         weg: w)
            })) {
                Text("A · In Bambu Studio öffnen").tag(DruckWeg.a)
                Text("B · Direkt drucken (LAN)").tag(DruckWeg.b).disabled(!status.wegB.moeglich)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(gesperrt(d))
            if d.weg == .a {
                Text("SK-CAD slict die Platten fertig und öffnet sie in Bambu Studio. Dort „Platte drucken“ (bzw. "
                     + "„Alle drucken“) und „Senden“ klicken. Bambu Handy bleibt wie gewohnt.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                wegBOptionen(d)
            }
            if !status.wegB.moeglich {
                DisclosureGroup(isExpanded: $anleitungOffen) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(status.wegB.anleitung.enumerated()), id: \.offset) { i, s in
                            Text("\(i + 1). \(s)").font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Weg B gesperrt: \(status.wegB.grund ?? "Developer Mode nicht nachgewiesen.")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func wegBOptionen(_ d: DruckDialogZustand) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Bett nivellieren", isOn: option(\.bettNivellieren, d))
            Toggle("Flussrate kalibrieren", isOn: option(\.flussrate, d))
            Toggle("Zeitraffer aufnehmen", isOn: option(\.zeitraffer, d))
            Text("Spule: extern (P1P ohne AMS). Weg B startet genau eine Platte.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
        .disabled(gesperrt(d))
    }

    @ViewBuilder
    private func phase(_ d: DruckDialogZustand) -> some View {
        switch d.phase {
        case .bereitet:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(d.auftragMeldung ?? "Bambu Studio slict die Platten …").font(.callout)
            }
        case .bereit(let e):
            Label(geslicedText(e), systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.green)
        case .laeuft:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(d.auftragMeldung ?? (d.weg == .a ? "Bambu Studio wird geöffnet …" : "Wird gesendet …"))
                    .font(.callout)
            }
        case .fertig(let e):
            VStack(alignment: .leading, spacing: 6) {
                Label(e.schritt == "geoeffnet" ? "In Bambu Studio geöffnet." : "Druck gestartet.",
                      systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                if e.schritt == "geoeffnet" {
                    Text("Dort „Platte drucken“ (bzw. „Alle drucken“) und „Senden“ klicken. Den Fortschritt zeigt die "
                         + "Druckerleiste, wenn „Status lesen“ an ist.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                if let f = e.datei {
                    Button("Datei im Finder zeigen") { model.druckerActions?.druckDateiZeigen(f) }
                        .buttonStyle(.link)
                }
            }
        case .fehler(let t):
            Label(t, systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
        if case .bereit(let e) = d.phase, !e.hinweise.isEmpty {
            ForEach(e.hinweise, id: \.self) { h in Text(h).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func knoepfe(_ d: DruckDialogZustand) -> some View {
        HStack {
            if case .fehler = d.phase {
                Button("Erneut versuchen") { model.druckerActions?.druckDialogNeuVorbereiten() }
            }
            Spacer()
            if case .fertig = d.phase {
                if let n = naechste(d) {
                    Button("Nächstes Material: \(n.titel) …") {
                        model.druckerActions?.druckDialogAendern(platten: n.platten, weg: d.weg)
                    }
                    .help("Die Platten des nächsten Materials vorbereiten (nach dem Spulenwechsel drucken)")
                }
                Button("Schließen") { model.druckerActions?.druckDialogSchliessen() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Abbrechen") { model.druckerActions?.druckDialogSchliessen() }
                    .keyboardShortcut(.cancelAction)
                Button(d.weg == .a ? "In Bambu Studio öffnen" : "Drucken") {
                    model.druckerActions?.druckBestaetigen()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!d.bestaetigbar || !d.fehlendesFilament(druck.vorschau).isEmpty
                    || (d.weg == .b && (!status.wegB.moeglich || d.platten.count != 1)))
                .help(d.fehlendesFilament(druck.vorschau).isEmpty ? "" : "Erst das Filament wählen")
            }
        }
    }

    // MARK: Hilfen

    private func gesperrt(_ d: DruckDialogZustand) -> Bool {
        switch d.phase {
        case .laeuft, .fertig: return true
        default: return false
        }
    }

    private func gewaehlt(_ nr: Int, _ d: DruckDialogZustand) -> Bool { d.platten.isEmpty || d.platten.contains(nr) }

    private func setze(_ nr: Int, _ an: Bool, _ d: DruckDialogZustand) {
        var wahl = Set(d.platten.isEmpty ? platten.map(\.nr) : d.platten)
        if an {
            // Ein Material je Auftrag (P1P ohne AMS): eine Platte anderen Materials ersetzt die Wahl
            if let v = druck.vorschau, let erste = wahl.first,
               DruckDialogZustand.material(erste, v) != DruckDialogZustand.material(nr, v)
            {
                wahl = []
            }
            wahl.insert(nr)
        } else {
            wahl.remove(nr)
        }
        if d.weg == .b, an { wahl = [nr] }
        guard !wahl.isEmpty else { return }  // mindestens eine Platte
        model.druckerActions?.druckDialogAendern(platten: wahl.sorted(), weg: d.weg)
    }

    private func option(_ k: WritableKeyPath<DruckOptionen, Bool>, _ d: DruckDialogZustand) -> Binding<Bool> {
        Binding(get: { d.optionen[keyPath: k] }, set: { v in
            var o = d.optionen
            o[keyPath: k] = v
            model.druckerActions?.druckDialogOptionen(o)
        })
    }

    private func naechste(_ d: DruckDialogZustand) -> (titel: String, platten: [Int])? {
        guard let v = druck.vorschau,
              let n = DruckDialogZustand.naechste(nach: d.platten.isEmpty ? platten.map(\.nr) : d.platten, vorschau: v)
        else { return nil }
        let name = v.klassenTitel(DruckDialogZustand.material(n[0], v))  // „PETG gelb“ (Strang „Rest Druck“)
        return ("\(name), Platte " + n.map(String.init).joined(separator: ", "), n)
    }

    private func gewaehltePlatten(_ d: DruckDialogZustand) -> [DruckPlatte] {
        platten.filter { gewaehlt($0.nr, d) }
    }

    private func materialText(_ p: DruckPlatte) -> String {
        p.material.map(\.name).joined(separator: ", ") + (p.farbe.map { " \($0)" } ?? "")
    }

    private func materialien(_ d: DruckDialogZustand) -> [DruckMaterialSumme] {
        var gesehen: [String: DruckMaterialSumme] = [:]
        for p in gewaehltePlatten(d) {
            for m in p.material where gesehen[m.material] == nil {
                var x = m
                x.filament = x.filament ?? druck.vorschau?.summe.material.first { $0.material == m.material }?.filament
                gesehen[m.material] = x
            }
        }
        return gesehen.values.sorted { $0.material < $1.material }
    }

    private func summenText(_ d: DruckDialogZustand) -> String {
        let g = gewaehltePlatten(d)
        let zeit = g.reduce(0) { $0 + $1.zeitS }
        let gramm = g.reduce(0) { $0 + $1.gramm }
        let stand = druck.vorschau?.stand.titel ?? "Schätzung"
        return "\(KevFormat.count(g.count, one: "Platte", many: "Platten")), \(DruckFormat.zeit(zeit)), "
            + "\(DruckFormat.gramm(gramm)) (\(stand))"
    }

    private func geslicedText(_ e: DruckAuftragErgebnis) -> String {
        guard !e.gesliced.isEmpty else { return "Gesliced, bereit." }
        let n = KevFormat.count(e.gesliced.count, one: "Platte", many: "Platten")
        return "Bambu Studio: \(n) gesliced, \(DruckFormat.zeit(e.zeitS)), \(DruckFormat.gramm(e.gramm))"
            + (e.ausZwischenspeicher ? " (aus dem Zwischenspeicher)" : "") + "."
    }
}
