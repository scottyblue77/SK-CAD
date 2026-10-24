import KevCADCore
import SwiftUI

/// Dialog „Gebaut …“: Vorschau der Buchung (was aus dem Bestand weg geht, welche Reste neu entstehen, welche
/// Druckplatten Filament abbuchen) und Bestätigung. Gebucht wird erst mit „Gebaut buchen“ (GEBAUT_REQ); danach erscheint
/// ein Hinweis mit „Rückgängig“.
///
/// Strang „Rest Druck“: Bei vielen Posten lagen die Druckplatten unter dem sichtbaren Bereich. Jetzt steht oben eine
/// Zusammenfassung (Kacheln je Abschnitt, ein Klick klappt den Abschnitt auf und springt hin), darunter die Abschnitte
/// zum Ein- und Ausklappen; lange Listen sind anfangs zu, die Druckplatten immer offen.
struct GebautDialog: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var offen: Set<Abschnitt> = []
    @State private var vorbelegt = false

    /// Abschnitte in der Reihenfolge der Anzeige.
    enum Abschnitt: String, CaseIterable, Hashable {
        case weg, platten, neu, kaufen, verschnitt

        var titel: String {
            switch self {
            case .weg: return "Wird aus dem Bestand abgebucht"
            case .platten: return "Druckplatten"
            case .neu: return "Kommt neu in den Bestand"
            case .kaufen: return "Vorausgesetzt gekauft"
            case .verschnitt: return "Verschnitt"
            }
        }

        var kurz: String {
            switch self {
            case .weg: return "Abbuchen"
            case .platten: return "Druckplatten"
            case .neu: return "Neu"
            case .kaufen: return "Gekauft"
            case .verschnitt: return "Verschnitt"
            }
        }

        var symbol: String {
            switch self {
            case .weg: return "minus.circle.fill"
            case .platten: return "printer.fill"
            case .neu: return "plus.circle.fill"
            case .kaufen: return "cart.fill"
            case .verschnitt: return "trash.circle.fill"
            }
        }

        var farbe: Color {
            switch self {
            case .weg: return .red
            case .platten: return MaterialKennzeichen.druckteil.color
            case .neu: return ZuschnittFarbe.restNeu.color
            case .kaufen: return ZuschnittFarbe.kaufen.color
            case .verschnitt: return ZuschnittFarbe.verschnitt.color
            }
        }

        /// So viele Zeilen zeigt ein Abschnitt anfangs offen; längere sind zu (die Zusammenfassung nennt die Zahl).
        static let offenBis = 6
    }

    private var vorschau: GebautVorschau? {
        guard let z = model.bestandZustand.zuschnitt else { return nil }
        return GebautVorschau.berechnen(
            zuschnitt: z, bestand: model.bestandZustand.bestand, lines: model.bom?.lines ?? [],
            name: { model.catalog?.item($0)?.name }, filament: model.bestandZustand.gebautFilamentAktuell)
    }

    /// Das Projekt führt Filament, die Rechnung des Kernels gehört aber noch nicht zur aktuellen Stückliste.
    private var filamentWartet: Bool {
        model.bestandZustand.bestand?.fuehrtFilament == true && model.bestandZustand.gebautFilamentAktuell == nil
    }

    private var sperre: String? {
        if model.bestandActions == nil { return "Buchen geht nur mit verbundenem Kernel." }
        if model.laufAktiv { return "Das Modell wird gerade neu gerechnet. Warte auf die neue Stückliste." }
        if model.bestandZustand.zuschnitt == nil { return "Der Kernel schickt noch keinen Zuschnitt mit Bestand." }
        if !model.bestandZustand.hatBuchbares && (vorschau?.leer ?? true) {
            return "Der Zuschnitt verplant nichts aus dem Bestand und es ist kein Filament abzubuchen."
        }
        return nil
    }

    private func zeilen(_ a: Abschnitt, _ v: GebautVorschau) -> [GebautVorschau.Zeile] {
        switch a {
        case .weg: return v.weg
        case .platten: return v.platten
        case .neu: return v.neu
        case .kaufen: return v.kaufen
        case .verschnitt: return v.verschnitt
        }
    }

    /// Abschnitte, die es gibt (Abbuchen und Neu immer, die übrigen nur mit Inhalt).
    private func abschnitte(_ v: GebautVorschau) -> [Abschnitt] {
        Abschnitt.allCases.filter { a in a == .weg || a == .neu || !zeilen(a, v).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            kopf
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)
            if let v = vorschau {
                ScrollViewReader { leser in
                    VStack(spacing: 0) {
                        zusammenfassung(v, leser)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                        Divider()
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(abschnitte(v), id: \.self) { a in
                                    abschnitt(a, zeilen(a, v)).id(a)
                                }
                                if let h = v.filamentHinweis {
                                    Label(h, systemImage: "info.circle").foregroundStyle(.secondary)
                                } else if filamentWartet {
                                    Label("Filament: Die Druckvorschau zu dieser Stückliste wird noch gerechnet; gebucht "
                                          + "wird trotzdem, was der Kernel beim Buchen findet.", systemImage: "hourglass")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 160, idealHeight: 340, maxHeight: 480)
                    }
                }
                .onAppear { vorbelegen(v) }
            } else {
                Divider()
                Text("Der Kernel schickt noch keinen Zuschnitt mit Bestand.")
                    .foregroundStyle(.secondary)
                    .padding(20)
            }
            Divider()
            fuss
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 560)
    }

    /// Kurze Listen offen, lange zu, Druckplatten immer offen (einmal beim Öffnen).
    private func vorbelegen(_ v: GebautVorschau) {
        guard !vorbelegt else { return }
        vorbelegt = true
        offen = Set(abschnitte(v).filter { $0 == .platten || zeilen($0, v).count <= Abschnitt.offenBis })
    }

    private var kopf: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "hammer.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("„\(model.project?.name ?? "Projekt")“ als gebaut buchen?")
                    .font(.title3.weight(.semibold))
                Text("SK-CAD bucht ab, was der Zuschnitt aus dem Bestand dieses Projekts verplant, und legt die neuen "
                    + "Reste mit Kennung an."
                    + (model.bestandZustand.bestand?.fuehrtFilament == true
                        ? " Das Filament der noch nicht gedruckt gebuchten Platten geht von den Spulen ab." : "")
                    + (model.bom.map { " Stand: Stückliste von Lauf \($0.run)." } ?? ""))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Zusammenfassung

    private func zusammenfassung(_ v: GebautVorschau, _ leser: ScrollViewProxy) -> some View {
        let liste = abschnitte(v)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Auf einen Blick").font(.headline)
                Spacer()
                Button(offen.count == liste.count ? "Alle zuklappen" : "Alle aufklappen") {
                    withAnimation(.snappy(duration: 0.2)) {
                        offen = offen.count == liste.count ? [] : Set(liste)
                    }
                }
                .buttonStyle(.link)
                .font(.callout)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 8)], alignment: .leading,
                      spacing: 8) {
                ForEach(liste, id: \.self) { a in
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { _ = offen.insert(a) }
                        DispatchQueue.main.async { withAnimation { leser.scrollTo(a, anchor: .top) } }
                    } label: {
                        kachel(a, v)
                    }
                    .buttonStyle(.plain)
                    .help("\(a.titel): aufklappen und hinspringen")
                }
            }
        }
    }

    private func kachel(_ a: Abschnitt, _ v: GebautVorschau) -> some View {
        let z = zeilen(a, v)
        return HStack(spacing: 8) {
            Image(systemName: a.symbol)
                .foregroundStyle(a.farbe)
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 1) {
                Text(a.kurz).font(.caption).foregroundStyle(.secondary)
                Text(kachelText(a, z)).font(.callout.weight(.medium)).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(a.farbe.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(a.farbe.opacity(0.22)))
        .contentShape(Rectangle())
    }

    private func kachelText(_ a: Abschnitt, _ z: [GebautVorschau.Zeile]) -> String {
        switch a {
        case .platten:
            let gebucht = z.filter(\.gebucht).count
            let jetzt = z.count - gebucht
            return [jetzt > 0 ? "\(jetzt) jetzt" : nil, gebucht > 0 ? "\(gebucht) gedruckt" : nil]
                .compactMap { $0 }.joined(separator: ", ")
        case .weg:
            return z.isEmpty ? "nichts" : KevFormat.count(z.count, one: "Posten", many: "Posten")
        case .neu:
            return z.isEmpty ? "nichts" : KevFormat.count(z.count, one: "Eintrag", many: "Einträge")
        case .kaufen, .verschnitt:
            return KevFormat.count(z.count, one: "Position", many: "Positionen")
        }
    }

    // MARK: Abschnitte

    private func abschnitt(_ a: Abschnitt, _ zeilen: [GebautVorschau.Zeile]) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { offen.contains(a) }, set: { an in
            if an { offen.insert(a) } else { offen.remove(a) }
        })) {
            VStack(alignment: .leading, spacing: 6) {
                if zeilen.isEmpty {
                    Text(a == .weg ? "Nichts aus dem Bestand verplant." : "Es entstehen keine Reste ab Mindestrest.")
                        .foregroundStyle(.secondary)
                }
                ForEach(zeilen) { z in
                    if a == .platten { plattenZeile(z) } else { zeile(z) }
                }
            }
            .padding(.top, 6)
            .padding(.leading, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: a.symbol).foregroundStyle(a.farbe)
                Text(a.titel).fontWeight(.semibold)
                Text("\(zeilen.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.snappy(duration: 0.2)) {
                    if offen.contains(a) { offen.remove(a) } else { offen.insert(a) }
                }
            }
        }
    }

    private func zeile(_ z: GebautVorschau.Zeile) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(z.text).monospacedDigit()
                Text(z.teil).foregroundStyle(.secondary).lineLimit(1)
            }
            if let h = z.hinweis {
                Text(h).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Druckplatte: wird jetzt abgebucht oder ist schon als gedruckt gebucht (Filament nicht doppelt).
    private func plattenZeile(_ z: GebautVorschau.Zeile) -> some View {
        HStack(spacing: 6) {
            Image(systemName: z.gebucht ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(z.gebucht ? Color.green : Color.secondary)
            Text(z.text).monospacedDigit()
            Text(z.teil).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            if let h = z.hinweis {
                Text("· \(h)").font(.caption).foregroundStyle(z.gebucht ? Color.green : Color.secondary)
            }
        }
        .help(z.gebucht ? "Das Filament dieser Platte ist schon gebucht und wird nicht noch einmal abgezogen"
            : "Das Filament dieser Platte wird mit „Gebaut“ abgebucht")
    }

    private var fuss: some View {
        HStack(spacing: 10) {
            if let s = sperre {
                Label(s, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("Lässt sich danach rückgängig machen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Abbrechen", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Gebaut buchen") {
                model.bestandActions?.bucheGebaut()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(sperre != nil)
        }
    }
}
