import KevCADCore
import SwiftUI

/// Titel, Anleitungstext und Hinweise eines Schritts bearbeiten (BAUPLAN_EDIT `text`, Quelle „kevin“: bleibt bei
/// neuen Läufen erhalten).
struct BauplanTextBlatt: View {
    let schritt: BauplanSchritt
    let speichern: (String, String, [String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var titel = ""
    @State private var text = ""
    @State private var hinweise = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Schritt bearbeiten").font(.title3.weight(.semibold))
            Text("Deine Texte bleiben bei neuen Läufen erhalten. Maße und Anzahlen kommen aus dem Modell.")
                .font(.callout).foregroundStyle(.secondary)
            LabeledContent("Titel") {
                TextField("Titel", text: $titel).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Anleitung").font(.callout.weight(.medium))
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 110)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Hinweise (einer je Zeile; Sicherheit wird gelb hervorgehoben)").font(.callout.weight(.medium))
                TextEditor(text: $hinweise)
                    .font(.body)
                    .frame(minHeight: 80)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            }
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Sichern") {
                    let h = hinweise.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    speichern(titel.trimmingCharacters(in: .whitespaces), text, h)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(titel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear {
            titel = schritt.titel
            text = schritt.text
            hinweise = schritt.hinweise.joined(separator: "\n")
        }
    }
}

/// Schritt teilen: die gewählten Teile kommen in einen neuen Schritt direkt danach (beide fest).
struct BauplanTeilenBlatt: View {
    let schritt: BauplanSchritt
    let teilen: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var gewaehlt = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Schritt teilen").font(.title3.weight(.semibold))
            Text("Die angekreuzten Teile kommen in einen neuen Schritt direkt nach „\(schritt.titel)“.")
                .font(.callout).foregroundStyle(.secondary)
            List(schritt.teile, id: \.self) { t in
                Toggle(isOn: Binding(get: { gewaehlt.contains(t) },
                                     set: { if $0 { gewaehlt.insert(t) } else { gewaehlt.remove(t) } })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(BauplanSchritt.kurzname(t))
                        Text(t).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 240)
            HStack {
                Text("\(gewaehlt.count) von \(schritt.teile.count)").foregroundStyle(.secondary)
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Teilen") {
                    teilen(schritt.teile.filter(gewaehlt.contains))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(gewaehlt.isEmpty || gewaehlt.count == schritt.teile.count)
            }
        }
        .padding(22)
        .frame(width: 520, height: 460)
    }
}

/// Reihenfolge „a vor b“ eintragen (bei mehreren gleichwertigen Folgen entscheidet Kevin; bleibt bei neuen Läufen).
struct BauplanRegelBlatt: View {
    let plan: Bauplan
    let schritt: BauplanSchritt
    let eintragen: (String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var vorher = true
    @State private var anderer: String = ""
    @State private var grund = ""

    private var montage: [BauplanSchritt] { (plan.montage?.schritte ?? []).filter { $0.id != schritt.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Reihenfolge festlegen").font(.title3.weight(.semibold))
            HStack {
                Text("„\(schritt.titel)“")
                Picker("", selection: $vorher) {
                    Text("vor").tag(true)
                    Text("nach").tag(false)
                }
                .labelsHidden()
                .fixedSize()
            }
            Picker("Schritt", selection: $anderer) {
                ForEach(montage) { s in
                    Text("\(plan.nummer(s.id) ?? 0)  \(s.titel)").tag(s.id)
                }
            }
            TextField("Grund (z. B. „erst das Gestell ausrichten“)", text: $grund)
                .textFieldStyle(.roundedBorder)
            Text("SK-CAD rechnet die Montagefolge danach neu und prüft sie in der Simulation.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Eintragen") {
                    if vorher { eintragen(schritt.id, anderer, grund) } else { eintragen(anderer, schritt.id, grund) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(anderer.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear { anderer = montage.first?.id ?? "" }
    }
}

/// Leiste über dem 3D-Bereich während des Durchspielens: Schritt x von y, Titel, vor und zurück, Abspielen, Tempo,
/// Ende. Erscheint nur, solange `BauplanStore.durchspielen` gesetzt ist.
struct DurchspielenLeiste: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: BauplanStore

    init(model: AppModel) {
        self.model = model
        self.store = model.bauplan
    }

    var body: some View {
        // Mittig über die Breite des 3D-Bereichs (die Versionsleiste nimmt ihren eigenen Platz, ProjectWindow), breit
        // höchstens 760 pt; schmal kürzt sie den Titel statt über den Rand zu laufen.
        GeometryReader { geo in
            leiste
                .frame(width: max(240, min(760, geo.size.width - 32)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .allowsHitTesting(store.durchspielen != nil)
    }

    @ViewBuilder
    private var leiste: some View {
        if let d = store.durchspielen, let plan = store.plan, let id = d.schritt, let s = plan.schritt(id) {
            VStack(spacing: 10) {
                // breit: alles in einer Zeile; schmal (Versionsleiste, Stückliste offen): Titel und Steuerung getrennt
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        titel(d, plan, id, s)
                        Spacer(minLength: 16)
                        problem(s)
                        steuerung(d)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        titel(d, plan, id, s)
                        HStack(spacing: 10) {
                            problem(s)
                            Spacer(minLength: 0)
                            steuerung(d)
                        }
                    }
                }
                fortschritt(d, plan)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
            .padding(.bottom, 44)  // über dem Maßstabsbalken des 3D-Bereichs
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var actions: BauplanActions? { model.bauplanActions }

    private func titel(_ d: BauplanDurchspielen, _ plan: Bauplan, _ id: String, _ s: BauplanSchritt) -> some View {
        HStack(spacing: 12) {
            BauplanNummer(nummer: plan.nummer(id) ?? 0, groesse: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.titel).font(.headline).lineLimit(1)
                Text("Montageschritt \(d.index + 1) von \(d.schritte.count)"
                     + (s.baugruppe.map { " · Vormontage \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .layoutPriority(-1)
            if s.anzahl > 1 { BauplanMengenMarke(anzahl: s.anzahl) }
        }
    }

    @ViewBuilder
    private func problem(_ s: BauplanSchritt) -> some View {
        if let w = s.schwersterBefund, w != .hinweis {
            Button {
                if let b = s.probleme.first { actions?.bauplanZeigen(teile: b.teile, ort: b.ort) }
            } label: {
                Label(KevFormat.count(s.probleme.count, one: "Problem", many: "Probleme"), systemImage: w.symbol)
                    .foregroundStyle(w.farbe)
            }
            .buttonStyle(.borderless)
            .help(s.probleme.map(\.text).joined(separator: "\n"))
        }
    }

    private func steuerung(_ d: BauplanDurchspielen) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Button { actions?.durchspielenGeheZu(0) } label: { Image(systemName: "backward.end.fill") }
                    .help("Zum ersten Schritt")
                Button { actions?.durchspielenSchritt(-1) } label: { Image(systemName: "backward.fill") }
                    .help("Voriger Schritt (⌥⌘←)")
                Button { actions?.durchspielenAbspielen(!d.spielt) } label: {
                    Image(systemName: d.spielt ? "pause.fill" : "play.fill").frame(width: 18)
                }
                .help(d.spielt ? "Anhalten" : "Abspielen")
                Button { actions?.durchspielenSchritt(1) } label: { Image(systemName: "forward.fill") }
                    .help("Nächster Schritt (⌥⌘→)")
                Button { actions?.durchspielenGeheZu(d.schritte.count - 1) } label: { Image(systemName: "forward.end.fill") }
                    .help("Zum letzten Schritt")
            }
            .buttonStyle(.borderless)
            .font(.title3)
            Menu {
                ForEach([0.5, 1.0, 1.5, 2.0, 3.0], id: \.self) { t in
                    Button("\(KevFormat.compact(t, maxDigits: 1))×") { actions?.durchspielenTempo(t) }
                }
            } label: {
                Text("\(KevFormat.compact(d.tempo, maxDigits: 1))×").monospacedDigit()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Tempo")
            Button { actions?.durchspielenBeenden() } label: {
                Image(systemName: "xmark.circle.fill").font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Durchspielen beenden: alle Teile wieder zeigen (⌥⌘.)")
        }
        .fixedSize()
    }

    /// Je Schritt ein Segment, der aktuelle füllt sich beim Einfahren; Klick springt hin.
    private func fortschritt(_ d: BauplanDurchspielen, _ plan: Bauplan) -> some View {
        GeometryReader { geo in
            let n = max(1, d.schritte.count)
            let w = max(1, (geo.size.width - CGFloat(n - 1) * 2) / CGFloat(n))
            HStack(spacing: 2) {
                ForEach(0..<n, id: \.self) { i in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule().fill(Color.kevAkzent)
                            .frame(width: i < d.index ? w : i == d.index ? w * d.fortschritt : 0)
                    }
                    .frame(width: w)
                    .contentShape(Rectangle())
                    .onTapGesture { actions?.durchspielenGeheZu(i) }
                    .help(plan.schritt(d.schritte[i])?.titel ?? "")
                }
            }
        }
        .frame(height: 5)
    }
}
