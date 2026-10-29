//  GlassHelpers.swift — Liquid Glass on iOS 26+, Material fallback before that
//  (the Viu Live TV pattern).
import SwiftUI

struct GlassCardBackground: ViewModifier {
    var cornerRadius: CGFloat = 16
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

struct GlassControlBackground: ViewModifier {
    var cornerRadius: CGFloat = 16
    var tint: Color? = nil
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                content.glassEffect(.regular.tint(tint).interactive(), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                content.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 16) -> some View { modifier(GlassCardBackground(cornerRadius: cornerRadius)) }
    func glassControl(cornerRadius: CGFloat = 16, tint: Color? = nil) -> some View { modifier(GlassControlBackground(cornerRadius: cornerRadius, tint: tint)) }
}

struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content
    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
