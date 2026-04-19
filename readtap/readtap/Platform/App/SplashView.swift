import SwiftUI

struct SplashView: View {
    let onComplete: () -> Void
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    // Phase timeline
    // 0 -> Pulsing text (loading state)
    // 1 -> text expands UP (scale 1.0 -> 1.2) - "inhale"
    // 2 -> text presses DOWN (scale 1.2 -> 0.9) - "tap/exhale"
    // 3 -> text relaxes back to normal (scale 0.9 -> 1.0)
    // 4 -> whole screen fades out to reveal the app
    @State private var phase = 0
    
    // Controls the continuous throbbing animation independent of phases
    @State private var isPulsing = false

    private let minSplashDuration: TimeInterval = 2.4
    let didWarmUpStart = Date()

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            VStack(spacing: 6) {
                Text("ReadTap")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundColor(Color(red: 0.122, green: 0.678, blue: 0.380))
                    .scaleEffect(phase == 0 ? (isPulsing ? 1.03 : 1.0) : 1.0)
                    .opacity(phase == 0 ? (isPulsing ? 0.75 : 1.0) : 1.0)
                    .animation(phase == 0 ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: isPulsing)
                    .scaleEffect(scaleForPhase)
                    .opacity(phase == 4 ? 0 : 1)
                    .animation(.spring(response: 0.6, dampingFraction: 0.7), value: phase)

                Text("Your reading companion")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(Color(red: 0.580, green: 0.639, blue: 0.722))
                    .opacity(phase == 4 ? 0 : 1)
                    .animation(.spring(response: 0.6, dampingFraction: 0.7), value: phase)
            }
        }
        .opacity(phase == 4 ? 0 : 1)
        .animation(.easeInOut(duration: 0.5), value: phase == 4)
        .onAppear {
            // Start the loading throb immediately so it doesn't look frozen
            isPulsing = true
            
            Task {
                await AppWarmup.shared.warmUpIfNeeded { _ in }

                let elapsed = Date().timeIntervalSince(didWarmUpStart)
                let remaining = minSplashDuration - elapsed
                if remaining > 0 {
                    try? await Task.sleep(for: .seconds(remaining))
                }

                // Warmup + Minimum duration has passed. Now execute the final Tap animation!
                await MainActor.run {
                    startFinalTapSequence()
                }
            }
        }
    }

    private var scaleForPhase: CGFloat {
        switch phase {
        case 0: return 1.0 // Base scale, augmented by isPulsing
        case 1: return 1.2
        case 2: return 0.92
        case 3: return 1.0
        default: return 1.0
        }
    }

    private func startFinalTapSequence() {
        // Run the phases sequentially. No more freezing!
        phase = 1 // Inhale (Stop pulsing automatically via ternary)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { phase = 2 } // Press
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { phase = 3 } // Settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            phase = 4 // Fade to app
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                onComplete()
            }
        }
    }
}
