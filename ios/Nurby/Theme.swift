import SwiftUI

/// Design tokens from the spec: Day (light grey) and Nord (dark), Apple system signal colors.
enum Theme {
    static func ground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x2E3440) : Color(hex: 0xE5E9F0)
    }
    static let accent = Color.blue                       // system blue: actions + agent
    static let agent = Color.blue
    static let free = Color.cyan                         // free geometry, visible sketches
    static let selected = Color.green                    // selected faces
    static let selectedEdge = Color.orange               // selected edges (read better than green on a face)
    static func selection(_ kind: DesignModel.Pick.Kind) -> Color { kind == .edge ? selectedEdge : selected }
    static let conflict = Color.red
    static func selectedRow(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.09) : .black.opacity(0.055)
    }
    static let panelRadius: CGFloat = 40
    static let rowRadius: CGFloat = 11
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// A round header button: one symbol on a faint disc, 34 pt.
struct HeaderIcon: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .frame(width: 34, height: 34)
            .background(.primary.opacity(0.07), in: .circle)
            .contentShape(.circle)
    }
}
