import SwiftUI

/// Conductor's shared flat/minimal design vocabulary.
/// Hairline-bordered flat cards replace `.ultraThinMaterial`/`.thinMaterial` blur,
/// and monochrome tags replace colored `.opacity(0.15)` capsules.

extension Color {
    static let cardBorder = Color.primary.opacity(0.08)
    static let cardBackground = Color.primary.opacity(0.03)
}

struct CardStyle: ViewModifier {
    var padding: CGFloat = 12
    var cornerRadius: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.cardBorder, lineWidth: 1)
            )
    }
}

extension View {
    /// Flat, hairline-bordered card surface — replaces .ultraThinMaterial/.thinMaterial everywhere.
    func cardStyle(padding: CGFloat = 12, cornerRadius: CGFloat = 10) -> some View {
        modifier(CardStyle(padding: padding, cornerRadius: cornerRadius))
    }
}

struct TagStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.06))
            .foregroundStyle(.secondary)
            .clipShape(Capsule())
    }
}

extension View {
    /// Monochrome pill for tags/badges — replaces colored .opacity(0.15) capsules (ticket ids, review/status badges).
    func tagStyle() -> some View {
        modifier(TagStyle())
    }
}
