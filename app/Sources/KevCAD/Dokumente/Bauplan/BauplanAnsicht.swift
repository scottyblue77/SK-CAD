import KevCADCore
import SwiftUI

/// Bauplan als Schritt-für-Schritt-Anleitung (DOKUMENTE.md „App“, Strang P6-A2): links Abschnitte und Schritte, rechts
/// der gewählte Schritt mit großem Strichbild, Teilen, Verbindungsmitteln, Werkzeug, Sicherheit, Bohrbild und den
/// Problemen der Simulation. Bearbeiten (Text, fest, verschieben, zusammenfassen, teilen, Reihenfolge) geht als
/// BAUPLAN_EDIT an den Kernel; „Durchspielen“ zeigt den Aufbau im 3D-Bereich.
/// Oberflächenzustand des Bauplans, den Fenster, Menü und Selbsttest teilen.
@MainActor
final class BauplanUI: ObservableObject {
    static let shared = BauplanUI()
    /// Gewählter Schritt (nil = Überblick).
    @Published var auswahl: String?
    /// Offene Blätter (Text bearbeiten, Teilen, Reihenfolge): hier statt in der Ansicht, damit auch der Inspektor sie
    /// öffnen kann.
    @Published var bearbeiten: BauplanSchritt?
    @Published var teilen: BauplanSchritt?
    @Published var regel: BauplanSchritt?
}

struct BauplanAnsicht: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: BauplanStore
    @ObservedObject private var ui = BauplanUI.shared
    @State private var nurProbleme = false

    init(model: AppModel) {
        self.model = model
        self.store = model.bauplan
    }

    private var actions: BauplanActions? { model.bauplanActions }

    var body: some View {
        Group {
            if let plan = store.plan {
                HStack(spacing: 0) {
                    BauplanListe(plan: plan, store: store, auswahl: $ui.auswahl, nurProbleme: $nurProbleme,
                                 actions: actions)
                        .frame(minWidth: 230, idealWidth: 300, maxWidth: 300)
                    Divider()
                    if let id = ui.auswahl, let s = plan.schritt(id) {
                        BauplanSchrittAnsicht(
                            plan: plan, schritt: s, bild: store.bild(s.id), store: store, actions: actions,
                            bearbeiten: { ui.bearbeiten = $0 }, teilen: { ui.teilen = $0 }, regel: { ui.regel = $0 })
                            .id(s.id)
                    } else {
                        BauplanUeberblick(plan: plan, store: store, actions: actions) { ui.auswahl = $0 }
                    }
                }
            } else {
                leer
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 480)
        .overlay(alignment: .bottom) { meldungsLeiste }
        .onAppear {
            if store.plan == nil, !store.laedt { actions?.bauplanAnfordern() }
        }
        .onChange(of: store.plan?.alleSchritte.map(\.id)) { _, ids in
            if let a = ui.auswahl, !(ids ?? []).contains(a) { ui.auswahl = nil }
        }
        .onChange(of: store.durchspielen?.schritt) { _, s in
            if let s { ui.auswahl = s }  // die Liste folgt dem Durchspielen
        }
        .sheet(item: $ui.bearbeiten) { s in
            BauplanTextBlatt(schritt: s) { titel, text, hinweise in
                actions?.bauplanBearbeiten([BauplanOp.text(schritt: s.id, titel: titel, text: text, hinweise: hinweise)],
                                           titel: "Text von Schritt gespeichert")
            }
        }
        .sheet(item: $ui.teilen) { s in
            BauplanTeilenBlatt(schritt: s) { teile in
                actions?.bauplanBearbeiten([BauplanOp.teilen(schritt: s.id, teile: teile)], titel: "Schritt geteilt")
            }
        }
        .sheet(item: $ui.regel) { s in
            if let plan = store.plan {
                BauplanRegelBlatt(plan: plan, schritt: s) { a, b, grund in
                    actions?.bauplanBearbeiten([BauplanOp.vorher(a: a, b: b, grund: grund)],
                                               titel: "Reihenfolge eingetragen")
                }
            }
        }
    }

    @ViewBuilder
    private var leer: some View {
        if store.laedt {
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("Bauplan wird erzeugt …").font(.title3.weight(.medium))
                Text("Montagefolge, Bilder und Simulation brauchen beim ersten Mal einige Sekunden.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Noch kein Bauplan", systemImage: "hammer")
            } description: {
                Text(store.meldung?.fehler == true ? store.meldung!.text
                     : "SK-CAD baut die Anleitung aus dem Modell: Material, Zuschnitt, Bearbeiten, Drucken und Montage.")
            } actions: {
                Button("Bauplan erzeugen") { actions?.bauplanAnfordern() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.project == nil || actions == nil)
            }
        }
    }

    @ViewBuilder
    private var meldungsLeiste: some View {
        if let a = store.arbeitet {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(a)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 14)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let m = store.meldung, Date().timeIntervalSince(m.zeit) < 8, store.plan != nil {
            Label(m.text, systemImage: m.fehler ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(m.fehler ? Color.red : Color.secondary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Liste

struct BauplanListe: View {
    let plan: Bauplan
    @ObservedObject var store: BauplanStore
    @Binding var auswahl: String?
    @Binding var nurProbleme: Bool
    let actions: BauplanActions?

    var body: some View {
        VStack(spacing: 0) {
            kopf
            Divider()
            ScrollViewReader { proxy in
            List(selection: $auswahl) {
                ForEach(plan.abschnitte.filter { !$0.schritte.isEmpty }) { a in
                    Section {
                        ForEach(gruppiert(a)) { g in
                            if let t = g.titel, a.art == .montage {
                                Text(t)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                    .padding(.top, 4)
                                    .selectionDisabled()
                            }
                            ForEach(g.schritte) { s in
                                BauplanZeile(schritt: s, nummer: plan.nummer(s.id) ?? 0,
                                             aktiv: store.durchspielen?.schritt == s.id)
                                    .tag(s.id)
                                    .id(s.id)
                                    .contextMenu { kontextMenu(s, a) }
                            }
                            .onMove { quelle, ziel in verschiebe(a, g.schritte, quelle, ziel) }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: a.art.symbol)
                            Text(a.titel)
                            Spacer()
                            if a.reihenfolgeFest {
                                Image(systemName: "lock.fill").help("Reihenfolge von Hand festgelegt")
                            }
                            Text("\(a.schritte.count)").monospacedDigit().foregroundStyle(.tertiary)
                        }
                    }
                }
                if !plan.vorher.filter({ $0.quelle != "auto" }).isEmpty {
                    Section("Reihenfolgen") {
                        ForEach(plan.vorher.filter { $0.quelle != "auto" }) { r in
                            HStack(alignment: .firstTextBaseline) {
                                Image(systemName: "arrow.right.circle")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(name(r.a)) vor \(name(r.b))").lineLimit(2)
                                    if !r.grund.isEmpty {
                                        Text(r.grund).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button {
                                    actions?.bauplanBearbeiten([BauplanOp.vorherLoeschen(index: r.index)],
                                                               titel: "Reihenfolge gelöscht")
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                                .help("Reihenfolge löschen")
                            }
                            .selectionDisabled()
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: auswahl) { _, id in
                // gewählter Schritt (auch beim Durchspielen) bleibt sichtbar
                if let id { withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) } }
            }
            }
        }
    }

    private func name(_ id: String) -> String {
        if let n = plan.nummer(id), let s = plan.schritt(id) { return "\(n) \(s.titel)" }
        return BauplanSchritt.kurzname(id)
    }

    private var kopf: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(plan.titel.isEmpty ? "Bauplan" : plan.titel)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Menu {
                    Button("Simulation neu rechnen") { actions?.bauplanPruefen(schritt: nil) }
                    Button("Bauplan neu laden") { actions?.bauplanAnfordern() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Weitere Aktionen")
            }
            HStack(spacing: 6) {
                BauplanChip(text: KevFormat.count(plan.alleSchritte.count, one: "Schritt", many: "Schritte"),
                     symbol: "list.number", farbe: .secondary)
                if plan.fehlerAnzahl > 0 {
                    BauplanChip(text: KevFormat.count(plan.fehlerAnzahl, one: "Fehler", many: "Fehler"),
                         symbol: "xmark.octagon.fill", farbe: .red)
                }
                if plan.warnungAnzahl > 0 {
                    BauplanChip(text: KevFormat.count(plan.warnungAnzahl, one: "Warnung", many: "Warnungen"),
                         symbol: "exclamationmark.triangle.fill", farbe: .orange)
                }
                if plan.fehlerAnzahl + plan.warnungAnzahl == 0 {
                    BauplanChip(text: "Simulation ohne Probleme", symbol: "checkmark.seal.fill", farbe: .green)
                }
            }
            Button {
                actions?.durchspielenStarten(ab: nil)
            } label: {
                Label(store.durchspielen == nil ? "Durchspielen" : "Durchspielen läuft", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.kevAkzent)
            .disabled(BauplanAblauf.schritte(plan).isEmpty)
            .help("Aufbau Schritt für Schritt im 3D-Bereich: nur montierte Teile, neue fahren ein")
        }
        .padding(14)
    }

    /// Schritte eines Abschnitts in Gruppen (Montage: je Vormontage bzw. Hauptmontage).
    private func gruppiert(_ a: BauplanAbschnitt) -> [BauplanGruppe] {
        let liste = a.schritte
        guard a.art == .montage else { return [BauplanGruppe(id: 0, titel: nil, schritte: liste)] }
        var out: [BauplanGruppe] = []
        for s in liste {
            let t = s.baugruppe.map { "Vormontage \($0)" } ?? "Hauptmontage"
            if out.last?.titel == t {
                out[out.count - 1].schritte.append(s)
            } else {
                out.append(BauplanGruppe(id: out.count, titel: t, schritte: [s]))
            }
        }
        return out
    }

    @ViewBuilder
    private func kontextMenu(_ s: BauplanSchritt, _ a: BauplanAbschnitt) -> some View {
        if a.art == .montage {
            Button("Ab hier durchspielen") { actions?.durchspielenStarten(ab: s.id) }
        }
        Button("Im 3D zeigen") { actions?.bauplanZeigen(teile: s.neu.isEmpty ? s.teile : s.neu, ort: nil) }
            .disabled(s.teile.isEmpty)
        Divider()
        Button(s.fest ? "Nicht mehr fest" : "Fest (bleibt bei neuen Läufen)") {
            actions?.bauplanBearbeiten([BauplanOp.fest(schritt: s.id, !s.fest)], titel: s.fest ? "Schritt gelöst" : "Schritt fest")
        }
        if let i = a.schritte.firstIndex(of: s) {
            Button("Nach oben") {
                actions?.bauplanBearbeiten([BauplanOp.verschieben(schritt: s.id, nach: i >= 2 ? a.schritte[i - 2].id : nil)],
                                           titel: "Schritt verschoben")
            }
            .disabled(i == 0)
            Button("Nach unten") {
                actions?.bauplanBearbeiten([BauplanOp.verschieben(schritt: s.id, nach: a.schritte[i + 1].id)],
                                           titel: "Schritt verschoben")
            }
            .disabled(i + 1 >= a.schritte.count)
            Button("Mit nächstem zusammenfassen") {
                actions?.bauplanBearbeiten([BauplanOp.zusammenfassen([s.id, a.schritte[i + 1].id])],
                                           titel: "Schritte zusammengefasst")
            }
            .disabled(i + 1 >= a.schritte.count)
        }
    }

    private func verschiebe(_ a: BauplanAbschnitt, _ gruppe: [BauplanSchritt], _ quelle: IndexSet, _ ziel: Int) {
        guard let von = quelle.first, gruppe.indices.contains(von) else { return }
        let s = gruppe[von]
        var neu = gruppe
        neu.move(fromOffsets: quelle, toOffset: ziel)
        guard let pos = neu.firstIndex(of: s) else { return }
        // „nach“ ist der Schritt davor im ganzen Abschnitt (nil = an den Anfang)
        let vorher: String? = pos > 0 ? neu[pos - 1].id
            : a.schritte.firstIndex(of: gruppe[0]).flatMap { $0 > 0 ? a.schritte[$0 - 1].id : nil }
        actions?.bauplanBearbeiten([BauplanOp.verschieben(schritt: s.id, nach: vorher)], titel: "Schritt verschoben")
    }
}

struct BauplanGruppe: Identifiable {
    var id: Int
    var titel: String?
    var schritte: [BauplanSchritt]
}

struct BauplanZeile: View {
    let schritt: BauplanSchritt
    let nummer: Int
    let aktiv: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            BauplanNummer(nummer: nummer, groesse: 22)
                .overlay {
                    if aktiv {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(.white, lineWidth: 2).padding(-2)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(schritt.titel)
                    .lineLimit(2)
                    .fontWeight(aktiv ? .semibold : .regular)
                HStack(spacing: 5) {
                    if schritt.anzahl > 1 {
                        Text(BauplanText.menge(schritt.anzahl)).fontWeight(.bold)
                    }
                    if !schritt.werkzeug.isEmpty {
                        Image(systemName: BauplanWerkzeug.symbol(schritt.werkzeug[0]))
                    }
                    if schritt.fest { Image(systemName: "lock.fill").help("fest: bleibt bei neuen Läufen") }
                    if schritt.quelle == "kevin" { Image(systemName: "person.fill").help("von dir geändert") }
                    if schritt.quelle == "agent" { Image(systemName: "sparkles").help("von Claude formuliert") }
                    if schritt.verwaist { Image(systemName: "questionmark.diamond").help("Teile fehlen im Modell") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let w = schritt.schwersterBefund, w != .hinweis {
                Image(systemName: w.symbol)
                    .foregroundStyle(w.farbe)
                    .help(schritt.probleme.map(\.text).joined(separator: "\n"))
            }
        }
        .padding(.vertical, 2)
    }
}

struct BauplanChip: View {
    let text: String
    let symbol: String
    let farbe: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(farbe == .secondary ? Color.secondary : farbe)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill((farbe == .secondary ? Color.secondary : farbe).opacity(0.12)))
    }
}

// MARK: - Überblick (kein Schritt gewählt)

struct BauplanUeberblick: View {
    let plan: Bauplan
    @ObservedObject var store: BauplanStore
    let actions: BauplanActions?
    let waehle: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("BAUANLEITUNG").font(.caption.weight(.semibold)).foregroundStyle(Color.kevAkzent).tracking(1.5)
                    Text(plan.titel.isEmpty ? "Bauplan" : plan.titel).font(.largeTitle.weight(.bold))
                    Text("\(KevFormat.count(plan.alleSchritte.count, one: "Schritt", many: "Schritte")) in "
                         + "\(plan.abschnitte.filter { !$0.schritte.isEmpty }.count) Abschnitten")
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                    ForEach(plan.abschnitte.filter { !$0.schritte.isEmpty }) { a in
                        Button {
                            if let s = a.schritte.first { waehle(s.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Image(systemName: a.art.symbol).font(.title2).foregroundStyle(Color.kevAkzent)
                                Text(a.titel).font(.headline)
                                let von = plan.nummer(a.schritte.first!.id) ?? 0
                                let bis = plan.nummer(a.schritte.last!.id) ?? 0
                                Text(von == bis ? "Schritt \(von)" : "Schritte \(von)–\(bis)")
                                    .font(.caption).foregroundStyle(.secondary)
                                let p = a.schritte.flatMap(\.probleme).count
                                if p > 0 {
                                    Label(KevFormat.count(p, one: "Problem", many: "Probleme"),
                                          systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption).foregroundStyle(.red)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !plan.alleWerkzeuge.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Werkzeug für den ganzen Aufbau").font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)], alignment: .leading,
                                  spacing: 8) {
                            ForEach(plan.alleWerkzeuge, id: \.self) { w in
                                Label(w, systemImage: BauplanWerkzeug.symbol(w))
                            }
                        }
                    }
                }
                let sicher = Array(Set(plan.alleSchritte.flatMap(\.sicherheitsHinweise))).sorted()
                if !sicher.isEmpty { BauplanSicherheit(texte: sicher) }
                if !plan.nichtImAufbau.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Nicht im Aufbau").font(.headline)
                        ForEach(plan.nichtImAufbau, id: \.teil) { t in
                            Text("\(t.teil): \(t.grund)").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }
}

// MARK: - Sicherheit und Probleme

struct BauplanSicherheit: View {
    let texte: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.black, Color.kevSicherheit)
            VStack(alignment: .leading, spacing: 6) {
                Text("Sicherheit").font(.headline)
                ForEach(texte, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.kevSicherheit.opacity(0.16)))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10).fill(Color.kevSicherheit).frame(width: 5)
        }
    }
}

struct BauplanBefundKarte: View {
    let befund: BauplanBefund
    let zeigen: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: befund.schwere.symbol)
                .font(.title3)
                .foregroundStyle(befund.schwere.farbe)
            VStack(alignment: .leading, spacing: 5) {
                Text("\(befund.schwere.titel) · \(befund.artTitel)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(befund.schwere == .hinweis ? Color.secondary : befund.schwere.farbe)
                Text(befund.text).fixedSize(horizontal: false, vertical: true)
                if let l = befund.loesung, !l.isEmpty {
                    Label(l, systemImage: "lightbulb")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if let zeigen, !befund.teile.isEmpty {
                Button("Im 3D zeigen", action: zeigen)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(befund.schwere == .hinweis ? Color.secondary.opacity(0.08) : befund.schwere.farbe.opacity(0.10)))
    }
}
