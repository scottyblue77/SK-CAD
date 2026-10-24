import KevCADCore
import SwiftUI

/// Drucker-Einstellungen (Phase 8): Name, IP, Seriennummer und Zugangscode (nur in den Schlüsselbund), Weg,
/// „Status lesen“. Gefundene Drucker im LAN (passiv gehört) lassen sich mit Name und IP übernehmen.
struct DruckerEinstellungen: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var drucker: DruckerStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = "P1P"
    @State private var ip = ""
    @State private var seriennummer = ""
    @State private var zugangscode = ""
    @State private var weg: DruckWeg = .a
    @State private var statusLesen = false
    @State private var fehler: String?
    @State private var loeschenFragen = false

    init(model: AppModel) {
        self.model = model
        _drucker = ObservedObject(wrappedValue: model.drucker)
    }

    private var status: DruckerStatus { drucker.status ?? DruckerStatus() }
    private var id: String { drucker.aktiver?.id ?? "p1p" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Drucker-Einstellungen", systemImage: "printer.dotmatrix").font(.title2.weight(.semibold))
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("IP-Adresse", text: $ip, prompt: Text("z. B. 192.168.178.40"))
                    if !status.gefunden.isEmpty { gefunden }
                } header: {
                    Text("Drucker")
                }
                Section {
                    TextField("Seriennummer", text: $seriennummer,
                              prompt: Text(drucker.zugangGespeichert ? "gespeichert (leer lassen = unverändert)" : "am Drucker oder in Bambu Studio unter „Gerät“"))
                    SecureField("Zugangscode", text: $zugangscode,
                                prompt: Text(drucker.zugangGespeichert ? "gespeichert (leer lassen = unverändert)" : "am Drucker: Einstellungen → WLAN"))
                    Text("Seriennummer und Zugangscode liegen nur im Schlüsselbund von macOS, nie in einer Datei. Damit "
                         + "der Kernel sie ohne Rückfrage lesen kann, erlaubt SK-CAD dort dem Programm „security“ den "
                         + "Zugriff; dadurch kann jedes Programm unter deinem Benutzer den Zugangscode ohne Rückfrage "
                         + "lesen. Bei Weg A erlaubt der Code nur, den Status zu lesen.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Image(systemName: drucker.zugangGespeichert ? "key.fill" : "key")
                            .foregroundStyle(drucker.zugangGespeichert ? Color.green : Color.secondary)
                        Text(drucker.zugangGespeichert ? "Zugangsdaten im Schlüsselbund" : "Keine Zugangsdaten gespeichert")
                            .font(.callout)
                        Spacer()
                        Button("Zugangsdaten löschen", role: .destructive) { loeschenFragen = true }
                            .disabled(!drucker.zugangGespeichert)
                    }
                } header: {
                    Text("Zugang")
                }
                Section {
                    Toggle("Status lesen (Fortschritt, Temperaturen, Fehler)", isOn: $statusLesen)
                    Text("SK-CAD verbindet sich dann im LAN nur lesend mit dem Drucker. Lesen ist auch im Cloud-Modus "
                         + "erlaubt; ob die zusätzliche Verbindung ganz ohne Nebenwirkung bleibt, ist nicht belegt. "
                         + "Deshalb ist es anfangs aus.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Picker("Weg", selection: $weg) {
                        Text("A · In Bambu Studio öffnen (Handy-App bleibt)").tag(DruckWeg.a)
                        Text("B · Direkt drucken (LAN-only, Developer Mode)").tag(DruckWeg.b)
                            .disabled(!status.wegB.moeglich)
                    }
                    .pickerStyle(.radioGroup)
                    if !status.wegB.moeglich {
                        DisclosureGroup("Weg B gesperrt: \(status.wegB.grund ?? "Developer Mode nicht nachgewiesen.")") {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(status.wegB.anleitung.enumerated()), id: \.offset) { i, s in
                                    Text("\(i + 1). \(s)").font(.caption).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .font(.caption)
                    }
                } header: {
                    Text("Status und Weg")
                }
            }
            .formStyle(.grouped)
            if let f = fehler {
                Label(f, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sichern") { sichern() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 580, height: 780)
        .onAppear(perform: laden)
        .confirmationDialog("Zugangsdaten löschen?", isPresented: $loeschenFragen) {
            Button("Löschen", role: .destructive) {
                do {
                    try model.druckerActions?.druckerZugangLoeschen(id: id)
                    statusLesen = false
                } catch {
                    fehler = error.localizedDescription
                }
            }
        } message: {
            Text("Seriennummer und Zugangscode werden aus dem Schlüsselbund entfernt; „Status lesen“ geht danach aus.")
        }
    }

    private var gefunden: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Im LAN gehört").font(.caption).foregroundStyle(.secondary)
            ForEach(status.gefunden) { g in
                HStack {
                    Image(systemName: drucker.istEingetragen(g) ? "checkmark.circle.fill" : "printer")
                        .foregroundStyle(drucker.istEingetragen(g) ? Color.green : Color.secondary)
                    Text("\(g.name) (\(g.modell)), \(g.ip)" + (g.verbindung.map { ", \($0 == "cloud" ? "Cloud-Modus" : "LAN-Modus")" } ?? ""))
                        .font(.callout)
                    Spacer()
                    Button("Übernehmen") {
                        name = g.name
                        ip = g.ip
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func laden() {
        guard let e = drucker.aktiver else { return }
        name = e.name
        ip = e.ip
        weg = e.weg
        statusLesen = e.statusLesen
    }

    private func sichern() {
        var e = drucker.aktiver ?? DruckerEintrag()
        e.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? "P1P" : name.trimmingCharacters(in: .whitespaces)
        e.ip = ip.trimmingCharacters(in: .whitespaces)
        e.weg = weg == .b && status.wegB.moeglich ? .b : .a
        e.statusLesen = statusLesen
        if statusLesen && e.ip.isEmpty {
            fehler = "Für „Status lesen“ fehlt die IP-Adresse."
            return
        }
        if statusLesen && !drucker.zugangGespeichert && (seriennummer.isEmpty || zugangscode.isEmpty) {
            fehler = "Für „Status lesen“ bitte Seriennummer und Zugangscode eintragen."
            return
        }
        do {
            try model.druckerActions?.druckerSpeichern(e, seriennummer: seriennummer.isEmpty ? nil : seriennummer,
                                                       zugangscode: zugangscode.isEmpty ? nil : zugangscode)
            seriennummer = ""
            zugangscode = ""
            dismiss()
        } catch {
            fehler = error.localizedDescription
        }
    }
}
