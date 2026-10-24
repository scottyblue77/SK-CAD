import AppKit
import KevCADCore
import SwiftUI
import UniformTypeIdentifiers

// Phase 4: Referenzen in der Oberfläche. Abschnitt „Referenzen“ im Inspektor (Zustand, Netz, Abweichung, Fotos,
// Messergebnis mit Sigma, Hinweise, „Maße übernehmen“, „Maßstab …“, Scans vom iPhone), Dialog „Referenz hinzufügen“
// (nach Drag and Drop oder über +), Dialog „Vermessen“, Dialog „Maßstab“. Die Oberfläche liest nur `model.referenzen` und
// ruft `ReferenzActions`; Legende, Band und Leiste im Viewport stehen in ReferenzRestAnsichten.swift.

extension AppModel {
    var referenzActions: ReferenzActions? { actions as? ReferenzActions }
}

enum ReferenzDateien {
    static let videoEndungen: Set<String> = ["mov", "mp4", "m4v"]
    static let fotoEndungen: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"]

    static func passend(_ urls: [URL]) -> [URL] {
        urls.filter { videoEndungen.contains($0.pathExtension.lowercased()) || fotoEndungen.contains($0.pathExtension.lowercased()) }
    }

    static func istVideo(_ url: URL) -> Bool { videoEndungen.contains(url.pathExtension.lowercased()) }

    /// Dateien aus einem Drop (Finder liefert Datei-URLs).
    static func laden(_ provider: [NSItemProvider], fertig: @escaping @MainActor ([URL]) -> Void) -> Bool {
        let passende = provider.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !passende.isEmpty else { return false }
        let gruppe = DispatchGroup()
        let sammler = URLSammler()
        for p in passende {
            gruppe.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { sammler.add(url) }
                gruppe.leave()
            }
        }
        gruppe.notify(queue: .main) {
            MainActor.assumeIsolated { fertig(passend(sammler.alle)) }
        }
        return true
    }

    /// Dialog „Video oder Fotos wählen“.
    @MainActor
    static func waehlen() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Referenz hinzufügen"
        panel.message = "Ein Handyvideo des Gegenstands oder einige Fotos wählen"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .jpeg, .png, .heic, .tiff]
        return panel.runModal() == .OK ? passend(panel.urls) : []
    }
}

private final class URLSammler: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func add(_ u: URL) {
        lock.lock()
        urls.append(u)
        lock.unlock()
    }
    var alle: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}

/// Abschnitt „Referenzen“ im Inspektor.
struct ReferenzInspectorSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: ReferenzStore
    @ObservedObject var state: ProjectWindowState
    @State private var ueber = false

    var body: some View {
        Section {
            if store.referenzen.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keine Referenz")
                    Text("Handyvideo oder Fotos des echten Gegenstands auf das Fenster ziehen: SK-CAD legt ein "
                        + "Referenznetz in die Szene und misst die Maße von model.py.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
            ForEach(store.referenzen) { r in
                ReferenzZeile(model: model, store: store, state: state, referenz: r)
            }
            ScanListeAbschnitt(store: store, actions: model.referenzActions)  // Scans vom iPhone
            if let m = store.meldung {
                Text(m)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            HStack {
                Text("Referenzen")
                Spacer()
                Button {
                    let urls = ReferenzDateien.waehlen()
                    if !urls.isEmpty { state.referenzDateien = urls }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Video oder Fotos als Referenz hinzufügen")
                .disabled(model.referenzActions == nil)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $ueber) { provider in
            ReferenzDateien.laden(provider) { urls in if !urls.isEmpty { state.referenzDateien = urls } }
        }
    }
}

private struct ReferenzZeile: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: ReferenzStore
    @ObservedObject var state: ProjectWindowState
    let referenz: ReferenzInfo
    @State private var uebernehmenFragen = false

    private var actions: ReferenzActions? { model.referenzActions }
    private var ergebnis: ReferenzErgebnis? { store.ergebnisse[referenz.name] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            kopf
            if referenz.zustand == .rechnet {
                ProgressView(value: referenz.fortschritt ?? 0) {
                    if referenz.istScan && referenz.laeuft == "capture" {
                        // Scan vom iPhone: Phase und Fortschritt statt „Object Capture“
                        HStack {
                            Text("Scan wird ausgewertet …").fontWeight(.medium)
                            Spacer()
                            Text("\(Int(((referenz.fortschritt ?? 0) * 100).rounded())) %").monospacedDigit()
                        }
                        .font(.caption)
                    } else {
                        Text(referenz.text ?? (referenz.laeuft == "capture" ? "Object Capture" : "Vermessen"))
                            .font(.caption)
                    }
                } currentValueLabel: {
                    if referenz.istScan && referenz.laeuft == "capture" {
                        Text([referenz.phase, referenz.text.map { $0.hasPrefix("Scan: ") ? String($0.dropFirst(6)) : $0 }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2)
                            .lineLimit(1)
                    }
                }
                .progressViewStyle(.linear)
                .controlSize(.small)
            }
            if let m = referenz.meldung, referenz.zustand == .fehler {
                Label(m, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if referenz.netz { netz }
            ReferenzAbweichungZeile(store: store, referenz: referenz, actions: actions)  // Farbkarte und Kennzahlen
            if !store.fotos(referenz.name).isEmpty { fotos }
            if let e = ergebnis { ReferenzErgebnisTabelle(ergebnis: e, params: store.params) }
            knoepfe
        }
        .padding(.vertical, 3)
        .confirmationDialog(
            "Gemessene Maße in model.py übernehmen?", isPresented: $uebernehmenFragen, titleVisibility: .visible
        ) {
            Button("Übernehmen") {
                if let e = ergebnis {
                    actions?.referenzMasseUebernehmen(
                        referenz.name, werte: Dictionary(uniqueKeysWithValues: e.masse.map { ($0.name, $0.gerundet) }))
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            if let e = ergebnis {
                Text(e.masse.map { m in
                    "\(m.name): \(m.start.map { KevFormat.number($0, digits: 1) } ?? "–") → \(KevFormat.number(m.gerundet, digits: 1)) mm"
                }.joined(separator: "\n") + "\n\nDer Vorgabewert in param(…) wird ersetzt, danach rechnet SK-CAD neu.")
            }
        }
    }

    private var kopf: some View {
        HStack(spacing: 6) {
            Image(systemName: referenz.istScan ? "iphone.gen3" : referenz.istVideo ? "video" : "photo.on.rectangle")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(referenz.name).fontWeight(.medium).lineLimit(1)
                Text(untertitel).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Menu {
                Button("Im Finder zeigen") { actions?.referenzImFinder(referenz.name) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var untertitel: String {
        var teile: [String] = []
        if referenz.istVideo || referenz.istScan {
            teile.append((referenz.quelle as NSString).lastPathComponent)
        } else {
            teile.append(referenz.quelle)
        }
        switch referenz.zustand {
        case .leer: teile.append("noch nicht gerechnet")
        case .rechnet: teile.append(referenz.laufText)
        case .fehler: teile.append("Fehler")
        case .fertig: break
        }
        return teile.joined(separator: " · ")
    }

    @ViewBuilder
    private var netz: some View {
        let sichtbar = !store.verborgen.contains(referenz.name)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Toggle(isOn: Binding(get: { sichtbar }, set: { actions?.referenzNetzZeigen(referenz.name, $0) })) {
                    Text("Netz")
                }
                .toggleStyle(.checkbox)
                Slider(
                    value: Binding(
                        get: { store.deckkraft(referenz.name) },
                        set: { actions?.referenzNetzDeckkraft(referenz.name, $0) }), in: 0.1...1
                )
                .controlSize(.mini)
                .disabled(!sichtbar)
                .help("Deckkraft des Referenznetzes")
            }
            if let h = referenz.captureHuelle {
                Text("Hülle mit Anbauten \(KevFormat.dimensions(h))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let g = referenz.captureGrundkoerper {
                Text("Grundkörper (ohne Anbauten) \(KevFormat.number(g.x, digits: 1)) × \(KevFormat.number(g.y, digits: 1)) mm")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let d = referenz.lageDrehung {
                Text("Am Modell angelegt (\(KevFormat.number(d, digits: 1))° um Z"
                    + (referenz.lageRest.map { ", Kameras \(KevFormat.number($0, digits: 0)) mm" } ?? "") + ")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var fotos: some View {
        let messung = store.fotoSatz(referenz.name, "messung")
        let capture = store.fotoSatz(referenz.name, "capture")
        return HStack(spacing: 8) {
            if !messung.isEmpty {
                Button("Fotoansicht (\(messung.count))") {
                    actions?.fotoansichtOeffnen(referenz.name, satz: "messung", index: 0)
                }
                .help("Fotos mit eingepasster Kamera hinter dem Modell, mit Differenz")
            }
            if !capture.isEmpty {
                Button(messung.isEmpty ? "Fotoansicht (\(capture.count))" : "Object Capture (\(capture.count))") {
                    actions?.fotoansichtOeffnen(referenz.name, satz: "capture", index: 0)
                }
                .help("Bilder von Object Capture durch dessen Kameras")
            }
        }
        .controlSize(.small)
    }

    private var knoepfe: some View {
        HStack(spacing: 8) {
            Button(ergebnis == nil ? "Vermessen …" : "Neu vermessen …") { state.referenzVermessen = referenz.name }
                .disabled(referenz.zustand == .rechnet && referenz.laeuft == "messung")
                .help("Freie Maße von model.py an dieser Referenz messen (fotomess)")
            if let e = ergebnis, !e.masse.isEmpty {
                Button("Maße übernehmen") { uebernehmenFragen = true }
                    .help("Gemessene Werte (auf 0,1 mm) in die param()-Aufrufe von model.py schreiben")
            }
            if !referenz.istScan && (referenz.netz || ergebnis != nil) {
                Button("Maßstab …") { state.referenzMassstab = referenz.name }
                    .disabled(referenz.zustand == .rechnet)
                    .help("Bekanntes Maß setzen: zwei Punkte am Netz oder ein Maß der Hülle; Netz und Kameras skalieren mit")
            }
        }
        .controlSize(.small)
    }
}

/// Messergebnis neben den Parametern: model.py, gemessen ± Sigma, Änderung; darunter Hülle, Grundkörper, Hinweise.
struct ReferenzErgebnisTabelle: View {
    let ergebnis: ReferenzErgebnis
    let params: [String: Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Grid(alignment: .trailing, horizontalSpacing: 8, verticalSpacing: 2) {
                GridRow {
                    Text("Maß").gridColumnAlignment(.leading)
                    Text("model.py")
                    Text("gemessen")
                    Text("±")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                ForEach(ergebnis.masse) { m in
                    GridRow {
                        Text(m.name).gridColumnAlignment(.leading).lineLimit(1)
                        Text((params[m.name] ?? m.start).map { KevFormat.number($0, digits: 1) } ?? "–")
                            .foregroundStyle(.secondary)
                        Text(KevFormat.number(m.wert, digits: 1)).fontWeight(.medium)
                        Text(KevFormat.number(m.sigma, digits: 1))
                            .foregroundStyle(m.sigma > max(2, 0.05 * abs(m.wert)) ? Color.orange : .secondary)
                    }
                    .font(.callout.monospacedDigit())
                }
            }
            if !ergebnis.bekannt.isEmpty {
                Text("Maßstab: " + ergebnis.bekannt.sorted { $0.key < $1.key }
                    .map { "\($0.key) \(KevFormat.number($0.value, digits: 1)) mm" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let h = ergebnis.huelle {
                Text("Hülle mit Anbauten \(KevFormat.dimensions(h))").font(.caption).foregroundStyle(.secondary)
            }
            if let g = ergebnis.grundkoerper {
                Text("\((ergebnis.grundkoerperTeil ?? "Grundkörper").split(separator: "/").last.map(String.init) ?? "") "
                    + KevFormat.dimensions(g))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("\(KevFormat.count(ergebnis.bilder, one: "Bild", many: "Bilder"))"
                + (ergebnis.ueberdeckung.map { ", Überdeckung \(KevFormat.number($0 * 100, digits: 1)) %" } ?? "")
                + (ergebnis.dauer.map { ", \(KevFormat.number($0, digits: 0)) s" } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(ergebnis.empfehlungen) { e in
                Label(e.text, systemImage: symbol(e.art))
                    .font(.caption)
                    .foregroundStyle(e.art == "unsicher" || e.art == "lage_ungeprueft" ? Color.orange : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func symbol(_ art: String) -> String {
        switch art {
        case "nachmessen": return "ruler"
        case "aufnahme": return "camera.viewfinder"
        case "unsicher", "lage_ungeprueft": return "exclamationmark.triangle"
        case "verworfen": return "xmark.circle"
        default: return "info.circle"
        }
    }
}

/// Dialog „Referenz hinzufügen“ nach Drag and Drop oder +.
struct ReferenzHinzufuegenDialog: View {
    let dateien: [URL]
    let fertig: (_ name: String?, _ masz: [String: Double]?, _ auflage: Bool, _ von: Double?, _ bis: Double?,
                 _ einstellung: String) -> Void
    let abbrechen: () -> Void
    @State private var name = ""
    @State private var maszArt = "laenge"
    @State private var maszWert = ""
    @State private var auflage = false
    @State private var von = ""
    @State private var bis = ""
    @State private var genau = false

    private var video: URL? { dateien.first(where: ReferenzDateien.istVideo) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Referenz hinzufügen").font(.title3.weight(.semibold))
            if let video {
                Text("Video \(video.lastPathComponent): Apple Object Capture rechnet daraus ein Referenznetz (rund eine "
                    + "Minute), danach lässt sich model.py daran vermessen.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(dateien.count) Foto(s): Kameras und Maße entstehen beim Vermessen.")
                    .foregroundStyle(.secondary)
            }
            Form {
                TextField("Name", text: $name, prompt: Text(video?.deletingPathExtension().lastPathComponent ?? "Fotos"))
                if video != nil {
                    HStack {
                        Picker("Bekanntes Maß", selection: $maszArt) {
                            Text("Länge (längste Seite)").tag("laenge")
                            Text("Breite").tag("breite")
                            Text("Höhe").tag("hoehe")
                            Text("Grundkörper Länge").tag("grund_laenge")
                            Text("Grundkörper Breite").tag("grund_breite")
                        }
                        TextField("mm", text: $maszWert).frame(width: 80)
                        Text("mm").foregroundStyle(.secondary)
                    }
                    Toggle("Liegt auf einer Unterlage (Scheibe, Tisch)", isOn: $auflage)
                    HStack {
                        TextField("von (s)", text: $von).frame(width: 80)
                        TextField("bis (s)", text: $bis).frame(width: 80)
                        Text("Abschnitt des Videos, leer = ganz").foregroundStyle(.secondary).font(.caption)
                    }
                    Toggle("Genau (120 Bilder, 2880 px, dreimal so lange)", isOn: $genau)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel, action: abbrechen)
                    .keyboardShortcut(.cancelAction)
                Button("Hinzufügen") {
                    let wert = Double(maszWert.replacingOccurrences(of: ",", with: "."))
                    fertig(name.isEmpty ? nil : name, wert.map { [maszArt: $0] }, auflage,
                           Double(von.replacingOccurrences(of: ",", with: ".")),
                           Double(bis.replacingOccurrences(of: ",", with: ".")), genau ? "genau" : "schnell")
                }
                .keyboardShortcut(.defaultAction)
            }
            if video != nil && Double(maszWert.replacingOccurrences(of: ",", with: ".")) == nil {
                Text("Ohne bekanntes Maß hat das Netz keinen Maßstab (Object Capture rechnet ohne LiDAR maßstabslos).")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// Dialog „Vermessen“: welche param()-Maße frei sind und welches den Maßstab gibt.
struct ReferenzVermessenDialog: View {
    let referenz: String
    @ObservedObject var store: ReferenzStore
    let fertig: (_ frei: [String]?, _ bekannt: [String: Double], _ bilder: Int) -> Void
    let abbrechen: () -> Void
    @State private var frei: Set<String> = []
    @State private var massstab = ""
    @State private var massstabWert = ""
    @State private var bilder = 8
    @State private var ausModell = true

    private var namen: [String] { store.params.keys.sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Referenz \(referenz) vermessen").font(.title3.weight(.semibold))
            Text("fotomess passt die Kanten des Modells an die Bilder an und misst die freien Maße mit Sigma. Ein Maß "
                + "bleibt fest und gibt den Maßstab.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Angaben aus messmodell() in model.py", isOn: $ausModell)
            if !ausModell {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow {
                            Text("param").foregroundStyle(.secondary)
                            Text("Wert").foregroundStyle(.secondary)
                            Text("messen").foregroundStyle(.secondary)
                            Text("Maßstab").foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        ForEach(namen, id: \.self) { n in
                            GridRow {
                                Text(n)
                                Text(KevFormat.number(store.params[n] ?? 0, digits: 1)).monospacedDigit()
                                Toggle("", isOn: Binding(
                                    get: { frei.contains(n) },
                                    set: { on in
                                        if on { frei.insert(n) } else { frei.remove(n) }
                                        if on && massstab == n { massstab = "" }
                                    }))
                                .labelsHidden()
                                Toggle("", isOn: Binding(
                                    get: { massstab == n },
                                    set: { on in
                                        massstab = on ? n : ""
                                        if on {
                                            frei.remove(n)
                                            massstabWert = KevFormat.number(store.params[n] ?? 0, digits: 1)
                                        }
                                    }))
                                .labelsHidden()
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
                if !massstab.isEmpty {
                    HStack {
                        Text("\(massstab) gemessen von Hand:")
                        TextField("mm", text: $massstabWert).frame(width: 90)
                        Text("mm").foregroundStyle(.secondary)
                    }
                }
            }
            Stepper("Bilder aus dem Video: \(bilder)", value: $bilder, in: 2...16)
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel, action: abbrechen).keyboardShortcut(.cancelAction)
                Button("Vermessen") {
                    var bekannt: [String: Double] = [:]
                    if !ausModell, !massstab.isEmpty,
                       let w = Double(massstabWert.replacingOccurrences(of: ",", with: ".")) {
                        bekannt[massstab] = w
                    }
                    fertig(ausModell ? nil : frei.sorted(), bekannt, bilder)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!ausModell && (frei.isEmpty || massstab.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

/// Dialoge der Referenzen am Projektfenster.
struct ReferenzDialoge: ViewModifier {
    @ObservedObject var model: AppModel
    @ObservedObject var state: ProjectWindowState

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { state.referenzDateien != nil }, set: { if !$0 { state.referenzDateien = nil } })) {
                ReferenzHinzufuegenDialog(dateien: state.referenzDateien ?? []) { name, masz, auflage, von, bis, einstellung in
                    model.referenzActions?.referenzHinzufuegen(
                        state.referenzDateien ?? [], name: name, masz: masz, auflage: auflage, von: von, bis: bis,
                        einstellung: einstellung)
                    state.referenzDateien = nil
                    state.showInspector = true
                } abbrechen: {
                    state.referenzDateien = nil
                }
            }
            .sheet(isPresented: Binding(get: { state.referenzMassstab != nil }, set: { if !$0 { state.referenzMassstab = nil } })) {
                MassstabDialog(referenz: state.referenzMassstab ?? "", store: model.referenzen, actions: model.referenzActions) {
                    state.referenzMassstab = nil
                }
            }
            .sheet(isPresented: Binding(get: { state.referenzVermessen != nil }, set: { if !$0 { state.referenzVermessen = nil } })) {
                ReferenzVermessenDialog(referenz: state.referenzVermessen ?? "", store: model.referenzen) { frei, bekannt, bilder in
                    if let r = state.referenzVermessen {
                        model.referenzActions?.referenzVermessen(r, frei: frei, bekannt: bekannt, bilder: bilder)
                    }
                    state.referenzVermessen = nil
                } abbrechen: {
                    state.referenzVermessen = nil
                }
            }
    }
}
