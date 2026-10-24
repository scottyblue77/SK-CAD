import AppKit
import KevCADCore
import SwiftUI

extension Notification.Name {
    /// Nur Selbsttest: der offene Dialog „Zukaufteil hinzufügen …“ soll wie mit „Hinzufügen“ sichern.
    static let zukaufSelfTestSubmit = Notification.Name("KevCADZukaufSelfTestSubmit")
}

/// Selbsttest Zukaufteile in der Testvariante, mit dem Ersatz-Kernel (`fake_kernel.py --zukauf`) oder dem echten
/// Kernel: `KEVCAD_SELFTEST=zukauf`, `KEVCAD_DOWNLOADS_DIR=<Temp-Ordner>` (nie das echte Downloads),
/// optional `KEVCAD_SELFTEST_PAUSE=<s>` für Fensterbilder (an jeder Stelle „BILD <name> <Fenster>“ auf stderr).
/// Mit dem echten Kernel: Projekt mit einem verbauten Zukaufteil (Ersatzkörper) und einem Vorschlag von Claude öffnen
/// (MCP), dazu echte STEP-Dateien `KEVCAD_SELFTEST_STEP` (igus WJRM-01-10, Zylinder Ø 19 × 29) und
/// `KEVCAD_SELFTEST_STEP_WAGEN` (CAD für das verbaute Zukaufteil); ohne sie schreibt der Test Platzhalter-Dateien.
///
/// Prüft: Zukaufteil im Teilebaum (vereinfacht, halbtransparent), Stückliste mit Hersteller und Link, Lagerkatalog mit
/// Zukaufteilen und Vorschlag, Freigabe des Vorschlags, Dialog → ZUKAUF_NEU → wartet auf CAD (Beobachtung im
/// Temp-Ordner), neue Datei → Rückfrage → ZUKAUF_CAD → importiert, CAD-Datei für das verbaute Teil → neu gerechnet mit
/// Hersteller-CAD. Ergebnis im Protokoll und in `<Datenordner>/selftest-zukauf.txt`.
@MainActor
enum ZukaufSelfTest {
    private static var started = false

    static func runIfRequested(_ session: AppSession) {
        guard !started, session.demo == nil, AppInfo.isTestVariant,
              ProcessInfo.processInfo.environment["KEVCAD_SELFTEST"] == "zukauf"
        else { return }
        started = true
        Task { await run(session) }
    }

    private static var pause: Double {
        Double(ProcessInfo.processInfo.environment["KEVCAD_SELFTEST_PAUSE"] ?? "") ?? 0
    }

    private static func run(_ session: AppSession) async {
        let model = session.model
        var lines: [String] = []
        var passed = true
        func check(_ ok: Bool, _ text: String) {
            passed = passed && ok
            let line = "\(ok ? "OK    " : "FEHLER") \(text)"
            lines.append(line)
            model.append(LogLine(level: ok ? .info : .error, text: "Selbsttest Zukauf: \(line)"))
        }
        func wait(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return condition()
        }
        /// Stelle für ein Fensterbild: Marke auf stderr, dann warten.
        func shot(_ name: String, window: String) async {
            guard pause > 0 else { return }
            try? await Task.sleep(for: .milliseconds(900))
            FileHandle.standardError.write(Data("[selbsttest-zukauf] BILD \(name) \(window)\n".utf8))
            try? await Task.sleep(for: .seconds(pause))
        }
        guard let actions = model.zukaufActions else {
            check(false, "keine ZukaufActions")
            return finish(lines, passed)
        }
        let downloads = AppInfo.downloadsDirectory
        let isTemp = downloads.path.hasPrefix(FileManager.default.temporaryDirectory.path)
            || downloads.path.hasPrefix("/tmp") || downloads.path.hasPrefix("/private/tmp")
            || downloads.path.contains("/scratchpad")
        check(isTemp, "Downloads-Ordner ist ein Temp-Ordner: \(downloads.path)")
        guard isTemp else { return finish(lines, passed) }

        // 1. Verbautes Zukaufteil: Teilebaum, Viewer, Stückliste (der echte Kernel braucht beim ersten Lauf länger)
        check(await wait(120) { model.bom != nil && !model.isRunning && model.parts.contains { $0.zukauf != nil } },
              "Lauf mit Zukaufteil fertig")
        let wagenID = model.parts.first(where: { $0.zukauf != nil })?.zukauf?.id ?? "alutec-05200"
        if let wagen = model.parts.first(where: { $0.zukauf != nil }) {
            check(wagen.zukauf?.isSimplified == true, "\(wagen.id): vereinfacht (\(wagen.zukauf?.title ?? "?"))")
            check(session.controller?.scene.simplifiedParts.contains(wagen.id) == true, "Ersatzkörper halbtransparent")
            await shot("viewport-vereinfacht", window: model.project?.name ?? "SK-CAD")
            model.actions?.select([wagen.id])
        }
        let line = model.bom?.lines.first { $0.art == "zukaufteil" }
        check(line?.zukauf?.hersteller != nil && line?.zukauf?.mpn != nil && line?.preisJe != nil
              && line?.zukauf?.url != nil && line?.zukauf?.vereinfacht == true,
              "Stücklistenzeile Zukaufteil: \(line?.benennung ?? "fehlt"), \(line?.zukauf?.title ?? "-"), "
              + "\(line?.preisJe.map(KevFormat.euro) ?? "-"), \(line?.zukauf?.url?.host ?? "kein Link")")
        await shot("projekt-vereinfacht", window: model.project?.name ?? "SK-CAD")

        // 2. Lagerkatalog: Zukaufteile als eigene Gruppe, Vorschlag von Claude, Freigabe wie mit „Freigeben“
        session.showCatalog(focus: .item(wagenID))
        check(await wait(10) { model.catalog?.items.contains { $0.isZukauf } == true }, "Zukaufteile im Lagerkatalog")
        let suggestion = model.catalog?.items.first { $0.isZukauf && $0.vorgeschlagen }
        check(suggestion != nil, "Vorschlag von Claude: \(suggestion?.name ?? "fehlt")")
        await shot("katalog-zukauf", window: "Lagerkatalog")
        if let suggestion {
            model.catalogActions?.saveCatalogEntry(kind: "teil", json: Catalog.approvedJSON(suggestion.json),
                                                   ebene: suggestion.ebene.isEditable ? suggestion.ebene : .eigen)
            check(await wait(10) { model.catalog?.item(suggestion.id)?.vorgeschlagen == false },
                  "Vorschlag freigegeben: \(suggestion.id)")
            await shot("katalog-freigegeben", window: "Lagerkatalog")
        }

        // 3. Dialog: Eingabe (Link eines Teils, das schon im Katalog steht), dann Felder bestätigen, Hinzufügen
        session.showZukaufDialog(.new(input: "https://www.beispiel-shop.de/p/alutec-05200"))
        try? await Task.sleep(for: .milliseconds(800))
        await shot("dialog-eingabe", window: "Zukaufteil hinzufügen")
        var draft = ZukaufDraft(input: "https://www.beispiel-shop.de/p/igus-wjrm-01-10")
        draft.hersteller = "igus"
        draft.mpn = "WJRM-01-10"
        draft.gtin = "4044918812108"
        draft.name = "igus drylin Linearlager WJRM-01-10"
        draft.id = draft.suggestedID()
        draft.preis = "12,85"
        draft.brutto = false
        draft.form = .zylinder
        draft.masse = ["d": "19", "l": "29"]
        draft.gewicht = "12"
        check(draft.validate().isEmpty, "Entwurf gültig: \(draft.validate().map(\.message))")
        session.showZukaufDialog(ZukaufDialogRequest(mode: .new, draft: draft, ebene: .projekt, startWithFields: true))
        try? await Task.sleep(for: .milliseconds(800))
        await shot("dialog-felder", window: "Zukaufteil hinzufügen")
        NotificationCenter.default.post(name: .zukaufSelfTestSubmit, object: nil)
        let gesendet = Date()
        check(await wait(30) {
            if case .accepted(let id, _) = model.zukaufActivity { return id == draft.id } else { return false }
        }, "ZUKAUF_NEU angenommen nach \(String(format: "%.1f", Date().timeIntervalSince(gesendet))) s: "
            + "\(model.zukaufActivity)")
        check(await wait(20) { model.zukaufStatus(for: draft.id)?.isWaiting == true }, "wartet auf CAD")
        check(model.zukaufStatus(for: draft.id)?.cadLinks.isEmpty == false,
              "CAD-Links: \(model.zukaufStatus(for: draft.id)?.cadLinks.map(\.titel) ?? [])")
        check(model.watchedDownloads?.standardizedFileURL == downloads.standardizedFileURL,
              "Beobachtung läuft: \(model.watchedDownloads?.path ?? "aus")")
        await shot("dialog-wartet", window: "Zukaufteil hinzufügen")

        // 4. Neue Datei in Downloads (in zwei Stücken geschrieben) → Rückfrage → übernehmen
        let env = ProcessInfo.processInfo.environment
        func stepData(_ key: String) -> Data {
            if let path = env[key], let data = FileManager.default.contents(atPath: path), !data.isEmpty { return data }
            return Data(String(repeating: "ISO-10303-21;\n", count: 6000).utf8)
        }
        let file = downloads.appendingPathComponent("WJRM-01-10.step")
        let content = stepData("KEVCAD_SELFTEST_STEP")
        let half = content.count / 2
        try? content.prefix(half).write(to: file)
        try? await Task.sleep(for: .milliseconds(300))
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile()
            h.write(content.suffix(from: half))
            try? h.close()
        }
        check(await wait(8) { model.downloadOffer?.fileName == file.lastPathComponent }, "Rückfrage zu \(file.lastPathComponent)")
        check(model.downloadOffer?.size == Int64(content.count), "erst gemeldet, als die Datei fertig war")
        session.dismissZukaufWindow()
        await shot("rueckfrage", window: model.project?.name ?? "SK-CAD")
        if let teil = model.downloadOffer?.candidates.first { actions.acceptDownload(for: teil) }
        check(await wait(30) { model.zukaufStatus(for: draft.id)?.zustand == .importiert },
              "importiert: \(model.zukaufStatus(for: draft.id)?.text ?? "-")")
        check(await wait(3) { model.watchedDownloads == nil }, "Beobachtung beendet, sobald nichts mehr wartet")

        // 5. CAD für das verbaute Zukaufteil selbst gewählt → neu gerechnet mit Hersteller-CAD
        let wagenFile = downloads.appendingPathComponent("\(wagenID).stp")
        try? stepData("KEVCAD_SELFTEST_STEP_WAGEN").write(to: wagenFile)
        actions.assignCAD(file: wagenFile, to: wagenID)
        check(await wait(60) { model.parts.first { $0.zukauf?.id == wagenID }?.zukauf?.cad == .hersteller && !model.isRunning },
              "\(wagenID) mit Hersteller-CAD neu gerechnet: \(model.parts.filter { $0.zukauf?.id == wagenID }.map(\.id))")
        check(session.controller?.scene.simplifiedParts.isEmpty == true, "kein Ersatzkörper mehr")
        check(await wait(5) { model.bom?.lines.first { $0.art == "zukaufteil" }?.zukauf?.vereinfacht == false },
              "Stückliste: CAD-Quelle \(model.bom?.lines.first { $0.art == "zukaufteil" }?.zukauf?.cadTitle ?? "?")")
        await shot("projekt-hersteller", window: model.project?.name ?? "SK-CAD")
        finish(lines, passed)
    }

    private static func finish(_ lines: [String], _ passed: Bool) {
        let text = (lines + [passed ? "Ergebnis: bestanden" : "Ergebnis: FEHLER"]).joined(separator: "\n") + "\n"
        try? text.write(to: AppInfo.supportDirectory.appendingPathComponent("selftest-zukauf.txt"), atomically: true,
                        encoding: .utf8)
        FileHandle.standardError.write(Data("[selbsttest-zukauf]\n\(text)".utf8))
    }
}

extension AppSession {
    /// Fenster „Zukaufteil hinzufügen …“ schließen (Selbsttest).
    func dismissZukaufWindow() {
        NSApp.windows.first { $0.title == "Zukaufteil hinzufügen" }?.close()
    }
}
