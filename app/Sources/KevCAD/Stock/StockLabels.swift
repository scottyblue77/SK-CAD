import AppKit
import KevCADCore
import SwiftUI

// Phase 2: gemeinsame Bausteine für Stückliste, Lagerkatalog und Inspektor.

extension AppModel {
    /// Phase-2-Aktionen (Stückliste, Katalog), falls der App-Kern bzw. die Demo sie anbietet.
    var catalogActions: CatalogActions? { actions as? CatalogActions }

    /// Anzeigename eines Materials aus dem Lagerkatalog, sonst die ID.
    func materialName(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return catalog?.material(id)?.name ?? id
    }

    /// Zeile der Stückliste, in der ein Teil steckt.
    func bomLine(for partID: String) -> BOMLine? { bom?.line(containing: partID) }

    /// Material eines Teils für die Anzeige: Katalogname, Name aus der Stückliste oder die Angabe aus model.py.
    func materialTitle(for part: PartNode) -> String? {
        let id = part.stock?.material ?? part.material
        guard let id, !id.isEmpty else { return nil }
        if let m = catalog?.material(id) { return m.name }
        if let name = bomLine(for: part.id)?.material { return name }
        return id.contains("-") ? id : id.capitalized
    }
}

extension CatalogLevel {
    var shortTitle: String {
        switch self {
        case .mitgeliefert: return "Mitgeliefert"
        case .eigen: return "Eigen"
        case .projekt: return "Projekt"
        }
    }

    var color: Color {
        switch self {
        case .mitgeliefert: return .secondary
        case .eigen: return .blue
        case .projekt: return .purple
        }
    }

    var symbol: String {
        switch self {
        case .mitgeliefert: return "shippingbox"
        case .eigen: return "person.crop.circle"
        case .projekt: return "folder"
        }
    }

    var detail: String {
        switch self {
        case .mitgeliefert: return "Mit SK-CAD geliefert, nur ansehen"
        case .eigen: return "Dein eigener Katalog, gilt in allen Projekten"
        case .projekt: return "Nur in diesem Projekt (katalog.json im Projektordner)"
        }
    }
}

/// Etikett der Katalog-Ebene.
struct LevelBadge: View {
    var level: CatalogLevel

    var body: some View {
        Badge(text: level.shortTitle, color: level == .mitgeliefert ? .gray : level.color)
            .help(level.detail)
    }
}

extension Color {
    /// sRGB aus "#8A9099" (auch ohne #, dreistellig erlaubt).
    init?(hex: String) {
        guard let norm = CatalogMaterialDraft.normalizedHex(hex), let v = UInt32(norm.dropFirst(), radix: 16) else {
            return nil
        }
        self.init(
            .sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255)
    }

    /// sRGB-Hex für das Formular.
    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

/// Farbfleck eines Materials.
struct MaterialSwatch: View {
    var hex: String?
    var size: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: size / 4, style: .continuous)
            .fill(hex.flatMap(Color.init(hex:)) ?? Color.gray.opacity(0.4))
            .overlay(
                RoundedRectangle(cornerRadius: size / 4, style: .continuous)
                    .strokeBorder(.primary.opacity(0.2), lineWidth: 0.5)
            )
            .frame(width: size, height: size)
    }
}

/// Symbol einer Art in einer kleinen Kachel (Liste, Details).
struct ArtTile: View {
    var art: String
    var size: CGFloat = 24
    var tint: Color = .accentColor

    var body: some View {
        Image(systemName: CatalogSchema.art(art).symbol)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).fill(tint.opacity(0.12)))
    }
}

/// Text in die Zwischenablage.
func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
