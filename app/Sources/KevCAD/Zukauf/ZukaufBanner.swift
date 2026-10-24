import AppKit
import KevCADCore
import SwiftUI

/// Band über dem Viewport für Zukaufteile: Rückfrage zu einer neuen Datei in Downloads, sonst „wartet auf CAD“ mit
/// „CAD suchen“, dazu kurze Meldungen (übernommen, Fehler). Steht immer im Baum (zeigt dann nichts), damit das
/// Wegklicken erhalten bleibt.
struct ZukaufBanner: View {
    @EnvironmentObject private var session: AppSession
    @ObservedObject var model: AppModel
    @State private var dismissedWaiting: String?
    @State private var choice: String?

    private var waiting: [ZukaufStatus] { model.waitingForCAD }
    private var waitingKey: String { waiting.map { "\($0.id):\($0.text ?? "")" }.joined(separator: "|") }
    private var notices: [ZukaufStatus] {
        model.zukaufStatus.filter { $0.zustand == .importiert || $0.zustand == .fehler || $0.uebergabe != nil }
    }

    private var hasContent: Bool {
        model.downloadOffer != nil || (!waiting.isEmpty && dismissedWaiting != waitingKey) || !notices.isEmpty
    }

    var body: some View {
        // Ohne Inhalt nichts zeigen (auch keinen Abstand im Stapel darüber); der Zustand bleibt trotzdem erhalten
        if hasContent { content }
    }

    private var content: some View {
        VStack(spacing: 8) {
            if let offer = model.downloadOffer {
                offerCard(offer)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if !waiting.isEmpty, dismissedWaiting != waitingKey {
                waitingCard
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            ForEach(notices) { status in
                notice(status)
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.25), value: model.downloadOffer)
        .animation(.snappy(duration: 0.25), value: model.zukaufStatus)
        .onChange(of: model.downloadOffer?.id) { choice = nil }
    }

    // MARK: Rückfrage

    private func offerCard(_ offer: DownloadOffer) -> some View {
        let teil = choice.flatMap { offer.candidates.contains($0) ? $0 : nil } ?? offer.candidates.first ?? ""
        return Card(tint: .accentColor) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Diese Datei als CAD für „\(session.zukaufName(teil))“ übernehmen?")
                        .font(.headline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(offer.fileName) · \(ByteCountFormatter.string(fromByteCount: offer.size, countStyle: .file)) · "
                        + "neu in \(model.watchedDownloads?.lastPathComponent ?? "Downloads") um \(Self.time(offer.date))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if offer.candidates.count > 1 {
                    Picker("Für", selection: Binding(get: { teil }, set: { choice = $0 })) {
                        ForEach(offer.candidates, id: \.self) { id in Text(session.zukaufName(id)).tag(id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Zu welchem wartenden Zukaufteil die Datei gehört")
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([offer.file])
                } label: {
                    Image(systemName: "folder")
                }
                .help("Im Finder zeigen")
                Button("Nein") { model.zukaufActions?.declineDownload() }
                    .help("Diese Datei nicht übernehmen; SK-CAD wartet weiter")
                Button("Übernehmen") { model.zukaufActions?.acceptDownload(for: teil) }
                    .buttonStyle(.borderedProminent)
                    .disabled(teil.isEmpty)
            }
        }
        .frame(maxWidth: 860)
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = KevFormat.locale
        f.dateFormat = "HH:mm"
        return f.string(from: date) + " Uhr"
    }

    // MARK: Wartet auf CAD

    private var waitingCard: some View {
        let first = waiting[0]
        let links = waiting.flatMap(\.cadLinks)
        return Card(tint: .orange) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "hourglass")
                    .font(.title3)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wartet auf CAD: " + InventoryBanner.list(waiting.map { session.zukaufName($0.id) }))
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(first.text ?? "Lade die STEP-Datei beim Hersteller herunter; SK-CAD beobachtet "
                        + "\(model.watchedDownloads.map { KevFormat.abbreviatedPath($0.path) } ?? "Downloads") und fragt dann nach.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                CADSearchButton(links: links)
                Button("Datei wählen …") { session.chooseCADFile(for: first.id) }
                    .help("CAD-Datei selbst auswählen (STEP, STP oder ZIP)")
                Button {
                    dismissedWaiting = waitingKey
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Band ausblenden; SK-CAD beobachtet Downloads weiter")
            }
        }
        .frame(maxWidth: 860)
    }

    // MARK: Meldungen

    @ViewBuilder
    private func notice(_ status: ZukaufStatus) -> some View {
        let name = session.zukaufName(status.id)
        if let file = status.uebergabe {
            Pill(symbol: "arrow.down.doc", tint: .accentColor) {
                Text("\(file) wird als CAD für \(name) übernommen …")
            } trailing: {
                ProgressView().controlSize(.small)
            }
        } else if status.zustand == .importiert {
            Pill(symbol: "checkmark.circle.fill", tint: .green) {
                // Der Kernel schreibt „CAD für … übernommen: Datei, n Körper“ schon vollständig (nicht doppelt zeigen)
                Text(status.text.map { $0.hasPrefix("CAD für") ? $0 : "CAD für \(name) übernommen · \($0)" }
                     ?? "CAD für \(name) übernommen")
            } trailing: {
                EmptyView()
            }
        } else {
            Pill(symbol: "xmark.octagon.fill", tint: .red) {
                Text("CAD für \(name): \(status.text ?? "Fehler")")
            } trailing: {
                Button("OK") { model.zukaufActions?.dismissZukaufStatus(status.id) }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
    }
}

/// Karte mit Glas-Hintergrund und farbigem Rand (wie das Band „Nicht aus dem Inventar“).
private struct Card<Content: View>: View {
    var tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.05)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(tint.opacity(0.4), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
            }
    }
}
