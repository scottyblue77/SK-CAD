import AppKit
import KevCADCore
import SwiftUI

/// Fenster „Zukaufteil hinzufügen …“ (Ablage-Menü, Lagerkatalog). Nimmt den Auftrag aus `session.zukaufRequest`.
struct ZukaufDialogWindow: View {
    @EnvironmentObject private var session: AppSession
    @ObservedObject var model: AppModel
    @State private var request: ZukaufDialogRequest = .new()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ZukaufDialog(model: model, request: request) { dismissWindow(id: WindowID.zukauf) }
            .id(request.id)
            .background(WindowHook(placement: .centered))
            .onAppear {
                session.attach(openWindow: openWindow, dismissWindow: dismissWindow)
                consume()
            }
            .onChange(of: session.zukaufRequest) { consume() }
    }

    private func consume() {
        guard let r = session.zukaufRequest else { return }
        session.zukaufRequest = nil
        request = r
    }
}

/// Drei Schritte: Eingabe (Link, MPN oder EAN), Felder bestätigen, danach der Stand beim Kernel (CAD suchen).
struct ZukaufDialog: View {
    enum Step { case input, fields, status }

    @EnvironmentObject private var session: AppSession
    @ObservedObject var model: AppModel
    let request: ZukaufDialogRequest
    var close: () -> Void

    @State private var step: Step
    @State private var inputText: String
    @State private var draft: ZukaufDraft
    @State private var ebene: CatalogLevel
    @State private var nameEdited: Bool
    @State private var idEdited: Bool
    @State private var showIssues = false
    @State private var submitted = false
    @State private var kernelError: String?
    /// Freigabe gespeichert, wartet darauf, dass der Katalog den Eintrag als frei zeigt.
    @State private var awaitingRelease: String?
    @State private var createdID: String?
    @State private var copied = false
    @Environment(\.openURL) private var openURL

    init(model: AppModel, request: ZukaufDialogRequest, close: @escaping () -> Void) {
        self.model = model
        self.request = request
        self.close = close
        _step = State(initialValue: request.mode == .new && !request.startWithFields ? .input : .fields)
        _inputText = State(initialValue: request.draft.eingabe)
        _draft = State(initialValue: request.draft)
        _ebene = State(initialValue: request.ebene)
        _nameEdited = State(initialValue: !request.draft.name.isEmpty)
        _idEdited = State(initialValue: request.mode != .new || !request.draft.id.isEmpty)
    }

    private var input: ZukaufInput { ZukaufInput.classify(inputText) }
    private var issues: [CatalogIssue] { draft.validate() }

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .input: inputStep
            case .fields: fieldsStep
            case .status: statusStep
            }
        }
        .frame(width: 600, height: step == .input ? 470 : 720)
        .animation(.snappy(duration: 0.2), value: step)
        .onChange(of: model.zukaufActivity) { _, activity in zukaufFinished(activity) }
        .onChange(of: model.catalogActivity) { _, activity in saveFinished(activity) }
        .onChange(of: model.catalog) { releaseChecked() }
        .onChange(of: draft.hersteller) { suggest() }
        .onChange(of: draft.mpn) { suggest() }
        .onChange(of: draft.shopNr) { suggest() }
        .onReceive(NotificationCenter.default.publisher(for: .zukaufSelfTestSubmit)) { _ in
            if AppInfo.isTestVariant, step == .fields { save() }
        }
    }

    // MARK: 1. Eingabe

    private var inputStep: some View {
        VStack(spacing: 0) {
            FormTitle(title: "Zukaufteil hinzufügen", symbol: "cart.badge.plus",
                      subtitle: "Shop-Link, Herstellernummer (MPN) oder EAN einfügen")
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    TextField("Eingabe", text: $inputText,
                              prompt: Text("https://… · 560H5000B · 4006381333931"))
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                        .onSubmit(next)
                    Button {
                        if let s = NSPasteboard.general.string(forType: .string) { inputText = s }
                    } label: {
                        Label("Einfügen", systemImage: "doc.on.clipboard")
                    }
                    .help("Text aus der Zwischenablage übernehmen")
                }
                if input != .empty {
                    Label(input.title, systemImage: input.symbol)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                matchHints
                Spacer(minLength: 0)
                noFetchNote
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxHeight: .infinity, alignment: .top)
            footer(primary: "Weiter", primaryDisabled: false, action: next, back: nil)
        }
    }

    /// Schon im Katalog oder von Claude vorgeschlagen.
    @ViewBuilder
    private var matchHints: some View {
        if let match = model.catalog?.zukauf(matching: input) {
            HintBox(symbol: match.vorgeschlagen ? "sparkles" : "checkmark.circle", tint: match.vorgeschlagen ? .orange : .green) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(match.vorgeschlagen ? "Claude hat dieses Teil schon vorgeschlagen" : "Schon im Katalog")
                        .fontWeight(.medium)
                    Text("\(match.name) · \(match.ebene.title)")
                        .foregroundStyle(.secondary)
                }
            } actions: {
                if match.vorgeschlagen {
                    Button("Prüfen …") { loadEntry(match, mode: .confirm) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Im Katalog zeigen") { session.showCatalog(focus: .item(match.id)) }
                }
            }
        }
    }

    private var noFetchNote: some View {
        HintBox(symbol: "info.circle", tint: .secondary) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SK-CAD lädt keine Shop-Seiten.").fontWeight(.medium)
                Text("Trag die Angaben im nächsten Schritt selbst ein oder bitte Claude, die Seite zu lesen: "
                    + "sein Vorschlag erscheint im Lagerkatalog und lässt sich hier prüfen und freigeben.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            VStack(alignment: .trailing, spacing: 6) {
                if case .link(let url) = input {
                    Button("Seite öffnen") { openURL(url) }
                        .help("Produktseite im Standardbrowser öffnen")
                }
                Button(copied ? "Kopiert" : "Auftrag kopieren") {
                    copyToPasteboard(Self.claudeTask(inputText))
                    copied = true
                }
                .disabled(input == .empty)
                .help("Auftrag für Claude in die Zwischenablage")
            }
        }
    }

    /// Auftrag für Claude (MCP-Werkzeuge laut PLAN-PHASE3-ZUKAUF.md).
    static func claudeTask(_ input: String) -> String {
        "Lege in SK-CAD ein Zukaufteil an: \(input.trimmingCharacters(in: .whitespacesAndNewlines))\n"
            + "Lies die Produktseite (Hersteller, Herstellernummer, EAN, Preis mit Datum und brutto/netto, Maße, "
            + "Gewicht, Bild) und schlage das Teil mit zukauf_anlegen vor. Such danach mit cad_suchen das Hersteller-CAD."
    }

    private func next() {
        guard input != .empty else {
            // Ohne Eingabe gleich zu den Feldern (alles von Hand)
            withAnimation { step = .fields }
            return
        }
        var d = draft
        d.eingabe = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        d.apply(input)
        draft = d
        suggest()
        withAnimation { step = .fields }
    }

    private func loadEntry(_ item: CatalogItem, mode: ZukaufDialogRequest.Mode) {
        session.showZukaufDialog(for: item, mode: mode)
    }

    // MARK: 2. Felder

    private var title: String {
        switch request.mode {
        case .new: return "Zukaufteil hinzufügen"
        case .confirm: return "Vorschlag von Claude prüfen"
        case .edit: return "Zukaufteil bearbeiten"
        }
    }

    private var subtitle: String {
        switch request.mode {
        case .new:
            return input == .empty ? "Angaben von Hand" : input.title
        case .confirm:
            return "Felder prüfen, dann freigeben · \(draft.id)"
        case .edit:
            return "\(ebene.title) · \(draft.id)"
        }
    }

    private var fieldsStep: some View {
        VStack(spacing: 0) {
            FormTitle(title: title, symbol: request.mode == .confirm ? "sparkles" : "cart", subtitle: subtitle)
            Form {
                productSection
                shopSection
                priceSection
                sizeSection
                LevelSection(model: model, ebene: $ebene, fixed: request.mode != .new)
            }
            .formStyle(.grouped)
            footer(
                primary: request.mode == .new ? "Hinzufügen" : (request.mode == .confirm ? "Freigeben" : "Sichern"),
                primaryDisabled: submitted, action: save,
                back: request.mode == .new ? { withAnimation { step = .input } } : nil)
        }
    }

    private var productSection: some View {
        Section("Produkt") {
            FieldRow(label: "Hersteller", text: $draft.hersteller, prompt: "z. B. Blum", issue: issue("hersteller"),
                     width: 280)
            FieldRow(label: "Herstellernummer", text: $draft.mpn, prompt: "MPN, z. B. 560H5000B", issue: issue("mpn"),
                     monospaced: true, width: 280)
            FieldRow(label: "Shop-Nummer", text: $draft.shopNr, prompt: "nur ohne MPN", hint: "reine Shop-Artikel",
                     monospaced: true, width: 280)
            FieldRow(label: "EAN", text: $draft.gtin, prompt: "8 bis 14 Ziffern, optional", issue: issue("gtin"),
                     monospaced: true, width: 280)
            FieldRow(label: "Name", text: Binding(get: { draft.name }, set: { draft.name = $0; nameEdited = true }),
                     prompt: "z. B. Blum Tandembox Vollauszug 500 mm", issue: issue("name"), width: 280)
            if request.mode == .new {
                FieldRow(label: "ID", text: Binding(get: { draft.id }, set: { draft.id = $0; idEdited = true }),
                         prompt: "hersteller-nummer", issue: issue("id") ?? idNote, monospaced: true, width: 280,
                         issueIsNote: issue("id") == nil)
            } else {
                LabeledContent("ID") { Text(draft.id).font(.body.monospaced()).textSelection(.enabled) }
            }
        }
    }

    private var shopSection: some View {
        Section {
            LabeledContent("Link") {
                HStack(spacing: 6) {
                    TextField("Link", text: $draft.url, prompt: Text("https://…"))
                        .labelsHidden()
                        .frame(width: 252)
                    Button {
                        if let url = ZukaufLink.url(draft.url) { openURL(url) }
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderless)
                    .disabled(ZukaufLink.url(draft.url) == nil)
                    .help("Produktseite im Standardbrowser öffnen")
                }
            }
            if let i = issue("url") { IssueText(text: i) }
            LabeledContent("Bild") {
                HStack(spacing: 8) {
                    TextField("Bild", text: $draft.bild, prompt: Text("https://…/bild.jpg"))
                        .labelsHidden()
                        .frame(width: 232)
                    ZukaufImage(url: ZukaufLink.url(draft.bild), size: 30)
                }
            }
            if let i = issue("bild") { IssueText(text: i) }
        } header: {
            Text("Shop")
        }
    }

    private var priceSection: some View {
        Section {
            LabeledContent("Preis je Stück") {
                HStack(spacing: 8) {
                    NumberInput(text: $draft.preis, prompt: "optional", width: 90)
                    Text(draft.waehrung == "EUR" ? "€" : draft.waehrung).foregroundStyle(.secondary)
                    Picker("Steuer", selection: $draft.brutto) {
                        Text("brutto").tag(true)
                        Text("netto").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("So, wie der Shop den Preis angibt")
                }
            }
            if let i = issue("preis") { IssueText(text: i) }
            LabeledContent("Stand") {
                DatePicker("Stand", selection: standBinding, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .fixedSize()
            }
            FieldRow(label: "Quelle", text: $draft.preisQuelle, prompt: "leer: der Link", width: 280)
        } header: {
            Text("Preis")
        } footer: {
            Text("Preise veralten: Stand und Link gehen mit in die Stückliste.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var standBinding: Binding<Date> {
        Binding(
            get: { ZukaufDraft.parseDay(draft.preisStand) ?? Date() },
            set: { draft.preisStand = ZukaufDraft.today($0) })
    }

    private var sizeSection: some View {
        Section {
            Picker("Ersatzkörper", selection: $draft.form) {
                ForEach(ZukaufForm.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            ForEach(draft.form.keys, id: \.self) { key in
                FieldRow(label: ZukaufForm.label(key), text: masseBinding(key), unit: "mm", prompt: "Pflicht",
                         issue: issue("masse.\(key)"), numeric: true)
            }
            FieldRow(label: "Gewicht", text: $draft.gewicht, unit: "g", prompt: "optional",
                     hint: "leer: aus Volumen × Dichte", issue: issue("gewicht"), numeric: true)
            Picker("Material", selection: $draft.material) {
                Text("ohne Angabe").tag("")
                ForEach(model.catalog?.materials ?? []) { m in
                    Text(m.name).tag(m.id)
                }
                if !draft.material.isEmpty && model.catalog?.material(draft.material) == nil {
                    Text(draft.material).tag(draft.material)
                }
            }
        } header: {
            Text("Maße und Gewicht")
        } footer: {
            Text("Hüllmaße aus dem Shop. Ohne Hersteller-CAD steht das Teil als Ersatzkörper aus diesen Maßen im Modell: "
                + "halbtransparent und im Teilebaum als vereinfacht markiert.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func masseBinding(_ key: String) -> Binding<String> {
        Binding(get: { draft.masse[key] ?? "" }, set: { draft.masse[key] = $0 })
    }

    private func issue(_ field: String) -> String? {
        guard showIssues else { return nil }
        return issues.first { $0.field == field }?.message
    }

    private var idNote: String? {
        let id = draft.id.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, let existing = model.catalog?.item(id) else { return nil }
        return "Ersetzt „\(existing.name)“ (\(existing.ebene.title))."
    }

    private func suggest() {
        if !nameEdited { draft.name = draft.suggestedName() }
        if !idEdited { draft.id = draft.suggestedID() }
    }

    private func save() {
        kernelError = nil
        guard issues.isEmpty else {
            withAnimation(.snappy(duration: 0.2)) { showIssues = true }
            return
        }
        switch request.mode {
        case .new:
            guard let actions = model.zukaufActions else {
                kernelError = "Hinzufügen geht gerade nicht (kein Kernel verbunden)."
                return
            }
            submitted = true
            let eingabe = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            actions.addZukauf(eingabe: eingabe.isEmpty ? draft.suggestedName() : eingabe, felder: draft.json(),
                              ebene: ebene)
        case .confirm, .edit:
            guard let actions = model.catalogActions else {
                kernelError = "Speichern geht gerade nicht (kein Kernel verbunden)."
                return
            }
            submitted = true
            actions.saveCatalogEntry(kind: "teil", json: draft.json(), ebene: ebene)
        }
    }

    private func zukaufFinished(_ activity: ZukaufActivity) {
        guard submitted, request.mode == .new else { return }
        switch activity {
        case .accepted(let id, _):
            submitted = false
            createdID = id
            withAnimation { step = .status }
        case .failed(let text):
            submitted = false
            kernelError = text
        default:
            break
        }
    }

    private func saveFinished(_ activity: CatalogActivity) {
        guard submitted, request.mode != .new else { return }
        switch activity {
        case .saved(let id, _):
            // Freigabe: erst schließen, wenn der nachgeladene Katalog den Eintrag als frei zeigt (sonst meldet der
            // App-Kern „nicht wirksam“, und die Meldung steht hier unten)
            if request.mode == .confirm, model.catalog?.item(id)?.vorgeschlagen == true {
                awaitingRelease = id
                return
            }
            finishSaved(id)
        case .failed(let text):
            submitted = false
            awaitingRelease = nil
            kernelError = text
        default:
            break
        }
    }

    private func releaseChecked() {
        guard let id = awaitingRelease, model.catalog?.item(id)?.vorgeschlagen == false else { return }
        finishSaved(id)
    }

    private func finishSaved(_ id: String) {
        submitted = false
        awaitingRelease = nil
        session.showCatalog(focus: .item(id))
        close()
    }

    // MARK: 3. Stand beim Kernel

    private var statusStep: some View {
        let id = createdID ?? draft.id
        let status = model.zukaufStatus(for: id)
        return VStack(spacing: 0) {
            FormTitle(title: draft.name, symbol: "checkmark.seal", subtitle: "Angelegt im \(ebene == .projekt ? "Projektkatalog" : "eigenen Katalog") · \(id)")
            Form {
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        ZukaufImage(url: ZukaufLink.url(draft.bild), size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text([draft.hersteller, draft.mpn.isEmpty ? draft.shopNr : draft.mpn]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .fontWeight(.medium)
                            if let p = ZukaufEntryInfo(entry: draft.entry()).preisText {
                                Text("\(p) · Stand \(ZukaufDate.display(draft.preisStand) ?? draft.preisStand)")
                                    .foregroundStyle(.secondary)
                            }
                            Text(ZukaufEntryInfo(entry: draft.entry()).masseText).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("CAD") {
                    if let status {
                        ZukaufStatusLabel(status: status)
                        if let text = status.text {
                            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if status.isWaiting {
                            Text(waitingText(status))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                CADSearchButton(links: status.cadLinks)
                                Button("Datei wählen …") { session.chooseCADFile(for: id) }
                                Spacer()
                            }
                        }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Der Kernel sucht das Hersteller-CAD …").foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Text("Bis das CAD da ist, verbaut Claude das Teil als Ersatzkörper aus den Maßen (vereinfacht). "
                        + "Sobald die Datei übernommen ist, ersetzt das Hersteller-Modell ihn beim nächsten Lauf.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Im Lagerkatalog zeigen") { session.showCatalog(focus: .item(id)) }
                Spacer()
                Button("Fertig", action: close)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func waitingText(_ status: ZukaufStatus) -> String {
        let types = status.erwartet.map { ".\($0)" }.joined(separator: ", ")
        let dir = model.watchedDownloads.map { KevFormat.abbreviatedPath($0.path) } ?? "Downloads"
        return (status.cadLinks.isEmpty ? "Lade die CAD-Datei beim Hersteller herunter. " :
            "„CAD suchen“ öffnet die Seite des Herstellers im Browser; lade dort die STEP-Datei herunter. ")
            + "SK-CAD beobachtet \(dir) und fragt nach, sobald eine neue Datei (\(types)) ankommt."
    }

    // MARK: Fuß

    private func footer(primary: String, primaryDisabled: Bool, action: @escaping () -> Void, back: (() -> Void)?)
        -> some View
    {
        HStack(spacing: 10) {
            if submitted {
                ProgressView().controlSize(.small)
                Text(request.mode == .new ? "Wird an den Kernel übergeben …" : "Wird gespeichert …")
                    .foregroundStyle(.secondary)
            } else if let kernelError {
                Label(kernelError, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .textSelection(.enabled)
            } else if showIssues, !issues.isEmpty, step == .fields {
                Label(issues.count == 1 ? issues[0].message : "\(issues.count) Angaben fehlen oder stimmen nicht",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let back {
                Button("Zurück", action: back)
            }
            Button("Abbrechen", action: close)
                .keyboardShortcut(.cancelAction)
            Button(primary, action: action)
                .keyboardShortcut(.defaultAction)
                .disabled(primaryDisabled)
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Kasten mit Symbol, Text und Knöpfen rechts.
struct HintBox<Content: View, Actions: View>: View {
    var symbol: String
    var tint: Color
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 22)
            content
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
                .controlSize(.small)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint == .secondary ? Color.primary.opacity(0.04) : tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}
