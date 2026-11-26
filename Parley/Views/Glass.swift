import SwiftUI

// Liquid Glass on iPhone and iPad. visionOS has its own glass and no Liquid Glass API, so there
// the same calls use its glass background and standard bordered buttons.

extension View {
    /// Liquid Glass behind the view, or visionOS's glass there.
    func parleyGlass<S: InsettableShape>(tint: Color? = nil, interactive: Bool = false, in shape: S) -> some View {
        #if os(visionOS)
        self
            .background(tint ?? .clear, in: shape)
            .glassBackgroundEffect(in: shape)
        #else
        self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        #endif
    }

    func parleyGlass() -> some View {
        parleyGlass(in: .capsule)
    }
}

extension PrimitiveButtonStyle where Self == ParleyGlassButtonStyle {
    static var parleyGlass: ParleyGlassButtonStyle { ParleyGlassButtonStyle(prominent: false) }
    static var parleyGlassProminent: ParleyGlassButtonStyle { ParleyGlassButtonStyle(prominent: true) }
}

struct ParleyGlassButtonStyle: PrimitiveButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        #if os(visionOS)
        if prominent {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                .buttonStyle(.borderedProminent)
        } else {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                .buttonStyle(.bordered)
        }
        #else
        if prominent {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                .buttonStyle(.glassProminent)
        } else {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                .buttonStyle(.glass)
        }
        #endif
    }
}

/// Groups glass shapes so they blend; just a container on visionOS.
struct ParleyGlassGroup<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        #if os(visionOS)
        content
        #else
        GlassEffectContainer(spacing: spacing) { content }
        #endif
    }
}
