import SwiftUI

/// Design tokens, spec source: ~/studio/n1-lab/DESIGN.md ("scientific instrument" character)
enum N1Design {
    /// Background #0B0C0E — near-black, not pure black
    static let bg = Color(red: 0.043, green: 0.047, blue: 0.055)
    /// Data ink #F4F4F0 — paper white
    static let ink = Color(red: 0.957, green: 0.957, blue: 0.941)
    /// Signal #5EEAD4 — the only accent color, at most one per screen
    static let signal = Color(red: 0.369, green: 0.918, blue: 0.831)
    /// Warning #FBBF24 — reserved for uncertainty and adherence prompts
    static let warn = Color(red: 0.984, green: 0.749, blue: 0.141)

    static let muted = ink.opacity(0.55)
    static let faint = ink.opacity(0.28)
    static let card = Color.white.opacity(0.045)
}

extension Font {
    /// Hypotheses and conclusions: serif, like a paper
    static func n1Serif(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    /// All numbers are monospaced — instrument-readout feel
    static func n1Mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Instrument-panel card
struct InstrumentCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(N1Design.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.07)))
    }
}

/// Section label: monospaced, uppercase, restrained
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.n1Mono(11, weight: .semibold))
            .tracking(2.5)
            .foregroundStyle(N1Design.muted)
            .textCase(.uppercase)
    }
}
