import SwiftUI

struct PrivacyWelcomeView: View {
    @Environment(\.dismiss) var dismiss
    var onComplete: (() -> Void)? = nil

    // Entrance animation state
    @State private var heroScale: CGFloat = 0.7
    @State private var heroOpacity: Double = 0
    @State private var titleOffset: CGFloat = 24
    @State private var titleOpacity: Double = 0
    @State private var cardsOpacity: Double = 0
    @State private var cardsOffset: CGFloat = 40
    @State private var ctaOpacity: Double = 0
    @State private var orbPhase: Double = 0

    // Section expand state
    @State private var expandedSection: PrivacySection? = .onDevice

    enum PrivacySection: String, CaseIterable {
        case onDevice  = "Stays on Your Device"
        case sent      = "Sent for Analysis"
        case never     = "We Never"
    }

    var body: some View {
        ZStack {
            // ── Background ──────────────────────────────────────────────
            backgroundLayer

            // ── Content ─────────────────────────────────────────────────
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    heroSection
                        .padding(.top, 64)
                        .padding(.bottom, 36)

                    privacySections
                        .padding(.bottom, 32)

                    ctaSection
                        .padding(.bottom, 52)
                }
                .padding(.horizontal, 20)
            }
        }
        .ignoresSafeArea()
        .onAppear { runEntranceAnimation() }
    }

    // MARK: - Background
    private var backgroundLayer: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.07)
                .ignoresSafeArea()

            // Animated orb — top center
            RadialGradient(
                colors: [
                    Color(red: 0.17, green: 0.44, blue: 0.93).opacity(0.28 + orbPhase * 0.08),
                    Color.clear
                ],
                center: .init(x: 0.5, y: -0.05 + orbPhase * 0.04),
                startRadius: 0,
                endRadius: 420
            )
            .ignoresSafeArea()

            // Bottom ambient
            RadialGradient(
                colors: [Color.cyan.opacity(0.06), Color.clear],
                center: .init(x: 0.8, y: 1.1),
                startRadius: 0,
                endRadius: 380
            )
            .ignoresSafeArea()

            // Fine noise-like grain overlay (simulated with dots)
            Canvas { context, size in
                var rng = SeededRandom(seed: 42)
                for _ in 0..<320 {
                    let x = rng.next() * size.width
                    let y = rng.next() * size.height
                    let r = rng.next() * 1.2
                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                        with: .color(.white.opacity(0.025 + rng.next() * 0.03))
                    )
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    // MARK: - Hero Section
    private var heroSection: some View {
        VStack(spacing: 20) {
            // Glowing eye icon
            ZStack {
                // Outer glow ring
                Circle()
                    .stroke(
                        RadialGradient(
                            colors: [Color.cyan.opacity(0.6), Color.clear],
                            center: .center, startRadius: 0, endRadius: 56
                        ),
                        lineWidth: 1
                    )
                    .frame(width: 112, height: 112)
                    .blur(radius: 2)

                // Glass disc
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 96, height: 96)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.35), Color.cyan.opacity(0.2)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Color.cyan.opacity(0.25), radius: 20, y: 0)

                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.white, Color.cyan.opacity(0.85)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
            }
            .scaleEffect(heroScale)
            .opacity(heroOpacity)

            // Title + subtitle
            VStack(spacing: 10) {
                Text("Your Privacy Matters")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text("Before you start scanning, here's exactly\nhow Lookout handles your data.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            .offset(y: titleOffset)
            .opacity(titleOpacity)
        }
    }

    // MARK: - Privacy Sections
    private var privacySections: some View {
        VStack(spacing: 12) {
            privacyCard(
                section: .onDevice,
                icon: "iphone",
                accentColor: Color(red: 0.20, green: 0.78, blue: 0.35),
                items: [
                    ("person.crop.circle.fill",    "Saved faces & face data"),
                    ("pawprint.fill",              "Pet names & visual descriptions"),
                    ("mappin.circle.fill",         "Saved places & locations"),
                    ("cart.fill",                  "Product scan history & preferences"),
                    ("brain.fill",                 "Your \"About You\" personal context"),
                    ("key.fill",                   "API keys"),
                    ("chart.bar.fill",             "Scan history & statistics"),
                ],
                footnote: nil
            )

            privacyCard(
                section: .sent,
                icon: "arrow.up.circle",
                accentColor: Color(red: 1.00, green: 0.62, blue: 0.04),
                items: [
                    ("camera.fill",   "Photos you scan — sent to your chosen AI (Claude or OpenAI) for identification"),
                    ("mic.fill",      "Voice follow-ups — converted to text on-device, text sent to AI"),
                    ("barcode",       "Barcodes — looked up via free public databases"),
                    ("music.note",    "Audio clips — sent to Apple's ShazamKit for music ID"),
                ],
                footnote: "Photos and voice text are sent only when you tap Scan or ask a follow-up. Nothing is sent in the background."
            )

            privacyCard(
                section: .never,
                icon: "xmark.shield.fill",
                accentColor: Color(red: 1.00, green: 0.27, blue: 0.23),
                items: [
                    ("eye.slash.fill",                       "Sell or share your data with anyone"),
                    ("antenna.radiowaves.left.and.right",    "Collect data in the background"),
                    ("person.3.fill",                        "Create accounts or track you"),
                    ("server.rack",                          "Store anything on our servers — there are none"),
                    ("megaphone.fill",                       "Show ads of any kind"),
                ],
                footnote: nil
            )
        }
        .opacity(cardsOpacity)
        .offset(y: cardsOffset)
    }

    // MARK: - CTA
    private var ctaSection: some View {
        VStack(spacing: 14) {
            Button(action: completeOnboarding) {
                HStack(spacing: 10) {
                    Text("Got It — Let's Go")
                        .font(.headline)
                    Image(systemName: "arrow.right")
                        .font(.headline)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.17, green: 0.44, blue: 0.93),
                                        Color(red: 0.12, green: 0.34, blue: 0.78)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                    }
                )
                .shadow(color: Color(red: 0.17, green: 0.44, blue: 0.93).opacity(0.45), radius: 18, y: 6)
            }
            .buttonStyle(.plain)

            Text("Review anytime in Settings → Privacy & Data")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.3))
                .multilineTextAlignment(.center)
        }
        .opacity(ctaOpacity)
    }

    // MARK: - Privacy Card
    private func privacyCard(
        section: PrivacySection,
        icon: String,
        accentColor: Color,
        items: [(String, String)],
        footnote: String?
    ) -> some View {
        let isExpanded = expandedSection == section

        return VStack(alignment: .leading, spacing: 0) {
            // Header — always visible, tappable
            Button {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                    expandedSection = isExpanded ? nil : section
                }
            } label: {
                HStack(spacing: 12) {
                    // Icon badge
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(accentColor.opacity(0.2))
                            .frame(width: 36, height: 36)
                        Image(systemName: icon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(accentColor)
                    }

                    Text(section.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)

                    Spacer()

                    // Chevron
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.4))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))

                    // Item count badge
                    Text("\(items.count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(accentColor)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(accentColor.opacity(0.18), in: Capsule())
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
            }
            .buttonStyle(.plain)

            // Expandable body
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    // Thin divider
                    Rectangle()
                        .fill(accentColor.opacity(0.2))
                        .frame(height: 0.5)
                        .padding(.horizontal, 16)

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: item.0)
                                    .font(.caption)
                                    .foregroundStyle(accentColor.opacity(0.8))
                                    .frame(width: 18)
                                    .padding(.top, 2)

                                Text(item.1)
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.75))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .lineSpacing(2)
                            }
                        }

                        if let footnote = footnote {
                            Text(footnote)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.4))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(cardSurface(accentColor: accentColor))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            accentColor.opacity(isExpanded ? 0.45 : 0.22),
                            Color.white.opacity(0.08)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        )
        .shadow(
            color: isExpanded ? accentColor.opacity(0.18) : .black.opacity(0.2),
            radius: isExpanded ? 16 : 8, y: 4
        )
    }

    private func cardSurface(accentColor: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.10, green: 0.10, blue: 0.14))

            RadialGradient(
                colors: [accentColor.opacity(0.10), Color.clear],
                center: .topLeading, startRadius: 0, endRadius: 180
            )

            LinearGradient(
                colors: [Color.white.opacity(0.05), Color.clear],
                startPoint: .topLeading, endPoint: .center
            )
        }
    }

    // MARK: - Entrance Animation
    private func runEntranceAnimation() {
        // Start orb drift
        withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) {
            orbPhase = 1
        }

        // Hero icon
        withAnimation(.spring(response: 0.7, dampingFraction: 0.65).delay(0.1)) {
            heroScale = 1; heroOpacity = 1
        }

        // Title
        withAnimation(.easeOut(duration: 0.55).delay(0.35)) {
            titleOffset = 0; titleOpacity = 1
        }

        // Cards
        withAnimation(.easeOut(duration: 0.5).delay(0.55)) {
            cardsOpacity = 1; cardsOffset = 0
        }

        // CTA
        withAnimation(.easeOut(duration: 0.45).delay(0.75)) {
            ctaOpacity = 1
        }
    }

    private func completeOnboarding() {
        if let onComplete { onComplete() } else { dismiss() }
    }
}

// MARK: - Seeded Random (for deterministic grain)
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let result = Double((state >> 33) & 0x7FFF_FFFF) / Double(0x7FFF_FFFF)
        return result
    }
}

#Preview {
    PrivacyWelcomeView()
}
