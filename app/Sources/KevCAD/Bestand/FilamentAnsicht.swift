import AppKit
import KevCADCore
import SwiftUI

// Filament im Bereich „Bestand“ (Strang „Bestand Stufe 2“, BESTAND.md „Filament“): Spulen je Material mit Kennung,
// Gramm übrig von voll als Balken, Hersteller, Farbe und Ort; erfassen, ändern, entfernen mit denselben Feldern und
// Regeln wie MCP `bestand_eintragen` (geprüft und gebucht vom Kernel, jede Buchung lässt sich rückgängig machen).

/// Auswahl im Bestand für ein Material: „filament:petg“; „filament:“ ist die Zeile „Filament wird nicht geführt“.
enum FilamentAuswahl {
    static let praefix = "filament:"

    static func id(_ material: String) -> String { praefix + material }

    /// Material einer Auswahl (leer für die Hinweiszeile), nil für Lagerteile.
    static func material(_ auswahl: String?) -> String? {
        guard let a = auswahl, a.hasPrefix(praefix) else { return nil }
        return String(a.dropFirst(praefix.count))
    }
}

extension AppModel {
    /// Anzeigename eines Filaments: Katalog, sonst Rechnung des Kernels, sonst die id in Großbuchstaben.
    func filamentName(_ material: String) -> String {
        catalog?.material(material)?.name ?? bestandZustand.gebautFilament?.materialien[material] ?? material.uppercased()
    }

    /// Kaufspule eines Materials in g (`spule_g` im Katalog, sonst 1 kg wie der Kernel).
    func spuleG(_ material: String) -> Double {
        guard let m = catalog?.material(material), let j = try? JSONDecoder().decode(JSONValue.self, from: m.json),
              let g = j["spule_g"]?.doubleValue, g > 0
        else { return 1000 }
        return g
    }

    /// Druckbare Materialien aus dem Katalog (für Spulen), nach Namen.
    var druckMaterialien: [CatalogMaterial] {
        (catalog?.materials ?? []).filter { $0.druckbar && !$0.vorgeschlagen }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Materialien für die Filament-Zeilen im Bestand: erst die mit Spulen, dann die der Druckteile ohne Spule (wenn das
    /// Projekt Filament führt).
    var filamentMaterialienImBestand: [String] {
        guard let b = bestandZustand.bestand else { return [] }
        var out = b.filamentMaterialien
        if b.fuehrtFilament {
            for f in bestandZustand.zuschnitt?.filamentBestand ?? [] where !out.contains(f.material) {
                out.append(f.material)
            }
        }
        return out
    }
}

/// Blatt „Spule erfassen“ bzw. „Spule ändern“.
struct SpulenAnfrage: Identifiable, Equatable {
    var id = UUID()
    /// Zu ändernde Spule (nil: neue Spule).
    var kennung: String?
    /// Vorbelegtes Material bei einer neuen Spule.
    var material: String?
}

// MARK: - Liste

struct FilamentZeile: View {
    @ObservedObject var model: AppModel
    let material: String
    /// Für die Druckvorschau fehlt Filament (steht auf der Einkaufsliste).
    var kaufen = false

    private var spulen: [BestandSpule] { model.bestandZustand.bestand?.spulen(material: material) ?? [] }

    var body: some View {
        let summe = spulen.reduce(0) { $0 + $1.gramm }
        HStack(spacing: 9) {
            Image(systemName: "printer.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(spulen.isEmpty ? Color.secondary : MaterialKennzeichen.druckteil.color)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill((spulen.isEmpty ? Color.secondary : MaterialKennzeichen.druckteil.color).opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text("Filament \(model.filamentName(material))").fontWeight(.medium).lineLimit(1)
                Text(spulen.isEmpty ? "keine Spule"
                     : "\(KevFormat.mass(grams: summe)) auf \(KevFormat.count(spulen.count, one: "Spule", many: "Spulen"))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 4)
            if kaufen {
                Image(systemName: "cart")
                    .foregroundStyle(ZuschnittFarbe.kaufen.color)
                    .help("Für die Druckvorschau fehlt Filament (Einkaufsliste)")
            }
        }
        .padding(.vertical, 2)
        .help("Filament \(model.filamentName(material)) (\(material))")
    }
}

// MARK: - Detail

struct FilamentDetail: View {
    @ObservedObject var model: AppModel
    @ObservedObject var material: MaterialZustand
    let materialID: String
    @ObservedObject private var ui = BestandUI.shared

    private var spulen: [BestandSpule] { model.bestandZustand.bestand?.spulen(material: materialID) ?? [] }
    private var busy: Bool { model.bestandZustand.aktivitaet == .saving }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                kopf
                if spulen.isEmpty {
                    Text("Keine Spule im Bestand. Alles Filament für Druckteile aus \(model.filamentName(materialID)) "
                        + "steht dann auf der Einkaufsliste.")
                        .foregroundStyle(.secondary)
                } else {
                    tabelle
                    if spulen.count >= 2 {
                        Text("Verbraucht wird in dieser Reihenfolge: angebrochene Spulen mit wenig Filament zuerst, "
                            + "dann volle.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                bedarf
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var kopf: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "printer.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(MaterialKennzeichen.druckteil.color)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(MaterialKennzeichen.druckteil.color.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Filament \(model.filamentName(materialID))")
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                let summe = spulen.reduce(0) { $0 + $1.gramm }
                Text("\(materialID) · \(KevFormat.mass(grams: summe)) auf "
                    + KevFormat.count(spulen.count, one: "Spule", many: "Spulen")
                    + " · Kaufspule \(KevFormat.compact(model.spuleG(materialID), maxDigits: 1)) g")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                // Links unter dem Titel: rechts liegt bei schmalem Fenster der Inspektor darüber
                Button {
                    ui.spule = SpulenAnfrage(kennung: nil, material: materialID)
                } label: {
                    Label("Spule hinzufügen …", systemImage: "plus")
                }
                .fixedSize()
                .controlSize(.small)
                .padding(.top, 4)
                .disabled(busy || model.bestandActions == nil)
            }
            Spacer(minLength: 8)
        }
    }

    private var tabelle: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("")
                Text("Spule")
                Text("Übrig")
                Text("Hersteller")
                Text("Farbe")
                Text("Ort")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(spulen) { s in
                GridRow {
                    HStack(spacing: 2) {
                        Button {
                            ui.spule = SpulenAnfrage(kennung: s.kennung)
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .help("Spule ändern (Gramm, Name, Ort …)")
                        Button {
                            entfernen(s)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .help("Spule entfernen (leer oder weg); lässt sich rückgängig machen")
                    }
                    .buttonStyle(.borderless)
                    .disabled(busy)
                    VStack(alignment: .leading, spacing: 2) {
                        SpulenKennung(spule: s)
                        if s.bezeichnung != s.kennung {
                            Text(s.bezeichnung).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: 190, alignment: .leading)
                    .help(s.bezeichnung)
                    SpulenBalken(spule: s, breite: 96)
                    Text(s.hersteller ?? "–").foregroundStyle(s.hersteller == nil ? .tertiary : .primary).lineLimit(1)
                        .frame(maxWidth: 120, alignment: .leading)
                    Text(s.farbe ?? "–").foregroundStyle(s.farbe == nil ? .tertiary : .primary).lineLimit(1)
                        .frame(maxWidth: 90, alignment: .leading)
                    Text(s.ort ?? "–").foregroundStyle(s.ort == nil ? .tertiary : .primary).lineLimit(1)
                        .frame(maxWidth: 110, alignment: .leading)
                }
                .contextMenu {
                    Button("Ändern …") { ui.spule = SpulenAnfrage(kennung: s.kennung) }
                    Button("Kennung kopieren") { copyToPasteboard(s.kennung) }
                    Divider()
                    Button("Entfernen", role: .destructive) { entfernen(s) }
                }
            }
        }
    }

    private func entfernen(_ s: BestandSpule) {
        model.bestandActions?.saveBestandSpule(
            kennung: s.kennung, spule: nil, anzahl: nil,
            grund: "Spule \(s.kennung) (\(s.bezeichnung)) aus dem Bestand entfernt")
    }

    /// Bedarf der Druckvorschau (je Farbe, Strang „Rest Druck“), was zu kaufen ist, was „Gebaut“ von diesem Material
    /// abbuchen würde, und „Gedruckt …“ für die Platten dieses Materials.
    @ViewBuilder
    private var bedarf: some View {
        let daten = model.materialDaten
        let zeilen = daten.filament.filter { $0.material == materialID }
        let kauf = daten.lagerEinkauf.filter { $0.position.id == materialID && $0.position.einheit.hasPrefix("Spule ") }
        let gebaut = model.bestandZustand.gebautFilamentAktuell?.spulen.filter { $0.material == materialID } ?? []
        let platten = model.druck.vorschau?.platten.filter { $0.material.contains { $0.material == materialID } } ?? []
        if !zeilen.isEmpty || !kauf.isEmpty || !gebaut.isEmpty || !platten.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                ForEach(zeilen) { f in
                    Label("Druckvorschau" + (f.farbe.map { " \($0)" } ?? "") + ": \(KevFormat.mass(grams: f.gramm)) für "
                          + KevFormat.count(f.teile, one: "Teil", many: "Teile"), systemImage: "printer")
                }
                ForEach(kauf) { kauf in
                    Label("\(kauf.position.mengeText) × \(kauf.position.einheit) \(kauf.position.benennung) kaufen"
                          + (kauf.position.hinweis.map { " · \($0)" } ?? ""), systemImage: "cart")
                        .foregroundStyle(ZuschnittFarbe.kaufen.color)
                }
                if kauf.isEmpty && !zeilen.isEmpty && !spulen.isEmpty {
                    Label("Der Bestand reicht", systemImage: "checkmark.seal")
                        .foregroundStyle(MaterialKennzeichen.rest.color)
                }
                if !platten.isEmpty {
                    HStack(spacing: 8) {
                        Button {
                            ui.gedruckt = GedrucktAnfrage(material: materialID)
                        } label: {
                            Label("Gedruckt …", systemImage: "checkmark.circle")
                        }
                        .controlSize(.small)
                        .disabled(busy || model.bestandActions == nil)
                        Text("bucht das Filament gedruckter Platten von den Spulen ab")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !gebaut.isEmpty {
                    Label("„Gebaut“ bucht ab: " + gebaut.map { "\(KevFormat.mass(grams: $0.gramm)) von \($0.kennung)" }
                        .joined(separator: ", "), systemImage: "hammer")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .monospacedDigit()
        }
    }
}

/// Hinweis, wenn das Projekt kein Filament führt (Auswahl „filament:“).
struct FilamentNichtGefuehrt: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var ui = BestandUI.shared

    var body: some View {
        ContentUnavailableView {
            Label("Filament wird nicht geführt", systemImage: "printer")
        } description: {
            Text("Trage die Spulen ein, die du für dieses Projekt hast. Dann rechnet die Einkaufsliste die fehlenden "
                + "Spulen gegen die Druckvorschau, und „Gedruckt“ bzw. „Gebaut“ buchen das Filament ab.")
        } actions: {
            Button("Spule aufnehmen …") { ui.spule = SpulenAnfrage() }
                .buttonStyle(.borderedProminent)
            Button("Kein Filament da") {
                model.bestandActions?.fuehreFilament(grund: "Filament führen, keine Spule da")
            }
            .help("Filament führen, ohne Spule: alles Filament der Druckvorschau steht auf der Einkaufsliste")
        }
        .disabled(model.bestandActions == nil || model.bestandZustand.aktivitaet == .saving)
    }
}

// MARK: - Bausteine

/// Kennung mit Zustand („voll“, „angebrochen“).
struct SpulenKennung: View {
    let spule: BestandSpule

    var body: some View {
        HStack(spacing: 4) {
            Text(spule.kennung)
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(MaterialKennzeichen.druckteil.color)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(MaterialKennzeichen.druckteil.color.opacity(0.14)))
            SpulenZustandMarke(zustand: spule.zustand)
        }
        .fixedSize()
    }
}

struct SpulenZustandMarke: View {
    let zustand: BestandSpule.Zustand

    var body: some View {
        Text(zustand.titel)
            .font(.caption2.weight(.medium))
            .foregroundStyle(farbe)
            .help(zustand == .voll ? "Volle Spule" : (zustand == .angebrochen ? "Angebrochene Spule, wird zuerst verbraucht"
                : "Leer"))
    }

    private var farbe: Color {
        switch zustand {
        case .voll: return MaterialKennzeichen.rest.color
        case .angebrochen: return .orange
        case .leer: return .secondary
        }
    }
}

/// Gramm übrig von voll als Balken mit Zahl.
struct SpulenBalken: View {
    let spule: BestandSpule
    var breite: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(farbe)
                    .frame(width: max(spule.gramm > 0 ? 3 : 0, breite * CGFloat(spule.anteil ?? 1)))
            }
            .frame(width: breite, height: 7)
            Text(kurz).font(.caption).monospacedDigit().lineLimit(1).fixedSize()
        }
        .help(spule.mengeText + (spule.anteil.map { " · \(Int(($0 * 100).rounded())) % übrig" } ?? ""))
    }

    /// „120 / 1.000 g“.
    private var kurz: String {
        let g = KevFormat.compact(spule.gramm, maxDigits: 1)
        return spule.grammVoll.map { "\(g) / \(KevFormat.compact($0, maxDigits: 1)) g" } ?? "\(g) g"
    }

    private var farbe: Color {
        guard let a = spule.anteil else { return MaterialKennzeichen.druckteil.color }
        return a < 0.15 ? .orange : MaterialKennzeichen.druckteil.color
    }
}

// MARK: - Erfassen und ändern

struct SpuleSheet: View {
    @ObservedObject var model: AppModel
    let anfrage: SpulenAnfrage
    @Environment(\.dismiss) private var dismiss
    @State private var eingabe = SpulenEingabe(material: "")
    @State private var gramm = ""
    @State private var grammVoll = ""
    @State private var anzahl = 1
    @State private var bereit = false

    private var vorher: BestandSpule? {
        anfrage.kennung.flatMap { k in model.bestandZustand.bestand?.spulen.first { $0.kennung == k } }
    }

    private var aktuell: SpulenEingabe {
        var e = eingabe
        e.gramm = gramm.trimmingCharacters(in: .whitespaces).isEmpty ? nil : KevFormat.parseNumber(gramm)
        e.grammVoll = KevFormat.parseNumber(grammVoll)
        return e
    }

    private var fehler: String? {
        if !gramm.trimmingCharacters(in: .whitespaces).isEmpty && KevFormat.parseNumber(gramm) == nil {
            return "Gramm übrig ist keine Zahl"
        }
        if KevFormat.parseNumber(grammVoll) == nil { return "Gramm voll ist keine Zahl" }
        if vorher == nil, let g = aktuell.gramm, g <= 0 { return "Leere Spulen nicht eintragen" }
        return aktuell.fehler
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "printer.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(MaterialKennzeichen.druckteil.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vorher.map { "Spule \($0.kennung) ändern" } ?? "Spule aufnehmen")
                        .font(.title3.weight(.semibold))
                    Text("Filament, das du für dieses Projekt hast. Die Kennung vergibt SK-CAD.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            Divider()
            Form {
                Picker("Material", selection: $eingabe.material) {
                    if eingabe.material.isEmpty { Text("Wählen …").tag("") }
                    ForEach(materialien, id: \.id) { m in Text(m.name).tag(m.id) }
                }
                .onChange(of: eingabe.material) { _, m in
                    if vorher == nil, !m.isEmpty { grammVoll = KevFormat.input(model.spuleG(m)) }
                }
                TextField("Name", text: $eingabe.name, prompt: Text("z. B. Bambu PETG Basic schwarz"))
                TextField("Hersteller", text: $eingabe.hersteller, prompt: Text("z. B. Bambu Lab"))
                TextField("Farbe", text: $eingabe.farbe, prompt: Text("z. B. schwarz"))
                LabeledContent("Gramm übrig") {
                    HStack {
                        TextField("", text: $gramm, prompt: Text(vorher == nil ? "leer: volle Spule" : ""))
                            .multilineTextAlignment(.trailing)
                        Text("g").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Gramm voll") {
                    HStack {
                        TextField("", text: $grammVoll).multilineTextAlignment(.trailing)
                        Text("g").foregroundStyle(.secondary)
                    }
                }
                TextField("Ort", text: $eingabe.ort, prompt: Text("z. B. Regal 3"))
                if vorher == nil {
                    Stepper("Anzahl gleicher Spulen: \(anzahl)", value: $anzahl, in: 1...50)
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 380)
            Divider()
            HStack(spacing: 10) {
                if let f = fehler, bereit {
                    Label(f, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                } else {
                    Text("Wird gebucht und lässt sich rückgängig machen.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(vorher == nil ? "Eintragen" : "Übernehmen", action: sichern)
                    .keyboardShortcut(.defaultAction)
                    .disabled(fehler != nil || model.bestandActions == nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 460)
        .onAppear(perform: vorbelegen)
    }

    private var materialien: [CatalogMaterial] {
        var m = model.druckMaterialien
        // Material einer vorhandenen Spule zeigen, auch wenn es nicht (mehr) im Katalog steht
        if !eingabe.material.isEmpty, !m.contains(where: { $0.id == eingabe.material }) {
            m.insert(CatalogMaterial(id: eingabe.material, name: model.filamentName(eingabe.material), gruppe: "",
                                     dichte: 0, farbe: "", ebene: .projekt), at: 0)
        }
        return m
    }

    private func vorbelegen() {
        if let s = vorher {
            eingabe = SpulenEingabe(s)
            gramm = KevFormat.input(s.gramm)
            grammVoll = KevFormat.input(s.grammVoll ?? model.spuleG(s.material))
        } else {
            let m = anfrage.material ?? model.filamentMaterialienImBestand.first ?? ""
            eingabe = SpulenEingabe(material: m)
            grammVoll = KevFormat.input(model.spuleG(m.isEmpty ? "pla" : m))
        }
        if model.catalog == nil { model.catalogActions?.requestCatalog(query: nil, art: nil) }
        bereit = true
    }

    private func sichern() {
        let e = aktuell
        let name = model.filamentName(e.material)
        if let s = vorher {
            model.bestandActions?.saveBestandSpule(kennung: s.kennung, spule: e, anzahl: nil,
                                                   grund: "Spule \(s.kennung) (\(name)) geändert")
        } else {
            let menge = e.gramm.map { KevFormat.compact($0, maxDigits: 1) + " g" } ?? "voll"
            let bez = e.name.isEmpty ? "" : " „\(e.name)“"
            model.bestandActions?.saveBestandSpule(
                kennung: nil, spule: e, anzahl: anzahl,
                grund: "Filament \(name): \(KevFormat.count(anzahl, one: "Spule", many: "Spulen"))\(bez) (\(menge))")
        }
        dismiss()
    }
}

// MARK: - Einkauf: Spulen je Material

/// Spulen eines Materials kurz für die Einkaufsliste: ab zwei Spulen jede mit Zustand (angebrochen, voll).
struct SpulenKurz: View {
    let spulen: [BestandSpule]

    var body: some View {
        if spulen.count >= 2 {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(spulen) { s in
                    HStack(spacing: 6) {
                        Text(s.kennung).monospacedDigit()
                        SpulenZustandMarke(zustand: s.zustand)
                        Text(KevFormat.mass(grams: s.gramm)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .help(s.bezeichnung)
                }
            }
            .font(.caption)
        } else if let s = spulen.first {
            HStack(spacing: 6) {
                Text("Bestand \(s.kennung)").monospacedDigit()
                SpulenZustandMarke(zustand: s.zustand)
                Text(KevFormat.mass(grams: s.gramm)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }
}
