import Foundation

/// Feste Angaben zur laufenden App: Variante, Datenordner, Socket, Port, Ort des Kernels.
public enum AppInfo {
    /// Bundle-ID der laufenden App (`de.upvis.kevcad` oder `de.upvis.kevcad.test`).
    public static var bundleID: String { Bundle.main.bundleIdentifier ?? "de.upvis.kevcad.dev" }

    /// Testvariante („Kev CAD Test“, auch mit Zusatz): eigener Datenordner, eigener Port, Fenster auf dem zweiten Monitor.
    public static var isTestVariant: Bool { bundleID.contains(".test") }

    /// Datenordner der App unter Application Support, je Variante getrennt.
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Unix-Socket zwischen App und Kernel-Server.
    public static var kernelSocket: URL { supportDirectory.appendingPathComponent("kernel.sock") }

    /// Port für MCP über HTTP auf 127.0.0.1 (Info.plist-Schlüssel `KevCADPort`, gesetzt von build.sh).
    public static var mcpPort: Int {
        if let s = Bundle.main.object(forInfoDictionaryKey: "KevCADPort") as? String, let p = Int(s) { return p }
        return isTestVariant ? 47824 : 47823
    }

    /// Demomodus ohne Kernel (Umgebungsvariable `KEVCAD_DEMO=1`), für Arbeiten an der Oberfläche.
    public static var isDemoMode: Bool { ProcessInfo.processInfo.environment["KEVCAD_DEMO"] == "1" }

    /// Repo-Ordner, aus dem die App gebaut wurde (Info.plist-Schlüssel `KevCADRepo`, gesetzt von build.sh).
    public static var repoDirectory: URL? {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "KevCADRepo") as? String, !path.isEmpty,
              !path.hasPrefix("$(")
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Startbefehl des Kernels: `<repo>/kernel/.venv/bin/kevcad-kernel`.
    public static var kernelExecutable: URL? {
        repoDirectory?.appendingPathComponent("kernel/.venv/bin/kevcad-kernel")
    }

    /// Name, mit dem die Oberfläche den Nutzer nennt (SK-CAD; Info.plist-Schlüssel `KevCADNutzer`, gesetzt über
    /// `KEVCAD_USER_NAME` in app/project.yml). Ohne Eintrag (etwa in Tests) gilt „Sebastian“.
    public static var nutzerName: String {
        if let s = Bundle.main.object(forInfoDictionaryKey: "KevCADNutzer") as? String, !s.isEmpty, !s.hasPrefix("$(") {
            return s
        }
        return "Sebastian"
    }

    /// Standardordner für Projekte.
    public static var projectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Kev CAD", isDirectory: true)
    }
}
