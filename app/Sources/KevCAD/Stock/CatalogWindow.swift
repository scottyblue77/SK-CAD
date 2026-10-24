import AppKit
import KevCADCore
import SwiftUI

/// Abschnitt in der Seitenleiste des Lagerkatalogs.
enum CatalogSection: Hashable {
    /// Vorschläge von Claude (Teile und Materialien mit `status: "vorgeschlagen"`).
    case suggestions
    case allItems
    case art(String)
    case allMaterials
    case group(String)

    var showsMaterials: Bool {
        switch self {
        case .allMaterials, .group: return true
        case .allItems, .art, .suggestions: return false
        }
    }
}

/// Fenster „Lagerkatalog“ (Fenster > Lagerkatalog, ⇧⌘K): links Arten und Materialgruppen, in der Mitte die Einträge
/// mit Suche, rechts die Details. Einträge der Ebenen „eigen“ und „projekt“ lassen sich bearbeiten und löschen,
/// mitgelieferte nur ansehen und als eigenes Teil kopieren. Gelesen und gespeichert wird über den Kernel
/// (CATALOG_REQ, CATALOG_SAVE, CATALOG_DELETE); gesucht wird im geladenen Katalog.
struct CatalogWindow: View {
    @EnvironmentObject private var session: AppSession
    @ObservedObject var model: AppModel
    @State private var section: CatalogSection? = .allItems
    @State private var selection: CatalogFocus?
    @State private var search = ""
    @State private var level: CatalogLevel?
    @State private var form: CatalogFormRequest?
    @State private var deleting: CatalogFocus?
    @State private var dismissedError: String?
    /// Freigaben aus diesem Fenster, die der Katalog noch nicht als frei zeigt.
    @State private var approving: Set<CatalogFocus> = []
    /// Gescheiterte Freigabe: als Hinweisfenster, damit sie nicht übersehen wird.
    @State private var approvalError: String?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let catalog = model.catalog {
                split(catalog)
            } else {
                CatalogEmptyState(model: model) { load(force: true) }
            }
        }
        .frame(minWidth: 940, minHeight: 540)
        .background(WindowHook(placement: .trailing(width: 1140, height: 720)))
        .navigationTitle("Lagerkatalog")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .sheet(item: $form) { request in
            CatalogFormSheet(model: model, request: request) { saved in
                selection = saved
                revealSelection()
            }
        }
        .confirmationDialog(
            deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible, presenting: deleting
        ) { entry in
            Button(isSuggestion(entry) ? "Ablehnen" : "Löschen", role: .destructive) { delete(entry) }
            Button("Abbrechen", role: .cancel) {}
        } message: { entry in
            Text(isSuggestion(entry)
                ? "Der Vorschlag von Claude wird aus dem Katalog entfernt."
                : "Der Eintrag wird aus dem Katalog entfernt. Ein model.py, das ihn verbaut, findet ihn danach nicht mehr.")
        }
        .onAppear {
            session.attach(openWindow: openWindow, dismissWindow: dismissWindow)
            load(force: false)
            consumeFocus()
            openDemoFormIfRequested()
            FreigabeSelfTest.runIfRequested(session)
        }
        .alert("Freigabe fehlgeschlagen", isPresented: Binding(
            get: { approvalError != nil }, set: { if !$0 { approvalError = nil } })
        ) {
            Button("OK", role: .cancel) { dismissedError = approvalError }
            Button("Protokoll zeigen") {
                dismissedError = approvalError
                session.showLog()
            }
        } message: {
            Text((approvalError ?? "") + "\n\nDer Eintrag ist weiter ein Vorschlag und lässt sich nicht verbauen.")
        }
        .onChange(of: session.catalogFocus) { consumeFocus() }
        .onChange(of: session.catalogSectionRequest) { consumeFocus() }
        .onChange(of: model.catalog) {
            consumeFocus()
            approving = approving.filter { isSuggestion($0) }
        }
        .onChange(of: model.kernelState) { _, state in
            if state == .ready, model.catalog == nil { load(force: false) }
        }
        .onChange(of: model.catalogActivity) { _, activity in
            if case .deleted(let id) = activity, selection == .item(id) || selection == .material(id) { selection = nil }
            if case .failed(let text) = activity, !approving.isEmpty {
                approving.removeAll()
                approvalError = text
            }
        }
    }

    private var subtitle: String {
        guard let c = model.catalog else { return "" }
        let zukauf = c.items.filter(\.isZukauf).count
        return "\(KevFormat.count(c.items.count - zukauf, one: "Lagerteil", many: "Lagerteile")) · "
            + (zukauf > 0 ? "\(KevFormat.count(zukauf, one: "Zukaufteil", many: "Zukaufteile")) · " : "")
            + KevFormat.count(c.materials.count, one: "Material", many: "Materialien")
    }

    // MARK: Aufbau

    private func split(_ catalog: Catalog) -> some View {
        NavigationSplitView {
            CatalogSidebar(catalog: catalog, level: level, section: $section)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } content: {
            CatalogList(
                model: model, catalog: catalog, section: section ?? .allItems, level: level, search: search,
                selection: $selection, onEdit: edit, onCopy: copy, onDelete: { deleting = $0 }, onApprove: approve,
                onShowSuggestions: { section = .suggestions }
            )
            .searchable(text: $search, placement: .toolbar, prompt: "Name, Maß, Norm, Material")
            .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 560)
        } detail: {
            VStack(spacing: 0) {
                detail(catalog)
                errorBar
            }
        }
    }

    @ViewBuilder
    private func detail(_ catalog: Catalog) -> some View {
        switch selection {
        case .item(let id)?:
            if let item = catalog.item(id), item.isZukauf {
                ZukaufCatalogDetail(model: model, item: item, onDelete: { deleting = .item(id) },
                                    onApprove: { approve(.item(id)) })
                    .id(id)
            } else if let item = catalog.item(id) {
                CatalogItemDetail(
                    model: model, item: item, catalog: catalog, onEdit: { edit(.item(id)) }, onCopy: { copy(.item(id)) },
                    onDelete: { deleting = .item(id) }, onApprove: { approve(.item(id)) })
                    .id(id)
            } else {
                noSelection
            }
        case .material(let id)?:
            if let material = catalog.material(id) {
                CatalogMaterialDetail(
                    model: model, material: material, catalog: catalog, onEdit: { edit(.material(id)) },
                    onCopy: { copy(.material(id)) }, onDelete: { deleting = .material(id) },
                    onApprove: { approve(.material(id)) })
                    .id(id)
            } else {
                noSelection
            }
        case nil:
            noSelection
        }
    }

    private var noSelection: some View {
        ContentUnavailableView {
            Label("Kein Eintrag ausgewählt", systemImage: "books.vertical")
        } description: {
            Text("Wähle einen Eintrag aus der Liste oder lege mit + ein neues Lagerteil oder Material an.")
        }
    }

    /// Fehler beim Speichern oder Löschen (außerhalb des Formulars).
    @ViewBuilder
    private var errorBar: some View {
        if case .failed(let text) = model.catalogActivity, form == nil, dismissedError != text {
            HStack(spacing: 8) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(text)
                    .font(.callout)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button("OK") { dismissedError = text }
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.08))
            .overlay(alignment: .top) { Divider() }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker(selection: $level) {
                Text("Alle Ebenen").tag(CatalogLevel?.none)
                Divider()
                ForEach(CatalogLevel.allCases, id: \.self) { l in
                    Label(l.title, systemImage: l.symbol).tag(CatalogLevel?.some(l))
                }
            } label: {
                Label("Ebene", systemImage: "line.3.horizontal.decrease.circle")
            }
            .pickerStyle(.menu)
            .help("Nach Ebene filtern: mitgeliefert, eigener Katalog, Projekt")
            .disabled(model.catalog == nil)

            Button {
                load(force: true)
            } label: {
                Label("Neu laden", systemImage: "arrow.clockwise")
            }
            .help("Katalog neu vom Kernel laden")

            Menu {
                Button("Neues Lagerteil …") { newItem() }
                Button("Neues Material …") { newMaterial() }
                Divider()
                Button("Zukaufteil hinzufügen …") { session.showZukaufDialog() }
            } label: {
                Label("Neu", systemImage: "plus")
            } primaryAction: {
                if section?.showsMaterials == true {
                    newMaterial()
                } else if section == .art(ZukaufDraft.art) {
                    session.showZukaufDialog()
                } else {
                    newItem()
                }
            }
            .help("Neues Lagerteil oder Material im eigenen Katalog anlegen")
            .disabled(model.catalog == nil)
        }
    }

    // MARK: Aktionen

    private func load(force: Bool) {
        guard force || model.catalog == nil else { return }
        if case .loading = model.catalogActivity, !force { return }
        model.catalogActions?.requestCatalog(query: nil, art: nil)
    }

    /// Auswahl von außen (Inspektor, Stückliste, Band „Nicht aus dem Inventar“): Eintrag bzw. Abschnitt zeigen,
    /// Suche und Filter zurücksetzen.
    private func consumeFocus() {
        var requested: CatalogSection?
        if let request = session.catalogSectionRequest, model.catalog != nil {
            session.catalogSectionRequest = nil
            search = ""
            level = nil
            section = request
            requested = request
        }
        guard let focus = session.catalogFocus, let catalog = model.catalog else { return }
        session.catalogFocus = nil
        search = ""
        level = nil
        // Ausdrücklich gewünschter Abschnitt (z. B. Vorschläge) bleibt, der Eintrag wird darin ausgewählt
        if requested != nil {
            selection = focus
            return
        }
        switch focus {
        case .item(let id):
            section = catalog.item(id).map { .art($0.art) } ?? .allItems
        case .material(let id):
            section = catalog.material(id).map { $0.gruppe.isEmpty ? .allMaterials : .group($0.gruppe) } ?? .allMaterials
        }
        selection = focus
    }

    /// Nach dem Speichern: den Abschnitt zeigen, in dem der Eintrag steht.
    private func revealSelection() {
        search = ""
        switch selection {
        case .item?: if section?.showsMaterials == true { section = .allItems }
        case .material?: if section?.showsMaterials != true { section = .allMaterials }
        case nil: break
        }
        if case .art(let art)? = section, case .item(let id)? = selection, model.catalog?.item(id)?.art != art {
            section = .allItems
        }
    }

    private func newItem() {
        var art = "vierkantrohr"
        if case .art(let a)? = section { art = a }
        var draft = CatalogItemDraft(art: art)
        if let first = model.catalog?.materials.first(where: { $0.id == "stahl-s235" }) ?? model.catalog?.materials.first,
           !["holz", "platte"].contains(art) {
            draft.material = first.id
        }
        form = CatalogFormRequest(mode: .new, draft: .item(draft), ebene: .eigen)
    }

    private func newMaterial() {
        var draft = CatalogMaterialDraft()
        if case .group(let g)? = section { draft.gruppe = g }
        form = CatalogFormRequest(mode: .new, draft: .material(draft), ebene: .eigen)
    }

    private func edit(_ entry: CatalogFocus) {
        guard let catalog = model.catalog else { return }
        switch entry {
        case .item(let id):
            guard let item = catalog.item(id), item.ebene.isEditable else { return }
            if item.isZukauf { return session.showZukaufDialog(for: item, mode: item.vorgeschlagen ? .confirm : .edit) }
            form = CatalogFormRequest(mode: .edit, draft: .item(CatalogItemDraft(entry: item.entry)), ebene: item.ebene)
        case .material(let id):
            guard let m = catalog.material(id), m.ebene.isEditable else { return }
            form = CatalogFormRequest(mode: .edit, draft: .material(CatalogMaterialDraft(entry: m.entry)), ebene: m.ebene)
        }
    }

    private func copy(_ entry: CatalogFocus) {
        guard let catalog = model.catalog else { return }
        switch entry {
        case .item(let id):
            guard let item = catalog.item(id) else { return }
            if item.isZukauf {
                var draft = ZukaufDraft(entry: item.entry)
                draft.id = ""
                draft.extra.removeValue(forKey: "cad")
                return session.showZukaufDialog(ZukaufDialogRequest(mode: .new, draft: draft, ebene: .eigen, startWithFields: true))
            }
            form = CatalogFormRequest(mode: .copy, draft: .item(CatalogItemDraft(entry: item.entry)), ebene: .eigen)
        case .material(let id):
            guard let m = catalog.material(id) else { return }
            form = CatalogFormRequest(mode: .copy, draft: .material(CatalogMaterialDraft(entry: m.entry)), ebene: .eigen)
        }
    }

    private var deleteTitle: String {
        guard let entry = deleting, let catalog = model.catalog else { return "Eintrag löschen?" }
        let verb = isSuggestion(entry) ? "ablehnen" : "löschen"
        switch entry {
        case .item(let id): return "„\(catalog.item(id)?.name ?? id)“ \(verb)?"
        case .material(let id): return "Material „\(catalog.material(id)?.name ?? id)“ \(verb)?"
        }
    }

    private func isSuggestion(_ entry: CatalogFocus) -> Bool {
        switch entry {
        case .item(let id): return model.catalog?.item(id)?.vorgeschlagen == true
        case .material(let id): return model.catalog?.material(id)?.vorgeschlagen == true
        }
    }

    /// Vorschlag freigeben: derselbe Eintrag mit `status: "frei"` (CATALOG_SAVE). Scheitert die Freigabe, an welcher
    /// Stelle auch immer, erscheint ein Hinweisfenster; still bleibt nichts liegen.
    private func approve(_ entry: CatalogFocus) {
        dismissedError = nil
        guard let catalog = model.catalog else {
            approvalError = "Der Lagerkatalog ist nicht geladen, die Freigabe wurde nicht gesendet."
            return
        }
        guard let actions = model.catalogActions else {
            approvalError = "Freigeben geht gerade nicht: Es ist kein Kernel verbunden."
            return
        }
        let json: Data, kind: String, ebene: CatalogLevel
        switch entry {
        case .item(let id):
            guard let item = catalog.item(id) else {
                approvalError = missing(id)
                return
            }
            (json, kind, ebene) = (item.json, "teil", item.ebene)
        case .material(let id):
            guard let m = catalog.material(id) else {
                approvalError = missing(id)
                return
            }
            (json, kind, ebene) = (m.json, "material", m.ebene)
        }
        approving.insert(entry)
        actions.saveCatalogEntry(kind: kind, json: Catalog.approvedJSON(json), ebene: ebene.isEditable ? ebene : .eigen)
        // Rückmeldung abwarten (der App-Kern meldet nach 15 s ohne Antwort selbst einen Fehler); bleibt trotzdem alles
        // still, wenigstens hier melden
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(25))
            guard approving.contains(entry), isSuggestion(entry), approvalError == nil else { return }
            approving.remove(entry)
            approvalError = "Keine Rückmeldung vom Kernel: Der Eintrag ist nach 25 s weiter ein Vorschlag."
        }
    }

    private func missing(_ id: String) -> String {
        "„\(id)“ steht nicht mehr im Katalog (inzwischen geändert oder entfernt). Katalog neu laden und erneut versuchen."
    }

    private func delete(_ entry: CatalogFocus) {
        guard let catalog = model.catalog else { return }
        dismissedError = nil
        switch entry {
        case .item(let id):
            guard let item = catalog.item(id) else { return }
            model.catalogActions?.deleteCatalogEntry(kind: "teil", id: id, ebene: item.ebene)
        case .material(let id):
            guard let m = catalog.material(id) else { return }
            model.catalogActions?.deleteCatalogEntry(kind: "material", id: id, ebene: m.ebene)
        }
    }

    /// Demomodus: Formular für Fensterbilder gleich öffnen (KEVCAD_DEMO_FORM=teil|material).
    private func openDemoFormIfRequested() {
        guard let kind = session.demo?.config.form, form == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if kind == "material" {
                var d = CatalogMaterialDraft()
                d.name = "Eiche geölt"
                d.id = "eiche-geoelt"
                d.gruppe = "Holz"
                d.dichte = "0,72"
                d.farbe = "#9C6B3C"
                d.preisJeKg = "7,20"
                d.preisQuelle = "Sägewerk Schmitt"
                form = CatalogFormRequest(mode: .new, draft: .material(d), ebene: .eigen)
            } else {
                var d = CatalogItemDraft(art: "rohr")
                d.masse = ["d": "33,7", "s": "2"]
                d.material = "edelstahl-1.4301"
                d.norm = "ISO 1127"
                d.preis = "14,50"
                d.preisQuelle = AppInfo.nutzerName
                d.tags = "geländer, edelstahl"
                form = CatalogFormRequest(mode: .new, draft: .item(d), ebene: .eigen)
            }
        }
    }
}

// MARK: - Leerzustand

private struct CatalogEmptyState: View {
    @EnvironmentObject private var session: AppSession
    @ObservedObject var model: AppModel
    var retry: () -> Void

    var body: some View {
        Group {
            if case .failed(let text) = model.catalogActivity {
                if model.kernelState == .ready || model.kernelState == .busy {
                    ContentUnavailableView {
                        Label("Lagerkatalog nicht verfügbar", systemImage: "books.vertical")
                    } description: {
                        Text(text)
                    } actions: {
                        Button("Erneut versuchen", action: retry)
                        Button("Protokoll zeigen") { session.showLog() }
                    }
                } else {
                    noKernel
                }
            } else if model.kernelState == .ready || model.kernelState == .busy || AppInfo.isDemoMode {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Lagerkatalog wird geladen …").foregroundStyle(.secondary)
                }
            } else {
                noKernel
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noKernel: some View {
        ContentUnavailableView {
            Label("Kein Kernel verbunden", systemImage: "bolt.horizontal.circle")
        } description: {
            Text("Materialien und Lagerteile kommen vom Kernel. Sobald er läuft, lädt der Lagerkatalog von selbst.")
        } actions: {
            Button("Kernel neu starten") { model.actions?.restartKernel() }
            Button("Protokoll zeigen") { session.showLog() }
        }
    }
}

// MARK: - Seitenleiste

private struct CatalogSidebar: View {
    let catalog: Catalog
    let level: CatalogLevel?
    @Binding var section: CatalogSection?

    private var items: [CatalogItem] { catalog.items.filter { level == nil || $0.ebene == level } }
    private var materials: [CatalogMaterial] { catalog.materials.filter { level == nil || $0.ebene == level } }

    private var arten: [String] {
        // Zukaufteile stehen in einem eigenen Abschnitt
        let present = Set(catalog.items.map(\.art)).subtracting([ZukaufDraft.art])
        let ordered = (catalog.arten + catalog.items.map(\.art)).filter(present.contains)
        var seen = Set<String>()
        return ordered.filter { seen.insert($0).inserted }.sorted {
            (CatalogSchema.order(of: $0), $0) < (CatalogSchema.order(of: $1), $1)
        }
    }

    private var groups: [String] {
        let names = Set(catalog.materials.map(\.gruppe).filter { !$0.isEmpty })
        return names.sorted {
            let a = CatalogSchema.materialGroups.firstIndex(of: $0) ?? 99, b = CatalogSchema.materialGroups.firstIndex(of: $1) ?? 99
            return (a, $0) < (b, $1)
        }
    }

    var body: some View {
        List(selection: $section) {
            if catalog.suggestionCount > 0 || section == .suggestions {
                Section("Vorschläge von Claude") {
                    HStack {
                        Label("Zu prüfen", systemImage: "sparkles")
                        Spacer(minLength: 4)
                        Text(KevFormat.integer(catalog.suggestionCount))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(catalog.suggestionCount > 0 ? Color.orange : Color.secondary))
                    }
                    .tag(CatalogSection.suggestions)
                }
            }
            Section("Lagerteile") {
                row("Alle Lagerteile", symbol: "square.stack.3d.up", count: items.filter { !$0.isZukauf }.count)
                    .tag(CatalogSection.allItems)
                ForEach(arten, id: \.self) { art in
                    row(CatalogSchema.art(art).plural, symbol: CatalogSchema.art(art).symbol,
                        count: items.filter { $0.art == art }.count)
                        .tag(CatalogSection.art(art))
                }
            }
            Section("Zukaufteile") {
                row("Alle Zukaufteile", symbol: "cart", count: items.filter(\.isZukauf).count)
                    .tag(CatalogSection.art(ZukaufDraft.art))
            }
            Section("Materialien") {
                row("Alle Materialien", symbol: "paintpalette", count: materials.count).tag(CatalogSection.allMaterials)
                ForEach(groups, id: \.self) { g in
                    row(g, symbol: "circle.lefthalf.filled", count: materials.filter { $0.gruppe == g }.count)
                        .tag(CatalogSection.group(g))
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ title: String, symbol: String, count: Int) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer(minLength: 4)
            Text(KevFormat.integer(count))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Liste

private struct CatalogList: View {
    @ObservedObject var model: AppModel
    let catalog: Catalog
    let section: CatalogSection
    let level: CatalogLevel?
    let search: String
    @Binding var selection: CatalogFocus?
    var onEdit: (CatalogFocus) -> Void
    var onCopy: (CatalogFocus) -> Void
    var onDelete: (CatalogFocus) -> Void
    var onApprove: (CatalogFocus) -> Void
    var onShowSuggestions: () -> Void

    private var tokens: [String] { CatalogSearch.tokens(search) }

    private var items: [CatalogItem] {
        let t = tokens
        return CatalogSearch.sorted(catalog.items).filter { item in
            if let level, item.ebene != level { return false }
            if case .art(let art) = section, item.art != art { return false }
            if section == .allItems, item.isZukauf { return false }
            if section == .suggestions, !item.vorgeschlagen { return false }
            return CatalogSearch.matches(item, tokens: t, material: catalog.material(item.material))
        }
    }

    private var materials: [CatalogMaterial] {
        let t = tokens
        return catalog.materials.filter { m in
            if let level, m.ebene != level { return false }
            if case .group(let g) = section, m.gruppe != g { return false }
            if section == .suggestions, !m.vorgeschlagen { return false }
            return CatalogSearch.matches(m, tokens: t)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        let suggestions = section == .suggestions
        let materialsShown = section.showsMaterials
        let items = materialsShown ? [] : self.items
        let materials = materialsShown || suggestions ? self.materials : []
        List(selection: $selection) {
            if suggestions {
                let zukauf = items.filter(\.isZukauf)
                if !zukauf.isEmpty {
                    Section("Zukaufteile") {
                        ForEach(zukauf) { item in
                            SuggestionRow(onApprove: { onApprove(.item(item.id)) }, onReject: { onDelete(.item(item.id)) }) {
                                ZukaufItemRow(model: model, item: item)
                            }
                            .tag(CatalogFocus.item(item.id))
                            .contextMenu { menu(.item(item.id), editable: item.ebene.isEditable, id: item.id, suggested: true) }
                        }
                    }
                }
                let stock = items.filter { !$0.isZukauf }
                if !stock.isEmpty {
                    Section("Lagerteile") {
                        ForEach(stock) { item in
                            SuggestionRow(onApprove: { onApprove(.item(item.id)) }, onReject: { onDelete(.item(item.id)) }) {
                                ItemRow(item: item, material: catalog.material(item.material))
                            }
                            .tag(CatalogFocus.item(item.id))
                            .contextMenu { menu(.item(item.id), editable: item.ebene.isEditable, id: item.id, suggested: true) }
                        }
                    }
                }
                if !materials.isEmpty {
                    Section("Materialien") {
                        ForEach(materials) { m in
                            SuggestionRow(onApprove: { onApprove(.material(m.id)) }, onReject: { onDelete(.material(m.id)) }) {
                                MaterialRow(material: m)
                            }
                            .tag(CatalogFocus.material(m.id))
                            .contextMenu { menu(.material(m.id), editable: m.ebene.isEditable, id: m.id, suggested: true) }
                        }
                    }
                }
            } else if materialsShown {
                ForEach(materials) { m in
                    MaterialRow(material: m).tag(CatalogFocus.material(m.id))
                        .contextMenu { menu(.material(m.id), editable: m.ebene.isEditable, id: m.id, suggested: m.vorgeschlagen) }
                }
            } else {
                ForEach(items) { item in
                    Group {
                        if item.isZukauf {
                            ZukaufItemRow(model: model, item: item)
                        } else {
                            ItemRow(item: item, material: catalog.material(item.material))
                        }
                    }
                        .tag(CatalogFocus.item(item.id))
                        .contextMenu { menu(.item(item.id), editable: item.ebene.isEditable, id: item.id, suggested: item.vorgeschlagen) }
                }
            }
        }
        .listStyle(.inset)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !suggestions, catalog.suggestionCount > 0 {
                SuggestionHint(count: catalog.suggestionCount, action: onShowSuggestions)
            }
        }
        .overlay {
            if suggestions ? (items.isEmpty && materials.isEmpty) : (materialsShown ? materials.isEmpty : items.isEmpty) {
                if !search.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView.search(text: search)
                } else if suggestions {
                    ContentUnavailableView(
                        "Keine offenen Vorschläge", systemImage: "checkmark.seal",
                        description: Text("Legt Claude neue Lagerteile oder Materialien an, erscheinen sie hier zur Freigabe."))
                } else {
                    ContentUnavailableView(
                        level.map { "Keine Einträge in „\($0.title)“" } ?? "Keine Einträge",
                        systemImage: materialsShown ? "paintpalette" : "shippingbox",
                        description: Text(section == .art(ZukaufDraft.art)
                            ? "Mit + fügst du ein Zukaufteil per Shop-Link, Herstellernummer oder EAN hinzu."
                            : "Mit + legst du ein neues \(materialsShown ? "Material" : "Lagerteil") an."))
                }
            }
        }
    }

    @ViewBuilder
    private func menu(_ entry: CatalogFocus, editable: Bool, id: String, suggested: Bool = false) -> some View {
        if suggested {
            Button("Freigeben") { onApprove(entry) }
            Button("Ablehnen …") { onDelete(entry) }
            Divider()
        }
        if editable {
            Button("Bearbeiten …") { onEdit(entry) }
        }
        Button(editable ? "Duplizieren …" : "Als eigenes Teil kopieren …") { onCopy(entry) }
        Divider()
        Button("ID kopieren") { copyToPasteboard(id) }
        if editable {
            Divider()
            Button("Löschen …", role: .destructive) { onDelete(entry) }
        }
    }
}

private struct ItemRow: View {
    let item: CatalogItem
    let material: CatalogMaterial?

    var body: some View {
        HStack(spacing: 10) {
            ArtTile(art: item.art, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Text(item.preisText ?? "–")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(item.preisText == nil ? .tertiary : .primary)
                if item.vorgeschlagen {
                    SuggestionBadge()
                } else if item.ebene != .mitgeliefert {
                    LevelBadge(level: item.ebene)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var detail: String {
        var parts: [String] = []
        if let norm = item.norm { parts.append(norm) }
        parts.append(material?.name ?? item.material)
        if let kg = item.kgJeM { parts.append("\(KevFormat.compact(kg)) kg/m") }
        return parts.joined(separator: " · ")
    }
}

private struct MaterialRow: View {
    let material: CatalogMaterial

    var body: some View {
        HStack(spacing: 10) {
            MaterialSwatch(hex: material.farbe, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(material.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if material.druckbar {
                        Image(systemName: "printer.fill")
                            .font(.caption)
                            .foregroundStyle(.teal)
                            .help("Druckbar: Filament für 3D-Druckteile")
                    }
                }
                Text("\(material.gruppe) · \(KevFormat.compact(material.dichte)) g/cm³")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Text(material.preisJeKg.map { "\(KevFormat.number($0, digits: 2)) €/kg" } ?? "–")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(material.preisJeKg == nil ? .tertiary : .primary)
                if material.vorgeschlagen {
                    SuggestionBadge()
                } else if material.ebene != .mitgeliefert {
                    LevelBadge(level: material.ebene)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Vorschläge von Claude

/// Etikett „Vorschlag“ für Einträge mit `status: "vorgeschlagen"`.
struct SuggestionBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkles").font(.system(size: 9, weight: .semibold))
            Text("Vorschlag")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.orange)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color.orange.opacity(0.15)))
        .help("Von Claude vorgeschlagen, wartet auf deine Freigabe")
    }
}

/// Zeile im Abschnitt „Vorschläge“: Eintrag mit Knöpfen zum Freigeben und Ablehnen.
private struct SuggestionRow<Content: View>: View {
    var onApprove: () -> Void
    var onReject: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            content
            Button(action: onReject) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Ablehnen")
            Button("Freigeben", action: onApprove)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }
}

/// Hinweis oben in der Liste, solange Vorschläge offen sind.
private struct SuggestionHint: View {
    var count: Int
    var action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.orange)
            Text("Claude hat \(KevFormat.count(count, one: "Eintrag", many: "Einträge")) vorgeschlagen")
                .font(.callout)
            Spacer(minLength: 6)
            Button("Prüfen", action: action)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
    }
}
