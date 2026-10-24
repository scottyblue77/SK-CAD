import AppKit
import KevCADCore
import SwiftUI

/// Willkommensfenster: links Neues Projekt, Öffnen und der Hinweis zu Claude, rechts „Zuletzt geöffnet“.
struct WelcomeView: View {
    @EnvironmentObject private var session: AppSession
    @ObservedObject var recents: RecentProjects
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showNewProject = false

    var body: some View {
        HStack(spacing: 0) {
            leftPane
                .frame(width: 400)
            RecentProjectsList(recents: recents)
                .frame(width: 380)
        }
        .frame(height: 500)
        .background(WindowHook(placement: .centered) { window in
            session.welcomeWindow = window
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            // Beim Start mit schon offenem Projekt nicht aufblitzen (siehe launchFinished).
            window.alphaValue = session.model.project != nil ? 0 : 1
        })
        .sheet(isPresented: $showNewProject) {
            NewProjectSheet()
        }
        .onAppear {
            session.attach(openWindow: openWindow, dismissWindow: dismissWindow)
            BauplanExportSelfTest.projektOeffnen(session)  // Phase 6, P6-A2: öffnet sein Projekt selbst
            DruckSelfTest.projektOeffnen(session)  // Druckvorschau: öffnet sein Projekt selbst
            DruckerSelbsttest.projektOeffnen(session)  // Phase 8: öffnet sein Projekt selbst
            MaterialSelfTest.projektOeffnen(session)  // Strang „Material“: ebenso
            RestDruckSelbsttest.projektOeffnen(session)  // Strang „Rest Druck“: ebenso
            SimulationSelfTest.projektOeffnen(session)  // Bereich Simulation: ebenso
            if session.launchFinished() { return }
            recents.refresh()
            consumeNewProjectRequest()
        }
        .onChange(of: session.newProjectRequested) { consumeNewProjectRequest() }
    }

    private func consumeNewProjectRequest() {
        guard session.newProjectRequested else { return }
        session.newProjectRequested = false
        showNewProject = true
    }

    // MARK: Links

    private var leftPane: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 4)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
            Text("SK-CAD")
                .font(.system(size: 32, weight: .semibold))
                .padding(.top, 10)
            HStack(spacing: 6) {
                Text(AppSession.versionText)
                    .foregroundStyle(.secondary)
                if AppInfo.isTestVariant { Badge(text: "Testvariante", color: .orange) }
                if AppInfo.isDemoMode { Badge(text: "Demomodus", color: .purple) }
            }
            .font(.callout)
            .padding(.top, 2)

            VStack(spacing: 6) {
                WelcomeAction(
                    symbol: "plus.rectangle.on.folder", title: "Neues Projekt …",
                    detail: "Ordner unter \(KevFormat.abbreviatedPath(AppInfo.projectsDirectory.path))",
                    shortcut: "⌘N"
                ) { showNewProject = true }
                WelcomeAction(
                    symbol: "folder", title: "Projekt öffnen …", detail: "Ordner mit model.py wählen", shortcut: "⌘O"
                ) { session.presentOpenPanel() }
            }
            .padding(.top, 26)
            .padding(.horizontal, 36)

            Spacer(minLength: 16)
            ClaudeHint()
                .padding(.horizontal, 24)
                .padding(.bottom, 22)
        }
        .frame(maxHeight: .infinity)
    }
}

/// Großer Knopf im Willkommensfenster.
private struct WelcomeAction: View {
    var symbol: String
    var title: String
    var detail: String
    var shortcut: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.tint.opacity(0.12)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.medium))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(shortcut)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Kurzer Hinweis, wie Claude verbunden wird (PLAN-MVP.md Abschnitt 11).
private struct ClaudeHint: View {
    @EnvironmentObject private var session: AppSession
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle").foregroundStyle(.tint)
                Text("Mit Claude verbinden").font(.callout.weight(.semibold))
                Spacer()
                Text("MCP-Port \(String(AppInfo.mcpPort))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text("Einmal im Terminal ausführen. Danach kann Claude Code Projekte öffnen, rechnen, messen und Bilder machen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(AppSession.claudeCommand.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 10.5, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    session.copyClaudeCommand()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .frame(width: 14)
                }
                .buttonStyle(.borderless)
                .help("Befehl kopieren")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

/// Kleines farbiges Etikett.
struct Badge: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}
