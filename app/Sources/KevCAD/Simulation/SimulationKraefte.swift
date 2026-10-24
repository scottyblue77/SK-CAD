import KevCADCore
import SwiftUI

// Reiter „Kräfte“ und „Lager“ im Inspektor des Bereichs Simulation: Kraft per Klick auf eine Fläche oder einen Punkt,
// Richtung entlang der Normale, einer Achse oder frei (Winkel oder Pfeil-Griff im Viewer), Betrag in N oder kg,
// Kraftpaar mit einem Gegenstück; Lager per Klick (fest, gelenkig, gleitend, auf Fläche oder Punkt).

struct KraefteAnsicht: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SimulationStore

    private var actions: SimulationActions? { model.simulationActions }

    var body: some View {
        if let lf = store.lastfall {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Toggle(isOn: Binding(get: { store.werkzeug == .kraft },
                                         set: { actions?.setSimulationWerkzeug($0 ? .kraft : .keins) })) {
                        Label("Kraft setzen", systemImage: "hand.tap")
                    }
                    .toggleStyle(.button)
                    .help("Im Viewer eine Fläche oder einen Punkt anklicken: dort entsteht ein Kraftpfeil (Esc beendet)")
                    Spacer()
                    PfeileBildschirmfestSchalter(store: store, actions: actions)
                }
                if let e = store.entwurf {
                    KraftEditor(model: model, store: store, entwurf: e)
                }
                liste(lf)
            }
        } else {
            Text(store.modellLastfall != nil ? "Kräfte eines Szenarios aus model.py sind nur lesbar: „Als Kopie "
                 + "bearbeiten“ legt einen Lastfall der App an." : "Erst einen Lastfall wählen oder anlegen.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func liste(_ lf: SimLastfall) -> some View {
        GroupBox("Kräfte in „\(lf.name)“") {
            VStack(alignment: .leading, spacing: 4) {
                if lf.lasten.isEmpty {
                    Text("Noch keine: „Kraft setzen“ und im Viewer klicken").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(lf.lasten) { l in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: l.paar ? "arrow.right.and.line.vertical.and.arrow.left" : "arrow.down.to.line")
                            .foregroundStyle(l.paar ? Color.purple : Color.blue)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(l.id) · \(simKurz(l.teil))" + (l.gegen.map { " ↔ \(simKurz($0))" } ?? ""))
                                .lineLimit(1)
                            Text(kraftText(l))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if l.zustand == .fehlt || l.zustand == .neu {
                                Text(l.zustandText)
                                    .font(.caption)
                                    .foregroundStyle(l.zustand == .fehlt ? .red : .orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 2)
                        SimZuordnungZeichen(zustand: l.zustand, text: l.zustandText)
                        Button {
                            actions?.lastBearbeiten(l.id)
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help("Ändern (Richtung, Betrag; neu anklicken setzt den Ort)")
                        Button {
                            actions?.simulationAendern([SimOp.lastLoeschen(lf.name, id: l.id)], fertig: nil)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Kraft löschen")
                    }
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(
                        store.lastAuswahl == l.id ? Color.accentColor.opacity(0.15) : Color.clear))
                    .contentShape(Rectangle())
                    .onTapGesture { actions?.waehleLast(store.lastAuswahl == l.id ? nil : l.id) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func kraftText(_ l: SimLast) -> String {
        let r: String
        switch l.richtung.art {
        case .normale: r = l.richtung.umkehren ? "aus der Fläche" : "in die Fläche"
        case .achse: r = "entlang \(l.richtung.umkehren ? "−" : "")\(l.richtung.achse)"
        case .frei: r = "frei \(KevFormat.number(l.richtung.azimut, digits: 0))° / \(KevFormat.number(l.richtung.hoehe, digits: 0))°"
        }
        let b: String
        switch l.einheit {
        case "kg": b = "\(KevFormat.number(l.betrag, digits: 1)) kg"
        case SimKraft.druck: b = "\(KevFormat.number(l.betrag, digits: 3)) N/mm²"
        default: b = "\(KevFormat.number(l.betrag, digits: 0)) N"
        }
        let f = l.kraftWirksam.map { " = " + simKraftText($0) } ?? ""
        return "\(b) \(r)\(l.aufFlaeche ? " auf der ganzen Fläche" : "")\(f)"
    }
}

/// Schalter „Pfeile bildschirmfest“: Pfeile, Lagersymbole und Griff behalten beim Zoomen ihre Größe auf dem Bildschirm.
struct PfeileBildschirmfestSchalter: View {
    @ObservedObject var store: SimulationStore
    var actions: SimulationActions?

    var body: some View {
        Toggle(isOn: Binding(get: { store.pfeileBildschirmfest }, set: { actions?.setPfeileBildschirmfest($0) })) {
            Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
        }
        .toggleStyle(.button)
        .help("Pfeile bildschirmfest: Kräfte, Lager und Griff behalten beim Heranzoomen ihre Größe auf dem Bildschirm "
              + "(sonst in Millimetern wie das Modell)")
    }
}

/// „Gilt für“: alle Lastfälle, nur der gewählte oder eine Auswahl mit Häkchen (Lager je Lastfall).
struct LastfallWahl: View {
    var titel: String
    @Binding var szenarien: [String]?
    var namen: [String]
    var gewaehlt: String?
    @State private var auswahlOffen = false

    private enum Modus: Hashable { case alle, gewaehlt, auswahl }

    private var modus: Modus {
        if auswahlOffen { return .auswahl }
        guard let s = szenarien else { return .alle }
        if let g = gewaehlt, s == [g] { return .gewaehlt }
        return .auswahl
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(titel, selection: Binding(get: { modus }, set: { m in
                switch m {
                case .alle:
                    auswahlOffen = false
                    szenarien = nil
                case .gewaehlt:
                    auswahlOffen = false
                    szenarien = gewaehlt.map { [$0] } ?? []
                case .auswahl:
                    auswahlOffen = true
                    if szenarien == nil { szenarien = gewaehlt.map { [$0] } ?? [] }
                }
            })) {
                Text("Alle Lastfälle").tag(Modus.alle)
                Text(gewaehlt.map { "Nur „\($0)“" } ?? "Nur der gewählte").tag(Modus.gewaehlt)
                    .disabled(gewaehlt == nil)
                Text("Auswahl …").tag(Modus.auswahl)
            }
            if modus == .auswahl {
                ForEach(namen, id: \.self) { n in
                    Toggle(n, isOn: Binding(get: { szenarien?.contains(n) ?? true }, set: { an in
                        var s = szenarien ?? []
                        if an { if !s.contains(n) { s.append(n) } } else { s.removeAll { $0 == n } }
                        szenarien = s
                    }))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                }
                if szenarien?.isEmpty == true {
                    Text("In keinem Lastfall: das Lager zählt nicht").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
}

/// Gleitrichtung eines gleitenden Lagers: in der Fläche, entlang X, Y, Z, entlang einer Kante (anklicken) oder frei.
struct GleitenWahl: View {
    @Binding var gleiten: SimGleiten?
    var kanteWaehlen: Bool
    var kanteAn: (Bool) -> Void
    @State private var freiAzimut = 0.0
    @State private var freiHoehe = 0.0

    private enum Wahl: Hashable { case flaeche, x, y, z, kante, frei }

    private var wahl: Wahl {
        if kanteWaehlen { return .kante }
        guard let g = gleiten, g.art == .richtung, let r = g.richtung else { return .flaeche }
        if g.quelle == "kante" { return .kante }
        if g.quelle == "achse" {
            if abs(r.x) > 0.999 { return .x }
            if abs(r.y) > 0.999 { return .y }
            if abs(r.z) > 0.999 { return .z }
        }
        return .frei
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Gleitet", selection: Binding(get: { wahl }, set: { w in
                if w != .kante, kanteWaehlen { kanteAn(false) }
                switch w {
                case .flaeche: gleiten = nil
                case .x: gleiten = .achse("+x")
                case .y: gleiten = .achse("+y")
                case .z: gleiten = .achse("+z")
                case .kante: kanteAn(true)
                case .frei:
                    let r = gleiten?.richtung ?? SimKraft.ausWinkeln(azimut: freiAzimut, hoehe: freiHoehe)
                    let wk = SimKraft.winkel(r)
                    freiAzimut = wk.azimut
                    freiHoehe = wk.hoehe
                    gleiten = SimGleiten(art: .richtung, richtung: r, quelle: "frei")
                }
            })) {
                Text("in der Fläche").tag(Wahl.flaeche)
                Text("entlang X").tag(Wahl.x)
                Text("entlang Y").tag(Wahl.y)
                Text("entlang Z").tag(Wahl.z)
                Text("entlang einer Kante").tag(Wahl.kante)
                Text("frei (Winkel)").tag(Wahl.frei)
            }
            .help("In der Fläche: hält nur senkrecht zur Fläche (genau entlang ihrer Normale). Entlang einer Richtung: "
                  + "wie auf einer Schiene, hält quer dazu in beide Richtungen")
            switch wahl {
            case .kante:
                HStack {
                    Text(kanteWaehlen ? "Kante im Viewer anklicken …" : (gleiten?.titel ?? "noch keine Kante"))
                        .font(.caption).foregroundStyle(kanteWaehlen ? .orange : .secondary)
                    Spacer()
                    Button(kanteWaehlen ? "Abbrechen" : "Kante anklicken") { kanteAn(!kanteWaehlen) }
                        .controlSize(.small)
                }
            case .frei:
                HStack {
                    Text("Azimut")
                    TextField("", value: Binding(get: { freiAzimut }, set: { v in
                        freiAzimut = v
                        gleiten = SimGleiten(art: .richtung, richtung: SimKraft.ausWinkeln(azimut: v, hoehe: freiHoehe),
                                             quelle: "frei")
                    }), format: .number.precision(.fractionLength(0...1)))
                        .frame(width: 50).multilineTextAlignment(.trailing)
                    Text("°")
                    Text("Höhe")
                    TextField("", value: Binding(get: { freiHoehe }, set: { v in
                        freiHoehe = v
                        gleiten = SimGleiten(art: .richtung, richtung: SimKraft.ausWinkeln(azimut: freiAzimut, hoehe: v),
                                             quelle: "frei")
                    }), format: .number.precision(.fractionLength(0...1)))
                        .frame(width: 50).multilineTextAlignment(.trailing)
                    Text("°")
                }
                .onAppear {
                    if let r = gleiten?.richtung {
                        let w = SimKraft.winkel(r)
                        freiAzimut = w.azimut
                        freiHoehe = w.hoehe
                    }
                }
            default:
                EmptyView()
            }
        }
    }
}

/// Entwurf einer Kraft: Ort aus dem Klick, Richtung, Betrag, Kraftpaar; „Übernehmen“ speichert (last_setzen).
struct KraftEditor: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SimulationStore
    var entwurf: SimulationStore.KraftEntwurf

    private var actions: SimulationActions? { model.simulationActions }

    var body: some View {
        let l = entwurf.last
        GroupBox(entwurf.bearbeitet.map { "Kraft \($0) ändern" } ?? "Neue Kraft") {
            VStack(alignment: .leading, spacing: 7) {
                Text(ortText(l))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Verteilung", selection: Binding(get: { l.verteilung }, set: { v in
                    var e = entwurf
                    e.last.verteilung = v
                    if v != "flaeche", e.last.einheit == SimKraft.druck { e.last.einheit = "N" }
                    actions?.setKraftEntwurf(e)
                })) {
                    Text("Am Punkt").tag("punkt")
                    Text("Ganze Fläche").tag("flaeche").disabled(l.ort.flaeche == nil)
                }
                .pickerStyle(.segmented)
                .help("Am Punkt: greift am Klickpunkt an (in der FEM im Umkreis verteilt). Ganze Fläche: gleichmäßig "
                      + "über die angeklickte Fläche, auch als Druck in N/mm²")
                Picker("Richtung", selection: bind(\.richtung.art)) {
                    ForEach(SimRichtung.Art.allCases, id: \.self) { a in
                        Text(a.titel).tag(a).disabled(a == .normale && l.ort.normale == nil
                                                      || a != .normale && l.einheit == SimKraft.druck)
                    }
                }
                .pickerStyle(.segmented)
                switch l.richtung.art {
                case .normale:
                    Text("Senkrecht auf die angeklickte Fläche, in das Teil hinein").font(.caption)
                        .foregroundStyle(.secondary)
                case .achse:
                    Picker("Achse", selection: bind(\.richtung.achse)) {
                        ForEach(SimulationZustand.achsen, id: \.self) { Text($0).tag($0) }
                    }
                case .frei:
                    HStack {
                        Text("Azimut")
                        TextField("", value: bind(\.richtung.azimut), format: .number.precision(.fractionLength(0...1)))
                            .frame(width: 56).multilineTextAlignment(.trailing)
                        Text("°")
                        Spacer()
                        Text("Höhe")
                        TextField("", value: bind(\.richtung.hoehe), format: .number.precision(.fractionLength(0...1)))
                            .frame(width: 56).multilineTextAlignment(.trailing)
                        Text("°")
                    }
                }
                if l.einheit != SimKraft.druck {
                    Text("Im Viewer: weiße Kugel am Pfeilende frei drehen, blauer Ring nur Azimut, grüner Ring nur "
                         + "Höhe; rastet auf Achsen und die Normale ein (⌘: aus)")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Umkehren", isOn: bind(\.richtung.umkehren))
                HStack {
                    Text("Betrag")
                    TextField("", value: bind(\.betrag), format: .number.precision(.fractionLength(0...3)))
                        .frame(width: 72).multilineTextAlignment(.trailing)
                    Picker("", selection: Binding(get: { l.einheit }, set: { v in
                        var e = entwurf
                        e.last.einheit = v
                        if v == SimKraft.druck {  // Druck: auf der ganzen Fläche, senkrecht
                            e.last.verteilung = "flaeche"
                            e.last.richtung.art = .normale
                        }
                        actions?.setKraftEntwurf(e)
                    })) {
                        Text("N").tag("N")
                        Text("kg").tag("kg")
                        Text("N/mm²").tag(SimKraft.druck).disabled(l.ort.flaeche == nil || l.ort.normale == nil)
                    }
                    .labelsHidden()
                    .frame(width: 84)
                }
                if l.aufFlaeche {
                    Text("Fläche " + (l.flaecheMm2.map { "\(KevFormat.number($0, digits: 1)) mm²" } ?? "?")
                         + (l.einheit == SimKraft.druck ? ", Kraft = Druck × Fläche" : ", gleichmäßig verteilt"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Kraftpaar mit", selection: bind(\.gegen)) {
                    Text("keinem (äußere Last)").tag(String?.none)
                    ForEach(model.parts.map(\.id).filter { $0 != l.teil }, id: \.self) { n in
                        Text(simKurz(n)).tag(String?.some(n))
                    }
                }
                .help("Innere Kraft: die Gegenkraft wirkt am selben Punkt auf dieses Teil (zählt nicht beim Kippen "
                      + "und Rutschen des Ganzen)")
                if let f = entwurf.kraft {
                    Text("F = " + simKraftText(f)).font(.callout.monospacedDigit())
                } else {
                    Text("Betrag über 0 und eine Richtung angeben").font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Button("Übernehmen") { actions?.kraftEntwurfSpeichern() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(entwurf.kraft == nil)
                    Button("Verwerfen") { actions?.setKraftEntwurf(nil) }
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func ortText(_ l: SimLast) -> String {
        var t = simKurz(l.teil)
        if let f = l.ort.flaeche { t += " · Fläche \(f)" }
        if let p = l.ort.punkt {
            t += " · (" + [p.x, p.y, p.z].map { KevFormat.number(Double($0), digits: 1) }.joined(separator: "; ") + ")"
        }
        if l.ort.normale == nil { t += " · ohne Normale" }
        return t + " – neu klicken setzt den Ort"
    }

    private func bind<T>(_ k: WritableKeyPath<SimLast, T>) -> Binding<T> {
        Binding(get: { entwurf.last[keyPath: k] }, set: { v in
            var e = entwurf
            e.last[keyPath: k] = v
            actions?.setKraftEntwurf(e)
        })
    }
}

// MARK: - Reiter Lager

/// Menü „Gilt für“ eines gesetzten Lagers: alle Lastfälle oder einzelne an- und abwählen (lager_setzen).
struct LagerLastfallMenue: View {
    var lager: SimLager
    var namen: [String]
    var actions: SimulationActions?

    var body: some View {
        Menu {
            Toggle("Alle Lastfälle", isOn: Binding(get: { lager.szenarien == nil }, set: { an in
                setze(an ? nil : namen)
            }))
            Divider()
            ForEach(namen, id: \.self) { n in
                Toggle(n, isOn: Binding(get: { lager.szenarien?.contains(n) ?? false }, set: { an in
                    var s = lager.szenarien ?? []
                    if an { if !s.contains(n) { s.append(n) } } else { s.removeAll { $0 == n } }
                    setze(s)
                }))
            }
        } label: {
            Image(systemName: "list.bullet.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Gilt für: \(lager.giltText)")
    }

    private func setze(_ s: [String]?) {
        var x = lager
        x.szenarien = s
        actions?.simulationAendern([SimOp.lagerSetzen(x)], fertig: nil)
    }
}

struct LagerAnsicht: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SimulationStore

    private var actions: SimulationActions? { model.simulationActions }

    /// „Kante anklicken“: Werkzeug Lager an, der nächste Klick auf eine Kante setzt die Gleitrichtung.
    private func kanteAn(_ an: Bool) {
        if an, store.werkzeug != .lager { actions?.setSimulationWerkzeug(.lager) }
        store.kanteWaehlen = an
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Lager gelten für alle Lastfälle oder nur für ausgewählte. Ohne ausdrückliches Lager leitet SK-CAD "
                 + "sie aus den Kontakten ab (Boden, Kulisse, befestigt, tragende Nachbarn).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Art", selection: $store.lagerArt) {
                ForEach(SimLager.Art.allCases, id: \.self) { Text($0.titel).tag($0) }
            }
            .pickerStyle(.segmented)
            .help(store.lagerArt.hilfe)
            Text(store.lagerArt.hilfe).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Auf", selection: $store.lagerAuf) {
                ForEach(SimLager.Auf.allCases, id: \.self) { Text($0.titel).tag($0) }
            }
            .pickerStyle(.segmented)
            if store.lagerArt == .gleitend && store.lagerEntwurf == nil {
                GleitenWahl(gleiten: $store.lagerGleiten, kanteWaehlen: store.kanteWaehlen, kanteAn: kanteAn)
            }
            if store.lagerEntwurf == nil {
                LastfallWahl(titel: "Gilt für", szenarien: $store.lagerSzenarien, namen: store.stand?.alleNamen ?? [],
                             gewaehlt: store.auswahl)
            }
            Toggle(isOn: Binding(get: { store.werkzeug == .lager },
                                 set: { actions?.setSimulationWerkzeug($0 ? .lager : .keins) })) {
                Label("Lager setzen", systemImage: "hand.tap")
            }
            .toggleStyle(.button)
            .help("Im Viewer eine Fläche oder einen Punkt anklicken (Esc beendet)")
            if let l = store.lagerEntwurf {
                GroupBox("Neues Lager") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(simKurz(l.teil)) · \(l.auf.titel)" + (l.ort.flaeche.map { " · Fläche \($0)" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("Art", selection: Binding(get: { l.art }, set: { a in
                            var x = l
                            x.art = a
                            actions?.setLagerEntwurf(x)
                        })) {
                            ForEach(SimLager.Art.allCases, id: \.self) { Text($0.titel).tag($0) }
                        }
                        Picker("Auf", selection: Binding(get: { l.auf }, set: { a in
                            var x = l
                            x.auf = a
                            actions?.setLagerEntwurf(x)
                        })) {
                            ForEach(SimLager.Auf.allCases, id: \.self) { a in
                                Text(a.titel).tag(a).disabled(a == .flaeche && l.ort.flaeche == nil)
                            }
                        }
                        if l.art == .gleitend {
                            GleitenWahl(gleiten: Binding(get: { l.gleiten }, set: { g in
                                var x = l
                                x.gleiten = g
                                actions?.setLagerEntwurf(x)
                            }), kanteWaehlen: store.kanteWaehlen, kanteAn: kanteAn)
                        }
                        LastfallWahl(titel: "Gilt für", szenarien: Binding(get: { l.szenarien }, set: { s in
                            var x = l
                            x.szenarien = s
                            actions?.setLagerEntwurf(x)
                        }), namen: store.stand?.alleNamen ?? [], gewaehlt: store.auswahl)
                        if l.art == .gleitend && l.ort.normale == nil && l.gleiten == nil {
                            Text("Gleitend braucht eine Fläche mit Normale oder eine Gleitrichtung").font(.caption)
                                .foregroundStyle(.red)
                        }
                        HStack {
                            Button("Übernehmen") { actions?.lagerEntwurfSpeichern() }
                                .keyboardShortcut(.defaultAction)
                                .disabled(l.art == .gleitend && l.ort.normale == nil && l.gleiten == nil)
                            Button("Verwerfen") { actions?.setLagerEntwurf(nil) }
                            Spacer()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            let alle = (store.stand?.lager ?? []) + (store.stand?.modellLager ?? [])
            GroupBox("Gesetzte Lager") {
                VStack(alignment: .leading, spacing: 4) {
                    if alle.isEmpty { Text("keine").font(.caption).foregroundStyle(.secondary) }
                    ForEach(alle) { l in
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(l.id) · \(l.art.titel) · \(simKurz(l.teil)) · \(l.auf.titel)").lineLimit(1)
                                Text(l.giltText + (l.art == .gleitend ? " · gleitet "
                                                   + (l.gleiten?.titel ?? "in der Fläche") : ""))
                                    .font(.caption)
                                    .foregroundStyle(l.giltFuer(store.auswahl) ? Color.secondary : Color.orange)
                                    .lineLimit(1)
                            }
                            if l.quelle == "modell" {
                                Text("model.py" + (l.zeile.map { " Z. \($0)" } ?? "")).font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 2)
                            SimZuordnungZeichen(zustand: l.zustand, text: l.zustandText)
                            if l.quelle != "modell" {
                                LagerLastfallMenue(lager: l, namen: store.stand?.alleNamen ?? [], actions: actions)
                                Button {
                                    actions?.simulationAendern([SimOp.lagerLoeschen(l.id)], fertig: nil)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        if l.zustand == .fehlt || l.zustand == .neu {
                            Text(l.zustandText).font(.caption).foregroundStyle(l.zustand == .fehlt ? .red : .orange)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let ab = store.stand?.abgeleitet, !ab.isEmpty {
                GroupBox("Abgeleitete Lager") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(ab) { a in
                            Toggle(isOn: Binding(get: { a.aktiv }, set: { an in
                                actions?.simulationAendern([SimOp.abgeleitet(a.id, aktiv: an)], fertig: nil)
                            })) {
                                Text(a.text).font(.caption).lineLimit(2)
                            }
                            .toggleStyle(.checkbox)
                            .disabled(a.ersetzt != nil)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
