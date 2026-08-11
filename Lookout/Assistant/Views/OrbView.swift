import SwiftUI

// MARK: - Orb View

/// The assistant's visual soul, ported from Jarvis.
///
/// One state is new: `.looking`. Jarvis's orb only ever knew about hearing,
/// thinking, and talking — it needed a way to show that the app is *seeing*, so
/// the orb shifts from cyan to amber and an iris contracts inside it. That shift
/// is the whole merge in one glyph.
struct OrbView: View {
    let state: AssistantState
    let audioLevel: Float

    @State private var breathe = false
    @State private var processingRotation: Double = 0
    @State private var irisScale: CGFloat = 1.0

    private let orbSize: CGFloat = 170

    var body: some View {
        ZStack {
            outerRings
            audioReactiveRing
            processingRing
            core
            iris
        }
        .onAppear {
            startBreathing()
            startProcessingSpin()
        }
        .onChange(of: state) { _, newState in
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                irisScale = newState == .looking ? 0.55 : 1.0
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Assistant")
        .accessibilityValue(state.displayText)
    }

    // MARK: - Layers

    private var outerRings: some View {
        ForEach(0..<3, id: \.self) { ring in
            Circle()
                .stroke(
                    ringColor.opacity(0.09 - Double(ring) * 0.025),
                    lineWidth: 1.5
                )
                .frame(
                    width: orbSize + CGFloat(ring) * 42 + glowExpansion,
                    height: orbSize + CGFloat(ring) * 42 + glowExpansion
                )
                .scaleEffect(breathe ? 1.02 : 0.98)
        }
    }

    @ViewBuilder
    private var audioReactiveRing: some View {
        if state == .listening {
            Circle()
                .stroke(
                    accentColor.opacity(Double(audioLevel) * 0.6),
                    lineWidth: 2 + CGFloat(audioLevel) * 4
                )
                .frame(
                    width: orbSize + 20 + CGFloat(audioLevel) * 30,
                    height: orbSize + 20 + CGFloat(audioLevel) * 30
                )
                .animation(.easeOut(duration: 0.08), value: audioLevel)
        }
    }

    @ViewBuilder
    private var processingRing: some View {
        if state == .thinking || state == .looking {
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(
                    AngularGradient(colors: [.clear, accentColor], center: .center),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .frame(width: orbSize + 26, height: orbSize + 26)
                .rotationEffect(.degrees(processingRotation))
        }
    }

    private var core: some View {
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(colors: gradientColors),
                    center: .center,
                    startRadius: 0,
                    endRadius: orbSize / 2
                )
            )
            .frame(width: orbSize, height: orbSize)
            .overlay(
                // Specular highlight — makes it read as a sphere, not a disc.
                Circle().fill(
                    RadialGradient(
                        gradient: Gradient(colors: [.white.opacity(0.15), .clear]),
                        center: UnitPoint(x: 0.35, y: 0.3),
                        startRadius: 0,
                        endRadius: orbSize * 0.4
                    )
                )
            )
            .scaleEffect(orbScale)
            .shadow(color: glowColor.opacity(glowIntensity), radius: 30)
            .shadow(color: glowColor.opacity(glowIntensity * 0.5), radius: 60)
    }

    /// Only visible while looking — a contracting pupil over the core.
    @ViewBuilder
    private var iris: some View {
        if state == .looking {
            Circle()
                .stroke(Color.black.opacity(0.55), lineWidth: 18)
                .frame(width: orbSize * 0.62, height: orbSize * 0.62)
                .scaleEffect(irisScale)
                .blur(radius: 6)
                .transition(.opacity)
        }
    }

    // MARK: - Palette

    /// Amber while seeing, red on error, cyan otherwise.
    private var accentColor: Color {
        switch state {
        case .looking: return Color(red: 1.0, green: 0.72, blue: 0.25)
        case .error: return .red
        default: return .cyan
        }
    }

    private var ringColor: Color {
        state == .wakeWordListening ? accentColor.opacity(0.4) : accentColor
    }

    private var glowColor: Color { accentColor }

    private var gradientColors: [Color] {
        switch state {
        case .idle:
            return [
                Color(red: 0.10, green: 0.40, blue: 0.60),
                Color(red: 0.05, green: 0.15, blue: 0.30),
                Color(red: 0.02, green: 0.05, blue: 0.15),
            ]
        case .wakeWordListening:
            // Dim, ambient — just barely alive.
            return [
                Color(red: 0.06, green: 0.20, blue: 0.35),
                Color(red: 0.03, green: 0.10, blue: 0.20),
                Color(red: 0.01, green: 0.04, blue: 0.10),
            ]
        case .listening:
            return [
                Color(red: 0.00, green: 0.60, blue: 0.80),
                Color(red: 0.00, green: 0.30, blue: 0.60),
                Color(red: 0.00, green: 0.10, blue: 0.30),
            ]
        case .thinking:
            return [
                Color(red: 0.20, green: 0.40, blue: 0.70),
                Color(red: 0.10, green: 0.20, blue: 0.50),
                Color(red: 0.05, green: 0.10, blue: 0.30),
            ]
        case .looking:
            return [
                Color(red: 0.95, green: 0.65, blue: 0.20),
                Color(red: 0.55, green: 0.32, blue: 0.06),
                Color(red: 0.22, green: 0.12, blue: 0.02),
            ]
        case .speaking:
            return [
                Color(red: 0.00, green: 0.70, blue: 0.90),
                Color(red: 0.00, green: 0.40, blue: 0.70),
                Color(red: 0.00, green: 0.15, blue: 0.35),
            ]
        case .error:
            return [
                Color(red: 0.60, green: 0.15, blue: 0.10),
                Color(red: 0.30, green: 0.05, blue: 0.05),
                Color(red: 0.15, green: 0.02, blue: 0.02),
            ]
        }
    }

    private var glowIntensity: Double {
        switch state {
        case .wakeWordListening: return 0.15
        case .idle: return 0.40
        case .listening: return 0.50
        case .looking: return 0.65
        case .speaking: return 0.60
        default: return 0.40
        }
    }

    private var orbScale: CGFloat {
        switch state {
        case .wakeWordListening: return breathe ? 1.01 : 0.99
        case .listening: return 1.0 + CGFloat(audioLevel) * 0.12
        case .speaking: return 1.0 + CGFloat(audioLevel) * 0.08
        case .thinking, .looking: return breathe ? 1.03 : 0.97
        default: return breathe ? 1.02 : 0.98
        }
    }

    private var glowExpansion: CGFloat {
        switch state {
        case .listening: return CGFloat(audioLevel) * 20
        case .speaking: return 10
        case .looking: return 14
        case .wakeWordListening: return -5
        default: return 0
        }
    }

    // MARK: - Animations

    private func startBreathing() {
        withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
            breathe = true
        }
    }

    private func startProcessingSpin() {
        withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
            processingRotation = 360
        }
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        VStack(spacing: 60) {
            OrbView(state: .wakeWordListening, audioLevel: 0)
            OrbView(state: .looking, audioLevel: 0)
        }
    }
}
