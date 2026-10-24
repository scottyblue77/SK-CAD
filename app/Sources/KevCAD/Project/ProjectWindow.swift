import Combine
import KevCADCore
import SwiftUI

/// Projektfenster: links Teilebaum, Mitte Viewport mit Schnellansichten und Statusleiste, rechts Inspektor. Dazu die
/// Bereiche „Dokumente“ (⌘2) und „Material“ (⌘3) mit eigener Seitenleiste, Mitte und eigenem Inspektor, und
/// „Simulation“ (⌘4): eigene Seitenleiste und eigener Inspektor um denselben Viewport, darunter die Ergebnisse.
struct ProjectWindow: View {
    @EnvironmentObject private var session: AppSession
    @ObservedObject var model: AppModel
    @StateObject private var state = ProjectWindowState()
    @StateObject private var versionen = VersionenZustand()
    @StateObject private var dokumente = DokumenteZustand()  // Phase 6: Bereich Dokumente
    /// Strang „Material“: Bereich Material. Bewusst nicht beobachtet (gehört zum Fensterzustand): Auswahl, Suche und
    /// Abschnitt sollen nicht das ganze Fenster samt verdecktem 3D-Bereich neu zeichnen; das tun die Ansichten selbst.
    private var material: MaterialZustand { state.materialZustand }
    @State private var columns = NavigationSplitViewVisibility.all
    /// Breite von Viewport und Stückliste (links der Versionsleiste), für `platzFuerLeiste`.
    @State private var modellBreite: CGFloat = 0
    @State private var modellMitLeiste = false
    /// Gewählter Lastfall im Bereich Simulation, für den Untertitel: das Fenster beobachtet den SimulationStore nicht
    /// (sonst zeichnete jeder Griff-Zug das ganze Fenster neu), nur dessen Auswahl.
    @State private var simulationAuswahl: String?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if model.project != nil {
                content
            } else {
                NoProjectView()
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .background(WindowHook(placement: .large) { session.projectWindow = $0 })
        .focusedSceneObject(state)
        .focusedSceneObject(versionen)
        .focusedSceneObject(dokumente)
        .navigationTitle(model.project?.name ?? "SK-CAD")
        .navigationSubtitle(untertitel)
        .modifier(DruckerDialoge(model: model))  // Phase 8: „Drucken …“ und Drucker-Einstellungen
        .modifier(RenderDialoge(model: model))  // Phase 7: „Rendern …“
        .onAppear {
            session.attach(openWindow: openWindow, dismissWindow: dismissWindow)
            BedingungenSchalter.wiederherstellen(model)
            dokumenteVerbinden()
            DokumenteSelfTest.runIfRequested(session, state: state, zustand: dokumente)
            SelfTest.runIfRequested(session)
            CatalogSelfTest.runIfRequested(session)
            ZukaufSelfTest.runIfRequested(session)
            BauplanExportSelfTest.runIfRequested(session, state: state, zustand: dokumente)  // Phase 6, P6-A2
            DruckSelfTest.runIfRequested(session, state: state)  // Druckvorschau (KEVCAD_SELFTEST=druck)
            DruckerSelbsttest.runIfRequested(session)  // Phase 8 (KEVCAD_SELFTEST=drucker)
            RenderSelbsttest.runIfRequested(session)  // Phase 7 (KEVCAD_SELFTEST=render)
            BestandSelfTest.runIfRequested(session)
            FilamentSelfTest.runIfRequested(session, state: state, material: material)  // KEVCAD_SELFTEST=filament
            RestDruckSelbsttest.runIfRequested(session, state: state, material: material)  // KEVCAD_SELFTEST=restdruck
            MaterialSelfTest.runIfRequested(session, state: state, material: material)
            SimulationSelfTest.runIfRequested(session, state: state)  // Bereich Simulation (KEVCAD_SELFTEST=simulation)
            if let config = session.demo?.config, config.usesGestell { state.schnell.oeffne(.stueckliste) }
        }
        .onChange(of: model.bom?.run) { _, _ in autoShowBOM() }
        // Untertitel „Simulation · <Lastfall>“ folgt der Auswahl sofort
        .onReceive(model.simulation.$auswahl.removeDuplicates()) { simulationAuswahl = $0 }
        // Phase 6, P6-A2: Durchspielen und „Im 3D zeigen“ aus dem Bauplan holen den 3D-Bereich nach vorn
        .onReceive(model.bauplan.$zeige3D.dropFirst()) { _ in
            withAnimation(.snappy(duration: 0.2)) { state.bereich = .modell }
        }
        .onChange(of: model.project?.path) { _, _ in  // Phase 6: anderes Projekt, andere Blätter
            dokumente.bearbeiter.vergessen()
            dokumente.auswahl = nil
            dokumente.markiert = []
            dokumente.element = nil
        }
    }

    /// Verbaut das Modell zum ersten Mal Lagerteile und ist keine Schnellansicht offen, klappt die Stückliste einmal von
    /// selbst auf.
    private func autoShowBOM() {
        guard state.schnell.offen.isEmpty, !state.bomAutoShown, let bom = model.bom,
              bom.lines.contains(where: { !$0.eigenteil })
        else { return }
        state.bomAutoShown = true
        withAnimation(.snappy(duration: 0.25)) { state.schnell.oeffne(.stueckliste) }
    }

    /// Sprünge in den Bereich „Material“ und zu den Berichten (Schnellansichten, Inspektor, Berichte, Bauplan).
    private var navigation: MaterialNavigation {
        MaterialNavigation(
            zeige: { [weak state, weak material] a, pos, sid in
                material?.zeige(a, position: pos, stockID: sid)
                state?.zeige(.material)
            },
            bericht: { [weak state, weak dokumente] art in
                BerichteUI.shared.bericht = art
                dokumente?.waehle(.berichte)
                state?.zeige(.dokumente)
            })
    }

    /// Aus dem Bereich „Material“: in den 3D-Bereich wechseln, die Teile wählen und einpassen.
    private func zeigeIm3D(_ teile: [String]) {
        state.zeige(.modell)
        model.actions?.select(teile)
        model.actions?.focus(on: teile)
    }

    /// Der Viewport ist zu sehen: im 3D-Bereich und im Bereich Simulation.
    private var zeigtViewport: Bool { state.bereich == .modell || state.bereich == .simulation }

    /// Untertitel: im 3D-Bereich der Projektordner, im Bereich Dokumente das gezeigte Blatt.
    private var untertitel: String {
        if state.bereich == .material { return "Material" }
        if state.bereich == .simulation { return "Simulation" + (simulationAuswahl.map { " · \($0)" } ?? "") }
        if state.bereich == .dokumente {
            if let id = dokumente.blattID, let e = model.dokumente.uebersicht?.blatt(id) {
                return "Dokumente · \(e.titel)"
            }
            return "Dokumente"
        }
        return model.project.map { KevFormat.abbreviatedPath($0.path.deletingLastPathComponent().path) } ?? ""
    }

    /// Bereich Dokumente: Rückgängig über das Fenster, Teile im 3D-Bereich zeigen.
    private func dokumenteVerbinden() {
        let b = dokumente.bearbeiter
        b.model = model
        b.zeige = { [weak state, weak dokumente] id in
            state?.bereich = .dokumente
            dokumente?.waehle(.blatt(id))
        }
        b.melde = { [weak dokumente] t in dokumente?.melde(t, fehler: true) }
        dokumente.zeigeIm3D = { [weak state, weak model] teile in
            withAnimation(.snappy(duration: 0.2)) { state?.bereich = .modell }
            model?.actions?.select(teile)
            model?.actions?.focus(on: teile)
        }
        state.dokumenteZustand = dokumente
    }

    private var content: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Group {
                switch state.bereich {
                case .dokumente: DokumenteSeitenleiste(model: model, store: model.dokumente, zustand: dokumente)
                case .material: MaterialSeitenleiste(model: model, material: material, navigation: navigation)
                case .simulation:
                    SimulationSeitenleiste(model: model, store: model.simulation, zustand: state.simulationZustand)
                case .modell: PartTreeView(model: model, state: state)
                }
            }
            .modifier(SpaltenBreite())
            .navigationSplitViewColumnWidth(min: 210, ideal: 260, max: 400)
        } detail: {
            // Der 3D-Bereich bleibt bestehen (Kamera, Metal-Ansicht), ruht aber, solange die Dokumente vorne sind
            ZStack {
                modellBereich  // auch im Bereich Simulation: Kräfte und Lager per Klick im Viewer
                    .opacity(zeigtViewport ? 1 : 0)
                    .allowsHitTesting(zeigtViewport)
                    .accessibilityHidden(!zeigtViewport)
                if state.bereich == .dokumente {
                    DokumenteBereich(model: model, store: model.dokumente, zustand: dokumente)
                        .transition(.opacity)
                }
                if state.bereich == .material {
                    MaterialBereich(model: model, material: material, navigation: navigation, zeigeIm3D: zeigeIm3D)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .top) {  // Bestand: Hinweis nach „Gebaut“ bzw. „Rückgängig“, mit „Rückgängig“
                VStack(spacing: 8) {
                    BuchungsBand(model: model)
                    // Freigabe (Strang „Feinschliff 2“): im 3D-Bereich zeigt es der Viewport
                    if state.bereich != .modell, let key = model.vorschlagSchluessel, state.dismissedFreigabe != key {
                        FreigabeBand(model: model, oeffnen: { state.freigabeOffen = true }) {
                            state.dismissedFreigabe = key
                        }
                    }
                }
                .padding(.top, 10)
                .padding(.horizontal, 12)
            }
            // Die Mitte nimmt genau ihre Spaltenbreite: Ist ein Inhalt (Bauplan, Berichte) im Mindestmaß breiter, drückt
            // er nicht das ganze Fenster über den Rand (Seitenleiste links und Inspektor rechts abgeschnitten)
            .modifier(SpaltenBreite())
            .clipped()
            .onChange(of: state.bereich) { _, b in
                session.controller?.viewport.mtkView?.isPaused = b != .modell && b != .simulation
                if b == .modell || b == .simulation { session.projectWindow?.makeFirstResponder(nil) }
                model.simulationActions?.setSimulationAktiv(b == .simulation)  // Kräfte und Lager im Viewer
            }
        }
        .inspector(isPresented: $state.showInspector) {
            Group {
                switch state.bereich {
                case .dokumente:
                    // kontextbezogen: Blatt, gewählter Bauplanschritt oder Einstellungen des Berichts
                    switch dokumente.auswahl {
                    case .bauplan: BauplanInspektor(model: model)
                    case .berichte: BerichteInspektor(model: model)
                    default: BlattInspektor(model: model, store: model.dokumente, zustand: dokumente)
                    }
                case .material:
                    MaterialInspektor(model: model, material: material, navigation: navigation, zeigeIm3D: zeigeIm3D)
                case .simulation:
                    SimulationInspektor(model: model, store: model.simulation, zustand: state.simulationZustand)
                case .modell:
                    InspectorView(model: model, state: state)
                }
            }
            .modifier(SpaltenBreite())
            .inspectorColumnWidth(min: 260, ideal: 300, max: 440)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) { BereichUmschalter(state: state) }  // 3D / Dokumente / Material
            switch state.bereich {
            case .dokumente:
                DokumenteToolbar(model: model, store: model.dokumente, zustand: dokumente, state: state)
            case .material:
                MaterialToolbar(model: model, material: material, state: state, navigation: navigation, session: session)
            case .simulation:
                SimulationToolbar(model: model, store: model.simulation, state: state)
            case .modell:
                modellToolbar
            }
        }
        .modifier(BestandDialoge(model: model))  // Gebaut, Erfassen, Band nach einer Buchung: in allen Bereichen
        .modifier(FreigabeDialogModifier(model: model, state: state))  // Vorschläge freigeben (Feinschliff 2)
        .modifier(ReferenzDialoge(model: model, state: state))  // Phase 4: Referenz hinzufügen, Vermessen
        .environment(\.materialNavigation, navigation)
    }

    @ToolbarContentBuilder
    private var modellToolbar: some ToolbarContent {
        ProjectToolbar(model: model, state: state, session: session)
        ToolbarItem(placement: .navigation) {  // Versionen: Variantenmenü in der Titelleiste
            VariantenMenu(model: model, store: model.versionen, zustand: versionen)
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: Binding(
                get: { versionen.zeigeLeiste },
                set: { on in withAnimation(.snappy(duration: 0.2)) { versionen.zeigeLeiste = on } }
            )) {
                Label("Versionen", systemImage: "clock.arrow.circlepath")
            }
            .help("Versionsleiste ein- oder ausblenden (⌥⌘V)")
        }
    }

    /// 3D-Bereich: Viewport mit Zeitleiste, Schnellansichten (Stückliste, Zuschnitt, Druck), Statusleiste und
    /// Versionsleiste. Die Versionsleiste ist eine Seitenleiste: Sie nimmt ihre Breite neben dem Viewport ein, Viewport
    /// und Schnellansichten werden schmaler und laufen nie unter sie (alles links davon auf die verbleibende Breite
    /// gezwungen und beschnitten). Wird es zu eng, wächst das Fenster beim Einblenden (`platzFuerLeiste`).
    private var modellBereich: some View {
            HStack(spacing: 0) {
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        ViewportArea(model: model, state: state)
                            .overlay(alignment: .bottomLeading) {  // Versionen: laufender Vergleich
                                VergleichKarte(model: model, store: model.versionen, zustand: versionen)
                                    .padding(14)
                            }
                            .overlay(alignment: .bottom) { DurchspielenLeiste(model: model) }  // Phase 6, P6-A2
                        AnimationTimeline(model: model, animation: model.animation)  // Phase 5, nur mit Animation
                        if state.bereich == .simulation {  // Bereich Simulation: Ergebnistabelle statt Schnellansichten
                            Divider()
                            SimulationErgebnisAnsicht(model: model, store: model.simulation, statik: model.statik,
                                                      zustand: state.simulationZustand)
                        } else {
                            // Strang „Material“: Stückliste und Zuschnitt kompakt, später Druck, je einzeln aufklappbar
                            SchnellansichtenBereich(model: model, state: state, gesamtHoehe: geo.size.height - 30,
                                                    aktiv: state.bereich == .modell, navigation: navigation)
                        }
                        StatusBar(model: model)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .onAppear { modellGemessen(geo.size.width) }
                    .onChange(of: geo.size.width) { _, w in modellGemessen(w) }
                }
                .frame(minWidth: 0, maxWidth: .infinity)
                .clipped()
                if versionen.zeigeLeiste && state.bereich == .modell {  // Versionen: Seitenleiste neben dem Viewport
                    Divider()
                    VersionenLeiste(model: model, store: model.versionen, zustand: versionen)
                        .fixedSize(horizontal: true, vertical: false)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .onChange(of: versionen.zeigeLeiste) { _, an in
                if an { DispatchQueue.main.async { platzFuerLeiste() } }  // nach dem Layout mit Leiste
            }
            .modifier(VersionenBlaetter(model: model, zustand: versionen))
    }

    private func modellGemessen(_ w: CGFloat) {
        modellBreite = w
        modellMitLeiste = versionen.zeigeLeiste
    }

    /// Mindestbreite von Viewport und Stückliste neben der Versionsleiste.
    static let modellMinBreite: CGFloat = 520

    /// Versionsleiste eingeblendet: Bliebe dem Viewport weniger als `modellMinBreite`, wächst das Fenster um den
    /// Fehlbetrag (so weit der Bildschirm reicht, nach links, wenn rechts kein Platz ist); im Vollbild bleibt es.
    private func platzFuerLeiste() {
        guard let fenster = session.projectWindow, !fenster.styleMask.contains(.fullScreen),
              let schirm = fenster.screen?.visibleFrame
        else { return }
        let rest = modellMitLeiste ? modellBreite : modellBreite - VersionenZustand.breite - 1
        let fehlt = Self.modellMinBreite - rest
        guard fehlt > 1 else { return }
        var f = fenster.frame
        let breite = min(schirm.width, f.width + fehlt)
        let zuwachs = breite - f.width
        guard zuwachs > 1 else { return }
        f.size.width = breite
        if f.maxX > schirm.maxX { f.origin.x = max(schirm.minX, schirm.maxX - breite) }
        fenster.setFrame(f, display: true, animate: true)
    }
}

/// Projektfenster ohne Projekt (z. B. über das Fenstermenü geöffnet).
private struct NoProjectView: View {
    @EnvironmentObject private var session: AppSession

    var body: some View {
        ContentUnavailableView {
            Label("Kein Projekt geöffnet", systemImage: "cube.transparent")
        } description: {
            Text("Lege ein neues Projekt an oder öffne einen Ordner mit model.py.")
        } actions: {
            HStack {
                Button("Neues Projekt …") { session.requestNewProject() }
                Button("Öffnen …") { session.presentOpenPanel() }
            }
        }
    }
}

/// Werkzeugleiste des Projektfensters. Alles ruft AppActions.
struct ProjectToolbar: ToolbarContent {
    @ObservedObject var model: AppModel
    @ObservedObject var state: ProjectWindowState
    let session: AppSession

    private var actions: AppActions? { model.actions }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                actions?.runModel()
            } label: {
                Label("Neu rechnen", systemImage: "arrow.clockwise")
            }
            .help("model.py neu rechnen (⌘R)")

            Toggle(isOn: Binding(get: { model.autoRun }, set: { actions?.setAutoRun($0) })) {
                Label("Auto-Lauf", systemImage: "bolt.badge.automatic")
            }
            .help(model.autoRun ? "Auto-Lauf an: rechnet nach jedem Speichern von model.py" : "Auto-Lauf aus")

            Toggle(isOn: Binding(get: { model.slowMotion }, set: { actions?.setSlowMotion($0) })) {
                Label("Zeitlupe", systemImage: "tortoise")
            }
            .help("Zeitlupe: Aufbau Teil für Teil verlangsamt zeigen")
        }

        ToolbarItemGroup(placement: .principal) {
            Menu {
                ForEach(StandardViewName.menuOrder, id: \.self) { view in
                    Button(view.title) { actions?.setStandardView(view) }
                }
                Divider()
                ForEach(StandardViewName.extraIsoOrder, id: \.self) { view in
                    Button(view.title) { actions?.setStandardView(view) }
                }
                Divider()
                Button("Alles einpassen") { actions?.focus(on: model.parts.filter(\.visible).map(\.id)) }
            } label: {
                Label("Ansicht", systemImage: "rotate.3d")
            }
            .help("Standardansichten (Tasten 1 bis 7)")

            Picker("Darstellung", selection: Binding(
                get: { model.displayStyle }, set: { actions?.setDisplayStyle($0) }
            )) {
                ForEach(DisplayStyle.allCases, id: \.self) { style in
                    Label(style.title, systemImage: style.symbol).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Darstellung: \(model.displayStyle.title)")

            Toggle(isOn: Binding(get: { model.sectionEnabled }, set: { _ in state.toggleSection(model) })) {
                Label("Schnitt", systemImage: "square.split.diagonal")
            }
            .help("Schnittebene ein oder aus (S)")

            Toggle(isOn: Binding(get: { model.measureMode }, set: { actions?.setMeasureMode($0) })) {
                Label("Messen", systemImage: "ruler")
            }
            .help("Messen: Elemente anklicken (M)")

            Toggle(isOn: Binding(
                get: { model.showConstraintSymbols }, set: { BedingungenSchalter.setzen(model, $0) }
            )) {
                Label("Bedingungen", systemImage: "link")
            }
            .disabled(model.constraintActions == nil)
            .help(model.showConstraintSymbols
                  ? "Bedingungen am Teil ausblenden (⌥⌘B)" : "Bedingungen am Teil zeigen (⌥⌘B)")

            Button {
                state.showExplode.toggle()
            } label: {
                Label("Explosion", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .help("Explosionsdarstellung (E schaltet um)")
            .popover(isPresented: $state.showExplode, arrowEdge: .bottom) {
                ExplodePopover(model: model, state: state)
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                actions?.saveScreenshot()
            } label: {
                Label("Bild speichern", systemImage: "camera")
            }
            .help("Bild der aktuellen Ansicht in output/ speichern")

            Menu {
                Button("STEP, STL und 3MF") { actions?.export(formats: ExportFormat.standard.map(\.rawValue)) }
                Divider()
                ForEach(ExportFormat.allCases) { format in
                    Button {
                        actions?.export(formats: [format.rawValue])
                    } label: {
                        Text(format.title)
                        Text(format.detail)
                    }
                }
                Divider()
                Button("Ausgabeordner im Finder zeigen") { session.revealProjectInFinder() }
            } label: {
                Label("Exportieren", systemImage: "square.and.arrow.up")
            } primaryAction: {
                actions?.export(formats: ExportFormat.standard.map(\.rawValue))
            }
            .disabled(model.parts.isEmpty)
            .help("Klick: STEP, STL und 3MF nach output/ (⌥⇧⌘E); Pfeil: einzelnes Format")

            Toggle(isOn: Binding(
                get: { state.schnell.istOffen(.stueckliste) },
                set: { _ in withAnimation(.snappy(duration: 0.2)) { state.schnell.umschalten(.stueckliste) } }
            )) {
                Label("Stückliste", systemImage: "list.bullet.rectangle")
            }
            .help("Stückliste unter dem Viewport auf- oder zuklappen (⌃⌘1); ausführlich im Bereich Material (⌘3)")

            Button {
                state.showInspector.toggle()
            } label: {
                Label("Inspektor", systemImage: "sidebar.trailing")
            }
            .help("Inspektor ein- oder ausblenden")
        }
    }
}

/// Regler für die Explosionsdarstellung.
private struct ExplodePopover: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: ProjectWindowState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Explosion").font(.headline)
                Spacer()
                Text(KevFormat.percent(model.explodeFactor))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(get: { model.explodeFactor }, set: { model.actions?.setExplode($0) }), in: 0...1
            ) {
                Text("Explosion")
            } minimumValueLabel: {
                Image(systemName: "square.stack.3d.up.fill").help("zusammengebaut")
            } maximumValueLabel: {
                Image(systemName: "square.stack.3d.forward.dottedline").help("voll auseinander")
            }
            .labelsHidden()
            HStack {
                Button("Zusammenbauen") { model.actions?.setExplode(0) }
                    .disabled(model.explodeFactor == 0)
                Spacer()
                Text("E schaltet um").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}

/// Inhalt einer Seitenspalte genau so breit wie die Spalte: Ist er im Mindestmaß breiter (lange Zeilen, Knöpfe), kürzt
/// und bricht er um, statt mittig über die Spalte hinauszuragen und links bzw. rechts abgeschnitten zu werden.
struct SpaltenBreite: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { geo in
            content.frame(width: geo.size.width, height: geo.size.height)
        }
    }
}
