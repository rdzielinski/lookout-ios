import SwiftUI

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - Lookout Design System
// Central source of truth for all visual tokens and shared UI utilities.
// Import this file; all other Lookout views depend on the types defined here.
// ──────────────────────────────────────────────────────────────────────────────

// MARK: - Skill Category Color Extension
// Placed here so every view gets the same mapping without duplicating it.
extension SkillCategory {
    /// The canonical skill color for this category.
    /// Named `skillColor` (not `accentColor`) to avoid ambiguity with
    /// SwiftUI's built-in `Color.accentColor` / `View.accentColor`.
    var skillColor: Color {
        switch self {
        case .flight:   return LookoutColor.flight
        case .landmark: return LookoutColor.landmark
        case .music:    return LookoutColor.music
        case .plant:    return LookoutColor.nature
        case .vehicle:  return LookoutColor.vehicle
        case .product:  return LookoutColor.product
        case .unknown:  return LookoutColor.unknown
        }
    }
}

// MARK: - Color Tokens
enum LookoutColor {
    // ── Background palette ──────────────────────────────────────────────
    /// Deepest background — screen base
    static let backgroundPrimary   = Color(red: 0.04, green: 0.04, blue: 0.07)
    /// Card base (before blur layer)
    static let backgroundCard      = Color(red: 0.10, green: 0.10, blue: 0.14)
    /// Elevated surface (e.g. settings row)
    static let backgroundElevated  = Color(red: 0.13, green: 0.13, blue: 0.18)

    // ── Glass tints ─────────────────────────────────────────────────────
    static let glassFill           = Color.white.opacity(0.08)
    static let glassBorderSubtle   = Color.white.opacity(0.10)
    static let glassBorderMedium   = Color.white.opacity(0.20)
    static let glassBorderStrong   = Color.white.opacity(0.35)

    // ── Text ─────────────────────────────────────────────────────────────
    static let textPrimary         = Color.white
    static let textSecondary       = Color.white.opacity(0.55)
    static let textTertiary        = Color.white.opacity(0.35)

    // ── Interactive ──────────────────────────────────────────────────────
    static let interactive         = Color(red: 0.17, green: 0.44, blue: 0.93)
    static let interactiveHover    = Color(red: 0.23, green: 0.48, blue: 0.96)
    static let destructive         = Color(red: 1.00, green: 0.27, blue: 0.23)

    // ── Skill categories ─────────────────────────────────────────────────
    static let flight   = Color(red: 0.29, green: 0.62, blue: 1.00)  // #4A9EFF
    static let landmark = Color(red: 1.00, green: 0.62, blue: 0.04)  // #FF9F0A
    static let music    = Color(red: 0.75, green: 0.35, blue: 0.95)  // #BF5AF2
    static let nature   = Color(red: 0.20, green: 0.78, blue: 0.35)  // #34C759
    static let vehicle  = Color(red: 1.00, green: 0.27, blue: 0.23)  // #FF453A
    static let product  = Color(red: 0.35, green: 0.78, blue: 0.98)  // #5AC8FA
    static let unknown  = Color(red: 0.56, green: 0.56, blue: 0.58)  // #8E8E93
}

// MARK: - Spacing Tokens
enum LookoutSpacing {
    static let xs:  CGFloat = 4
    static let sm:  CGFloat = 8
    static let md:  CGFloat = 12
    static let lg:  CGFloat = 16
    static let xl:  CGFloat = 20
    static let xxl: CGFloat = 24
    static let screenMargin: CGFloat = 16
}

// MARK: - Corner Radius Tokens
enum LookoutRadius {
    static let chip:   CGFloat = 9
    static let small:  CGFloat = 10
    static let medium: CGFloat = 14
    static let card:   CGFloat = 16
    static let large:  CGFloat = 18
    static let result: CGFloat = 24
}

// MARK: - Shadow Tokens
struct LookoutShadow {
    static let card = Shadow(color: .black.opacity(0.28), radius: 16, x: 0, y: 8)
    static let button = Shadow(color: .black.opacity(0.32), radius: 20, x: 0, y: 8)

    static func categoryGlow(_ color: Color, intensity: Double = 1.0) -> Shadow {
        Shadow(color: color.opacity(0.40 * intensity), radius: 24, x: 0, y: 0)
    }

    struct Shadow {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }
}

// MARK: - Glass Card Modifier
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = LookoutRadius.card
    var accentColor: Color = .clear
    var accentIntensity: Double = 0.22
    var borderColor: Color = LookoutColor.glassBorderMedium

    func body(content: Content) -> some View {
        content
            .background(glassBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                accentColor.opacity(accentIntensity * 2),
                                borderColor
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            )
    }

    private var glassBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LookoutColor.backgroundCard)

            // Sheen
            LinearGradient(
                colors: [Color.white.opacity(0.06), Color.clear],
                startPoint: .topLeading, endPoint: .center
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

            // Category accent glow (top-left radial)
            if accentColor != .clear {
                RadialGradient(
                    colors: [accentColor.opacity(accentIntensity), Color.clear],
                    center: .topLeading, startRadius: 0, endRadius: 200
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        }
    }
}

extension View {
    /// Apply the Lookout glass card treatment.
    func lookoutGlassCard(
        cornerRadius: CGFloat = LookoutRadius.card,
        accentColor: Color = .clear,
        accentIntensity: Double = 0.22,
        borderColor: Color = LookoutColor.glassBorderMedium
    ) -> some View {
        modifier(GlassCard(
            cornerRadius: cornerRadius,
            accentColor: accentColor,
            accentIntensity: accentIntensity,
            borderColor: borderColor
        ))
    }

    /// Standard card shadow.
    func lookoutCardShadow(color: Color = .black, opacity: Double = 0.28, radius: CGFloat = 16, y: CGFloat = 8) -> some View {
        shadow(color: color.opacity(opacity), radius: radius, x: 0, y: y)
    }

    /// Category glow halo.
    func categoryGlow(_ color: Color, intensity: Double = 1.0) -> some View {
        shadow(color: color.opacity(0.40 * intensity), radius: 22, x: 0, y: 0)
    }
}

// MARK: - Skill Badge Component
struct SkillBadge: View {
    let category: SkillCategory
    var size: BadgeSize = .small

    enum BadgeSize { case small, medium }

    var body: some View {
        HStack(spacing: size == .small ? 4 : 5) {
            Image(systemName: category.iconName)
                .font(size == .small ? .system(size: 9, weight: .semibold) : .caption)
                .foregroundStyle(category.skillColor)

            Text(category.badgeName)
                .font(size == .small
                    ? .system(size: 9, weight: .bold, design: .rounded)
                    : .caption.weight(.bold).monospaced()
                )
                .fontDesign(.rounded)
                .foregroundStyle(category.skillColor)
        }
        .padding(.horizontal, size == .small ? 7 : 9)
        .padding(.vertical, size == .small ? 3 : 4)
        .background(category.skillColor.opacity(0.20), in: RoundedRectangle(cornerRadius: LookoutRadius.chip, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LookoutRadius.chip, style: .continuous)
                .strokeBorder(category.skillColor.opacity(0.30), lineWidth: 0.6)
        )
    }
}

// MARK: - Glass Divider
struct GlassDivider: View {
    var color: Color = .white
    var opacity: Double = 0.08

    var body: some View {
        Rectangle()
            .fill(color.opacity(opacity))
            .frame(height: 0.5)
    }
}

// MARK: - Circular Glass Button
struct CircularGlassButton: View {
    let icon: String
    var size: CGFloat = 40
    var iconSize: Font = .title3
    var iconWeight: Font.Weight = .semibold
    var accentColor: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(iconSize.weight(iconWeight))
                .foregroundStyle(accentColor)
                .frame(width: size, height: size)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
                .overlay(
                    Circle().strokeBorder(LookoutColor.glassBorderMedium, lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Atmospheric Background (reusable)
struct AtmosphericBackground: View {
    var categoryColor: Color = .cyan
    var intensity: Double = 1.0
    @Binding var phase: Double

    var body: some View {
        ZStack {
            // Base vignette
            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.clear, Color.black.opacity(0.65)],
                startPoint: .top, endPoint: .bottom
            )

            // Category orb — top left, shifts with phase
            RadialGradient(
                colors: [categoryColor.opacity(0.22 * intensity), Color.clear],
                center: .init(x: 0.15 + phase * 0.08, y: 0.08 + phase * 0.04),
                startRadius: 0, endRadius: 320
            )
            .animation(.easeInOut(duration: 6).repeatForever(autoreverses: true), value: phase)

            // Cyan secondary orb — top right
            RadialGradient(
                colors: [Color.cyan.opacity((0.12 + phase * 0.05) * intensity), Color.clear],
                center: .init(x: 0.88 - phase * 0.06, y: 0.05 + phase * 0.03),
                startRadius: 0, endRadius: 280
            )
            .animation(.easeInOut(duration: 10).repeatForever(autoreverses: true), value: phase)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

// MARK: - Shimmer Modifier
struct ShimmerEffect: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0),
                            Color.white.opacity(0.18),
                            Color.white.opacity(0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.5)
                    .offset(x: phase * (geo.size.width * 1.5))
                }
                .clipped()
            )
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerEffect())
    }
}

// MARK: - Press Scale Effect
struct PressScaleEffect: ButtonStyle {
    var scale: CGFloat = 0.95

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressScaleEffect {
    static var pressScale: PressScaleEffect { .init() }
    static func pressScale(_ scale: CGFloat) -> PressScaleEffect { .init(scale: scale) }
}

// MARK: - Lookout Primary Button
struct LookoutPrimaryButton: View {
    let title: String
    var icon: String? = nil
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView().tint(.white).scaleEffect(0.85)
                } else {
                    Text(title)
                        .font(.headline)
                    if let icon {
                        Image(systemName: icon).font(.headline)
                    }
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: LookoutRadius.medium, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [LookoutColor.interactive, LookoutColor.interactive.opacity(0.78)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                    RoundedRectangle(cornerRadius: LookoutRadius.medium, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                }
            )
            .shadow(color: LookoutColor.interactive.opacity(0.45), radius: 18, y: 6)
        }
        .buttonStyle(.pressScale(0.97))
        .disabled(isLoading)
    }
}

// MARK: - Empty State View
struct LookoutEmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.22))

            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.35))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
