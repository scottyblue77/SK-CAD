import AppKit
import KevCADCore
import SwiftUI

// Oberfläche von Kev CAD (AP4). Zuständig für alles in app/Sources/KevCAD (siehe CLAUDE.md).
//
// Drei Fenster: Willkommen (ohne offenes Projekt), Projekt (ein Projekt zur Zeit, wie AppModel) und Protokoll.
// Beim Start erscheint immer zuerst das Willkommensfenster (SwiftUI öffnet nur die erste Szene verlässlich); ist schon
// ein Projekt offen, wechselt es sofort unsichtbar zum Projektfenster (AppSession.launchFinished).

@main
struct KevCADApp: App {
    @StateObject private var session = AppSession()

    init() {
        // Nur eine Instanz je Variante: läuft schon eine (Tools-Stapel, Start durch die Claude-Brücke), diese nach vorn
        // holen und selbst gleich wieder beenden. Zwei Instanzen würden sich Socket und MCP-Port streitig machen.
        let me = NSRunningApplication.current
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: AppInfo.bundleID)
            .first(where: { $0.processIdentifier != me.processIdentifier && !$0.isTerminated })
        {
            other.activate()
            exit(0)
        }
        // Fenster stellt die App selbst her (aus dem AppModel), nicht die macOS-Fensterwiederherstellung. Ohne diese
        // Vorgabe merkt sich macOS nach einem Start ohne Fenster „keine Fenster“ und öffnet beim nächsten Start nichts,
        // trotz restorationBehavior(.disabled).
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
    }

    var body: some Scene {
        Window("Willkommen bei SK-CAD", id: WindowID.welcome) {
            WelcomeView(recents: session.recents)
                .environmentObject(session)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .keyboardShortcut("1", modifiers: [.command, .shift])
        .commands {
            KevCADCommands(session: session, model: session.model, recents: session.recents)
            SidebarCommands()
            InspectorCommands()
            DemoCommands(session: session)
            StockCommands(session: session, model: session.model)
            BestandCommands(model: session.model)
            ZukaufCommands(session: session, model: session.model)
            AnimationCommands(model: session.model, animation: session.model.animation)
            VersionenCommands(model: session.model, store: session.model.versionen)
            DokumenteCommands(model: session.model)  // Phase 6: Bereich Dokumente, PDF, Drucken
            MaterialCommands(session: session, model: session.model)  // Bereiche ⌘1 bis ⌘3, Schnellansichten, Material
            // Phase 6, P6-A2: Dokumente exportieren (⇧⌘E), Durchspielen
            DokumenteExportCommands(session: session, model: session.model, bauplan: session.model.bauplan)
            RenderCommands(model: session.model)  // Phase 7: Rendern … (⌥⌘R)
            SimulationCommands(model: session.model)  // Bereich Simulation (⌘4): Lastfälle, Kräfte, Lager, Rechnen
        }

        Window("SK-CAD", id: WindowID.project) {
            ProjectWindow(model: session.model)
                .environmentObject(session)
        }
        .defaultSize(width: 1400, height: 900)
        .windowToolbarStyle(.unified)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Protokoll", id: WindowID.log) {
            LogWindow(model: session.model)
                .environmentObject(session)
        }
        .defaultSize(width: 860, height: 520)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .keyboardShortcut("l", modifiers: [.command, .option])

        // Phase 2: Lagerkatalog (Fenster > Lagerkatalog, ⇧⌘K)
        Window("Lagerkatalog", id: WindowID.catalog) {
            CatalogWindow(model: session.model)
                .environmentObject(session)
        }
        .defaultSize(width: 1140, height: 720)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .keyboardShortcut("k", modifiers: [.command, .shift])

        // Phase 3: Zukaufteil hinzufügen (Ablage-Menü, Lagerkatalog)
        Window("Zukaufteil hinzufügen", id: WindowID.zukauf) {
            ZukaufDialogWindow(model: session.model)
                .environmentObject(session)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}
